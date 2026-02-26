import { create } from 'zustand';
import { createJSONStorage, persist } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { Socket as PhxSocket, Channel } from 'phoenix';
import { Buffer } from 'buffer';
import ProxyManager from './ProxyManager';
import AuthManager from './AuthManager';
import { Chat, Message } from './types';
import { importPublicKey, encryptFileData, encryptFileChunked } from './crypto';
import { decryptMessagesBatch, encryptMessageNativeFirst } from '../native/chat/core';
import * as Crypto from 'expo-crypto';
import * as FileSystem from 'expo-file-system/legacy';
import SoundManager from './SoundManager';
import { uploadMedia } from './api-client';
import { useEncryptedMediaStore } from './stores/encrypted-media-store';
import { manipulateAsync, SaveFormat } from 'expo-image-manipulator';
import { fetchHomeChatsNativeFirst } from '../native/home/api';

const CHATSTORE_DEBUG = false;
const chatStoreLog = (...args: any[]) => {
    if (CHATSTORE_DEBUG) console.log(...args);
};
const CHATSTORE_MESSAGE_FLOW_DEBUG = false;
const chatStoreMessageLog = (...args: any[]) => {
    const runtimeEnabled = __DEV__ && (globalThis as any).__VIBE_CHATSTORE_MSGFLOW_DEBUG === true;
    if (CHATSTORE_MESSAGE_FLOW_DEBUG || CHATSTORE_DEBUG || runtimeEnabled) {
        if (CHATSTORE_DEBUG) {
            console.log('[ChatStore][MsgFlow]', ...args);
        }
    }
};
const CHATSTORE_HISTORY_PERF_LOG = false;
const chatStoreHistoryPerfLog = (...args: any[]) => {
    if (!CHATSTORE_HISTORY_PERF_LOG) return;
    console.log('[ChatStore][HistoryPerf]', ...args);
};
const MEDIA_UPLOAD_DEFERRED = 'MEDIA_UPLOAD_DEFERRED';
const MEDIA_LOCAL_FILE_MISSING = 'MEDIA_LOCAL_FILE_MISSING';
const LOCAL_MEDIA_MISSING_USER_MESSAGE = 'Local media file is no longer available. Please record/select again.';
const RETRY_DISPATCH_GAP_MS = 320;
const STALE_SENDING_RETRY_MS = 14_000;

const isRecoverableSendError = (error: unknown) => {
    const message = String((error as any)?.message || error || '').toLowerCase();
    return (
        message.includes('network request failed') ||
        message.includes('network error') ||
        message.includes('failed to fetch') ||
        message.includes('fetch failed') ||
        message.includes('timeout') ||
        message.includes('transport_close') ||
        message.includes('upload') ||
        message.includes('channel') ||
        message.includes('socket') ||
        message.includes('public key') ||
        message.includes('encryption key') ||
        message.includes('could not get encryption key') ||
        message.includes('not joined') ||
        message.includes('temporarily unavailable') ||
        message.includes(MEDIA_UPLOAD_DEFERRED.toLowerCase())
    );
};

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

const normalizeFileUri = (uri: string) => (uri.startsWith('file://') ? uri : `file://${uri}`);

const guessMediaExtension = (uri: string, type?: Message['type']): string => {
    const cleanUri = uri.split('?')[0].split('#')[0];
    const ext = cleanUri.split('.').pop()?.trim().toLowerCase();
    if (ext) return ext;
    if (type === 'voice' || type === 'music') return 'm4a';
    if (type === 'image') return 'jpg';
    if (type === 'video') return 'mp4';
    return 'bin';
};

const ensureReadableLocalUri = async (uri: string): Promise<string | null> => {
    const normalizedUri = normalizeFileUri(uri);
    const info = await FileSystem.getInfoAsync(normalizedUri);
    if (!(info as any)?.exists) return null;
    return normalizedUri;
};

const hasPermanentLocalMediaError = (message?: Pick<Message, 'errorMessage'> | null): boolean => {
    const errorText = String(message?.errorMessage || '').toLowerCase();
    if (!errorText) return false;
    return (
        errorText.includes(MEDIA_LOCAL_FILE_MISSING.toLowerCase()) ||
        errorText.includes('local media file is no longer available')
    );
};

const durableOutgoingMediaPath = (messageId: string, sourceUri: string, type?: Message['type']): string | null => {
    const baseDir = FileSystem.documentDirectory || FileSystem.cacheDirectory;
    if (!baseDir) return null;
    const ext = guessMediaExtension(sourceUri, type);
    return `${baseDir}outgoing-media/${messageId}.${ext}`;
};

const ensureDurableOutgoingLocalUri = async (
    sourceUri: string,
    messageId: string,
    type?: Message['type'],
): Promise<string | null> => {
    const normalizedSource = normalizeFileUri(sourceUri);
    const targetUri = durableOutgoingMediaPath(messageId, normalizedSource, type);

    if (targetUri) {
        const targetInfo = await FileSystem.getInfoAsync(targetUri);
        if ((targetInfo as any)?.exists) {
            return targetUri;
        }
    }

    const readableSource = await ensureReadableLocalUri(normalizedSource);
    if (!readableSource) return null;
    if (!targetUri) return readableSource;
    if (readableSource === targetUri) return readableSource;

    const dirParts = targetUri.split('/');
    dirParts.pop();
    const targetDir = dirParts.join('/');
    try {
        await FileSystem.makeDirectoryAsync(targetDir, { intermediates: true });
    } catch {
        // ignore mkdir race
    }

    try {
        await FileSystem.copyAsync({ from: readableSource, to: targetUri });
        chatStoreMessageLog('media:durable-copy', {
            messageId,
            type,
            from: readableSource,
            to: targetUri,
        });
        return targetUri;
    } catch (copyError) {
        chatStoreMessageLog('media:durable-copy-failed-using-source', {
            messageId,
            type,
            from: readableSource,
            to: targetUri,
            error: String(copyError),
        });
        return readableSource;
    }
};



// --- Obfuscation Helpers (Match Web Client) ---
const generateNoise = (len = 32) => {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    let result = '';
    for (let i = 0; i < len; i++) result += chars.charAt(Math.floor(Math.random() * chars.length));
    return result;
};

// Simplified obfuscation for Phoenix as well
const obfuscatePayload = (data: any) => {
    // For now, we'll send raw JSON to Phoenix to keep it simple during migration
    // If you want to keep obfuscation, you'd need to match the Elixir deobfuscator
    // But since `deobfuscatePayload` on server was specific to the Node implementation,
    // we will start with clear JSON for reliability, or implement a matching Elixir plug.

    // Assuming the Elixir backend currently accepts raw JSON or standard params in channels.
    return data;
};

const deobfuscatePayload = (wrapped: any) => {
    try {
        if (wrapped && wrapped.d) {
            // Decode base64 to string using Buffer which is more reliable in RN
            const decoded = Buffer.from(wrapped.d, 'base64').toString('utf-8');
            return JSON.parse(decoded);
        }
    } catch (e) {
        console.error('[ChatStore] Deobfuscate failed:', e);
    }
    return wrapped;
};

// Helper to parse decrypted content which might be JSON (new format) or string (legacy)
const parseDecryptedContent = (decrypted: string): Partial<Message> => {
    try {
        if (decrypted.trim().startsWith('{')) {
            const parsed = JSON.parse(decrypted);
            // Check if it's our metadata payload
            if (parsed.text !== undefined || parsed.mediaUrl !== undefined || parsed.contact !== undefined) {
                return {
                    plaintext: parsed.text,
                    mediaUrl: parsed.mediaUrl,
                    mediaKey: parsed.mediaKey, // AES key!
                    fileName: parsed.fileName,
                    fileSize: parsed.fileSize,
                    latitude: parsed.latitude,
                    longitude: parsed.longitude,
                    duration: parsed.duration,
                    replyToId: parsed.replyToId,
                    contact: parsed.contact,
                    caption: parsed.caption,
                    viewOnce: parsed.viewOnce,
                    isVideoNote: parsed.isVideoNote,
                    isEdited: parsed.isEdited === true,
                    editedAt: typeof parsed.editedAt === 'number' ? parsed.editedAt : undefined,
                    extra: {
                        width: parsed.width,
                        height: parsed.height,
                        thumbnailBase64: parsed.thumbnailBase64,
                        waveform: parsed.waveform,
                    },
                };
            }
        }
    } catch (e) {
        // Not JSON, fall through to string
    }
    return { plaintext: decrypted };
};

const normalizeMessage = (m: any): Message => {
    let content = m.plaintext || m._senderPlaintext || m.sender_plaintext;
    let extra: Partial<Message> = {};

    // Detect if content is a JSON string (e.g. {"text":"..."})
    if (typeof content === 'string' && content.trim().startsWith('{')) {
        const parsed = parseDecryptedContent(content);
        if (parsed.plaintext !== undefined) {
            content = parsed.plaintext;
            extra = parsed;
        }
    }

    return {
        id: m.id || m.message_id,
        fromId: m.fromId || m.from_id,
        chatId: m.chatId || m.chat_id,
        encryptedContent: m.encryptedContent || m.encrypted_content,
        type: m.type || 'text',
        timestamp: typeof m.timestamp === 'string' ? new Date(m.timestamp).getTime() : (m.timestamp || Date.now()),
        plaintext: content,
        status: m.status || 'sent',
        readBy: m.readBy || m.read_by || [],
        mediaUrl: extra.mediaUrl || m.mediaUrl || m.media_url,
        mediaKey: extra.mediaKey, // Pass through key
        fileName: extra.fileName || m.fileName || m.file_name,
        fileSize: extra.fileSize || m.fileSize || m.file_size,
        latitude: extra.latitude || m.latitude,
        longitude: extra.longitude || m.longitude,
        duration: extra.duration || m.duration,
        replyToId: extra.replyToId || m.replyToId || m.reply_to_id,
        contact: extra.contact || m.contact,
        caption: extra.caption || m.caption,
        viewOnce: extra.viewOnce || m.viewOnce,
        viewedBy: m.viewedBy || [],
        isVideoNote: extra.isVideoNote || m.isVideoNote,
        isEdited: extra.isEdited || m.isEdited || m.edited === true,
        editedAt: extra.editedAt || m.editedAt || m.edited_at,
        extra: extra.extra || m.extra,
    };
};

const decryptMessageContent = async (
    privateKey: string,
    encryptedContent: string,
    isFromMe: boolean,
    chatId: string = 'unknown_chat'
): Promise<string> => {
    try {
        const result = await decryptMessagesBatch({
            privateKey,
            items: [
                {
                    id: 'single',
                    encryptedContent,
                    isFromMe,
                },
            ],
        });
        return result.messages.single || '';
    } catch (e: any) {
        console.warn(`[ChatStore] decryptMessageContent failed for chat ${chatId}:`, e);
        return '';
    }
};

interface ChatState {
    chats: Chat[];
    isConnected: boolean;
    isLoading: boolean;
    activeChatId: string | null;
    typingUsers: Set<string>;
    recordingUsers: Set<string>;
    onlineUsers: Set<string>;
    offlineQueue: Message[]; // Queue for offline messages
    socket: PhxSocket | null;
    uploadProgress: Record<string, number>; // messageId -> 0..1 progress
    lastChatsLoad: number;

    // Actions
    disconnect: () => void;
    initSocket: () => void;
    loadChats: () => Promise<void>;
    startChat: (friendId: string, friendInfo?: { username?: string, profileImage?: string, publicKey?: string }) => Promise<string>; // Returns chatId
    sendMessage: (chatId: string, text: string, type?: Message['type'], metadata?: any, existingId?: string) => Promise<void>;
    editMessage: (chatId: string, messageId: string, text: string) => Promise<boolean>;

    setActiveChat: (id: string | null) => void;
    loadMessages: (chatId: string) => Promise<void>;
    updateMessageDecryption: (chatId: string, messageId: string, plaintext: string) => void;
    batchUpdateDecryption: (chatId: string, updates: Record<string, string>) => void;
    sendTyping: (chatId: string) => void;
    sendStopTyping: (chatId: string) => void;
    deleteChat: (chatId: string) => void;
    pinChat: (chatId: string) => void;
    toggleMuteChat: (chatId: string) => void;
    toggleMarkUnread: (chatId: string, forceStatus?: boolean) => void;
    updateChatFriendInfoByFriendId: (friendId: string, info: { friendName?: string; friendImage?: string }) => void;

    // Groups & Channels
    createGroup: (name: string, memberIds: string[]) => Promise<string | null>;
    createChannel: (name: string, description?: string) => Promise<string | null>;
    joinChannel: (channelId: string) => Promise<boolean>;
    leaveChannel: (channelId: string) => Promise<boolean>;
    sendRecording: (chatId: string) => void;
    sendStopRecording: (chatId: string) => void;
    sendReadReceipt: (chatId: string, messageId: string) => void;
    sendDeliveryReceipt: (chatId: string, messageId: string) => void;
    setUploadProgress: (messageId: string, progress: number) => void;
    clearUploadProgress: (messageId: string) => void;
    cancelUpload: (chatId: string, messageId: string) => void;
    markViewOnceViewed: (chatId: string, messageId: string) => void;
    retryMessage: (chatId: string, messageId: string) => Promise<void>;
    deleteFailedMessage: (chatId: string, messageId: string) => void;
}

// Module-level flag to ensure socket is only initialized once
let socketInitialized = false;

// Module-level socket and channel variables (not persisted)
let socket: PhxSocket | null = null;
let userChannel: Channel | null = null;
let chatChannels: Map<string, Channel> = new Map();
let loadChatsDebounceTimer: ReturnType<typeof setTimeout> | null = null;
let channelResyncTimer: ReturnType<typeof setTimeout> | null = null;
const pendingRetryFlushTimers = new Map<string, ReturnType<typeof setTimeout>>();
const pendingRetryPumpRunning = new Set<string>();
const pendingRetryPumpNeedsAnotherPass = new Set<string>();
// Dedup set to prevent processing the same message multiple times from concurrent broadcasts
const recentlyProcessedMsgIds = new Set<string>();
// AbortControllers for cancellable media uploads
const uploadAbortControllers = new Map<string, AbortController>();
// Dedup startChat calls per friendId to prevent duplicate chats on the backend
const startChatInFlight = new Map<string, Promise<string>>();
// Dedup public-key fetches per friend to avoid first-send stalls and duplicate requests
const friendKeyFetchInFlight = new Map<string, Promise<string | null>>();
const historyLoadInFlight = new Map<string, Promise<void>>();

const resolveAuthBearerToken = (session?: { loginToken?: string; userId?: string } | null): string | null => {
    if (session?.loginToken) return session.loginToken;
    if (session?.userId) return session.userId;

    try {
        const { useAuthStore } = require('./stores/auth-store');
        const user = useAuthStore.getState().user;
        if (user?.loginToken) return user.loginToken;
        if ((user as any)?.token) return (user as any).token;
        if (user?.userId) return user.userId;
    } catch {
        // noop - auth store may not be available in some runtime contexts
    }

    return null;
};

const buildAuthHeaders = (
    session?: { loginToken?: string; userId?: string } | null,
    base: Record<string, string> = {},
): Record<string, string> => {
    const token = resolveAuthBearerToken(session);
    if (!token) return base;
    return {
        ...base,
        Authorization: `Bearer ${token}`,
    };
};

const extractPublicKey = (data: any): string | null => {
    if (!data) return null;
    return data.publicKey || data.friendKey || data.friendPublicKey || data.public_key || null;
};

const isValidBinaryId = (value?: string | null): boolean => {
    if (!value || typeof value !== 'string') return false;
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
};

const isRetryableMessage = (message: Message, now = Date.now()): boolean => {
    if (message.status === 'error' && hasPermanentLocalMediaError(message)) return false;
    if (message.status === 'pending' || message.status === 'error') return true;
    if (message.status === 'sending') {
        const sentAt = typeof message.timestamp === 'number' ? message.timestamp : now;
        return now - sentAt > STALE_SENDING_RETRY_MS;
    }
    return false;
};

const isChatChannelWritable = (channel?: Channel | null): boolean => {
    if (!channel) return false;
    const state = (channel as any)?.state;
    return state === 'joined' || state === 'joining';
};

const waitForChatChannelReady = async (
    chatId: string,
    get: any,
    maxAttempts = 9,
    waitMs = 170,
): Promise<boolean> => {
    if (!socket?.isConnected()) return false;
    if (isChatChannelWritable(chatChannels.get(chatId))) return true;

    scheduleChannelResync(get, 120);
    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
        await sleep(waitMs);
        if (!socket?.isConnected()) return false;
        if (isChatChannelWritable(chatChannels.get(chatId))) return true;
    }
    return false;
};

const runChatRetryPump = async (chatId: string, get: any) => {
    if (pendingRetryPumpRunning.has(chatId)) {
        pendingRetryPumpNeedsAnotherPass.add(chatId);
        return;
    }

    pendingRetryPumpRunning.add(chatId);
    try {
        const initialState = get();
        const initialChat = initialState.chats.find((c: Chat) => c.chatId === chatId);
        if (!initialChat) return;

        const channelReady = await waitForChatChannelReady(chatId, get);
        if (!channelReady) {
            chatStoreMessageLog('retry:channel-not-ready', { chatId });
            scheduleChatRetryFlush(chatId, get, 1300);
            return;
        }

        const latestState = get();
        const chat = latestState.chats.find((c: Chat) => c.chatId === chatId);
        if (!chat) return;

        const now = Date.now();
        const toRetry = chat.messages
            .filter((m: Message) => isRetryableMessage(m, now))
            .sort((a: Message, b: Message) => (a.timestamp || 0) - (b.timestamp || 0));

        if (toRetry.length === 0) return;

        chatStoreLog('[ChatStore] Retry flush (sequential):', chatId, toRetry.length);
        for (const message of toRetry) {
            const latestChat = get().chats.find((c: Chat) => c.chatId === chatId);
            const latestMessage = latestChat?.messages.find((m: Message) => m.id === message.id);
            if (!latestMessage || !isRetryableMessage(latestMessage)) continue;

            await get().retryMessage(chatId, message.id);
            await sleep(RETRY_DISPATCH_GAP_MS);
        }
    } finally {
        pendingRetryPumpRunning.delete(chatId);
        if (pendingRetryPumpNeedsAnotherPass.delete(chatId)) {
            scheduleChatRetryFlush(chatId, get, RETRY_DISPATCH_GAP_MS);
        }
    }
};

const scheduleChatRetryFlush = (chatId: string, get: any, delayMs = 900) => {
    if (pendingRetryPumpRunning.has(chatId)) {
        pendingRetryPumpNeedsAnotherPass.add(chatId);
        return;
    }

    const existing = pendingRetryFlushTimers.get(chatId);
    if (existing) {
        clearTimeout(existing);
    }

    const timer = setTimeout(() => {
        pendingRetryFlushTimers.delete(chatId);
        void runChatRetryPump(chatId, get);
    }, delayMs);

    pendingRetryFlushTimers.set(chatId, timer);
};

