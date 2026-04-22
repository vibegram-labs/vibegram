import Dispatch
import Foundation
import Security

@available(iOS 13.0, *)
private final class ChatBridgePinnedSessionDelegate: NSObject, URLSessionDelegate {
  private let pinnedHashes: Set<String>

  init(pinnedHashes: Set<String>) {
    self.pinnedHashes = pinnedHashes
    super.init()
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let serverTrust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    guard !pinnedHashes.isEmpty else {
      completionHandler(.performDefaultHandling, nil)
      return
    }

    var error: CFError?
    guard SecTrustEvaluateWithError(serverTrust, &error) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
    for cert in certChain {
      if let spkiHash = ChatPhoenixClient.sha256SPKIHash(of: cert), pinnedHashes.contains(spkiHash)
      {
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
        return
      }
    }

    completionHandler(.cancelAuthenticationChallenge, nil)
  }
}

@available(iOS 13.0, *)
final class ChatBlackoutTransport: NSObject, ChatRealtimeTransport {
  private struct BridgeTarget {
    let id: String
    let baseURL: URL
    let pinnedHashes: Set<String>
    let priority: Int
  }

  private let callbacks: ChatTransportCallbacks
  private let authToken: String?
  private let userId: String
  private let activeBridgeId: String?
  private let queue = DispatchQueue(label: "vibe.chat.blackout.transport")
  private let requestTimeout: TimeInterval = 32
  private let pollBackoffMs: Int = 1200
  private let fatalFailureThreshold = 3
  private let queueSpecificKey = DispatchSpecificKey<UInt8>()
  private let queueSpecificValue: UInt8 = 1
  private var bridges: [BridgeTarget]
  private var currentBridgeIndex = 0
  private var sessionId: String?
  private var pollCursor: String?
  private var joinedTopics = Set<String>()
  private var isClosing = false
  private var isConnected = false
  private var nextRefValue = 1
  private var consecutiveFailures = 0
  private var pollWorkItem: DispatchWorkItem?

  init(
    baseURL: URL,
    authToken: String?,
    userId: String,
    activeBridgeId: String?,
    bridgeBundle: [String: Any]?,
    callbacks: ChatTransportCallbacks
  ) {
    self.authToken = authToken
    self.userId = userId
    self.activeBridgeId = activeBridgeId
    self.callbacks = callbacks
    self.bridges = Self.resolveBridgeTargets(
      explicitBaseURL: baseURL,
      activeBridgeId: activeBridgeId,
      bridgeBundle: bridgeBundle
    )
    super.init()
    queue.setSpecific(key: queueSpecificKey, value: queueSpecificValue)
  }

  func connect() {
    queue.async {
      self.isClosing = false
      self.isConnected = false
      self.sessionId = nil
      self.pollCursor = nil
      self.consecutiveFailures = 0
      self.openSessionLocked()
    }
  }

  func disconnect() {
    queue.async {
      self.isClosing = true
      self.isConnected = false
      self.sessionId = nil
      self.pollCursor = nil
      self.pollWorkItem?.cancel()
      self.pollWorkItem = nil
    }
  }

  @discardableResult
  func join(topic: String, payload: [String: Any]) -> String {
    let ref = nextRef()
    queue.async {
      self.joinedTopics.insert(topic)
      self.emitFrameLocked(
        ChatTransportFrame(
          joinRef: ref,
          ref: ref,
          topic: topic,
          event: "phx_reply",
          payload: ["status": "ok", "response": payload]
        ))
      if self.isConnected {
        self.schedulePollLocked(immediate: true)
      }
    }
    return ref
  }

  @discardableResult
  func leave(topic: String) -> String {
    let ref = nextRef()
    queue.async {
      self.joinedTopics.remove(topic)
      self.emitFrameLocked(
        ChatTransportFrame(
          joinRef: ref,
          ref: ref,
          topic: topic,
          event: "phx_reply",
          payload: ["status": "ok", "response": [:]]
        ))
      if self.isConnected {
        self.schedulePollLocked(immediate: true)
      }
    }
    return ref
  }

