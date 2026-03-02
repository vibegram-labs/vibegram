
import forge from 'node-forge';
import { Buffer } from 'buffer';
import Constants, { ExecutionEnvironment } from 'expo-constants';

const isExpoGo = Constants.executionEnvironment === ExecutionEnvironment.StoreClient;

let QuickCrypto: any = null;
if (!isExpoGo) {
    try {
        // Try to load the native module
        QuickCrypto = require('react-native-quick-crypto');
        if (QuickCrypto && QuickCrypto.default) QuickCrypto = QuickCrypto.default;
    } catch (e) {
        console.warn("QuickCrypto module not found. Falling back to slow legacy crypto.");
    }
}

const USE_NATIVE = !!QuickCrypto && !!QuickCrypto.generateKeyPairSync;

console.log(`[CRYPTO] Using ${USE_NATIVE ? 'Fast Native (QuickCrypto)' : 'Slow Legacy (Forge)'} Implementation`);

// Lazy accessor for the native CryptoKit/JCA module (preferred over QuickCrypto)
let _nativeCryptoCore: any = undefined;
const getNativeCryptoCore = () => {
    if (_nativeCryptoCore !== undefined) return _nativeCryptoCore;
    if (isExpoGo) { _nativeCryptoCore = null; return null; }
    try {
        const { getNativeChatCoreModule } = require('../native/chat/runtime');
        const mod = getNativeChatCoreModule();
        _nativeCryptoCore = (mod?.supportsCryptoPipeline?.()) ? mod : null;
    } catch { _nativeCryptoCore = null; }
    return _nativeCryptoCore;
};

export type NativeKeyPair = {
    publicKey: string; // PEM string
    privateKey: string; // PEM string
};

// --- Helpers ---

const toBase64 = (bytes: string | Buffer | Uint8Array): string => {
    if (typeof bytes === 'string') return forge.util.encode64(bytes);
    // QuickCrypto returns Buffers usually
    return Buffer.from(bytes).toString('base64');
};

const fromBase64 = (base64: string): Buffer => {
    return Buffer.from(base64, 'base64');
};

// Forge helper for fallback
const forgeFromBase64 = (base64: string): string => {
    return forge.util.decode64(base64.replace(/\s/g, ''));
};

const forgeToBase64 = (bytes: string): string => {
    return forge.util.encode64(bytes);
};

// --- Key Management ---

export const generateKeyPair = async (): Promise<NativeKeyPair> => {
    if (USE_NATIVE) {
        try {
            // Use ASYNC version to avoid blocking UI
            return new Promise((resolve, reject) => {
                QuickCrypto.generateKeyPair(
                    'rsa',
                    {
                        modulusLength: 2048,
                        publicKeyEncoding: { type: 'spki', format: 'pem' },
                        privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
                    },
                    (err: any, publicKey: string, privateKey: string) => {
                        if (err) {
                            console.error("Native Async Gen Key Failed", err);
                            reject(err);
                        } else {
                            resolve({ publicKey, privateKey });
                        }
                    }
                );
            });
        } catch (e) {
            console.error("Native Gen Key Setup Failed", e);
            // Fall through to fallback
        }
    }

    // Fallback using Forge with UI yielding
    return new Promise((resolve, reject) => {
        try {
            const ExpoCrypto = require('expo-crypto');
            const seed = ExpoCrypto.getRandomBytes(32);
            if (typeof (forge.random as any).collect === 'function') {
                let seedStr = '';
                for (let i = 0; i < seed.length; i++) {
                    seedStr += String.fromCharCode(seed[i]);
                }
                (forge.random as any).collect(seedStr);
            } else {
                forge.random.getBytesSync(1);
            }

            // Use requestAnimationFrame + setTimeout to yield to UI
            requestAnimationFrame(() => {
                setTimeout(() => {
                    try {
                        // SECURITY: Use 2048 bits minimum — 1024 is broken since 2010
                        const keypair = forge.pki.rsa.generateKeyPair({ bits: 2048, workers: -1 });
                        resolve({
                            publicKey: forge.pki.publicKeyToPem(keypair.publicKey),
                            privateKey: forge.pki.privateKeyToPem(keypair.privateKey)
                        });
                    } catch (e) {
                        reject(e);
                    }
                }, 50);
            });
        } catch (e) {
            console.error("Forge Key Gen Init Failed", e);
            reject(e);
        }
    });
};

