import Foundation

@available(iOS 13.0, *)
final class ChatPacketTransport: ChatRealtimeTransport {
  private let inner: ChatPhoenixClient

  init(
    socketURL: URL,
    authToken: String?,
    proxyHost: String,
    proxyPort: Int,
    callbacks: ChatTransportCallbacks
  ) {
    self.inner = ChatPhoenixClient(
      baseURL: socketURL,
      params: [:],
      authToken: authToken,
      proxyConfig: ChatProxyConfiguration(host: proxyHost, port: proxyPort),
      callbacks: callbacks
    )
  }

  func connect() {
    inner.connect()
  }

  func disconnect() {
    inner.disconnect()
  }

  @discardableResult
  func join(topic: String, payload: [String: Any]) -> String {
    inner.join(topic: topic, payload: payload)
  }

  @discardableResult
  func leave(topic: String) -> String {
    inner.leave(topic: topic)
  }

  @discardableResult
  func push(topic: String, event: String, payload: [String: Any]) -> String {
    inner.push(topic: topic, event: event, payload: payload)
  }
}
