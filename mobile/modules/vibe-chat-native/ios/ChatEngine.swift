import CryptoKit
import Foundation
import Security

private struct ChatEngineHybridPayload: Decodable {
  let iv: String
  let c: String
  let k: String
  let s: String?
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
  guard let versionLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
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
  let normalized = pem
    .replacingOccurrences(of: "\\r\\n", with: "\n")
    .replacingOccurrences(of: "\\n", with: "\n")
    .replacingOccurrences(of: "\\r", with: "\n")
  let sanitized = normalized
    .replacingOccurrences(of: "-----BEGIN [^-]+-----", with: "", options: .regularExpression)
    .replacingOccurrences(of: "-----END [^-]+-----", with: "", options: .regularExpression)
    .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
  return Data(base64Encoded: sanitized)
}

private func chatEnginePrivateKey(from pem: String) -> SecKey? {
  guard let keyData = chatEngineDecodePEM(pem) else { return nil }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
  ]
  var error: Unmanaged<CFError>?
  if let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error) {
    return key
  }
  if let pkcs1Data = chatEngineExtractPKCS1FromPKCS8(keyData) {
    error = nil
    return SecKeyCreateWithData(pkcs1Data as CFData, attrs as CFDictionary, &error)
  }
  return nil
}

private func chatEngineRSADecryptOAEP(privateKey: SecKey, encrypted: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let decrypted = SecKeyCreateDecryptedData(
    privateKey,
    .rsaEncryptionOAEPSHA256,
    encrypted as CFData,
    &error
  ) as Data?
  _ = error?.takeRetainedValue()
  return decrypted
}

private func chatEngineDecryptHybridMessage(
  privateKey: SecKey,
  ciphertext: String,
  isMyMessage: Bool
) -> String {
  let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return "" }
  guard let payload = try? JSONDecoder().decode(ChatEngineHybridPayload.self, from: data) else { return "" }
  guard
    let iv = Data(base64Encoded: payload.iv),
    let cipherAndTag = Data(base64Encoded: payload.c),
    let recipientKeyBlob = Data(base64Encoded: payload.k),
    cipherAndTag.count >= 16
  else { return "" }

  var keyCandidates = [Data]()
  if isMyMessage {
    if let s = payload.s, let senderBlob = Data(base64Encoded: s) { keyCandidates.append(senderBlob) }
    keyCandidates.append(recipientKeyBlob)
  } else {
    keyCandidates.append(recipientKeyBlob)
    if let s = payload.s, let senderBlob = Data(base64Encoded: s) { keyCandidates.append(senderBlob) }
  }

  var aesKeyData: Data?
  for blob in keyCandidates {
    if let decrypted = chatEngineRSADecryptOAEP(privateKey: privateKey, encrypted: blob) {
      aesKeyData = decrypted
      break
    }
  }
  guard let aesKeyData else { return "" }

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
    return ""
  }
}

final class ChatEngine {
  static let shared = ChatEngine()
  static let didChangeNotification = Notification.Name("Vibe.ChatEngine.didChange")

  private struct SurfaceBinding {
    let surfaceId: String
    let chatId: String?
    let myUserId: String?
    let peerUserId: String?
  }

  private let queue = DispatchQueue(label: "vibe.chat.engine")
  private let store = ChatEngineStore.shared

  private var state: [String: Any] = [
    "state": "idle",
    "connected": false,
    "updatedAt": 0,
    "note": "ChatEngine scaffold (shadow mode)",
  ]
  private var onlineUsers = Set<String>()
  private var surfaceBindings: [String: SurfaceBinding] = [:]
  private var openChatChannels: [String: Int] = [:]
  // chatId -> messageId -> "delivered" | "read"
  private var receiptIndex: [String: [String: String]] = [:]
  private var localStatusIndex: [String: [String: String]] = [:]
  private var phoenixClient: AnyObject?
  private var nativePresenceActive = false
  private var nativeUserTopic: String?
  private var nativeUserJoinRef: String?
  private var nativeSocketSignature: String?
  private var nativeChatJoinRefsByRef: [String: String] = [:]
  private var nativeJoinedChatIds = Set<String>()
  private var nativePendingMessagePushRefs: [String: (chatId: String, messageId: String)] = [:]
  private var nativePendingEditPushRefs: [String: (chatId: String, messageId: String)] = [:]
  private var nativePendingDeletePushRefs: [String: (chatId: String, messageId: String)] = [:]
  private var historyRowsByChat: [String: [[String: Any]]] = [:]
  private var historyLoadingChats = Set<String>()
  private var liveMessageRowsByChat: [String: [String: [String: Any]]] = [:]
  private var deletedMessageIdsByChat: [String: Set<String>] = [:]
  private var cachedDecryptPrivateKeyPem: String?
  private var cachedDecryptPrivateKey: SecKey?
  private var cachedDecryptKeyTimestamp: Date?
  /// Time-to-live for the cached private key in memory (seconds).
  /// After this period of inactivity the key is cleared and re-derived from Keychain on next use.
  private let keyTTL: TimeInterval = 300