export const exportPublicKey = async (key: string): Promise<string> => {
    // It's already PEM
    return key
        .replace(/-----BEGIN PUBLIC KEY-----/g, '')
        .replace(/-----END PUBLIC KEY-----/g, '')
        .replace(/[\r\n]/g, '');
};

export const importPublicKey = async (pem: string): Promise<string> => {
    let fullPem = pem;
    if (!pem.includes('BEGIN PUBLIC KEY')) {
        const chunked = pem.match(/.{1,64}/g)?.join('\n') || pem;
        fullPem = `-----BEGIN PUBLIC KEY-----\n${chunked}\n-----END PUBLIC KEY-----`;
    }
    return fullPem;
};

// PEM Helpers - Pass through since we store as PEM now
export const exportPrivateKeyPem = (key: string): string => key;
export const exportPublicKeyPem = (key: string): string => key;
export const importKeyPairFromPem = async (privatePem: string, publicPem: string): Promise<NativeKeyPair> => {
    return { privateKey: privatePem, publicKey: publicPem };
};


// Async version of deriveKeyFromPassphrase to prevent UI blocking
export const deriveKeyFromPassphraseAsync = async (passphrase: string, salt: string): Promise<string> => {
    // Yield to UI first
    await new Promise(resolve => requestAnimationFrame(resolve));

    // Priority 1: Native CryptoKit/JCA (hardware-accelerated, no OpenSSL dep)
    const nativeCore = getNativeCryptoCore();
    if (nativeCore?.deriveKey) {
        try {
            const base64Key: string = await nativeCore.deriveKey({
                passphrase, salt, iterations: 600000, keyLength: 32,
            });
            return Buffer.from(base64Key, 'base64').toString('binary');
        } catch (e) {
            console.warn('[Crypto] Native deriveKey failed, falling back', e);
        }
    }

    // Priority 2: QuickCrypto (OpenSSL bindings)
    if (USE_NATIVE && QuickCrypto.pbkdf2) {
        // Use async native version if available
        return new Promise((resolve, reject) => {
            QuickCrypto.pbkdf2(
                passphrase,
                salt,
                600000,  // SECURITY: OWASP 2023 recommends 600,000+ iterations
                32,
                'sha256',
                (err: any, derivedKey: Buffer) => {
                    if (err) reject(err);
                    else resolve(derivedKey.toString('binary'));
                }
            );
        });
    }

    // Fallback - sync but with yield before
    await new Promise(resolve => setTimeout(resolve, 10));
    // SECURITY: OWASP 2023 recommends 600,000+ iterations
    return forge.pkcs5.pbkdf2(
        passphrase,
        salt,
        600000,
        32,
        forge.md.sha256.create()
    );
};

// Keep sync version for backward compatibility but prefer async
export const deriveKeyFromPassphrase = (passphrase: string, salt: string): string => {
    // SECURITY: OWASP 2023 recommends 600,000+ iterations
    if (USE_NATIVE) {
        const key = QuickCrypto.pbkdf2Sync(passphrase, salt, 600000, 32, 'sha256');
        return key.toString('binary');
    }
    return forge.pkcs5.pbkdf2(
        passphrase,
        salt,
        600000,
        32,
        forge.md.sha256.create()
    );
};

