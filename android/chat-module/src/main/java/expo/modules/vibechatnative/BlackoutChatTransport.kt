package expo.modules.vibechatnative

import okhttp3.Call
import okhttp3.Callback
import okhttp3.CertificatePinner
import okhttp3.ConnectionSpec
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.TlsVersion
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

internal class BlackoutChatTransport(
  bridgeBaseUrl: String,
  private val authToken: String?,
  private val userId: String,
  private val activeBridgeId: String?,
  bridgeBundle: Map<String, Any?>?,
  private val callbacks: ChatTransportCallbacks,
) : ChatRealtimeTransport {
  private data class BridgeTarget(
    val id: String,
    val baseUrl: String,
    val pins: List<String>,
    val priority: Int,
  )

  private val refCounter = AtomicLong(1L)
  private val joinedTopics = linkedSetOf<String>()
  @Volatile private var isClosing = false
  @Volatile private var isConnected = false
  @Volatile private var sessionId: String? = null
  @Volatile private var pollCursor: String? = null
  private var pollCall: Call? = null
  private var consecutiveFailures = 0
  private val bridges = resolveBridgeTargets(bridgeBaseUrl, activeBridgeId, bridgeBundle)
  @Volatile private var currentBridgeIndex = 0

  override fun connect() {
    isClosing = false
    isConnected = false
    sessionId = null
    pollCursor = null
    consecutiveFailures = 0
    openSession()
  }

  override fun disconnect() {
    isClosing = true
    isConnected = false
    sessionId = null
    pollCursor = null
    pollCall?.cancel()
    pollCall = null
  }

  override fun join(topic: String, payload: Map<String, Any?>): String {
    val ref = refCounter.getAndIncrement().toString()
    joinedTopics.add(topic)
    callbacks.onEvent(
      ChatTransportEvent(
        topic = topic,
        event = "phx_reply",
        payload = mapOf("status" to "ok", "response" to payload),
        ref = ref,
        joinRef = ref,
      ),
    )
    if (isConnected) schedulePoll()
    return ref
  }

  override fun leave(topic: String): String {
    val ref = refCounter.getAndIncrement().toString()
    joinedTopics.remove(topic)
    callbacks.onEvent(
      ChatTransportEvent(
        topic = topic,
        event = "phx_reply",
        payload = mapOf("status" to "ok", "response" to emptyMap<String, Any?>()),
        ref = ref,
        joinRef = ref,
      ),
    )
    return ref
  }

  override fun push(topic: String, event: String, payload: Map<String, Any?>): String {
    val ref = refCounter.getAndIncrement().toString()
    val currentSessionId = sessionId
    if (!isConnected || currentSessionId.isNullOrBlank()) {
      callbacks.onEvent(
        ChatTransportEvent(
          topic = topic,
          event = "phx_reply",
          payload = mapOf("status" to "error", "response" to mapOf("reason" to "bridge_unavailable")),
          ref = ref,
        ),
      )
      return ref
    }

    val endpoint = when (event) {
      "delivery-receipt", "read-receipt" -> "/bridge/v1/text/ack"
      else -> "/bridge/v1/text/send"
    }
    val body = linkedMapOf<String, Any?>(
      "sessionId" to currentSessionId,
      "topic" to topic,
      "event" to event,
      "chatId" to topic.removePrefix("chat:"),
      "payload" to payload,
    )
    performJsonRequest(endpoint, body) { result ->
      if (isClosing) return@performJsonRequest
      result.fold(
        onSuccess = { response ->
          consecutiveFailures = 0
          emitFramesFromResponse(response, fallbackTopic = topic, fallbackEvent = event)
          callbacks.onEvent(
            ChatTransportEvent(
              topic = topic,
              event = "phx_reply",
              payload = mapOf("status" to "ok", "response" to response),
              ref = ref,
            ),
          )
          if (event == "message") schedulePoll()
        },
        onFailure = { error ->
          callbacks.onError("bridge_push_failed:${error.message ?: "unknown"}")
          callbacks.onEvent(
            ChatTransportEvent(
              topic = topic,
              event = "phx_reply",
              payload = mapOf(
                "status" to "error",
                "response" to mapOf("reason" to (error.message ?: "bridge_push_failed")),
              ),
              ref = ref,
            ),
          )
        },
      )
    }
    return ref
  }

  private fun openSession() {
    val bridge = currentBridge() ?: run {
      callbacks.onError("bridge_config_missing")
      callbacks.onClosed(-1, "bridge_config_missing")
      return
    }
    val body = linkedMapOf<String, Any?>(
      "userId" to userId,
      "bridgeId" to bridge.id,
    )
    if (!activeBridgeId.isNullOrBlank()) {
      body["activeBridgeId"] = activeBridgeId
    }
    performJsonRequest("/bridge/v1/session/open", body) { result ->
      if (isClosing) return@performJsonRequest
      result.fold(
        onSuccess = { response ->
          sessionId = stringValue(response["sessionId"] ?: response["session_id"])
            ?: java.util.UUID.randomUUID().toString().lowercase()
          pollCursor =
            stringValue(response["cursor"] ?: response["nextCursor"] ?: response["next_cursor"])
          isConnected = true
          consecutiveFailures = 0
          callbacks.onOpen()
          emitFramesFromResponse(response, fallbackTopic = "user:$userId", fallbackEvent = "phx_reply")
          schedulePoll()
        },
        onFailure = { error ->
          handleBridgeFailure("bridge_open_failed:${error.message ?: "unknown"}")
        },
      )
    }
  }

  private fun schedulePoll() {
    poll()
  }

  private fun poll() {
    val currentSessionId = sessionId ?: return
    if (isClosing || !isConnected) return
    val body = linkedMapOf<String, Any?>(
      "sessionId" to currentSessionId,
      "topics" to joinedTopics.toList(),
    )
    if (!pollCursor.isNullOrBlank()) {
      body["cursor"] = pollCursor
    }
    performJsonRequest("/bridge/v1/text/poll", body, assignPollCall = true) { result ->
      if (isClosing) return@performJsonRequest
      result.fold(
        onSuccess = { response ->
          consecutiveFailures = 0
          pollCursor =
            stringValue(response["cursor"] ?: response["nextCursor"] ?: response["next_cursor"])
              ?: pollCursor
          emitFramesFromResponse(response, fallbackTopic = "user:$userId", fallbackEvent = "message")
          schedulePoll()
        },
        onFailure = { error ->
          handleBridgeFailure("bridge_poll_failed:${error.message ?: "unknown"}")
        },
      )
    }
  }

  private fun handleBridgeFailure(error: String) {
    consecutiveFailures += 1
    callbacks.onError(error)
    if (bridges.size > 1 && consecutiveFailures >= 3) {
      currentBridgeIndex = (currentBridgeIndex + 1) % bridges.size
      sessionId = null
      pollCursor = null
      consecutiveFailures = 0
      openSession()
      return
    }
    if (consecutiveFailures >= 3) {
      isConnected = false
      sessionId = null
      pollCursor = null
      callbacks.onClosed(-1, error)
      return
    }
    schedulePoll()
  }

  private fun performJsonRequest(
    path: String,
    body: Map<String, Any?>,
    assignPollCall: Boolean = false,
    completion: (Result<Map<String, Any?>>) -> Unit,
  ) {
    val bridge = currentBridge()
    val client = bridge?.let(::buildClient)
    val url = bridge?.baseUrl?.trimEnd('/')?.plus("/${path.trimStart('/')}")
    val httpUrl = url?.toHttpUrlOrNull()
    if (bridge == null || client == null || httpUrl == null) {
      completion(Result.failure(IllegalStateException("invalid_bridge_url")))
      return
    }
    val requestBody = (mapToJson(body) as JSONObject).toString().toRequestBody(
      "application/json".toMediaTypeOrNull(),
    )
    val requestBuilder = Request.Builder()
      .url(httpUrl)
      .post(requestBody)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
    if (!authToken.isNullOrBlank()) {
      requestBuilder.header("Authorization", "Bearer $authToken")
    }
    val call = client.newCall(requestBuilder.build())
    if (assignPollCall) {
      pollCall = call
    }
    call.enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        completion(Result.failure(e))
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          if (!res.isSuccessful) {
            val bodyText = try { res.body?.string().orEmpty() } catch (_: Throwable) { "" }
            completion(Result.failure(IllegalStateException("http_${res.code}:${bodyText.take(160)}")))
            return
          }
          val bodyText = try { res.body?.string().orEmpty() } catch (_: Throwable) { "" }
          if (bodyText.isBlank()) {
            completion(Result.success(emptyMap()))
            return
          }
          try {
            val parsed = if (bodyText.trimStart().startsWith("[")) {
              mapOf("events" to jsonToAny(JSONArray(bodyText)))
            } else {
              jsonToAny(JSONObject(bodyText)) as? Map<String, Any?> ?: emptyMap()
            }
            completion(Result.success(parsed))
          } catch (error: Throwable) {
            completion(Result.failure(IllegalStateException("invalid_json")))
          }
        }
      }
    })
  }

  private fun emitFramesFromResponse(
    response: Map<String, Any?>,
    fallbackTopic: String,
    fallbackEvent: String,
  ) {
    val rawEvents = response["events"] as? List<*>
    if (!rawEvents.isNullOrEmpty()) {
      rawEvents.mapNotNull { it as? Map<*, *> }.forEach {
        emitFrameFromMap(it, fallbackTopic, fallbackEvent)
      }
      return
    }
    val rawMessages = response["messages"] as? List<*>
    if (!rawMessages.isNullOrEmpty()) {
      rawMessages.mapNotNull { it as? Map<*, *> }.forEach {
        emitFrameFromMap(it, fallbackTopic, "message")
      }
    }
  }

  private fun emitFrameFromMap(
    raw: Map<*, *>,
    fallbackTopic: String,
    fallbackEvent: String,
  ) {
    val map = raw.entries.associate { it.key.toString() to it.value }
    val chatId = stringValue(map["chatId"] ?: map["chat_id"])
    val topic =
      stringValue(map["topic"] ?: map["chatTopic"] ?: map["chat_topic"])
        ?: chatId?.let { "chat:$it" }
        ?: fallbackTopic
    val event = stringValue(map["event"]) ?: fallbackEvent
    val payload = (map["payload"] as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value }
      ?: map.filterKeys {
        it !in setOf("topic", "chatTopic", "chat_topic", "chatId", "chat_id", "event", "ref", "joinRef", "join_ref")
      }
    callbacks.onEvent(
      ChatTransportEvent(
        topic = topic,
        event = event,
        payload = payload,
        ref = stringValue(map["ref"]),
        joinRef = stringValue(map["joinRef"] ?: map["join_ref"]),
      ),
    )
  }

  private fun currentBridge(): BridgeTarget? {
    if (bridges.isEmpty()) return null
    val index = currentBridgeIndex.coerceIn(0, bridges.lastIndex)
    return bridges[index]
  }

  private fun buildClient(bridge: BridgeTarget): OkHttpClient {
    val builder = OkHttpClient.Builder()
      .connectionSpecs(
        listOf(
          ConnectionSpec.Builder(ConnectionSpec.MODERN_TLS)
            .tlsVersions(TlsVersion.TLS_1_2, TlsVersion.TLS_1_3)
            .build(),
        ),
      )
    if (bridge.pins.isNotEmpty()) {
      val host = bridge.baseUrl.toHttpUrlOrNull()?.host
      if (!host.isNullOrBlank()) {
        val pinnerBuilder = CertificatePinner.Builder()
        bridge.pins.forEach { pin -> pinnerBuilder.add(host, "sha256/$pin") }
        builder.certificatePinner(pinnerBuilder.build())
      }
    }
    return builder.build()
  }

  private fun resolveBridgeTargets(
    bridgeBaseUrl: String,
    activeBridgeId: String?,
    bridgeBundle: Map<String, Any?>?,
  ): List<BridgeTarget> {
    val targets = mutableListOf<BridgeTarget>()
    val descriptors = bridgeBundle?.get("descriptors") as? List<*> ?: emptyList<Any?>()
    descriptors.mapNotNull { it as? Map<*, *> }.forEach { descriptor ->
      val baseUrl = stringValue(descriptor["baseUrl"])
        ?: buildDescriptorBaseUrl(descriptor)
        ?: return@forEach
      val id = stringValue(descriptor["id"] ?: descriptor["host"]) ?: baseUrl
      val pins = (descriptor["spkiPins"] as? List<*>)?.mapNotNull { stringValue(it) }.orEmpty()
      val priority = (descriptor["priority"] as? Number)?.toInt() ?: 999
      targets.add(BridgeTarget(id = id, baseUrl = baseUrl, pins = pins, priority = priority))
    }
    if (targets.isEmpty()) {
      targets.add(BridgeTarget(id = activeBridgeId ?: "explicit", baseUrl = bridgeBaseUrl, pins = emptyList(), priority = 0))
    }
    return targets.sortedWith(compareBy<BridgeTarget> {
      if (it.id == activeBridgeId) -1 else it.priority
    })
  }

  private fun buildDescriptorBaseUrl(descriptor: Map<*, *>): String? {
    val host = stringValue(descriptor["host"]) ?: return null
    val scheme = if (stringValue(descriptor["transport"]) == "http") "http" else "https"
    val port = (descriptor["port"] as? Number)?.toInt()?.let { ":$it" }.orEmpty()
    val pathPrefix = stringValue(descriptor["pathPrefix"])?.trim('/')?.takeIf { it.isNotEmpty() }
    return buildString {
      append("$scheme://$host$port")
      if (!pathPrefix.isNullOrBlank()) {
        append("/")
        append(pathPrefix)
      }
    }
  }

  private fun stringValue(value: Any?): String? {
    val text = value?.toString()?.trim().orEmpty()
    return text.ifEmpty { null }
  }

  private fun jsonToAny(value: Any?): Any? =
    when (value) {
      null, JSONObject.NULL -> null
      is JSONObject -> {
        val out = linkedMapOf<String, Any?>()
        val keys = value.keys()
        while (keys.hasNext()) {
          val key = keys.next()
          out[key] = jsonToAny(value.opt(key))
        }
        out
      }
      is JSONArray -> {
        val out = ArrayList<Any?>(value.length())
        for (i in 0 until value.length()) out.add(jsonToAny(value.opt(i)))
        out
      }
      else -> value
    }

  private fun mapToJson(value: Any?): Any =
    when (value) {
      null -> JSONObject.NULL
      is JSONObject, is JSONArray, is Number, is Boolean, is String -> value
      is Map<*, *> -> {
        val obj = JSONObject()
        value.forEach { (k, v) ->
          if (k != null) obj.put(k.toString(), mapToJson(v))
        }
        obj
      }
      is Iterable<*> -> {
        val array = JSONArray()
        value.forEach { array.put(mapToJson(it)) }
        array
      }
      is Array<*> -> {
        val array = JSONArray()
        value.forEach { array.put(mapToJson(it)) }
        array
      }
      else -> value.toString()
    }
}