  @discardableResult
  func push(topic: String, event: String, payload: [String: Any]) -> String {
    let ref = nextRef()
    queue.async {
      guard self.isConnected, let sessionId = self.sessionId else {
        self.emitFrameLocked(
          ChatTransportFrame(
            joinRef: nil,
            ref: ref,
            topic: topic,
            event: "phx_reply",
            payload: [
              "status": "error",
              "response": ["reason": "bridge_unavailable"],
            ]
          ))
        return
      }

      let endpoint: String
      var body: [String: Any] = [
        "sessionId": sessionId,
        "topic": topic,
        "event": event,
        "payload": payload,
      ]

      switch event {
      case "message":
        endpoint = "/bridge/v1/text/send"
        body["chatId"] = Self.chatId(from: topic)
      case "delivery-receipt", "read-receipt":
        endpoint = "/bridge/v1/text/ack"
        body["chatId"] = Self.chatId(from: topic)
      default:
        endpoint = "/bridge/v1/text/send"
        body["chatId"] = Self.chatId(from: topic)
      }

      self.performJSONRequestLocked(path: endpoint, body: body) { result in
        self.queue.async {
          guard !self.isClosing else { return }
          switch result {
          case .success(let response):
            self.consecutiveFailures = 0
            self.handleResponseFramesLocked(response, fallbackTopic: topic, fallbackEvent: event)
            self.emitFrameLocked(
              ChatTransportFrame(
                joinRef: nil,
                ref: ref,
                topic: topic,
                event: "phx_reply",
                payload: ["status": "ok", "response": response]
              ))
            if event == "message" {
              self.schedulePollLocked(immediate: true)
            }
          case .failure(let error):
            self.emitFrameLocked(
              ChatTransportFrame(
                joinRef: nil,
                ref: ref,
                topic: topic,
                event: "phx_reply",
                payload: [
                  "status": "error",
                  "response": ["reason": error],
                ]
              ))
            self.callbacks.onError("bridge_push_failed:\(error)")
          }
        }
      }
    }
    return ref
  }

  private func openSessionLocked() {
    guard let bridge = currentBridgeLocked() else {
      callbacks.onError("bridge_config_missing")
      callbacks.onClose(-1, "bridge_config_missing")
      return
    }

    var body: [String: Any] = [
      "userId": userId,
      "bridgeId": bridge.id,
    ]
    if let activeBridgeId, !activeBridgeId.isEmpty {
      body["activeBridgeId"] = activeBridgeId
    }
    performJSONRequestLocked(path: "/bridge/v1/session/open", body: body) { result in
      self.queue.async {
        guard !self.isClosing else { return }
        switch result {
        case .success(let response):
          self.sessionId =
            Self.stringValue(response["sessionId"])
            ?? Self.stringValue(response["session_id"])
            ?? UUID().uuidString.lowercased()
          self.pollCursor =
            Self.stringValue(response["cursor"])
            ?? Self.stringValue(response["nextCursor"])
            ?? Self.stringValue(response["next_cursor"])
          self.isConnected = true
          self.consecutiveFailures = 0
          self.callbacks.onOpen()
          self.handleResponseFramesLocked(
            response,
            fallbackTopic: "user:\(self.userId)",
            fallbackEvent: "phx_reply"
          )
          self.schedulePollLocked(immediate: true)
        case .failure(let error):
          self.handleBridgeFailureLocked(error: "bridge_open_failed:\(error)")
        }
      }
    }
  }