  private init() {
    // Clear cached private key when the app moves to the background
    // to reduce the window of exposure to memory dump attacks.
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.clearCachedKeyOnBackground()
    }
  }

  private func clearCachedKeyOnBackground() {
    queue.async {
      self.cachedDecryptPrivateKey = nil
      self.cachedDecryptPrivateKeyPem = nil
      self.cachedDecryptKeyTimestamp = nil
    }
  }

  func configure(_ payload: [String: Any]) -> [String: Any] {
    store.setConfig(payload)
    let now = nowMs()
    return queue.sync {
      state["state"] = "configured"
      state["updatedAt"] = now
      state["configuredAt"] = now
      state["configKeys"] = Array(payload.keys).sorted()
      state["note"] = "ChatEngine configured (native Phoenix presence enabled, shadow fallback active)"
      state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
      let snapshot = statusSnapshotLocked()
      appendJournalLocked(event: "configure", payload: ["keys": Array(payload.keys).sorted()])
      postChangeLocked(reason: "configure", userInfo: ["state": snapshot])
      return snapshot
    }
  }

  func getStatus() -> [String: Any] {
    queue.sync { statusSnapshotLocked() }
  }

  func connect() -> [String: Any] {
    if #available(iOS 13.0, *) {
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
    let clientToClose: AnyObject? = queue.sync {
      let now = nowMs()
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
      liveMessageRowsByChat.removeAll()
      deletedMessageIdsByChat.removeAll()
      historyRowsByChat.removeAll()
      historyLoadingChats.removeAll()
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
    if #available(iOS 13.0, *), let client = clientToClose as? ChatPhoenixClient {
      client.disconnect()
    }
    return getStatus()
  }

  func bindSurface(_ payload: [String: Any]) -> [String: Any] {
    let surfaceId = normalizedString(payload["surfaceId"]) ?? normalizedString(payload["engineSurfaceId"]) ?? ""
    let chatId = normalizedString(payload["chatId"])
    let myUserId = normalizedUpper(payload["myUserId"])
    let peerUserId = normalizedUpper(payload["peerUserId"])
    guard !surfaceId.isEmpty else { return getStatus() }

    return queue.sync {
      surfaceBindings[surfaceId] = SurfaceBinding(
        surfaceId: surfaceId,
        chatId: chatId,
        myUserId: myUserId,
        peerUserId: peerUserId
      )
      state["updatedAt"] = nowMs()
      appendJournalLocked(
        event: "bind-surface",
        payload: [
          "surfaceId": surfaceId,
          "chatId": chatId as Any,
          "peerUserId": peerUserId as Any,
        ])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "surfaceBindingChanged", userInfo: ["surfaceId": surfaceId])
      return snapshot
    }
  }

  func unbindSurface(_ payload: [String: Any]) -> [String: Any] {
    let surfaceId = normalizedString(payload["surfaceId"]) ?? normalizedString(payload["engineSurfaceId"]) ?? ""
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
    return queue.sync {
      if let chatId, !chatId.isEmpty {
        let nextCount = (openChatChannels[chatId] ?? 0) + 1
        openChatChannels[chatId] = nextCount
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
      }
      appendJournalLocked(event: "open-chat-channel", payload: payload)
      state["updatedAt"] = nowMs()
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "chatChannelStateChanged", userInfo: ["chatId": chatId as Any])
      return snapshot
    }
  }

  func closeChatChannel(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    return queue.sync {
      if let chatId, !chatId.isEmpty, let current = openChatChannels[chatId] {
        if current <= 1 {
          openChatChannels.removeValue(forKey: chatId)
          nativeJoinedChatIds.remove(chatId)
          if let client = phoenixClient as? ChatPhoenixClient {
            client.leave(topic: chatTopic(for: chatId))
          }
        } else {
          openChatChannels[chatId] = current - 1
        }
      }
      appendJournalLocked(event: "close-chat-channel", payload: payload)
      state["updatedAt"] = nowMs()
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "chatChannelStateChanged", userInfo: ["chatId": chatId as Any])
      return snapshot
    }
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

  func sendEncryptedMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId = normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let messagePayload = payload["message"] as? [String: Any]
    guard let chatId, let messageId, let messagePayload else {
      return [
        "accepted": false,
        "reason": "invalid_payload",
      ]
    }

    return queue.sync {
      guard let client = phoenixClient as? ChatPhoenixClient else {
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
      let ref = client.push(topic: chatTopic(for: chatId), event: "message", payload: messagePayload)
      nativePendingMessagePushRefs[ref] = (chatId: chatId, messageId: messageId)
      appendJournalLocked(event: "native-send-message", payload: [
        "chatId": chatId,
        "messageId": messageId,
        "ref": ref,
      ])
      postChangeLocked(reason: "messageStatusChanged", userInfo: ["chatId": chatId, "messageId": messageId])
      return [
        "accepted": true,
        "transport": "native",
        "ref": ref,
      ]
    }
  }

  func sendEditMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId = normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let encryptedContent = normalizedString(payload["encryptedContent"]) ?? normalizedString(payload["encrypted_content"])
    let editedAt = payload["editedAt"] ?? payload["edited_at"]
    guard let chatId, let messageId, let encryptedContent else {
      return ["accepted": false, "reason": "invalid_payload"]
    }

    return queue.sync {
      guard let client = phoenixClient as? ChatPhoenixClient else {
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
      let ref = client.push(topic: chatTopic(for: chatId), event: "edit-message", payload: wirePayload)
      nativePendingEditPushRefs[ref] = (chatId: chatId, messageId: messageId)
      appendJournalLocked(event: "native-send-edit-message", payload: [
        "chatId": chatId,
        "messageId": messageId,
        "ref": ref,
      ])
      return ["accepted": true, "transport": "native", "ref": ref]
    }
  }

  func sendDeleteMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId = normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else {
      return ["accepted": false, "reason": "invalid_payload"]
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
      guard let client = phoenixClient as? ChatPhoenixClient else {
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      let ref = client.push(topic: chatTopic(for: chatId), event: "delete-message", payload: [
        "messageId": messageId,
        "forEveryone": forEveryone,
      ])
      nativePendingDeletePushRefs[ref] = (chatId: chatId, messageId: messageId)
      appendJournalLocked(event: "native-send-delete-message", payload: [
        "chatId": chatId,
        "messageId": messageId,
        "forEveryone": forEveryone,
        "ref": ref,
      ])
      return ["accepted": true, "transport": "native", "ref": ref]
    }
  }

  func upsertLocalMessageStatus(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId = normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
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
    return queue.sync {
      liveMessageRowsByChat[chatId]?[messageId]
    }
  }

  func getChatRows(_ payload: [String: Any]) -> [[String: Any]] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return [] }
    return queue.sync {
      historyRowsByChat[chatId] ?? []
    }
  }

  func isLiveMessageDeleted(_ payload: [String: Any]) -> Bool {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    guard let chatId, let messageId else { return false }
    return queue.sync {
      deletedMessageIdsByChat[chatId]?.contains(messageId) == true
    }
  }

  // Shadow-mode bridge from JS until native Phoenix transport is implemented.
  func setPresenceSnapshot(userIds: [String]) -> [String: Any] {
    let normalized = Set(userIds.compactMap { normalizedUpper($0) })
    return queue.sync {
      if nativePresenceActive {
        state["updatedAt"] = nowMs()
        appendJournalLocked(event: "set-presence-snapshot-ignored", payload: ["count": normalized.count])
        return statusSnapshotLocked()
      }
      onlineUsers = normalized
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

    return queue.sync {
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
    let messageId = normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else { return getStatus() }
    return queue.sync {
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
    let messageId = normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else { return getStatus() }
    return queue.sync {
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: status)

      var accepted = false
      var ref: String?
      if let client = phoenixClient as? ChatPhoenixClient,
         nativeJoinedChatIds.contains(chatId),
         (state["connected"] as? Bool) == true
      {
        ref = client.push(topic: chatTopic(for: chatId), event: wireEvent, payload: ["messageId": messageId])
        accepted = true
        appendJournalLocked(event: "native-\(eventName)-push", payload: [
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

  private func statusSnapshotLocked() -> [String: Any] {
    var snapshot = state
    snapshot["onlineUserCount"] = onlineUsers.count
    snapshot["boundSurfaceCount"] = surfaceBindings.count
    snapshot["boundChatCount"] = Set(surfaceBindings.values.compactMap(\.chatId)).count
    snapshot["openChatChannelCount"] = openChatChannels.count
    snapshot["openChatChannels"] = openChatChannels
    snapshot["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    snapshot["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    snapshot["nativeJoinedChatCount"] = nativeJoinedChatIds.count
    snapshot["journalCount"] = store.getJournal(limit: nil).count
    return snapshot
  }

  @available(iOS 13.0, *)
  private func connectNativePresence() -> [String: Any] {
    let config = store.getConfig()
    let socketUrlString = normalizedString(config["socketUrl"]) ?? normalizedString(config["url"])
    let authToken = normalizedString(config["authToken"]) ?? normalizedString(config["token"])
    let userId = normalizedString(config["userId"])
    let userTopic = normalizedString(config["userChannelTopic"])
      ?? (userId != nil ? "user:\(userId!)" : nil)

    guard let socketUrlString, let socketURL = URL(string: socketUrlString), let userTopic else {
      return queue.sync {
        state["state"] = "native-config-missing"
        state["connected"] = false
        state["updatedAt"] = nowMs()
        state["note"] = "ChatEngine native presence missing socketUrl/userTopic config"
        appendJournalLocked(event: "connect-native-missing-config", payload: [
          "hasSocketUrl": socketUrlString != nil,
          "hasUserTopic": userTopic != nil,
          "hasAuthToken": authToken != nil,
        ])
        let snapshot = statusSnapshotLocked()
        postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return snapshot
      }
    }

    let signature = "\(socketUrlString)|\(authToken ?? "")|\(userTopic)"
    let callbacks = ChatPhoenixClient.Callbacks(
      onOpen: { [weak self] in self?.handleNativeSocketOpened(userTopic: userTopic) },
      onClose: { [weak self] code, reason in self?.handleNativeSocketClosed(code: code, reason: reason) },
      onError: { [weak self] error in self?.handleNativeSocketError(error) },
      onEvent: { [weak self] frame in self?.handleNativeSocketFrame(frame) }
    )

    let clientToReplace: ChatPhoenixClient? = queue.sync {
      var clientToReplace: ChatPhoenixClient?
      if let existing = phoenixClient as? ChatPhoenixClient, nativeSocketSignature != signature {
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
      historyLoadingChats.removeAll()
      liveMessageRowsByChat.removeAll()
      deletedMessageIdsByChat.removeAll()
      }
      if phoenixClient == nil {
        // Pass auth token separately so it goes in the Authorization header,
        // not as a URL query parameter (prevents token leakage in logs/proxies).
        let client = ChatPhoenixClient(
          baseURL: socketURL,
          params: [:],
          authToken: authToken,
          callbacks: callbacks
        )
        phoenixClient = client
        nativeSocketSignature = signature
      }
      nativeUserTopic = userTopic
      state["connected"] = false
      state["state"] = "connecting-native-presence"
      state["updatedAt"] = nowMs()
      state["note"] = "ChatEngine native Phoenix presence connecting"
      state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
      appendJournalLocked(event: "connect-native", payload: ["topic": userTopic])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return clientToReplace
    }

    clientToReplace?.disconnect()
    (queue.sync { phoenixClient as? ChatPhoenixClient })?.connect()
    return getStatus()
  }

  private func handleNativeSocketOpened(userTopic: String) {
    queue.async {
      guard let client = self.phoenixClient as? ChatPhoenixClient else { return }
      self.state["connected"] = true
      self.state["state"] = "native-socket-open"
      self.state["updatedAt"] = self.nowMs()
      self.state["note"] = "ChatEngine native Phoenix socket open"
      self.appendJournalLocked(event: "native-socket-open", payload: [:])
      self.nativeUserTopic = userTopic
      self.nativeUserJoinRef = client.join(topic: userTopic, payload: [:])
      self.nativeChatJoinRefsByRef.removeAll()
      self.nativeJoinedChatIds.removeAll()
      self.nativePendingMessagePushRefs.removeAll()
      self.nativePendingEditPushRefs.removeAll()
      self.nativePendingDeletePushRefs.removeAll()
      self.historyLoadingChats.removeAll()
      self.liveMessageRowsByChat.removeAll()
      self.deletedMessageIdsByChat.removeAll()
      for chatId in self.openChatChannels.keys {
        self.joinNativeChatTopicIfNeededLocked(chatId: chatId)
      }
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
    }
  }

  private func handleNativeSocketClosed(code: Int, reason: String?) {
    queue.async {
      self.nativePresenceActive = false
      self.nativeUserJoinRef = nil
      self.nativeChatJoinRefsByRef.removeAll()
      self.nativeJoinedChatIds.removeAll()
      self.nativePendingMessagePushRefs.removeAll()
      self.nativePendingEditPushRefs.removeAll()
      self.nativePendingDeletePushRefs.removeAll()
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
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
    }
  }

  private func handleNativeSocketError(_ error: String) {
    queue.async {
      self.state["updatedAt"] = self.nowMs()
      self.state["lastNativeSocketError"] = error
      self.appendJournalLocked(event: "native-socket-error", payload: ["error": error])
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "engineError", userInfo: ["state": snapshot, "error": error])
    }
  }

  @available(iOS 13.0, *)
  private func handleNativeSocketFrame(_ frame: ChatPhoenixClient.EventFrame) {
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
          } else {
            self.appendJournalLocked(
              event: "native-chat-join-error",
              payload: ["chatId": chatId, "status": status, "payload": self.makeJSONSafeMap(frame.payload)]
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
          self.upsertLocalStatusLocked(chatId: pending.chatId, messageId: pending.messageId, status: nextStatus)
          self.appendJournalLocked(event: "native-message-push-reply", payload: [
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
          self.appendJournalLocked(event: "native-edit-message-push-reply", payload: [
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
          self.appendJournalLocked(event: "native-delete-message-push-reply", payload: [
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
        if frame.event == "message",
           let insertedMessageId = self.applyNativeIncomingMessageEventLocked(chatId: chatId, payload: frame.payload)
        {
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
        if let mutationUpdate = self.applyNativeChatMutationEventLocked(chatId: chatId, event: frame.event, payload: frame.payload) {
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
        if let receiptUpdate = self.applyNativeChatEventLocked(chatId: chatId, event: frame.event, payload: frame.payload) {
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
      appendJournalLocked(event: "native-presence-initial", payload: ["count": ids.count])
      return true
    case "friend-online":
      if let userId = normalizedUpper(payload["userId"] ?? payload["user_id"] ?? payload["id"]) {
        onlineUsers.insert(userId)
        appendJournalLocked(event: "native-presence-online", payload: ["userId": userId])
        return true
      }
      return false
    case "friend-offline":
      if let userId = normalizedUpper(payload["userId"] ?? payload["user_id"] ?? payload["id"]) {
        onlineUsers.remove(userId)
        appendJournalLocked(event: "native-presence-offline", payload: ["userId": userId])
        return true
      }
      return false
    case "presence_state":
      if let map = payload as? [String: Any] {
        let ids = map.keys.compactMap { normalizedUpper($0) }
        onlineUsers = Set(ids)
        appendJournalLocked(event: "native-presence-state", payload: ["count": ids.count])
        return true
      }
      return false
    case "presence_diff", "presence-diff":
      let joins = payload["joins"] as? [String: Any] ?? [:]
      let leaves = payload["leaves"] as? [String: Any] ?? [:]
      for id in joins.keys {
        if let normalized = normalizedUpper(id) { onlineUsers.insert(normalized) }
      }
      for id in leaves.keys {
        if let normalized = normalizedUpper(id) { onlineUsers.remove(normalized) }
      }
      appendJournalLocked(event: "native-presence-diff", payload: [
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

  private func currentUserIdLocked() -> String? {
    normalizedUpper(getConfigValueLocked("userId"))
  }

  private func decryptPrivateKeyLocked() -> SecKey? {
    guard
      let pem = normalizedString(getConfigValueLocked("privateKeyPem") ?? getConfigValueLocked("privateKey"))
    else {
      return nil
    }
    // Check TTL: clear cached key if it has expired to limit in-memory exposure.
    if let ts = cachedDecryptKeyTimestamp, Date().timeIntervalSince(ts) >= keyTTL {
      cachedDecryptPrivateKey = nil
      cachedDecryptPrivateKeyPem = nil
      cachedDecryptKeyTimestamp = nil
    }
    if let cached = cachedDecryptPrivateKey, cachedDecryptPrivateKeyPem == pem {
      cachedDecryptKeyTimestamp = Date()
      return cached
    }
    let key = chatEnginePrivateKey(from: pem)
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
    if let duration = json["duration"] { out["duration"] = duration }
    if let isEdited = json["isEdited"] { out["isEdited"] = isEdited }
    if let editedAt = json["editedAt"] { out["editedAt"] = editedAt }
    if let waveform = json["waveform"] { out["waveform"] = waveform }
    if let isVideoNote = json["isVideoNote"] { out["isVideoNote"] = isVideoNote }
    if let width = json["width"] { out["width"] = width }
    if let height = json["height"] { out["height"] = height }
    if let thumbnailBase64 = json["thumbnailBase64"] { out["thumbnailBase64"] = thumbnailBase64 }
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
    let isMe = normalizedUpper(normalizedFrom) != nil && normalizedUpper(normalizedFrom) == currentUserIdLocked()
    let text = normalizedString(decryptedFields["text"]) ?? ""
    let mediaUrl = normalizedString(decryptedFields["mediaUrl"])
    let duration = parseDoubleValue(decryptedFields["duration"])
    let waveform = parseWaveformArray(decryptedFields["waveform"])
    let isEdited = forceEdited || ((decryptedFields["isEdited"] as? Bool) == true)
    let editedAt = forceEditedAt ?? decryptedFields["editedAt"]

    var metadata: [String: Any] = [:]
    if let waveform { metadata["waveform"] = waveform }
    if let width = decryptedFields["width"] { metadata["width"] = width }
    if let height = decryptedFields["height"] { metadata["height"] = height }
    if let thumbnailBase64 = decryptedFields["thumbnailBase64"] { metadata["thumbnailBase64"] = thumbnailBase64 }
    if let isVideoNote = decryptedFields["isVideoNote"] { metadata["isVideoNote"] = isVideoNote }

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
    if let duration { message["duration"] = duration }
    if !metadata.isEmpty { message["metadata"] = metadata }

    return [
      "kind": "message",
      "key": "m-\(messageId)",
      "message": message,
    ]
  }

  private func applyNativeIncomingMessageEventLocked(chatId: String, payload: [String: Any]) -> String? {
    guard let messageId = normalizedString(payload["id"] ?? payload["message_id"]) else { return nil }
    let fromId = normalizedString(payload["fromId"] ?? payload["from_id"])
    let encryptedContent = normalizedString(payload["encryptedContent"] ?? payload["encrypted_content"])
    let type = normalizedString(payload["type"]) ?? "text"
    let timestampMs = parseLongValue(payload["timestamp"]) ?? Int64(nowMs())
    let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()

    let hadEncryptedContent = encryptedContent != nil && !encryptedContent!.isEmpty
    let decryptedText: String = {
      guard let encryptedContent, !encryptedContent.isEmpty, let privateKey = decryptPrivateKeyLocked() else {
        return ""
      }
      return chatEngineDecryptHybridMessage(privateKey: privateKey, ciphertext: encryptedContent, isMyMessage: isMe)
    }()
    let decryptionFailed = hadEncryptedContent && decryptedText.isEmpty

    let decryptedFields = parseDecryptedMessagePayload(decryptedText)
    var row = buildLiveRowPayloadLocked(
      chatId: chatId,
      messageId: messageId,
      fromId: fromId,
      type: type,
      timestampMs: timestampMs,
      encryptedContent: encryptedContent,
      decryptedFields: decryptedFields
    )
    // Signal decryption failure to the UI layer so it can show an appropriate indicator
    // instead of a blank bubble.
    if decryptionFailed, var message = row["message"] as? [String: Any] {
      message["decryptionFailed"] = true
      row["message"] = message
    }
    upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: row)
    appendJournalLocked(event: "native-message-row-upsert", payload: [
      "chatId": chatId,
      "messageId": messageId,
      "type": type,
    ])
    state["updatedAt"] = nowMs()
    return messageId
  }

  private func applyNativeChatMutationEventLocked(
    chatId: String,
    event: String,
    payload: [String: Any]
  ) -> (messageId: String, action: String)? {
    guard !chatId.isEmpty else { return nil }
    guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else { return nil }
    switch event {
    case "message-edited":
      let editedAtValue = payload["editedAt"] ?? payload["edited_at"]
      let encryptedContent = normalizedString(payload["encryptedContent"] ?? payload["encrypted_content"])
      let existingRow = liveMessageRowsByChat[chatId]?[messageId]
      let existingMessage = existingRow?["message"] as? [String: Any]
      let fromId = normalizedString(existingMessage?["fromId"])
      let type = normalizedString(existingMessage?["type"]) ?? "text"
      let timestampMs = parseLongValue(existingMessage?["timestampMs"] ?? existingMessage?["timestamp"])
        ?? Int64(nowMs())
      let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
      let decryptedFields: [String: Any] = {
        guard let encryptedContent, !encryptedContent.isEmpty, let privateKey = decryptPrivateKeyLocked() else {
          return [:]
        }
        let decrypted = chatEngineDecryptHybridMessage(
          privateKey: privateKey,
          ciphertext: encryptedContent,
          isMyMessage: isMe
        )
        return parseDecryptedMessagePayload(decrypted)
      }()
      let row = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: fromId,
        type: type,
        timestampMs: timestampMs,
        encryptedContent: encryptedContent ?? normalizedString(existingMessage?["encryptedContent"]),
        decryptedFields: decryptedFields,
        forceEdited: true,
        forceEditedAt: editedAtValue
      )
      upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: row)
      appendJournalLocked(event: "native-message-edited", payload: [
        "chatId": chatId,
        "messageId": messageId,
        "editedAt": editedAtValue as Any,
      ])
      state["updatedAt"] = nowMs()
      return (messageId, "edited")
    case "message-deleted":
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      appendJournalLocked(event: "native-message-deleted", payload: [
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
      guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else { return nil }
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: "delivered")
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "delivered")
      appendJournalLocked(event: "native-message-delivered", payload: [
        "chatId": chatId,
        "messageId": messageId,
      ])
      return (messageId, "delivered")
    case "message-read":
      guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else { return nil }
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: "read")
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "read")
      appendJournalLocked(event: "native-message-read", payload: [
        "chatId": chatId,
        "messageId": messageId,
      ])
      return (messageId, "read")
    default:
      return nil
    }
  }

  private func joinNativeChatTopicIfNeededLocked(chatId: String) {
    guard !chatId.isEmpty else { return }
    guard let client = phoenixClient as? ChatPhoenixClient else { return }
    guard state["connected"] as? Bool == true else { return }
    loadChatHistoryIfNeededLocked(chatId: chatId)
    if nativeJoinedChatIds.contains(chatId) { return }
    if nativeChatJoinRefsByRef.values.contains(chatId) { return }
    let ref = client.join(topic: chatTopic(for: chatId), payload: [:])
    nativeChatJoinRefsByRef[ref] = chatId
    appendJournalLocked(event: "native-chat-join-start", payload: ["chatId": chatId, "ref": ref])
  }

  private func chatTopic(for chatId: String) -> String {
    "chat:\(chatId)"
  }

  private func apiBaseURLLocked() -> URL? {
    if let configured = normalizedString(getConfigValueLocked("apiBaseUrl") ?? getConfigValueLocked("baseUrl")),
       let url = URL(string: configured)
    {
      return url
    }
    guard
      let socketUrl = normalizedString(getConfigValueLocked("socketUrl") ?? getConfigValueLocked("url")),
      var components = URLComponents(string: socketUrl)
    else { return nil }
    if components.scheme == "wss" { components.scheme = "https" }
    if components.scheme == "ws" { components.scheme = "http" }
    if components.path.hasSuffix("/socket") {
      components.path = String(components.path.dropLast("/socket".count))
    }
    return components.url
  }

  private func authHeaderTokenLocked() -> String? {
    normalizedString(getConfigValueLocked("authToken") ?? getConfigValueLocked("token"))
  }

  private func loadChatHistoryIfNeededLocked(chatId: String, force: Bool = false) {
    guard !chatId.isEmpty else { return }
    if historyLoadingChats.contains(chatId) { return }
    if !force, historyRowsByChat[chatId] != nil { return }
    guard
      let apiBase = apiBaseURLLocked(),
      let userId = normalizedString(getConfigValueLocked("userId"))
    else {
      appendJournalLocked(event: "native-chat-history-skip", payload: [
        "chatId": chatId,
        "reason": "missing_config",
      ])
      return
    }

    historyLoadingChats.insert(chatId)
    let token = authHeaderTokenLocked()
    var request = URLRequest(url: apiBase.appendingPathComponent("chats").appendingPathComponent(userId))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    appendJournalLocked(event: "native-chat-history-load-start", payload: ["chatId": chatId])

    // Use a pinned URLSession with the same cert pinning + TLS enforcement
    // as the WebSocket connection, instead of URLSession.shared.
    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.historyLoadingChats.remove(chatId)
        if let error {
          self.appendJournalLocked(event: "native-chat-history-load-error", payload: [
            "chatId": chatId,
            "error": error.localizedDescription,
          ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(reason: "engineError", userInfo: ["state": snapshot, "error": error.localizedDescription])
          return
        }
        guard let http = response as? HTTPURLResponse else {
          self.appendJournalLocked(event: "native-chat-history-load-error", payload: [
            "chatId": chatId,
            "error": "invalid_response",
          ])
          return
        }
        guard (200...299).contains(http.statusCode), let data else {
          self.appendJournalLocked(event: "native-chat-history-load-error", payload: [
            "chatId": chatId,
            "status": http.statusCode,
          ])
          return
        }
        self.applyChatHistoryResponseLocked(chatId: chatId, data: data)
      }
    }.resume()
  }

  private func applyChatHistoryResponseLocked(chatId: String, data: Data) {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let chats = object as? [[String: Any]]
    else {
      appendJournalLocked(event: "native-chat-history-load-error", payload: [
        "chatId": chatId,
        "error": "invalid_json",
      ])
      return
    }

    let targetChat = chats.first(where: {
      normalizedString($0["chatId"] ?? $0["chat_id"]) == chatId
    })
    let rawMessages = (targetChat?["messages"] as? [[String: Any]]) ?? []
    let rows = buildHistoryRowsLocked(chatId: chatId, rawMessages: rawMessages)
    historyRowsByChat[chatId] = rows
    state["updatedAt"] = nowMs()
    appendJournalLocked(event: "native-chat-history-load-ok", payload: [
      "chatId": chatId,
      "rows": rows.count,
      "messages": rawMessages.count,
    ])
    let snapshot = statusSnapshotLocked()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
  }

  private func buildHistoryRowsLocked(chatId: String, rawMessages: [[String: Any]]) -> [[String: Any]] {
    let sortedMessages = rawMessages.sorted { lhs, rhs in
      let lt = parseLongValue(lhs["timestamp"] ?? lhs["timestampMs"] ?? lhs["timestamp_ms"]) ?? 0
      let rt = parseLongValue(rhs["timestamp"] ?? rhs["timestampMs"] ?? rhs["timestamp_ms"]) ?? 0
      return lt < rt
    }
    return sortedMessages.compactMap { raw in
      guard let messageId = normalizedString(raw["id"] ?? raw["message_id"]) else { return nil }
      let fromId = normalizedString(raw["fromId"] ?? raw["from_id"])
      let type = normalizedString(raw["type"]) ?? "text"
      let timestampMs = parseLongValue(raw["timestamp"] ?? raw["timestampMs"] ?? raw["timestamp_ms"]) ?? Int64(nowMs())
      let encryptedContent = normalizedString(raw["encryptedContent"] ?? raw["encrypted_content"])
      let plaintextFallback = normalizedString(raw["plaintext"] ?? raw["text"]) ?? ""
      let serverStatus = normalizedString(raw["status"])?.lowercased()
      let isEdited = ((raw["isEdited"] as? Bool) == true)
      let editedAt = raw["editedAt"] ?? raw["edited_at"]
      let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
      let hadEncryptedContent = encryptedContent != nil && !encryptedContent!.isEmpty
      var historyDecryptionFailed = false
      let decryptedFields: [String: Any] = {
        if let encryptedContent, !encryptedContent.isEmpty, let privateKey = decryptPrivateKeyLocked() {
          let decrypted = chatEngineDecryptHybridMessage(
            privateKey: privateKey,
            ciphertext: encryptedContent,
            isMyMessage: isMe
          )
          let parsed = parseDecryptedMessagePayload(decrypted)
          if !parsed.isEmpty { return parsed }
          historyDecryptionFailed = true
        }
        return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
      }()
      var row = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: fromId,
        type: type,
        timestampMs: timestampMs,
        encryptedContent: encryptedContent,
        decryptedFields: decryptedFields,
        forceEdited: isEdited,
        forceEditedAt: editedAt
      )
      if var message = row["message"] as? [String: Any] {
        if let serverStatus { message["status"] = serverStatus }
        if let reactionEmoji = normalizedString(raw["reactionEmoji"] ?? raw["reaction_emoji"]) {
          message["reactionEmoji"] = reactionEmoji
        }
        if hadEncryptedContent && historyDecryptionFailed {
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
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: info)
  }

  private func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
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
}