const scheduleChannelResync = (get: any, delayMs = 220) => {
    if (channelResyncTimer) return;
    channelResyncTimer = setTimeout(() => {
        channelResyncTimer = null;
        Promise.resolve(get().loadChats()).catch(() => { });
    }, delayMs);
};

const tryOpenDirectChatChannel = async (chatId: string): Promise<Channel | null> => {
    const existing = chatChannels.get(chatId);
    if (existing) return existing;

    const activeSocket = socket;
    if (!activeSocket || !activeSocket.isConnected()) return null;

    let directChannel: Channel | null = null;
    try {
        directChannel = activeSocket.channel(`chat:${chatId}`, {});
        const joined = await new Promise<boolean>((resolve) => {
            let settled = false;
            let timeout: ReturnType<typeof setTimeout> | null = null;
            const settle = (value: boolean) => {
                if (settled) return;
                settled = true;
                if (timeout) {
                    clearTimeout(timeout);
                    timeout = null;
                }
                resolve(value);
            };
            directChannel!
                .join()
                .receive("ok", () => settle(true))
                .receive("error", () => settle(false))
                .receive("timeout", () => settle(false));
            timeout = setTimeout(() => settle(false), 1400);
        });
        if (!joined) {
            try { directChannel.leave(); } catch { /* ignore */ }
            return null;
        }
        return directChannel;
    } catch {
        try { directChannel?.leave(); } catch { /* ignore */ }
        return null;
    }
};

const removeMessageFromChatList = (chats: Chat[], chatId: string, messageId: string): Chat[] => {
    const idx = chats.findIndex(c => c.chatId === chatId);
    if (idx === -1) return chats;

    const chat = chats[idx];
    if (!chat.messages.some(m => m.id === messageId)) return chats;

    const nextMessages = chat.messages.filter(m => m.id !== messageId);
    const nextLast = nextMessages.length > 0 ? nextMessages[nextMessages.length - 1] : undefined;
    const nextChats = [...chats];
    nextChats[idx] = {
        ...chat,
        messages: nextMessages,
        lastMessage: nextLast,
    };
    return nextChats;
};

const applyReadUpToMessageInChat = (
    chats: Chat[],
    chatId: string,
    messageId: string,
    myUserId?: string | null
): Chat[] => {
    const chatIdx = chats.findIndex(c => c.chatId === chatId);
    if (chatIdx === -1) return chats;

    const currentChat = chats[chatIdx];
    const targetIdx = currentChat.messages.findIndex(m => m.id === messageId);
    if (targetIdx === -1) return chats;

    const targetTs = currentChat.messages[targetIdx]?.timestamp || 0;
    const myId = (myUserId || '').toUpperCase();
    let changed = false;

    const nextMessages = currentChat.messages.map((m) => {
        const fromMe = myId && (m.fromId || '').toUpperCase() === myId;
        if (!fromMe) return m;
        if ((m.timestamp || 0) > targetTs) return m;

        const status = m.status;
        if (status === 'read') return m;
        if (status === 'error') return m;
        if (
            status === 'sent' ||
            status === 'delivered' ||
            status === 'sending' ||
            status === 'pending' ||
            status === undefined
        ) {
            changed = true;
            return { ...m, status: 'read' as const };
        }
        return m;
    });

    if (!changed) return chats;

    const nextChats = [...chats];
    nextChats[chatIdx] = {
        ...currentChat,
        messages: nextMessages,
        lastMessage: currentChat.lastMessage
            ? (nextMessages.find((m) => m.id === currentChat.lastMessage?.id) || currentChat.lastMessage)
            : currentChat.lastMessage,
    };
    return nextChats;
};

const statusRank = (status?: Message['status']): number => {
    switch (status) {
        case 'read':
            return 5;
        case 'delivered':
            return 4;
        case 'sent':
            return 3;
        case 'sending':
            return 2;
        case 'pending':
            return 1;
        case 'error':
        default:
            return 0;
    }
};

const chooseMostAdvancedStatus = (
    localStatus?: Message['status'],
    serverStatus?: Message['status']
): Message['status'] => {
    return statusRank(serverStatus) > statusRank(localStatus)
        ? (serverStatus || 'sent')
        : (localStatus || serverStatus || 'sent');
};

const isPendingLikeStatus = (status?: Message['status']) => (
    status === 'sending' || status === 'pending' || status === 'error'
);

const normalizeComparableText = (value?: string | null) => (
    typeof value === 'string' ? value.trim() : ''
);

const doesOutgoingPayloadMatchMessage = (
    existing: Message,
    text: string,
    type: Message['type'],
    metadata: any,
): boolean => {
    if (existing.type !== type) {
        return false;
    }

    const sameReply = (existing.replyToId || '') === (metadata?.replyToId || '');
    if (!sameReply) {
        return false;
    }

    if (type === 'text') {
        return normalizeComparableText(existing.plaintext) === normalizeComparableText(text);
    }

    const sameText = normalizeComparableText(existing.plaintext) === normalizeComparableText(text);
    const existingMedia = typeof existing.mediaUrl === 'string' ? existing.mediaUrl : '';
    const metadataMedia = typeof metadata?.mediaUrl === 'string' ? metadata.mediaUrl : '';
    const sameMedia = !existingMedia || !metadataMedia || existingMedia === metadataMedia;
    const sameFileName =
        !existing.fileName || !metadata?.fileName || existing.fileName === metadata.fileName;
    const existingDuration = typeof existing.duration === 'number' ? existing.duration : null;
    const metadataDuration = typeof metadata?.duration === 'number' ? metadata.duration : null;
    const sameDuration =
        existingDuration == null || metadataDuration == null
            ? true
            : Math.abs(existingDuration - metadataDuration) <= 0.35;

    return sameText && sameMedia && sameFileName && sameDuration;
};

const messageTimestamp = (message?: Message | null) => (
    typeof message?.timestamp === 'number' ? message.timestamp : 0
);

const isMessageFromUser = (message: Message, myUserId?: string | null) => (
    !!myUserId && (message.fromId || '').toUpperCase() === myUserId.toUpperCase()
);

const isLikelyOutgoingDuplicate = (
    existing: Message,
    incoming: Message,
    myUserId?: string | null,
): boolean => {
    if (!isMessageFromUser(existing, myUserId) || !isMessageFromUser(incoming, myUserId)) {
        return false;
    }
    if (!isPendingLikeStatus(existing.status)) {
        return false;
    }
    if (existing.type !== incoming.type) {
        return false;
    }

    const timeDelta = Math.abs(messageTimestamp(existing) - messageTimestamp(incoming));
    if (timeDelta > 5 * 60 * 1000) {
        return false;
    }

    if (existing.encryptedContent && incoming.encryptedContent && existing.encryptedContent === incoming.encryptedContent) {
        return true;
    }

    if (incoming.type === 'text') {
        const localText = normalizeComparableText(existing.plaintext);
        const incomingText = normalizeComparableText(incoming.plaintext);
        if (!localText || !incomingText) return false;
        return localText === incomingText && (existing.replyToId || '') === (incoming.replyToId || '');
    }

    if (existing.mediaUrl && incoming.mediaUrl && existing.mediaUrl === incoming.mediaUrl) {
        return true;
    }
    if (existing.fileName && incoming.fileName && existing.fileName === incoming.fileName) {
        const existingDuration = Number(existing.duration || 0);
        const incomingDuration = Number(incoming.duration || 0);
        return Math.abs(existingDuration - incomingDuration) <= 1.0;
    }
    if ((incoming.type === 'voice' || incoming.type === 'music' || incoming.type === 'video') && existing.duration && incoming.duration) {
        return Math.abs(existing.duration - incoming.duration) <= 0.35;
    }

    return false;
};

const mergeIncomingWithExistingMessage = (
    existing: Message,
    incoming: Message,
    myUserId?: string | null,
    outgoingReconcile = false,
): Message => {
    const incomingFromMe = isMessageFromUser(incoming, myUserId);
    const fallbackIncomingStatus: Message['status'] =
        incoming.status || (incomingFromMe ? 'sent' : 'delivered');
    const mergedStatus = chooseMostAdvancedStatus(existing.status, fallbackIncomingStatus);

    return {
        ...existing,
        ...incoming,
        id: incoming.id || existing.id,
        encryptedContent: incoming.encryptedContent || existing.encryptedContent || '',
        timestamp: outgoingReconcile
            ? (messageTimestamp(existing) || messageTimestamp(incoming) || Date.now())
            : (messageTimestamp(incoming) || messageTimestamp(existing) || Date.now()),
        status: mergedStatus,
        plaintext: incoming.plaintext ?? existing.plaintext,
        mediaUrl: incoming.mediaUrl ?? existing.mediaUrl,
        fileName: incoming.fileName ?? existing.fileName,
        fileSize: incoming.fileSize ?? existing.fileSize,
        latitude: incoming.latitude ?? existing.latitude,
        longitude: incoming.longitude ?? existing.longitude,
        duration: incoming.duration ?? existing.duration,
        replyToId: incoming.replyToId ?? existing.replyToId,
        contact: incoming.contact ?? existing.contact,
        caption: incoming.caption ?? existing.caption,
        viewOnce: incoming.viewOnce ?? existing.viewOnce,
        viewedBy: incoming.viewedBy ?? existing.viewedBy,
        isVideoNote: incoming.isVideoNote ?? existing.isVideoNote,
        mediaKey: incoming.mediaKey ?? existing.mediaKey,
        isEdited: incoming.isEdited ?? existing.isEdited,
        editedAt: incoming.editedAt ?? existing.editedAt,
        errorMessage: mergedStatus === 'error'
            ? (incoming.errorMessage || existing.errorMessage)
            : undefined,
        extra: {
            ...(existing.extra || {}),
            ...(incoming.extra || {}),
        },
    };
};

const upsertIncomingMessage = (
    messages: Message[],
    incoming: Message,
    myUserId?: string | null,
): {
    messages: Message[];
    inserted: boolean;
    changed: boolean;
    reconciledFromMessageId?: string;
} => {
    const exactIndex = messages.findIndex((m) => m.id === incoming.id);
    if (exactIndex >= 0) {
        const merged = mergeIncomingWithExistingMessage(messages[exactIndex], incoming, myUserId);
        const shouldPrunePendingTwin =
            isMessageFromUser(merged, myUserId) && !isPendingLikeStatus(merged.status);
        const nextMessages = messages
            .map((m, idx) => (idx === exactIndex ? merged : m))
            .filter((m, idx) => {
                if (idx === exactIndex) return true;
                if (m.id === incoming.id) return false;
                if (shouldPrunePendingTwin && isLikelyOutgoingDuplicate(m, merged, myUserId)) {
                    return false;
                }
                return true;
            });
        const removedCount = messages.length - nextMessages.length;
        chatStoreMessageLog('upsert:exact', {
            messageId: incoming.id,
            status: merged.status,
            removedCount,
            countBefore: messages.length,
            countAfter: nextMessages.length,
        });
        return {
            messages: nextMessages,
            inserted: false,
            changed: true,
        };
    }

    let reconcileIndex = -1;
    let reconcileScore = Number.POSITIVE_INFINITY;
    for (let i = 0; i < messages.length; i++) {
        const candidate = messages[i];
        if (!isLikelyOutgoingDuplicate(candidate, incoming, myUserId)) continue;
        const score = Math.abs(messageTimestamp(candidate) - messageTimestamp(incoming));
        if (score < reconcileScore) {
            reconcileScore = score;
            reconcileIndex = i;
        }
    }

    if (reconcileIndex >= 0) {
        const existing = messages[reconcileIndex];
        const merged = mergeIncomingWithExistingMessage(existing, incoming, myUserId, true);
        const shouldPrunePendingTwin =
            isMessageFromUser(merged, myUserId) && !isPendingLikeStatus(merged.status);
        const nextMessages = messages
            .map((m, idx) => (idx === reconcileIndex ? merged : m))
            .filter((m, idx) => {
                if (idx === reconcileIndex) return true;
                if (m.id === incoming.id) return false;
                if (shouldPrunePendingTwin && isLikelyOutgoingDuplicate(m, merged, myUserId)) {
                    return false;
                }
                return true;
            });
        const removedCount = messages.length - nextMessages.length;
        chatStoreMessageLog('upsert:reconcile', {
            fromMessageId: existing.id,
            toMessageId: incoming.id,
            type: incoming.type,
            status: merged.status,
            removedCount,
            countBefore: messages.length,
            countAfter: nextMessages.length,
        });
        return {
            messages: nextMessages,
            inserted: false,
            changed: true,
            reconciledFromMessageId: existing.id,
        };
    }

    chatStoreMessageLog('upsert:insert', {
        messageId: incoming.id,
        type: incoming.type,
        status: incoming.status,
        countBefore: messages.length,
        countAfter: messages.length + 1,
    });
    return {
        messages: [...messages, incoming],
        inserted: true,
        changed: true,
    };
};

const pruneOfflineQueue = (
    offlineQueue: Message[],
    ...messageIds: Array<string | undefined>
): Message[] => {
    const targets = new Set(messageIds.filter((id): id is string => typeof id === 'string' && id.length > 0));
    if (targets.size === 0) return offlineQueue;
    const nextQueue = offlineQueue.filter((message) => !targets.has(message.id));
    return nextQueue.length === offlineQueue.length ? offlineQueue : nextQueue;
};

const applyMessageEditedInChats = (
    chats: Chat[],
    chatId: string,
    messageId: string,
    patch: Partial<Message>
): Chat[] => {
    const chatIdx = chats.findIndex(c => c.chatId === chatId);
    if (chatIdx === -1) return chats;
    const msgIdx = chats[chatIdx].messages.findIndex(m => m.id === messageId);
    if (msgIdx === -1) return chats;

    const nextChats = [...chats];
    const nextMessages = [...nextChats[chatIdx].messages];
    const current = nextMessages[msgIdx];
    nextMessages[msgIdx] = {
        ...current,
        ...patch,
        extra: {
            ...(current.extra || {}),
            ...(patch.extra || {}),
        },
    };
    nextChats[chatIdx] = {
        ...nextChats[chatIdx],
        messages: nextMessages,
        lastMessage: nextChats[chatIdx].lastMessage?.id === messageId
            ? nextMessages[msgIdx]
            : nextChats[chatIdx].lastMessage,
    };
    return nextChats;
};

const handleMessageEditedPayload = async (
    chatId: string,
    payload: any,
    set: any,
    get: any,
) => {
    const messageId = payload?.messageId || payload?.message_id;
    const encryptedContent = payload?.encryptedContent || payload?.encrypted_content;
    if (!messageId || !encryptedContent) return;

    const editedAtRaw = payload?.editedAt || payload?.edited_at;
    const editedAt = typeof editedAtRaw === 'number' ? editedAtRaw : Date.now();

    const currentChats = get().chats as Chat[];
    const chat = currentChats.find(c => c.chatId === chatId);
    const existingMsg = chat?.messages.find(m => m.id === messageId);

    let parsedPatch: Partial<Message> = {};
    const auth = AuthManager.getInstance().getSession();
    if (auth?.keyPair?.privateKey && existingMsg) {
        try {
            const isFromMe = (existingMsg.fromId || '').toUpperCase() === (auth.userId || '').toUpperCase();
            const decrypted = await decryptMessageContent(auth.keyPair.privateKey, encryptedContent, isFromMe, chatId);
            if (decrypted) {
                parsedPatch = parseDecryptedContent(decrypted);
            }
        } catch (e) {
            console.warn('[ChatStore] Realtime edit decrypt failed', e);
        }
    }

    const nextChats = applyMessageEditedInChats(currentChats, chatId, messageId, {
        ...parsedPatch,
        encryptedContent,
        isEdited: true,
        editedAt,
        extra: {
            ...(parsedPatch.extra || {}),
            isEdited: true,
            editedAt,
        },
    });

    if (nextChats !== currentChats) {
        set({ chats: nextChats });
    }
};

const warmFriendPublicKey = async (
    chatId: string,
    friendId: string,
    set: any,
    get: any
): Promise<string | null> => {
    const normalizedFriendId = (friendId || '').toUpperCase();
    if (!normalizedFriendId) return null;

    // Use cached key first.
    const existingChat = get().chats.find((c: any) => c.chatId === chatId || (c.friendId || '').toUpperCase() === normalizedFriendId);
    const cached = extractPublicKey(existingChat);
    if (cached) return cached;

    const inFlight = friendKeyFetchInFlight.get(normalizedFriendId);
    if (inFlight) return inFlight;

    const promise = (async () => {
        const proxy = ProxyManager.getInstance();
        const baseUrl = proxy.getBestUrl();
        const auth = AuthManager.getInstance().getSession();
        try {
            const res = await fetch(`${baseUrl}/api/user/${friendId}`, {
                headers: {
                    'ngrok-skip-browser-warning': 'true',
                    ...buildAuthHeaders(auth),
                }
            });
            if (!res.ok) return null;

            const userData = await res.json();
            const key = extractPublicKey(userData);
            if (!key) return null;

            // Persist key into all chats for this friend so first reply is instant as well.
            const { chats } = get();
            let changed = false;
            const updated = chats.map((c: any) => {
                if ((c.friendId || '').toUpperCase() !== normalizedFriendId) return c;
                if (c.friendKey) return c;
                changed = true;
                return { ...c, friendKey: key };
            });
            if (changed) set({ chats: updated });

            return key;
        } catch (e) {
            console.warn('[ChatStore] Failed to warm friend key:', e);
            return null;
        } finally {
            friendKeyFetchInFlight.delete(normalizedFriendId);
        }
    })();

    friendKeyFetchInFlight.set(normalizedFriendId, promise);
    return promise;
};

// Export a getter so relay/other modules can access the live Phoenix socket
export const getPhoenixSocket = (): PhxSocket | null => socket;

// Export a getter for the joined user channel (used by call signaling)
export const getUserChannel = (): Channel | null => userChannel;

let nativeChatEngineModuleCache: any | null | undefined;
const getNativeChatEngineShadowModule = (): any | null => {
    if (nativeChatEngineModuleCache !== undefined) return nativeChatEngineModuleCache;
    try {
        // Lazy require avoids startup/circular dependency issues for non-native paths.
        const runtime = require('../native/chat/runtime');
        nativeChatEngineModuleCache = runtime?.getNativeChatEngineModule?.() ?? null;
    } catch {
        nativeChatEngineModuleCache = null;
    }
    return nativeChatEngineModuleCache;
};

