import CommonCrypto
import CryptoKit
import ExpoModulesCore
import Foundation
import Security

private struct HybridPayload: Decodable {
  let v: Int?
  let iv: String
  let c: String
  let k: String?
  let s: String?
  let g: String?
}

private struct PEMDecodeResult {
  let data: Data?
  let label: String
  let hadEscapedNewlines: Bool
  let inputLength: Int
  let normalizedLength: Int
  let base64Length: Int
}

private func pemLabel(from value: String) -> String {
  guard
    let regex = try? NSRegularExpression(pattern: "-----BEGIN ([^-]+)-----"),
    let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
    let labelRange = Range(match.range(at: 1), in: value)
  else {
    return "unknown"
  }
  return String(value[labelRange])
}

private func readDERLength(bytes: [UInt8], offset: inout Int) -> Int? {
  guard offset < bytes.count else { return nil }
  let first = Int(bytes[offset])
  offset += 1
  if (first & 0x80) == 0 {
    return first
  }
  let lengthByteCount = first & 0x7f
  guard lengthByteCount > 0, lengthByteCount <= 4 else { return nil }
  guard offset + lengthByteCount <= bytes.count else { return nil }
  var value = 0
  for _ in 0..<lengthByteCount {
    value = (value << 8) | Int(bytes[offset])
    offset += 1
  }
  return value
}

private func extractPKCS1FromPKCS8(_ data: Data) -> Data? {
  let bytes = [UInt8](data)
  var offset = 0

  // PrivateKeyInfo ::= SEQUENCE
  guard offset < bytes.count, bytes[offset] == 0x30 else { return nil }
  offset += 1
  guard let seqLength = readDERLength(bytes: bytes, offset: &offset) else { return nil }
  let seqEnd = offset + seqLength
  guard seqEnd <= bytes.count else { return nil }

  // version INTEGER
  guard offset < seqEnd, bytes[offset] == 0x02 else { return nil }
  offset += 1
  guard let versionLength = readDERLength(bytes: bytes, offset: &offset) else { return nil }
  offset += versionLength
  guard offset <= seqEnd else { return nil }

  // algorithm identifier SEQUENCE
  guard offset < seqEnd, bytes[offset] == 0x30 else { return nil }
  offset += 1
  guard let algorithmLength = readDERLength(bytes: bytes, offset: &offset) else { return nil }
  offset += algorithmLength
  guard offset <= seqEnd else { return nil }

  // privateKey OCTET STRING (this is PKCS#1 bytes for RSA)
  guard offset < seqEnd, bytes[offset] == 0x04 else { return nil }
  offset += 1
  guard let privateKeyLength = readDERLength(bytes: bytes, offset: &offset) else { return nil }
  let keyStart = offset
  let keyEnd = keyStart + privateKeyLength
  guard keyEnd <= seqEnd else { return nil }
  return data.subdata(in: keyStart..<keyEnd)
}

private func decodePEM(_ pem: String) -> PEMDecodeResult {
  let hadEscapedNewlines = pem.contains("\\n") || pem.contains("\\r")
  let normalized =
    pem
    .replacingOccurrences(of: "\\r\\n", with: "\n")
    .replacingOccurrences(of: "\\n", with: "\n")
    .replacingOccurrences(of: "\\r", with: "\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let label = pemLabel(from: normalized)

  let withoutHeaders =
    normalized
    .replacingOccurrences(of: "-----BEGIN [^-]+-----", with: "", options: .regularExpression)
    .replacingOccurrences(of: "-----END [^-]+-----", with: "", options: .regularExpression)
  let sanitized = withoutHeaders

  // Use .ignoreUnknownCharacters so whitespace/newlines in the base64 body
  // are silently skipped — Data(base64Encoded:) rejects them by default.
  return PEMDecodeResult(
    data: Data(base64Encoded: sanitized, options: .ignoreUnknownCharacters),
    label: label,
    hadEscapedNewlines: hadEscapedNewlines,
    inputLength: pem.count,
    normalizedLength: normalized.count,
    base64Length: sanitized.count
  )
}

private func secKeyFromData(_ keyData: Data, keyClass: CFString) -> (SecKey?, String?) {
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: keyClass,
  ]
  var error: Unmanaged<CFError>?
  let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error)
  let errorDescription = error?.takeRetainedValue().localizedDescription
  return (key, errorDescription)
}

