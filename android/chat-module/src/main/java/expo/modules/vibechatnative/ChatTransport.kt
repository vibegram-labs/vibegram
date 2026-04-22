package expo.modules.vibechatnative

internal data class ChatTransportEvent(
  val topic: String,
  val event: String,
  val payload: Map<String, Any?>,
  val ref: String? = null,
  val joinRef: String? = null,
)

internal interface ChatTransportCallbacks {
  fun onOpen()
  fun onClosed(code: Int, reason: String?)
  fun onError(error: String)
  fun onEvent(frame: ChatTransportEvent)
}

internal interface ChatRealtimeTransport {
  fun connect()
  fun disconnect()
  fun join(topic: String, payload: Map<String, Any?> = emptyMap()): String
  fun leave(topic: String): String
  fun push(topic: String, event: String, payload: Map<String, Any?> = emptyMap()): String
}