export const encryptPrivateKey = (privateKeyPem: string, keyBytes: string): string => {
    try {
        const pKey = forge.pki.privateKeyFromPem(privateKeyPem);
        const asn1 = forge.pki.privateKeyToAsn1(pKey);
        const derBuffer = forge.asn1.toDer(asn1);
        const dataBytes = derBuffer.getBytes();

        if (USE_NATIVE) {
            try {
                // Use QuickCrypto AES-GCM
                const iv = QuickCrypto.randomBytes(12);
                const cipher = QuickCrypto.createCipheriv('aes-256-gcm', Buffer.from(keyBytes, 'binary'), iv);

                // Encrypt
                // dataBytes from forge is binary string -> Buffer
                const dataBuffer = Buffer.from(dataBytes, 'binary');

                // Cipher update/final
                // Force return Buffer? usually default.
                let encryptedBuf = cipher.update(dataBuffer);
                // Check type
                if (!Buffer.isBuffer(encryptedBuf)) {
                    console.warn("QuickCrypto.update returned non-Buffer, converting.");
                    encryptedBuf = Buffer.from(encryptedBuf, 'binary');
                }

                let finalEncBuf = cipher.final();
                if (!Buffer.isBuffer(finalEncBuf)) {
                    console.warn("QuickCrypto.final returned non-Buffer, converting.");
                    finalEncBuf = Buffer.from(finalEncBuf, 'binary');
                }

                const totalEncrypted = Buffer.concat([encryptedBuf, finalEncBuf]);

                let tag = cipher.getAuthTag();
                if (!Buffer.isBuffer(tag)) {
                    console.warn("QuickCrypto.getAuthTag returned non-Buffer, converting.");
                    tag = Buffer.from(tag, 'binary');
                }

                // Format: Base64(IV + Encrypted + Tag) 
                const finalBuf = Buffer.concat([
                    iv,
                    totalEncrypted,
                    tag
                ]);
                return finalBuf.toString('base64');
            } catch (nativeErr) {
                console.warn("Native Encrypt PrivKey failed, falling back to Forge", nativeErr);
                // Fallthrough to legacy code below
            }
        }

        // Fallback Force
        const ivBytes = forge.random.getBytesSync(12);
        const cipher = forge.cipher.createCipher('AES-GCM', forge.util.createBuffer(keyBytes));
        cipher.start({ iv: forge.util.createBuffer(ivBytes) });
        cipher.update(forge.util.createBuffer(dataBytes));
        cipher.finish();
        const encrypted = cipher.output.getBytes();
        const tag = cipher.mode.tag.getBytes();
        return forgeToBase64(ivBytes + encrypted + tag);

    } catch (e) {
        console.error("Encrypt Private Key Error", e);
        throw e;
    }
};

export const decryptPrivateKey = (encryptedBase64: string, keyBytes: string): string => {
    // Return PEM
    const combined = forgeFromBase64(encryptedBase64); // Binary string

    const ivBytes = combined.slice(0, 12);
    const contentWithTag = combined.slice(12);
    const tagLength = 16;
    const encryptedContent = contentWithTag.slice(0, contentWithTag.length - tagLength);
    const tag = contentWithTag.slice(contentWithTag.length - tagLength);

    if (USE_NATIVE) {
        try {
            const decipher = QuickCrypto.createDecipheriv(
                'aes-256-gcm',
                Buffer.from(keyBytes, 'binary'),
                Buffer.from(ivBytes, 'binary')
            );
            decipher.setAuthTag(Buffer.from(tag, 'binary'));

            // FIX: Output binary instead of utf8, because the content is DER (binary)
            // decipher.update returns Buffer if no encoding given, or string if encoding given.
            // Let's use Buffers throughout to be safe.
            let decryptedBuf = decipher.update(Buffer.from(encryptedContent, 'binary'));
            const finalBuf = decipher.final();
            const totalBuf = Buffer.concat([decryptedBuf, finalBuf]);

            const decryptedString = totalBuf.toString('utf8');

            if (decryptedString.includes('-----BEGIN RSA PRIVATE KEY-----')) {
                return decryptedString;
            }

            // If it's binary DER, convert to PEM using Forge (which expects binary string)
            const binaryString = totalBuf.toString('binary');
            const asn1 = forge.asn1.fromDer(binaryString);
            const key = forge.pki.privateKeyFromAsn1(asn1);
            return forge.pki.privateKeyToPem(key);

        } catch (e) {
            console.warn("Native Decrypt PrivKey failed, trying Legacy", e);
        }
    }

    // Fallback: Ensure we use Buffers for Key and IV to prevent string encoding issues
    const decipher = forge.cipher.createDecipher('AES-GCM', forge.util.createBuffer(keyBytes));
    decipher.start({
        iv: forge.util.createBuffer(ivBytes),
        tag: forge.util.createBuffer(tag)
    });
    decipher.update(forge.util.createBuffer(encryptedContent));

    const success = decipher.finish();
    if (!success) {
        // Detailed error for debugging
        throw new Error(`Private Key Decryption Failed: Auth Tag Mismatch (KeyLen: ${keyBytes.length}, IVLen: ${ivBytes.length}, TagLen: ${tag.length})`);
    }

    // Safety check for output
    if (!decipher.output) {
        throw new Error('Private Key Decryption Failed: No output from decipher');
    }

    // First try to get bytes (for binary DER data)
    const derBytes = decipher.output.getBytes();

    // Check if it's already a PEM string
    if (derBytes.includes('-----BEGIN RSA PRIVATE KEY-----')) {
        return derBytes;
    }

    // Treat as binary DER and convert to PEM
    try {
        const asn1 = forge.asn1.fromDer(derBytes);
        const key = forge.pki.privateKeyFromAsn1(asn1);
        return forge.pki.privateKeyToPem(key);
    } catch (derError: any) {
        console.error('DER parsing failed:', derError.message);
        throw new Error(`Private Key Decryption Failed: Invalid key format after decryption`);
    }
};