private func describeKeyFailure(
  label: String,
  hadEscapedNewlines: Bool,
  inputLength: Int,
  normalizedLength: Int,
  base64Length: Int,
  derLength: Int,
  failureStep: String,
  importError: String?
) -> String {
  let errorText = importError ?? "unknown"
  return
    "label=\(label), escapedNewlines=\(hadEscapedNewlines), input=\(inputLength), normalized=\(normalizedLength), base64=\(base64Length), der=\(derLength), step=\(failureStep), error=\(errorText)"
}

private func privateSecKey(from pem: String) -> (key: SecKey?, failureDetails: String?) {
  let decoded = decodePEM(pem)
  guard let keyData = decoded.data else {
    return (
      nil,
      describeKeyFailure(
        label: decoded.label,
        hadEscapedNewlines: decoded.hadEscapedNewlines,
        inputLength: decoded.inputLength,
        normalizedLength: decoded.normalizedLength,
        base64Length: decoded.base64Length,
        derLength: 0,
        failureStep: "decodePEM",
        importError: "base64 decode failed"
      )
    )
  }

  let directResult = secKeyFromData(keyData, keyClass: kSecAttrKeyClassPrivate)
  if let key = directResult.0 {
    return (key, nil)
  }

  if decoded.label == "PRIVATE KEY", let pkcs1Data = extractPKCS1FromPKCS8(keyData) {
    let pkcs1Result = secKeyFromData(pkcs1Data, keyClass: kSecAttrKeyClassPrivate)
    if let key = pkcs1Result.0 {
      return (key, nil)
    }

    return (
      nil,
      describeKeyFailure(
        label: decoded.label,
        hadEscapedNewlines: decoded.hadEscapedNewlines,
        inputLength: decoded.inputLength,
        normalizedLength: decoded.normalizedLength,
        base64Length: decoded.base64Length,
        derLength: keyData.count,
        failureStep: "SecKeyCreateWithData(pkcs8->pkcs1)",
        importError: pkcs1Result.1 ?? directResult.1
      )
    )
  }

  return (
    nil,
    describeKeyFailure(
      label: decoded.label,
      hadEscapedNewlines: decoded.hadEscapedNewlines,
      inputLength: decoded.inputLength,
      normalizedLength: decoded.normalizedLength,
      base64Length: decoded.base64Length,
      derLength: keyData.count,
      failureStep: decoded.label == "PRIVATE KEY"
        ? "extractPKCS1FromPKCS8" : "SecKeyCreateWithData",
      importError: directResult.1
    )
  )
}

private func publicSecKey(from pem: String) -> SecKey? {
  let decoded = decodePEM(pem)
  guard let keyData = decoded.data else {
    return nil
  }
  return secKeyFromData(keyData, keyClass: kSecAttrKeyClassPublic).0
}

private func rsaDecryptOAEP(privateKey: SecKey, encrypted: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let decrypted =
    SecKeyCreateDecryptedData(
      privateKey,
      .rsaEncryptionOAEPSHA256,
      encrypted as CFData,
      &error
    ) as Data?
  if decrypted != nil {
    return decrypted
  }
  _ = error?.takeRetainedValue()
  return nil
}

private func rsaEncryptOAEP(publicKey: SecKey, plain: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let encrypted =
    SecKeyCreateEncryptedData(
      publicKey,
      .rsaEncryptionOAEPSHA256,
      plain as CFData,
      &error
    ) as Data?
  if encrypted != nil {
    return encrypted
  }
  _ = error?.takeRetainedValue()
  return nil
}

private func randomBytes(count: Int) throws -> Data {
  var data = Data(count: count)
  let status = data.withUnsafeMutableBytes { buffer in
    guard let baseAddress = buffer.baseAddress else {
      return errSecParam
    }
    return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
  }
  if status != errSecSuccess {
    throw NSError(
      domain: "ChatNativeCore",
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "Secure random generation failed (\(status))"]
    )
  }
  return data
}