const fireAndForgetChatEngineShadowCall = (
    methodName:
        | 'setChatEngineConfig'
        | 'connectChatEngine'
        | 'disconnectChatEngine'
        | 'sendEncryptedMessage'
        | 'sendDeliveryReceipt'
        | 'sendReadReceipt',
    payload?: Record<string, unknown>,
) => {
    try {
        const nativeChatEngine = getNativeChatEngineShadowModule();
        const method = nativeChatEngine?.[methodName];
        if (typeof method !== 'function') return;
        const result = payload === undefined ? method() : method(payload);
        void Promise.resolve(result).catch((error) => {
            chatStoreLog(`[ChatStore] ChatEngine shadow ${methodName} failed`, error);
        });
    } catch (error) {
        chatStoreLog(`[ChatStore] ChatEngine shadow ${methodName} unavailable`, error);
    }
};

const mirrorChatEngineDeliveryReceiptPush = (chatId: string, messageId: string) => {
    if (!chatId || !messageId) return;
    fireAndForgetChatEngineShadowCall('sendDeliveryReceipt', { chatId, messageId });
};

const mirrorChatEngineReadReceiptPush = (chatId: string, messageId: string) => {
    if (!chatId || !messageId) return;
    fireAndForgetChatEngineShadowCall('sendReadReceipt', { chatId, messageId });
};

const tryNativeChatEngineSendEncryptedMessage = async (
    chatId: string,
    messageId: string,
    messagePayload: Record<string, unknown>,
): Promise<boolean> => {
    try {
        const nativeChatEngine = getNativeChatEngineShadowModule();
        const method = nativeChatEngine?.sendEncryptedMessage;
        if (typeof method !== 'function') return false;
        const result = await Promise.resolve(method({
            chatId,
            messageId,
            message: messagePayload,
        }));
        return !!(result as any)?.accepted;
    } catch (error) {
        chatStoreLog('[ChatStore] ChatEngine native sendEncryptedMessage failed', error);
        return false;
    }
};

const tryNativeChatEngineEditMessage = async (
    chatId: string,
    messageId: string,
    encryptedContent: string,
    editedAt: number,
): Promise<boolean> => {
    try {
        const nativeChatEngine = getNativeChatEngineShadowModule();
        const method = nativeChatEngine?.sendEditMessage;
        if (typeof method !== 'function') return false;
        const result = await Promise.resolve(method({
            chatId,
            messageId,
            encryptedContent,
            editedAt,
        }));
        return !!(result as any)?.accepted;
    } catch (error) {
        chatStoreLog('[ChatStore] ChatEngine native sendEditMessage failed', error);
        return false;
    }
};

const tryNativeChatEngineReceiptPush = async (
    methodName: 'sendDeliveryReceipt' | 'sendReadReceipt',
    chatId: string,
    messageId: string,
): Promise<boolean> => {
    try {
        const nativeChatEngine = getNativeChatEngineShadowModule();
        const method = nativeChatEngine?.[methodName];
        if (typeof method !== 'function') return false;
        const result = await Promise.resolve(method({ chatId, messageId }));
        return !!(result as any)?.accepted;
    } catch (error) {
        chatStoreLog(`[ChatStore] ChatEngine native ${methodName} failed`, error);
        return false;
    }
};

const configureChatEngineShadowTransport = (apiBaseUrl: string, socketUrl: string, auth: any) => {
    if (!socketUrl || !auth?.userId) return;
    const jsFallbackEnv = process.env.EXPO_PUBLIC_CHAT_NATIVE_JS_FALLBACK;
    const chatNativeJsFallbackEnabled = jsFallbackEnv === '1' || jsFallbackEnv === 'true';
    fireAndForgetChatEngineShadowCall('setChatEngineConfig', {
        apiBaseUrl,
        socketUrl,
        authToken: auth.loginToken || auth.userId,
        userId: auth.userId,
        userChannelTopic: `user:${auth.userId}`,
        privateKeyPem: auth?.keyPair?.privateKey,
        publicKeyPem: auth?.keyPair?.publicKey,
        chatNativeJsFallbackEnabled,
    });
};

const connectChatEngineShadowTransport = () => {
    fireAndForgetChatEngineShadowCall('connectChatEngine');
};

const disconnectChatEngineShadowTransport = () => {
    fireAndForgetChatEngineShadowCall('disconnectChatEngine');
};

// Export a function to reset socket (for development/hot-reload issues)
export const resetSocketConnection = () => {


    // Leave all chat channels
    chatChannels.forEach((channel, chatId) => {
        try {
            channel.leave();
        } catch (e) {
            console.warn('[ChatStore] Error leaving channel:', chatId, e);
        }
    });
    chatChannels.clear();

    // Leave user channel
    if (userChannel) {
        try {
            userChannel.leave();
        } catch (e) {
            console.warn('[ChatStore] Error leaving user channel:', e);
        }
        userChannel = null;
    }

    // Disconnect socket
    if (socket) {
        try {
            socket.disconnect();
        } catch (e) {
            console.warn('[ChatStore] Error disconnecting socket:', e);
        }
        socket = null;
    }

    if (loadChatsDebounceTimer) {
        clearTimeout(loadChatsDebounceTimer);
        loadChatsDebounceTimer = null;
    }
    if (channelResyncTimer) {
        clearTimeout(channelResyncTimer);
        channelResyncTimer = null;
    }
    pendingRetryFlushTimers.forEach((timer) => clearTimeout(timer));
    pendingRetryFlushTimers.clear();
    pendingRetryPumpRunning.clear();
    pendingRetryPumpNeedsAnotherPass.clear();

    // Reset flag so socket can be re-initialized
    socketInitialized = false;
    disconnectChatEngineShadowTransport();


};

