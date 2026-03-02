import CommonCrypto
import Foundation
import Security

@available(iOS 13.0, *)
final class ChatPhoenixClient: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate {
  struct EventFrame {
    let joinRef: String?
    let ref: String?
    let topic: String
    let event: String
    let payload: [String: Any]
  }

  struct Callbacks {
    let onOpen: () -> Void
    let onClose: (_ code: Int, _ reason: String?) -> Void
    let onError: (_ error: String) -> Void
    let onEvent: (_ frame: EventFrame) -> Void
  }

  // MARK: - Certificate Pinning Configuration

  /// SPKI SHA-256 hashes for certificate pinning.
  /// Add your server's leaf cert + at least one backup/intermediate hash.
  /// Generate with: openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64
  /// Set to empty to disable pinning (e.g. during development).
  static var pinnedSPKIHashes: Set<String> = [
    // "u6dScLDuE2TrAks7ct4HDBekXo9byFES6oApqW/pAjQ=",
    // "AlSQhgtJirc8ahLyekmtX+Iw+v46yPYRLJt9Cq1GlB0=",
  ]

  /// Whether certificate pinning is enforced. Disabled when no hashes are configured.
  static var pinningEnabled: Bool { !pinnedSPKIHashes.isEmpty }

  private let baseURL: URL
  private let params: [String: String]
  private let authToken: String?
  private let callbacks: Callbacks
  private let queue = DispatchQueue(label: "vibe.chat.phoenix.client")
  private let connectRequestTimeout: TimeInterval = 8.0
  private let heartbeatInterval: TimeInterval = 10.0
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var heartbeatTimer: DispatchSourceTimer?
  private var nextRefValue: Int = 1
  private var isClosing = false

  init(baseURL: URL, params: [String: String], authToken: String? = nil, callbacks: Callbacks) {
    self.baseURL = baseURL
    self.params = params
    self.authToken = authToken
    self.callbacks = callbacks
    super.init()
    queue.setSpecific(key: queueKey, value: 1)
  }

  func connect() {
    queue.async {
      self.cleanupLocked()
      guard let url = self.makeSocketURL() else {
        self.callbacks.onError("invalid_socket_url")
        return
      }
      self.isClosing = false
      let config = URLSessionConfiguration.default
      config.timeoutIntervalForRequest = self.connectRequestTimeout
      config.tlsMinimumSupportedProtocolVersion = .TLSv12
      let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

      var request = URLRequest(url: url)
      request.timeoutInterval = self.connectRequestTimeout
      // Also send as Authorization header for any reverse-proxy / middleware
      // that may inspect it (the primary auth is the ?token= query param).
      if let token = self.authToken, !token.isEmpty {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }
      let task = session.webSocketTask(with: request)
      self.session = session
      self.task = task
      task.resume()
      self.receiveNext()
    }
  }

  func disconnect() {
    queue.async {
      self.isClosing = true
      self.stopHeartbeatLocked()
      self.task?.cancel(with: .goingAway, reason: nil)
      self.cleanupLocked()
    }
  }

  @discardableResult
  func join(topic: String, payload: [String: Any] = [:]) -> String {
    let ref = nextRef()
    sendFrame(joinRef: ref, ref: ref, topic: topic, event: "phx_join", payload: payload)
    return ref
  }

  @discardableResult
  func leave(topic: String) -> String {
    let ref = nextRef()
    sendFrame(joinRef: ref, ref: ref, topic: topic, event: "phx_leave", payload: [:])
    return ref
  }

  @discardableResult
  func push(topic: String, event: String, payload: [String: Any] = [:]) -> String {
    let ref = nextRef()
    sendFrame(joinRef: nil, ref: ref, topic: topic, event: event, payload: payload)
    return ref
  }