private func decryptHybridMessage(
  privateKey: SecKey,
  ciphertext: String,
  isMyMessage: Bool
) -> String {
  let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty {
    return ""
  }
  if !trimmed.hasPrefix("{") {
    NSLog("[ChatNativeCore] Decrypt failed: Format not JSON")
    return "[Decryption Failed - Format]"
  }

  do {
    let payloadData = Data(trimmed.utf8)
    let payload = try JSONDecoder().decode(HybridPayload.self, from: payloadData)

    var keyCandidates: [String] = []
    if let g = payload.g {
      keyCandidates.append(g)
    }
    if isMyMessage {
      if let senderKey = payload.s {
        keyCandidates.append(senderKey)
      }
      if let recipientKey = payload.k {
        keyCandidates.append(recipientKey)
      }
    } else {
      if let recipientKey = payload.k {
        keyCandidates.append(recipientKey)
      }
      if let senderKey = payload.s {
        keyCandidates.append(senderKey)
      }
    }

    var aesKeyData: Data?
    for keyCandidate in keyCandidates {
      guard let encryptedKey = Data(base64Encoded: keyCandidate) else {
        continue
      }
      if let decryptedKey = rsaDecryptOAEP(privateKey: privateKey, encrypted: encryptedKey) {
        aesKeyData = decryptedKey
        break
      }
    }

    guard let aesKeyData else {
      NSLog(
        "[ChatNativeCore] Decrypt failed: Could not decrypt AES key. Candidates count: %d",
        keyCandidates.count)
      throw NSError(
        domain: "ChatNativeCore",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Could not decrypt AES key"]
      )
    }

    guard
      let ivData = Data(base64Encoded: payload.iv),
      let combinedData = Data(base64Encoded: payload.c),
      combinedData.count >= 16
    else {
      NSLog("[ChatNativeCore] Decrypt failed: Invalid ciphertext payload")
      throw NSError(
        domain: "ChatNativeCore",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Invalid ciphertext payload"]
      )
    }

    let ciphertextData = combinedData.prefix(combinedData.count - 16)
    let tagData = combinedData.suffix(16)
    let nonce = try AES.GCM.Nonce(data: ivData)
    let sealedBox = try AES.GCM.SealedBox(
      nonce: nonce,
      ciphertext: ciphertextData,
      tag: tagData
    )
    let plaintextData = try AES.GCM.open(sealedBox, using: SymmetricKey(data: aesKeyData))
    return String(data: plaintextData, encoding: .utf8) ?? ""
  } catch {
    NSLog("[ChatNativeCore] Decrypt failed: %@", error.localizedDescription)
    return "[Decryption Failed]"
  }
}

private func encryptHybridMessage(
  recipientPublicKeyPem: String,
  message: String,
  myPublicKeyPem: String?
) throws -> String {
  guard let recipientKey = publicSecKey(from: recipientPublicKeyPem) else {
    throw NSError(
      domain: "ChatNativeCore",
      code: 10,
      userInfo: [NSLocalizedDescriptionKey: "Invalid recipient public key"]
    )
  }

  let aesKey = try randomBytes(count: 32)
  let iv = try randomBytes(count: 12)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.seal(
    Data(message.utf8),
    using: SymmetricKey(data: aesKey),
    nonce: nonce
  )

  guard let encryptedKeyRecipient = rsaEncryptOAEP(publicKey: recipientKey, plain: aesKey) else {
    throw NSError(
      domain: "ChatNativeCore",
      code: 11,
      userInfo: [NSLocalizedDescriptionKey: "Recipient RSA encrypt failed"]
    )
  }

  var senderEncryptedKeyBase64: String?
  if let myPublicKeyPem, let myPublicKey = publicSecKey(from: myPublicKeyPem) {
    if let encryptedSenderKey = rsaEncryptOAEP(publicKey: myPublicKey, plain: aesKey) {
      senderEncryptedKeyBase64 = encryptedSenderKey.base64EncodedString()
    }
  }

  let combinedCipher = sealed.ciphertext + sealed.tag
  var json: [String: Any] = [
    "v": 1,
    "iv": iv.base64EncodedString(),
    "c": combinedCipher.base64EncodedString(),
    "k": encryptedKeyRecipient.base64EncodedString(),
  ]
  if let senderEncryptedKeyBase64 {
    json["s"] = senderEncryptedKeyBase64
  }

  let serialized = try JSONSerialization.data(withJSONObject: json, options: [])
  guard let payloadString = String(data: serialized, encoding: .utf8) else {
    throw NSError(
      domain: "ChatNativeCore",
      code: 12,
      userInfo: [NSLocalizedDescriptionKey: "Could not encode payload"]
    )
  }
  return payloadString
}