export const useChatStore = create<ChatState>()(
    persist(
        (set, get) => ({
            chats: [],
            isConnected: false,
            isLoading: false,
            activeChatId: null,
            typingUsers: new Set(),
            recordingUsers: new Set(),
            onlineUsers: new Set(),
            offlineQueue: [],
            socket: null,
            uploadProgress: {},
            lastChatsLoad: 0,

            disconnect: () => {
                resetSocketConnection();
                set({ isConnected: false, socket: null });
            },

            initSocket: () => {
                // Module-level singleton check - prevents any re-initialization
                if (socketInitialized) {

                    return;
                }
                socketInitialized = true;

                const proxy = ProxyManager.getInstance();
                const baseUrl = proxy.getBestUrl();
                // Convert http(s) to ws(s)
                const socketUrl = baseUrl.replace(/^http/, 'ws') + '/socket';

                const auth = AuthManager.getInstance().getSession();
                if (!auth) {

                    socketInitialized = false; // Reset so it can try again later
                    return;
                }

                configureChatEngineShadowTransport(baseUrl, socketUrl, auth);



                socket = new PhxSocket(socketUrl, {
                    params: { token: auth.loginToken || auth.userId },
                    // Disable automatic reconnection to prevent spam when server is unavailable
                    reconnectAfterMs: () => 10000, // Wait 10 seconds between reconnect attempts
                });

                socket.connect();
                set({ socket }); // Update store state with socket instance

                const scheduleLoadChats = (delayMs = 180) => {
                    if (loadChatsDebounceTimer) return;
                    loadChatsDebounceTimer = setTimeout(() => {
                        loadChatsDebounceTimer = null;
                        get().loadChats();
                    }, delayMs);
                };

                const queueRecoverableMessages = () => {
                    const { chats: currentChats, offlineQueue } = get();
                    const recovered: Message[] = [];
                    let chatsChanged = false;

                    const updatedChats = currentChats.map((chat) => {
                        let changed = false;
                        const nextMessages = chat.messages.map((msg) => {
                            if (msg.status === 'sending') {
                                changed = true;
                                chatsChanged = true;
                                const pendingMsg = { ...msg, status: 'pending' as const };
                                recovered.push(pendingMsg);
                                return pendingMsg;
                            }
                            if (msg.status === 'pending' || msg.status === 'error') {
                                recovered.push(msg);
                            }
                            return msg;
                        });
                        return changed ? { ...chat, messages: nextMessages } : chat;
                    });

                    const queueMap = new Map<string, Message>();
                    for (const msg of offlineQueue) queueMap.set(msg.id, msg);
                    for (const msg of recovered) queueMap.set(msg.id, msg);

                    const nextQueue = Array.from(queueMap.values());
                    const queueChanged =
                        nextQueue.length !== offlineQueue.length ||
                        nextQueue.some((msg, index) => offlineQueue[index]?.id !== msg.id);

                    const patch: Partial<ChatState> = {};
                    if (chatsChanged) patch.chats = updatedChats;
                    if (queueChanged) patch.offlineQueue = nextQueue;
                    if (Object.keys(patch).length > 0) set(patch as any);
                };

                socket.onOpen(() => {
                    connectChatEngineShadowTransport();

                    set({ isConnected: true });

                    // Re-sync push token on every reconnect so server always has it
                    try {
                        const { useNotificationStore } = require('./stores/notification-store');
                        useNotificationStore.getState().initNotifications({
                            forceSync: true,
                            reason: 'socket_open',
                        });
                    } catch (e) { /* ignore if notification store not ready */ }

                    // Process Offline Queue — also recover any unsent messages stuck in chats
                    const { offlineQueue, chats: currentChats } = get();
                    const pendingMessages: Message[] = [];
                    for (const chat of currentChats) {
                        for (const msg of chat.messages) {
                            if (msg.status === 'pending' || msg.status === 'error' || msg.status === 'sending') {
                                pendingMessages.push(msg);
                            }
                        }
                    }

                    // Combine offline queue + stuck pending/error messages (dedup by id)
                    const seenIds = new Set<string>();
                    const toRetry: Message[] = [];
                    for (const msg of [...offlineQueue, ...pendingMessages]) {
                        if (!isRetryableMessage(msg)) continue;
                        if (msg.id && !seenIds.has(msg.id)) {
                            seenIds.add(msg.id);
                            toRetry.push(msg);
                        }
                    }

                    const nextQueueMap = new Map<string, Message>();
                    toRetry.forEach((msg) => nextQueueMap.set(msg.id, msg));
                    set({ offlineQueue: Array.from(nextQueueMap.values()) });

                    if (toRetry.length > 0) {
                        const retryChatIds = Array.from(
                            new Set(
                                toRetry
                                    .map((msg) => msg.chatId)
                                    .filter((chatId): chatId is string => typeof chatId === 'string' && chatId.length > 0),
                            ),
                        );

                        chatStoreLog('[ChatStore] Retrying pending messages by chat', {
                            messages: toRetry.length,
                            chats: retryChatIds.length,
                        });

                        retryChatIds.forEach((retryChatId, index) => {
                            // Stagger each chat pump to avoid reconnect burst.
                            scheduleChatRetryFlush(retryChatId, get, 1200 + (index * 180));
                        });
                    }

                    // IMPORTANT: Clear all channel references on reconnect
                    // This ensures we re-join with fresh handlers
                    chatChannels.forEach((channel) => {
                        try { channel.leave(); } catch (e) { /* ignore */ }
                    });
                    chatChannels.clear();


                    // Re-join chat channels on every reconnect.
                    // We clear channel refs above, so skipping this leaves retry queue without writable channels.
                    scheduleLoadChats(100);

                    // Join User Channel for signaling/status.
                    // Recreate it on reconnect if an old instance is stuck in a non-joined state.
                    const userChannelState = (userChannel as any)?.state;
                    const needsUserChannelJoin =
                        !userChannel ||
                        (userChannelState !== 'joined' && userChannelState !== 'joining');

                    if (needsUserChannelJoin) {
                        if (userChannel) {
                            try { userChannel.leave(); } catch (e) { /* ignore */ }
                            userChannel = null;
                        }

                        userChannel = socket!.channel(`user:${auth.userId}`, {});
                        userChannel.join()
                            .receive("ok", resp => {
                                // Do not play call intro sound on normal app/socket connect.
                            })
                            .receive("error", resp => { });

                        userChannel.on('initial-presence', (resp: any) => {
                            const userIds = resp.onlineFriendIds || [];
                            set({ onlineUsers: new Set(userIds.map((id: string) => id.toUpperCase())) });
                        });

                        // Listen for presence changes (user came online/offline)
                        userChannel.on('presence-diff', (resp: any) => {
                            const { onlineUsers } = get();
                            const newSet = new Set(onlineUsers);

                            // Phoenix Presence format: { joins: { "userId": {...} }, leaves: { "userId": {...} } }
                            // Add users who came online
                            if (resp.joins && typeof resp.joins === 'object') {
                                Object.keys(resp.joins).forEach((id: string) => newSet.add(id.toUpperCase()));
                            }
                            // Remove users who went offline
                            if (resp.leaves && typeof resp.leaves === 'object') {
                                Object.keys(resp.leaves).forEach((id: string) => newSet.delete(id.toUpperCase()));
                            }

                            set({ onlineUsers: newSet });
                        });

                        // Also listen for friend-online and friend-offline events
                        userChannel.on('friend-online', (resp: any) => {
                            const { onlineUsers } = get();
                            // robust check for keys
                            const rawId = resp.userId || resp.user_id || resp.id;
                            const userId = (rawId || '').toUpperCase();

                            if (userId) {
                                const newSet = new Set(onlineUsers);
                                newSet.add(userId);
                                set({ onlineUsers: newSet });
                            }
                        });

                        userChannel.on('friend-offline', (resp: any) => {
                            const { onlineUsers } = get();
                            // robust check for keys
                            const rawId = resp.userId || resp.user_id || resp.id;
                            const userId = (rawId || '').toUpperCase();

                            if (userId) {
                                const newSet = new Set(onlineUsers);
                                newSet.delete(userId);
                                set({ onlineUsers: newSet });
                            }
                        });

                        // Phoenix Presence state (initial list of online users)
                        userChannel.on('presence_state', (state: any) => {
                            const userIds = Object.keys(state).map(id => id.toUpperCase());
                            set({ onlineUsers: new Set(userIds) });
                        });

                        // Phoenix Presence diff (users joining/leaving)
                        userChannel.on('presence_diff', (diff: any) => {
                            const { onlineUsers } = get();
                            const newSet = new Set(onlineUsers);

                            // Add users who came online
                            Object.keys(diff.joins || {}).forEach(id => newSet.add(id.toUpperCase()));
                            // Remove users who went offline
                            Object.keys(diff.leaves || {}).forEach(id => newSet.delete(id.toUpperCase()));

                            set({ onlineUsers: newSet });
                        });

                        // Listen for new chat creation (e.g., first message from a new contact)
                        userChannel.on('new_chat', (payload: any) => {

                            // Reload chats to get the new chat
                            scheduleLoadChats(250);
                        });

                        // Listen for new message notification (for chats we might not have yet or deleted)
                        userChannel.on('new_message', (payload: any) => {
                            chatStoreLog('[ChatStore] user:new_message received', payload);
                            const msgId = payload.message_id || payload.messageId;
                            if (msgId && recentlyProcessedMsgIds.has(msgId)) return;

                            const { chats } = get();
                            const chatId = payload.chatId || payload.chat_id;

                            // Check if we have this chat and are subscribed to its channel
                            const existingChat = chats.find(c => c.chatId === chatId);
                            const isSubscribed = chatChannels.has(chatId);

                            if (!existingChat || !isSubscribed) {
                                // Chat doesn't exist in our list OR we're not subscribed
                                // This happens when:
                                // 1. New chat we never had
                                // 2. Chat we deleted (but someone messaged us)

                                scheduleLoadChats(250);
                            }
                        });

                        // ==============================================
                        // CALL SIGNALING HANDLERS
                        // ==============================================

                        // Handle incoming call request
                        userChannel.on('call-start', (payload: any) => {
                            try {
                                const { useAuthStore } = require('./stores/auth-store');
                                const selfUserId = (useAuthStore.getState().user?.userId || '').trim().toUpperCase();
                                const fromUserIdRaw =
                                    (typeof payload?.fromUserId === 'string' ? payload.fromUserId : '') ||
                                    (typeof payload?.from_user_id === 'string' ? payload.from_user_id : '');
                                const toUserIdRaw =
                                    (typeof payload?.toUserId === 'string' ? payload.toUserId : '') ||
                                    (typeof payload?.to_user_id === 'string' ? payload.to_user_id : '');
                                const callIdRaw =
                                    (typeof payload?.callId === 'string' ? payload.callId : '') ||
                                    (typeof payload?.call_id === 'string' ? payload.call_id : '');
                                const fromUserIdUpper = fromUserIdRaw.trim().toUpperCase();
                                const toUserIdUpper = toUserIdRaw.trim().toUpperCase();

                                if (selfUserId && fromUserIdUpper && selfUserId === fromUserIdUpper) {
                                    console.log('[ChatStore][CallDebug] ignore call-start self-originated', {
                                        callId: callIdRaw || undefined,
                                        fromUserId: fromUserIdRaw || undefined,
                                        toUserId: toUserIdRaw || undefined,
                                    });
                                    return;
                                }
                                if (selfUserId && toUserIdUpper && selfUserId !== toUserIdUpper) {
                                    console.log('[ChatStore][CallDebug] ignore call-start not-for-self', {
                                        callId: callIdRaw || undefined,
                                        fromUserId: fromUserIdRaw || undefined,
                                        toUserId: toUserIdRaw || undefined,
                                        selfUserId: selfUserId.slice(0, 8),
                                    });
                                    return;
                                }

                                const explicitCallType =
                                    (typeof payload?.callType === 'string' ? payload.callType : '') ||
                                    (typeof payload?.call_type === 'string' ? payload.call_type : '') ||
                                    ((typeof payload?.type === 'string' && payload.type.toLowerCase() === 'video') ? 'video' : 'voice');
                                if (!payload?.callType) payload.callType = explicitCallType;
                                if (!payload?.call_type) payload.call_type = explicitCallType;

                                // Dynamic import to avoid crashes if CallStore fails to load
                                const { useCallStore } = require('./stores/CallStore');
                                const callStore = useCallStore.getState();
                                console.log('[ChatStore][CallDebug] call-start received', {
                                    callId: callIdRaw || undefined,
                                    fromUserId: fromUserIdRaw || undefined,
                                    toUserId: toUserIdRaw || undefined,
                                    type: payload?.callType || payload?.call_type,
                                    rawType: payload?.type,
                                    rawEvent: payload?.event,
                                });
                                const handled = callStore.handleIncomingCallPayload(payload);
                                if (!handled) {
                                    console.log('[ChatStore][CallDebug] call-start fallback enrichment path', {
                                        callId: callIdRaw || undefined,
                                        fromUserId: fromUserIdRaw || undefined,
                                    });
                                    // Fallback enrichment from chat list when backend payload has minimal fields.
                                    const fromUserId =
                                        (typeof payload?.fromUserId === 'string' ? payload.fromUserId : '') ||
                                        (typeof payload?.from_user_id === 'string' ? payload.from_user_id : '');
                                    const callId =
                                        (typeof payload?.callId === 'string' ? payload.callId : '') ||
                                        (typeof payload?.call_id === 'string' ? payload.call_id : '');
                                    if (fromUserId && callId) {
                                        if (selfUserId && fromUserId.toUpperCase() === selfUserId) {
                                            console.log('[ChatStore][CallDebug] skip fallback incoming self-originated', { callId, fromUserId });
                                            return;
                                        }
                                        const { chats } = get();
                                        const callerChat = chats.find(c =>
                                            c.friendId?.toUpperCase() === fromUserId.toUpperCase()
                                        );
                                        callStore.handleIncomingCall({
                                            fromUserId,
                                            fromUserName: callerChat?.friendName || fromUserId.slice(0, 8),
                                            fromUserImage: callerChat?.friendImage,
                                            callType: payload?.callType === 'video' || payload?.call_type === 'video' ? 'video' : 'voice',
                                            callId,
                                        });
                                    }
                                }
                            } catch (e) {
                                console.warn('[ChatStore] Call handling failed (WebRTC not available?):', e);
                            }
                        });

                        // Handle call accepted by remote party
                        userChannel.on('call-accepted', (payload: any) => {
                            try {
                                const { useCallStore } = require('./stores/CallStore');
                                useCallStore.getState().handleCallAccepted(payload);
                            } catch (e) {
                                console.warn('[ChatStore] Call accepted handling failed:', e);
                            }
                        });

                        // Handle call ended by remote party
                        userChannel.on('call-end', (payload: any) => {
                            try {
                                const { useCallStore } = require('./stores/CallStore');
                                useCallStore.getState().handleCallEnded(payload);
                            } catch (e) {
                                console.warn('[ChatStore] Call end handling failed:', e);
                            }
                        });

                        // Handle WebRTC signaling (SDP offer/answer, ICE candidates)
                        userChannel.on('webrtc-signal', (payload: any) => {
                            try {
                                const { useCallStore } = require('./stores/CallStore');
                                useCallStore.getState().handleWebRTCSignal(payload);
                            } catch (e) {
                                console.warn('[ChatStore] WebRTC signal handling failed:', e);
                            }
                        });
                    }
                });

                socket.onClose((e) => {
                    // console.log('[ChatStore] Phoenix Socket Disconnected', e);
                    disconnectChatEngineShadowTransport();
                    queueRecoverableMessages();
                    // Clear channel references so they get re-joined on reconnect
                    // This ensures fresh handlers are attached
                    chatChannels.clear();
                    userChannel = null;
                    set({ isConnected: false });
                });

                socket.onError((e) => {
                    disconnectChatEngineShadowTransport();
                    queueRecoverableMessages();
                    // Don't clear channels here - let onClose handle it
                    // Just update connection status
                    set({ isConnected: false });
                });
            },

            loadChats: async () => {
                let auth = AuthManager.getInstance().getSession();
                if (!auth) {
                    auth = await AuthManager.getInstance().init();
                    if (!auth) {
                        return;
                    }
                }

                set({ isLoading: true, lastChatsLoad: Date.now() });

                try {
                    // Fetch chats via native-first path (fallbacks to JS API client).
                    const data = await fetchHomeChatsNativeFirst({
                        userId: auth.userId,
                        apiBaseUrl: ProxyManager.getInstance().getBestUrl(),
                        authToken: auth.loginToken || (auth as any)?.token || '',
                    });

                    // Process chats
                    // Process chats with merge logic - PRESERVE local plaintext!
                    const currentChats = get().chats;
                    let processedChats: Chat[] = [];

                    processedChats = await Promise.all(data.map(async (c: any) => {
                        const existing = currentChats.find(ec => ec.chatId === c.chatId);

                        // Normalize server messages to ensure camelCase keys (encryptedContent, etc.)
                        const serverMessagesRaw = c.messages || [];
                        const serverMessages = serverMessagesRaw.map(normalizeMessage);

                        const localMessages = existing?.messages || [];

                        // Merge server history into local state with ID-reconcile support.
                        // This prevents "sent+error duplicate" rows when backend rewrites IDs.
                        let mergedMessages = [...localMessages];
                        let mergeInsertedCount = 0;
                        let mergeReconciledCount = 0;
                        for (const serverMsg of serverMessages) {
                            const mergeResult = upsertIncomingMessage(
                                mergedMessages,
                                serverMsg,
                                auth?.userId || null,
                            );
                            if (mergeResult.changed) {
                                if (mergeResult.reconciledFromMessageId) {
                                    mergeReconciledCount += 1;
                                } else if (mergeResult.inserted) {
                                    mergeInsertedCount += 1;
                                }
                                mergedMessages = mergeResult.messages;
                            }
                        }
                        mergedMessages.sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));
                        chatStoreLog(`[ChatStore-TargetLog] User ${auth?.userId} loaded chat ${c.chatId}. API returned ${serverMessages.length} msgs. Merged result is ${mergedMessages.length} msgs.`);
                        const undecryptableCount = mergedMessages.filter(m => m.encryptedContent && !m.plaintext).length;
                        if (undecryptableCount > 0) {
                            chatStoreLog(`[ChatStore-TargetLog] Out of ${mergedMessages.length} msgs, ${undecryptableCount} need decryption/rendering.`);
                        }

                        chatStoreMessageLog('loadChats:merged', {
                            chatId: c.chatId,
                            localCount: localMessages.length,
                            serverCount: serverMessages.length,
                            mergedCount: mergedMessages.length,
                            inserted: mergeInsertedCount,
                            reconciled: mergeReconciledCount,
                        });

                        // DECRYPT LAST MESSAGE FOR PREVIEW if needed
                        const lastMsg = mergedMessages[mergedMessages.length - 1];
                        if (lastMsg && !lastMsg.plaintext && lastMsg.encryptedContent) {
                            try {
                                if (auth?.keyPair?.privateKey) {
                                    const isFromMe = (lastMsg.fromId || '').toUpperCase() === (auth.userId || '').toUpperCase();
                                    const decrypted = await decryptMessageContent(auth.keyPair.privateKey, lastMsg.encryptedContent, isFromMe, c.chatId);
                                    if (decrypted) {
                                        const parsed = parseDecryptedContent(decrypted);
                                        Object.assign(lastMsg, parsed);
                                    }
                                }
                            } catch (e) {
                                // console.warn('[ChatStore] Preview decrypt failed', e);
                            }
                        }

                        return {
                            chatId: c.chatId,
                            type: c.type || 'dm',
                            name: c.name || null,
                            description: c.description || null,
                            avatarUrl: c.avatarUrl || null,
                            creatorId: c.creatorId || null,
                            memberCount: c.memberCount || null,
                            role: c.role || 'member',
                            members: Array.isArray(c.members)
                                ? c.members
                                    .map((member: any) => {
                                        const userId = String(member?.userId || member?.id || '').trim().toUpperCase();
                                        if (!userId) return null;
                                        const name =
                                            typeof member?.name === 'string' && member.name.trim().length > 0
                                                ? member.name.trim()
                                                : undefined;
                                        const rawRole =
                                            typeof member?.role === 'string'
                                                ? member.role.trim().toLowerCase()
                                                : '';
                                        const role =
                                            rawRole === 'owner' || rawRole === 'admin' || rawRole === 'member' || rawRole === 'subscriber'
                                                ? rawRole
                                                : undefined;
                                        return { userId, name, role };
                                    })
                                    .filter(Boolean)
                                : undefined,
                            friendId: c.friendId,
                            friendName: c.friendName || c.name || c.friendId,
                            friendImage: c.friendImage || c.avatarUrl || null,
                            friendKey: extractPublicKey(c) || extractPublicKey(existing),
                            messages: mergedMessages,
                            lastMessage: lastMsg || serverMessages[0] || null,
                            unreadCount: c.unreadCount || 0,
                            pinned: c.pinned || false,
                            muted: c.muted || false,
                            markedUnread: c.markedUnread || false
                        };
                    }));

                    // Join chat channels for real-time updates
                    // Check socket exists and is connected
                    const isSocketReady = socket && socket.isConnected();

                    if (isSocketReady) {
                        for (const chat of processedChats) {
                            const topic = `chat:${chat.chatId}`;

                            // Always re-join if not in our map (handles reconnection)
                            if (!chatChannels.has(chat.chatId)) {
                                chatStoreLog('[ChatStore] Joining channel:', topic);
                                const channel = socket!.channel(topic, {});

                                // Store reference immediately to prevent duplicate joins
                                chatChannels.set(chat.chatId, channel);

                                channel.join()
                                    .receive("ok", () => {
                                        scheduleChatRetryFlush(chat.chatId, get, 260);
                                    })
                                    .receive("error", (err: any) => {
                                        chatChannels.delete(chat.chatId);
                                    });

                                channel.on("message", async (payload: any) => {
                                    chatStoreLog(`[ChatStore-TargetLog] Realtime msg received on ${topic}: ${payload.id}, type: ${payload.type}. hasPlaintext: ${!!payload.plaintext}, encryptedContent: ${!!payload.encryptedContent}`);
                                    const incomingId = payload?.id || payload?.message_id;

                                    // Ignore current user's own messages (we handle them optimistically)
                                    // UNLESS it's a confirmation/echo with updated server ID (not implemented yet)
                                    // For now we rely on dedup logic
                                    if (incomingId && recentlyProcessedMsgIds.has(incomingId)) return;
                                    if (incomingId) {
                                        recentlyProcessedMsgIds.add(incomingId);
                                        setTimeout(() => recentlyProcessedMsgIds.delete(incomingId), 10000);
                                    }

                                    // Add to store
                                    const newMsg = normalizeMessage(payload);

                                    // Try to decrypt immediately if we have key
                                    const currentAuth = AuthManager.getInstance().getSession();
                                    if (currentAuth?.keyPair?.privateKey && newMsg.encryptedContent) {
                                        try {
                                            const isFromMe = (newMsg.fromId || '').toUpperCase() === (currentAuth.userId || '').toUpperCase();
                                            const decrypted = await decryptMessageContent(currentAuth.keyPair.privateKey, newMsg.encryptedContent, isFromMe, chat.chatId);
                                            if (decrypted) {
                                                const parsed = parseDecryptedContent(decrypted);
                                                Object.assign(newMsg, parsed);
                                            }
                                        } catch (e) {
                                            console.warn('[ChatStore] Realtime decrypt failed', e);
                                        }
                                    }

                                    // Send Delivery Receipt (if not from me)
                                    // REUSE currentAuth from above
                                    if (newMsg.fromId !== currentAuth?.userId) {
                                        get().sendDeliveryReceipt(chat.chatId, newMsg.id);
                                    }

                                    const { chats: currentChats, offlineQueue } = get();
                                    const idx = currentChats.findIndex(c => c.chatId === chat.chatId);
                                    if (idx < 0) return;

                                    const updated = [...currentChats];
                                    const messagesBeforeCount = updated[idx].messages.length;
                                    const upsert = upsertIncomingMessage(
                                        updated[idx].messages,
                                        newMsg,
                                        currentAuth?.userId || null,
                                    );
                                    if (!upsert.changed) return;

                                    const isMe = isMessageFromUser(newMsg, currentAuth?.userId || null);
                                    const nextMessages = upsert.messages;
                                    const nextUnreadCount = isMe || !upsert.inserted
                                        ? (updated[idx].unreadCount || 0)
                                        : ((updated[idx].unreadCount || 0) + 1);
                                    updated[idx] = {
                                        ...updated[idx],
                                        messages: nextMessages,
                                        lastMessage: nextMessages[nextMessages.length - 1] || updated[idx].lastMessage,
                                        unreadCount: nextUnreadCount,
                                    };

                                    // Move to top
                                    updated.sort((a, b) => {
                                        if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
                                        return (b.lastMessage?.timestamp || 0) - (a.lastMessage?.timestamp || 0);
                                    });

                                    const nextQueue = pruneOfflineQueue(
                                        offlineQueue,
                                        newMsg.id,
                                        upsert.reconciledFromMessageId,
                                    );
                                    if (nextQueue === offlineQueue) {
                                        set({ chats: updated });
                                    } else {
                                        set({ chats: updated, offlineQueue: nextQueue });
                                    }

                                    chatStoreMessageLog('realtime:applied', {
                                        chatId: chat.chatId,
                                        messageId: newMsg.id,
                                        type: newMsg.type,
                                        inserted: upsert.inserted,
                                        reconciledFrom: upsert.reconciledFromMessageId,
                                        messagesBefore: messagesBeforeCount,
                                        messagesAfter: nextMessages.length,
                                        queueBefore: offlineQueue.length,
                                        queueAfter: nextQueue.length,
                                        isMe,
                                    });

                                    const nextChat = updated.find((entry) => entry.chatId === chat.chatId);
                                    if (!isMe && nextChat && !extractPublicKey(nextChat)) {
                                        warmFriendPublicKey(chat.chatId, nextChat.friendId, set, get).catch(() => { });
                                    }
                                    if (isMe) {
                                        SoundManager.play('sent'); // Confirmation from server
                                    } else if (!(nextChat?.muted)) {
                                        SoundManager.play('received');
                                    }
                                });

                                // Listen for typing events
                                channel.on("typing", (payload: any) => {
                                    const { typingUsers } = get();
                                    const auth = AuthManager.getInstance().getSession();
                                    const myUserId = auth?.userId?.toUpperCase() || '';
                                    let userId = (payload.userId || payload.fromId || '').toUpperCase();

                                    // Skip our own typing events (don't show ourselves as "typing")
                                    if (userId === 'ME' || userId === myUserId || userId === '') {
                                        chatStoreLog('[ChatStore] Skipping own typing event');
                                        return;
                                    }

                                    chatStoreLog('[ChatStore] Adding to typingUsers:', userId);
                                    const newSet = new Set(typingUsers);
                                    newSet.add(userId);
                                    set({ typingUsers: newSet });
                                });

                                channel.on("stop-typing", (payload: any) => {
                                    const { typingUsers } = get();
                                    const auth = AuthManager.getInstance().getSession();
                                    const myUserId = auth?.userId?.toUpperCase() || '';
                                    let userId = (payload.userId || payload.fromId || '').toUpperCase();

                                    // Skip our own stop-typing events
                                    if (userId === 'ME' || userId === myUserId || userId === '') {
                                        chatStoreLog('[ChatStore] Skipping own stop-typing event');
                                        return;
                                    }

                                    chatStoreLog('[ChatStore] Removing from typingUsers:', userId);
                                    const newSet = new Set(typingUsers);
                                    newSet.delete(userId);
                                    set({ typingUsers: newSet });
                                });

                                channel.on("recording", (payload: any) => {
                                    const { recordingUsers } = get();
                                    const auth = AuthManager.getInstance().getSession();
                                    const myUserId = auth?.userId?.toUpperCase() || '';
                                    let userId = (payload.userId || payload.fromId || '').toUpperCase();

                                    if (userId === 'ME' || userId === myUserId || userId === '') return;

                                    const newSet = new Set(recordingUsers);
                                    newSet.add(userId);
                                    set({ recordingUsers: newSet });
                                });

                                channel.on("stop-recording", (payload: any) => {
                                    const { recordingUsers } = get();
                                    const auth = AuthManager.getInstance().getSession();
                                    const myUserId = auth?.userId?.toUpperCase() || '';
                                    let userId = (payload.userId || payload.fromId || '').toUpperCase();

                                    if (userId === 'ME' || userId === myUserId || userId === '') return;

                                    const newSet = new Set(recordingUsers);
                                    newSet.delete(userId);
                                    set({ recordingUsers: newSet });
                                });

                                // Listen for message delivered events (when recipient receives message)
                                channel.on("message-delivered", (payload: any) => {
                                    const messageId = payload.messageId || payload.message_id;
                                    if (!messageId) return;

                                    const { chats: currentChats } = get();
                                    const chatIdx = currentChats.findIndex(c => c.chatId === chat.chatId);
                                    if (chatIdx === -1) return;

                                    const msgIdx = currentChats[chatIdx].messages.findIndex(m => m.id === messageId);
                                    if (msgIdx === -1) return;

                                    // Pending can happen after reconnect/timeouts; delivery should still advance it.
                                    const currentStatus = currentChats[chatIdx].messages[msgIdx].status;
                                    if (
                                        currentStatus === 'sent' ||
                                        currentStatus === 'sending' ||
                                        currentStatus === 'pending'
                                    ) {
                                        const updated = [...currentChats];
                                        const updatedMessages = [...updated[chatIdx].messages];
                                        updatedMessages[msgIdx] = { ...updatedMessages[msgIdx], status: 'delivered' };
                                        updated[chatIdx] = { ...updated[chatIdx], messages: updatedMessages };
                                        set({ chats: updated });
                                        chatStoreLog('[ChatStore] Updated message status to delivered:', messageId);
                                    }
                                });

                                // Listen for message read events (when recipient reads message)
                                channel.on("message-read", (payload: any) => {
                                    const messageId = payload.messageId || payload.message_id;
                                    if (!messageId) return;

                                    const { chats: currentChats } = get();
                                    const auth = AuthManager.getInstance().getSession();
                                    const nextChats = applyReadUpToMessageInChat(
                                        currentChats,
                                        chat.chatId,
                                        messageId,
                                        auth?.userId || null
                                    );
                                    if (nextChats !== currentChats) {
                                        set({ chats: nextChats });
                                        chatStoreLog('[ChatStore] Updated message status to read (up to):', messageId);
                                    }
                                });

                                channel.on("message-deleted", (payload: any) => {
                                    const messageId = payload.messageId || payload.message_id;
                                    if (!messageId) return;
                                    const currentChats = get().chats;
                                    const nextChats = removeMessageFromChatList(currentChats, chat.chatId, messageId);
                                    if (nextChats !== currentChats) {
                                        set({ chats: nextChats });
                                        const { offlineQueue } = get();
                                        if (offlineQueue.some((m) => m.id === messageId)) {
                                            set({ offlineQueue: offlineQueue.filter((m) => m.id !== messageId) });
                                        }
                                    }
                                });

                                channel.on("message-edited", (payload: any) => {
                                    void handleMessageEditedPayload(chat.chatId, payload, set, get);
                                });
                            }
                        }
                    } else {
                        chatStoreLog('[ChatStore] Socket not ready, channels will be joined on connect');
                    }

                    // Sort chats: Pinned first, then by last message timestamp (newest first)
                    processedChats.sort((a, b) => {
                        if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
                        const aTime = a.lastMessage?.timestamp || 0;
                        const bTime = b.lastMessage?.timestamp || 0;
                        return bTime - aTime;
                    });

                    const existingChatsSnapshot = get().chats;
                    const chatsUnchanged =
                        existingChatsSnapshot.length === processedChats.length &&
                        existingChatsSnapshot.every((existing, index) => {
                            const next = processedChats[index];
                            if (!next) return false;
                            const existingLastId = existing.lastMessage?.id || '';
                            const nextLastId = next.lastMessage?.id || '';
                            return (
                                existing.chatId === next.chatId &&
                                existing.messages.length === next.messages.length &&
                                existingLastId === nextLastId &&
                                existing.unreadCount === next.unreadCount &&
                                existing.pinned === next.pinned
                            );
                        });

                    if (chatsUnchanged) {
                        set({ isLoading: false });
                        chatStoreLog('[ChatStore] Chats unchanged, skipped chats state update');
                    } else {
                        set({ chats: processedChats, isLoading: false });
                        chatStoreLog('[ChatStore] State updated with chats:', processedChats.length);
                    }

                    // Warm friend public keys for startup-sensitive chats (active + unread),
                    // so first send/reply does not wait on key fetch.
                    const currentActive = get().activeChatId;
                    const warmCandidates = processedChats
                        .filter(c =>
                            !!c.friendId &&
                            !extractPublicKey(c) &&
                            (c.chatId === currentActive || (c.unreadCount || 0) > 0)
                        )
                        .slice(0, 4);

                    warmCandidates.forEach((c) => {
                        warmFriendPublicKey(c.chatId, c.friendId, set, get).catch(() => { });
                    });

                } catch (e) {
                    if (isRecoverableSendError(e)) {
                        console.warn('[ChatStore] Load chats deferred (network):', (e as any)?.message || e);
                    } else {
                        console.error('[ChatStore] Load chats failed:', e);
                    }
                    set({ isLoading: false });
                }
            },

            startChat: async (friendId, friendInfo) => {
                const friendKey = (friendId || '').toUpperCase();
                if (!friendKey) throw new Error('Missing friendId');

                // If we already have a DM with this user, reuse it.
                const existingByFriend = get().chats.find(c => (c.friendId || '').toUpperCase() === friendKey);
                if (existingByFriend?.chatId) {
                    if (!extractPublicKey(existingByFriend)) {
                        warmFriendPublicKey(existingByFriend.chatId, friendId, set, get).catch(() => { });
                    }
                    return existingByFriend.chatId;
                }

                // Dedupe concurrent calls to prevent duplicate chats
                const existingInFlight = startChatInFlight.get(friendKey);
                if (existingInFlight) return existingInFlight;

                const promise = (async () => {
                    const proxy = ProxyManager.getInstance();
                    const baseUrl = proxy.getBestUrl();
                    const auth = AuthManager.getInstance().getSession();
                    if (!auth) throw new Error('Not authenticated');

                    const res = await fetch(`${baseUrl}/api/chat`, {
                        method: 'POST',
                        headers: buildAuthHeaders(auth, {
                            'Content-Type': 'application/json',
                        }),
                        body: JSON.stringify({ myId: auth.userId, friendId })
                    });

                    chatStoreLog('[ChatStore] startChat response status:', res.status);

                    if (!res.ok) {
                        const text = await res.text();
                        console.error('[ChatStore] startChat failed:', text);
                        throw new Error(text || `HTTP ${res.status}`);
                    }

                    const data = await res.json();
                    const chatId = data.chatId;

                    // Add new chat to local state immediately so it appears in the list
                    const { chats } = get();
                    const existingChat = chats.find(c => c.chatId === chatId);
                    if (!existingChat) {
                        const newChat: Chat = {
                            chatId: chatId,
                            friendId: friendId,
                            friendName: friendInfo?.username || friendId,
                            friendImage: friendInfo?.profileImage || undefined,
                            friendKey: extractPublicKey(friendInfo) || undefined,
                            messages: data.messages || [],
                            lastMessage: undefined,
                            unreadCount: 0,
                            pinned: false,
                            muted: false,
                            markedUnread: false
                        };
                        set({ chats: [newChat, ...chats] });

                        if (!newChat.friendKey) {
                            warmFriendPublicKey(chatId, friendId, set, get).catch(() => { });
                        }

                        // Also join the chat channel for real-time updates
                        if (socket && socket.isConnected()) {
                            const topic = `chat:${chatId}`;
                            if (!chatChannels.has(chatId)) {
                                const channel = socket.channel(topic, {});
                                chatChannels.set(chatId, channel); // Store immediately

                                // Register event handlers BEFORE join so no messages are missed.
                                // Phoenix channels queue pushes until joined, so sendMessage
                                // can push immediately — it will be delivered once join completes.

                                // Add message handler for this new channel with pre-decryption
                                channel.on("message", (payload: any) => {
                                    const deobfuscated = deobfuscatePayload(payload);
                                    const serverMsg = deobfuscated.encryptedContent ? deobfuscated : payload;
                                    const incomingId = serverMsg.id || serverMsg.message_id;

                                    if (!incomingId || !serverMsg.fromId) return;

                                    // Synchronous dedup check
                                    if (recentlyProcessedMsgIds.has(incomingId)) return;
                                    recentlyProcessedMsgIds.add(incomingId);
                                    setTimeout(() => recentlyProcessedMsgIds.delete(incomingId), 10000);

                                    (async () => {
                                        chatStoreLog('[ChatStore] New Message in new chat:', serverMsg.id);
                                        const { chats: currentChats, offlineQueue } = get();
                                        const idx = currentChats.findIndex(c => c.chatId === chatId);
                                        if (idx < 0) return;

                                        // PRE-DECRYPT the message
                                        let decryptedPayload: Partial<Message> = {};
                                        try {
                                            const sess = AuthManager.getInstance().getSession();
                                            if (sess?.keyPair?.privateKey && serverMsg.encryptedContent) {
                                                const isFromMe = serverMsg.fromId === sess.userId;
                                                const decrypted = await decryptMessageContent(sess.keyPair.privateKey, serverMsg.encryptedContent, isFromMe, chatId);
                                                if (decrypted) {
                                                    decryptedPayload = parseDecryptedContent(decrypted);
                                                }
                                            }
                                        } catch (e) {
                                            console.warn('[ChatStore] Pre-decrypt failed in startChat:', e);
                                        }

                                        const msg = normalizeMessage({
                                            ...serverMsg,
                                            chatId,
                                            status: serverMsg.status || 'delivered',
                                        });
                                        if (Object.keys(decryptedPayload).length > 0) {
                                            Object.assign(msg, decryptedPayload);
                                        }

                                        const updated = [...currentChats];
                                        const messagesBeforeCount = updated[idx].messages.length;
                                        const upsert = upsertIncomingMessage(
                                            updated[idx].messages,
                                            msg,
                                            auth.userId,
                                        );
                                        if (!upsert.changed) return;

                                        const isMe = isMessageFromUser(msg, auth.userId);
                                        const nextMessages = upsert.messages;
                                        const nextUnreadCount = isMe || !upsert.inserted
                                            ? (updated[idx].unreadCount || 0)
                                            : ((updated[idx].unreadCount || 0) + 1);
                                        updated[idx] = {
                                            ...updated[idx],
                                            messages: nextMessages,
                                            lastMessage: nextMessages[nextMessages.length - 1] || updated[idx].lastMessage,
                                            unreadCount: nextUnreadCount,
                                        };

                                        const nextQueue = pruneOfflineQueue(
                                            offlineQueue,
                                            msg.id,
                                            upsert.reconciledFromMessageId,
                                        );
                                        if (nextQueue === offlineQueue) {
                                            set({ chats: updated });
                                        } else {
                                            set({ chats: updated, offlineQueue: nextQueue });
                                        }

                                        chatStoreMessageLog('startChat:realtimeApplied', {
                                            chatId,
                                            messageId: msg.id,
                                            type: msg.type,
                                            inserted: upsert.inserted,
                                            reconciledFrom: upsert.reconciledFromMessageId,
                                            messagesBefore: messagesBeforeCount,
                                            messagesAfter: nextMessages.length,
                                            queueBefore: offlineQueue.length,
                                            queueAfter: nextQueue.length,
                                            isMe,
                                        });

                                        if (!isMe && !extractPublicKey(updated[idx])) {
                                            warmFriendPublicKey(chatId, updated[idx].friendId, set, get).catch(() => { });
                                        }
                                    })();
                                });

                                // Add typing handlers
                                channel.on("typing", (payload: any) => {
                                    const { typingUsers } = get();
                                    const auth = AuthManager.getInstance().getSession();
                                    const myUserId = auth?.userId?.toUpperCase() || '';
                                    let userId = (payload.userId || payload.fromId || '').toUpperCase();
                                    if (userId === 'ME' || userId === myUserId || userId === '') return;
                                    const newSet = new Set(typingUsers);
                                    newSet.add(userId);
                                    set({ typingUsers: newSet });
                                });

                                channel.on("stop-typing", (payload: any) => {
                                    const { typingUsers } = get();
                                    const auth = AuthManager.getInstance().getSession();
                                    const myUserId = auth?.userId?.toUpperCase() || '';
                                    let userId = (payload.userId || payload.fromId || '').toUpperCase();
                                    if (userId === 'ME' || userId === myUserId || userId === '') return;
                                    const newSet = new Set(typingUsers);
                                    newSet.delete(userId);
                                    set({ typingUsers: newSet });
                                });

                                // Listen for message delivered events
                                channel.on("message-delivered", (payload: any) => {
                                    chatStoreLog('[ChatStore] Message delivered (startChat):', payload);
                                    const messageId = payload.messageId || payload.message_id;
                                    if (!messageId) return;

                                    const { chats: currentChats } = get();
                                    const chatIdx = currentChats.findIndex(c => c.chatId === chatId);
                                    if (chatIdx === -1) return;

                                    const msgIdx = currentChats[chatIdx].messages.findIndex(m => m.id === messageId);
                                    if (msgIdx === -1) return;

                                    const currentStatus = currentChats[chatIdx].messages[msgIdx].status;
                                    if (
                                        currentStatus === 'sent' ||
                                        currentStatus === 'sending' ||
                                        currentStatus === 'pending'
                                    ) {
                                        const updated = [...currentChats];
                                        const updatedMessages = [...updated[chatIdx].messages];
                                        updatedMessages[msgIdx] = { ...updatedMessages[msgIdx], status: 'delivered' };
                                        updated[chatIdx] = { ...updated[chatIdx], messages: updatedMessages };
                                        set({ chats: updated });
                                    }
                                });

                                // Listen for message read events
                                channel.on("message-read", (payload: any) => {
                                    chatStoreLog('[ChatStore] Message read (startChat):', payload);
                                    const messageId = payload.messageId || payload.message_id;
                                    if (!messageId) return;

                                    const { chats: currentChats } = get();
                                    const auth = AuthManager.getInstance().getSession();
                                    const nextChats = applyReadUpToMessageInChat(
                                        currentChats,
                                        chatId,
                                        messageId,
                                        auth?.userId || null
                                    );
                                    if (nextChats !== currentChats) {
                                        set({ chats: nextChats });
                                    }
                                });

                                channel.on("message-deleted", (payload: any) => {
                                    const messageId = payload.messageId || payload.message_id;
                                    if (!messageId) return;
                                    const currentChats = get().chats;
                                    const nextChats = removeMessageFromChatList(currentChats, chatId, messageId);
                                    if (nextChats !== currentChats) {
                                        set({ chats: nextChats });
                                        const { offlineQueue } = get();
                                        if (offlineQueue.some((m) => m.id === messageId)) {
                                            set({ offlineQueue: offlineQueue.filter((m) => m.id !== messageId) });
                                        }
                                    }
                                });

                                channel.on("message-edited", (payload: any) => {
                                    void handleMessageEditedPayload(chatId, payload, set, get);
                                });

                                // Join channel in background (don't await — Phoenix queues pushes until joined)
                                channel.join()
                                    .receive("ok", () => {
                                        chatStoreLog(`[ChatStore] Joined new chat ${chatId}`);
                                        scheduleChatRetryFlush(chatId, get, 260);
                                    })
                                    .receive("error", () => {
                                        chatStoreLog(`[ChatStore] Failed to join new chat ${chatId}`);
                                        chatChannels.delete(chatId);
                                    })
                                    .receive("timeout", () => {
                                        chatStoreLog(`[ChatStore] Timeout joining new chat ${chatId}`);
                                    });
                            }
                        }
                    }

                    return chatId;
                })();

                startChatInFlight.set(friendKey, promise);
                try {
                    return await promise;
                } finally {
                    startChatInFlight.delete(friendKey);
                }
            },

            setUploadProgress: (messageId, progress) => {
                const { uploadProgress } = get();
                set({ uploadProgress: { ...uploadProgress, [messageId]: progress } });
            },

            clearUploadProgress: (messageId) => {
                const { uploadProgress } = get();
                const updated = { ...uploadProgress };
                delete updated[messageId];
                set({ uploadProgress: updated });
                uploadAbortControllers.delete(messageId);
            },

            cancelUpload: (chatId, messageId) => {
                // Abort the in-flight upload
                const controller = uploadAbortControllers.get(messageId);
                if (controller) {
                    controller.abort();
                    uploadAbortControllers.delete(messageId);
                }
                // Clear progress
                get().clearUploadProgress(messageId);
                // Remove the message from chat
                const { chats } = get();
                set({
                    chats: chats.map(c => {
                        if (c.chatId !== chatId) return c;
                        const msgs = c.messages.filter(m => m.id !== messageId);
                        return { ...c, messages: msgs, lastMessage: msgs[msgs.length - 1] || c.lastMessage };
                    })
                });
            },

            markViewOnceViewed: (chatId, messageId) => {
                const { chats } = get();
                set({
                    chats: chats.map(c => {
                        if (c.chatId !== chatId) return c;
                        return {
                            ...c,
                            messages: (c.messages || []).map(m => {
                                if (m.id !== messageId) return m;
                                const viewed = m.viewedBy || [];
                                if (viewed.includes('self')) return m;
                                return { ...m, viewedBy: [...viewed, 'self'] };
                            }),
                        };
                    }),
                });
            },

            retryMessage: async (chatId, messageId) => {
                const { chats } = get();
                const chat = chats.find(c => c.chatId === chatId);
                if (!chat) return;
                const msg = chat.messages.find(m => m.id === messageId);
                if (!msg || (msg.status !== 'error' && msg.status !== 'pending' && msg.status !== 'sending')) return;
                if (hasPermanentLocalMediaError(msg)) {
                    chatStoreMessageLog('retry:skipped-permanent-local-media-error', {
                        chatId,
                        messageId,
                        type: msg.type,
                        mediaUrl: msg.mediaUrl,
                    });
                    return;
                }

                const existingId = isValidBinaryId(msg.id) ? msg.id : undefined;
                if (!existingId) {
                    // Remove stale non-UUID message IDs before retrying to avoid backend cast errors.
                    const updatedChats = chats.map((c) => {
                        if (c.chatId !== chatId) return c;
                        const nextMessages = c.messages.filter((m) => m.id !== messageId);
                        return {
                            ...c,
                            messages: nextMessages,
                            lastMessage: nextMessages[nextMessages.length - 1] || c.lastMessage,
                        };
                    });
                    set({ chats: updatedChats });
                }

                // Recover text from encrypted payload when persisted pending messages lost plaintext.
                let recoveredText = msg.plaintext || '';
                if (msg.type === 'text' && !recoveredText.trim() && msg.encryptedContent) {
                    try {
                        const sess = AuthManager.getInstance().getSession();
                        if (sess?.keyPair?.privateKey) {
                            const isFromMe = (msg.fromId || '').toUpperCase() === (sess.userId || '').toUpperCase();
                            const decrypted = await decryptMessageContent(sess.keyPair.privateKey, msg.encryptedContent, isFromMe, chatId);
                            const parsed = parseDecryptedContent(decrypted || '');
                            if (typeof parsed.plaintext === 'string') {
                                recoveredText = parsed.plaintext;
                            } else if (typeof decrypted === 'string') {
                                recoveredText = decrypted;
                            }

                            if (recoveredText !== (msg.plaintext || '')) {
                                const latestChats = get().chats;
                                const idx = latestChats.findIndex((c) => c.chatId === chatId);
                                if (idx > -1) {
                                    const updated = [...latestChats];
                                    updated[idx] = {
                                        ...updated[idx],
                                        messages: updated[idx].messages.map((m) => (
                                            m.id === messageId ? { ...m, plaintext: recoveredText } : m
                                        )),
                                    };
                                    set({ chats: updated });
                                }
                            }
                        }
                    } catch (e) {
                        console.warn('[ChatStore] retryMessage plaintext recovery failed:', e);
                    }
                }

                if (msg.type === 'text' && !recoveredText.trim()) {
                    const latestChats = get().chats;
                    const idx = latestChats.findIndex((c) => c.chatId === chatId);
                    if (idx > -1) {
                        const updated = [...latestChats];
                        updated[idx] = {
                            ...updated[idx],
                            messages: updated[idx].messages.map((m) => (
                                m.id === messageId
                                    ? { ...m, status: 'error' as const, errorMessage: 'Could not recover message text for retry' }
                                    : m
                            )),
                        };
                        set({ chats: updated });
                    }
                    return;
                }

                // Re-send using recovered plaintext and existing metadata.
                try {
                    await get().sendMessage(chatId, recoveredText, msg.type, {
                        mediaUrl: msg.mediaUrl,
                        fileName: msg.fileName,
                        fileSize: msg.fileSize,
                        latitude: msg.latitude,
                        longitude: msg.longitude,
                        duration: msg.duration,
                        contact: msg.contact,
                        replyToId: msg.replyToId,
                        caption: msg.caption,
                        viewOnce: msg.viewOnce,
                        isVideoNote: msg.isVideoNote,
                        width: msg.extra?.width,
                        height: msg.extra?.height,
                        waveform: msg.extra?.waveform,
                    }, existingId);
                } catch (e) {
                    console.warn('[ChatStore] retryMessage send failed:', e);
                }
            },

            deleteFailedMessage: (chatId, messageId) => {
                const { chats } = get();
                const chatIdx = chats.findIndex(c => c.chatId === chatId);
                if (chatIdx === -1) return;
                const msg = chats[chatIdx].messages.find(m => m.id === messageId);
                if (!msg || (msg.status !== 'error' && msg.status !== 'pending')) return;

                const updated = [...chats];
                const filteredMessages = updated[chatIdx].messages.filter(m => m.id !== messageId);
                updated[chatIdx] = {
                    ...updated[chatIdx],
                    messages: filteredMessages,
                    lastMessage: filteredMessages.length > 0 ? filteredMessages[filteredMessages.length - 1] : undefined,
                };
                set({ chats: updated });
            },

            editMessage: async (chatId, messageId, text) => {
                const auth = AuthManager.getInstance().getSession();
                if (!auth?.keyPair?.publicKey || !auth?.keyPair?.privateKey) return false;
                if (!isValidBinaryId(messageId)) return false;

                const nextText = text.trim();
                if (!nextText) return false;
                if (__DEV__) {
                    chatStoreLog('[ChatStore] editMessage start', { chatId, messageId, textLength: nextText.length });
                }

                const { chats } = get();
                const chat = chats.find(c => c.chatId === chatId);
                if (!chat) return false;
                const existing = chat.messages.find(m => m.id === messageId);
                if (!existing || existing.type !== 'text') return false;
                if ((existing.fromId || '').toUpperCase() !== auth.userId.toUpperCase()) return false;
                if ((existing.plaintext || '').trim() === nextText) return true;

                const channel = chatChannels.get(chatId);

                const friendPublicKey = extractPublicKey(chat) || await warmFriendPublicKey(chatId, chat.friendId, set, get);
                if (!friendPublicKey) return false;

                const editedAt = Date.now();

                try {
                    const fullPayload = JSON.stringify({
                        text: nextText,
                        mediaUrl: existing.mediaUrl,
                        mediaKey: existing.mediaKey,
                        fileName: existing.fileName,
                        fileSize: existing.fileSize,
                        latitude: existing.latitude,
                        longitude: existing.longitude,
                        duration: existing.duration,
                        width: existing.extra?.width,
                        height: existing.extra?.height,
                        replyToId: existing.replyToId,
                        contact: existing.contact,
                        caption: existing.caption,
                        thumbnailBase64: existing.extra?.thumbnailBase64,
                        viewOnce: existing.viewOnce || undefined,
                        isVideoNote: existing.isVideoNote || undefined,
                        waveform: existing.extra?.waveform || undefined,
                        isEdited: true,
                        editedAt,
                    });

                    const importedKey = await importPublicKey(friendPublicKey);
                    const encrypted = await encryptMessageNativeFirst({
                        recipientPublicKey: importedKey,
                        message: fullPayload,
                        myPublicKey: auth.keyPair.publicKey,
                    });

                    const optimisticPatch: Partial<Message> = {
                        plaintext: nextText,
                        encryptedContent: encrypted,
                        isEdited: true,
                        editedAt,
                        extra: {
                            ...(existing.extra || {}),
                            isEdited: true,
                            editedAt,
                        },
                    };
                    const optimisticChats = applyMessageEditedInChats(get().chats, chatId, messageId, optimisticPatch);
                    if (optimisticChats !== get().chats) {
                        set({ chats: optimisticChats });
                        if (__DEV__) {
                            chatStoreLog('[ChatStore] editMessage optimistic patch applied', { chatId, messageId, editedAt });
                        }
                    }

                    const nativeAccepted = await tryNativeChatEngineEditMessage(chatId, messageId, encrypted, editedAt);
                    if (nativeAccepted) {
                        if (__DEV__) {
                            chatStoreLog('[ChatStore] editMessage native push accepted', { chatId, messageId });
                        }
                        return true;
                    }

                    if (!channel) return false;

                    channel.push("edit-message", {
                        messageId,
                        encryptedContent: encrypted,
                        editedAt,
                    }).receive("error", (err: any) => {
                        console.warn('[ChatStore] edit-message failed:', err);
                    }).receive("timeout", () => {
                        console.warn('[ChatStore] edit-message timeout:', messageId);
                    });
                    if (__DEV__) {
                        chatStoreLog('[ChatStore] editMessage JS fallback push sent', { chatId, messageId });
                    }

                    return true;
                } catch (e) {
                    console.error('[ChatStore] editMessage failed:', e);
                    return false;
                }
            },

            sendMessage: async (chatId, text, type: Message['type'] = 'text', metadata: any = {}, existingId?: string) => {
                const auth = AuthManager.getInstance().getSession();
                if (!auth) {
                    console.warn('[ChatStore] sendMessage - no auth session');
                    return;
                }

                const normalizedExistingId = isValidBinaryId(existingId) ? existingId : undefined;
                let msgId = normalizedExistingId || Crypto.randomUUID();
                let staleExistingId = existingId && existingId !== msgId ? existingId : undefined;
                const now = Date.now();

                // Check Connection
                const { isConnected } = get();

                // Add to chats state immediately
                const { chats } = get();
                const chatIndex = chats.findIndex(c => c.chatId === chatId);
                if (chatIndex > -1) {
                    const existingMessage = chats[chatIndex].messages.find((m) => m.id === msgId);
                    if (existingMessage) {
                        const samePayload = doesOutgoingPayloadMatchMessage(existingMessage, text, type, metadata);
                        if (
                            samePayload
                            && (
                                existingMessage.status === 'sent'
                                || existingMessage.status === 'delivered'
                                || existingMessage.status === 'read'
                            )
                        ) {
                            chatStoreMessageLog('send:dedup-skip-existing', {
                                chatId,
                                messageId: msgId,
                                type,
                                status: existingMessage.status,
                            });
                            return;
                        }
                        if (!samePayload) {
                            const previousId = msgId;
                            msgId = Crypto.randomUUID();
                            staleExistingId = undefined;
                            chatStoreMessageLog('send:id-collision-regenerated', {
                                chatId,
                                previousId,
                                regeneratedId: msgId,
                                type,
                                existingStatus: existingMessage.status,
                            });
                        }
                    }

                    // 1. IMMEDIATE Optimistic Update - show message before encryption
                    const optimisticMsg: Message = {
                        id: msgId,
                        fromId: auth.userId,
                        chatId: chatId,
                        encryptedContent: '',
                        type: type,
                        timestamp: now,
                        plaintext: text,
                        mediaUrl: metadata.mediaUrl,
                        fileName: metadata.fileName,
                        fileSize: metadata.fileSize,
                        latitude: metadata.latitude,
                        longitude: metadata.longitude,
                        duration: metadata.duration,
                        contact: metadata.contact,
                        replyToId: metadata.replyToId,
                        caption: metadata.caption,
                        viewOnce: metadata.viewOnce,
                        viewedBy: [],
                        isVideoNote: metadata.isVideoNote,
                        extra: {
                            width: metadata.width,
                            height: metadata.height,
                            waveform: metadata.waveform,
                        },
                        status: isConnected ? 'sending' : 'pending'
                    };

                    const updatedChats = [...chats];
                    // Handle potential duplicate/retry by filtering — combine filter + append in one pass
                    const existingMsgs = updatedChats[chatIndex].messages;
                    const newMsgs = staleExistingId || existingMsgs.some(m => m.id === msgId)
                        ? existingMsgs.filter(m => m.id !== msgId && m.id !== staleExistingId)
                        : existingMsgs;
                    // Append optimistic message (reuse array ref if no filter was needed)
                    const finalMsgs = newMsgs === existingMsgs
                        ? [...existingMsgs, optimisticMsg]
                        : [...newMsgs, optimisticMsg];

                    updatedChats[chatIndex] = {
                        ...updatedChats[chatIndex],
                        messages: finalMsgs,
                        lastMessage: optimisticMsg
                    };
                    // Move this chat to its correct position instead of a full sort.
                    // In most cases it just moves to the top (or just below pinned chats).
                    if (chatIndex > 0) {
                        const [movedChat] = updatedChats.splice(chatIndex, 1);
                        let insertAt = 0;
                        // Skip past pinned chats that should stay above
                        while (insertAt < updatedChats.length && updatedChats[insertAt].pinned && !movedChat.pinned) {
                            insertAt++;
                        }
                        updatedChats.splice(insertAt, 0, movedChat);
                    }
                    set({ chats: updatedChats });
                } else {
                    throw new Error('Chat not found');
                }

                // 1.5 Normalize/Persist local media URI before queueing or upload.
                let resolvedMediaUrl = metadata.mediaUrl;
                let mediaKey: string | undefined; // AES key for file-level encryption
                const isLocalFile = resolvedMediaUrl && (resolvedMediaUrl.startsWith('file://') || resolvedMediaUrl.startsWith('/'));
                const isMediaType = ['image', 'video', 'voice', 'music', 'file'].includes(type) || metadata.mediaUrl;

                const syncOptimisticMessagePatch = (patch: Partial<Message>) => {
                    const nextChats = get().chats;
                    const nextChatIndex = nextChats.findIndex((c) => c.chatId === chatId);
                    if (nextChatIndex === -1) return;

                    let changed = false;
                    const updatedChats = [...nextChats];
                    const updatedMessages = updatedChats[nextChatIndex].messages.map((m) => {
                        if (m.id !== msgId) return m;
                        const patchExtra = patch.extra as Record<string, unknown> | undefined;
                        const hasDirectChange = Object.entries(patch).some(([key, value]) => {
                            if (key === 'extra') return false;
                            return (m as any)[key] !== value;
                        });
                        const hasExtraChange = !!patchExtra && Object.entries(patchExtra).some(([key, value]) => (
                            (m.extra || {})[key] !== value
                        ));
                        if (!hasDirectChange && !hasExtraChange) return m;
                        changed = true;
                        return {
                            ...m,
                            ...patch,
                            extra: {
                                ...(m.extra || {}),
                                ...(patch.extra || {}),
                            },
                        };
                    });

                    if (!changed) return;
                    updatedChats[nextChatIndex] = {
                        ...updatedChats[nextChatIndex],
                        messages: updatedMessages,
                        lastMessage: updatedMessages[updatedMessages.length - 1] || updatedChats[nextChatIndex].lastMessage,
                    };
                    set({ chats: updatedChats });
                };

                const syncOptimisticMediaUri = (nextUri: string) => {
                    syncOptimisticMessagePatch({ mediaUrl: nextUri });
                };

                if (isLocalFile && isMediaType) {
                    const durableUri = await ensureDurableOutgoingLocalUri(resolvedMediaUrl, msgId, type);
                    if (!durableUri) {
                        console.warn('[ChatStore] Local media file is not readable:', resolvedMediaUrl);
                        const latestChats = get().chats;
                        const idx = latestChats.findIndex((c) => c.chatId === chatId);
                        if (idx > -1) {
                            const updated = [...latestChats];
                            updated[idx] = {
                                ...updated[idx],
                                messages: updated[idx].messages.map((m) => (
                                    m.id === msgId
                                        ? {
                                            ...m,
                                            status: 'error' as const,
                                            errorMessage: LOCAL_MEDIA_MISSING_USER_MESSAGE,
                                        }
                                        : m
                                )),
                            };
                            set({ chats: updated });
                        }
                        get().clearUploadProgress(msgId);
                        return;
                    }

                    resolvedMediaUrl = durableUri;
                    metadata.mediaUrl = durableUri;
                    syncOptimisticMediaUri(durableUri);
                    chatStoreMessageLog('send:local-media-ready', {
                        chatId,
                        messageId: msgId,
                        type,
                        mediaUri: durableUri,
                    });
                }
                const originalLocalMediaUri = isLocalFile && isMediaType
                    ? metadata.mediaUrl
                    : undefined;

                if (!isConnected) {
                    chatStoreLog('[ChatStore] Offline, queuing message:', msgId);
                    const { offlineQueue } = get();
                    const queuedMessage = get().chats
                        .find((c) => c.chatId === chatId)
                        ?.messages.find((m) => m.id === msgId);
                    if (!queuedMessage) {
                        chatStoreMessageLog('send:offline-queue-missing-row', {
                            chatId,
                            messageId: msgId,
                            type,
                        });
                        return;
                    }
                    const nextQueueMap = new Map<string, Message>();
                    offlineQueue.forEach((m) => nextQueueMap.set(m.id, m));
                    nextQueueMap.set(msgId, queuedMessage);
                    set({ offlineQueue: Array.from(nextQueueMap.values()) });
                    return;
                }

                // 1.6 START KEY FETCH IN PARALLEL with media processing (HD speed optimization)
                const chat = chats.find(c => c.chatId === chatId);
                if (!chat) throw new Error('Chat not found');
                let friendPublicKey: string | null = extractPublicKey(chat);

                const keyFetchPromise = friendPublicKey
                    ? Promise.resolve(friendPublicKey)
                    : warmFriendPublicKey(chatId, chat.friendId, set, get);

                if (isLocalFile && isMediaType) {
                    // Create an AbortController so this upload can be cancelled
                    const abortController = new AbortController();
                    uploadAbortControllers.set(msgId, abortController);
                    const uploadSignal = abortController.signal;

                    try {
                        chatStoreLog('[ChatStore] Encrypting & uploading media:', resolvedMediaUrl);
                        const mediaCategory = type === 'image' ? 'image' : type === 'video' ? 'video' : type === 'voice' || type === 'music' ? 'audio' : 'file';

                        // Step 0: Set initial progress to show activity
                        get().setUploadProgress(msgId, 0.05);

                        let fileUri = normalizeFileUri(resolvedMediaUrl);
                        const readableFileUri = await ensureReadableLocalUri(fileUri);
                        if (!readableFileUri) {
                            throw new Error(MEDIA_LOCAL_FILE_MISSING);
                        }
                        fileUri = readableFileUri;

                        // Check file size to decide encryption strategy
                        const fileInfo = await FileSystem.getInfoAsync(fileUri);
                        const fileSizeBytes = (fileInfo as any).size || 0;
                        const fileSizeMB = fileSizeBytes / (1024 * 1024);

                        // For large files (>15MB), use chunked encryption to avoid OOM crash.
                        // Reads file in 1MB chunks through streaming AES cipher instead of
                        // loading entire file into a single base64 JS string.
                        const useLargeFileMode = fileSizeMB > 15;

                        if (useLargeFileMode) {
                            chatStoreLog(`[ChatStore] Large file (${Math.round(fileSizeMB)}MB), using chunked encryption`);
                            get().setUploadProgress(msgId, 0.05);

                            const ext = guessMediaExtension(resolvedMediaUrl, type);
                            const tempPath = `${FileSystem.cacheDirectory}encrypted_${Date.now()}.${ext}.enc`;

                            const result = await encryptFileChunked(
                                fileUri,
                                tempPath,
                                (fraction) => {
                                    // Map encrypt progress 0-1 to 0.05-0.30
                                    get().setUploadProgress(msgId, 0.05 + (fraction * 0.25));
                                }
                            );

                            if (result) {
                                mediaKey = result.keyBase64;
                                chatStoreLog('[ChatStore] Large file chunked-encrypted, key length:', mediaKey.length);
                                get().setUploadProgress(msgId, 0.30);

                                const uploadedUrl = await uploadMedia(
                                    tempPath,
                                    auth.userId,
                                    mediaCategory as 'image' | 'audio' | 'video' | 'file',
                                    (progress) => {
                                        const activeProgress = 0.3 + (progress * 0.7);
                                        get().setUploadProgress(msgId, activeProgress);
                                    },
                                    uploadSignal,
                                );

                                FileSystem.deleteAsync(tempPath, { idempotent: true }).catch(() => { });

                                if (uploadedUrl) {
                                    resolvedMediaUrl = uploadedUrl;
                                    metadata.mediaUrl = uploadedUrl;
                                    syncOptimisticMessagePatch({ mediaUrl: uploadedUrl, mediaKey });
                                    if (typeof originalLocalMediaUri === 'string' && originalLocalMediaUri.length > 0) {
                                        const originalUri = originalLocalMediaUri.startsWith('file://') ? originalLocalMediaUri : `file://${originalLocalMediaUri}`;
                                        useEncryptedMediaStore.getState().manuallyCacheFile(uploadedUrl, originalUri);
                                    }
                                    chatStoreLog('[ChatStore] Large media encrypted & uploaded, URL:', resolvedMediaUrl);
                                } else {
                                    throw new Error(MEDIA_UPLOAD_DEFERRED);
                                }
                            } else {
                                // Chunked encryption not available (e.g. Expo Go), upload directly
                                chatStoreLog('[ChatStore] Chunked encrypt unavailable, uploading directly');
                                const uploadedUrl = await uploadMedia(
                                    fileUri,
                                    auth.userId,
                                    mediaCategory as 'image' | 'audio' | 'video' | 'file',
                                    (progress) => {
                                        get().setUploadProgress(msgId, 0.1 + (progress * 0.9));
                                    },
                                    uploadSignal,
                                );
                                if (uploadedUrl) {
                                    resolvedMediaUrl = uploadedUrl;
                                    metadata.mediaUrl = uploadedUrl;
                                    syncOptimisticMessagePatch({ mediaUrl: uploadedUrl, mediaKey });
                                    if (typeof originalLocalMediaUri === 'string' && originalLocalMediaUri.length > 0) {
                                        const originalUri = originalLocalMediaUri.startsWith('file://') ? originalLocalMediaUri : `file://${originalLocalMediaUri}`;
                                        useEncryptedMediaStore.getState().manuallyCacheFile(uploadedUrl, originalUri);
                                    }
                                } else {
                                    throw new Error(MEDIA_UPLOAD_DEFERRED);
                                }
                            }
                        } else {
                            // Small files: encrypt in memory (safe for <15MB)

                            // Step 0.5: HD thumbnail generation + SD compression (run in parallel where possible)
                            if (type === 'image' && metadata.hdMode) {
                                // HD mode: generate tiny thumbnail for instant preview on receiver
                                try {
                                    const thumb = await manipulateAsync(
                                        fileUri,
                                        [{ resize: { width: 400 } }],
                                        { compress: 0.6, format: SaveFormat.JPEG }
                                    );
                                    const thumbBase64 = await FileSystem.readAsStringAsync(thumb.uri, {
                                        encoding: FileSystem.EncodingType.Base64,
                                    });
                                    metadata.thumbnailBase64 = thumbBase64;
                                    FileSystem.deleteAsync(thumb.uri, { idempotent: true }).catch(() => { });
                                    chatStoreLog('[ChatStore] HD thumbnail generated:', Math.round(thumbBase64.length * 0.75 / 1024), 'KB');
                                } catch (thumbErr) {
                                    console.warn('[ChatStore] Thumbnail generation failed:', thumbErr);
                                }
                            } else if (type === 'image' && !metadata.hdMode) {
                                // SD mode: compress oversized images
                                try {
                                    const fileSizeKB = fileSizeBytes / 1024;
                                    if (fileSizeKB > 1024) {
                                        const maxDim = 2048;
                                        const compressed = await manipulateAsync(
                                            fileUri,
                                            [{ resize: { width: maxDim } }],
                                            { compress: 0.85, format: SaveFormat.JPEG }
                                        );
                                        chatStoreLog('[ChatStore] Image optimized:', Math.round(fileSizeKB), 'KB ->', compressed.uri);
                                        fileUri = compressed.uri;
                                    }
                                } catch (compErr) {
                                    console.warn('[ChatStore] Image optimization failed, using original:', compErr);
                                }
                            }

                            // Step 1: Read file as base64
                            const readableUri = await ensureReadableLocalUri(fileUri);
                            if (!readableUri) {
                                throw new Error(MEDIA_LOCAL_FILE_MISSING);
                            }
                            const fileBase64 = await FileSystem.readAsStringAsync(readableUri, {
                                encoding: FileSystem.EncodingType.Base64,
                            });
                            chatStoreLog('[ChatStore] File read, size:', Math.round(fileBase64.length * 0.75 / 1024), 'KB');
                            get().setUploadProgress(msgId, 0.15); // 15%

                            // Step 2: Encrypt the file data with AES-256-GCM (native QuickCrypto is fast)
                            const encResult = await encryptFileData(fileBase64);
                            mediaKey = encResult.keyBase64;
                            chatStoreLog('[ChatStore] File encrypted, key length:', mediaKey.length);
                            get().setUploadProgress(msgId, 0.25); // 25%

                            // Step 3: Write encrypted data to a temp file
                            const ext = type === 'image' ? 'jpg' : guessMediaExtension(resolvedMediaUrl, type);
                            const tempPath = `${FileSystem.cacheDirectory}encrypted_${Date.now()}.${ext}.enc`;
                            await FileSystem.writeAsStringAsync(tempPath, encResult.encryptedBase64, {
                                encoding: FileSystem.EncodingType.Base64,
                            });
                            get().setUploadProgress(msgId, 0.30); // 30% - Ready to upload

                            // Step 4: Upload the encrypted file
                            const uploadedUrl = await uploadMedia(
                                tempPath,
                                auth.userId,
                                mediaCategory as 'image' | 'audio' | 'video' | 'file',
                                (progress) => {
                                    // Map 0-1 to 0.3-1.0
                                    const activeProgress = 0.3 + (progress * 0.7);
                                    get().setUploadProgress(msgId, activeProgress);
                                },
                                uploadSignal,
                            );

                            // Clean up temp file
                            FileSystem.deleteAsync(tempPath, { idempotent: true }).catch(() => { });

                            if (uploadedUrl) {
                                resolvedMediaUrl = uploadedUrl;
                                metadata.mediaUrl = uploadedUrl;
                                syncOptimisticMessagePatch({ mediaUrl: uploadedUrl, mediaKey });

                                // Optimization: Map encrypted URL to original local file for sender display
                                if (typeof originalLocalMediaUri === 'string' && originalLocalMediaUri.length > 0) {
                                    const originalUri = originalLocalMediaUri.startsWith('file://') ? originalLocalMediaUri : `file://${originalLocalMediaUri}`;
                                    useEncryptedMediaStore.getState().manuallyCacheFile(uploadedUrl, originalUri);
                                }

                                chatStoreLog('[ChatStore] Encrypted media uploaded, URL:', resolvedMediaUrl);
                            } else {
                                throw new Error(MEDIA_UPLOAD_DEFERRED);
                            }
                        }

                    } catch (uploadErr) {
                        const uploadMessage = String((uploadErr as any)?.message || uploadErr || '').toLowerCase();
                        if (
                            uploadMessage.includes('not readable') ||
                            uploadMessage.includes('does not exist') ||
                            uploadMessage.includes('no such file') ||
                            uploadMessage.includes(MEDIA_LOCAL_FILE_MISSING.toLowerCase())
                        ) {
                            throw new Error(MEDIA_LOCAL_FILE_MISSING);
                        }
                        console.warn('[ChatStore] Media encrypt/upload deferred:', uploadErr);
                        throw uploadErr;
                    }
                }

                // 2. Background: Encrypt and send
                try {
                    const startTotal = Date.now();
                    chatStoreLog('[Timing] Background Send Process Start:', startTotal);

                    // Await the key fetch that was started in parallel with media processing
                    friendPublicKey = await keyFetchPromise;
                    if (friendPublicKey) {
                        chatStoreLog('[Timing] Public key ready (parallel fetch complete)');
                    }

                    if (!friendPublicKey) {
                        throw new Error('Could not get encryption key');
                    }

                    const startEncrypt = Date.now();
                    chatStoreLog('[Timing] Encrypt Start:', startEncrypt);

                    // Create full payload with metadata to encrypt
                    // Use the resolved (uploaded) URL, not the local file URI
                    // Include mediaKey so recipient can decrypt the file-level encryption
                    const fullPayload = JSON.stringify({
                        text: text,
                        mediaUrl: resolvedMediaUrl,
                        mediaKey: mediaKey, // AES-256-GCM key for file decryption (only present if file was encrypted)
                        fileName: metadata.fileName,
                        fileSize: metadata.fileSize,
                        latitude: metadata.latitude,
                        longitude: metadata.longitude,
                        duration: metadata.duration,
                        width: metadata.width,
                        height: metadata.height,
                        replyToId: metadata.replyToId,
                        contact: metadata.contact,
                        caption: metadata.caption,
                        thumbnailBase64: metadata.thumbnailBase64,
                        viewOnce: metadata.viewOnce || undefined,
                        isVideoNote: metadata.isVideoNote || undefined,
                        waveform: metadata.waveform || undefined,
                    });

                    // Import and encrypt
                    const importedKey = await importPublicKey(friendPublicKey);
                    const encrypted = await encryptMessageNativeFirst({
                        recipientPublicKey: importedKey,
                        message: fullPayload,
                        myPublicKey: auth.keyPair?.publicKey,
                    });

                    const endEncrypt = Date.now();
                    chatStoreLog('[Timing] Encrypt Done:', endEncrypt, 'Duration:', endEncrypt - startEncrypt, 'ms');

                    // Update message with encrypted content
                    const currentChats = get().chats;
                    const updatedIndex = currentChats.findIndex(c => c.chatId === chatId);
                    if (updatedIndex > -1) {
                        const newChats = [...currentChats];
                        newChats[updatedIndex] = {
                            ...newChats[updatedIndex],
                            messages: newChats[updatedIndex].messages.map(m =>
                                m.id === msgId
                                    ? {
                                        ...m,
                                        encryptedContent: encrypted,
                                        mediaUrl: resolvedMediaUrl || m.mediaUrl,
                                        mediaKey: mediaKey || m.mediaKey,
                                        errorMessage: undefined,
                                        status: (m.status === 'pending' ? 'pending' : 'sending') as Message['status'],
                                    }
                                    : m
                            )
                        };
                        set({ chats: newChats });
                    }

                    // Send via Channel
                    let channel = chatChannels.get(chatId);
                    let ephemeralChannel: Channel | null = null;
                    if (!channel) {
                        ephemeralChannel = await tryOpenDirectChatChannel(chatId);
                        if (ephemeralChannel) {
                            channel = ephemeralChannel;
                        }
                    }
                    if (channel) {
                        const sendChannel = channel;
                        const isEphemeralChannel = sendChannel === ephemeralChannel;
                        const releaseEphemeralChannel = () => {
                            if (!isEphemeralChannel) return;
                            try { sendChannel.leave(); } catch { /* ignore */ }
                        };
                        const payload = {
                            pushPreview: (() => {
                                const trimmed = (typeof text === 'string' ? text.trim() : '');
                                if (trimmed.length > 0) {
                                    return trimmed.length > 160 ? `${trimmed.slice(0, 159)}…` : trimmed;
                                }
                                switch (type) {
                                    case 'image':
                                        return 'Photo';
                                    case 'video':
                                        return 'Video';
                                    case 'voice':
                                        return 'Voice message';
                                    case 'music':
                                        return 'Audio';
                                    case 'file':
                                        return 'File';
                                    case 'location':
                                        return 'Location';
                                    case 'contact':
                                        return 'Contact';
                                    case 'gif':
                                        return 'GIF';
                                    default:
                                        return '';
                                }
                            })(),
                            id: msgId,
                            fromId: auth.userId,
                            encryptedContent: encrypted,
                            timestamp: now,
                            type: type,
                            // SECURITY: Don't send metadata in plaintext! (Keep inside encryptedContent)
                            // We send null to server to avoid leaking it in DB
                            mediaUrl: null,
                            fileName: null,
                            latitude: null,
                            longitude: null
                        };
                        chatStoreLog('[ChatStore] Sending message payload meta:', {
                            id: payload.id,
                            type: payload.type,
                            timestamp: payload.timestamp,
                        });
                        const startPush = Date.now();

                        // Pre-register msgId in dedup set so server echo is ignored
                        recentlyProcessedMsgIds.add(msgId);
                        setTimeout(() => recentlyProcessedMsgIds.delete(msgId), 10000);

                        const nativeSendAccepted = await tryNativeChatEngineSendEncryptedMessage(chatId, msgId, payload as Record<string, unknown>);
                        if (nativeSendAccepted) {
                            releaseEphemeralChannel();
                            get().clearUploadProgress(msgId);
                            chatStoreLog('[ChatStore] Native ChatEngine send accepted', { chatId, msgId });
                            SoundManager.play('sent');

                            const { offlineQueue } = get();
                            if (offlineQueue.some((m) => m.id === msgId)) {
                                set({ offlineQueue: offlineQueue.filter((m) => m.id !== msgId) });
                            }

                            const latestChats = get().chats;
                            const idx = latestChats.findIndex(c => c.chatId === chatId);
                            if (idx > -1) {
                                const updated = [...latestChats];
                                updated[idx] = {
                                    ...updated[idx],
                                    messages: updated[idx].messages.map(m =>
                                        m.id === msgId ? { ...m, status: 'sent' as const } : m
                                    )
                                };
                                set({ chats: updated });
                            }
                            return;
                        }

                        // Play sent sound immediately (optimistic) for JS transport fallback.
                        SoundManager.play('sent');

                        sendChannel.push("message", payload).receive("ok", () => {
                            releaseEphemeralChannel();
                            get().clearUploadProgress(msgId);
                            const ackTime = Date.now();
                            chatStoreLog('[Timing] Channel Ack received:', ackTime, 'Latency:', ackTime - startPush, 'ms');
                            const { offlineQueue } = get();
                            if (offlineQueue.some((m) => m.id === msgId)) {
                                set({ offlineQueue: offlineQueue.filter((m) => m.id !== msgId) });
                            }

                            // Update status to SENT (Single Check)
                            const latestChats = get().chats;
                            const idx = latestChats.findIndex(c => c.chatId === chatId);
                            if (idx > -1) {
                                const updated = [...latestChats];
                                updated[idx] = {
                                    ...updated[idx],
                                    messages: updated[idx].messages.map(m =>
                                        m.id === msgId ? { ...m, status: 'sent' as const } : m
                                    )
                                };
                                set({ chats: updated });
                            }
                        }).receive("error", (err: any) => {
                            releaseEphemeralChannel();
                            console.error('[ChatStore] Channel push ERROR', {
                                msgId,
                                chatId,
                                error: String(err),
                                reason: err?.reason,
                                latency: Date.now() - startPush,
                            });
                            get().clearUploadProgress(msgId);
                            console.error('[ChatStore] Message send failed:', err);
                            const reason = String(err?.reason || '').toLowerCase();
                            const transient =
                                !get().isConnected ||
                                isRecoverableSendError(err) ||
                                reason === 'closed' ||
                                reason === 'timeout' ||
                                reason === 'transport_close';
                            chatStoreMessageLog('send:pushError', {
                                chatId,
                                messageId: msgId,
                                reason,
                                transient,
                                connected: get().isConnected,
                            });
                            // Keep transient transport failures pending for auto-retry.
                            const latestChats = get().chats;
                            const idx = latestChats.findIndex(c => c.chatId === chatId);
                            if (idx > -1) {
                                const updated = [...latestChats];
                                const nextStatus = transient ? 'pending' : 'error';
                                updated[idx] = {
                                    ...updated[idx],
                                    messages: updated[idx].messages.map(m =>
                                        m.id === msgId ? { ...m, status: nextStatus } : m
                                    )
                                };
                                set({ chats: updated });
                            }
                            if (transient) {
                                const { offlineQueue } = get();
                                const retryMessage = get().chats
                                    .find(c => c.chatId === chatId)
                                    ?.messages.find(m => m.id === msgId);
                                if (retryMessage) {
                                    const queueMap = new Map<string, Message>();
                                    offlineQueue.forEach((m) => queueMap.set(m.id, m));
                                    queueMap.set(msgId, { ...retryMessage, status: 'pending' });
                                    set({ offlineQueue: Array.from(queueMap.values()) });
                                }
                                if (get().isConnected) {
                                    scheduleChannelResync(get, 180);
                                    scheduleChatRetryFlush(chatId, get, 1200);
                                }
                            }
                        }).receive("timeout", () => {
                            releaseEphemeralChannel();
                            get().clearUploadProgress(msgId);
                            chatStoreLog('[ChatStore] Message send timed out:', msgId);
                            // Timeout is treated as transient network/channel failure.
                            const latestChats = get().chats;
                            const idx = latestChats.findIndex(c => c.chatId === chatId);
                            if (idx > -1) {
                                const updated = [...latestChats];
                                updated[idx] = {
                                    ...updated[idx],
                                    messages: updated[idx].messages.map(m =>
                                        m.id === msgId ? { ...m, status: 'pending' as const } : m
                                    )
                                };
                                set({ chats: updated });
                            }
                            const retryMessage = get().chats
                                .find(c => c.chatId === chatId)
                                ?.messages.find(m => m.id === msgId);
                            if (retryMessage) {
                                const { offlineQueue } = get();
                                const queueMap = new Map<string, Message>();
                                offlineQueue.forEach((m) => queueMap.set(m.id, m));
                                queueMap.set(msgId, { ...retryMessage, status: 'pending' });
                                set({ offlineQueue: Array.from(queueMap.values()) });
                            }
                            if (get().isConnected) {
                                scheduleChannelResync(get, 180);
                                scheduleChatRetryFlush(chatId, get, 1200);
                            }
                        });
                    } else {
                        chatStoreLog('[ChatStore] No channel for chat:', chatId);
                        // No channel available — queue as pending for reconnect auto-retry.
                        const latestChats = get().chats;
                        const idx = latestChats.findIndex(c => c.chatId === chatId);
                        if (idx > -1) {
                            const updated = [...latestChats];
                            updated[idx] = {
                                ...updated[idx],
                                messages: updated[idx].messages.map(m =>
                                    m.id === msgId ? { ...m, status: 'pending' as const } : m
                                )
                            };
                            set({ chats: updated });
                        }
                        const retryMessage = get().chats
                            .find(c => c.chatId === chatId)
                            ?.messages.find(m => m.id === msgId);
                        if (retryMessage) {
                            const { offlineQueue } = get();
                            const queueMap = new Map<string, Message>();
                            offlineQueue.forEach((m) => queueMap.set(m.id, m));
                            queueMap.set(msgId, { ...retryMessage, status: 'pending' });
                            set({ offlineQueue: Array.from(queueMap.values()) });
                        }
                        if (get().isConnected) {
                            scheduleChannelResync(get, 160);
                            scheduleChatRetryFlush(chatId, get, 1100);
                        }
                    }
                } catch (e: any) {
                    get().clearUploadProgress(msgId);
                    // If user cancelled, the message was already removed by cancelUpload — skip error marking
                    if (e?.message === 'Upload cancelled') {
                        chatStoreLog('[ChatStore] Upload cancelled by user:', msgId);
                        return;
                    }
                    const errorMessage = String(e?.message || e || '');
                    const localFileMissing = errorMessage.includes(MEDIA_LOCAL_FILE_MISSING);
                    const transient = !localFileMissing && (!get().isConnected || isRecoverableSendError(e));
                    if (transient) {
                        console.warn('[ChatStore] sendMessage deferred (pending):', e?.message || e);
                    } else if (localFileMissing) {
                        console.warn('[ChatStore] sendMessage failed: missing local media file', { msgId, chatId });
                    } else {
                        console.error('[ChatStore] sendMessage error:', e);
                    }
                    // Update message status based on failure type
                    const currentChats = get().chats;
                    const idx = currentChats.findIndex(c => c.chatId === chatId);
                    if (idx > -1) {
                        const newChats = [...currentChats];
                        const nextStatus = transient ? 'pending' : 'error';
                        newChats[idx] = {
                            ...newChats[idx],
                            messages: newChats[idx].messages.map(m =>
                                m.id === msgId
                                    ? {
                                        ...m,
                                        status: nextStatus,
                                        errorMessage: localFileMissing
                                            ? LOCAL_MEDIA_MISSING_USER_MESSAGE
                                            : m.errorMessage,
                                    }
                                    : m
                            )
                        };
                        set({ chats: newChats });
                    }
                    if (transient) {
                        const retryMessage = get().chats
                            .find(c => c.chatId === chatId)
                            ?.messages.find(m => m.id === msgId);
                        if (retryMessage) {
                            const { offlineQueue } = get();
                            const queueMap = new Map<string, Message>();
                            offlineQueue.forEach((m) => queueMap.set(m.id, m));
                            queueMap.set(msgId, { ...retryMessage, status: 'pending' });
                            set({ offlineQueue: Array.from(queueMap.values()) });
                        }
                        if (get().isConnected) {
                            scheduleChannelResync(get, 180);
                            scheduleChatRetryFlush(chatId, get, 1200);
                        }
                    }
                }
            },

            setActiveChat: (id) => set({ activeChatId: id }),

            loadMessages: async (chatId) => {
                const loadStartTs = Date.now();
                const inFlight = historyLoadInFlight.get(chatId);
                if (inFlight) {
                    chatStoreHistoryPerfLog('loadMessages:join-inflight', { chatId, dt: Date.now() - loadStartTs });
                    await inFlight;
                    return;
                }

                const cachedChat = get().chats.find((c) => c.chatId === chatId);
                const cachedCount = Array.isArray(cachedChat?.messages) ? cachedChat!.messages.length : 0;
                if (cachedCount > 0) {
                    if (__DEV__) {
                        chatStoreLog('[ChatStore][HistoryDebug] loadMessages executing (previously skipped cache-first)', {
                            chatId,
                            cachedCount,
                        });
                    }
                }

                const run = (async () => {
                    const runStartTs = Date.now();
                    const proxy = ProxyManager.getInstance();
                    const baseUrl = proxy.getBestUrl();
                    const auth = AuthManager.getInstance().getSession();

                    try {
                        const fetchStartTs = Date.now();
                        const res = await fetch(`${baseUrl}/api/chat/${chatId}/messages`, {
                            headers: {
                                'ngrok-skip-browser-warning': 'true',
                                ...buildAuthHeaders(auth),
                            }
                        });
                        chatStoreHistoryPerfLog('loadMessages:fetch:done', {
                            chatId,
                            status: res.status,
                            fetchDt: Date.now() - fetchStartTs,
                            totalDt: Date.now() - runStartTs,
                        });

                        if (!res.ok) {
                            const body = await res.text().catch(() => '');
                            throw new Error(`HTTP ${res.status}${body ? `: ${body.slice(0, 180)}` : ''}`);
                        }
                        const jsonStartTs = Date.now();
                        const messages = await res.json();
                        chatStoreHistoryPerfLog('loadMessages:json:done', {
                            chatId,
                            count: Array.isArray(messages) ? messages.length : -1,
                            jsonDt: Date.now() - jsonStartTs,
                            totalDt: Date.now() - runStartTs,
                        });
                        if (!Array.isArray(messages)) {
                            console.warn('[ChatStore][HistoryDebug] loadMessages returned non-array payload', {
                                chatId,
                                payloadType: typeof messages,
                            });
                            return;
                        }

                        if (__DEV__) {
                            const unresolvedTextCount = messages.filter((m: any) => {
                                const type = (m?.type || 'text');
                                if (type !== 'text') return false;
                                const text = m?.plaintext || m?.content || m?.text || '';
                                return !(typeof text === 'string' && text.trim().length > 0);
                            }).length;
                            const encryptedCount = messages.filter((m: any) => !!(m?.encryptedContent || m?.encrypted_content)).length;
                            chatStoreLog('[ChatStore][HistoryDebug] loadMessages fetched from API', {
                                chatId,
                                fetchedCount: messages.length,
                                encryptedCount,
                                unresolvedTextCount,
                                sample: messages.slice(0, 6).map((m: any) => ({
                                    id: m?.id,
                                    type: m?.type,
                                    status: m?.status,
                                    hasEncryptedContent: !!(m?.encryptedContent || m?.encrypted_content),
                                    hasPlaintext: typeof m?.plaintext === 'string' && m.plaintext.trim().length > 0,
                                    hasContentField: typeof m?.content === 'string' && m.content.trim().length > 0,
                                    hasTextField: typeof m?.text === 'string' && m.text.trim().length > 0,
                                })),
                            });
                        }

                        // MERGE messages: keep local messages that aren't on server, add server messages
                        const { chats } = get();
                        const chatIndex = chats.findIndex(c => c.chatId === chatId);
                        if (chatIndex > -1) {
                            const mergeStartTs = Date.now();
                            const existingMessages = chats[chatIndex].messages;
                            const serverMsgMap = new Map<string, any>();

                            // Map server messages by ID
                            messages.forEach((m: any) => {
                                serverMsgMap.set(m.id, {
                                    id: m.id,
                                    fromId: m.fromId || m.from_id,
                                    chatId: chatId,
                                    encryptedContent: m.encryptedContent || m.encrypted_content,
                                    type: m.type || 'text',
                                    timestamp: m.timestamp,
                                    plaintext: undefined,
                                    status: m.status || 'delivered'
                                });
                            });

                            // Merge: prioritize local messages (they may have plaintext), add new server messages
                            const mergedMessages: Message[] = [];
                            const seenIds = new Set<string>();

                            // First, add all existing local messages (preserves plaintext decryption)
                            existingMessages.forEach(msg => {
                                const serverMsg = serverMsgMap.get(msg.id);
                                if (serverMsg) {
                                    mergedMessages.push({
                                        ...serverMsg,
                                        ...msg,
                                        status: chooseMostAdvancedStatus(msg.status, serverMsg.status),
                                        timestamp: msg.timestamp ?? serverMsg.timestamp,
                                    });
                                } else {
                                    mergedMessages.push(msg);
                                }
                                seenIds.add(msg.id);
                            });

                            // Then add server messages that don't exist locally
                            const newServerMessages: Message[] = [];
                            serverMsgMap.forEach((msg, id) => {
                                if (!seenIds.has(id)) {
                                    newServerMessages.push(msg);
                                }
                            });

                            if (newServerMessages.length > 0 && auth?.keyPair?.privateKey) {
                                try {
                                    const decryptStartTs = Date.now();
                                    const itemsToDecrypt = newServerMessages
                                        .filter(m => m.encryptedContent)
                                        .map(m => ({
                                            id: m.id,
                                            encryptedContent: m.encryptedContent!,
                                            isFromMe: (m.fromId || '').toUpperCase() === (auth.userId || '').toUpperCase()
                                        }));

                                    if (itemsToDecrypt.length > 0) {
                                        const decryptedBatch = await decryptMessagesBatch({
                                            privateKey: auth.keyPair.privateKey,
                                            items: itemsToDecrypt
                                        });
                                        newServerMessages.forEach(msg => {
                                            if (decryptedBatch.messages[msg.id]) {
                                                const parsed = parseDecryptedContent(decryptedBatch.messages[msg.id]);
                                                Object.assign(msg, parsed);
                                            }
                                        });
                                    }
                                    chatStoreHistoryPerfLog('loadMessages:decrypt:newServerMessages', {
                                        chatId,
                                        newServerMessages: newServerMessages.length,
                                        decryptCandidates: itemsToDecrypt.length,
                                        decryptDt: Date.now() - decryptStartTs,
                                        totalDt: Date.now() - runStartTs,
                                    });
                                } catch (e) {
                                    console.warn('[ChatStore] bulk decryption failed in loadMessages', e);
                                }
                            }

                            mergedMessages.push(...newServerMessages);

                            // Sort by timestamp
                            mergedMessages.sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));

                            const updatedChats = [...chats];
                            updatedChats[chatIndex] = {
                                ...updatedChats[chatIndex],
                                messages: mergedMessages
                            };
                            if (__DEV__) {
                                const mergedUnresolvedTextCount = mergedMessages.filter((m: any) => {
                                    const type = (m?.type || 'text');
                                    if (type !== 'text') return false;
                                    const text = m?.plaintext || m?.content || m?.text || '';
                                    return !(typeof text === 'string' && text.trim().length > 0);
                                }).length;
                                chatStoreLog('[ChatStore][HistoryDebug] loadMessages merged into store', {
                                    chatId,
                                    localCountBeforeMerge: existingMessages.length,
                                    serverCount: messages.length,
                                    mergedCount: mergedMessages.length,
                                    mergedUnresolvedTextCount,
                                    mergedSample: mergedMessages.slice(0, 6).map((m: any) => ({
                                        id: m?.id,
                                        type: m?.type,
                                        status: m?.status,
                                        hasEncryptedContent: !!m?.encryptedContent,
                                        hasPlaintext: typeof m?.plaintext === 'string' && m.plaintext.trim().length > 0,
                                    })),
                                });
                            }
                            const setStartTs = Date.now();
                            set({ chats: updatedChats });
                            chatStoreHistoryPerfLog('loadMessages:merge+set:done', {
                                chatId,
                                existingMessages: existingMessages.length,
                                serverMessages: messages.length,
                                newServerMessages: newServerMessages.length,
                                mergedMessages: mergedMessages.length,
                                mergeDt: Date.now() - mergeStartTs,
                                setDt: Date.now() - setStartTs,
                                totalDt: Date.now() - runStartTs,
                            });
                        }
                        chatStoreHistoryPerfLog('loadMessages:done', { chatId, totalDt: Date.now() - runStartTs });
                    } catch (e) {
                        chatStoreHistoryPerfLog('loadMessages:error', {
                            chatId,
                            totalDt: Date.now() - runStartTs,
                            error: String((e as any)?.message || e),
                        });
                        console.error('[ChatStore] Load messages failed:', e);
                    }
                })();

                historyLoadInFlight.set(chatId, run);
                try {
                    await run;
                } finally {
                    historyLoadInFlight.delete(chatId);
                }
            },

            updateMessageDecryption: (chatId, messageId, plaintext) => {
                const { chats } = get();
                const chatIndex = chats.findIndex(c => c.chatId === chatId);
                if (chatIndex === -1) return;

                const msgIndex = chats[chatIndex].messages.findIndex(m => m.id === messageId);
                if (msgIndex === -1) return;

                // Create new array references to trigger re-render
                const updatedChats = [...chats];
                const updatedMessages = [...updatedChats[chatIndex].messages];

                // Parse plaintext which might be JSON
                const parsed = parseDecryptedContent(plaintext);

                updatedMessages[msgIndex] = {
                    ...updatedMessages[msgIndex],
                    ...parsed
                };
                updatedChats[chatIndex] = {
                    ...updatedChats[chatIndex],
                    messages: updatedMessages
                };

                set({ chats: updatedChats });
            },

            batchUpdateDecryption: (chatId, updates) => {
                const { chats } = get();
                const chatIndex = chats.findIndex(c => c.chatId === chatId);
                if (chatIndex === -1) return;

                // Update all messages in a single state update
                const updatedChats = [...chats];
                const updatedMessages = chats[chatIndex].messages.map(m => {
                    if (Object.prototype.hasOwnProperty.call(updates, m.id)) {
                        const decrypted = updates[m.id];
                        const parsed = parseDecryptedContent(decrypted);
                        return { ...m, ...parsed };
                    }
                    return m;
                });

                updatedChats[chatIndex] = {
                    ...updatedChats[chatIndex],
                    messages: updatedMessages
                };

                set({ chats: updatedChats });
            },
            sendTyping: (chatId) => {
                const auth = AuthManager.getInstance().getSession();
                chatChannels.get(chatId)?.push("typing", { userId: auth?.userId || "me" });
            },
            sendStopTyping: (chatId: string) => {
                // Check local chat exists first?
                if (chatChannels.has(chatId)) {
                    const auth = AuthManager.getInstance().getSession();
                    const channel = chatChannels.get(chatId);
                    chatStoreLog('[ChatStore] Sending stop-typing for:', auth?.userId);
                    channel?.push("stop-typing", { userId: auth?.userId || "me" });
                }
            },

            sendRecording: (chatId: string) => {
                if (chatChannels.has(chatId)) {
                    const auth = AuthManager.getInstance().getSession();
                    const channel = chatChannels.get(chatId);
                    chatStoreLog('[ChatStore] Sending recording for:', auth?.userId);
                    channel?.push("recording", { userId: auth?.userId || "me" });
                }
            },

            sendStopRecording: (chatId: string) => {
                if (chatChannels.has(chatId)) {
                    const auth = AuthManager.getInstance().getSession();
                    const channel = chatChannels.get(chatId);
                    chatStoreLog('[ChatStore] Sending stop-recording for:', auth?.userId);
                    channel?.push("stop-recording", { userId: auth?.userId || "me" });
                }
            },

            sendReadReceipt: (chatId, messageId) => {
                if (!isValidBinaryId(messageId)) return;
                const channel = chatChannels.get(chatId);
                void (async () => {
                    const nativeAccepted = await tryNativeChatEngineReceiptPush('sendReadReceipt', chatId, messageId);
                    if (!nativeAccepted && channel) {
                        channel.push("read-receipt", { messageId });
                        mirrorChatEngineReadReceiptPush(chatId, messageId);
                    }
                })();

                // Update local status immediately to prevent duplicate requests
                const { chats } = get();
                const chatIdx = chats.findIndex(c => c.chatId === chatId);
                if (chatIdx > -1) {
                    const messages = chats[chatIdx].messages;
                    const msgIdx = messages.findIndex(m => m.id === messageId);

                    if (msgIdx > -1 && messages[msgIdx].status !== 'read') {
                        const updatedChats = [...chats];
                        const updatedMessages = [...messages];

                        updatedMessages[msgIdx] = {
                            ...updatedMessages[msgIdx],
                            status: 'read'
                        };

                        updatedChats[chatIdx] = {
                            ...updatedChats[chatIdx],
                            messages: updatedMessages,
                            // Decrement unread count if > 0
                            unreadCount: Math.max(0, (updatedChats[chatIdx].unreadCount || 0) - 1)
                        };

                        set({ chats: updatedChats });
                    }
                }
            },

            sendDeliveryReceipt: (chatId, messageId) => {
                if (!isValidBinaryId(messageId)) return;
                const channel = chatChannels.get(chatId);
                void (async () => {
                    const nativeAccepted = await tryNativeChatEngineReceiptPush('sendDeliveryReceipt', chatId, messageId);
                    if (!nativeAccepted && channel) {
                        channel.push("delivery-receipt", { messageId });
                        mirrorChatEngineDeliveryReceiptPush(chatId, messageId);
                    }
                })();
            },

            deleteChat: async (chatId) => {
                const { chats } = get();

                // Leave the channel first
                const channel = chatChannels.get(chatId);
                if (channel) {
                    channel.leave();
                    chatChannels.delete(chatId);
                }

                // Remove from local state immediately (optimistic update)
                set({ chats: chats.filter(c => c.chatId !== chatId) });

                // Also delete from server
                try {
                    const auth = AuthManager.getInstance().getSession();
                    if (auth) {
                        const proxy = ProxyManager.getInstance();
                        const baseUrl = proxy.getBestUrl();
                        await fetch(`${baseUrl}/api/chats/${chatId}`, {
                            method: 'DELETE',
                            headers: buildAuthHeaders(auth, {
                                'Content-Type': 'application/json',
                            }),
                        });
                        chatStoreLog('[ChatStore] Chat deleted from server:', chatId);
                    }
                } catch (e) {
                    console.warn('[ChatStore] Failed to delete chat from server:', e);
                    // The local delete already happened, server sync will happen on next load
                }
            },

            pinChat: async (chatId) => {
                const { chats } = get();
                const chat = chats.find(c => c.chatId === chatId);
                if (!chat) return;

                const newPinnedStatus = !chat.pinned;

                // Update locally first (optimistic)
                const updatedChats = chats.map(c =>
                    c.chatId === chatId ? { ...c, pinned: newPinnedStatus } : c
                );
                // Sort: pinned chats first, then by last message time
                updatedChats.sort((a, b) => {
                    if (a.pinned && !b.pinned) return -1;
                    if (!a.pinned && b.pinned) return 1;
                    return (b.lastMessage?.timestamp || 0) - (a.lastMessage?.timestamp || 0);
                });
                set({ chats: updatedChats });

                // Persist to server
                try {
                    const auth = AuthManager.getInstance().getSession();
                    if (auth) {
                        const proxy = ProxyManager.getInstance();
                        const baseUrl = proxy.getBestUrl();
                        await fetch(`${baseUrl}/api/chat/${chatId}/pin`, {
                            method: 'POST',
                            headers: buildAuthHeaders(auth, {
                                'Content-Type': 'application/json',
                            }),
                            body: JSON.stringify({ userId: auth.userId, pinned: newPinnedStatus })
                        });
                    }
                } catch (e) {
                    console.warn('[ChatStore] Failed to pin chat on server:', e);
                }
            },

            toggleMuteChat: async (chatId) => {
                const { chats } = get();
                const chat = chats.find(c => c.chatId === chatId);
                if (!chat) return;

                const newMutedStatus = !chat.muted;

                // Update locally
                set({
                    chats: chats.map(c =>
                        c.chatId === chatId ? { ...c, muted: newMutedStatus } : c
                    )
                });

                // Persist to server
                try {
                    const auth = AuthManager.getInstance().getSession();
                    if (auth) {
                        const proxy = ProxyManager.getInstance();
                        const baseUrl = proxy.getBestUrl();
                        await fetch(`${baseUrl}/api/chat/${chatId}/mute`, {
                            method: 'POST',
                            headers: buildAuthHeaders(auth, {
                                'Content-Type': 'application/json',
                            }),
                            body: JSON.stringify({ userId: auth.userId, muted: newMutedStatus })
                        });
                    }
                } catch (e) {
                    console.warn('[ChatStore] Failed to mute chat on server:', e);
                }
            },

            toggleMarkUnread: (chatId, forceStatus) => {
                const { chats } = get();
                set({
                    chats: chats.map(c =>
                        c.chatId === chatId
                            ? { ...c, markedUnread: forceStatus !== undefined ? forceStatus : !c.markedUnread }
                            : c
                    )
                });
            },

            updateChatFriendInfoByFriendId: (friendId, info) => {
                const normalizedFriendId = (friendId || '').toUpperCase();
                set((state) => {
                    let changed = false;
                    const updated = state.chats.map((c) => {
                        if (!c.friendId) return c;
                        if ((c.friendId || '').toUpperCase() !== normalizedFriendId) return c;

                        const next = {
                            ...c,
                            friendName: info.friendName ?? c.friendName,
                            friendImage: info.friendImage ?? c.friendImage,
                        };
                        if (next.friendName !== c.friendName || next.friendImage !== c.friendImage) changed = true;
                        return next;
                    });
                    return changed ? { ...state, chats: updated } : state;
                });
            },

            // ── Groups & Channels ────────────────────────────

            createGroup: async (name, memberIds) => {
                const auth = AuthManager.getInstance().getSession();
                if (!auth) return null;

                try {
                    const normalizedCreatorId = (auth.userId || '').trim().toUpperCase();
                    const normalizedMemberIds = Array.from(
                        new Set(
                            (memberIds || [])
                                .map((memberId) => (memberId || '').trim())
                                .filter((memberId) => memberId.length > 0 && memberId.toUpperCase() !== normalizedCreatorId)
                        )
                    );
                    if (normalizedMemberIds.length === 0) {
                        return null;
                    }

                    const { apiClient } = await import('./api-client');
                    const result = await apiClient.createGroup(auth.userId, name, normalizedMemberIds);
                    if (result.chatId) {
                        await get().loadChats();
                        return result.chatId;
                    }
                    return null;
                } catch (e) {
                    console.error('[ChatStore] createGroup failed:', e);
                    return null;
                }
            },

            createChannel: async (name, description) => {
                const auth = AuthManager.getInstance().getSession();
                if (!auth) return null;

                try {
                    const { apiClient } = await import('./api-client');
                    const result = await apiClient.createChannel(auth.userId, name, description);
                    if (result.chatId) {
                        await get().loadChats();
                        return result.chatId;
                    }
                    return null;
                } catch (e) {
                    console.error('[ChatStore] createChannel failed:', e);
                    return null;
                }
            },

            joinChannel: async (channelId) => {
                const auth = AuthManager.getInstance().getSession();
                if (!auth) return false;

                try {
                    const { apiClient } = await import('./api-client');
                    const result = await apiClient.joinChannel(channelId, auth.userId);
                    if (result.success) {
                        await get().loadChats();
                        return true;
                    }
                    return false;
                } catch (e) {
                    console.error('[ChatStore] joinChannel failed:', e);
                    return false;
                }
            },

            leaveChannel: async (channelId) => {
                const auth = AuthManager.getInstance().getSession();
                if (!auth) return false;

                try {
                    const { apiClient } = await import('./api-client');
                    const result = await apiClient.leaveChannel(channelId, auth.userId);
                    if (result.success) {
                        set({ chats: get().chats.filter(c => c.chatId !== channelId) });
                        return true;
                    }
                    return false;
                } catch (e) {
                    console.error('[ChatStore] leaveChannel failed:', e);
                    return false;
                }
            },


        }),
        {
            name: 'vibe-chat-store',
            storage: createJSONStorage(() => AsyncStorage),
            // Only persist chats and activeChatId, exclude transient state
            partialize: (state) => ({
                chats: state.chats,
                activeChatId: state.activeChatId,
            }),
            // Merge persisted state with initial state
            merge: (persistedState, currentState) => ({
                ...currentState,
                ...(persistedState as Partial<ChatState>),
            }),
            // Called when store is rehydrated from storage
            onRehydrateStorage: () => {
                chatStoreLog('[ChatStore] Starting hydration from storage...');
                return (state, error) => {
                    if (error) {
                        console.error('[ChatStore] Hydration error:', error);
                    } else {
                        chatStoreLog('[ChatStore] Hydration complete. Chats:', state?.chats?.length || 0);
                        // Messages have encryptedContent but no plaintext after hydration
                        // The UI will handle decryption when messages are rendered
                    }
                };
            },
        }
    )
);

// Debug subscription - log when chats change
if (__DEV__ && CHATSTORE_DEBUG) {
    useChatStore.subscribe(
        (state, prevState) => {
            if (state.chats !== prevState.chats) {
                const chatId = state.activeChatId;
                const chat = chatId ? state.chats.find(c => c.chatId === chatId) : null;
                chatStoreLog('[ChatStore] State changed! Active chat messages:', chat?.messages?.length || 0);
            }
        }
    );
}
