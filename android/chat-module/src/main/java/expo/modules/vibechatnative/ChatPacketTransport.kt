package expo.modules.vibechatnative

internal class ChatPacketTransport(
  socketUrl: String,
  authToken: String?,
  proxyHost: String,
  proxyPort: Int,
  callbacks: ChatTransportCallbacks,
) : ChatRealtimeTransport {
  private val inner = ChatPhoenixClient(
    socketUrl = socketUrl,
    params = emptyMap(),
    authToken = authToken,
    proxyConfig = ChatProxyConfiguration(proxyHost, proxyPort),
    callbacks = callbacks,
  )

  override fun connect() {
    inner.connect()
  }

  override fun disconnect() {
    inner.disconnect()
  }

  override fun join(topic: String, payload: Map<String, Any?>): String =
    inner.join(topic, payload)

  override fun leave(topic: String): String =
    inner.leave(topic)

  override fun push(topic: String, event: String, payload: Map<String, Any?>): String =
    inner.push(topic, event, payload)
}