public class ChatNativeCoreModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeCore")

    Function("isSupported") {
      true
    }

    Function("supportsCryptoPipeline") {
      true
    }

    AsyncFunction("decryptMessagesBatch") { (input: [String: Any]) throws -> [String: Any] in
      guard let privateKeyPem = input["privateKey"] as? String else {
        return ["messages": [String: String]()]
      }
      let privateKeyResult = privateSecKey(from: privateKeyPem)
      guard let privateKey = privateKeyResult.key else {
        let details = privateKeyResult.failureDetails ?? "no details"
        throw NSError(
          domain: "ChatNativeCore",
          code: 21,
          userInfo: [NSLocalizedDescriptionKey: "Invalid private key (\(details))"]
        )
      }
      let items = input["items"] as? [[String: Any]] ?? []
      var messages: [String: String] = [:]
      messages.reserveCapacity(items.count)

      for item in items {
        guard
          let id = item["id"] as? String,
          let encryptedContent = item["encryptedContent"] as? String
        else {
          continue
        }
        let isFromMe = (item["isFromMe"] as? Bool) ?? false
        let decrypted = decryptHybridMessage(
          privateKey: privateKey,
          ciphertext: encryptedContent,
          isMyMessage: isFromMe
        )
        if !decrypted.isEmpty {
          messages[id] = decrypted
        }
      }
      return ["messages": messages]
    }

    AsyncFunction("encryptMessage") { (input: [String: Any]) throws -> String in
      guard let recipientPublicKeyPem = input["recipientPublicKey"] as? String else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 20,
          userInfo: [NSLocalizedDescriptionKey: "recipientPublicKey is required"]
        )
      }
      let message = (input["message"] as? String) ?? ""
      let myPublicKeyPem = input["myPublicKey"] as? String
      return try encryptHybridMessage(
        recipientPublicKeyPem: recipientPublicKeyPem,
        message: message,
        myPublicKeyPem: myPublicKeyPem
      )
    }

    AsyncFunction("normalizeRowsBatch") { (input: [String: Any]) -> [String: Any] in
      return [
        "rows": input["rows"] ?? [],
        "changed": false,
      ]
    }

    // MARK: - PBKDF2 Key Derivation (CommonCrypto, hardware-accelerated)

    AsyncFunction("deriveKey") { (input: [String: Any]) throws -> String in
      guard let passphrase = input["passphrase"] as? String,
        let salt = input["salt"] as? String
      else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 30,
          userInfo: [NSLocalizedDescriptionKey: "passphrase and salt are required"]
        )
      }
      let iterations = UInt32((input["iterations"] as? Int) ?? 600_000)
      let keyLength = (input["keyLength"] as? Int) ?? 32

      let passphraseData = Data(passphrase.utf8)
      let saltData = Data(salt.utf8)
      var derivedKey = Data(count: keyLength)

      let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
        passphraseData.withUnsafeBytes { passphraseBytes in
          saltData.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
              CCPBKDFAlgorithm(kCCPBKDF2),
              passphraseBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
              passphraseData.count,
              saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
              saltData.count,
              CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
              iterations,
              derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
              keyLength
            )
          }
        }
      }

      guard status == kCCSuccess else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 31,
          userInfo: [NSLocalizedDescriptionKey: "PBKDF2 derivation failed (\(status))"]
        )
      }
      return derivedKey.base64EncodedString()
    }

    // MARK: - File-Level AES-256-GCM Encryption (CryptoKit)

    AsyncFunction("encryptFileData") { (input: [String: Any]) throws -> [String: String] in
      guard let dataBase64 = input["data"] as? String,
        let fileData = Data(base64Encoded: dataBase64)
      else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 40,
          userInfo: [NSLocalizedDescriptionKey: "Invalid base64 file data"]
        )
      }
      let aesKey = try randomBytes(count: 32)
      let iv = try randomBytes(count: 12)
      let nonce = try AES.GCM.Nonce(data: iv)
      let sealed = try AES.GCM.seal(
        fileData,
        using: SymmetricKey(data: aesKey),
        nonce: nonce
      )
      var combined = Data()
      combined.append(iv)
      combined.append(sealed.ciphertext)
      combined.append(sealed.tag)
      return [
        "encryptedBase64": combined.base64EncodedString(),
        "keyBase64": aesKey.base64EncodedString(),
      ]
    }

    AsyncFunction("decryptFileData") { (input: [String: Any]) throws -> String in
      guard let encryptedBase64 = input["encryptedBase64"] as? String,
        let keyBase64 = input["keyBase64"] as? String,
        let combined = Data(base64Encoded: encryptedBase64),
        let aesKey = Data(base64Encoded: keyBase64),
        combined.count > 28
      else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 50,
          userInfo: [NSLocalizedDescriptionKey: "Invalid encrypted file data or key"]
        )
      }
      let iv = combined.prefix(12)
      let ciphertextData = combined.dropFirst(12).dropLast(16)
      let tagData = combined.suffix(16)
      let nonce = try AES.GCM.Nonce(data: iv)
      let sealedBox = try AES.GCM.SealedBox(
        nonce: nonce,
        ciphertext: ciphertextData,
        tag: tagData
      )
      let plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: aesKey))
      return plaintext.base64EncodedString()
    }
  }
}
