import CryptoKit
import Foundation
import Security
import UIKit

private struct ChatEngineHybridPayload: Decodable {
  let iv: String
  let c: String
  let k: String?
  let s: String?
  let g: String?
}

private func chatEngineReadDERLength(bytes: [UInt8], offset: inout Int) -> Int? {
  guard offset < bytes.count else { return nil }
  let first = Int(bytes[offset])
  offset += 1
  if (first & 0x80) == 0 { return first }
  let count = first & 0x7f
  guard count > 0, count <= 4, offset + count <= bytes.count else { return nil }
  var value = 0
  for _ in 0..<count {
    value = (value << 8) | Int(bytes[offset])
    offset += 1
  }
  return value
}

private func chatEngineExtractPKCS1FromPKCS8(_ data: Data) -> Data? {
  let bytes = [UInt8](data)
  var offset = 0
  guard offset < bytes.count, bytes[offset] == 0x30 else { return nil }
  offset += 1
  guard let seqLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
  let seqEnd = offset + seqLength
  guard seqEnd <= bytes.count else { return nil }
  guard offset < seqEnd, bytes[offset] == 0x02 else { return nil }
  offset += 1
  guard let versionLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else {
    return nil
  }
  offset += versionLength
  guard offset < seqEnd, bytes[offset] == 0x30 else { return nil }
  offset += 1
  guard let algLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
  offset += algLength
  guard offset < seqEnd, bytes[offset] == 0x04 else { return nil }
  offset += 1
  guard let keyLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
  let start = offset
  let end = start + keyLength
  guard end <= seqEnd else { return nil }
  return data.subdata(in: start..<end)
}

private func chatEngineDecodePEM(_ pem: String) -> Data? {
  // Turn literal escape sequences that arrive from JSON serialisation
  // (e.g. the two-character sequence \n) into real newlines.
  let normalized =
    pem
    .replacingOccurrences(of: "\\r\\n", with: "\n")
    .replacingOccurrences(of: "\\r", with: "\n")
    .replacingOccurrences(of: "\\n", with: "\n")
  let sanitized =
    normalized
    .replacingOccurrences(of: "-----BEGIN [^-]+-----", with: "", options: .regularExpression)
    .replacingOccurrences(of: "-----END [^-]+-----", with: "", options: .regularExpression)
  // Use .ignoreUnknownCharacters so whitespace/newlines in the base64 body
  // are silently skipped — Data(base64Encoded:) rejects them by default.
  return Data(base64Encoded: sanitized, options: .ignoreUnknownCharacters)
}

private func chatEnginePrivateKey(from pem: String) -> SecKey? {
  guard let keyData = chatEngineDecodePEM(pem) else {
    print(
      "[ChatEngine] chatEnginePrivateKey — PEM decode returned nil, pemLen=\(pem.count) prefix=\(pem.prefix(50))"
    )
    return nil
  }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    kSecAttrKeySizeInBits as String: 2048,
  ]
  var error: Unmanaged<CFError>?

  let isPKCS8 = pem.contains("BEGIN PRIVATE KEY") && !pem.contains("BEGIN RSA PRIVATE KEY")
  let targetData = (isPKCS8 ? chatEngineExtractPKCS1FromPKCS8(keyData) : nil) ?? keyData

  // Attempt 1: standard
  if let key = SecKeyCreateWithData(targetData as CFData, attrs as CFDictionary, &error) {
    return key
  }

  // Attempt 2: retry without explicit key-size (in case it's non-2048)
  let attrsNoSize: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
  ]
  error = nil
  if let key = SecKeyCreateWithData(targetData as CFData, attrsNoSize as CFDictionary, &error) {
    return key
  }

  // Safe logging — use takeUnretainedValue to avoid over-releasing CFError
  let errDesc: String
  if let e = error {
    errDesc = String(describing: e.takeUnretainedValue())
  } else {
    errDesc = "nil"
  }
  let firstBytes = keyData.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
  print(
    "[ChatEngine] chatEnginePrivateKey FAILED — derLen=\(keyData.count) firstBytes=[\(firstBytes)] pemPrefix=\(pem.prefix(40)) error=\(errDesc)"
  )
  return nil
}

private func chatEngineRSADecryptOAEP(privateKey: SecKey, encrypted: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let decrypted =
    SecKeyCreateDecryptedData(
      privateKey,
      .rsaEncryptionOAEPSHA256,
      encrypted as CFData,
      &error
    ) as Data?
  _ = error?.takeRetainedValue()
  return decrypted
}

private func chatEnginePublicKey(from pem: String) -> SecKey? {
  guard let keyData = chatEngineDecodePEM(pem) else { return nil }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
  ]
  var error: Unmanaged<CFError>?
  let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error)
  _ = error?.takeRetainedValue()
  return key
}

private func chatEngineRSAEncryptOAEP(publicKey: SecKey, plain: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let encrypted =
    SecKeyCreateEncryptedData(
      publicKey,
      .rsaEncryptionOAEPSHA256,
      plain as CFData,
      &error
    ) as Data?
  _ = error?.takeRetainedValue()
  return encrypted
}

private func chatEngineRandomBytes(count: Int) throws -> Data {
  var data = Data(count: count)
  let status = data.withUnsafeMutableBytes { buffer in
    guard let baseAddress = buffer.baseAddress else { return errSecParam }
    return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
  }
  if status != errSecSuccess {
    throw NSError(
      domain: "ChatEngine",
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "Secure random generation failed (\(status))"]
    )
  }
  return data
}

private func chatEngineEncryptHybridMessage(
  recipientPublicKeyPem: String,
  message: String,
  myPublicKeyPem: String?
) throws -> String {
  guard let recipientKey = chatEnginePublicKey(from: recipientPublicKeyPem) else {
    throw NSError(
      domain: "ChatEngine", code: 10,
      userInfo: [NSLocalizedDescriptionKey: "Invalid recipient public key"])
  }

  let aesKey = try chatEngineRandomBytes(count: 32)
  let iv = try chatEngineRandomBytes(count: 12)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.seal(Data(message.utf8), using: SymmetricKey(data: aesKey), nonce: nonce)

  guard let encryptedRecipientKey = chatEngineRSAEncryptOAEP(publicKey: recipientKey, plain: aesKey)
  else {
    throw NSError(
      domain: "ChatEngine", code: 11,
      userInfo: [NSLocalizedDescriptionKey: "Recipient RSA encrypt failed"])
  }

  var senderEncryptedKeyB64: String?
  if let myPublicKeyPem, let myPublicKey = chatEnginePublicKey(from: myPublicKeyPem) {
    if let encryptedSenderKey = chatEngineRSAEncryptOAEP(publicKey: myPublicKey, plain: aesKey) {
      senderEncryptedKeyB64 = encryptedSenderKey.base64EncodedString()
    }
  }

  let combinedCipher = sealed.ciphertext + sealed.tag
  var json: [String: Any] = [
    "v": 1,
    "iv": iv.base64EncodedString(),
    "c": combinedCipher.base64EncodedString(),
    "k": encryptedRecipientKey.base64EncodedString(),
  ]
  if let senderEncryptedKeyB64 { json["s"] = senderEncryptedKeyB64 }
  let serialized = try JSONSerialization.data(withJSONObject: json, options: [])
  guard let payloadString = String(data: serialized, encoding: .utf8) else {
    throw NSError(
      domain: "ChatEngine", code: 12,
      userInfo: [NSLocalizedDescriptionKey: "Could not encode payload"])
  }
  return payloadString
}

private func chatEngineDecryptHybridMessage(
  privateKey: SecKey,
  ciphertext: String,
  isMyMessage: Bool
) -> String {
  let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return "" }
  guard let payload = try? JSONDecoder().decode(ChatEngineHybridPayload.self, from: data) else {
    NSLog(
      "[ChatEngine] Decrypt failed: Payload decode error on JSON (isMyMessage: %@)",
      isMyMessage ? "Y" : "N")
    return ""
  }
  guard
    let iv = Data(base64Encoded: payload.iv),
    let cipherAndTag = Data(base64Encoded: payload.c),
    cipherAndTag.count >= 16
  else {
    NSLog("[ChatEngine] Decrypt failed: Invalid iv or ciphertext structure")
    return ""
  }

  var keyCandidates = [Data]()

  if let g = payload.g, let gBlob = Data(base64Encoded: g) {
    keyCandidates.append(gBlob)
  }

  if isMyMessage {
    if let s = payload.s, let senderBlob = Data(base64Encoded: s) {
      keyCandidates.append(senderBlob)
    }
    if let k = payload.k, let recipientBlob = Data(base64Encoded: k) {
      keyCandidates.append(recipientBlob)
    }
  } else {
    if let k = payload.k, let recipientBlob = Data(base64Encoded: k) {
      keyCandidates.append(recipientBlob)
    }
    if let s = payload.s, let senderBlob = Data(base64Encoded: s) {
      keyCandidates.append(senderBlob)
    }
  }

  var aesKeyData: Data?
  for blob in keyCandidates {
    if let decrypted = chatEngineRSADecryptOAEP(privateKey: privateKey, encrypted: blob) {
      aesKeyData = decrypted
      break
    }
  }
  guard let aesKeyData else {
    NSLog(
      "[ChatEngine] Decrypt failed: Could not decrypt AES key. Candidates count: %d",
      keyCandidates.count)
    return ""
  }

  let ciphertextData = cipherAndTag.dropLast(16)
  let tagData = cipherAndTag.suffix(16)
  do {
    let nonce = try AES.GCM.Nonce(data: iv)
    let sealedBox = try AES.GCM.SealedBox(
      nonce: nonce,
      ciphertext: ciphertextData,
      tag: tagData
    )
    let plaintextData = try AES.GCM.open(sealedBox, using: SymmetricKey(data: aesKeyData))
    return String(data: plaintextData, encoding: .utf8) ?? ""
  } catch {
    NSLog("[ChatEngine] Decrypt failed (AES): %@", error.localizedDescription)
    return ""
  }
}

private func chatEngineEncryptMediaData(_ plainData: Data) throws -> (encryptedData: Data, keyBase64: String) {
  let aesKey = try chatEngineRandomBytes(count: 32)
  let iv = try chatEngineRandomBytes(count: 12)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.seal(plainData, using: SymmetricKey(data: aesKey), nonce: nonce)

  var combined = Data()
  combined.append(iv)
  combined.append(sealed.ciphertext)
  combined.append(sealed.tag)

  return (combined, aesKey.base64EncodedString())
}

private func chatEngineDecryptMediaData(_ encryptedData: Data, keyBase64: String) throws -> Data {
  guard
    let aesKey = Data(base64Encoded: keyBase64),
    encryptedData.count > 28
  else {
    throw NSError(
      domain: "ChatEngine",
      code: 40,
      userInfo: [NSLocalizedDescriptionKey: "Invalid encrypted media payload"]
    )
  }

  let iv = encryptedData.prefix(12)
  let ciphertext = encryptedData.dropFirst(12).dropLast(16)
  let tag = encryptedData.suffix(16)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
  return try AES.GCM.open(sealed, using: SymmetricKey(data: aesKey))
}

final class ChatEngine {
  static let shared = ChatEngine()
  static let didChangeNotification = Notification.Name("Vibe.ChatEngine.didChange")

  private struct SurfaceBinding {
    let surfaceId: String
    let chatId: String?
    let myUserId: String?
    let peerUserId: String?
    let peerAgentId: String?
  }

  private struct AgentProgressState: Equatable {
    let label: String
    let tool: String?
    let status: String
    let updatedAtMs: Int64
  }

  private let queue = DispatchQueue(label: "vibe.chat.engine")
  private let queueSpecificKey = DispatchSpecificKey<UInt8>()
  private let queueSpecificValue: UInt8 = 1
  private let store = ChatEngineStore.shared

  private var state: [String: Any] = [
    "state": "idle",
    "connected": false,
    "updatedAt": 0,
    "note": "ChatEngine scaffold (shadow mode)",
  ]
  private var onlineUsers = Set<String>()
  private var lastSeenByUserId: [String: Int64] = [:]
  private var surfaceBindings: [String: SurfaceBinding] = [:]
  private var openChatChannels: [String: Int] = [:]
  // chatId -> messageId -> "delivered" | "read"
  private var receiptIndex: [String: [String: String]] = [:]
  private var localStatusIndex: [String: [String: String]] = [:]
  private var phoenixClient: ChatRealtimeTransport?
  private var nativePresenceActive = false
  private var nativeUserTopic: String?
  private var nativeUserJoinRef: String?
  private var nativeSocketSignature: String?
  private var nativeChatJoinRefsByRef: [String: String] = [:]
  private var nativeJoinedChatIds = Set<String>()
  private var nativePendingMessagePushRefs: [String: (chatId: String, messageId: String)] = [:]
  private var nativePendingEditPushRefs: [String: (chatId: String, messageId: String)] = [:]
  private var nativePendingDeletePushRefs: [String: (chatId: String, messageId: String)] = [:]
  private var pendingOutboundDraftsByMessageId: [String: [String: Any]] = [:]
  private var pendingOutboundQueueByChat: [String: [String]] = [:]
  private var activeMediaUploadTasksByMessageId: [String: URLSessionTask] = [:]
  private var canceledOutboundMessageIds = Set<String>()
  private var nativeTypingStateByChatId: [String: Bool] = [:]
  private var peerTypingUserIdsByChatId: [String: Set<String>] = [:]
  private var agentProgressByChatId: [String: AgentProgressState] = [:]
  private var nativeRecordingStateByChatId: [String: Bool] = [:]
  private var pinnedMessagesByChatId: [String: [[String: Any]]] = [:]
  private var pinnedFetchInFlightChatIds = Set<String>()
  private var historyRowsByChat: [String: [[String: Any]]] = [:]
  private var historyFullyLoadedChats = Set<String>()
  private var cachedSavedMessagesResponse: [[String: Any]]?
  private var historyLoadingChats = Set<String>()
  private var liveMessageRowsByChat: [String: [String: [String: Any]]] = [:]
  private var deletedMessageIdsByChat: [String: Set<String>] = [:]
  private var chatPeerUserIdsByChatId: [String: String] = [:]
  private var chatPeerAgentIdsByChatId: [String: String] = [:]
  private var agentIdsByPeerUserId: [String: String] = [:]
  private var friendPublicKeysByUserId: [String: String] = [:]
  private var pendingFriendKeyChatIdsByUserId: [String: Set<String>] = [:]
  private var friendKeyFetchInFlightUserIds = Set<String>()
  private var friendKeyRetryWorkItemsByUserId: [String: DispatchWorkItem] = [:]
  private var configuredUserId: String?
  private var reconnectWorkItem: DispatchWorkItem?
  private var reconnectAttempt: Int = 0
  private var autoReconnectEnabled = true
  private var cachedDecryptPrivateKeyPem: String?
  private var cachedDecryptPrivateKey: SecKey?
  private var cachedDecryptKeyTimestamp: Date?
  private static let fallbackApiBaseURL = "https://api.vibegram.io"
  /// Time-to-live for the cached private key in memory (seconds).
  /// After this period of inactivity the key is cleared and re-derived from Keychain on next use.
  private let keyTTL: TimeInterval = 300