  private func nextRef() -> String {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return nextRefLocked()
    }
    return queue.sync { nextRefLocked() }
  }

  private func nextRefLocked() -> String {
    let value = nextRefValue
    nextRefValue += 1
    return String(value)
  }

  private func makeSocketURL() -> URL? {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    // Ensure the path ends with /websocket for Phoenix long-poll fallback compat.
    if !components.path.hasSuffix("/websocket") {
      components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      components.path = "/" + components.path + "/websocket"
    }
    var items = components.queryItems ?? []
    for (key, value) in params where !key.isEmpty {
      items.removeAll { $0.name == key }
      items.append(URLQueryItem(name: key, value: value))
    }
    // Phoenix's UserSocket expects the auth token as a "token" query param.
    // The Authorization header is NOT forwarded by Phoenix's :x_headers connect_info
    // (only headers prefixed x- are forwarded), so we must pass via query param.
    if let token = authToken, !token.isEmpty {
      items.removeAll { $0.name == "token" }
      items.append(URLQueryItem(name: "token", value: token))
    }
    components.queryItems = items.isEmpty ? nil : items
    return components.url
  }

  private func sendFrame(
    joinRef: String?,
    ref: String?,
    topic: String,
    event: String,
    payload: [String: Any]
  ) {
    queue.async {
      guard let task = self.task else { return }
      // Phoenix V1 JSON Serializer expects a JSON **object** (map),
      // NOT the V2 array wire format.
      var frame: [String: Any] = [
        "topic": topic,
        "event": event,
        "payload": payload,
      ]
      if let joinRef { frame["join_ref"] = joinRef }
      if let ref { frame["ref"] = ref }
      guard JSONSerialization.isValidJSONObject(frame),
        let data = try? JSONSerialization.data(withJSONObject: frame),
        let text = String(data: data, encoding: .utf8)
      else {
        self.callbacks.onError("serialize_frame_failed:\(event)")
        return
      }
      task.send(.string(text)) { [weak self] error in
        if let error {
          self?.callbacks.onError("send_failed:\(error.localizedDescription)")
        }
      }
    }
  }

  private func receiveNext() {
    queue.async {
      guard let task = self.task else { return }
      task.receive { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let message):
          self.handleMessage(message)
          self.receiveNext()
        case .failure(let error):
          if self.isClosing { return }
          self.callbacks.onError("receive_failed:\(error.localizedDescription)")
          self.callbacks.onClose(-1, error.localizedDescription)
        }
      }
    }
  }

  private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    let data: Data?
    switch message {
    case .string(let text):
      data = text.data(using: .utf8)
    case .data(let raw):
      data = raw
    @unknown default:
      data = nil
    }
    guard let data else { return }

    let parsed = try? JSONSerialization.jsonObject(with: data)

    // Phoenix V1 JSON format: {"topic":..., "event":..., "ref":..., "join_ref":..., "payload":...}
    if let map = parsed as? [String: Any] {
      let topic = map["topic"] as? String ?? ""
      let event = map["event"] as? String ?? ""
      guard !topic.isEmpty, !event.isEmpty else { return }
      let payload = (map["payload"] as? [String: Any]) ?? [:]
      let frame = EventFrame(
        joinRef: map["join_ref"] as? String,
        ref: map["ref"] as? String,
        topic: topic,
        event: event,
        payload: payload
      )
      callbacks.onEvent(frame)
      return
    }

    // Fallback: Phoenix V2 array format [joinRef, ref, topic, event, payload]
    if let raw = parsed as? [Any], raw.count >= 5 {
      let topic = raw[2] as? String ?? ""
      let event = raw[3] as? String ?? ""
      guard !topic.isEmpty, !event.isEmpty else { return }
      let payload = (raw[4] as? [String: Any]) ?? [:]
      let frame = EventFrame(
        joinRef: raw[0] is NSNull ? nil : (raw[0] as? String),
        ref: raw[1] is NSNull ? nil : (raw[1] as? String),
        topic: topic,
        event: event,
        payload: payload
      )
      callbacks.onEvent(frame)
    }
  }

  private func startHeartbeatLocked() {
    stopHeartbeatLocked()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.sendFrame(
        joinRef: nil,
        ref: self.nextRefLocked(),
        topic: "phoenix",
        event: "heartbeat",
        payload: [:]
      )
    }
    heartbeatTimer = timer
    timer.resume()
  }

  private func stopHeartbeatLocked() {
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
  }

  private func cleanupLocked() {
    stopHeartbeatLocked()
    task = nil
    session?.invalidateAndCancel()
    session = nil
  }

  private let queueKey = DispatchSpecificKey<UInt8>()

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    queue.async {
      self.startHeartbeatLocked()
      self.callbacks.onOpen()
    }
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
    queue.async {
      self.stopHeartbeatLocked()
      self.cleanupLocked()
      if self.isClosing { return }
      self.callbacks.onClose(Int(closeCode.rawValue), reasonText)
    }
  }

  // MARK: - Certificate Pinning (URLSessionDelegate)

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

    // If pinning is not configured, fall through to default validation.
    guard Self.pinningEnabled else {
      completionHandler(.performDefaultHandling, nil)
      return
    }

    // Evaluate the server trust first with standard validation.
    var error: CFError?
    guard SecTrustEvaluateWithError(serverTrust, &error) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    // Check each certificate in the chain for a matching SPKI hash.
    let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
    for cert in certChain {
      if let spkiHash = Self.sha256SPKIHash(of: cert),
        Self.pinnedSPKIHashes.contains(spkiHash)
      {
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
        return
      }
    }

    // No pin matched — reject.
    completionHandler(.cancelAuthenticationChallenge, nil)
  }

  /// Compute the SHA-256 hash of the certificate's Subject Public Key Info (SPKI).
  static func sha256SPKIHash(of certificate: SecCertificate) -> String? {
    guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
    var error: Unmanaged<CFError>?
    guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
      _ = error?.takeRetainedValue()
      return nil
    }
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    publicKeyData.withUnsafeBytes { buffer in
      _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
    }
    return Data(hash).base64EncodedString()
  }

  /// Shared pinned URLSession for HTTP requests (e.g. chat history).
  /// Uses the same pinning and TLS configuration as the WebSocket session.
  static func makePinnedURLSession(delegate: URLSessionDelegate? = nil) -> URLSession {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.tlsMinimumSupportedProtocolVersion = .TLSv12
    let pinnedDelegate = delegate ?? PinnedSessionDelegate()
    return URLSession(configuration: config, delegate: pinnedDelegate, delegateQueue: nil)
  }
}

/// Standalone delegate for HTTP requests that need cert pinning (e.g. history fetch).
@available(iOS 13.0, *)
final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
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

    guard ChatPhoenixClient.pinningEnabled else {
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
      if let spkiHash = ChatPhoenixClient.sha256SPKIHash(of: cert),
        ChatPhoenixClient.pinnedSPKIHashes.contains(spkiHash)
      {
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
        return
      }
    }

    completionHandler(.cancelAuthenticationChallenge, nil)
  }
}