// --- Encryption / Decryption ---

export interface HybridPayload {
    v: number; iv: string; c: string; k: string; s?: string;
}

export const encryptMessage = async (
    recipientPublicKeyPem: string,
    message: string,
    myPublicKeyPem?: string
): Promise<string> => {
    try {
        if (USE_NATIVE) {
            const aesKey = QuickCrypto.randomBytes(32);
            const iv = QuickCrypto.randomBytes(12);

            const cipher = QuickCrypto.createCipheriv('aes-256-gcm', aesKey, iv);
            let encryptedC = cipher.update(message, 'utf8', 'base64');
            encryptedC += cipher.final('base64');
            const tag = cipher.getAuthTag().toString('base64');

            // Combine Enc+Tag for payload "c"
            const combinedC = Buffer.concat([Buffer.from(encryptedC, 'base64'), Buffer.from(tag, 'base64')]);

            // RSA Encrypt AES Key
            const encryptedKeyRecipient = QuickCrypto.publicEncrypt(
                { key: recipientPublicKeyPem, padding: QuickCrypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
                aesKey
            );

            let encryptedKeySender;
            if (myPublicKeyPem) {
                encryptedKeySender = QuickCrypto.publicEncrypt(
                    { key: myPublicKeyPem, padding: QuickCrypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
                    aesKey
                );
            }

            const payload: HybridPayload = {
                v: 1,
                iv: iv.toString('base64'),
                c: combinedC.toString('base64'),
                k: encryptedKeyRecipient.toString('base64'),
                s: encryptedKeySender ? encryptedKeySender.toString('base64') : undefined
            };
            return JSON.stringify(payload);
        }

        // --- FALLBACK FORGE ---
        const aesKeyBytes = forge.random.getBytesSync(32);
        const ivBytes = forge.random.getBytesSync(12);
        const cipher: any = forge.cipher.createCipher('AES-GCM', aesKeyBytes);
        cipher.start({ iv: ivBytes });
        cipher.update(forge.util.createBuffer(message, 'utf8'));
        if (!cipher.finish()) throw new Error('AES encryption failed to finish');
        const encryptedContent = cipher.output.getBytes();
        const tag = cipher.mode.tag.getBytes();
        const combinedContent = encryptedContent + tag;

        const rKey = forge.pki.publicKeyFromPem(recipientPublicKeyPem);
        // Forge RSA-OAEP encrypt
        const encryptedKeyForRecipient = rKey.encrypt(aesKeyBytes, 'RSA-OAEP', {
            md: forge.md.sha256.create(),
            mgf1: {
                md: forge.md.sha256.create()
            }
        });

        let encryptedKeyForSender: string | undefined;
        if (myPublicKeyPem) {
            const mKey = forge.pki.publicKeyFromPem(myPublicKeyPem);
            encryptedKeyForSender = mKey.encrypt(aesKeyBytes, 'RSA-OAEP', {
                md: forge.md.sha256.create(),
                mgf1: {
                    md: forge.md.sha256.create()
                }
            });
        }

        return JSON.stringify({
            v: 1,
            iv: forgeToBase64(ivBytes),
            c: forgeToBase64(combinedContent),
            k: forgeToBase64(encryptedKeyForRecipient),
            s: encryptedKeyForSender ? forgeToBase64(encryptedKeyForSender) : undefined
        });

    } catch (e: any) {
        console.error("Encryption Failed", e);
        throw new Error(`Encryption failed: ${e.message}`);
    }
};

export const decryptMessage = async (
    privateKeyPem: string,
    ciphertext: string,
    isMyMessage: boolean = false
): Promise<string> => {
    try {
        if (!ciphertext) return "";
        const trimmedCiphertext = ciphertext.trim();
        if (!trimmedCiphertext.startsWith('{')) return "[Decryption Failed - Format]";

        const payload: HybridPayload = JSON.parse(trimmedCiphertext);
        // Group messages are plain JSON (e.g. {"text":"hello"}) — return as-is without decryption.
        if (!payload.iv || !payload.c) {
            return trimmedCiphertext;
        }
        const keysToTry: { field: 'k' | 's', key: string }[] = [];

        if (isMyMessage) {
            if (payload.s) keysToTry.push({ field: 's', key: payload.s });
            if (payload.k) keysToTry.push({ field: 'k', key: payload.k });
        } else {
            if (payload.k) keysToTry.push({ field: 'k', key: payload.k });
            if (payload.s) keysToTry.push({ field: 's', key: payload.s });
        }

        if (USE_NATIVE) {
            let aesKey: Buffer | null = null;

            for (const { key } of keysToTry) {
                try {
                    const keyBuf = Buffer.from(key, 'base64');
                    aesKey = QuickCrypto.privateDecrypt(
                        { key: privateKeyPem, padding: QuickCrypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
                        keyBuf
                    );
                    if (aesKey) break;
                } catch (e) { }
            }

            if (!aesKey) throw new Error('Could not decrypt AES key');

            const iv = Buffer.from(payload.iv, 'base64');
            const combined = Buffer.from(payload.c, 'base64');
            const tagLen = 16;
            const encryptedContent = combined.subarray(0, combined.length - tagLen); // use subarray for Node buffer
            const tag = combined.subarray(combined.length - tagLen);

            const decipher = QuickCrypto.createDecipheriv('aes-256-gcm', aesKey, iv);
            decipher.setAuthTag(tag);
            let decrypted = decipher.update(encryptedContent, null, 'utf8');
            decrypted += decipher.final('utf8');
            return decrypted;
        }

        // --- FALLBACK FORGE ---
        const privateKey = forge.pki.privateKeyFromPem(privateKeyPem);
        let aesKeyBytes: string | null = null;
        for (const { key } of keysToTry) {
            try {
                const encryptedKeyBytes = forgeFromBase64(key);
                aesKeyBytes = privateKey.decrypt(encryptedKeyBytes, 'RSA-OAEP', { md: forge.md.sha256.create() });
                if (aesKeyBytes) break;
            } catch (e) { }
        }

        if (!aesKeyBytes) throw new Error('Could not decrypt AES key');

        const ivBytes = forgeFromBase64(payload.iv);
        const combinedContentBytes = forgeFromBase64(payload.c);
        const tagLength = 16;
        const encryptedContent2 = combinedContentBytes.slice(0, combinedContentBytes.length - tagLength);
        const tag2 = combinedContentBytes.slice(combinedContentBytes.length - tagLength);

        const decipher2 = forge.cipher.createDecipher('AES-GCM', aesKeyBytes);
        decipher2.start({ iv: ivBytes, tag: forge.util.createBuffer(tag2) });
        decipher2.update(forge.util.createBuffer(encryptedContent2));

        const success = decipher2.finish();
        if (!success) throw new Error('AES-GCM Authentication failed');

        return decipher2.output.toString();

    } catch (e: any) {
        console.warn('Decryption error details:', e);
        return "[Decryption Failed]";
    }
};


// --- FILE-LEVEL ENCRYPTION for media uploads ---
// Encrypts raw file data with AES-256-GCM so the CDN/server never sees plaintext media

export interface FileEncryptionResult {
    /** Base64 encoded: IV (12B) + encrypted data + auth tag (16B) */
    encryptedBase64: string;
    /** Base64 encoded AES-256 key — include this inside the E2E encrypted message payload */
    keyBase64: string;
}

/**
 * Encrypt file data (as base64 string) with a random AES-256-GCM key.
 * The key must be shared with the recipient inside the E2E encrypted message.
 */
export const encryptFileData = async (fileBase64: string): Promise<FileEncryptionResult> => {
    // Priority 1: Native CryptoKit/JCA module
    const nativeCore = getNativeCryptoCore();
    if (nativeCore?.encryptFileData) {
        try {
            return await nativeCore.encryptFileData({ data: fileBase64 });
        } catch (e) {
            console.warn('[Crypto] Native encryptFileData failed, falling back', e);
        }
    }

    // Priority 2: QuickCrypto
    if (USE_NATIVE) {
        try {
            const aesKey = QuickCrypto.randomBytes(32);
            const iv = QuickCrypto.randomBytes(12);
            const dataBuf = Buffer.from(fileBase64, 'base64');

            const cipher = QuickCrypto.createCipheriv('aes-256-gcm', aesKey, iv);
            let encrypted = cipher.update(dataBuf);
            if (!Buffer.isBuffer(encrypted)) encrypted = Buffer.from(encrypted, 'binary');
            let final = cipher.final();
            if (!Buffer.isBuffer(final)) final = Buffer.from(final, 'binary');
            let tag = cipher.getAuthTag();
            if (!Buffer.isBuffer(tag)) tag = Buffer.from(tag, 'binary');

            const combined = Buffer.concat([iv, encrypted, final, tag]);
            return {
                encryptedBase64: combined.toString('base64'),
                keyBase64: aesKey.toString('base64'),
            };
        } catch (e) {
            console.warn('[Crypto] Native file encrypt failed, falling back to Forge', e);
        }
    }

    // Forge fallback
    const aesKeyBytes = forge.random.getBytesSync(32);
    const ivBytes = forge.random.getBytesSync(12);
    const dataBinary = forge.util.decode64(fileBase64);

    const cipher: any = forge.cipher.createCipher('AES-GCM', aesKeyBytes);
    cipher.start({ iv: ivBytes });
    cipher.update(forge.util.createBuffer(dataBinary));
    if (!cipher.finish()) throw new Error('File AES encryption failed');

    const encBytes = cipher.output.getBytes();
    const tagBytes = cipher.mode.tag.getBytes();
    const combined = ivBytes + encBytes + tagBytes;

    return {
        encryptedBase64: forge.util.encode64(combined),
        keyBase64: forge.util.encode64(aesKeyBytes),
    };
};

/**
 * Encrypt a large file by reading in chunks instead of loading the entire file
 * into a single base64 JS string. This avoids ~4x memory bloat on large files.
 *
 * Reads source file in 1MB raw chunks → feeds each through the streaming
 * AES-256-GCM cipher → collects encrypted Buffer objects → writes final
 * combined output (IV + ciphertext + tag) to destUri in one shot.
 *
 * Peak memory: ~fileSize (encrypted Buffers) + 1MB (read chunk) instead of
 * ~4x fileSize with the base64 round-trip approach.
 *
 * Output format is identical to encryptFileData: IV (12B) + ciphertext + authTag (16B).
 * Requires native QuickCrypto (production builds).
 */
export const encryptFileChunked = async (
    sourceUri: string,
    destUri: string,
    onProgress?: (fraction: number) => void,
): Promise<{ keyBase64: string } | null> => {
    if (!USE_NATIVE) return null; // Chunked mode requires native crypto

    const FileSystem = require('expo-file-system');
    const info = await FileSystem.getInfoAsync(sourceUri);
    const totalBytes: number = (info as any).size || 0;
    if (totalBytes === 0) return null;

    const CHUNK_SIZE = 1024 * 1024; // 1 MB per chunk
    const aesKey = QuickCrypto.randomBytes(32);
    const iv = QuickCrypto.randomBytes(12);

    const cipher = QuickCrypto.createCipheriv('aes-256-gcm', aesKey, iv);

    // Collect encrypted chunks as raw Buffers (NOT base64 strings — saves ~33% memory)
    const encryptedParts: Buffer[] = [Buffer.from(iv)];

    let offset = 0;
    while (offset < totalBytes) {
        const len = Math.min(CHUNK_SIZE, totalBytes - offset);

        // Read one chunk as base64 from disk (~1.3MB string for 1MB raw)
        const chunkB64: string = await FileSystem.readAsStringAsync(sourceUri, {
            encoding: FileSystem.EncodingType.Base64,
            position: offset,
            length: len,
        });

        // Decode to raw Buffer, encrypt, store encrypted Buffer
        const chunkBuf = Buffer.from(chunkB64, 'base64');
        let enc = cipher.update(chunkBuf);
        if (!Buffer.isBuffer(enc)) enc = Buffer.from(enc, 'binary');
        encryptedParts.push(enc);

        offset += len;
        if (onProgress) onProgress(offset / totalBytes);
    }

    let final = cipher.final();
    if (!Buffer.isBuffer(final)) final = Buffer.from(final, 'binary');
    if (final.length > 0) encryptedParts.push(final);

    let tag = cipher.getAuthTag();
    if (!Buffer.isBuffer(tag)) tag = Buffer.from(tag, 'binary');
    encryptedParts.push(tag);

    // Concat all parts and write to dest file in one shot
    const combined = Buffer.concat(encryptedParts);
    await FileSystem.writeAsStringAsync(destUri, combined.toString('base64'), {
        encoding: FileSystem.EncodingType.Base64,
    });

    return { keyBase64: aesKey.toString('base64') };
};

/**
 * Decrypt file data that was encrypted with encryptFileData.
 * Returns the original file content as a base64 string.
 */
export const decryptFileData = async (encryptedBase64: string, keyBase64: string): Promise<string> => {
    // Priority 1: Native CryptoKit/JCA module
    const nativeCore = getNativeCryptoCore();
    if (nativeCore?.decryptFileData) {
        try {
            return await nativeCore.decryptFileData({ encryptedBase64, keyBase64 });
        } catch (e) {
            console.warn('[Crypto] Native decryptFileData failed, falling back', e);
        }
    }

    // Priority 2: QuickCrypto
    if (USE_NATIVE) {
        try {
            const combined = Buffer.from(encryptedBase64, 'base64');
            const aesKey = Buffer.from(keyBase64, 'base64');
            const iv = combined.subarray(0, 12);
            const tagLen = 16;
            const encrypted = combined.subarray(12, combined.length - tagLen);
            const tag = combined.subarray(combined.length - tagLen);

            const decipher = QuickCrypto.createDecipheriv('aes-256-gcm', aesKey, iv);
            decipher.setAuthTag(tag);
            let decrypted = decipher.update(encrypted);
            if (!Buffer.isBuffer(decrypted)) decrypted = Buffer.from(decrypted, 'binary');
            let final = decipher.final();
            if (!Buffer.isBuffer(final)) final = Buffer.from(final, 'binary');

            return Buffer.concat([decrypted, final]).toString('base64');
        } catch (e) {
            console.warn('[Crypto] Native file decrypt failed, falling back to Forge', e);
        }
    }

    // Forge fallback
    const combinedBinary = forge.util.decode64(encryptedBase64);
    const aesKeyBytes = forge.util.decode64(keyBase64);
    const ivBytes = combinedBinary.slice(0, 12);
    const tagLen = 16;
    const encContent = combinedBinary.slice(12, combinedBinary.length - tagLen);
    const tagBytes = combinedBinary.slice(combinedBinary.length - tagLen);

    const decipher = forge.cipher.createDecipher('AES-GCM', aesKeyBytes);
    decipher.start({ iv: ivBytes, tag: forge.util.createBuffer(tagBytes) });
    decipher.update(forge.util.createBuffer(encContent));

    if (!decipher.finish()) throw new Error('File AES-GCM auth failed');
    const decryptedBinary = decipher.output.getBytes();
    return forge.util.encode64(decryptedBinary);
};