  private init() {
    queue.setSpecific(key: queueSpecificKey, value: queueSpecificValue)
    // Clear cached private key when the app moves to the background
    // to reduce the window of exposure to memory dump attacks.
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.clearCachedKeyOnBackground()
    }
    // Reconnect immediately when the app returns to the foreground.
    // Without this, the reconnect backoff timer (up to 8s) plus the
    // WebSocket connect timeout (8s) can delay reconnection by 10-13s.
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.reconnectOnForeground()
    }
    queue.async { [weak self] in
      self?.restoreOutboundStateLocked()
    }
    // Native-owned transport bootstrap:
    // if config already exists (or can be reconstructed from native session),
    // connect without waiting for any JS route lifecycle.
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.ensureNativeTransport(trigger: "engine_init")
    }
  }

  private func currentOutboundUserIdLocked() -> String? {
    normalizedString(store.getConfig()["userId"])
  }

  private func persistOutboundStateLocked() {
    guard let userId = currentOutboundUserIdLocked() else { return }
    if pendingOutboundDraftsByMessageId.isEmpty && pendingOutboundQueueByChat.isEmpty {
      store.clearOutboundState()
      return
    }
    store.setOutboundState([
      "userId": userId,
      "updatedAt": nowMs(),
      "draftsByMessageId": pendingOutboundDraftsByMessageId,
      "queueByChat": pendingOutboundQueueByChat,
    ])
  }

  private func restoreOutboundStateLocked() {
    guard pendingOutboundDraftsByMessageId.isEmpty, pendingOutboundQueueByChat.isEmpty else { return }
    let payload = store.getOutboundState()
    guard !payload.isEmpty else { return }
    guard let storedUserId = normalizedString(payload["userId"]) else { return }
    guard let currentUserId = currentOutboundUserIdLocked(), currentUserId == storedUserId else {
      store.clearOutboundState()
      return
    }

    let rawDrafts = payload["draftsByMessageId"] as? [String: Any] ?? [:]
    var restoredDrafts: [String: [String: Any]] = [:]
    for (messageId, value) in rawDrafts {
      if let draft = value as? [String: Any] {
        restoredDrafts[messageId] = draft
      }
    }

    let rawQueues = payload["queueByChat"] as? [String: Any] ?? [:]
    var restoredQueues: [String: [String]] = [:]
    for (chatId, value) in rawQueues {
      if let ids = value as? [String], !ids.isEmpty {
        restoredQueues[chatId] = ids
      }
    }

    pendingOutboundDraftsByMessageId = restoredDrafts
    pendingOutboundQueueByChat = restoredQueues
    if !restoredDrafts.isEmpty || !restoredQueues.isEmpty {
      appendJournalLocked(
        event: "native-outgoing-restored",
        payload: ["drafts": restoredDrafts.count, "chats": restoredQueues.count]
      )
    }
  }

  private func clearCachedKeyOnBackground() {
    queue.async {
      self.cachedDecryptPrivateKey = nil
      self.cachedDecryptPrivateKeyPem = nil
      self.cachedDecryptKeyTimestamp = nil
    }
  }

  private func reconnectOnForeground() {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      // Reset backoff and cancel pending reconnect timer so we connect
      // immediately instead of waiting for the next backoff tick.
      self.queue.sync {
        self.reconnectAttempt = 0
        self.cancelReconnectLocked()
        self.appendJournalLocked(
          event: "foreground-reconnect",
          payload: ["state": self.normalizedString(self.state["state"]) ?? "unknown"])
      }
      // ensureNativeTransport checks connected/connecting state internally
      // and only initiates a connection when actually needed.
      self.ensureNativeTransport(trigger: "app_foreground")
    }
  }

  private func loadNativeAuthSessionFromKeychain() -> [String: Any]? {
    // Expo SecureStore stores items with:
    //   kSecAttrService  = "<keychainService>:no-auth"  (default keychainService = "app")
    //   kSecAttrAccount  = Data(key.utf8)                (NOT a plain String)
    //   kSecAttrGeneric  = Data(key.utf8)
    let keyData = Data("user_session_v2".utf8)

    // Try Expo SecureStore format first (with service suffix)
    for service in ["app:no-auth", "app:auth", "app"] {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keyData,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecSuccess, let data = result as? Data,
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        return json
      }
    }

    // Fallback: try legacy format without service (in case an older build stored it)
    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: "user_session_v2",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    return nil
  }

  private func hasNativeSocketConfigLocked() -> Bool {
    let config = store.getConfig()
    let transportMode = transportModeLocked(config: config)
    let socketUrl = normalizedString(config["socketUrl"] ?? config["url"])
    let userId = normalizedString(config["userId"])
    let token = normalizedString(config["authToken"] ?? config["token"])
    if transportMode == "offline" {
      return userId != nil && token != nil
    }
    if transportMode == "bridge_text" {
      return bridgeBaseURLLocked(config: config) != nil && userId != nil && token != nil
    }
    return socketUrl != nil && userId != nil && token != nil
  }

  @discardableResult
  private func bootstrapConfigFromNativeSessionIfNeededLocked(trigger: String) -> Bool {
    if hasNativeSocketConfigLocked() { return true }

    let existing = store.getConfig()
    let nativeCallConfig = VibeNativeCallStore.shared.getNativeEngineConfig()
    let session = loadNativeAuthSessionFromKeychain()

    guard
      let userId = normalizedString(
        existing["userId"] ?? nativeCallConfig["userId"] ?? session?["userId"])
    else {
      appendJournalLocked(
        event: "native-config-bootstrap-skip",
        payload: [
          "trigger": trigger,
          "reason": "missing_user_id",
        ])
      return false
    }

    let apiBase =
      normalizedString(
        existing["apiBaseUrl"] ?? existing["baseUrl"] ?? nativeCallConfig["baseUrl"]
          ?? nativeCallConfig["apiBaseUrl"])
      ?? Self.fallbackApiBaseURL
    let socketUrl =
      normalizedString(existing["socketUrl"] ?? existing["url"] ?? nativeCallConfig["socketUrl"])
      ?? (apiBase.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
        + "/socket")
    let token =
      normalizedString(existing["authToken"] ?? existing["token"] ?? nativeCallConfig["authToken"])
      ?? normalizedString(session?["loginToken"])
      ?? userId

    var merged = existing
    merged["apiBaseUrl"] = apiBase
    merged["socketUrl"] = socketUrl
    merged["authToken"] = token
    merged["userId"] = userId
    if normalizedString(existing["userChannelTopic"]) == nil {
      merged["userChannelTopic"] = "user:\(userId)"
    }
    if normalizedString(existing["privateKeyPem"] ?? existing["privateKey"]) == nil,
      let privateKeyPem = normalizedString(session?["privateKeyPem"] ?? session?["privateKey"])
    {
      merged["privateKeyPem"] = privateKeyPem
    }
    if normalizedString(existing["publicKeyPem"] ?? existing["publicKey"]) == nil,
      let publicKeyPem = normalizedString(session?["publicKeyPem"] ?? session?["publicKey"])
    {
      merged["publicKeyPem"] = publicKeyPem
    }

    store.setConfig(merged)
    state["state"] = "configured-native-bootstrap"
    state["updatedAt"] = nowMs()
    state["configuredAt"] = state["updatedAt"]
    state["configKeys"] = Array(merged.keys).sorted()
    state["note"] = "ChatEngine configured from native session"
    state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
    appendJournalLocked(
      event: "native-config-bootstrap",
      payload: [
        "trigger": trigger,
        "hasSocketUrl": normalizedString(merged["socketUrl"] ?? merged["url"]) != nil,
        "hasUserId": normalizedString(merged["userId"]) != nil,
        "hasToken": normalizedString(merged["authToken"] ?? merged["token"]) != nil,
        "hasPrivateKey": normalizedString(merged["privateKeyPem"] ?? merged["privateKey"]) != nil,
        "hasPublicKey": normalizedString(merged["publicKeyPem"] ?? merged["publicKey"]) != nil,
      ])
    return true
  }

  private func ensureNativeTransport(trigger: String) {
    guard #available(iOS 13.0, *) else { return }
    let shouldConnect = queue.sync {
      autoReconnectEnabled = true
      let connected = (state["connected"] as? Bool) == true
      let currentState = normalizedString(state["state"])?.lowercased() ?? ""
      if connected || currentState == "connecting-native-presence"
        || currentState == "native-socket-open"
      {
        return false
      }
      if transportModeLocked() == "offline" {
        return false
      }
      return bootstrapConfigFromNativeSessionIfNeededLocked(trigger: trigger)
    }
    guard shouldConnect else { return }
    _ = connectNativePresence()
  }

  private func hasRealtimeDemandLocked() -> Bool {
    if !pendingOutboundQueueByChat.isEmpty { return true }
    if !openChatChannels.isEmpty { return true }
    if !surfaceBindings.isEmpty { return true }
    return false
  }

  private func cancelReconnectLocked() {
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
  }

  private func reconnectDelayLocked() -> TimeInterval {
    // Keep retries fast when we have pending outbound work, otherwise back off more.
    let hasPendingOutbound = !pendingOutboundQueueByChat.isEmpty
    let sequence: [TimeInterval] =
      hasPendingOutbound
      ? [0.15, 0.35, 0.75, 1.5, 2.5, 4.0]
      : [0.35, 0.9, 2.0, 4.0, 6.0, 8.0]
    let index = min(max(0, reconnectAttempt), sequence.count - 1)
    return sequence[index]
  }

  private func scheduleReconnectLocked(reason: String) {
    guard #available(iOS 13.0, *) else { return }
    guard autoReconnectEnabled else { return }
    guard hasRealtimeDemandLocked() else { return }
    guard reconnectWorkItem == nil else { return }
    let connected = (state["connected"] as? Bool) == true
    let currentState = normalizedString(state["state"])?.lowercased() ?? ""
    guard !connected, currentState != "connecting-native-presence",
      currentState != "native-socket-open"
    else { return }

    let delay = reconnectDelayLocked()
    appendJournalLocked(
      event: "native-reconnect-scheduled",
      payload: [
        "reason": reason,
        "attempt": reconnectAttempt + 1,
        "delayMs": Int(delay * 1000),
      ])

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.queue.async {
        self.reconnectWorkItem = nil
        guard self.autoReconnectEnabled else { return }
        let connected = (self.state["connected"] as? Bool) == true
        let currentState = self.normalizedString(self.state["state"])?.lowercased() ?? ""
        guard !connected, currentState != "connecting-native-presence",
          currentState != "native-socket-open"
        else {
          self.reconnectAttempt = 0
          return
        }
        self.reconnectAttempt = min(self.reconnectAttempt + 1, 64)
        self.appendJournalLocked(
          event: "native-reconnect-attempt",
          payload: [
            "attempt": self.reconnectAttempt,
            "state": currentState,
          ])
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "auto_reconnect")
        }
      }
    }

    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  func configure(_ payload: [String: Any]) -> [String: Any] {
    store.setConfig(payload)
    let now = nowMs()
    let snapshot = queue.sync {
      let nextUserId = normalizedString(payload["userId"])
      if configuredUserId != nil, configuredUserId != nextUserId {
        pendingOutboundDraftsByMessageId.removeAll()
        pendingOutboundQueueByChat.removeAll()
        store.clearOutboundState()
      }
      configuredUserId = nextUserId
      restoreOutboundStateLocked()
      state["state"] = "configured"
      state["updatedAt"] = now
      state["configuredAt"] = now
      state["configKeys"] = Array(payload.keys).sorted()
      state["note"] =
        "ChatEngine configured (native Phoenix presence enabled, shadow fallback active)"
      state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
      let snapshot = statusSnapshotLocked()
      appendJournalLocked(event: "configure", payload: ["keys": Array(payload.keys).sorted()])
      postChangeLocked(reason: "configure", userInfo: ["state": snapshot])
      return snapshot
    }
    ensureNativeTransport(trigger: "configure")
    return snapshot
  }

  func getStatus() -> [String: Any] {
    syncOnQueue { statusSnapshotLocked() }
  }

  func getTransportStatus() -> [String: Any] {
    syncOnQueue { statusSnapshotLocked() }
  }

  func resolveURLForOpen(_ raw: String?) -> String? {
    syncOnQueue { resolveURLForOpenLocked(raw) }
  }

  func authorizationHeaderForAPI() -> String? {
    syncOnQueue {
      guard let token = authHeaderTokenLocked(), !token.isEmpty else { return nil }
      return "Bearer \(token)"
    }
  }

  func decryptMediaDataIfNeeded(_ data: Data, mediaKey: String?) -> Data? {
    let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedKey.isEmpty else { return data }
    return try? chatEngineDecryptMediaData(data, keyBase64: trimmedKey)
  }

  func isUserOnline(userId: String?) -> Bool {
    syncOnQueue {
      guard let normalized = normalizedUpper(userId), !normalized.isEmpty else { return false }
      return onlineUsers.contains(normalized)
    }
  }

  func lastSeenTimestampMs(userId: String?) -> Int64? {
    syncOnQueue {
      guard let normalized = normalizedUpper(userId), !normalized.isEmpty else { return nil }
      return lastSeenByUserId[normalized]
    }
  }

  func connect() -> [String: Any] {
    if #available(iOS 13.0, *) {
      syncOnQueue {
        autoReconnectEnabled = true
        cancelReconnectLocked()
      }
      return connectNativePresence()
    }
    let now = nowMs()
    return queue.sync {
      state["connected"] = true
      state["state"] = "connected-shadow"
      state["updatedAt"] = now
      state["note"] = "ChatEngine shadow connect (native WebSocket unavailable on this iOS version)"
      appendJournalLocked(event: "connect-shadow", payload: [:])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return snapshot
    }
  }

  func disconnect() -> [String: Any] {
    let clientToClose: ChatRealtimeTransport? = queue.sync {
      let now = nowMs()
      autoReconnectEnabled = false
      cancelReconnectLocked()
      reconnectAttempt = 0
      let client = phoenixClient
      phoenixClient = nil
      nativePresenceActive = false
      nativeUserJoinRef = nil
      nativeUserTopic = nil
      nativeChatJoinRefsByRef.removeAll()
      nativeJoinedChatIds.removeAll()
      nativePendingMessagePushRefs.removeAll()
      nativePendingEditPushRefs.removeAll()
      nativePendingDeletePushRefs.removeAll()
      pendingOutboundDraftsByMessageId.removeAll()
      pendingOutboundQueueByChat.removeAll()
      onlineUsers.removeAll()
      lastSeenByUserId.removeAll()
      surfaceBindings.removeAll()
      openChatChannels.removeAll()
      receiptIndex.removeAll()
      localStatusIndex.removeAll()
      nativeTypingStateByChatId.removeAll()
      peerTypingUserIdsByChatId.removeAll()
      agentProgressByChatId.removeAll()
      nativeRecordingStateByChatId.removeAll()
      pinnedMessagesByChatId.removeAll()
      pinnedFetchInFlightChatIds.removeAll()
      liveMessageRowsByChat.removeAll()
      deletedMessageIdsByChat.removeAll()
      historyRowsByChat.removeAll()
      historyFullyLoadedChats.removeAll()
      historyLoadingChats.removeAll()
      cachedSavedMessagesResponse = nil
      chatPeerUserIdsByChatId.removeAll()
      friendPublicKeysByUserId.removeAll()
      pendingFriendKeyChatIdsByUserId.removeAll()
      friendKeyFetchInFlightUserIds.removeAll()
      for (_, item) in friendKeyRetryWorkItemsByUserId {
        item.cancel()
      }
      friendKeyRetryWorkItemsByUserId.removeAll()
      configuredUserId = nil
      // Clear cached private key on disconnect to reduce memory exposure.
      cachedDecryptPrivateKey = nil
      cachedDecryptPrivateKeyPem = nil
      cachedDecryptKeyTimestamp = nil
      state["connected"] = false
      state["state"] = "disconnected"
      state["updatedAt"] = now
      state["presenceSource"] = "shadow"
      appendJournalLocked(event: "disconnect", payload: [:])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return client
    }
    if #available(iOS 13.0, *) {
      clientToClose?.disconnect()
    }
    return getStatus()
  }

  func bindSurface(_ payload: [String: Any]) -> [String: Any] {
    let surfaceId =
      normalizedString(payload["surfaceId"]) ?? normalizedString(payload["engineSurfaceId"]) ?? ""
    let chatId = normalizedString(payload["chatId"])
    let myUserId = normalizedUpper(payload["myUserId"])
    let peerUserId = normalizedUpper(payload["peerUserId"])
    let peerAgentId =
      normalizedString(payload["peerAgentId"] ?? payload["peer_agent_id"])
    guard !surfaceId.isEmpty else { return getStatus() }

    let snapshot = queue.sync {
      surfaceBindings[surfaceId] = SurfaceBinding(
        surfaceId: surfaceId,
        chatId: chatId,
        myUserId: myUserId,
        peerUserId: peerUserId,
        peerAgentId: peerAgentId
      )
      if let chatId, !chatId.isEmpty, let peerUserId, !peerUserId.isEmpty {
        chatPeerUserIdsByChatId[chatId] = peerUserId
        if let peerAgentId, !peerAgentId.isEmpty {
          chatPeerAgentIdsByChatId[chatId] = peerAgentId
          agentIdsByPeerUserId[peerUserId] = peerAgentId
        }
        scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: peerUserId,
          trigger: "bind_surface"
        )
        scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "surface_peer_bound")
      }
      state["updatedAt"] = nowMs()
      appendJournalLocked(
        event: "bind-surface",
        payload: [
          "surfaceId": surfaceId,
          "chatId": chatId as Any,
          "peerUserId": peerUserId as Any,
          "peerAgentId": peerAgentId as Any,
        ])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "surfaceBindingChanged", userInfo: ["surfaceId": surfaceId])
      return snapshot
    }
    ensureNativeTransport(trigger: "bind_surface")
    return snapshot
  }

  func unbindSurface(_ payload: [String: Any]) -> [String: Any] {
    let surfaceId =
      normalizedString(payload["surfaceId"]) ?? normalizedString(payload["engineSurfaceId"]) ?? ""
    guard !surfaceId.isEmpty else { return getStatus() }
    return queue.sync {
      surfaceBindings.removeValue(forKey: surfaceId)
      state["updatedAt"] = nowMs()
      appendJournalLocked(event: "unbind-surface", payload: ["surfaceId": surfaceId])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "surfaceBindingChanged", userInfo: ["surfaceId": surfaceId])
      return snapshot
    }
  }

  func openChatChannel(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let peerUserIdHint = normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"])
    let snapshot = queue.sync {
      if let chatId, !chatId.isEmpty {
        if let peerUserIdHint {
          chatPeerUserIdsByChatId[chatId] = peerUserIdHint
          scheduleFriendPublicKeyFetchLocked(
            chatId: chatId,
            peerUserIdHint: peerUserIdHint,
            trigger: "open_chat_channel"
          )
        }
        let nextCount = (openChatChannels[chatId] ?? 0) + 1
        openChatChannels[chatId] = nextCount
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        // Eagerly fetch history so messages appear instantly when the chat view renders.
        loadChatHistoryIfNeededLocked(chatId: chatId)
      }
      appendJournalLocked(event: "open-chat-channel", payload: payload)
      state["updatedAt"] = nowMs()
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "chatChannelStateChanged", userInfo: ["chatId": chatId as Any])
      return snapshot
    }
    ensureNativeTransport(trigger: "open_chat_channel")
    return snapshot
  }

  func closeChatChannel(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    return queue.sync {
      if let chatId, !chatId.isEmpty, let current = openChatChannels[chatId] {
        if current <= 1 {
          openChatChannels.removeValue(forKey: chatId)
          nativeJoinedChatIds.remove(chatId)
          peerTypingUserIdsByChatId.removeValue(forKey: chatId)
          agentProgressByChatId.removeValue(forKey: chatId)
          if let client = phoenixClient {
            client.leave(topic: chatTopic(for: chatId))
          }
        } else {
          openChatChannels[chatId] = current - 1
        }
      }
      if !hasRealtimeDemandLocked() {
        cancelReconnectLocked()
        reconnectAttempt = 0
      }
      appendJournalLocked(event: "close-chat-channel", payload: payload)
      state["updatedAt"] = nowMs()
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "chatChannelStateChanged", userInfo: ["chatId": chatId as Any])
      return snapshot
    }
  }

  /// Triggers background history loading for a list of chat IDs so messages
  /// are cached before the user taps into a chat.
  func prefetchChatHistories(chatIds: [String]) {
    queue.async { [weak self] in
      guard let self else { return }
      for rawChatId in chatIds {
        guard let chatId = self.normalizedString(rawChatId), !chatId.isEmpty else { continue }
        self.loadChatHistoryIfNeededLocked(chatId: chatId)
      }
    }
  }

  /// Seeds lightweight preview rows from the Home API payload without triggering
  /// background full-history fetches for every chat.
  func seedChatHistories(_ payload: [String: Any]) -> [String: Any] {
    guard let histories = payload["chatHistories"] as? [String: [[String: Any]]] else {
      return ["seeded": 0]
    }

    var triggered = 0
    queue.sync {
      for (rawChatId, messagesArray) in histories {
        guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { continue }
        // We only seed if the full history hasn't already been loaded.
        if !historyFullyLoadedChats.contains(chatId) {
          let rows = buildHistoryRowsLocked(chatId: chatId, rawMessages: messagesArray)
          historyRowsByChat[chatId] = rows
          triggered += 1
        }
      }
    }

    NSLog(
      "[ChatEngine] seedChatHistories injected %d chats without eager history fetch", triggered)
    return ["seeded": triggered]
  }

  func sendDeliveryReceipt(_ payload: [String: Any]) -> [String: Any] {
    sendReceipt(
      payload,
      status: "delivered",
      eventName: "delivery-receipt",
      wireEvent: "delivery-receipt"
    )
  }

  func sendReadReceipt(_ payload: [String: Any]) -> [String: Any] {
    sendReceipt(
      payload,
      status: "read",
      eventName: "read-receipt",
      wireEvent: "read-receipt"
    )
  }

  func sendTypingState(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    let typing: Bool = {
      switch payload["typing"] {
      case let value as Bool:
        return value
      case let value as NSNumber:
        return value.boolValue
      case let value as String:
        return ["1", "true", "yes", "on"].contains(value.lowercased())
      default:
        return false
      }
    }()
    return queue.sync {
      if isBridgeTextModeLocked() {
        return ["accepted": false, "reason": "typing_disabled_in_blackout", "typing": typing]
      }
      if nativeTypingStateByChatId[chatId] == typing {
        return ["accepted": true, "transport": "native", "deduped": true, "typing": typing]
      }
      nativeTypingStateByChatId[chatId] = typing
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "typing_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket", "typing": typing]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "typing_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined", "typing": typing]
      }
      let userId = normalizedString(getConfigValueLocked("userId")) ?? "me"
      let event = typing ? "typing" : "stop-typing"
      let ref = client.push(
        topic: chatTopic(for: chatId), event: event, payload: ["userId": userId])
      appendJournalLocked(
        event: "native-\(event)", payload: ["chatId": chatId, "ref": ref, "typing": typing])
      state["updatedAt"] = nowMs()
      postChangeLocked(reason: "typingStateSent", userInfo: ["chatId": chatId, "typing": typing])
      return ["accepted": true, "transport": "native", "ref": ref, "typing": typing]
    }
  }

  func sendRecordingState(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    let isRecording: Bool = {
      switch payload["isRecording"] ?? payload["recording"] {
      case let value as Bool:
        return value
      case let value as NSNumber:
        return value.boolValue
      case let value as String:
        return ["1", "true", "yes", "on"].contains(value.lowercased())
      default:
        return false
      }
    }()
    let isLocked: Bool = {
      switch payload["isLocked"] ?? payload["locked"] {
      case let value as Bool:
        return value
      case let value as NSNumber:
        return value.boolValue
      case let value as String:
        return ["1", "true", "yes", "on"].contains(value.lowercased())
      default:
        return false
      }
    }()
    let mode = normalizedString(payload["mode"]) ?? "voice"
    return queue.sync {
      if isBridgeTextModeLocked() {
        return [
          "accepted": false,
          "reason": "recording_disabled_in_blackout",
          "isRecording": isRecording,
        ]
      }
      if nativeRecordingStateByChatId[chatId] == isRecording {
        return [
          "accepted": true, "transport": "native", "deduped": true, "isRecording": isRecording,
        ]
      }
      nativeRecordingStateByChatId[chatId] = isRecording
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "recording_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket", "isRecording": isRecording]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "recording_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined", "isRecording": isRecording]
      }
      let userId = normalizedString(getConfigValueLocked("userId")) ?? "me"
      let event = isRecording ? "recording" : "stop-recording"
      var wirePayload: [String: Any] = ["userId": userId]
      if isRecording {
        wirePayload["mode"] = mode
        wirePayload["isLocked"] = isLocked
        if let vad = payload["vad"] { wirePayload["vad"] = vad }
      }
      let ref = client.push(topic: chatTopic(for: chatId), event: event, payload: wirePayload)
      appendJournalLocked(
        event: "native-\(event)",
        payload: [
          "chatId": chatId,
          "ref": ref,
          "isRecording": isRecording,
          "isLocked": isLocked,
          "mode": mode,
        ])
      state["updatedAt"] = nowMs()
      postChangeLocked(
        reason: "recordingStateSent",
        userInfo: [
          "chatId": chatId,
          "isRecording": isRecording,
          "isLocked": isLocked,
          "mode": mode,
        ])
      return ["accepted": true, "transport": "native", "ref": ref, "isRecording": isRecording]
    }
  }

  func retryOutgoingMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    return queue.sync {
      guard let messageId else {
        return ["accepted": false, "reason": "invalid_message"]
      }
      canceledOutboundMessageIds.remove(messageId)
      guard let draft = pendingOutboundDraftsByMessageId[messageId] else {
        return ["accepted": false, "reason": "missing_draft", "messageId": messageId]
      }
      let resolvedChatId = chatId ?? normalizedString(draft["chatId"] ?? draft["chat_id"]) ?? ""
      guard !resolvedChatId.isEmpty else {
        return ["accepted": false, "reason": "invalid_chat", "messageId": messageId]
      }
      queueOutboundDraftLocked(
        chatId: resolvedChatId, messageId: messageId, payload: draft, reason: "manual_retry")
      scheduleReplayQueuedOutboundLocked(chatId: resolvedChatId, trigger: "manual_retry")
      return ["accepted": true, "queued": true, "messageId": messageId, "state": "pending"]
    }
  }

  func cancelOutgoingMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    return queue.sync {
      guard let messageId else {
        return ["accepted": false, "reason": "invalid_message"]
      }
      let resolvedChatId =
        chatId
        ?? pendingOutboundDraftsByMessageId[messageId].flatMap {
          normalizedString($0["chatId"] ?? $0["chat_id"])
        }
        ?? ""
      guard !resolvedChatId.isEmpty else {
        return ["accepted": false, "reason": "invalid_chat", "messageId": messageId]
      }
      let activeUploadTask = activeMediaUploadTasksByMessageId.removeValue(forKey: messageId)
      let hadActiveUpload = activeUploadTask != nil
      activeUploadTask?.cancel()
      canceledOutboundMessageIds.insert(messageId)
      removeQueuedOutboundDraftLocked(chatId: resolvedChatId, messageId: messageId, dropDraft: true)
      setLiveMessageUploadProgressLocked(chatId: resolvedChatId, messageId: messageId, progress: nil)
      upsertLocalStatusLocked(chatId: resolvedChatId, messageId: messageId, status: "error")
      appendJournalLocked(
        event: "native-outgoing-cancel",
        payload: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "hadActiveUpload": hadActiveUpload,
        ])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "outgoingMessageCanceled",
        userInfo: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "state": snapshot,
        ])
      postChangeLocked(
        reason: "chatMessageChanged",
        userInfo: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "action": "updated",
          "state": snapshot,
        ])
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "status": "error",
          "state": snapshot,
        ])
      return ["accepted": true, "messageId": messageId, "state": "canceled"]
    }
  }

  func sendMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let providedMessageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let type = (normalizedString(payload["type"]) ?? "text").lowercased()
    let text = normalizedString(payload["text"]) ?? ""
    let metadata = payload["metadata"] as? [String: Any] ?? [:]
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    let supportedTypes: Set<String> = [
      "text", "image", "gif", "file", "voice", "video", "music", "location", "contact",
      "sticker",
    ]
    guard supportedTypes.contains(type) else {
      return ["accepted": false, "reason": "unsupported_type", "type": type]
    }
    if syncOnQueue({ isBridgeTextModeLocked() && type != "text" }) {
      return ["accepted": false, "reason": "media_disabled_in_blackout", "type": type]
    }

    let metadataValue: (String, [String]) -> Any? = { key, aliases in
      if let value = payload[key] { return value }
      for alias in aliases {
        if let value = payload[alias] { return value }
      }
      if let value = metadata[key] { return value }
      for alias in aliases {
        if let value = metadata[alias] { return value }
      }
      return nil
    }

    let mediaUrl = normalizedString(
      metadataValue("mediaUrl", ["media_url", "previewUrl", "preview_url"]))
    let localPlaybackMediaUrl = mediaUrl.flatMap { self.isLocalMediaURI($0) ? $0 : nil }
    let fileName = normalizedString(metadataValue("fileName", ["file_name"]))
    let fileSize = parseLongValue(metadataValue("fileSize", ["file_size"]))
    let latitude = parseDoubleValue(metadataValue("latitude", []))
    let longitude = parseDoubleValue(metadataValue("longitude", []))
    let duration = parseDoubleValue(metadataValue("duration", []))
    let width = parseLongValue(metadataValue("width", []))
    let height = parseLongValue(metadataValue("height", []))
    let caption = normalizedString(metadataValue("caption", []))
    let thumbnailBase64 = normalizedString(metadataValue("thumbnailBase64", ["thumbnail_base64"]))
    var mediaKey = normalizedString(metadataValue("mediaKey", ["media_key"]))
    let contact = metadataValue("contact", [])
    let viewOnce = metadataValue("viewOnce", ["view_once"])
    let isVideoNote = metadataValue("isVideoNote", ["is_video_note"])
    let waveform = metadataValue("waveform", [])
    let stickerId = normalizedString(metadataValue("stickerId", []))
    let stickerPackId = normalizedString(metadataValue("stickerPackId", ["packId", "pack_id"]))
    let stickerBundleFileName = normalizedString(
      metadataValue("stickerBundleFileName", ["bundleFileName", "bundle_file_name"]))
    let stickerEmoji = normalizedString(metadataValue("emoji", []))
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if type == "text" && !hasText {
      return ["accepted": false, "reason": "empty_text"]
    }
    if ["image", "gif", "file", "voice", "video", "music"].contains(type) {
      guard let mediaUrl, !mediaUrl.isEmpty else {
        return ["accepted": false, "reason": "missing_media_url", "type": type]
      }
    }
    if type == "location" && (latitude == nil || longitude == nil) {
      return ["accepted": false, "reason": "invalid_location"]
    }
    if type == "contact" && contact == nil {
      return ["accepted": false, "reason": "missing_contact"]
    }

    let messageId = providedMessageId ?? UUID().uuidString.lowercased()
    let timestampMs =
      parseLongValue(payload["timestampMs"] ?? payload["timestamp"] ?? payload["timestamp_ms"])
      ?? Int64(nowMs())
    let replyToId =
      normalizedString(payload["replyToId"] ?? payload["reply_to_id"])
      ?? normalizedString(metadata["replyToId"] ?? metadata["reply_to_id"])
    let peerUserIdHint = normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"])
    let explicitPeerAgentId =
      normalizedString(
        payload["peerAgentId"] ?? payload["peer_agent_id"] ?? payload["mentionedAgentId"]
          ?? payload["mentioned_agent_id"])

    return queue.sync {
      canceledOutboundMessageIds.remove(messageId)
      let effectivePayload = payload
      let isGroup =
        (payload["isGroup"] as? Bool) == true || (payload["isGroupOrChannel"] as? Bool) == true
      NSLog(
        "[ChatEngine] sendMessage START chatId=%@ messageId=%@ isGroup=%@", chatId, messageId,
        isGroup ? "true" : "false")

      if let peerUserIdHint {
        chatPeerUserIdsByChatId[chatId] = peerUserIdHint
      }
      if let explicitPeerAgentId, !explicitPeerAgentId.isEmpty {
        chatPeerAgentIdsByChatId[chatId] = explicitPeerAgentId
        if let peerUserIdHint {
          agentIdsByPeerUserId[peerUserIdHint] = explicitPeerAgentId
        }
      }
      let peerUserId = peerUserIdHint ?? chatPeerUserIdsByChatId[chatId]
      let peerAgentId = explicitPeerAgentId ?? resolvePeerAgentIdLocked(
        chatId: chatId, peerUserIdHint: peerUserId)

      // ── Build + emit optimistic row FIRST so message bubble appears instantly ──
      let optimisticStartMs = nowMs()
      var decryptedFields: [String: Any] = ["text": text]
      if let mediaUrl { decryptedFields["mediaUrl"] = mediaUrl }
      if let localPlaybackMediaUrl { decryptedFields["localMediaUrl"] = localPlaybackMediaUrl }
      if let fileName { decryptedFields["fileName"] = fileName }
      if let fileSize { decryptedFields["fileSize"] = fileSize }
      if let latitude { decryptedFields["latitude"] = latitude }
      if let longitude { decryptedFields["longitude"] = longitude }
      if let duration { decryptedFields["duration"] = duration }
      if let width { decryptedFields["width"] = width }
      if let height { decryptedFields["height"] = height }
      if let replyToId { decryptedFields["replyToId"] = replyToId }
      if let contact { decryptedFields["contact"] = contact }
      if let caption { decryptedFields["caption"] = caption }
      if let thumbnailBase64 { decryptedFields["thumbnailBase64"] = thumbnailBase64 }
      if let mediaKey { decryptedFields["mediaKey"] = mediaKey }
      if let viewOnce { decryptedFields["viewOnce"] = viewOnce }
      if let isVideoNote { decryptedFields["isVideoNote"] = isVideoNote }
      if let waveform { decryptedFields["waveform"] = waveform }
      if let stickerId { decryptedFields["stickerId"] = stickerId }
      if let stickerPackId { decryptedFields["stickerPackId"] = stickerPackId }
      if let stickerBundleFileName {
        decryptedFields["stickerBundleFileName"] = stickerBundleFileName
      }
      if let stickerEmoji { decryptedFields["emoji"] = stickerEmoji }
      var optimisticRow = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: normalizedString(getConfigValueLocked("userId")),
        type: type,
        timestampMs: timestampMs,
        encryptedContent: nil,
        decryptedFields: decryptedFields
      )
      if var message = optimisticRow["message"] as? [String: Any] {
        message["status"] = "sending"
        if let replyToId { message["replyToId"] = replyToId }
        optimisticRow["message"] = message
      }
      upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: optimisticRow)
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "sending")
      postChangeLocked(
        reason: "chatMessageInserted",
        userInfo: ["chatId": chatId, "messageId": messageId, "action": "inserted"])
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": "sending"])
      NSLog(
        "[ChatEngine] sendMessage optimistic row emitted in %dms chatId=%@ messageId=%@",
        Int(nowMs() - optimisticStartMs), chatId, messageId)

      // ── Now resolve friend public key (may do synchronous HTTP — no longer blocks UI) ──
      let keyResolveStartMs = nowMs()
      let isSavedMessagesChat = chatId == "saved_messages"
      let friendPublicKey: String?
      if isGroup || isSavedMessagesChat {
        friendPublicKey = nil
      } else if let peerAgentId, !peerAgentId.isEmpty {
        friendPublicKey = nil
      } else {
        guard
          let key = resolveFriendPublicKeyLocked(
            chatId: chatId, peerUserIdHint: peerUserId)
        else {
          NSLog(
            "[ChatEngine] sendMessage queued reason=missing_friend_key chatId=%@ messageId=%@ keyResolveMs=%d",
            chatId, messageId, Int(nowMs() - keyResolveStartMs))
          upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
          pendingOutboundDraftsByMessageId[messageId] = effectivePayload
          queueOutboundDraftLocked(
            chatId: chatId, messageId: messageId, payload: effectivePayload,
            reason: "missing_friend_key")
          scheduleFriendPublicKeyFetchLocked(
            chatId: chatId,
            peerUserIdHint: peerUserId,
            trigger: "send_missing_friend_key"
          )
          loadChatHistoryIfNeededLocked(chatId: chatId, force: true)
          DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.ensureNativeTransport(trigger: "send_missing_friend_key")
          }
          appendJournalLocked(
            event: "native-send-message-error",
            payload: [
              "chatId": chatId,
              "messageId": messageId,
              "reason": "missing_friend_key",
            ])
          postChangeLocked(
            reason: "messageStatusChanged",
            userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
          return [
            "accepted": true, "queued": true, "reason": "missing_friend_key",
            "messageId": messageId,
            "state": "pending",
          ]
        }
        friendPublicKey = key
      }
      NSLog(
        "[ChatEngine] sendMessage keyResolved in %dms chatId=%@ messageId=%@ hasKey=%@",
        Int(nowMs() - keyResolveStartMs), chatId, messageId,
        friendPublicKey != nil ? "true" : "false")

      let apiBase = self.apiBaseURLLocked()
      let token = self.authHeaderTokenLocked()
      let userId = normalizedString(self.getConfigValueLocked("userId"))
      let myPublicKeyPem = normalizedString(
        self.getConfigValueLocked("publicKeyPem") ?? self.getConfigValueLocked("publicKey"))

      let needsUpload =
        ["image", "gif", "file", "voice", "video", "music"].contains(type)
        && (mediaUrl != nil)
        && isLocalMediaURI(mediaUrl!)

      var uploadTargetUrl: String? = nil
      if needsUpload {
        uploadTargetUrl = mediaUrl
        // Eagerly compute file size from the local file so the UI can display
        // real-time progress (e.g. "1.2 MB / 16 MB") from the very first frame.
        if fileSize == nil, let localUri = mediaUrl, let localURL = localFileURL(from: localUri) {
          let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
          if let size = attrs?[.size] as? Int64, size > 0 {
            mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
              message["fileSize"] = size
              var meta = (message["metadata"] as? [String: Any]) ?? [:]
              meta["fileSize"] = size
              message["metadata"] = meta
            }
          }
        }
        setLiveMessageUploadProgressLocked(chatId: chatId, messageId: messageId, progress: 0.02)
        postChangeLocked(
          reason: "chatMessageChanged",
          userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
        )
      }

      DispatchQueue.global(qos: .userInitiated).async {
        [weak self, friendPublicKey, uploadTargetUrl, myPublicKeyPem] in
        guard let self = self else { return }

        var finalMediaUrl = mediaUrl
        var finalFileName = fileName
        var finalFileSize = fileSize
        var finalMediaKey = mediaKey
        var localEffectivePayload = effectivePayload
        var localOptimisticRow = optimisticRow

        if let localMediaUrl = uploadTargetUrl {
          guard let apiBase = apiBase, let token = token, let userId = userId else {
            self.queue.async {
              self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
              self.queueOutboundDraftLocked(
                chatId: chatId, messageId: messageId, payload: localEffectivePayload,
                reason: "missing_upload_config")
              self.appendJournalLocked(
                event: "native-media-upload-error",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "reason": "missing_upload_config",
                ])
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: nil)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
            }
            return
          }

          self.queue.async {
            self.appendJournalLocked(
              event: "native-media-upload-start",
              payload: [
                "chatId": chatId,
                "messageId": messageId,
                "type": type,
              ])
            self.setLiveMessageUploadProgressLocked(
              chatId: chatId, messageId: messageId, progress: 0.027)
            self.postChangeLocked(
              reason: "chatMessageChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
            )
          }

          let uploadOutcome = self.uploadLocalMediaLocked(
            localUri: localMediaUrl,
            messageType: type,
            fileNameHint: fileName,
            userId: userId,
            token: token,
            apiBase: apiBase,
            messageId: messageId
          ) { progress in
            self.queue.async { [weak self] in
              guard let self else { return }
              if self.canceledOutboundMessageIds.contains(messageId) { return }
              let scaledProgress = max(0.027, min(1.0, Double(progress)))
              if self.setLiveMessageUploadProgressLocked(
                chatId: chatId,
                messageId: messageId,
                progress: scaledProgress
              ) {
                self.postChangeLocked(
                  reason: "chatMessageChanged",
                  userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
                )
              }
            }
          }

          if let uploadResult = uploadOutcome.result {
            finalMediaUrl = uploadResult.remoteUrl
            if finalFileName == nil { finalFileName = uploadResult.fileName }
            if finalFileSize == nil { finalFileSize = uploadResult.fileSize }
            if finalMediaKey == nil { finalMediaKey = uploadResult.mediaKey }

            var nextMetadata = (localEffectivePayload["metadata"] as? [String: Any]) ?? [:]
            nextMetadata["mediaUrl"] = uploadResult.remoteUrl
            if let localPlaybackMediaUrl { nextMetadata["localMediaUrl"] = localPlaybackMediaUrl }
            if let finalFileName { nextMetadata["fileName"] = finalFileName }
            if let finalFileSize { nextMetadata["fileSize"] = finalFileSize }
            if let finalMediaKey { nextMetadata["mediaKey"] = finalMediaKey }

            localEffectivePayload["metadata"] = nextMetadata
            localEffectivePayload["chatId"] = chatId
            localEffectivePayload["messageId"] = messageId
            localEffectivePayload["type"] = type
            localEffectivePayload["text"] = text

            if var message = localOptimisticRow["message"] as? [String: Any] {
              message["mediaUrl"] = uploadResult.remoteUrl
              if let localPlaybackMediaUrl { message["localMediaUrl"] = localPlaybackMediaUrl }
              if let finalFileName { message["fileName"] = finalFileName }
              if let finalFileSize { message["fileSize"] = finalFileSize }
              if let finalMediaKey { message["mediaKey"] = finalMediaKey }
              var metadata = (message["metadata"] as? [String: Any]) ?? [:]
              if let finalMediaKey { metadata["mediaKey"] = finalMediaKey }
              if let localPlaybackMediaUrl { metadata["localMediaUrl"] = localPlaybackMediaUrl }
              message["metadata"] = metadata
              localOptimisticRow["message"] = message
            }

            let threadMediaUrl = finalMediaUrl
            let threadOptimisticRow = localOptimisticRow
            self.queue.async {
              self.upsertLiveMessageRowLocked(
                chatId: chatId, messageId: messageId, row: threadOptimisticRow)
              NSLog(
                "[ChatEngine] voice upload complete chatId=%@ messageId=%@ remoteUrl=%@ localPlayback=%@ type=%@",
                chatId,
                messageId,
                threadMediaUrl ?? "-",
                localPlaybackMediaUrl ?? "-",
                type
              )
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: 1.0)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.appendJournalLocked(
                event: "native-media-upload-ok",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "url": threadMediaUrl ?? "",
                ])
            }
          } else {
            let reason = uploadOutcome.reason ?? "upload_failed"
            let retryableReasons: Set<String> = [
              "upload_failed", "upload_timeout", "missing_upload_config",
            ]
            let shouldQueue = retryableReasons.contains(reason)

            self.queue.async {
              self.upsertLocalStatusLocked(
                chatId: chatId, messageId: messageId, status: shouldQueue ? "pending" : "error")
              self.appendJournalLocked(
                event: "native-media-upload-error",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "reason": reason,
                ])
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: nil)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "status": shouldQueue ? "pending" : "error",
                ])
              if shouldQueue {
                self.queueOutboundDraftLocked(
                  chatId: chatId, messageId: messageId, payload: localEffectivePayload,
                  reason: reason)
              }
              self.canceledOutboundMessageIds.remove(messageId)
            }
            return
          }
        }

        if self.syncOnQueue({ self.canceledOutboundMessageIds.contains(messageId) }) {
          self.queue.async {
            self.setLiveMessageUploadProgressLocked(
              chatId: chatId, messageId: messageId, progress: nil)
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
            self.postChangeLocked(
              reason: "chatMessageChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
            )
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"])
            self.canceledOutboundMessageIds.remove(messageId)
          }
          return
        }

        if isSavedMessagesChat {
          localEffectivePayload["chatId"] = chatId
          localEffectivePayload["messageId"] = messageId
          localEffectivePayload["type"] = type
          localEffectivePayload["text"] = text

          self.queue.async {
            self.removeQueuedOutboundDraftLocked(
              chatId: chatId, messageId: messageId, dropDraft: false)
            self.pendingOutboundDraftsByMessageId[messageId] = localEffectivePayload
            self.appendJournalLocked(
              event: "native-send-saved-message-start",
              payload: [
                "chatId": chatId,
                "messageId": messageId,
                "type": type,
              ])
            NSLog(
              "[ChatEngine] sendMessage saved_messages direct chatId=%@ messageId=%@ type=%@",
              chatId, messageId, type)
          }

          self.sendSavedMessage(localEffectivePayload) { result in
            self.queue.async { [weak self] in
              guard let self else { return }
              let success = (result["success"] as? Bool) == true
              let statusCode = result["status"] as? Int ?? -1
              let failureReason =
                normalizedString(result["reason"])
                ?? normalizedString(result["error"])
                ?? "saved_message_send_failed"
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: nil)
              if success {
                self.removeQueuedOutboundDraftLocked(
                  chatId: chatId, messageId: messageId, dropDraft: true)
              } else {
                self.removeQueuedOutboundDraftLocked(
                  chatId: chatId, messageId: messageId, dropDraft: false)
              }
              self.upsertLocalStatusLocked(
                chatId: chatId,
                messageId: messageId,
                status: success ? "sent" : "error"
              )
              self.appendJournalLocked(
                event: success ? "native-send-saved-message-ok" : "native-send-saved-message-error",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "status": statusCode,
                  "reason": success ? "ok" : failureReason,
                ])
              NSLog(
                "[ChatEngine] sendMessage saved_messages %@ chatId=%@ messageId=%@ status=%d reason=%@",
                success ? "OK" : "FAIL",
                chatId,
                messageId,
                statusCode,
                success ? "ok" : failureReason)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "status": success ? "sent" : "error",
                ])
            }
          }
          return
        }

        var fullPayloadBase: [String: Any] = ["text": text]
        if let finalMediaUrl { fullPayloadBase["mediaUrl"] = finalMediaUrl }
        if let finalMediaKey { fullPayloadBase["mediaKey"] = finalMediaKey }
        if let finalFileName { fullPayloadBase["fileName"] = finalFileName }
        if let finalFileSize { fullPayloadBase["fileSize"] = finalFileSize }
        if let latitude { fullPayloadBase["latitude"] = latitude }
        if let longitude { fullPayloadBase["longitude"] = longitude }
        if let duration { fullPayloadBase["duration"] = duration }
        if let width { fullPayloadBase["width"] = width }
        if let height { fullPayloadBase["height"] = height }
        if let replyToId { fullPayloadBase["replyToId"] = replyToId }
        if let contact { fullPayloadBase["contact"] = contact }
        if let caption { fullPayloadBase["caption"] = caption }
        if let thumbnailBase64 { fullPayloadBase["thumbnailBase64"] = thumbnailBase64 }
        if let viewOnce { fullPayloadBase["viewOnce"] = viewOnce }
        if let isVideoNote { fullPayloadBase["isVideoNote"] = isVideoNote }
        if let waveform { fullPayloadBase["waveform"] = waveform }
        if let stickerId { fullPayloadBase["stickerId"] = stickerId }
        if let stickerPackId { fullPayloadBase["stickerPackId"] = stickerPackId }
        if let stickerBundleFileName {
          fullPayloadBase["stickerBundleFileName"] = stickerBundleFileName
        }
        if let stickerEmoji { fullPayloadBase["emoji"] = stickerEmoji }
        let fullPayload = makeJSONSafeMap(fullPayloadBase)
        guard
          let fullPayloadData = try? JSONSerialization.data(
            withJSONObject: fullPayload, options: []),
          let fullPayloadString = String(data: fullPayloadData, encoding: .utf8)
        else {
          self.queue.async {
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
          }
          return
        }

        let encryptedContent: String
        do {
          if isGroup || friendPublicKey == nil {
            encryptedContent = fullPayloadString
          } else {
            encryptedContent = try chatEngineEncryptHybridMessage(
              recipientPublicKeyPem: friendPublicKey!,
              message: fullPayloadString,
              myPublicKeyPem: myPublicKeyPem ?? ""
            )
          }
        } catch {
          self.queue.async {
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
            self.appendJournalLocked(
              event: "native-send-message-error",
              payload: [
                "chatId": chatId,
                "messageId": messageId,
                "reason": "encrypt_failed",
                "error": error.localizedDescription,
              ])
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"])
          }
          return
        }

        let pushPreview: String = {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            if trimmed.count <= 160 { return trimmed }
            return String(trimmed.prefix(159)) + "…"
          }
          switch type {
          case "image": return "Photo"
          case "video": return "Video"
          case "voice": return "Voice message"
          case "music": return "Audio"
          case "file": return "File"
          case "location": return "Location"
          case "contact": return "Contact"
          case "gif": return "GIF"
          case "sticker": return "Sticker"
          default: return ""
          }
        }()

        var wirePayload: [String: Any] = [
          "id": messageId,
          "encryptedContent": encryptedContent,
          "timestamp": timestampMs,
          "type": type,
          "pushPreview": pushPreview,
          "mediaUrl": NSNull(),
          "fileName": NSNull(),
          "latitude": NSNull(),
          "longitude": NSNull(),
        ]
        if let replyToId, !replyToId.isEmpty {
          wirePayload["replyToId"] = replyToId
        }
        if let fromId = userId {
          wirePayload["fromId"] = fromId
        }
        if let peerAgentId, !peerAgentId.isEmpty {
          wirePayload["mentionedAgentId"] = peerAgentId
          wirePayload["agentText"] = text
        }
        if let agentMention = payload["agentMention"] as? Bool, agentMention {
          wirePayload["agentMention"] = true
          if let agentText = payload["agentText"] as? String {
            wirePayload["agentText"] = agentText
          }
        }
        if let mentionedAgentUsername = payload["mentionedAgentUsername"] as? String,
          !mentionedAgentUsername.isEmpty
        {
          wirePayload["mentionedAgentUsername"] = mentionedAgentUsername
          if let agentText = payload["agentText"] as? String {
            wirePayload["agentText"] = agentText
          }
        }

        if var message = localOptimisticRow["message"] as? [String: Any] {
          message["encryptedContent"] = encryptedContent
          localOptimisticRow["message"] = message
        }
        let threadOptimisticRow = localOptimisticRow
        let threadEffectivePayload = localEffectivePayload
        let threadWirePayload = wirePayload

        self.queue.async {
          if self.canceledOutboundMessageIds.contains(messageId) {
            self.setLiveMessageUploadProgressLocked(
              chatId: chatId, messageId: messageId, progress: nil)
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
            self.postChangeLocked(
              reason: "chatMessageChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
            )
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"])
            self.canceledOutboundMessageIds.remove(messageId)
            return
          }
          self.upsertLiveMessageRowLocked(
            chatId: chatId, messageId: messageId, row: threadOptimisticRow)
          self.pendingOutboundDraftsByMessageId[messageId] = threadEffectivePayload

          guard let client = self.phoenixClient else {
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
            self.queueOutboundDraftLocked(
              chatId: chatId, messageId: messageId, payload: threadEffectivePayload,
              reason: "no_native_socket")
            self.scheduleReconnectLocked(reason: "send_no_socket")
            DispatchQueue.global(qos: .utility).async { [weak self] in
              self?.ensureNativeTransport(trigger: "send_no_socket")
            }
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
            return
          }

          guard self.nativeJoinedChatIds.contains(chatId) else {
            self.joinNativeChatTopicIfNeededLocked(chatId: chatId)
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
            self.queueOutboundDraftLocked(
              chatId: chatId, messageId: messageId, payload: threadEffectivePayload,
              reason: "chat_not_joined"
            )
            self.scheduleReconnectLocked(reason: "send_chat_not_joined")
            DispatchQueue.global(qos: .utility).async { [weak self] in
              self?.ensureNativeTransport(trigger: "send_chat_not_joined")
            }
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
            return
          }

          let ref = client.push(
            topic: self.chatTopic(for: chatId), event: "message", payload: threadWirePayload)
          self.nativePendingMessagePushRefs[ref] = (chatId: chatId, messageId: messageId)

          let timeoutRef = ref
          self.queue.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self else { return }
            if let pending = self.nativePendingMessagePushRefs.removeValue(forKey: timeoutRef) {
              self.appendJournalLocked(
                event: "native-send-timeout",
                payload: [
                  "chatId": pending.chatId,
                  "messageId": pending.messageId,
                  "ref": timeoutRef,
                ])
              self.upsertLocalStatusLocked(
                chatId: pending.chatId, messageId: pending.messageId, status: "error")
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: [
                  "chatId": pending.chatId, "messageId": pending.messageId, "status": "error",
                ])
            }
          }

          self.appendJournalLocked(
            event: "native-send-message",
            payload: [
              "chatId": chatId,
              "messageId": messageId,
              "ref": ref,
            ])
          self.postChangeLocked(
            reason: "messageStatusChanged", userInfo: ["chatId": chatId, "messageId": messageId])
        }
      }

      return [
        "accepted": true,
        "queued": true,
        "messageId": messageId,
        "state": "sending",
      ]
    }
  }

  func sendEncryptedMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let messagePayload = payload["message"] as? [String: Any]
    guard let chatId, let messageId, let messagePayload else {
      return [
        "accepted": false,
        "reason": "invalid_payload",
      ]
    }

    return queue.sync {
      guard let client = phoenixClient else {
        return [
          "accepted": false,
          "reason": "no_native_socket",
        ]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return [
          "accepted": false,
          "reason": "chat_not_joined",
        ]
      }

      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "sending")
      let ref = client.push(
        topic: chatTopic(for: chatId), event: "message", payload: messagePayload)
      nativePendingMessagePushRefs[ref] = (chatId: chatId, messageId: messageId)

      let timeoutRef = ref
      queue.asyncAfter(deadline: .now() + 15.0) { [weak self] in
        guard let self = self else { return }
        if let pending = self.nativePendingMessagePushRefs.removeValue(forKey: timeoutRef) {
          self.appendJournalLocked(
            event: "native-send-timeout",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": timeoutRef,
            ])
          self.upsertLocalStatusLocked(
            chatId: pending.chatId, messageId: pending.messageId, status: "error")
          self.postChangeLocked(
            reason: "messageStatusChanged",
            userInfo: ["chatId": pending.chatId, "messageId": pending.messageId, "status": "error"])
        }
      }

      appendJournalLocked(
        event: "native-send-message",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "ref": ref,
        ])
      postChangeLocked(
        reason: "messageStatusChanged", userInfo: ["chatId": chatId, "messageId": messageId])
      return [
        "accepted": true,
        "transport": "native",
        "ref": ref,
      ]
    }
  }

  func sendEditMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let encryptedContent =
      normalizedString(payload["encryptedContent"])
      ?? normalizedString(payload["encrypted_content"])
    let editedAt = payload["editedAt"] ?? payload["edited_at"]
    guard let chatId, let messageId, let encryptedContent else {
      return ["accepted": false, "reason": "invalid_payload"]
    }
    if syncOnQueue({ isBridgeTextModeLocked() }) {
      return ["accepted": false, "reason": "edit_disabled_in_blackout"]
    }

    return queue.sync {
      guard let client = phoenixClient else {
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      var wirePayload: [String: Any] = [
        "messageId": messageId,
        "encryptedContent": encryptedContent,
      ]
      if let editedAt {
        wirePayload["editedAt"] = editedAt
      }
      let ref = client.push(
        topic: chatTopic(for: chatId), event: "edit-message", payload: wirePayload)
      nativePendingEditPushRefs[ref] = (chatId: chatId, messageId: messageId)
      appendJournalLocked(
        event: "native-send-edit-message",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "ref": ref,
        ])
      return ["accepted": true, "transport": "native", "ref": ref]
    }
  }

  func sendDeleteMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else {
      return ["accepted": false, "reason": "invalid_payload"]
    }
    if syncOnQueue({ isBridgeTextModeLocked() }) {
      return ["accepted": false, "reason": "delete_disabled_in_blackout"]
    }

    let forEveryone: Bool = {
      switch payload["forEveryone"] ?? payload["for_everyone"] {
      case let bool as Bool:
        return bool
      case let str as String:
        return ["true", "1", "yes"].contains(str.lowercased())
      case let num as NSNumber:
        return num.boolValue
      default:
        return true
      }
    }()

    return queue.sync {
      guard let client = phoenixClient else {
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      let ref = client.push(
        topic: chatTopic(for: chatId), event: "delete-message",
        payload: [
          "messageId": messageId,
          "forEveryone": forEveryone,
        ])
      nativePendingDeletePushRefs[ref] = (chatId: chatId, messageId: messageId)
      appendJournalLocked(
        event: "native-send-delete-message",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "forEveryone": forEveryone,
          "ref": ref,
        ])
      return ["accepted": true, "transport": "native", "ref": ref]
    }
  }

  func editMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let nextText = normalizedString(payload["text"])
    guard let chatId, let messageId, let nextText else {
      return ["accepted": false, "reason": "invalid_payload"]
    }
    let trimmedText = nextText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      return ["accepted": false, "reason": "empty_text"]
    }

    return queue.sync {
      guard let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId)
      else {
        return ["accepted": false, "reason": "message_not_found"]
      }
      let peerUserIdHint =
        normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"])
        ?? chatPeerUserIdsByChatId[chatId]
      guard
        let friendPublicKey = resolveFriendPublicKeyLocked(
          chatId: chatId, peerUserIdHint: peerUserIdHint)
      else {
        scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: peerUserIdHint,
          trigger: "edit_missing_friend_key"
        )
        return ["accepted": false, "reason": "missing_friend_key"]
      }

      let editedAt = Int64(nowMs())
      var fullPayloadBase: [String: Any] = [
        "text": trimmedText,
        "isEdited": true,
        "editedAt": editedAt,
      ]
      if let mediaUrl = normalizedString(existingMessage["mediaUrl"]) {
        fullPayloadBase["mediaUrl"] = mediaUrl
      }
      if let fileName = normalizedString(existingMessage["fileName"]) {
        fullPayloadBase["fileName"] = fileName
      }
      if let duration = parseDoubleValue(existingMessage["duration"]) {
        fullPayloadBase["duration"] = duration
      }
      if let replyToId = normalizedString(existingMessage["replyToId"]) {
        fullPayloadBase["replyToId"] = replyToId
      }
      if let metadata = existingMessage["metadata"] as? [String: Any] {
        if let width = metadata["width"] { fullPayloadBase["width"] = width }
        if let height = metadata["height"] { fullPayloadBase["height"] = height }
        if let thumbnailBase64 = metadata["thumbnailBase64"] {
          fullPayloadBase["thumbnailBase64"] = thumbnailBase64
        }
        if let isVideoNote = metadata["isVideoNote"] {
          fullPayloadBase["isVideoNote"] = isVideoNote
        }
        if let waveform = metadata["waveform"] { fullPayloadBase["waveform"] = waveform }
      }
      let fullPayload = makeJSONSafeMap(fullPayloadBase)
      guard
        let payloadData = try? JSONSerialization.data(withJSONObject: fullPayload, options: []),
        let payloadString = String(data: payloadData, encoding: .utf8)
      else {
        return ["accepted": false, "reason": "payload_encode_failed"]
      }
      let myPublicKeyPem = normalizedString(
        getConfigValueLocked("publicKeyPem") ?? getConfigValueLocked("publicKey"))
      let encryptedContent: String
      do {
        encryptedContent = try chatEngineEncryptHybridMessage(
          recipientPublicKeyPem: friendPublicKey,
          message: payloadString,
          myPublicKeyPem: myPublicKeyPem
        )
      } catch {
        appendJournalLocked(
          event: "native-edit-message-error",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "reason": "encrypt_failed",
            "error": error.localizedDescription,
          ])
        return ["accepted": false, "reason": "encrypt_failed"]
      }

      guard let client = phoenixClient else {
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return ["accepted": false, "reason": "chat_not_joined"]
      }
      let ref = client.push(
        topic: chatTopic(for: chatId), event: "edit-message",
        payload: [
          "messageId": messageId,
          "encryptedContent": encryptedContent,
          "editedAt": editedAt,
        ])
      nativePendingEditPushRefs[ref] = (chatId: chatId, messageId: messageId)
      appendJournalLocked(
        event: "native-send-edit-message",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "ref": ref,
        ])
      let result: [String: Any] = ["accepted": true, "transport": "native", "ref": ref]
      _ = applyNativeChatMutationEventLocked(
        chatId: chatId,
        event: "message-edited",
        payload: [
          "messageId": messageId,
          "encryptedContent": encryptedContent,
          "editedAt": editedAt,
        ]
      )
      postChangeLocked(
        reason: "chatMessageEdited", userInfo: ["chatId": chatId, "messageId": messageId])
      return result
    }
  }

  func deleteMessage(_ payload: [String: Any]) -> [String: Any] {
    sendDeleteMessage(payload)
  }

  func upsertLocalMessageStatus(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let status = normalizedString(payload["status"])?.lowercased()
    guard let chatId, let messageId, let status else { return getStatus() }
    if status == "delivered" || status == "read" {
      return queue.sync {
        upsertReceiptLocked(chatId: chatId, messageId: messageId, status: status)
        if status == "read" || status == "delivered" {
          upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: status)
        }
        appendJournalLocked(event: "upsert-local-status", payload: payload)
        let snapshot = statusSnapshotLocked()
        postChangeLocked(
          reason: "messageStatusChanged",
          userInfo: ["chatId": chatId, "messageId": messageId, "status": status]
        )
        return snapshot
      }
    }
    return queue.sync {
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: status)
      appendJournalLocked(event: "upsert-local-status", payload: payload)
      state["updatedAt"] = nowMs()
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": status]
      )
      return snapshot
    }
  }

  func setChatMuted(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    guard let muted = parseBooleanLike(payload["muted"]) else {
      return ["accepted": false, "reason": "invalid_muted"]
    }

    let requestContext: (URL, String, String)?
    requestContext = syncOnQueue {
      guard
        let apiBase = apiBaseURLLocked(),
        let userId = normalizedString(
          payload["userId"] ?? payload["user_id"] ?? getConfigValueLocked("userId"))
      else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      appendJournalLocked(
        event: "native-chat-mute-request",
        payload: ["chatId": chatId, "muted": muted, "userId": userId]
      )
      state["updatedAt"] = nowMs()
      return (apiBase, token, userId)
    }

    guard let (apiBase, token, userId) = requestContext else {
      return ["accepted": false, "reason": "missing_config", "chatId": chatId]
    }

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("mute"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["userId": userId, "muted": muted], options: [])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          self.appendJournalLocked(
            event: "native-chat-mute-error",
            payload: [
              "chatId": chatId,
              "muted": muted,
              "error": error.localizedDescription,
            ])
          return
        }
        let success = (200...299).contains(statusCode)
        self.appendJournalLocked(
          event: success ? "native-chat-mute-ok" : "native-chat-mute-error",
          payload: [
            "chatId": chatId,
            "muted": muted,
            "status": statusCode,
          ])
        if success {
          self.postChangeLocked(
            reason: "chatMuteChanged",
            userInfo: ["chatId": chatId, "muted": muted]
          )
        }
      }
    }.resume()

    return ["accepted": true, "queued": true, "chatId": chatId, "muted": muted]
  }

  func clearChat(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }

    let requestContext: (URL, String)?
    requestContext = syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""

      historyRowsByChat.removeValue(forKey: chatId)
      if chatId == "saved_messages" {
        self.cachedSavedMessagesResponse = nil
      }
      historyLoadingChats.remove(chatId)
      liveMessageRowsByChat.removeValue(forKey: chatId)
      deletedMessageIdsByChat.removeValue(forKey: chatId)
      receiptIndex.removeValue(forKey: chatId)
      localStatusIndex.removeValue(forKey: chatId)
      pendingOutboundQueueByChat.removeValue(forKey: chatId)
      nativeTypingStateByChatId.removeValue(forKey: chatId)
      peerTypingUserIdsByChatId.removeValue(forKey: chatId)
      agentProgressByChatId.removeValue(forKey: chatId)
      nativeRecordingStateByChatId.removeValue(forKey: chatId)
      pinnedMessagesByChatId.removeValue(forKey: chatId)
      pinnedFetchInFlightChatIds.remove(chatId)
      chatPeerUserIdsByChatId.removeValue(forKey: chatId)
      openChatChannels.removeValue(forKey: chatId)

      let draftIdsToRemove = pendingOutboundDraftsByMessageId.compactMap {
        (messageId, draft) -> String? in
        let draftChatId = normalizedString(draft["chatId"] ?? draft["chat_id"])
        return draftChatId == chatId ? messageId : nil
      }
      draftIdsToRemove.forEach { pendingOutboundDraftsByMessageId.removeValue(forKey: $0) }

      if nativeJoinedChatIds.contains(chatId) {
        nativeJoinedChatIds.remove(chatId)
        if let client = phoenixClient {
          client.leave(topic: chatTopic(for: chatId))
        }
      }

      appendJournalLocked(event: "native-chat-clear-local", payload: ["chatId": chatId])
      state["updatedAt"] = nowMs()
      postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId])
      postChangeLocked(reason: "chatCleared", userInfo: ["chatId": chatId])
      return (apiBase, token)
    }

    guard let (apiBase, token) = requestContext else {
      return ["accepted": false, "reason": "missing_config", "chatId": chatId]
    }

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chats")
        .appendingPathComponent(chatId))
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          self.appendJournalLocked(
            event: "native-chat-clear-error",
            payload: [
              "chatId": chatId,
              "error": error.localizedDescription,
            ])
          return
        }
        let success = (200...299).contains(statusCode)
        self.appendJournalLocked(
          event: success ? "native-chat-clear-ok" : "native-chat-clear-error",
          payload: [
            "chatId": chatId,
            "status": statusCode,
          ])
      }
    }.resume()

    return ["accepted": true, "queued": true, "chatId": chatId]
  }

  func blockUser(_ payload: [String: Any]) -> [String: Any] {
    let blockedUserId =
      normalizedString(
        payload["blockedUserId"] ?? payload["blocked_user_id"] ?? payload["peerUserId"]
          ?? payload["peer_user_id"])
    guard let blockedUserId, !blockedUserId.isEmpty else {
      return ["accepted": false, "reason": "invalid_user"]
    }

    let requestContext: (URL, String)?
    requestContext = syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      appendJournalLocked(
        event: "native-user-block-request",
        payload: ["blockedUserId": blockedUserId]
      )
      state["updatedAt"] = nowMs()
      return (apiBase, token)
    }

    guard let (apiBase, token) = requestContext else {
      return ["accepted": false, "reason": "missing_config"]
    }

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("user")
        .appendingPathComponent("block"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["blocked_user_id": blockedUserId], options: [])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          self.appendJournalLocked(
            event: "native-user-block-error",
            payload: [
              "blockedUserId": blockedUserId,
              "error": error.localizedDescription,
            ])
          return
        }
        let success = (200...299).contains(statusCode)
        self.appendJournalLocked(
          event: success ? "native-user-block-ok" : "native-user-block-error",
          payload: [
            "blockedUserId": blockedUserId,
            "status": statusCode,
          ])
        if success {
          self.postChangeLocked(
            reason: "userBlocked",
            userInfo: ["blockedUserId": blockedUserId]
          )
        }
      }
    }.resume()

    return ["accepted": true, "queued": true, "blockedUserId": blockedUserId]
  }

  func getPinnedMessages(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) ?? ""
    let shouldRefresh = parseBooleanLike(payload["refresh"]) ?? false
    guard !chatId.isEmpty else {
      NSLog("[ChatEngine][Pin] getPinnedMessages ignored: empty chatId")
      return ["chatId": "", "loading": false, "data": []]
    }

    return syncOnQueue {
      let hasCache = pinnedMessagesByChatId[chatId] != nil
      if !hasCache {
        pinnedMessagesByChatId[chatId] = []
      }
      if (shouldRefresh || !hasCache) && !pinnedFetchInFlightChatIds.contains(chatId) {
        fetchPinnedMessagesLocked(chatId: chatId, trigger: "on_demand")
      }
      let cachedPins = pinnedMessagesByChatId[chatId] ?? []
      NSLog(
        "[ChatEngine][Pin] getPinnedMessages chatId=%@ refresh=%@ hasCache=%@ loading=%@ count=%@",
        chatId,
        shouldRefresh ? "true" : "false",
        hasCache ? "true" : "false",
        pinnedFetchInFlightChatIds.contains(chatId) ? "true" : "false",
        String(cachedPins.count)
      )
      return [
        "chatId": chatId,
        "loading": pinnedFetchInFlightChatIds.contains(chatId),
        "data": cachedPins,
      ]
    }
  }

  func pinMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    let pinned = parseBooleanLike(payload["pinned"]) ?? true
    NSLog(
      "[ChatEngine][Pin] pinMessage request chatId=%@ messageId=%@ pinned=%@",
      chatId ?? "(nil)",
      messageId ?? "(nil)",
      pinned ? "true" : "false"
    )
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    guard let messageId, !messageId.isEmpty else {
      return ["accepted": false, "reason": "invalid_message"]
    }

    let requestContext: (URL, String)?
    requestContext = syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      applyPinnedUpdateLocked(
        chatId: chatId,
        messageId: messageId,
        pinned: pinned,
        payload: [
          "messageId": messageId,
          "chatId": chatId,
          "timestamp": nowMs(),
        ],
        trigger: "local_pin_request",
        refreshRemote: false
      )
      state["updatedAt"] = nowMs()
      postChangeLocked(
        reason: "chatPinnedUpdated",
        userInfo: ["chatId": chatId, "messageId": messageId, "pinned": pinned]
      )
      return (apiBase, token)
    }

    guard let (apiBase, token) = requestContext else {
      NSLog(
        "[ChatEngine][Pin] pinMessage missing config chatId=%@ messageId=%@",
        chatId,
        messageId
      )
      return ["accepted": false, "reason": "missing_config", "chatId": chatId]
    }

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("messages")
        .appendingPathComponent(messageId).appendingPathComponent("pin"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["pinned": pinned], options: [])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          NSLog(
            "[ChatEngine][Pin] pinMessage network error chatId=%@ messageId=%@ pinned=%@ error=%@",
            chatId,
            messageId,
            pinned ? "true" : "false",
            error.localizedDescription
          )
          self.appendJournalLocked(
            event: "native-pin-message-error",
            payload: [
              "chatId": chatId,
              "messageId": messageId,
              "pinned": pinned,
              "error": error.localizedDescription,
            ])
          self.fetchPinnedMessagesLocked(chatId: chatId, trigger: "pin_error_reconcile")
          return
        }
        let success = (200...299).contains(statusCode)
        NSLog(
          "[ChatEngine][Pin] pinMessage response chatId=%@ messageId=%@ pinned=%@ status=%@ success=%@",
          chatId,
          messageId,
          pinned ? "true" : "false",
          String(statusCode),
          success ? "true" : "false"
        )
        self.appendJournalLocked(
          event: success ? "native-pin-message-ok" : "native-pin-message-error",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "pinned": pinned,
            "status": statusCode,
          ])
        self.fetchPinnedMessagesLocked(chatId: chatId, trigger: "pin_request_complete")
      }
    }.resume()

    return [
      "accepted": true, "queued": true, "chatId": chatId, "messageId": messageId, "pinned": pinned,
    ]
  }

  func getChatProfileSummary(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId, !chatId.isEmpty else {
      return [
        "chatId": "",
        "historyLoaded": false,
        "totalMessages": 0,
        "mediaCount": 0,
        "fileCount": 0,
        "linkCount": 0,
        "recentFiles": [],
      ]
    }

    return syncOnQueue {
      let rows = historyRowsByChat[chatId] ?? []
      var totalMessages = 0
      var mediaCount = 0
      var fileCount = 0
      var linkCount = 0
      var recentFiles: [String] = []

      for row in rows {
        guard normalizedString(row["kind"]) == "message" else { continue }
        guard let message = row["message"] as? [String: Any] else { continue }
        totalMessages += 1

        let type = normalizedString(message["type"])?.lowercased() ?? "text"
        let text = normalizedString(message["text"]) ?? ""
        let caption = normalizedString(message["caption"]) ?? ""
        let mediaUrl = normalizedString(message["mediaUrl"])
        let fileName = normalizedString(message["fileName"])

        let isMediaType = ["image", "gif", "video", "voice", "music"].contains(type)
        if isMediaType {
          mediaCount += 1
        }

        let isFileType = type == "file" || (!isMediaType && fileName != nil)
        if isFileType {
          fileCount += 1
          if let fileName, !fileName.isEmpty, recentFiles.count < 3 {
            recentFiles.append(fileName)
          }
        }

        let hasLink =
          containsLinkCandidate(text) || containsLinkCandidate(caption)
          || containsLinkCandidate(mediaUrl)
        if hasLink {
          let agentRegex = try? NSRegularExpression(
            pattern: "(/api/agent/document/|/uploads/agent-docs/)", options: [])
          let isAgentDoc =
            agentRegex?.firstMatch(
              in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) != nil
            || agentRegex?.firstMatch(
              in: caption, options: [], range: NSRange(location: 0, length: caption.utf16.count))
              != nil
            || agentRegex?.firstMatch(
              in: mediaUrl ?? "", options: [],
              range: NSRange(location: 0, length: (mediaUrl ?? "").utf16.count)) != nil

          if !isAgentDoc {
            linkCount += 1
          }
        }
      }

      return [
        "chatId": chatId,
        "historyLoaded": historyRowsByChat[chatId] != nil,
        "totalMessages": totalMessages,
        "mediaCount": mediaCount,
        "fileCount": fileCount,
        "linkCount": linkCount,
        "recentFiles": recentFiles,
      ]
    }
  }

  func getJournal() -> [[String: Any]] {
    store.getJournal()
  }

  func clearJournal() -> [String: Any] {
    store.clearJournal()
    return queue.sync {
      state["updatedAt"] = nowMs()
      state["journalCount"] = 0
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "journalCleared", userInfo: [:])
      return snapshot
    }
  }

  func getLiveMessageRow(_ payload: [String: Any]) -> [String: Any]? {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    guard let chatId, let messageId else { return nil }
    return syncOnQueue {
      liveMessageRowsByChat[chatId]?[messageId]
    }
  }

  func getLiveMessageRows(_ payload: [String: Any]) -> [String: [String: Any]] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return [:] }
    return syncOnQueue {
      liveMessageRowsByChat[chatId] ?? [:]
    }
  }

  func getChatRows(_ payload: [String: Any]) -> [[String: Any]] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return [] }
    return syncOnQueue {
      historyRowsByChat[chatId] ?? []
    }
  }

  func typingUserIds(chatId: String?) -> [String] {
    guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return [] }
    return syncOnQueue {
      Array(peerTypingUserIdsByChatId[chatId] ?? []).sorted()
    }
  }

  func agentProgress(chatId: String?) -> [String: Any]? {
    guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return nil }
    return syncOnQueue {
      guard let state = agentProgressByChatId[chatId] else { return nil }
      var payload: [String: Any] = [
        "label": state.label,
        "status": state.status,
        "updatedAtMs": state.updatedAtMs,
        "isActive": true,
      ]
      if let tool = state.tool {
        payload["tool"] = tool
      }
      return payload
    }
  }

  /// Returns true only if native chat history has been successfully fetched
  /// from the server for this chatId. Used by ChatListView to decide whether
  /// native rows can fully replace JS rows.
  func isChatHistoryLoaded(chatId: String) -> Bool {
    syncOnQueue {
      historyRowsByChat[chatId] != nil
    }
  }

  func isTyping(_ payload: [String: Any]) -> Bool {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return false }
    return syncOnQueue {
      !(peerTypingUserIdsByChatId[chatId]?.isEmpty ?? true)
    }
  }

  func isLiveMessageDeleted(_ payload: [String: Any]) -> Bool {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    guard let chatId, let messageId else { return false }
    return syncOnQueue {
      deletedMessageIdsByChat[chatId]?.contains(messageId) == true
    }
  }

  // Shadow-mode bridge from JS until native Phoenix transport is implemented.
  func setPresenceSnapshot(userIds: [String]) -> [String: Any] {
    let normalized = Set(userIds.compactMap { normalizedUpper($0) })
    return queue.sync {
      if nativePresenceActive {
        state["updatedAt"] = nowMs()
        appendJournalLocked(
          event: "set-presence-snapshot-ignored", payload: ["count": normalized.count])
        return statusSnapshotLocked()
      }
      onlineUsers = normalized
      for userId in normalized {
        lastSeenByUserId.removeValue(forKey: userId)
      }
      state["updatedAt"] = nowMs()
      appendJournalLocked(event: "set-presence-snapshot", payload: ["count": normalized.count])
      state["presenceSource"] = "shadow"
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "presenceChanged", userInfo: ["onlineCount": normalized.count])
      return snapshot
    }
  }

  func resolveDisplayStatus(
    chatId: String?,
    messageId: String?,
    rawStatus: String?,
    isMe: Bool,
    peerUserId: String?
  ) -> String? {
    let normalizedRaw = normalizedString(rawStatus)?.lowercased()
    guard isMe else { return normalizedRaw }

    if normalizedRaw == "read" { return "read" }

    return syncOnQueue {
      var receiptStatus: String?
      var localStatus: String?
      if let chatId, let messageId {
        receiptStatus = receiptIndex[chatId]?[messageId]
        localStatus = localStatusIndex[chatId]?[messageId]
      }
      if receiptStatus == "read" { return "read" }
      if receiptStatus == "delivered" { return "delivered" }
      if normalizedRaw == "delivered" { return "delivered" }

      if let localStatus {
        switch localStatus {
        case "error":
          return "error"
        case "sent":
          if let peer = normalizedUpper(peerUserId), onlineUsers.contains(peer) {
            return "delivered"
          }
          return "sent"
        case "pending", "sending":
          if normalizedRaw == nil || normalizedRaw == "sending" || normalizedRaw == "pending" {
            return localStatus
          }
        default:
          break
        }
      }

      if normalizedRaw == "sent",
        let peer = normalizedUpper(peerUserId),
        onlineUsers.contains(peer)
      {
        return "delivered"
      }
      return normalizedRaw
    }
  }

  private func markReceipt(
    _ payload: [String: Any],
    status: String,
    eventName: String
  ) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else { return getStatus() }
    return syncOnQueue {
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: status)
      appendJournalLocked(event: eventName, payload: payload)
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": status]
      )
      return snapshot
    }
  }

  private func sendReceipt(
    _ payload: [String: Any],
    status: String,
    eventName: String,
    wireEvent: String
  ) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else { return getStatus() }
    return syncOnQueue {
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: status)

      var accepted = false
      var ref: String?
      if let client = phoenixClient,
        nativeJoinedChatIds.contains(chatId),
        (state["connected"] as? Bool) == true
      {
        ref = client.push(
          topic: chatTopic(for: chatId), event: wireEvent, payload: ["messageId": messageId])
        accepted = true
        appendJournalLocked(
          event: "native-\(eventName)-push",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "ref": ref as Any,
          ])
      }

      appendJournalLocked(event: eventName, payload: payload)
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": status]
      )
      var out = snapshot
      out["accepted"] = accepted
      out["transport"] = accepted ? "native" : "shadow"
      if let ref { out["ref"] = ref }
      return out
    }
  }

  private func upsertReceiptLocked(chatId: String, messageId: String, status: String) {
    var chatMap = receiptIndex[chatId] ?? [:]
    let current = chatMap[messageId]
    let next = strongerStatus(current, status)
    chatMap[messageId] = next
    receiptIndex[chatId] = chatMap
    state["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    state["updatedAt"] = nowMs()
  }

  private func upsertLocalStatusLocked(chatId: String, messageId: String, status: String) {
    var chatMap = localStatusIndex[chatId] ?? [:]
    let current = chatMap[messageId]
    let next = strongerDisplayStatus(current, status)
    chatMap[messageId] = next
    localStatusIndex[chatId] = chatMap
    setLiveMessageStatusLocked(chatId: chatId, messageId: messageId, status: next)
    if next == "sent" || next == "delivered" || next == "read" || next == "error" {
      setLiveMessageUploadProgressLocked(chatId: chatId, messageId: messageId, progress: nil)
    }
    state["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    state["updatedAt"] = nowMs()
  }

  private func removeMessageIndicesLocked(chatId: String, messageId: String) {
    if var receiptChatMap = receiptIndex[chatId] {
      receiptChatMap.removeValue(forKey: messageId)
      if receiptChatMap.isEmpty {
        receiptIndex.removeValue(forKey: chatId)
      } else {
        receiptIndex[chatId] = receiptChatMap
      }
    }
    if var localChatMap = localStatusIndex[chatId] {
      localChatMap.removeValue(forKey: messageId)
      if localChatMap.isEmpty {
        localStatusIndex.removeValue(forKey: chatId)
      } else {
        localStatusIndex[chatId] = localChatMap
      }
    }
    state["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    state["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    state["updatedAt"] = nowMs()
  }

  private func strongerStatus(_ lhs: String?, _ rhs: String) -> String {
    func rank(_ value: String?) -> Int {
      switch value {
      case "read": return 2
      case "delivered": return 1
      default: return 0
      }
    }
    return rank(rhs) >= rank(lhs) ? rhs : (lhs ?? rhs)
  }

  private func strongerDisplayStatus(_ lhs: String?, _ rhs: String) -> String {
    func rank(_ value: String?) -> Int {
      switch value {
      case "read": return 5
      case "delivered": return 4
      case "sent": return 3
      case "sending": return 2
      case "pending": return 1
      case "error": return 6
      default: return 0
      }
    }
    return rank(rhs) >= rank(lhs) ? rhs : (lhs ?? rhs)
  }

  private func defaultAgentProgressLabel(tool: String?) -> String {
    switch tool {
    case "search_google":
      return "Thinking..."
    case "analyze_image":
      return "Thinking..."
    case "analyze_document":
      return "Thinking..."
    case "create_document":
      return "Updating file..."
    case "find_rows":
      return "Thinking..."
    case "edit_rows":
      return "Updating file..."
    case "delete_rows":
      return "Updating file..."
    case "export_rows":
      return "Updating file..."
    case "delete_document":
      return "Updating file..."
    case "pin_message":
      return "Pinning..."
    default:
      return "Typing..."
    }
  }

  private func setAgentProgressLocked(
    chatId: String,
    label: String?,
    tool: String?,
    status: String
  ) {
    let normalizedStatus =
      status
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .isEmpty
      ? "running"
      : status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    let shouldClear = Set([
      "done", "complete", "completed", "idle", "stopped", "stop", "error", "failed",
    ]).contains(normalizedStatus)

    if shouldClear {
      clearAgentProgressLocked(chatId: chatId, status: normalizedStatus)
      return
    }

    let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let trimmedToolValue = tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let normalizedTool = trimmedToolValue.isEmpty ? nil : trimmedToolValue
    let resolvedLabel =
      trimmedLabel.isEmpty ? defaultAgentProgressLabel(tool: normalizedTool) : trimmedLabel
    let next = AgentProgressState(
      label: resolvedLabel,
      tool: normalizedTool,
      status: normalizedStatus,
      updatedAtMs: Int64(nowMs())
    )
    let previous = agentProgressByChatId[chatId]
    guard previous != next else { return }
    agentProgressByChatId[chatId] = next
    emitAgentProgressChangeLocked(chatId: chatId, state: next)
  }

  private func clearAgentProgressLocked(chatId: String, status: String = "done") {
    guard let previous = agentProgressByChatId.removeValue(forKey: chatId) else { return }
    let normalizedStatus =
      status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "done"
      : status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    emitAgentProgressChangeLocked(
      chatId: chatId, state: nil, previous: previous, status: normalizedStatus)
  }

  private func emitAgentProgressChangeLocked(
    chatId: String,
    state: AgentProgressState?,
    previous: AgentProgressState? = nil,
    status: String? = nil
  ) {
    let snapshot = statusSnapshotLocked()
    var userInfo: [String: Any] = [
      "chatId": chatId,
      "state": snapshot,
      "isActive": state != nil,
    ]
    if let state {
      userInfo["label"] = state.label
      userInfo["status"] = state.status
      userInfo["updatedAtMs"] = state.updatedAtMs
      if let tool = state.tool {
        userInfo["tool"] = tool
      }
    } else {
      userInfo["status"] = status ?? previous?.status ?? "done"
      if let previous {
        userInfo["updatedAtMs"] = previous.updatedAtMs
      }
    }
    postChangeLocked(reason: "agentProgress", userInfo: userInfo)
  }

  private func statusSnapshotLocked() -> [String: Any] {
    var snapshot = state
    snapshot["transportMode"] = transportModeLocked()
    snapshot["activeBridgeId"] = normalizedString(getConfigValueLocked("activeBridgeId"))
    snapshot["bridgeBaseUrl"] = bridgeBaseURLLocked()?.absoluteString
    snapshot["bridgeReachable"] =
      transportModeLocked() == "bridge_text" ? ((state["connected"] as? Bool) == true) : false
    snapshot["disableCalls"] = disableCallsLocked()
    snapshot["disableMedia"] = disableMediaLocked()
    snapshot["disableRemoteAvatars"] = disableRemoteAvatarsLocked()
    snapshot["onlineUserCount"] = onlineUsers.count
    snapshot["onlineUserIds"] = Array(onlineUsers).sorted()
    snapshot["lastSeenUserCount"] = lastSeenByUserId.count
    snapshot["boundSurfaceCount"] = surfaceBindings.count
    snapshot["boundChatCount"] = Set(surfaceBindings.values.compactMap(\.chatId)).count
    snapshot["openChatChannelCount"] = openChatChannels.count
    snapshot["openChatChannels"] = openChatChannels
    snapshot["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    snapshot["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    snapshot["nativeJoinedChatCount"] = nativeJoinedChatIds.count
    snapshot["outboundDraftCount"] = pendingOutboundDraftsByMessageId.count
    snapshot["outboundQueuedCount"] = pendingOutboundQueueByChat.values.reduce(0) { $0 + $1.count }
    snapshot["typingChatCount"] = peerTypingUserIdsByChatId.count
    snapshot["typingUserCount"] = peerTypingUserIdsByChatId.values.reduce(0) { $0 + $1.count }
    snapshot["agentProgressChatCount"] = agentProgressByChatId.count
    snapshot["pinnedChatCount"] = pinnedMessagesByChatId.count
    snapshot["pinnedMessageCount"] = pinnedMessagesByChatId.values.reduce(0) { $0 + $1.count }
    snapshot["journalCount"] = store.getJournal(limit: nil).count
    return snapshot
  }

  @available(iOS 13.0, *)
  private func connectNativePresence() -> [String: Any] {
    _ = queue.sync {
      bootstrapConfigFromNativeSessionIfNeededLocked(trigger: "connect_native_presence")
    }
    let config = store.getConfig()
    let transportMode = transportModeLocked(config: config)
    let socketUrlString = normalizedString(config["socketUrl"]) ?? normalizedString(config["url"])
    let socketURL = socketUrlString.flatMap(URL.init(string:))
    let bridgeBaseURL = bridgeBaseURLLocked(config: config)
    let authToken = normalizedString(config["authToken"]) ?? normalizedString(config["token"])
    let userId = normalizedString(config["userId"])
    let userTopic =
      normalizedString(config["userChannelTopic"])
      ?? (userId != nil ? "user:\(userId!)" : nil)

    if transportMode == "offline" {
      return queue.sync {
        state["state"] = "offline"
        state["connected"] = false
        state["updatedAt"] = nowMs()
        state["note"] = "ChatEngine realtime transport disabled"
        state["transportMode"] = transportMode
        state["presenceSource"] = "shadow"
        appendJournalLocked(
          event: "connect-native-offline",
          payload: [
            "hasUserTopic": userTopic != nil,
          ])
        let snapshot = statusSnapshotLocked()
        postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return snapshot
      }
    }

    let resolvedTarget =
      transportMode == "bridge_text" ? bridgeBaseURL?.absoluteString : socketUrlString
    guard resolvedTarget != nil, let userTopic else {
      return queue.sync {
        state["state"] = "native-config-missing"
        state["connected"] = false
        state["updatedAt"] = nowMs()
        state["transportMode"] = transportMode
        state["note"] =
          transportMode == "bridge_text"
          ? "ChatEngine blackout bridge missing bridgeBaseUrl/userTopic config"
          : "ChatEngine native presence missing socketUrl/userTopic config"
        appendJournalLocked(
          event: "connect-native-missing-config",
          payload: [
            "hasSocketUrl": socketUrlString != nil,
            "hasBridgeBaseUrl": bridgeBaseURL != nil,
            "hasUserTopic": userTopic != nil,
            "hasAuthToken": authToken != nil,
            "transportMode": transportMode,
          ])
        let snapshot = statusSnapshotLocked()
        postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return snapshot
      }
    }

    let signature = "\(transportMode)|\(resolvedTarget ?? "")|\(authToken ?? "")|\(userTopic)"
    let callbacks = ChatTransportCallbacks(
      onOpen: { [weak self] in self?.handleNativeSocketOpened(userTopic: userTopic) },
      onClose: { [weak self] code, reason in
        self?.handleNativeSocketClosed(code: code, reason: reason)
      },
      onError: { [weak self] error in self?.handleNativeSocketError(error) },
      onEvent: { [weak self] frame in self?.handleNativeSocketFrame(frame) }
    )

    let clientToReplace: ChatRealtimeTransport? = queue.sync {
      autoReconnectEnabled = true
      cancelReconnectLocked()
      var clientToReplace: ChatRealtimeTransport?
      if let existing = phoenixClient, nativeSocketSignature != signature {
        clientToReplace = existing
        phoenixClient = nil
        nativePresenceActive = false
        nativeUserJoinRef = nil
        nativeUserTopic = nil
        nativeChatJoinRefsByRef.removeAll()
        nativeJoinedChatIds.removeAll()
        nativePendingMessagePushRefs.removeAll()
        nativePendingEditPushRefs.removeAll()
        nativePendingDeletePushRefs.removeAll()
        pendingOutboundDraftsByMessageId.removeAll()
        pendingOutboundQueueByChat.removeAll()
        nativeTypingStateByChatId.removeAll()
        peerTypingUserIdsByChatId.removeAll()
        agentProgressByChatId.removeAll()
        nativeRecordingStateByChatId.removeAll()
        pinnedMessagesByChatId.removeAll()
        pinnedFetchInFlightChatIds.removeAll()
        historyLoadingChats.removeAll()
        liveMessageRowsByChat.removeAll()
        deletedMessageIdsByChat.removeAll()
      }
      if phoenixClient == nil {
        if transportMode == "bridge_text", let bridgeBaseURL {
          let client = ChatBlackoutTransport(
            baseURL: bridgeBaseURL,
            authToken: authToken,
            userId: userId ?? userTopic.replacingOccurrences(of: "user:", with: ""),
            activeBridgeId: normalizedString(config["activeBridgeId"]),
            bridgeBundle: config["bridgeBundle"] as? [String: Any],
            callbacks: callbacks
          )
          phoenixClient = client
        } else if let socketURL {
          // Pass auth token separately so it goes in the Authorization header,
          // not as a URL query parameter (prevents token leakage in logs/proxies).
          let client = ChatPhoenixClient(
            baseURL: socketURL,
            params: [:],
            authToken: authToken,
            callbacks: callbacks
          )
          phoenixClient = client
        }
        nativeSocketSignature = signature
      }
      nativeUserTopic = userTopic
      state["connected"] = false
      state["state"] = "connecting-native-presence"
      state["updatedAt"] = nowMs()
      state["transportMode"] = transportMode
      state["activeBridgeId"] = normalizedString(config["activeBridgeId"])
      state["bridgeBaseUrl"] = bridgeBaseURL?.absoluteString
      state["note"] =
        transportMode == "bridge_text"
        ? "ChatEngine blackout bridge connecting"
        : "ChatEngine native Phoenix presence connecting"
      state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
      var connectPayload: [String: Any] = [
        "topic": userTopic,
        "transportMode": transportMode,
      ]
      if let bridgeBaseURL {
        connectPayload["bridgeBaseUrl"] = bridgeBaseURL.absoluteString
      }
      appendJournalLocked(event: "connect-native", payload: connectPayload)
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return clientToReplace
    }

    clientToReplace?.disconnect()
    (queue.sync { phoenixClient })?.connect()
    return getStatus()
  }

  private func handleNativeSocketOpened(userTopic: String) {
    queue.async {
      guard let client = self.phoenixClient else { return }
      self.cancelReconnectLocked()
      self.reconnectAttempt = 0
      self.state["connected"] = true
      self.state["state"] = "native-socket-open"
      self.state["updatedAt"] = self.nowMs()
      self.state["note"] = "ChatEngine native Phoenix socket open"
      NSLog("[ChatEngine] native Phoenix socket open - Triggering reconnects")
      self.appendJournalLocked(event: "native-socket-open", payload: [:])
      self.nativeUserTopic = userTopic
      self.nativeUserJoinRef = client.join(topic: userTopic, payload: [:])
      self.nativeChatJoinRefsByRef.removeAll()
      self.nativeJoinedChatIds.removeAll()
      self.nativePendingMessagePushRefs.removeAll()
      self.nativePendingEditPushRefs.removeAll()
      self.nativePendingDeletePushRefs.removeAll()
      self.nativeTypingStateByChatId.removeAll()
      self.peerTypingUserIdsByChatId.removeAll()
      self.agentProgressByChatId.removeAll()
      self.nativeRecordingStateByChatId.removeAll()
      self.pinnedMessagesByChatId.removeAll()
      self.pinnedFetchInFlightChatIds.removeAll()
      self.historyLoadingChats.removeAll()
      self.liveMessageRowsByChat.removeAll()
      self.deletedMessageIdsByChat.removeAll()
      for chatId in self.openChatChannels.keys {
        self.joinNativeChatTopicIfNeededLocked(chatId: chatId)
      }
      let queuedChats = Array(self.pendingOutboundQueueByChat.keys)
      for chatId in queuedChats {
        self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "socket_open")
      }
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
    }
  }

  private func handleNativeSocketClosed(code: Int, reason: String?) {
    queue.async {
      let inFlightMessages = Array(self.nativePendingMessagePushRefs.values)
      for pending in inFlightMessages {
        self.upsertLocalStatusLocked(
          chatId: pending.chatId, messageId: pending.messageId, status: "pending")
        if let draft = self.pendingOutboundDraftsByMessageId[pending.messageId] {
          self.queueOutboundDraftLocked(
            chatId: pending.chatId, messageId: pending.messageId, payload: draft,
            reason: "socket_closed")
        }
      }
      self.nativePresenceActive = false
      self.nativeUserJoinRef = nil
      self.nativeChatJoinRefsByRef.removeAll()
      self.nativeJoinedChatIds.removeAll()
      self.nativePendingMessagePushRefs.removeAll()
      self.nativePendingEditPushRefs.removeAll()
      self.nativePendingDeletePushRefs.removeAll()
      self.nativeTypingStateByChatId.removeAll()
      self.peerTypingUserIdsByChatId.removeAll()
      self.agentProgressByChatId.removeAll()
      self.nativeRecordingStateByChatId.removeAll()
      self.pinnedMessagesByChatId.removeAll()
      self.pinnedFetchInFlightChatIds.removeAll()
      self.historyLoadingChats.removeAll()
      self.liveMessageRowsByChat.removeAll()
      self.deletedMessageIdsByChat.removeAll()
      self.state["connected"] = false
      self.state["state"] = "native-socket-closed"
      self.state["updatedAt"] = self.nowMs()
      self.state["presenceSource"] = "shadow"
      self.appendJournalLocked(
        event: "native-socket-closed",
        payload: ["code": code, "reason": reason as Any]
      )
      self.scheduleReconnectLocked(reason: "socket_closed")
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
    }
  }

  private func handleNativeSocketError(_ error: String) {
    queue.async {
      let normalizedError = error.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let shouldForceReconnect =
        normalizedError.contains("send_failed")
        || normalizedError.contains("receive_failed")
        || normalizedError.contains("network")
        || normalizedError.contains("timed out")
        || normalizedError.contains("connection")
      if shouldForceReconnect {
        let inFlightMessages = Array(self.nativePendingMessagePushRefs.values)
        for pending in inFlightMessages {
          self.upsertLocalStatusLocked(
            chatId: pending.chatId, messageId: pending.messageId, status: "pending")
          if let draft = self.pendingOutboundDraftsByMessageId[pending.messageId] {
            self.queueOutboundDraftLocked(
              chatId: pending.chatId, messageId: pending.messageId, payload: draft,
              reason: "socket_error")
          }
        }
        self.nativePresenceActive = false
        self.nativeUserJoinRef = nil
        self.nativeChatJoinRefsByRef.removeAll()
        self.nativeJoinedChatIds.removeAll()
        self.nativePendingMessagePushRefs.removeAll()
        self.nativePendingEditPushRefs.removeAll()
        self.nativePendingDeletePushRefs.removeAll()
        self.nativeTypingStateByChatId.removeAll()
        self.peerTypingUserIdsByChatId.removeAll()
        self.agentProgressByChatId.removeAll()
        self.nativeRecordingStateByChatId.removeAll()
        self.pinnedMessagesByChatId.removeAll()
        self.pinnedFetchInFlightChatIds.removeAll()
        self.state["connected"] = false
        self.state["state"] = "native-socket-error"
        self.state["presenceSource"] = "shadow"
      }
      self.state["updatedAt"] = self.nowMs()
      self.state["lastNativeSocketError"] = error
      self.appendJournalLocked(event: "native-socket-error", payload: ["error": error])
      if shouldForceReconnect {
        self.scheduleReconnectLocked(reason: "socket_error")
      }
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "engineError", userInfo: ["state": snapshot, "error": error])
    }
  }

  @available(iOS 13.0, *)
  private func handleNativeSocketFrame(_ frame: ChatTransportFrame) {
    queue.async {
      if frame.event == "phx_reply",
        frame.topic == self.nativeUserTopic,
        let ref = frame.ref,
        ref == self.nativeUserJoinRef,
        (frame.payload["status"] as? String) == "ok"
      {
        self.nativePresenceActive = true
        self.state["presenceSource"] = "native"
        self.state["userChannelState"] = "joined"
        self.state["updatedAt"] = self.nowMs()
        self.appendJournalLocked(event: "native-user-joined", payload: ["topic": frame.topic])
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return
      }

      if frame.event == "phx_reply", let ref = frame.ref {
        if let chatId = self.nativeChatJoinRefsByRef.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          if status == "ok" {
            self.nativeJoinedChatIds.insert(chatId)
            self.appendJournalLocked(event: "native-chat-joined", payload: ["chatId": chatId])
            self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "chat_joined")
          } else {
            self.appendJournalLocked(
              event: "native-chat-join-error",
              payload: [
                "chatId": chatId, "status": status, "payload": self.makeJSONSafeMap(frame.payload),
              ]
            )
          }
          self.state["updatedAt"] = self.nowMs()
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatChannelStateChanged",
            userInfo: ["chatId": chatId, "state": snapshot]
          )
          return
        }

        if let pending = self.nativePendingMessagePushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          let nextStatus = status == "ok" ? "sent" : "error"
          if status == "ok" {
            self.removeQueuedOutboundDraftLocked(
              chatId: pending.chatId, messageId: pending.messageId, dropDraft: true)
          }
          self.upsertLocalStatusLocked(
            chatId: pending.chatId, messageId: pending.messageId, status: nextStatus)
          self.appendJournalLocked(
            event: "native-message-push-reply",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": ref,
              "status": status,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "messageStatusChanged",
            userInfo: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "status": nextStatus,
              "state": snapshot,
            ]
          )
          return
        }

        if let pending = self.nativePendingEditPushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          self.appendJournalLocked(
            event: "native-edit-message-push-reply",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": ref,
              "status": status,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatMessageEdited",
            userInfo: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "action": "edited",
              "state": snapshot,
            ]
          )
          return
        }

        if let pending = self.nativePendingDeletePushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          if status == "ok" {
            self.removeMessageIndicesLocked(chatId: pending.chatId, messageId: pending.messageId)
          }
          self.appendJournalLocked(
            event: "native-delete-message-push-reply",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": ref,
              "status": status,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatMessageDeleted",
            userInfo: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "action": "deleted",
              "state": snapshot,
            ]
          )
          return
        }
      }

      if frame.topic.hasPrefix("chat:") {
        let chatId = String(frame.topic.dropFirst(5))
        if frame.event == "agent-progress" {
          let payloadUserId = self.normalizedString(
            frame.payload["userId"] ?? frame.payload["user_id"] ?? frame.payload["id"])
          let isAgentEvent =
            (frame.payload["isAgent"] as? Bool == true)
            || payloadUserId?.lowercased() == Self.agentUserId
          if isAgentEvent {
            let label = self.normalizedString(frame.payload["label"])
            let tool = self.normalizedString(frame.payload["tool"])
            let status = self.normalizedString(frame.payload["status"]) ?? "running"
            self.setAgentProgressLocked(chatId: chatId, label: label, tool: tool, status: status)
          }
          return
        }
        if frame.event == "typing" || frame.event == "stop-typing" {
          let typing = frame.event == "typing"
          let payloadUserId = self.normalizedUpper(
            frame.payload["userId"] ?? frame.payload["user_id"] ?? frame.payload["id"])
          let myUserId = self.normalizedUpper(self.getConfigValueLocked("userId"))
          var typingUsers = self.peerTypingUserIdsByChatId[chatId] ?? Set<String>()
          if let payloadUserId, payloadUserId != myUserId {
            if typing {
              typingUsers.insert(payloadUserId)
            } else {
              typingUsers.remove(payloadUserId)
            }
            if typingUsers.isEmpty {
              self.peerTypingUserIdsByChatId.removeValue(forKey: chatId)
            } else {
              self.peerTypingUserIdsByChatId[chatId] = typingUsers
            }
          } else if !typing {
            self.peerTypingUserIdsByChatId.removeValue(forKey: chatId)
            typingUsers.removeAll()
          }
          if !typing, payloadUserId?.lowercased() == Self.agentUserId {
            self.clearAgentProgressLocked(chatId: chatId, status: "done")
          }
          let typingUserIds = Array(typingUsers).sorted()
          let isAnyTyping = !typingUserIds.isEmpty || (typing && payloadUserId == nil)
          self.postChangeLocked(
            reason: "peerTyping",
            userInfo: [
              "chatId": chatId,
              "messageId": isAnyTyping ? "true" : "false",  // Kept for ChatListView compatibility.
              "typingUserIds": typingUserIds,
            ]
          )
          return
        }
        if frame.event == "pinned-updated" {
          guard
            let messageId = self.normalizedString(
              frame.payload["messageId"] ?? frame.payload["message_id"])
          else { return }
          let pinned = self.parseBooleanLike(frame.payload["pinned"]) ?? true
          NSLog(
            "[ChatEngine][Pin] socket pinned-updated chatId=%@ messageId=%@ pinned=%@ payloadKeys=%@",
            chatId,
            messageId,
            pinned ? "true" : "false",
            Array(frame.payload.keys).sorted().joined(separator: ",")
          )
          self.applyPinnedUpdateLocked(
            chatId: chatId,
            messageId: messageId,
            pinned: pinned,
            payload: frame.payload,
            trigger: "socket_pinned_updated",
            refreshRemote: true
          )
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatPinnedUpdated",
            userInfo: [
              "chatId": chatId,
              "messageId": messageId,
              "pinned": pinned,
              "state": snapshot,
            ]
          )
          return
        }
        if frame.event == "message",
          let insertedMessageId = self.applyNativeIncomingMessageEventLocked(
            chatId: chatId, payload: frame.payload)
        {
          let fromId = self.normalizedString(frame.payload["fromId"] ?? frame.payload["from_id"])
          let isAgentMessage =
            (frame.payload["isAgentMessage"] as? Bool == true)
            || fromId?.lowercased() == Self.agentUserId
          if isAgentMessage {
            self.clearAgentProgressLocked(chatId: chatId, status: "done")
          }

          let myUserId = self.normalizedUpper(self.getConfigValueLocked("userId"))
          let isMe = self.normalizedUpper(fromId) == myUserId

          if !isMe {
            _ = self.sendDeliveryReceipt([
              "chatId": chatId,
              "messageId": insertedMessageId,
            ])
          }

          if self.peerTypingUserIdsByChatId[chatId] != nil {
            self.peerTypingUserIdsByChatId.removeValue(forKey: chatId)
            self.postChangeLocked(
              reason: "peerTyping",
              userInfo: [
                "chatId": chatId,
                "messageId": "false",
                "typingUserIds": [] as [String],
              ]
            )
          }
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatMessageInserted",
            userInfo: [
              "chatId": chatId,
              "messageId": insertedMessageId,
              "state": snapshot,
            ]
          )
          return
        }
        if let mutationUpdate = self.applyNativeChatMutationEventLocked(
          chatId: chatId, event: frame.event, payload: frame.payload)
        {
          let reason: String = {
            switch mutationUpdate.action {
            case "edited": return "chatMessageEdited"
            case "deleted": return "chatMessageDeleted"
            default: return "chatMessageChanged"
            }
          }()
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: reason,
            userInfo: [
              "chatId": chatId,
              "messageId": mutationUpdate.messageId,
              "action": mutationUpdate.action,
              "state": snapshot,
            ]
          )
          return
        }
        if let receiptUpdate = self.applyNativeChatEventLocked(
          chatId: chatId, event: frame.event, payload: frame.payload)
        {
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "messageStatusChanged",
            userInfo: [
              "chatId": chatId,
              "messageId": receiptUpdate.messageId,
              "status": receiptUpdate.status,
              "state": snapshot,
            ]
          )
          return
        }
      }

      guard frame.topic == self.nativeUserTopic else { return }
      if self.applyPresenceEventLocked(event: frame.event, payload: frame.payload) {
        self.state["presenceSource"] = "native"
        self.state["updatedAt"] = self.nowMs()
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(
          reason: "presenceChanged",
          userInfo: ["onlineCount": self.onlineUsers.count, "state": snapshot]
        )
      }
    }
  }

  private func applyPresenceEventLocked(event: String, payload: [String: Any]) -> Bool {
    switch event {
    case "initial-presence":
      let ids = (payload["onlineFriendIds"] as? [Any])?.compactMap { normalizedUpper($0) } ?? []
      onlineUsers = Set(ids)
      for userId in ids {
        lastSeenByUserId.removeValue(forKey: userId)
      }
      appendJournalLocked(event: "native-presence-initial", payload: ["count": ids.count])
      return true
    case "friend-online":
      if let userId = normalizedUpper(payload["userId"] ?? payload["user_id"] ?? payload["id"]) {
        onlineUsers.insert(userId)
        lastSeenByUserId.removeValue(forKey: userId)
        appendJournalLocked(event: "native-presence-online", payload: ["userId": userId])
        return true
      }
      return false
    case "friend-offline":
      if let userId = normalizedUpper(payload["userId"] ?? payload["user_id"] ?? payload["id"]) {
        onlineUsers.remove(userId)
        let lastSeen =
          parseLongValue(
            payload["lastSeenMs"] ?? payload["last_seen_ms"] ?? payload["lastSeen"]
              ?? payload["last_seen"])
          ?? Int64(nowMs())
        lastSeenByUserId[userId] = lastSeen
        appendJournalLocked(
          event: "native-presence-offline",
          payload: ["userId": userId, "lastSeenMs": lastSeen])
        return true
      }
      return false
    case "presence_state":
      let ids = payload.keys.compactMap { normalizedUpper($0) }
      onlineUsers = Set(ids)
      for userId in ids {
        lastSeenByUserId.removeValue(forKey: userId)
      }
      appendJournalLocked(event: "native-presence-state", payload: ["count": ids.count])
      return true
    case "presence_diff", "presence-diff":
      let joins = payload["joins"] as? [String: Any] ?? [:]
      let leaves = payload["leaves"] as? [String: Any] ?? [:]
      for id in joins.keys {
        if let normalized = normalizedUpper(id) {
          onlineUsers.insert(normalized)
          lastSeenByUserId.removeValue(forKey: normalized)
        }
      }
      for id in leaves.keys {
        if let normalized = normalizedUpper(id) {
          onlineUsers.remove(normalized)
          lastSeenByUserId[normalized] = Int64(nowMs())
        }
      }
      appendJournalLocked(
        event: "native-presence-diff",
        payload: [
          "joins": joins.keys.count,
          "leaves": leaves.keys.count,
        ])
      return true
    default:
      return false
    }
  }

  private func getConfigValueLocked(_ key: String) -> Any? {
    store.getConfig()[key]
  }

  private func transportModeLocked(config: [String: Any]? = nil) -> String {
    let resolvedConfig = config ?? store.getConfig()
    let mode =
      normalizedString(resolvedConfig["transportMode"])?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).lowercased()
    switch mode {
    case "bridge_text", "offline":
      return mode ?? "direct"
    default:
      return "direct"
    }
  }

  private func isBridgeTextModeLocked(config: [String: Any]? = nil) -> Bool {
    transportModeLocked(config: config) == "bridge_text"
  }

  private func disableMediaLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["disableMedia"])
      ?? isBridgeTextModeLocked(config: resolvedConfig)
  }

  private func disableCallsLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["disableCalls"])
      ?? isBridgeTextModeLocked(config: resolvedConfig)
  }

  private func disableRemoteAvatarsLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["disableRemoteAvatars"])
      ?? isBridgeTextModeLocked(config: resolvedConfig)
  }

  private func bridgeBaseURLLocked(config: [String: Any]? = nil) -> URL? {
    let resolvedConfig = config ?? store.getConfig()
    if let explicit = normalizedString(resolvedConfig["bridgeBaseUrl"]), let url = URL(string: explicit) {
      return url
    }
    let activeBridgeId = normalizedString(resolvedConfig["activeBridgeId"])
    let bundle = resolvedConfig["bridgeBundle"] as? [String: Any]
    let descriptors = bundle?["descriptors"] as? [[String: Any]] ?? []
    let preferred =
      descriptors.first(where: { normalizedString($0["id"]) == activeBridgeId })
      ?? descriptors.sorted { left, right in
        let leftPriority = parseLongValue(left["priority"]) ?? 999
        let rightPriority = parseLongValue(right["priority"]) ?? 999
        return leftPriority < rightPriority
      }.first
    guard let preferred else { return nil }
    if let baseUrl = normalizedString(preferred["baseUrl"]), let url = URL(string: baseUrl) {
      return url
    }
    guard let host = normalizedString(preferred["host"]) else { return nil }
    let transport = normalizedString(preferred["transport"]) == "http" ? "http" : "https"
    let port = parseLongValue(preferred["port"]).map { ":\($0)" } ?? ""
    let pathPrefix =
      normalizedString(preferred["pathPrefix"])?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let suffix = (pathPrefix?.isEmpty == false) ? "/\(pathPrefix!)" : ""
    return URL(string: "\(transport)://\(host)\(port)\(suffix)")
  }

  private func bridgeURLLocked(_ path: String, config: [String: Any]? = nil) -> URL? {
    guard let base = bridgeBaseURLLocked(config: config) else { return nil }
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return base.appendingPathComponent(trimmed)
  }

  func isJsEmergencyFallbackEnabled() -> Bool {
    queue.sync {
      switch getConfigValueLocked("chatNativeJsFallbackEnabled") {
      case let bool as Bool:
        return bool
      case let str as String:
        return ["1", "true", "yes", "on"].contains(
          str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
      case let num as NSNumber:
        return num.boolValue
      default:
        return false
      }
    }
  }

  private func extractPublicKeyValue(from data: [String: Any]) -> String? {
    normalizedString(data["publicKey"])
      ?? normalizedString(data["friendKey"])
      ?? normalizedString(data["friendPublicKey"])
      ?? normalizedString(data["public_key"])
  }

  private func cacheChatPeerInfoLocked(chatId: String, chatObject: [String: Any]) {
    if let friendId = normalizedUpper(chatObject["friendId"] ?? chatObject["friend_id"]) {
      chatPeerUserIdsByChatId[chatId] = friendId
      if let agentId = normalizedString(chatObject["friendAgentId"] ?? chatObject["friend_agent_id"]) {
        chatPeerAgentIdsByChatId[chatId] = agentId
        agentIdsByPeerUserId[friendId] = agentId
      }
      if let key = extractPublicKeyValue(from: chatObject) {
        friendPublicKeysByUserId[friendId] = key
      } else {
        scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: friendId,
          trigger: "history_peer_info"
        )
      }
    }
  }

  private func resolveFriendPublicKeyLocked(chatId: String, peerUserIdHint: String?) -> String? {
    let resolvedPeerId = peerUserIdHint ?? chatPeerUserIdsByChatId[chatId]
    if let resolvedPeerId {
      chatPeerUserIdsByChatId[chatId] = resolvedPeerId
    }
    if let resolvedPeerId, let cached = friendPublicKeysByUserId[resolvedPeerId] {
      return cached
    }
    return nil
  }

  private func resolvePeerAgentIdLocked(chatId: String, peerUserIdHint: String?) -> String? {
    if let cached = chatPeerAgentIdsByChatId[chatId], !cached.isEmpty {
      return cached
    }
    let resolvedPeerId = peerUserIdHint ?? chatPeerUserIdsByChatId[chatId]
    guard let resolvedPeerId else { return nil }
    return agentIdsByPeerUserId[resolvedPeerId]
  }

  private func scheduleFriendPublicKeyRetryLocked(peerId: String, reason: String) {
    guard pendingFriendKeyChatIdsByUserId[peerId]?.isEmpty == false else {
      friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
      friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
      return
    }
    guard friendKeyRetryWorkItemsByUserId[peerId] == nil else { return }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.queue.async {
        self.friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
        guard let chatId = self.pendingFriendKeyChatIdsByUserId[peerId]?.first else { return }
        self.scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: peerId,
          trigger: "retry_\(reason)"
        )
      }
    }
    friendKeyRetryWorkItemsByUserId[peerId] = workItem
    queue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
  }

  private func scheduleFriendPublicKeyFetchLocked(
    chatId: String,
    peerUserIdHint: String?,
    trigger: String
  ) {
    let resolvedPeerId = (peerUserIdHint ?? chatPeerUserIdsByChatId[chatId])?.uppercased()
    guard let peerId = resolvedPeerId, !peerId.isEmpty else { return }
    chatPeerUserIdsByChatId[chatId] = peerId
    if friendPublicKeysByUserId[peerId] != nil {
      scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "friend_key_cached")
      return
    }

    var pendingChats = pendingFriendKeyChatIdsByUserId[peerId] ?? Set<String>()
    pendingChats.insert(chatId)
    pendingFriendKeyChatIdsByUserId[peerId] = pendingChats

    guard !friendKeyFetchInFlightUserIds.contains(peerId) else { return }
    let isBridgeText = isBridgeTextModeLocked()
    guard let token = authHeaderTokenLocked() else { return }
    let requestURL: URL? =
      isBridgeText
      ? bridgeURLLocked("/bridge/v1/keys/peer")
      : apiBaseURLLocked()?.appendingPathComponent("api").appendingPathComponent("user")
        .appendingPathComponent(peerId)
    guard let requestURL else { return }

    friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
    friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
    friendKeyFetchInFlightUserIds.insert(peerId)

    var request = URLRequest(url: requestURL)
    request.httpMethod = isBridgeText ? "POST" : "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if isBridgeText {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 8.0
    if isBridgeText {
      request.httpBody = try? JSONSerialization.data(
        withJSONObject: ["peerUserId": peerId, "chatId": chatId], options: [])
    }
    appendJournalLocked(
      event: "friend-key-fetch-start",
      payload: ["peerUserId": peerId, "chatId": chatId, "trigger": trigger]
    )
    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.friendKeyFetchInFlightUserIds.remove(peerId)

        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let parsedObject: [String: Any]? = {
          guard error == nil,
            let statusCode,
            (200...299).contains(statusCode),
            let data
          else { return nil }
          return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }()
        let resolvedKey: String? = {
          guard let obj = parsedObject else { return nil }
          return
            self.normalizedString(obj["publicKey"])
            ?? self.normalizedString(obj["friendKey"])
            ?? self.normalizedString(obj["friendPublicKey"])
            ?? self.normalizedString(obj["public_key"])
            ?? ((obj["data"] as? [String: Any]).flatMap(self.extractPublicKeyValue(from:)))
        }()
        let resolvedAgentId: String? = {
          guard let obj = parsedObject else { return nil }
          let nested = obj["data"] as? [String: Any]
          let isAgent =
            (obj["isAgent"] as? Bool == true)
            || (nested?["isAgent"] as? Bool == true)
          guard isAgent else { return nil }
          return
            self.normalizedString(obj["agentId"] ?? obj["agent_id"])
            ?? self.normalizedString(nested?["agentId"] ?? nested?["agent_id"])
        }()

        let waitingChatIds = Array(self.pendingFriendKeyChatIdsByUserId[peerId] ?? [])
        if let resolvedAgentId, !resolvedAgentId.isEmpty {
          self.agentIdsByPeerUserId[peerId] = resolvedAgentId
          for waitingChatId in waitingChatIds {
            self.chatPeerAgentIdsByChatId[waitingChatId] = resolvedAgentId
          }
        }
        if let resolvedKey {
          self.friendPublicKeysByUserId[peerId] = resolvedKey
          for waitingChatId in waitingChatIds {
            self.chatPeerUserIdsByChatId[waitingChatId] = peerId
          }
          self.pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerId)
          self.friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
          self.friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
          self.appendJournalLocked(
            event: "friend-key-fetch-ok",
            payload: ["peerUserId": peerId, "chatCount": waitingChatIds.count]
          )
          for waitingChatId in waitingChatIds {
            self.scheduleReplayQueuedOutboundLocked(
              chatId: waitingChatId, trigger: "friend_key_loaded")
          }
          return
        }

        if let resolvedAgentId, !resolvedAgentId.isEmpty {
          self.pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerId)
          self.friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
          self.friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
          self.appendJournalLocked(
            event: "friend-key-fetch-agent-ok",
            payload: [
              "peerUserId": peerId,
              "chatCount": waitingChatIds.count,
              "agentId": resolvedAgentId,
            ]
          )
          for waitingChatId in waitingChatIds {
            self.scheduleReplayQueuedOutboundLocked(
              chatId: waitingChatId, trigger: "peer_agent_loaded")
          }
          return
        }

        self.appendJournalLocked(
          event: "friend-key-fetch-error",
          payload: [
            "peerUserId": peerId,
            "chatCount": waitingChatIds.count,
            "status": statusCode as Any,
            "error": error?.localizedDescription as Any,
          ])
        let shouldRetry = waitingChatIds.contains {
          !(self.pendingOutboundQueueByChat[$0]?.isEmpty ?? true)
        }
        if shouldRetry {
          self.scheduleFriendPublicKeyRetryLocked(peerId: peerId, reason: "fetch_failed")
        } else {
          self.pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerId)
        }
      }
    }.resume()
  }

  private func currentUserIdLocked() -> String? {
    normalizedUpper(getConfigValueLocked("userId"))
  }

  private func decryptPrivateKeyLocked() -> SecKey? {
    guard
      let pem = normalizedString(
        getConfigValueLocked("privateKeyPem") ?? getConfigValueLocked("privateKey"))
    else {
      print("[ChatEngine] decryptPrivateKeyLocked — no privateKeyPem in config")
      return nil
    }
    // Check TTL: clear cached key if it has expired to limit in-memory exposure.
    if let ts = cachedDecryptKeyTimestamp, Date().timeIntervalSince(ts) >= keyTTL {
      cachedDecryptPrivateKey = nil
      cachedDecryptPrivateKeyPem = nil
      cachedDecryptKeyTimestamp = nil
    }
    if cachedDecryptPrivateKeyPem == pem {
      if let cached = cachedDecryptPrivateKey {
        cachedDecryptKeyTimestamp = Date()
        return cached
      }
      if let ts = cachedDecryptKeyTimestamp, Date().timeIntervalSince(ts) < keyTTL {
        return nil
      }
    }
    let key = chatEnginePrivateKey(from: pem)
    if key == nil {
      print(
        "[ChatEngine] decryptPrivateKeyLocked — parsing FAILED, pem.count=\(pem.count) prefix=\(pem.prefix(50))"
      )
    }
    cachedDecryptPrivateKeyPem = pem
    cachedDecryptPrivateKey = key
    cachedDecryptKeyTimestamp = Date()
    return key
  }

  private func parseLongValue(_ value: Any?) -> Int64? {
    if let n = value as? NSNumber { return n.int64Value }
    if let s = value as? String { return Int64(s) }
    return nil
  }

  private func parseDoubleValue(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
  }

  private func parseWaveformArray(_ value: Any?) -> [Double]? {
    let rawList: [Any]
    if let array = value as? [Any] {
      rawList = array
    } else if let nsArray = value as? NSArray {
      rawList = nsArray.compactMap { $0 }
    } else {
      return nil
    }
    let mapped = rawList.compactMap { parseDoubleValue($0) }.map { max(0.0, min(1.0, $0)) }
    return mapped.isEmpty ? nil : mapped
  }

  private func deriveFileNameFromURL(_ rawURL: String?) -> String? {
    guard let rawURL = normalizedString(rawURL), !rawURL.isEmpty else { return nil }
    let normalizedPath = rawURL.split(separator: "?", maxSplits: 1).first.map(String.init)
    let name = (normalizedPath ?? rawURL).split(separator: "/").last.map(String.init)
    guard let name else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func isLikelyHybridCiphertext(_ raw: String?) -> Bool {
    guard let raw = normalizedString(raw) else { return false }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
      return false
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      return false
    }
    return json["iv"] != nil && json["c"] != nil && json["k"] != nil
  }

  private func parseDecryptedMessagePayload(_ raw: String) -> [String: Any] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
      return ["text": raw]
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      return ["text": raw]
    }
    var out: [String: Any] = [:]
    if let text = json["text"] { out["text"] = text }
    if let mediaUrl = json["mediaUrl"] { out["mediaUrl"] = mediaUrl }
    if let mediaKey = json["mediaKey"] { out["mediaKey"] = mediaKey }
    if let fileName = json["fileName"] { out["fileName"] = fileName }
    if let fileSize = json["fileSize"] { out["fileSize"] = fileSize }
    if let latitude = json["latitude"] { out["latitude"] = latitude }
    if let longitude = json["longitude"] { out["longitude"] = longitude }
    if let duration = json["duration"] { out["duration"] = duration }
    if let replyToId = json["replyToId"] { out["replyToId"] = replyToId }
    if let contact = json["contact"] { out["contact"] = contact }
    if let caption = json["caption"] { out["caption"] = caption }
    if let viewOnce = json["viewOnce"] { out["viewOnce"] = viewOnce }
    if let isEdited = json["isEdited"] { out["isEdited"] = isEdited }
    if let editedAt = json["editedAt"] { out["editedAt"] = editedAt }
    if let waveform = json["waveform"] { out["waveform"] = waveform }
    if let isVideoNote = json["isVideoNote"] { out["isVideoNote"] = isVideoNote }
    if let width = json["width"] { out["width"] = width }
    if let height = json["height"] { out["height"] = height }
    if let thumbnailBase64 = json["thumbnailBase64"] { out["thumbnailBase64"] = thumbnailBase64 }
    if let stickerId = json["stickerId"] { out["stickerId"] = stickerId }
    if let stickerPackId = json["stickerPackId"] ?? json["packId"] {
      out["stickerPackId"] = stickerPackId
    }
    if let stickerBundleFileName = json["stickerBundleFileName"] ?? json["bundleFileName"] {
      out["stickerBundleFileName"] = stickerBundleFileName
    }
    if let emoji = json["emoji"] { out["emoji"] = emoji }
    if out["text"] == nil {
      out["text"] = raw
    }
    return out
  }

  private func formatMessageTimeLabel(timestampMs: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0))
  }

  private func upsertLiveMessageRowLocked(chatId: String, messageId: String, row: [String: Any]) {
    var perChat = liveMessageRowsByChat[chatId] ?? [:]
    perChat[messageId] = row
    liveMessageRowsByChat[chatId] = perChat
    if var deleted = deletedMessageIdsByChat[chatId] {
      deleted.remove(messageId)
      if deleted.isEmpty {
        deletedMessageIdsByChat.removeValue(forKey: chatId)
      } else {
        deletedMessageIdsByChat[chatId] = deleted
      }
    }
  }

  private func mutateLiveMessagePayloadLocked(
    chatId: String,
    messageId: String,
    mutate: (inout [String: Any]) -> Void
  ) {
    guard var perChat = liveMessageRowsByChat[chatId],
      var row = perChat[messageId],
      var message = row["message"] as? [String: Any]
    else {
      return
    }
    mutate(&message)
    row["message"] = message
    perChat[messageId] = row
    liveMessageRowsByChat[chatId] = perChat
  }

  private func setLiveMessageStatusLocked(chatId: String, messageId: String, status: String) {
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      message["status"] = status
    }
  }

  @discardableResult
  private func setLiveMessageUploadProgressLocked(
    chatId: String,
    messageId: String,
    progress: Double?
  ) -> Bool {
    let normalizedProgress: Double?
    if let progress, progress.isFinite {
      normalizedProgress = max(0.0, min(1.0, progress))
    } else {
      normalizedProgress = nil
    }

    let existingProgress: Double? = {
      guard let perChat = liveMessageRowsByChat[chatId],
        let row = perChat[messageId],
        let message = row["message"] as? [String: Any]
      else {
        return nil
      }
      return parseDoubleValue(message["uploadProgress"])
        ?? parseDoubleValue((message["metadata"] as? [String: Any])?["uploadProgress"])
    }()

    let isUnchanged: Bool = {
      switch (existingProgress, normalizedProgress) {
      case (nil, nil):
        return true
      case let (lhs?, rhs?):
        return abs(lhs - rhs) < 0.004
      default:
        return false
      }
    }()
    if isUnchanged {
      return false
    }

    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      if let clamped = normalizedProgress {
        message["uploadProgress"] = clamped
        var metadata = (message["metadata"] as? [String: Any]) ?? [:]
        metadata["uploadProgress"] = clamped
        message["metadata"] = metadata
      } else {
        message.removeValue(forKey: "uploadProgress")
        if var metadata = message["metadata"] as? [String: Any] {
          metadata.removeValue(forKey: "uploadProgress")
          if metadata.isEmpty {
            message.removeValue(forKey: "metadata")
          } else {
            message["metadata"] = metadata
          }
        }
      }
    }
    return true
  }

  private func markLiveMessageDeletedLocked(chatId: String, messageId: String) {
    if var perChat = liveMessageRowsByChat[chatId] {
      perChat.removeValue(forKey: messageId)
      if perChat.isEmpty {
        liveMessageRowsByChat.removeValue(forKey: chatId)
      } else {
        liveMessageRowsByChat[chatId] = perChat
      }
    }
    var deleted = deletedMessageIdsByChat[chatId] ?? Set<String>()
    deleted.insert(messageId)
    deletedMessageIdsByChat[chatId] = deleted
  }

  private func findMessagePayloadLocked(chatId: String, messageId: String) -> [String: Any]? {
    if let liveMessage = liveMessageRowsByChat[chatId]?[messageId]?["message"] as? [String: Any] {
      return liveMessage
    }
    guard let rows = historyRowsByChat[chatId] else { return nil }
    for row in rows {
      guard normalizedString(row["kind"]) == "message" else { continue }
      guard let message = row["message"] as? [String: Any] else { continue }
      if normalizedString(message["id"]) == messageId {
        return message
      }
    }
    return nil
  }

  private func buildLiveRowPayloadLocked(
    chatId: String,
    messageId: String,
    fromId: String?,
    type: String?,
    timestampMs: Int64,
    encryptedContent: String?,
    decryptedFields: [String: Any],
    forceEdited: Bool = false,
    forceEditedAt: Any? = nil
  ) -> [String: Any] {
    let normalizedType = normalizedString(type)?.lowercased() ?? "text"
    let normalizedFrom = normalizedString(fromId)
    let isMe =
      normalizedUpper(normalizedFrom) != nil
      && normalizedUpper(normalizedFrom) == currentUserIdLocked()
    let text = normalizedString(decryptedFields["text"]) ?? ""
    let mediaUrl = normalizedString(decryptedFields["mediaUrl"])
    let localMediaUrl = normalizedString(
      decryptedFields["localMediaUrl"] ?? decryptedFields["local_media_url"])
    let fileName = normalizedString(decryptedFields["fileName"])
    let fileSize = parseLongValue(decryptedFields["fileSize"])
    let latitude = parseDoubleValue(decryptedFields["latitude"])
    let longitude = parseDoubleValue(decryptedFields["longitude"])
    let duration = parseDoubleValue(decryptedFields["duration"])
    let replyToId = normalizedString(decryptedFields["replyToId"])
    let caption = normalizedString(decryptedFields["caption"])
    let waveform = parseWaveformArray(decryptedFields["waveform"])
    let isEdited = forceEdited || ((decryptedFields["isEdited"] as? Bool) == true)
    let editedAt = forceEditedAt ?? decryptedFields["editedAt"]

    var metadata: [String: Any] = [:]
    if let waveform { metadata["waveform"] = waveform }
    if let width = decryptedFields["width"] { metadata["width"] = width }
    if let height = decryptedFields["height"] { metadata["height"] = height }
    if let thumbnailBase64 = decryptedFields["thumbnailBase64"] {
      metadata["thumbnailBase64"] = thumbnailBase64
    }
    if let isVideoNote = decryptedFields["isVideoNote"] { metadata["isVideoNote"] = isVideoNote }
    if let fileSize { metadata["fileSize"] = fileSize }
    if let latitude { metadata["latitude"] = latitude }
    if let longitude { metadata["longitude"] = longitude }
    if let viewOnce = decryptedFields["viewOnce"] { metadata["viewOnce"] = viewOnce }
    if let contact = decryptedFields["contact"] { metadata["contact"] = contact }
    if let caption { metadata["caption"] = caption }
    if let mediaKey = decryptedFields["mediaKey"] { metadata["mediaKey"] = mediaKey }
    if let localMediaUrl { metadata["localMediaUrl"] = localMediaUrl }
    if let stickerId = normalizedString(decryptedFields["stickerId"]) {
      metadata["stickerId"] = stickerId
    }
    if let stickerPackId = normalizedString(
      decryptedFields["stickerPackId"] ?? decryptedFields["packId"])
    {
      metadata["stickerPackId"] = stickerPackId
      metadata["packId"] = stickerPackId
    }
    if let stickerBundleFileName = normalizedString(
      decryptedFields["stickerBundleFileName"] ?? decryptedFields["bundleFileName"])
    {
      metadata["stickerBundleFileName"] = stickerBundleFileName
      metadata["bundleFileName"] = stickerBundleFileName
    }
    if let emoji = normalizedString(decryptedFields["emoji"]) {
      metadata["emoji"] = emoji
    }

    var message: [String: Any] = [
      "id": messageId,
      "chatId": chatId,
      "timestampMs": Double(timestampMs),
      "timestamp": formatMessageTimeLabel(timestampMs: timestampMs),
      "text": text,
      "type": normalizedType,
      "isMe": isMe,
      "isEdited": isEdited,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": 18,
        "borderBottomRightRadius": 18,
        "borderBottomLeftRadius": 18,
      ],
    ]
    if let normalizedFrom { message["fromId"] = normalizedFrom }
    if isMe { message["status"] = "sent" }
    if let editedAt { message["editedAt"] = editedAt }
    if let encryptedContent { message["encryptedContent"] = encryptedContent }
    if let mediaUrl { message["mediaUrl"] = mediaUrl }
    if let localMediaUrl { message["localMediaUrl"] = localMediaUrl }
    if let fileName { message["fileName"] = fileName }
    if let duration { message["duration"] = duration }
    if let replyToId { message["replyToId"] = replyToId }
    if let caption { message["caption"] = caption }
    if let contact = decryptedFields["contact"] { message["contact"] = contact }
    if !metadata.isEmpty { message["metadata"] = metadata }

    return [
      "kind": "message",
      "key": "m-\(messageId)",
      "message": message,
    ]
  }

  private static let agentUserId = "00000000-0000-0000-0000-000000000001"

  private func applyNativeIncomingMessageEventLocked(chatId: String, payload: [String: Any])
    -> String?
  {
    guard let messageId = normalizedString(payload["id"] ?? payload["message_id"]) else {
      return nil
    }
    let fromId = normalizedString(payload["fromId"] ?? payload["from_id"])
    let encryptedContent = normalizedString(
      payload["encryptedContent"] ?? payload["encrypted_content"])
    let type = normalizedString(payload["type"]) ?? "text"
    let timestampMs = parseLongValue(payload["timestamp"]) ?? Int64(nowMs())
    let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
    let rawMediaUrl = normalizedString(payload["mediaUrl"] ?? payload["media_url"])
    let rawFileName = normalizedString(payload["fileName"] ?? payload["file_name"])
    let rawMediaKey = normalizedString(payload["mediaKey"] ?? payload["media_key"])
    let derivedFileName = deriveFileNameFromURL(rawMediaUrl)
    let encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)

    // Detect agent messages by fromId or explicit flag
    let isAgentMessage =
      (payload["isAgentMessage"] as? Bool == true)
      || (payload["is_agent_message"] as? Bool == true)
      || (normalizedString(fromId)?.lowercased() == Self.agentUserId)
      || normalizedString(payload["agentId"] ?? payload["agent_id"]) != nil
      || normalizedString(payload["agentName"] ?? payload["agent_name"]) != nil
      || (rawMediaUrl?.lowercased().contains("/uploads/agent-docs/") == true)
      || (rawMediaUrl?.lowercased().contains("/api/agent/document/") == true)
    let plainContent =
      normalizedString(payload["plainContent"] ?? payload["plain_content"] ?? payload["plaintext"])
    let agentName = normalizedString(payload["agentName"] ?? payload["agent_name"])
    let agentId = normalizedString(payload["agentId"] ?? payload["agent_id"])

    let hadEncryptedContent = encryptedContent != nil && !encryptedContent!.isEmpty
    let decryptedText: String = {
      // Agent messages use plainContent instead of encryption
      if isAgentMessage, let plainContent, !plainContent.isEmpty {
        return plainContent
      }
      guard let encryptedContent, !encryptedContent.isEmpty else {
        return ""
      }
      if !encryptedLooksHybrid {
        return encryptedContent
      }
      guard let privateKey = decryptPrivateKeyLocked() else { return "" }
      return chatEngineDecryptHybridMessage(
        privateKey: privateKey, ciphertext: encryptedContent, isMyMessage: isMe)
    }()
    let decryptionFailed =
      !isAgentMessage && hadEncryptedContent && encryptedLooksHybrid && decryptedText.isEmpty

    var decryptedFields = parseDecryptedMessagePayload(decryptedText)
    if let rawMediaUrl, !rawMediaUrl.isEmpty, normalizedString(decryptedFields["mediaUrl"]) == nil {
      decryptedFields["mediaUrl"] = rawMediaUrl
    }
    if let rawMediaKey, !rawMediaKey.isEmpty, normalizedString(decryptedFields["mediaKey"]) == nil {
      decryptedFields["mediaKey"] = rawMediaKey
    }
    let fileNameForRow =
      rawFileName
      ?? ((normalizedString(type)?.lowercased() == "file") ? derivedFileName : nil)
    if let fileNameForRow, !fileNameForRow.isEmpty,
      normalizedString(decryptedFields["fileName"]) == nil
    {
      decryptedFields["fileName"] = fileNameForRow
    }
    var row = buildLiveRowPayloadLocked(
      chatId: chatId,
      messageId: messageId,
      fromId: fromId,
      type: type,
      timestampMs: timestampMs,
      encryptedContent: encryptedContent,
      decryptedFields: decryptedFields
    )
    // Inject agent-specific fields into the message payload for the UI layer
    if isAgentMessage, var message = row["message"] as? [String: Any] {
      message["isAgentMessage"] = true
      message["isMe"] = false
      if let agentName { message["agentName"] = agentName }
      if let agentId { message["agentId"] = agentId }
      if let plainContent { message["plainContent"] = plainContent }
      // Use plainContent as the display text for agent messages
      if let plainContent, !plainContent.isEmpty { message["text"] = plainContent }
      row["message"] = message
    }
    // Signal decryption failure to the UI layer so it can show an appropriate indicator
    // instead of a blank bubble.
    if decryptionFailed, var message = row["message"] as? [String: Any] {
      message["decryptionFailed"] = true
      row["message"] = message
    }
    if ["image", "gif", "file", "voice", "video", "music", "sticker"].contains(type.lowercased()), isMe,
      let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId),
      let localPlaybackUrl = extractLocalPlaybackMediaURLFromMessage(existingMessage)
    {
      NSLog(
        "[ChatEngine] preserve local media url on incoming echo chatId=%@ messageId=%@ local=%@",
        chatId,
        messageId,
        localPlaybackUrl
      )
      row = mergeLocalPlaybackMediaURLIntoRow(row: row, localUrl: localPlaybackUrl)
    }
    upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: row)
    appendJournalLocked(
      event: "native-message-row-upsert",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "type": type,
      ])
    state["updatedAt"] = nowMs()
    return messageId
  }

  private func extractLocalPlaybackMediaURLFromMessage(_ message: [String: Any]) -> String? {
    let metadata = message["metadata"] as? [String: Any]
    let candidates: [Any?] = [
      message["localMediaUrl"],
      message["local_media_url"],
      metadata?["localMediaUrl"],
      metadata?["local_media_url"],
      message["mediaUrl"],
      message["media_url"],
      metadata?["mediaUrl"],
      metadata?["media_url"],
      message["uri"],
      metadata?["uri"],
      message["audioUrl"],
      message["audio_url"],
      metadata?["audioUrl"],
      metadata?["audio_url"],
    ]
    for candidate in candidates {
      guard let value = normalizedString(candidate), isLocalMediaURI(value) else { continue }
      return value
    }
    return nil
  }

  private func mergeLocalPlaybackMediaURLIntoRow(row: [String: Any], localUrl: String) -> [String:
    Any]
  {
    var mutableRow = row
    guard var message = mutableRow["message"] as? [String: Any] else {
      return mutableRow
    }
    message["localMediaUrl"] = localUrl
    var metadata = (message["metadata"] as? [String: Any]) ?? [:]
    metadata["localMediaUrl"] = localUrl
    message["metadata"] = metadata
    mutableRow["message"] = message
    return mutableRow
  }

  private func applyNativeChatMutationEventLocked(
    chatId: String,
    event: String,
    payload: [String: Any]
  ) -> (messageId: String, action: String)? {
    guard !chatId.isEmpty else { return nil }
    guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else {
      return nil
    }
    switch event {
    case "message-edited":
      let editedAtValue = payload["editedAt"] ?? payload["edited_at"]
      let encryptedContent = normalizedString(
        payload["encryptedContent"] ?? payload["encrypted_content"])
      let existingRow = liveMessageRowsByChat[chatId]?[messageId]
      let existingMessage = existingRow?["message"] as? [String: Any]
      let existingMetadata = existingMessage?["metadata"] as? [String: Any]
      let fromId = normalizedString(existingMessage?["fromId"])
      let type = normalizedString(existingMessage?["type"]) ?? "text"
      let timestampMs =
        parseLongValue(existingMessage?["timestampMs"] ?? existingMessage?["timestamp"])
        ?? Int64(nowMs())
      let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
      let decryptedFields: [String: Any] = {
        guard let encryptedContent, !encryptedContent.isEmpty else {
          return [:]
        }
        if !isLikelyHybridCiphertext(encryptedContent) {
          return parseDecryptedMessagePayload(encryptedContent)
        }
        guard let privateKey = decryptPrivateKeyLocked() else { return [:] }
        let decrypted = chatEngineDecryptHybridMessage(
          privateKey: privateKey,
          ciphertext: encryptedContent,
          isMyMessage: isMe
        )
        return parseDecryptedMessagePayload(decrypted)
      }()
      var hydratedFields = decryptedFields
      if normalizedString(hydratedFields["mediaUrl"]) == nil {
        hydratedFields["mediaUrl"] =
          existingMessage?["mediaUrl"] ?? existingMessage?["media_url"]
          ?? existingMetadata?["mediaUrl"] ?? existingMetadata?["media_url"]
      }
      if normalizedString(hydratedFields["fileName"]) == nil {
        hydratedFields["fileName"] =
          existingMessage?["fileName"] ?? existingMessage?["file_name"]
          ?? existingMetadata?["fileName"] ?? existingMetadata?["file_name"]
      }
      if normalizedString(hydratedFields["mediaKey"]) == nil {
        hydratedFields["mediaKey"] =
          existingMessage?["mediaKey"] ?? existingMessage?["media_key"]
          ?? existingMetadata?["mediaKey"] ?? existingMetadata?["media_key"]
      }
      if hydratedFields["thumbnailBase64"] == nil {
        hydratedFields["thumbnailBase64"] =
          existingMessage?["thumbnailBase64"] ?? existingMessage?["thumbnail_base64"]
          ?? existingMetadata?["thumbnailBase64"] ?? existingMetadata?["thumbnail_base64"]
      }
      let row = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: fromId,
        type: type,
        timestampMs: timestampMs,
        encryptedContent: encryptedContent
          ?? normalizedString(existingMessage?["encryptedContent"]),
        decryptedFields: hydratedFields,
        forceEdited: true,
        forceEditedAt: editedAtValue
      )
      upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: row)
      appendJournalLocked(
        event: "native-message-edited",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "editedAt": editedAtValue as Any,
        ])
      state["updatedAt"] = nowMs()
      return (messageId, "edited")
    case "message-deleted":
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      applyPinnedUpdateLocked(
        chatId: chatId,
        messageId: messageId,
        pinned: false,
        payload: [:],
        trigger: "message_deleted",
        refreshRemote: false
      )
      appendJournalLocked(
        event: "native-message-deleted",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
        ])
      state["updatedAt"] = nowMs()
      return (messageId, "deleted")
    default:
      return nil
    }
  }

  private func applyNativeChatEventLocked(
    chatId: String,
    event: String,
    payload: [String: Any]
  ) -> (messageId: String, status: String)? {
    guard !chatId.isEmpty else { return nil }
    switch event {
    case "message-delivered":
      guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else {
        return nil
      }
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: "delivered")
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "delivered")
      appendJournalLocked(
        event: "native-message-delivered",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
        ])
      return (messageId, "delivered")
    case "message-read":
      guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else {
        return nil
      }
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: "read")
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "read")
      appendJournalLocked(
        event: "native-message-read",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
        ])
      return (messageId, "read")
    default:
      return nil
    }
  }

  private func fetchPinnedMessagesLocked(chatId: String, trigger: String) {
    guard !chatId.isEmpty else { return }
    guard !pinnedFetchInFlightChatIds.contains(chatId) else {
      NSLog(
        "[ChatEngine][Pin] fetchPinnedMessages skipped (in-flight) chatId=%@ trigger=%@",
        chatId,
        trigger
      )
      return
    }
    guard let apiBase = apiBaseURLLocked() else {
      NSLog(
        "[ChatEngine][Pin] fetchPinnedMessages skipped (missing apiBase) chatId=%@ trigger=%@",
        chatId,
        trigger
      )
      return
    }
    let token = authHeaderTokenLocked() ?? ""

    pinnedFetchInFlightChatIds.insert(chatId)
    NSLog(
      "[ChatEngine][Pin] fetchPinnedMessages start chatId=%@ trigger=%@ tokenPresent=%@",
      chatId,
      trigger,
      token.isEmpty ? "false" : "true"
    )
    appendJournalLocked(
      event: "native-pinned-load-start",
      payload: ["chatId": chatId, "trigger": trigger]
    )

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("pinned_messages"))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.pinnedFetchInFlightChatIds.remove(chatId)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        if let error {
          NSLog(
            "[ChatEngine][Pin] fetchPinnedMessages network error chatId=%@ trigger=%@ error=%@",
            chatId,
            trigger,
            error.localizedDescription
          )
          self.appendJournalLocked(
            event: "native-pinned-load-error",
            payload: [
              "chatId": chatId,
              "trigger": trigger,
              "error": error.localizedDescription,
            ])
          self.postChangeLocked(
            reason: "chatPinnedUpdated",
            userInfo: ["chatId": chatId, "loading": false]
          )
          return
        }

        guard (200...299).contains(statusCode), let data else {
          NSLog(
            "[ChatEngine][Pin] fetchPinnedMessages http error chatId=%@ trigger=%@ status=%@",
            chatId,
            trigger,
            String(statusCode)
          )
          self.appendJournalLocked(
            event: "native-pinned-load-error",
            payload: [
              "chatId": chatId,
              "trigger": trigger,
              "status": statusCode,
            ])
          self.postChangeLocked(
            reason: "chatPinnedUpdated",
            userInfo: ["chatId": chatId, "loading": false]
          )
          return
        }

        let nextPins = self.parsePinnedMessagesResponse(data: data, chatId: chatId)
        let nextPinIds = nextPins.compactMap {
          self.normalizedString($0["messageId"] ?? $0["message_id"])
        }
        NSLog(
          "[ChatEngine][Pin] fetchPinnedMessages ok chatId=%@ trigger=%@ status=%@ count=%@ ids=%@",
          chatId,
          trigger,
          String(statusCode),
          String(nextPins.count),
          nextPinIds.joined(separator: ",")
        )
        let previousPins = self.pinnedMessagesByChatId[chatId] ?? []
        let previousIds = Set(
          previousPins.compactMap { self.normalizedString($0["messageId"] ?? $0["message_id"]) })
        let nextIds = Set(
          nextPins.compactMap { self.normalizedString($0["messageId"] ?? $0["message_id"]) })
        let allIds = previousIds.union(nextIds)
        for messageId in allIds {
          self.setMessagePinnedStateLocked(
            chatId: chatId,
            messageId: messageId,
            pinned: nextIds.contains(messageId)
          )
        }

        self.pinnedMessagesByChatId[chatId] = nextPins
        self.state["updatedAt"] = self.nowMs()
        self.appendJournalLocked(
          event: "native-pinned-load-ok",
          payload: [
            "chatId": chatId,
            "trigger": trigger,
            "count": nextPins.count,
            "status": statusCode,
          ])
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(
          reason: "chatPinnedUpdated",
          userInfo: [
            "chatId": chatId,
            "loading": false,
            "count": nextPins.count,
            "state": snapshot,
          ]
        )
      }
    }.resume()
  }

  private func parsePinnedMessagesResponse(data: Data, chatId: String) -> [[String: Any]] {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let response = object as? [String: Any]
    else {
      return []
    }

    let rawItems = (response["data"] as? [Any]) ?? []
    return rawItems.compactMap { rawItem in
      guard let raw = rawItem as? [String: Any] else { return nil }
      return normalizePinnedEntry(raw, chatId: chatId)
    }
  }

  private func normalizePinnedEntry(
    _ raw: [String: Any],
    chatId: String,
    fallbackMessageId: String? = nil
  ) -> [String: Any]? {
    let messageId =
      normalizedString(raw["messageId"] ?? raw["message_id"] ?? raw["id"] ?? fallbackMessageId)
    guard let messageId, !messageId.isEmpty else { return nil }

    var entry: [String: Any] = [
      "messageId": messageId,
      "chatId": chatId,
    ]
    if let pinnedAt = raw["pinnedAt"] ?? raw["pinned_at"] {
      entry["pinnedAt"] = pinnedAt
    } else {
      entry["pinnedAt"] = nowMs()
    }
    if let timestamp = raw["timestamp"] ?? raw["messageTimestamp"] ?? raw["message_timestamp"] {
      entry["timestamp"] = timestamp
    }
    if let type = normalizedString(raw["type"] ?? raw["messageType"] ?? raw["message_type"]) {
      entry["type"] = type
    }
    if let mediaURL = normalizedString(raw["mediaUrl"] ?? raw["media_url"]) {
      entry["mediaUrl"] = mediaURL
    }
    if let fileName = normalizedString(raw["fileName"] ?? raw["file_name"]) {
      entry["fileName"] = fileName
    }
    if let text = normalizedString(raw["text"] ?? raw["plainContent"] ?? raw["plain_content"]) {
      entry["text"] = text
    }
    return entry
  }

  private func applyPinnedUpdateLocked(
    chatId: String,
    messageId: String,
    pinned: Bool,
    payload: [String: Any],
    trigger: String,
    refreshRemote: Bool
  ) {
    setMessagePinnedStateLocked(chatId: chatId, messageId: messageId, pinned: pinned)

    var pins = pinnedMessagesByChatId[chatId] ?? []
    pins.removeAll {
      normalizedString($0["messageId"] ?? $0["message_id"]) == messageId
    }
    if pinned {
      let entry =
        normalizePinnedEntry(payload, chatId: chatId, fallbackMessageId: messageId)
        ?? [
          "messageId": messageId,
          "chatId": chatId,
          "pinnedAt": nowMs(),
        ]
      pins.insert(entry, at: 0)
    }
    pinnedMessagesByChatId[chatId] = pins
    NSLog(
      "[ChatEngine][Pin] applyPinnedUpdate chatId=%@ messageId=%@ pinned=%@ trigger=%@ pinCount=%@",
      chatId,
      messageId,
      pinned ? "true" : "false",
      trigger,
      String(pins.count)
    )
    state["updatedAt"] = nowMs()
    appendJournalLocked(
      event: "native-pinned-updated",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "pinned": pinned,
        "trigger": trigger,
      ])
    if refreshRemote {
      fetchPinnedMessagesLocked(chatId: chatId, trigger: trigger)
    }
  }

  private func setMessagePinnedStateLocked(chatId: String, messageId: String, pinned: Bool) {
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      message["isPinned"] = pinned
      message["pinned"] = pinned
    }

    guard var rows = historyRowsByChat[chatId] else { return }
    var changed = false
    for index in rows.indices {
      guard normalizedString(rows[index]["kind"]) == "message" else { continue }
      guard var message = rows[index]["message"] as? [String: Any] else { continue }
      guard normalizedString(message["id"]) == messageId else { continue }
      message["isPinned"] = pinned
      message["pinned"] = pinned
      var row = rows[index]
      row["message"] = message
      rows[index] = row
      changed = true
    }
    if changed {
      historyRowsByChat[chatId] = rows
    }
  }

  private func joinNativeChatTopicIfNeededLocked(chatId: String) {
    guard !chatId.isEmpty else { return }
    // Always start HTTP history fetch immediately — do NOT gate behind socket state.
    // This ensures messages load fast even before WebSocket is connected.
    loadChatHistoryIfNeededLocked(chatId: chatId)
    guard let client = phoenixClient else {
      scheduleReconnectLocked(reason: "join_chat_no_socket")
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "join_chat_no_socket")
      }
      return
    }
    guard state["connected"] as? Bool == true else {
      scheduleReconnectLocked(reason: "join_chat_not_connected")
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "join_chat_not_connected")
      }
      return
    }
    if nativeJoinedChatIds.contains(chatId) { return }
    if nativeChatJoinRefsByRef.values.contains(chatId) { return }
    let ref = client.join(topic: chatTopic(for: chatId), payload: [:])
    nativeChatJoinRefsByRef[ref] = chatId
    appendJournalLocked(event: "native-chat-join-start", payload: ["chatId": chatId, "ref": ref])
  }

  private func queueOutboundDraftLocked(
    chatId: String, messageId: String, payload: [String: Any], reason: String
  ) {
    pendingOutboundDraftsByMessageId[messageId] = payload
    var ids = pendingOutboundQueueByChat[chatId] ?? []
    if ids.contains(messageId) { return }
    ids.append(messageId)
    pendingOutboundQueueByChat[chatId] = ids
    appendJournalLocked(
      event: "native-outgoing-queued",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "reason": reason,
      ])
    persistOutboundStateLocked()
    postChangeLocked(
      reason: "outgoingMessageQueued",
      userInfo: [
        "chatId": chatId,
        "messageId": messageId,
        "reason": reason,
      ])
  }

  private func removeQueuedOutboundDraftLocked(chatId: String, messageId: String, dropDraft: Bool) {
    if var ids = pendingOutboundQueueByChat[chatId] {
      ids.removeAll { $0 == messageId }
      if ids.isEmpty {
        pendingOutboundQueueByChat.removeValue(forKey: chatId)
      } else {
        pendingOutboundQueueByChat[chatId] = ids
      }
    }
    if dropDraft {
      pendingOutboundDraftsByMessageId.removeValue(forKey: messageId)
    }
    persistOutboundStateLocked()
  }

  private func scheduleReplayQueuedOutboundLocked(chatId: String, trigger: String) {
    let ids = pendingOutboundQueueByChat[chatId] ?? []
    NSLog(
      "[ChatEngine] scheduleReplayQueuedOutboundLocked chatId=%@ trigger=%@ count=%d", chatId,
      trigger, ids.count)
    guard !ids.isEmpty else { return }
    var drafts: [[String: Any]] = []
    for messageId in ids {
      if nativePendingMessagePushRefs.values.contains(where: {
        $0.chatId == chatId && $0.messageId == messageId
      }) {
        continue
      }
      if let draft = pendingOutboundDraftsByMessageId[messageId] {
        drafts.append(draft)
      }
    }
    guard !drafts.isEmpty else { return }
    appendJournalLocked(
      event: "native-outgoing-replay-scheduled",
      payload: [
        "chatId": chatId,
        "count": drafts.count,
        "trigger": trigger,
      ])
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      for draft in drafts {
        _ = self.sendMessage(draft)
      }
    }
  }

  private func chatTopic(for chatId: String) -> String {
    "chat:\(chatId)"
  }

  private struct LocalMediaUploadResult {
    let remoteUrl: String
    let fileName: String?
    let fileSize: Int64?
    let mediaKey: String?
  }

  private struct LocalMediaUploadOutcome {
    let result: LocalMediaUploadResult?
    let reason: String?
  }

  private func isLocalMediaURI(_ raw: String) -> Bool {
    raw.hasPrefix("file://") || raw.hasPrefix("/") || raw.hasPrefix("content://")
  }

  private func uploadCategory(for messageType: String) -> String {
    switch messageType {
    case "image", "gif":
      return "image"
    case "voice", "music":
      return "audio"
    case "video":
      return "video"
    default:
      return "file"
    }
  }

  private func shouldEncryptUploadedMediaType(_ messageType: String) -> Bool {
    switch messageType {
    case "image", "gif", "voice", "music", "video", "file", "sticker":
      return true
    default:
      return false
    }
  }

  private func mediaMimeType(fileName: String, fallbackType: String) -> String {
    let ext = (fileName as NSString).pathExtension.lowercased()
    if !ext.isEmpty {
      switch ext {
      case "jpg", "jpeg":
        return "image/jpeg"
      case "png":
        return "image/png"
      case "gif":
        return "image/gif"
      case "webp":
        return "image/webp"
      case "heic":
        return "image/heic"
      case "m4a":
        return "audio/mp4"
      case "mp3":
        return "audio/mpeg"
      case "wav":
        return "audio/wav"
      case "aac":
        return "audio/aac"
      case "mp4":
        return "video/mp4"
      case "mov":
        return "video/quicktime"
      default:
        break
      }
    }
    switch fallbackType {
    case "image", "gif":
      return "image/jpeg"
    case "voice", "music":
      return "audio/mp4"
    case "video":
      return "video/mp4"
    default:
      return "application/octet-stream"
    }
  }

  private func resolveUploadURL(apiBase: URL) -> URL? {
    var base = apiBase.absoluteString
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if base.hasSuffix("/api") {
      base = String(base.dropLast(4))
    }
    return URL(string: base + "/api/media/upload")
  }

  private func localFileURL(from rawURI: String) -> URL? {
    if rawURI.hasPrefix("file://"), let url = URL(string: rawURI), url.isFileURL {
      return url
    }
    if rawURI.hasPrefix("/") {
      return URL(fileURLWithPath: rawURI)
    }
    return nil
  }

  private func appendMultipartField(body: inout Data, boundary: String, name: String, value: String)
  {
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append(
      "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
    body.append("\(value)\r\n".data(using: .utf8) ?? Data())
  }

  fileprivate class UploadSessionDelegate: PinnedSessionDelegate, URLSessionTaskDelegate,
    URLSessionDataDelegate
  {
    var onProgress: ((Float) -> Void)?
    var onCompletion: ((Data?, HTTPURLResponse?, Error?) -> Void)?
    var responseData = Data()
    private var lastEmitTime: TimeInterval = 0
    private var lastEmittedProgress: Float = 0

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
      totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
      guard totalBytesExpectedToSend > 0 else { return }
      let progress = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
      let now = CACurrentMediaTime()
      let shouldEmit =
        progress >= 0.999
        || progress <= 0.0
        || (progress - lastEmittedProgress) >= 0.01
        || (now - lastEmitTime) >= (1.0 / 30.0)
      if shouldEmit {
        lastEmitTime = now
        lastEmittedProgress = progress
        onProgress?(progress)
      }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      onCompletion?(responseData, task.response as? HTTPURLResponse, error)
    }
  }

  private func uploadLocalMediaLocked(
    localUri: String,
    messageType: String,
    fileNameHint: String?,
    userId: String,
    token: String,
    apiBase: URL,
    messageId: String? = nil,
    onProgress: ((Float) -> Void)? = nil
  ) -> LocalMediaUploadOutcome {
    guard let fileURL = localFileURL(from: localUri) else {
      return LocalMediaUploadOutcome(result: nil, reason: "invalid_local_media_uri")
    }
    let normalizedURL = fileURL.standardizedFileURL
    guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
      return LocalMediaUploadOutcome(result: nil, reason: "media_file_missing")
    }
    let fileData: Data
    do {
      fileData = try Data(contentsOf: normalizedURL, options: [.mappedIfSafe])
    } catch {
      return LocalMediaUploadOutcome(result: nil, reason: "media_file_read_failed")
    }
    let originalFileSize = Int64(fileData.count)
    let resolvedFileName = fileNameHint ?? normalizedURL.lastPathComponent
    let resolvedMimeType = mediaMimeType(fileName: resolvedFileName, fallbackType: messageType)
    let uploadType = uploadCategory(for: messageType)
    guard let uploadURL = resolveUploadURL(apiBase: apiBase) else {
      return LocalMediaUploadOutcome(result: nil, reason: "invalid_upload_url")
    }
    let uploadFileData: Data
    let mediaKey: String?
    if shouldEncryptUploadedMediaType(messageType) {
      do {
        let encrypted = try chatEngineEncryptMediaData(fileData)
        uploadFileData = encrypted.encryptedData
        mediaKey = encrypted.keyBase64
      } catch {
        return LocalMediaUploadOutcome(result: nil, reason: "media_encrypt_failed")
      }
    } else {
      uploadFileData = fileData
      mediaKey = nil
    }

    let boundary = "----VibeChatBoundary\(UUID().uuidString)"
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 35

    var body = Data()
    appendMultipartField(body: &body, boundary: boundary, name: "user_id", value: userId)
    appendMultipartField(body: &body, boundary: boundary, name: "type", value: uploadType)
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"\(resolvedFileName)\"\r\n".data(
        using: .utf8) ?? Data())
    body.append("Content-Type: \(resolvedMimeType)\r\n\r\n".data(using: .utf8) ?? Data())
    body.append(uploadFileData)
    body.append("\r\n".data(using: .utf8) ?? Data())
    body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())
    let delegate = UploadSessionDelegate()
    delegate.onProgress = onProgress

    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var responseCode: Int?
    var responseError: Error?

    delegate.onCompletion = { data, res, error in
      if let error {
        responseError = error
      }
      responseCode = res?.statusCode
      responseData = data
      semaphore.signal()
    }

    let session = ChatPhoenixClient.makePinnedURLSession(delegate: delegate)
    let task = session.uploadTask(with: request, from: body)
    if let messageId, !messageId.isEmpty {
      syncOnQueue {
        activeMediaUploadTasksByMessageId[messageId] = task
      }
    }
    task.resume()
    let waitResult = semaphore.wait(timeout: .now() + 40.0)
    if waitResult == .timedOut {
      task.cancel()
      if let messageId, !messageId.isEmpty {
        syncOnQueue {
          if activeMediaUploadTasksByMessageId[messageId] === task {
            activeMediaUploadTasksByMessageId.removeValue(forKey: messageId)
          }
        }
      }
      return LocalMediaUploadOutcome(result: nil, reason: "upload_timeout")
    }
    if let messageId, !messageId.isEmpty {
      syncOnQueue {
        if activeMediaUploadTasksByMessageId[messageId] === task {
          activeMediaUploadTasksByMessageId.removeValue(forKey: messageId)
        }
      }
    }
    if
      let nsError = responseError as NSError?,
      nsError.domain == NSURLErrorDomain,
      nsError.code == NSURLErrorCancelled
    {
      return LocalMediaUploadOutcome(result: nil, reason: "upload_canceled")
    }
    if responseError != nil {
      return LocalMediaUploadOutcome(result: nil, reason: "upload_failed")
    }
    guard let responseCode, (200...299).contains(responseCode), let responseData else {
      return LocalMediaUploadOutcome(result: nil, reason: "upload_failed")
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
      let remoteUrl = normalizedString(json["url"] ?? json["mediaUrl"] ?? json["media_url"])
    else {
      return LocalMediaUploadOutcome(result: nil, reason: "invalid_upload_response")
    }
    return LocalMediaUploadOutcome(
      result: LocalMediaUploadResult(
        remoteUrl: remoteUrl,
        fileName: resolvedFileName,
        fileSize: originalFileSize,
        mediaKey: mediaKey),
      reason: nil
    )
  }

  private func apiBaseURLLocked() -> URL? {
    if let configured = normalizedString(
      getConfigValueLocked("apiBaseUrl") ?? getConfigValueLocked("baseUrl")),
      let url = URL(string: configured)
    {
      return url
    }
    guard
      let socketUrl = normalizedString(
        getConfigValueLocked("socketUrl") ?? getConfigValueLocked("url")),
      var components = URLComponents(string: socketUrl)
    else { return nil }
    if components.scheme == "wss" { components.scheme = "https" }
    if components.scheme == "ws" { components.scheme = "http" }
    if components.path.hasSuffix("/socket") {
      components.path = String(components.path.dropLast("/socket".count))
    }
    return components.url
  }

  private func originString(from base: URL) -> String? {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { return nil }
    return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func sanitizeOpenURLString(_ raw: String) -> String {
    let trimmed =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

    return
      trimmed
      .replacingOccurrences(
        of: #"^https?:\/\/\[(https?:\/\/[^\]]+)\](\/.*)?$"#,
        with: "$1$2",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"^\[(https?:\/\/[^\]]+)\](\/.*)?$"#,
        with: "$1$2",
        options: .regularExpression
      )
      .replacingOccurrences(of: "https://https://", with: "https://")
      .replacingOccurrences(of: "http://http://", with: "http://")
  }

  private func resolveURLForOpenLocked(_ raw: String?) -> String? {
    guard let raw = normalizedString(raw), !raw.isEmpty else { return nil }
    let sanitized = sanitizeOpenURLString(raw)
    guard !sanitized.isEmpty else { return nil }

    if let url = URL(string: sanitized), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https" || scheme == "file"
    {
      return url.absoluteString
    }

    if sanitized.hasPrefix("/uploads/") || sanitized.hasPrefix("uploads/"),
      let base = apiBaseURLLocked(),
      let origin = originString(from: base)
    {
      let path = sanitized.hasPrefix("/") ? sanitized : "/" + sanitized
      return origin + path
    }

    if sanitized.hasPrefix("/"), let base = apiBaseURLLocked(),
      let origin = originString(from: base)
    {
      return origin + sanitized
    }

    return sanitized
  }

  private func authHeaderTokenLocked() -> String? {
    normalizedString(getConfigValueLocked("authToken") ?? getConfigValueLocked("token"))
  }

  private func loadChatHistoryIfNeededLocked(chatId: String, force: Bool = false) {
    guard !chatId.isEmpty else { return }
    if historyLoadingChats.contains(chatId) { return }
    if !force, historyFullyLoadedChats.contains(chatId) { return }
    let isBridgeText = isBridgeTextModeLocked()
    let apiBase = apiBaseURLLocked()
    let bridgeURL = bridgeURLLocked("/bridge/v1/chat/history")
    guard let userId = normalizedString(getConfigValueLocked("userId")),
      (isBridgeText ? bridgeURL != nil : apiBase != nil)
    else {
      NSLog(
        "[ChatEngine] loadChatHistory SKIP chatId=%@ reason=missing_config",
        String(chatId.prefix(12)))
      appendJournalLocked(
        event: "native-chat-history-skip",
        payload: [
          "chatId": chatId,
          "reason": "missing_config",
        ])
      return
    }

    // saved_messages uses a different API endpoint: /api/saved_messages/{userId}
    let isSavedMessages = chatId == "saved_messages"

    historyLoadingChats.insert(chatId)
    let token = authHeaderTokenLocked()
    let finalUrl: URL
    var request: URLRequest
    if isBridgeText, let bridgeURL {
      finalUrl = bridgeURL
      request = URLRequest(url: finalUrl)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(
        withJSONObject: [
          "chatId": chatId,
          "userId": userId,
          "limit": 15,
          "savedMessages": isSavedMessages,
        ],
        options: []
      )
    } else if isSavedMessages, let apiBase {
      finalUrl = apiBase.appendingPathComponent("api").appendingPathComponent("saved_messages")
        .appendingPathComponent(userId)
      request = URLRequest(url: finalUrl)
      request.httpMethod = "GET"
    } else if let apiBase {
      let baseMessageUrl = apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("messages")
      var urlComponents = URLComponents(url: baseMessageUrl, resolvingAgainstBaseURL: false)
      urlComponents?.queryItems = [URLQueryItem(name: "limit", value: "15")]
      finalUrl = urlComponents?.url ?? baseMessageUrl
      request = URLRequest(url: finalUrl)
      request.httpMethod = "GET"
    } else {
      historyLoadingChats.remove(chatId)
      return
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let fetchStartMs = self.nowMs()
    NSLog(
      "[ChatEngine] loadChatHistory START chatId=%@ url=%@", String(chatId.prefix(12)),
      request.url?.absoluteString ?? "nil")
    appendJournalLocked(event: "native-chat-history-load-start", payload: ["chatId": chatId])

    // Use a pinned URLSession with the same cert pinning + TLS enforcement
    // as the WebSocket connection, instead of URLSession.shared.
    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        let durationMs = self.nowMs() - fetchStartMs
        self.historyLoadingChats.remove(chatId)
        if let error {
          NSLog(
            "[ChatEngine] loadChatHistory FAIL chatId=%@ duration=%lldms error=%@",
            String(chatId.prefix(12)), durationMs, error.localizedDescription)
          self.appendJournalLocked(
            event: "native-chat-history-load-error",
            payload: [
              "chatId": chatId,
              "error": error.localizedDescription,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "engineError",
            userInfo: ["state": snapshot, "error": error.localizedDescription])
          return
        }
        guard let http = response as? HTTPURLResponse else {
          NSLog(
            "[ChatEngine] loadChatHistory FAIL chatId=%@ duration=%lldms error=invalid_response",
            String(chatId.prefix(12)), durationMs)
          self.appendJournalLocked(
            event: "native-chat-history-load-error",
            payload: [
              "chatId": chatId,
              "error": "invalid_response",
            ])
          return
        }
        guard (200...299).contains(http.statusCode), let data else {
          NSLog(
            "[ChatEngine] loadChatHistory FAIL chatId=%@ duration=%lldms status=%d",
            String(chatId.prefix(12)), durationMs, http.statusCode)
          self.appendJournalLocked(
            event: "native-chat-history-load-error",
            payload: [
              "chatId": chatId,
              "status": http.statusCode,
            ])
          return
        }
        NSLog(
          "[ChatEngine] loadChatHistory OK chatId=%@ duration=%lldms bytes=%d",
          String(chatId.prefix(12)),
          durationMs, data.count)
        if isSavedMessages {
          self.applySavedMessagesHistoryResponseLocked(data: data)
        } else {
          self.applyChatHistoryResponseLocked(chatId: chatId, data: data)
        }
      }
    }.resume()
  }

  private func applyChatHistoryResponseLocked(chatId: String, data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      appendJournalLocked(
        event: "native-chat-history-load-error",
        payload: [
          "chatId": chatId,
          "error": "invalid_json_expected_messages_array",
        ])
      return
    }

    let messagesArray: [[String: Any]]
    if let array = object as? [[String: Any]] {
      messagesArray = array
    } else if let dict = object as? [String: Any], let array = dict["data"] as? [[String: Any]] {
      messagesArray = array
    } else if let dict = object as? [String: Any], let array = dict["messages"] as? [[String: Any]]
    {
      messagesArray = array
    } else {
      appendJournalLocked(
        event: "native-chat-history-load-error",
        payload: [
          "chatId": chatId,
          "error": "invalid_json_expected_messages_array",
        ])
      return
    }

    let rows = buildHistoryRowsLocked(chatId: chatId, rawMessages: messagesArray)
    historyRowsByChat[chatId] = rows
    historyFullyLoadedChats.insert(chatId)
    state["updatedAt"] = nowMs()
    appendJournalLocked(
      event: "native-chat-history-load-ok",
      payload: [
        "chatId": chatId,
        "rows": rows.count,
        "messages": messagesArray.count,
      ])
    scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "history_loaded")
    let snapshot = statusSnapshotLocked()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
  }

  private func applySavedMessagesHistoryResponseLocked(data: Data) {
    let chatId = "saved_messages"
    let rawItems = parseSavedMessagesServerItems(data)
    guard !rawItems.isEmpty else {
      appendJournalLocked(
        event: "native-chat-history-load-error",
        payload: [
          "chatId": chatId,
          "error": "empty_saved_messages_response",
        ])
      historyFullyLoadedChats.insert(chatId)
      if historyRowsByChat[chatId] == nil {
        historyRowsByChat[chatId] = []
      }
      cachedSavedMessagesResponse = []
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
      return
    }
    let normalized = normalizeSavedMessagesLocked(rawItems)
    cachedSavedMessagesResponse = normalized
    let rows = buildHistoryRowsLocked(chatId: chatId, rawMessages: normalized)
    historyRowsByChat[chatId] = rows
    historyFullyLoadedChats.insert(chatId)
    state["updatedAt"] = nowMs()
    appendJournalLocked(
      event: "native-chat-history-load-ok",
      payload: [
        "chatId": chatId,
        "rows": rows.count,
        "messages": rawItems.count,
      ])
    scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "history_loaded")
    let snapshot = statusSnapshotLocked()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
  }

  private func buildHistoryRowsLocked(chatId: String, rawMessages: [[String: Any]]) -> [[String:
    Any]]
  {
    let sortedMessages = rawMessages.sorted { lhs, rhs in
      let lt = parseLongValue(lhs["timestamp"] ?? lhs["timestampMs"] ?? lhs["timestamp_ms"]) ?? 0
      let rt = parseLongValue(rhs["timestamp"] ?? rhs["timestampMs"] ?? rhs["timestamp_ms"]) ?? 0
      return lt < rt
    }
    return sortedMessages.compactMap { raw in
      guard let messageId = normalizedString(raw["id"] ?? raw["message_id"]) else { return nil }
      let fromId = normalizedString(raw["fromId"] ?? raw["from_id"])
      let type = normalizedString(raw["type"]) ?? "text"
      let timestampMs =
        parseLongValue(raw["timestamp"] ?? raw["timestampMs"] ?? raw["timestamp_ms"])
        ?? Int64(nowMs())
      let encryptedContent = normalizedString(raw["encryptedContent"] ?? raw["encrypted_content"])
      let plaintextFallback = normalizedString(raw["plaintext"] ?? raw["text"]) ?? ""
      let serverStatus = normalizedString(raw["status"])?.lowercased()
      let isEdited = ((raw["isEdited"] as? Bool) == true)
      let editedAt = raw["editedAt"] ?? raw["edited_at"]
      let rawMediaUrl = normalizedString(raw["mediaUrl"] ?? raw["media_url"])
      let rawFileName = normalizedString(raw["fileName"] ?? raw["file_name"])
      let rawMediaKey = normalizedString(raw["mediaKey"] ?? raw["media_key"])
      let derivedFileName = deriveFileNameFromURL(rawMediaUrl)

      let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
      let encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)
      let historyIsAgent =
        (raw["isAgentMessage"] as? Bool == true)
        || (raw["is_agent_message"] as? Bool == true)
        || (normalizedString(fromId)?.lowercased() == Self.agentUserId)
        || normalizedString(raw["agentId"] ?? raw["agent_id"]) != nil
        || normalizedString(raw["agentName"] ?? raw["agent_name"]) != nil
        || (rawMediaUrl?.lowercased().contains("/uploads/agent-docs/") == true)
        || (rawMediaUrl?.lowercased().contains("/api/agent/document/") == true)
      let agentPlainContent =
        normalizedString(raw["plainContent"] ?? raw["plain_content"])
        ?? normalizedString(raw["plaintext"])
        ?? encryptedContent
      let hadEncryptedContent = encryptedContent != nil && !encryptedContent!.isEmpty
      var historyDecryptionFailed = false
      let decryptedFields: [String: Any] = {
        if historyIsAgent {
          if let agentPlainContent, !agentPlainContent.isEmpty {
            return ["text": agentPlainContent]
          }
          return [:]
        }

        if let encryptedContent, !encryptedContent.isEmpty {
          if !encryptedLooksHybrid {
            return parseDecryptedMessagePayload(encryptedContent)
          }
          guard let privateKey = decryptPrivateKeyLocked() else {
            historyDecryptionFailed = true
            return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
          }
          let decrypted = chatEngineDecryptHybridMessage(
            privateKey: privateKey,
            ciphertext: encryptedContent,
            isMyMessage: isMe
          )
          if decrypted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            historyDecryptionFailed = true
            return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
          }
          let parsed = parseDecryptedMessagePayload(decrypted)
          if !parsed.isEmpty { return parsed }
          historyDecryptionFailed = true
        }
        return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
      }()
      var enrichedFields = decryptedFields
      if let rawMediaUrl, !rawMediaUrl.isEmpty, normalizedString(enrichedFields["mediaUrl"]) == nil
      {
        enrichedFields["mediaUrl"] = rawMediaUrl
      }
      if let rawMediaKey, !rawMediaKey.isEmpty, normalizedString(enrichedFields["mediaKey"]) == nil {
        enrichedFields["mediaKey"] = rawMediaKey
      }
      let fileNameForRow =
        rawFileName
        ?? ((normalizedString(type)?.lowercased() == "file") ? derivedFileName : nil)
      if let fileNameForRow, !fileNameForRow.isEmpty,
        normalizedString(enrichedFields["fileName"]) == nil
      {
        enrichedFields["fileName"] = fileNameForRow
      }
      var row = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: fromId,
        type: type,
        timestampMs: timestampMs,
        encryptedContent: encryptedContent,
        decryptedFields: enrichedFields,
        forceEdited: isEdited,
        forceEditedAt: editedAt
      )
      if historyIsAgent, var message = row["message"] as? [String: Any] {
        message["isAgentMessage"] = true
        message["isMe"] = false
        if let agentId = normalizedString(raw["agentId"] ?? raw["agent_id"]) {
          message["agentId"] = agentId
        }
        if let name = normalizedString(raw["agentName"] ?? raw["agent_name"]) {
          message["agentName"] = name
        }
        if let agentPlainContent, !agentPlainContent.isEmpty {
          message["plainContent"] = agentPlainContent
          message["text"] = agentPlainContent
        }
        row["message"] = message
      }
      if var message = row["message"] as? [String: Any] {
        if let serverStatus { message["status"] = serverStatus }
        if let reactionEmoji = normalizedString(raw["reactionEmoji"] ?? raw["reaction_emoji"]) {
          message["reactionEmoji"] = reactionEmoji
        }
        if !historyIsAgent && hadEncryptedContent && encryptedLooksHybrid && historyDecryptionFailed
        {
          message["decryptionFailed"] = true
        }
        row["message"] = message
      }
      return row
    }
  }

  private func appendJournalLocked(event: String, payload: [String: Any]) {
    store.appendJournal([
      "event": event,
      "timestamp": nowMs(),
      "payload": sanitizeJournalPayload(makeJSONSafeMap(payload)),
    ])
  }

  /// Truncate sensitive identifiers in journal payloads to prevent
  /// leaking full chat/message/user IDs in plaintext storage.
  private func sanitizeJournalPayload(_ payload: [String: Any]) -> [String: Any] {
    let sensitiveKeys: Set<String> = ["chatId", "messageId", "userId", "peerUserId", "fromId"]
    var out = payload
    for key in sensitiveKeys {
      if let value = out[key] as? String, value.count > 8 {
        out[key] = String(value.prefix(8)) + "..."
      }
    }
    return out
  }

  private func postChangeLocked(reason: String, userInfo: [String: Any]) {
    var info = userInfo
    info["reason"] = reason
    info["timestamp"] = nowMs()
    if ["chatMessageInserted", "chatMessageChanged", "chatRowsReloaded", "presenceChanged"]
      .contains(reason)
    {
      let rawChatId =
        (info["chatId"] as? String) ??
        (info["chat_id"] as? String) ??
        ""
      let chatId =
        rawChatId.count > 12 ? String(rawChatId.prefix(12)) + "..." : rawChatId
      print(
        "[ChatEngine] didChange reason=\(reason) chatId=\(chatId.isEmpty ? "<empty>" : chatId)"
      )
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: info)
  }

  private func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
  }

  private func syncOnQueue<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: queueSpecificKey) == queueSpecificValue {
      return work()
    }
    return queue.sync(execute: work)
  }

  private func normalizedString(_ value: Any?) -> String? {
    if let str = value as? String {
      let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }
    if let n = value as? NSNumber {
      return n.stringValue
    }
    return nil
  }

  private func parseBooleanLike(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
      return bool
    case let str as String:
      let normalized = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["1", "true", "yes", "on"].contains(normalized) {
        return true
      }
      if ["0", "false", "no", "off"].contains(normalized) {
        return false
      }
      return nil
    case let num as NSNumber:
      return num.boolValue
    default:
      return nil
    }
  }

  private func containsLinkCandidate(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    let lower = value.lowercased()
    return lower.contains("http://") || lower.contains("https://") || lower.contains("www.")
  }

  private func normalizedUpper(_ value: Any?) -> String? {
    normalizedString(value)?.uppercased()
  }

  private func makeJSONSafeMap(_ payload: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in payload {
      if JSONSerialization.isValidJSONObject(["v": value]) {
        out[key] = value
      } else {
        out[key] = String(describing: value)
      }
    }
    return out
  }

  private var requestContext: (URL, String)? {
    syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      return (apiBase, token)
    }
  }

  private func parseSavedMessagesServerItems(_ data: Data) -> [[String: Any]] {
    let json = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? []
    if let items = json as? [[String: Any]] {
      return items
    }
    if let dict = json as? [String: Any], let items = dict["data"] as? [[String: Any]] {
      return items
    }
    if let dict = json as? [String: Any], let items = dict["messages"] as? [[String: Any]] {
      return items
    }
    return []
  }

  private func parseJSONObjectString(_ raw: Any?) -> [String: Any] {
    guard let text = normalizedString(raw), let data = text.data(using: .utf8) else { return [:] }
    guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else {
      return [:]
    }
    return json as? [String: Any] ?? [:]
  }

  private func normalizeSavedMessagesLocked(_ rawItems: [[String: Any]]) -> [[String: Any]] {
    let privateKey = decryptPrivateKeyLocked()
    let currentUserId = currentUserIdLocked()

    return rawItems.compactMap { raw in
      guard
        let messageId = normalizedString(
          raw["original_message_id"] ?? raw["messageId"] ?? raw["message_id"] ?? raw["id"])
      else { return nil }

      let fromId =
        normalizedString(raw["from_id"] ?? raw["fromId"])
        ?? normalizedString(getConfigValueLocked("userId"))
      let type = normalizedString(raw["type"])?.lowercased() ?? "text"
      let timestampMs =
        parseLongValue(raw["timestamp"] ?? raw["timestampMs"] ?? raw["timestamp_ms"])
        ?? Int64(nowMs())
      let encryptedContent =
        normalizedString(raw["encrypted_content"] ?? raw["encryptedContent"])
      let parsedExtra = parseJSONObjectString(raw["extra"])
      var decryptedFields = parsedExtra

      let plaintextFallback =
        normalizedString(raw["content"] ?? raw["plaintext"] ?? raw["text"]) ?? ""
      if !plaintextFallback.isEmpty {
        decryptedFields["text"] = plaintextFallback
      }

      if let encryptedContent, !encryptedContent.isEmpty {
        let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserId
        let parsedEncryptedFields: [String: Any]
        if !isLikelyHybridCiphertext(encryptedContent) {
          parsedEncryptedFields = parseDecryptedMessagePayload(encryptedContent)
        } else if let privateKey {
          let decrypted = chatEngineDecryptHybridMessage(
            privateKey: privateKey,
            ciphertext: encryptedContent,
            isMyMessage: isMe
          )
          parsedEncryptedFields = parseDecryptedMessagePayload(decrypted)
        } else {
          parsedEncryptedFields = [:]
        }
        for (key, value) in parsedEncryptedFields where decryptedFields[key] == nil {
          decryptedFields[key] = value
        }
      }

      let resolvedText = normalizedString(decryptedFields["text"]) ?? plaintextFallback
      let resolvedMediaUrl =
        normalizedString(
          decryptedFields["mediaUrl"] ?? raw["media_url"] ?? raw["mediaUrl"])
      let resolvedFileName =
        normalizedString(
          decryptedFields["fileName"] ?? raw["file_name"] ?? raw["fileName"])
      let resolvedMediaKey = normalizedString(
        decryptedFields["mediaKey"] ?? raw["media_key"] ?? raw["mediaKey"])
      let resolvedLatitude = parseDoubleValue(decryptedFields["latitude"])
      let resolvedLongitude = parseDoubleValue(decryptedFields["longitude"])
      let resolvedDuration = parseDoubleValue(decryptedFields["duration"])
      let resolvedEditedAt = parseLongValue(
        decryptedFields["editedAt"] ?? raw["edited_at"] ?? raw["editedAt"])

      var normalized: [String: Any] = [
        "id": messageId,
        "chatId": "saved_messages",
        "timestamp": timestampMs,
        "timestampMs": timestampMs,
        "type": type,
        "extra": parsedExtra,
      ]
      if let fromId { normalized["fromId"] = fromId }
      if let encryptedContent { normalized["encryptedContent"] = encryptedContent }
      if !resolvedText.isEmpty {
        normalized["plaintext"] = resolvedText
        normalized["text"] = resolvedText
      }
      if let resolvedMediaUrl { normalized["mediaUrl"] = resolvedMediaUrl }
      if let resolvedFileName { normalized["fileName"] = resolvedFileName }
      if let resolvedMediaKey { normalized["mediaKey"] = resolvedMediaKey }
      if let resolvedLatitude { normalized["latitude"] = resolvedLatitude }
      if let resolvedLongitude { normalized["longitude"] = resolvedLongitude }
      if let resolvedDuration { normalized["duration"] = resolvedDuration }
      if let resolvedEditedAt { normalized["editedAt"] = resolvedEditedAt }
      if let status = normalizedString(raw["status"])?.lowercased() {
        normalized["status"] = status
      } else if normalizedUpper(fromId) == currentUserId {
        normalized["status"] = "sent"
      }
      if let isEdited = raw["isEdited"] as? Bool {
        normalized["isEdited"] = isEdited
      }
      if let replyToId = normalizedString(decryptedFields["replyToId"]) {
        normalized["replyToId"] = replyToId
      }
      if let width = decryptedFields["width"] { normalized["width"] = width }
      if let height = decryptedFields["height"] { normalized["height"] = height }
      if let waveform = decryptedFields["waveform"] { normalized["waveform"] = waveform }
      if let isVideoNote = decryptedFields["isVideoNote"] {
        normalized["isVideoNote"] = isVideoNote
      }
      if let contact = decryptedFields["contact"] {
        normalized["contact"] = contact
      }
      if let stickerId = normalizedString(decryptedFields["stickerId"]) {
        normalized["stickerId"] = stickerId
      }
      if let stickerPackId = normalizedString(
        decryptedFields["stickerPackId"] ?? decryptedFields["packId"])
      {
        normalized["stickerPackId"] = stickerPackId
        normalized["packId"] = stickerPackId
      }
      if let stickerBundleFileName = normalizedString(
        decryptedFields["stickerBundleFileName"] ?? decryptedFields["bundleFileName"])
      {
        normalized["stickerBundleFileName"] = stickerBundleFileName
        normalized["bundleFileName"] = stickerBundleFileName
      }
      if let emoji = normalizedString(decryptedFields["emoji"]) {
        normalized["emoji"] = emoji
      }
      return normalized
    }
  }

  func fetchSavedMessages(_ payload: [String: Any], completion: @escaping ([String: Any]) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      let hasCache = self.cachedSavedMessagesResponse != nil
      if let cached = self.cachedSavedMessagesResponse {
        DispatchQueue.main.async {
          completion(["success": true, "messages": cached])
        }
      }
      guard let (apiBase, token) = self.requestContext else {
        if !hasCache {
          DispatchQueue.main.async {
            completion(["success": false, "reason": "missing_config", "messages": []])
          }
        }
        return
      }
      guard
        let userId =
          normalizedString(
            payload["userId"] ?? payload["user_id"] ?? getConfigValueLocked("userId"))
      else {
        if !hasCache {
          DispatchQueue.main.async {
            completion(["success": false, "reason": "missing_user_id", "messages": []])
          }
        }
        return
      }

      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("saved_messages")
          .appendingPathComponent(userId))
      request.httpMethod = "GET"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { [weak self] data, response, error in
        guard let self else { return }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let data, error == nil, (200...299).contains(statusCode) else {
          if !hasCache {
            DispatchQueue.main.async {
              completion([
                "success": false,
                "reason": "http_\(statusCode)",
                "messages": [],
              ])
            }
          }
          return
        }
        let rawItems = self.syncOnQueue { self.parseSavedMessagesServerItems(data) }
        let messages = self.syncOnQueue {
          let normalized = self.normalizeSavedMessagesLocked(rawItems)
          self.cachedSavedMessagesResponse = normalized
          return normalized
        }
        if !hasCache {
          DispatchQueue.main.async {
            completion(["success": true, "messages": messages])
          }
        }
      }.resume()
    }
  }

  func sendSavedMessage(_ payload: [String: Any], completion: @escaping ([String: Any]) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(["success": false, "reason": "missing_config"]) }
        return
      }
      guard let userId = normalizedString(getConfigValueLocked("userId")) else {
        DispatchQueue.main.async { completion(["success": false, "reason": "missing_user_id"]) }
        return
      }

      let type = normalizedString(payload["type"])?.lowercased() ?? "text"
      let text = normalizedString(payload["text"]) ?? ""
      let messageId =
        normalizedString(payload["messageId"] ?? payload["message_id"] ?? payload["id"])
        ?? UUID().uuidString.lowercased()
      NSLog(
        "[ChatEngine] sendSavedMessage START messageId=%@ type=%@ hasText=%@",
        messageId,
        type,
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true")
      let metadata = (payload["metadata"] as? [String: Any]) ?? [:]
      var mediaUrl =
        normalizedString(
          metadata["mediaUrl"] ?? metadata["media_url"] ?? payload["mediaUrl"]
            ?? payload["media_url"])
      var fileName =
        normalizedString(metadata["fileName"] ?? metadata["file_name"] ?? payload["fileName"])
      var fileSize = parseLongValue(
        metadata["fileSize"] ?? metadata["file_size"] ?? payload["fileSize"])
      let latitude = parseDoubleValue(metadata["latitude"] ?? payload["latitude"])
      let longitude = parseDoubleValue(metadata["longitude"] ?? payload["longitude"])
      let duration = parseDoubleValue(metadata["duration"] ?? payload["duration"])
      let width = parseLongValue(metadata["width"] ?? payload["width"])
      let height = parseLongValue(metadata["height"] ?? payload["height"])
      var mediaKey = normalizedString(metadata["mediaKey"] ?? metadata["media_key"] ?? payload["mediaKey"])
      let replyToId =
        normalizedString(metadata["replyToId"] ?? metadata["reply_to_id"] ?? payload["replyToId"])
      let contact = metadata["contact"] ?? payload["contact"]
      let isVideoNote = metadata["isVideoNote"] ?? payload["isVideoNote"]
      let stickerId = normalizedString(metadata["stickerId"] ?? payload["stickerId"])
      let stickerPackId = normalizedString(
        metadata["stickerPackId"] ?? metadata["packId"] ?? payload["stickerPackId"]
          ?? payload["packId"])
      let stickerBundleFileName = normalizedString(
        metadata["stickerBundleFileName"] ?? metadata["bundleFileName"]
          ?? payload["stickerBundleFileName"] ?? payload["bundleFileName"])
      let stickerEmoji = normalizedString(metadata["emoji"] ?? payload["emoji"])
      let myPublicKeyPem = normalizedString(
        getConfigValueLocked("publicKeyPem") ?? getConfigValueLocked("publicKey"))

      if type == "text" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        DispatchQueue.main.async { completion(["success": false, "reason": "empty_text"]) }
        return
      }

      let uploadableTypes: Set<String> = ["image", "voice", "video", "file", "sticker", "music"]
      if let currentMediaUrl = mediaUrl, uploadableTypes.contains(type),
        isLocalMediaURI(currentMediaUrl)
      {
        let uploadOutcome = uploadLocalMediaLocked(
          localUri: currentMediaUrl,
          messageType: type,
          fileNameHint: fileName,
          userId: userId,
          token: token,
          apiBase: apiBase
        )
        guard let uploadResult = uploadOutcome.result else {
          DispatchQueue.main.async {
            completion([
              "success": false,
              "reason": uploadOutcome.reason ?? "upload_failed",
              "messageId": messageId,
            ])
          }
          return
        }
        mediaUrl = uploadResult.remoteUrl
        if fileName == nil { fileName = uploadResult.fileName }
        if fileSize == nil { fileSize = uploadResult.fileSize }
        if mediaKey == nil { mediaKey = uploadResult.mediaKey }
      }

      var encryptedContent = ""
      if let myPublicKeyPem, !myPublicKeyPem.isEmpty {
        var encryptedPayload: [String: Any] = ["text": text]
        if let mediaUrl { encryptedPayload["mediaUrl"] = mediaUrl }
        if let mediaKey { encryptedPayload["mediaKey"] = mediaKey }
        if let fileName { encryptedPayload["fileName"] = fileName }
        if let fileSize { encryptedPayload["fileSize"] = fileSize }
        if let latitude { encryptedPayload["latitude"] = latitude }
        if let longitude { encryptedPayload["longitude"] = longitude }
        if let width { encryptedPayload["width"] = width }
        if let height { encryptedPayload["height"] = height }
        if let duration { encryptedPayload["duration"] = duration }
        if let replyToId { encryptedPayload["replyToId"] = replyToId }
        if let contact { encryptedPayload["contact"] = contact }
        if let isVideoNote { encryptedPayload["isVideoNote"] = isVideoNote }
        if let stickerId { encryptedPayload["stickerId"] = stickerId }
        if let stickerPackId { encryptedPayload["stickerPackId"] = stickerPackId }
        if let stickerBundleFileName {
          encryptedPayload["stickerBundleFileName"] = stickerBundleFileName
        }
        if let stickerEmoji { encryptedPayload["emoji"] = stickerEmoji }
        if let payloadString = try? JSONSerialization.data(
          withJSONObject: makeJSONSafeMap(encryptedPayload), options: []),
          let messageString = String(data: payloadString, encoding: .utf8),
          let sealed = try? chatEngineEncryptHybridMessage(
            recipientPublicKeyPem: myPublicKeyPem,
            message: messageString,
            myPublicKeyPem: myPublicKeyPem
          )
        {
          encryptedContent = sealed
        }
      }

      var extraPayload: [String: Any] = [:]
      if let fileName { extraPayload["fileName"] = fileName }
      if let fileSize { extraPayload["fileSize"] = fileSize }
      if let latitude { extraPayload["latitude"] = latitude }
      if let longitude { extraPayload["longitude"] = longitude }
      if let width { extraPayload["width"] = width }
      if let height { extraPayload["height"] = height }
      if let duration { extraPayload["duration"] = duration }
      if let replyToId { extraPayload["replyToId"] = replyToId }
      if let isVideoNote { extraPayload["isVideoNote"] = isVideoNote }
      if let stickerId { extraPayload["stickerId"] = stickerId }
      if let stickerPackId {
        extraPayload["stickerPackId"] = stickerPackId
        extraPayload["packId"] = stickerPackId
      }
      if let stickerBundleFileName {
        extraPayload["stickerBundleFileName"] = stickerBundleFileName
        extraPayload["bundleFileName"] = stickerBundleFileName
      }
      if let stickerEmoji { extraPayload["emoji"] = stickerEmoji }

      let requestBody = makeJSONSafeMap([
        "user_id": userId,
        "original_message_id": messageId,
        "chat_id": "saved_messages",
        "from_id": userId,
        "encrypted_content": encryptedContent,
        "content": "",
        "type": type,
        "media_url": NSNull(),
        "timestamp": Int64(nowMs()),
        "extra": String(
          data: (try? JSONSerialization.data(withJSONObject: extraPayload, options: []))
            ?? Data("{}".utf8),
          encoding: .utf8
        ) ?? "{}",
      ])

      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("saved_messages"))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
      request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody, options: [])

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, error in
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let success = error == nil && (200...299).contains(statusCode)
        let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let errorText = error?.localizedDescription ?? ""
        NSLog(
          "[ChatEngine] sendSavedMessage %@ messageId=%@ status=%d error=%@ body=%@",
          success ? "OK" : "FAIL",
          messageId,
          statusCode,
          errorText.isEmpty ? "-" : errorText,
          responseBody.isEmpty ? "-" : responseBody
        )
        DispatchQueue.main.async {
          completion([
            "success": success,
            "status": statusCode,
            "messageId": messageId,
            "reason": success ? "ok" : "request_failed",
            "error": errorText,
            "body": responseBody,
          ])
        }
      }.resume()
    }
  }

  func deleteSavedMessage(_ payload: [String: Any], completion: @escaping ([String: Any]) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(["success": false, "reason": "missing_config"]) }
        return
      }
      guard
        let userId =
          normalizedString(
            payload["userId"] ?? payload["user_id"] ?? getConfigValueLocked("userId"))
      else {
        DispatchQueue.main.async { completion(["success": false, "reason": "missing_user_id"]) }
        return
      }
      guard
        let messageId =
          normalizedString(payload["messageId"] ?? payload["message_id"] ?? payload["id"])
      else {
        DispatchQueue.main.async { completion(["success": false, "reason": "missing_message_id"]) }
        return
      }

      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("saved_messages")
          .appendingPathComponent(userId).appendingPathComponent(messageId))
      request.httpMethod = "DELETE"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { _, response, error in
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        DispatchQueue.main.async {
          completion([
            "success": error == nil && (200...299).contains(statusCode),
            "status": statusCode,
            "messageId": messageId,
          ])
        }
      }.resume()
    }
  }

  // MARK: - Agent Config (Native HTTP)

  func fetchAgentConfig(chatId: String, completion: @escaping ([String: Any]?) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("group")
          .appendingPathComponent(chatId).appendingPathComponent("agent"))
      request.httpMethod = "GET"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, error in
        guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        DispatchQueue.main.async { completion(json) }
      }.resume()
    }
  }

  func saveAgentConfig(chatId: String, config: [String: Any], completion: @escaping (Bool) -> Void)
  {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      let endpoint = apiBase.appendingPathComponent("api").appendingPathComponent("group")
        .appendingPathComponent(chatId).appendingPathComponent("agent")
      let safeConfig = self.makeJSONSafeMap(config)
      let payload = (try? JSONSerialization.data(withJSONObject: safeConfig)) ?? Data()

      let hasPersistedId: Bool = {
        if let id = config["id"] as? String {
          return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return config["id"] != nil
      }()
      let initialMethod = hasPersistedId ? "PUT" : "POST"

      func makeRequest(method: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if !token.isEmpty {
          request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payload
        return request
      }

      func send(method: String, completion: @escaping (Int) -> Void) {
        let request = makeRequest(method: method)
        let session = ChatPhoenixClient.makePinnedURLSession()
        session.dataTask(with: request) { _, response, _ in
          completion((response as? HTTPURLResponse)?.statusCode ?? -1)
        }.resume()
      }

      send(method: initialMethod) { statusCode in
        if initialMethod == "POST" && statusCode == 409 {
          send(method: "PUT") { retryStatus in
            let success = (200...299).contains(retryStatus)
            DispatchQueue.main.async { completion(success) }
          }
          return
        }
        let success = (200...299).contains(statusCode)
        DispatchQueue.main.async { completion(success) }
      }
    }
  }

  func generateAgentPrompt(
    chatId: String,
    input: String,
    enabledTools: [String],
    completion: @escaping ([String: Any]?) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(nil) }
        return
      }

      let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedInput.isEmpty else {
        DispatchQueue.main.async { completion(nil) }
        return
      }

      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("group")
          .appendingPathComponent(chatId).appendingPathComponent("agent")
          .appendingPathComponent("generate_prompt"))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let safeTools =
        enabledTools
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let body: [String: Any] = [
        "input": trimmedInput,
        "enabled_tools": safeTools,
      ]
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, _ in
        guard
          let data = data,
          (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        DispatchQueue.main.async { completion(json) }
      }.resume()
    }
  }

  func deleteAgentConfig(chatId: String, completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("group")
          .appendingPathComponent(chatId).appendingPathComponent("agent"))
      request.httpMethod = "DELETE"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, error in
        let success = (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        DispatchQueue.main.async { completion(success) }
      }.resume()
    }
  }
}