  private func schedulePollLocked(immediate: Bool) {
    pollWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.queue.async {
        self?.pollLocked()
      }
    }
    pollWorkItem = workItem
    let delay = immediate ? DispatchTime.now() : .now() + .milliseconds(pollBackoffMs)
    queue.asyncAfter(deadline: delay, execute: workItem)
  }

  private func pollLocked() {
    guard !isClosing, isConnected, let sessionId = sessionId else { return }
    var body: [String: Any] = [
      "sessionId": sessionId,
      "topics": Array(joinedTopics).sorted(),
    ]
    if let pollCursor, !pollCursor.isEmpty {
      body["cursor"] = pollCursor
    }
    performJSONRequestLocked(path: "/bridge/v1/text/poll", body: body) { result in
      self.queue.async {
        guard !self.isClosing else { return }
        switch result {
        case .success(let response):
          self.consecutiveFailures = 0
          self.pollCursor =
            Self.stringValue(response["cursor"])
            ?? Self.stringValue(response["nextCursor"])
            ?? Self.stringValue(response["next_cursor"])
            ?? self.pollCursor
          self.handleResponseFramesLocked(
            response,
            fallbackTopic: "user:\(self.userId)",
            fallbackEvent: "message"
          )
          self.schedulePollLocked(immediate: true)
        case .failure(let error):
          self.handleBridgeFailureLocked(error: "bridge_poll_failed:\(error)")
        }
      }
    }
  }

  private func handleBridgeFailureLocked(error: String) {
    consecutiveFailures += 1
    callbacks.onError(error)
    if bridges.count > 1, consecutiveFailures >= fatalFailureThreshold {
      currentBridgeIndex = (currentBridgeIndex + 1) % bridges.count
      sessionId = nil
      pollCursor = nil
      consecutiveFailures = 0
      openSessionLocked()
      return
    }
    if consecutiveFailures >= fatalFailureThreshold {
      isConnected = false
      sessionId = nil
      pollCursor = nil
      callbacks.onClose(-1, error)
      return
    }
    schedulePollLocked(immediate: false)
  }

  private func currentBridgeLocked() -> BridgeTarget? {
    guard !bridges.isEmpty else { return nil }
    let index = min(max(0, currentBridgeIndex), bridges.count - 1)
    return bridges[index]
  }

  private func performJSONRequestLocked(
    path: String,
    body: [String: Any],
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    guard let bridge = currentBridgeLocked() else {
      completion(
        .failure(
          NSError(
            domain: "ChatBlackoutTransport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "bridge_missing"]
          )))
      return
    }
    let url = Self.resolveURL(baseURL: bridge.baseURL, path: path)
    guard let url else {
      completion(
        .failure(
          NSError(
            domain: "ChatBlackoutTransport",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "invalid_bridge_url"]
          )))
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
    guard JSONSerialization.isValidJSONObject(body),
      let data = try? JSONSerialization.data(withJSONObject: body, options: [])
    else {
      completion(
        .failure(
          NSError(
            domain: "ChatBlackoutTransport",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "invalid_body"]
          )))
      return
    }
    request.httpBody = data

    let delegate = ChatBridgePinnedSessionDelegate(pinnedHashes: bridge.pinnedHashes)
    let session = ChatPhoenixClient.makePinnedURLSession(delegate: delegate)
    let task = session.dataTask(with: request) { data, response, error in
      defer { session.finishTasksAndInvalidate() }
      if let error {
        completion(.failure(error))
        return
      }
      guard let httpResponse = response as? HTTPURLResponse else {
        completion(
          .failure(
            NSError(
              domain: "ChatBlackoutTransport",
              code: 4,
              userInfo: [NSLocalizedDescriptionKey: "invalid_response"]
            )))
        return
      }
      guard (200...299).contains(httpResponse.statusCode) else {
        let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        completion(
          .failure(
            NSError(
              domain: "ChatBlackoutTransport",
              code: httpResponse.statusCode,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "http_\(httpResponse.statusCode):\(bodyText.prefix(160))"
              ]
            )))
        return
      }
      guard let data, !data.isEmpty else {
        completion(.success([:]))
        return
      }
      guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      else {
        completion(
          .failure(
            NSError(
              domain: "ChatBlackoutTransport",
              code: 5,
              userInfo: [NSLocalizedDescriptionKey: "invalid_json"]
            )))
        return
      }
      if let map = json as? [String: Any] {
        completion(.success(map))
        return
      }
      if let list = json as? [[String: Any]] {
        completion(.success(["events": list]))
        return
      }
      completion(.success([:]))
    }
    task.resume()
  }

  private func handleResponseFramesLocked(
    _ response: [String: Any], fallbackTopic: String, fallbackEvent: String
  ) {
    if let events = response["events"] as? [[String: Any]], !events.isEmpty {
      for event in events {
        emitFrameFromMapLocked(event, fallbackTopic: fallbackTopic, fallbackEvent: fallbackEvent)
      }
      return
    }

    if let messages = response["messages"] as? [[String: Any]], !messages.isEmpty {
      for message in messages {
        emitFrameFromMapLocked(message, fallbackTopic: fallbackTopic, fallbackEvent: "message")
      }
      return
    }
  }

  private func emitFrameFromMapLocked(
    _ map: [String: Any], fallbackTopic: String, fallbackEvent: String
  ) {
    let topic =
      Self.stringValue(map["topic"])
      ?? Self.stringValue(map["chatTopic"])
      ?? Self.stringValue(map["chat_topic"])
      ?? Self.chatId(from: Self.stringValue(map["chatId"]) ?? Self.stringValue(map["chat_id"]) ?? "")
        .map { "chat:\($0)" }
      ?? fallbackTopic
    let event = Self.stringValue(map["event"]) ?? fallbackEvent
    let payload =
      (map["payload"] as? [String: Any])
      ?? Self.extractPayload(from: map)
    let frame = ChatTransportFrame(
      joinRef: Self.stringValue(map["joinRef"]) ?? Self.stringValue(map["join_ref"]),
      ref: Self.stringValue(map["ref"]),
      topic: topic,
      event: event,
      payload: payload
    )
    emitFrameLocked(frame)
  }

  private func emitFrameLocked(_ frame: ChatTransportFrame) {
    callbacks.onEvent(frame)
  }

  private func nextRef() -> String {
    if DispatchQueue.getSpecific(key: queueSpecificKey) == queueSpecificValue {
      return nextRefLocked()
    }
    return queue.sync { nextRefLocked() }
  }

  private func nextRefLocked() -> String {
    let value = nextRefValue
    nextRefValue += 1
    return String(value)
  }

  private static func resolveBridgeTargets(
    explicitBaseURL: URL,
    activeBridgeId: String?,
    bridgeBundle: [String: Any]?
  ) -> [BridgeTarget] {
    var targets: [BridgeTarget] = []
    let descriptors = bridgeBundle?["descriptors"] as? [[String: Any]] ?? []
    for descriptor in descriptors {
      let id =
        stringValue(descriptor["id"])
        ?? stringValue(descriptor["host"])
        ?? UUID().uuidString.lowercased()
      let url =
        stringValue(descriptor["baseUrl"]).flatMap(URL.init(string:))
        ?? buildDescriptorURL(descriptor)
      guard let url else { continue }
      let pins = Set((descriptor["spkiPins"] as? [String] ?? []).filter { !$0.isEmpty })
      let priority = Int(truncating: (descriptor["priority"] as? NSNumber) ?? 999)
      targets.append(
        BridgeTarget(id: id, baseURL: url, pinnedHashes: pins, priority: priority)
      )
    }

    if targets.isEmpty {
      targets = [
        BridgeTarget(
          id: activeBridgeId ?? "explicit",
          baseURL: explicitBaseURL,
          pinnedHashes: [],
          priority: 0
        )
      ]
    }

    return targets.sorted { left, right in
      if left.id == activeBridgeId { return true }
      if right.id == activeBridgeId { return false }
      return left.priority < right.priority
    }
  }

  private static func buildDescriptorURL(_ descriptor: [String: Any]) -> URL? {
    guard let host = stringValue(descriptor["host"]) else { return nil }
    let scheme =
      (stringValue(descriptor["transport"]) == "http" ? "http" : "https")
    let port =
      (descriptor["port"] as? NSNumber)?.intValue
      ?? Int(stringValue(descriptor["port"]) ?? "")
    let pathPrefix = stringValue(descriptor["pathPrefix"])?.trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
    var base = "\(scheme)://\(host)"
    if let port { base += ":\(port)" }
    if let pathPrefix, !pathPrefix.isEmpty { base += "/\(pathPrefix)" }
    return URL(string: base)
  }

  private static func resolveURL(baseURL: URL, path: String) -> URL? {
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return baseURL.appendingPathComponent(trimmed)
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func chatId(from topic: String) -> String? {
    let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("chat:") {
      return String(trimmed.dropFirst(5))
    }
    return trimmed
  }

  private static func extractPayload(from map: [String: Any]) -> [String: Any] {
    var payload = map
    ["topic", "event", "ref", "joinRef", "join_ref", "chatId", "chat_id", "chatTopic",
     "chat_topic"].forEach { payload.removeValue(forKey: $0) }
    return payload
  }
}
