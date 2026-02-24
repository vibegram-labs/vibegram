import Foundation

@available(iOS 13.0, *)
final class ChatPhoenixClient: NSObject, URLSessionWebSocketDelegate {
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

  private let baseURL: URL
  private let params: [String: String]
  private let callbacks: Callbacks
  private let queue = DispatchQueue(label: "vibe.chat.phoenix.client")
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var heartbeatTimer: DispatchSourceTimer?
  private var nextRefValue: Int = 1
  private var isClosing = false

  init(baseURL: URL, params: [String: String], callbacks: Callbacks) {
    self.baseURL = baseURL
    self.params = params
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
      config.timeoutIntervalForRequest = 30
      let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
      let task = session.webSocketTask(with: url)
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
    var items = components.queryItems ?? []
    for (key, value) in params where !key.isEmpty {
      items.removeAll { $0.name == key }
      items.append(URLQueryItem(name: key, value: value))
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
      let frame: [Any] = [
        joinRef ?? NSNull(),
        ref ?? NSNull(),
        topic,
        event,
        payload,
      ]
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

    guard let data,
          let raw = try? JSONSerialization.jsonObject(with: data) as? [Any],
          raw.count >= 5
    else { return }

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

  private func startHeartbeatLocked() {
    stopHeartbeatLocked()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 25, repeating: 25)
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
}
