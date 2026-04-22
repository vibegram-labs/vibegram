import Foundation

@available(iOS 13.0, *)
struct ChatTransportFrame {
  let joinRef: String?
  let ref: String?
  let topic: String
  let event: String
  let payload: [String: Any]
}

@available(iOS 13.0, *)
struct ChatTransportCallbacks {
  let onOpen: () -> Void
  let onClose: (_ code: Int, _ reason: String?) -> Void
  let onError: (_ error: String) -> Void
  let onEvent: (_ frame: ChatTransportFrame) -> Void
}

@available(iOS 13.0, *)
protocol ChatRealtimeTransport: AnyObject {
  func connect()
  func disconnect()
  @discardableResult
  func join(topic: String, payload: [String: Any]) -> String
  @discardableResult
  func leave(topic: String) -> String
  @discardableResult
  func push(topic: String, event: String, payload: [String: Any]) -> String
}
