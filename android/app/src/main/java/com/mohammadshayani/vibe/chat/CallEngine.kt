package com.mohammadshayani.vibe.chat

import android.content.Context
import android.util.Log
import com.mohammadshayani.vibe.chat.notifications.VibeNativeCallStore
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

internal object NativeCallEngine {
  private val executor = Executors.newSingleThreadExecutor()
  @Volatile private var appContextRef: Context? = null
  @Volatile private var turnRefreshInFlight = false
  private val state = ConcurrentHashMap<String, Any?>(
    mapOf(
      "state" to "idle",
      "updatedAt" to 0L,
      "turnState" to "idle",
      "signalingState" to "idle",
    )
  )

  fun configure(context: Context, payload: Map<String, Any?>): Map<String, Any?> {
    appContextRef = context.applicationContext
    VibeNativeCallStore.setNativeEngineConfig(context, payload)
    val now = System.currentTimeMillis()
    synchronized(state) {
      state["state"] = "configured"
      state["relayMode"] = payload["relayMode"] ?: payload["connectionMode"] ?: payload["iceTransportPolicy"]
      state["socketUrl"] = payload["socketUrl"] ?: payload["signalingUrl"]
      state["turnCredentialsUrl"] = payload["turnCredentialsUrl"] ?: payload["turnUrl"]
      state["userChannelTopic"] = payload["userChannelTopic"] ?: payload["topic"]
      state["configuredAt"] = now
      state["updatedAt"] = now
      state["signalingState"] = "ready"
      state["note"] = "Native call signaling configured."
      Log.d("VibeNativeCall", "Engine.configure keys=${payload.keys.sorted().joinToString(",")}")
      val result = LinkedHashMap(state)
      refreshTurnConfig(context, force = true)
      return result
    }
  }

  fun getConfig(context: Context): Map<String, Any?> =
    VibeNativeCallStore.getNativeEngineConfig(context)

  fun getStatus(): Map<String, Any?> =
    synchronized(state) { LinkedHashMap(state) }

  fun getIceConfig(context: Context): Map<String, Any?> =
    VibeNativeCallStore.getNativeIceConfig(context)

  fun getSignalingJournal(limit: Int? = null): List<Map<String, Any?>> {
    val context = appContextRef ?: return emptyList()
    return VibeNativeCallStore.getNativeSignalingEvents(context, limit)
  }

  fun clearSignalingJournal(): Map<String, Any?> {
    appContextRef?.let { VibeNativeCallStore.clearNativeSignalingEvents(it) }
    val now = System.currentTimeMillis()
    synchronized(state) {
      state["signalingEventCount"] = 0
      state["signalingInboundCount"] = 0
      state["signalingOutboundCount"] = 0
      state["signalingLastEvent"] = null
      state["signalingLastDirection"] = null
      state["signalingLastTopic"] = null
      state["signalingLastError"] = null
      state["signalingLastAt"] = now
      state["updatedAt"] = now
      return LinkedHashMap(state)
    }
  }

  fun refreshTurnConfig(context: Context, force: Boolean = false): Map<String, Any?> {
    val config = VibeNativeCallStore.getNativeEngineConfig(context)
    val urlString = normalizedString(config["turnCredentialsUrl"] ?: config["turnUrl"])
    val now = System.currentTimeMillis()
    if (urlString == null) {
      synchronized(state) {
        state["turnState"] = "missing-url"
        state["turnLastError"] = "Missing turnCredentialsUrl"
        state["updatedAt"] = now
        return LinkedHashMap(state)
      }
    }

    if (!force) {
      val cached = VibeNativeCallStore.getNativeIceConfig(context)
      val expiresAt = longValue(cached["expiresAt"])
      if (expiresAt != null && expiresAt > now + 5_000) {
        synchronized(state) {
          state["turnState"] = "ready"
          state["turnIceServerCount"] = ((cached["iceServers"] as? List<*>)?.size ?: 0)
          state["turnIceTransportPolicy"] = cached["iceTransportPolicy"]
          state["turnServerIceTransportPolicy"] = cached["serverIceTransportPolicy"]
          state["turnExpiresAt"] = cached["expiresAt"]
          state["turnLastFetchAt"] = cached["fetchedAt"]
          state["turnLastError"] = null
          state["updatedAt"] = now
          return LinkedHashMap(state)
        }
      }
    }

    synchronized(state) {
      if (turnRefreshInFlight) return LinkedHashMap(state)
      turnRefreshInFlight = true
      state["turnState"] = "fetching"
      state["turnLastError"] = null
      state["updatedAt"] = now
    }

    val shouldForceRelay = forceRelayEnabled(config)
    executor.execute {
      var conn: HttpURLConnection? = null
      try {
        conn = (URL(urlString).openConnection() as HttpURLConnection).apply {
          requestMethod = "GET"
          connectTimeout = 12_000
          readTimeout = 12_000
          setRequestProperty("Accept", "application/json")
        }
        val statusCode = conn.responseCode
        val body = (if (statusCode in 200..299) conn.inputStream else conn.errorStream)
          ?.bufferedReader()
          ?.use { it.readText() }
          .orEmpty()

        if (statusCode !in 200..299) {
          finishTurnRefreshError("http:$statusCode")
          return@execute
        }

        val decoded = JSONObject(body)
        val iceServersArray = decoded.optJSONArray("iceServers") ?: JSONArray()
        val ttl = maxOf(decoded.optInt("ttl", 3600), 30)
        val serverPolicy = normalizeTransportPolicy(decoded.optString("iceTransportPolicy", "all"))
        val effectivePolicy = if (shouldForceRelay) "relay" else serverPolicy
        val fetchedAt = System.currentTimeMillis()
        val expiresAt = fetchedAt + (ttl.toLong() * 1000L)

        val iceConfig = linkedMapOf<String, Any?>(
          "iceServers" to jsonArrayToList(iceServersArray),
          "ttl" to ttl,
          "fetchedAt" to fetchedAt,
          "expiresAt" to expiresAt,
          "serverIceTransportPolicy" to serverPolicy,
          "iceTransportPolicy" to effectivePolicy,
          "forceRelay" to shouldForceRelay,
        )
        VibeNativeCallStore.setNativeIceConfig(context, iceConfig)

        synchronized(state) {
          turnRefreshInFlight = false
          state["turnState"] = "ready"
          state["turnIceServerCount"] = iceServersArray.length()
          state["turnIceTransportPolicy"] = effectivePolicy
          state["turnServerIceTransportPolicy"] = serverPolicy
          state["turnExpiresAt"] = expiresAt
          state["turnLastFetchAt"] = fetchedAt
          state["turnLastError"] = null
          state["updatedAt"] = fetchedAt
          state["note"] = "Native call signaling configured; TURN config ready."
        }
        Log.d("VibeNativeCall", "Engine.turnFetch ok servers=${iceServersArray.length()} policy=$effectivePolicy forceRelay=$shouldForceRelay")
      } catch (t: Throwable) {
        finishTurnRefreshError("network:${t.message ?: "unknown"}")
      } finally {
        conn?.disconnect()
      }
    }

    return getStatus()
  }

  fun startOutgoing(payload: Map<String, Any?>): Map<String, Any?> =
    run {
      val callPayload = preparedCallPayload(payload, event = "call-start", direction = "outbound").toMutableMap()
      val signal = ChatEngine.sendCallSignal(callPayload)
      callPayload["signaling"] = signal
      callPayload["signalingAccepted"] = signal["accepted"] ?: false
      callPayload["signalingQueued"] = signal["queued"] ?: false
      callPayload["signalingRef"] = signal["ref"]
      recordSignalingEvent(callPayload, defaultEvent = "call-start", defaultDirection = "outbound")
      transition("starting", callPayload, "outgoing", signalingNote(signal, "Outgoing call routed through native signaling."))
    }

  fun acceptIncoming(payload: Map<String, Any?>): Map<String, Any?> =
    run {
      val callPayload = preparedCallPayload(payload, event = "call-accepted", direction = "outbound").toMutableMap()
      if (normalizedString(callPayload["toUserId"]) == null) {
        normalizedString(callPayload["fromUserId"] ?: callPayload["from_user_id"])?.let { callPayload["toUserId"] = it }
      }
      val signal = ChatEngine.sendCallSignal(callPayload)
      callPayload["signaling"] = signal
      callPayload["signalingAccepted"] = signal["accepted"] ?: false
      callPayload["signalingQueued"] = signal["queued"] ?: false
      callPayload["signalingRef"] = signal["ref"]
      recordSignalingEvent(callPayload, defaultEvent = "call-accepted", defaultDirection = "outbound")
      transition("accepting", callPayload, "incoming", signalingNote(signal, "Incoming call accepted through native signaling."))
    }

  fun handleSignal(payload: Map<String, Any?>): Map<String, Any?> =
    run {
      val typeAsEvent = normalizedString(payload["type"]).takeIf { it in setOf("call-start", "call-accepted", "call-end") }
      val event = normalizedString(payload["event"]) ?: typeAsEvent ?: "webrtc-signal"
      val callPayload = preparedCallPayload(payload, event = event, direction = "inbound").toMutableMap()
      recordSignalingEvent(callPayload, defaultEvent = event, defaultDirection = "inbound")
      when (event) {
        "call-start" -> {
          appContextRef?.let { VibeNativeCallStore.enqueueIncomingCall(it, stringPayload(callPayload)) }
          transition("ringing", callPayload, "incoming", "Incoming call routed through native signaling.")
        }
        "call-accepted" ->
          transition("connecting", callPayload, "outgoing", "Call accepted through native signaling.")
        "call-end" -> {
          callPayload["remote"] = true
          endCall(callPayload)
        }
        else ->
          synchronized(state) {
            state["updatedAt"] = System.currentTimeMillis()
            state["lastSignalType"] = payload["type"] ?: payload["signalType"]
            state["note"] = "WebRTC signal routed through native signaling."
            Log.d("VibeNativeCall", "Engine.handleSignal type=${payload["type"] ?: payload["signalType"]}")
            LinkedHashMap(state)
          }
      }
    }

  fun endCall(payload: Map<String, Any?>): Map<String, Any?> =
    run {
      val remote = boolValue(payload["remote"])
      val callPayload = preparedCallPayload(
        payload,
        event = "call-end",
        direction = if (remote) "inbound" else "outbound",
      ).toMutableMap()
      if (!remote) {
        if (normalizedString(callPayload["toUserId"]) == null) {
          remoteUserId(callPayload)?.let { callPayload["toUserId"] = it }
        }
        val signal = ChatEngine.sendCallSignal(callPayload)
        callPayload["signaling"] = signal
        callPayload["signalingAccepted"] = signal["accepted"] ?: false
        callPayload["signalingQueued"] = signal["queued"] ?: false
        callPayload["signalingRef"] = signal["ref"]
      }
      val inferredDirection = if (boolValue(callPayload["remote"])) "inbound" else "outbound"
      recordSignalingEvent(callPayload, defaultEvent = "call-end", defaultDirection = inferredDirection)
      transition("ended", callPayload, payload["direction"]?.toString(), "Call ended through native signaling.")
    }

  private fun preparedCallPayload(
    payload: Map<String, Any?>,
    event: String,
    direction: String,
  ): Map<String, Any?> {
    val now = System.currentTimeMillis()
    val next = LinkedHashMap(makeJsonSafeMap(payload))
    next["event"] = event
    next["direction"] = direction
    if (normalizedString(next["callId"] ?: next["call_id"]) == null) {
      next["callId"] = "call_${now}_${java.util.UUID.randomUUID().toString().take(8)}"
    }
    if (normalizedString(next["callType"] ?: next["call_type"]) == null) {
      next["callType"] = "voice"
    }
    normalizedString(next["call_id"])?.let {
      if (normalizedString(next["callId"]) == null) next["callId"] = it
    }
    normalizedString(next["call_type"])?.let {
      if (normalizedString(next["callType"]) == null) next["callType"] = it
    }
    return next
  }

  private fun remoteUserId(payload: Map<String, Any?>): String? =
    normalizedString(payload["toUserId"] ?: payload["to_user_id"])
      ?: normalizedString(payload["remoteUserId"] ?: payload["remote_user_id"])
      ?: normalizedString(payload["fromUserId"] ?: payload["from_user_id"])
      ?: normalizedString(payload["peerUserId"] ?: payload["peer_user_id"])

  private fun signalingNote(signal: Map<String, Any?>, fallback: String): String {
    if (!boolValue(signal["accepted"])) {
      return "Native signaling rejected: ${normalizedString(signal["reason"]) ?: "unknown"}."
    }
    if (boolValue(signal["queued"])) {
      return "Native signaling queued until the user channel joins."
    }
    return fallback
  }

  private fun boolValue(value: Any?): Boolean =
    when (value) {
      is Boolean -> value
      is Number -> value.toInt() != 0
      is String -> value.equals("true", ignoreCase = true) || value == "1" || value.equals("yes", ignoreCase = true)
      else -> false
    }

  private fun stringPayload(payload: Map<String, Any?>): Map<String, String> =
    payload.mapValues { (_, value) -> value?.toString().orEmpty() }

  private fun transition(
    nextState: String,
    payload: Map<String, Any?>,
    direction: String?,
    note: String,
  ): Map<String, Any?> {
    synchronized(state) {
      state["state"] = nextState
      state["callId"] = payload["callId"] ?: payload["call_id"]
      state["callType"] = payload["callType"] ?: payload["call_type"]
      if (direction != null) state["direction"] = direction
      state["updatedAt"] = System.currentTimeMillis()
      state["note"] = note
      Log.d("VibeNativeCall", "Engine.transition state=$nextState callId=${state["callId"]} type=${state["callType"]}")
      return LinkedHashMap(state)
    }
  }

  private fun finishTurnRefreshError(error: String) {
    synchronized(state) {
      turnRefreshInFlight = false
      val now = System.currentTimeMillis()
      state["turnState"] = "error"
      state["turnLastError"] = error
      state["turnLastFetchAt"] = now
      state["updatedAt"] = now
      Log.w("VibeNativeCall", "Engine.turnFetch error=$error")
    }
  }

  private fun recordSignalingEvent(
    payload: Map<String, Any?>,
    defaultEvent: String,
    defaultDirection: String,
  ) {
    val now = System.currentTimeMillis()
    val eventName = normalizedString(payload["event"]) ?: defaultEvent
    val direction = normalizedString(payload["direction"]) ?: defaultDirection
    val config = appContextRef?.let { VibeNativeCallStore.getNativeEngineConfig(it) } ?: emptyMap()
    val topic = normalizedString(payload["topic"]) ?: normalizedString(config["userChannelTopic"])
    val entry = linkedMapOf<String, Any?>(
      "timestamp" to now,
      "event" to eventName,
      "direction" to direction,
      "payload" to makeJsonSafeMap(payload),
    )
    if (topic != null) entry["topic"] = topic
    (payload["callId"] ?: payload["call_id"])?.let { entry["callId"] = it }
    (payload["callType"] ?: payload["call_type"])?.let { entry["callType"] = it }
    (payload["type"] ?: payload["signalType"])?.let { entry["signalType"] = it }

    val ctx = appContextRef
    if (ctx != null) {
      VibeNativeCallStore.appendNativeSignalingEvent(ctx, entry)
    }

    synchronized(state) {
      state["signalingState"] = "mirroring"
      state["signalingLastEvent"] = eventName
      state["signalingLastDirection"] = direction
      state["signalingLastTopic"] = topic
      state["signalingLastAt"] = now
      state["signalingLastError"] = if (ctx == null) "missing-context" else null
      state["signalingEventCount"] = ((state["signalingEventCount"] as? Number)?.toInt() ?: 0) + 1
      if (direction == "inbound") {
        state["signalingInboundCount"] = ((state["signalingInboundCount"] as? Number)?.toInt() ?: 0) + 1
      } else if (direction == "outbound") {
        state["signalingOutboundCount"] = ((state["signalingOutboundCount"] as? Number)?.toInt() ?: 0) + 1
      }
      state["updatedAt"] = now
    }
    Log.d("VibeNativeCall", "Engine.signaling journal dir=$direction event=$eventName")
  }

  private fun normalizedString(value: Any?): String? {
    val text = value?.toString()?.trim().orEmpty()
    return text.ifEmpty { null }
  }

  private fun longValue(value: Any?): Long? =
    when (value) {
      is Long -> value
      is Int -> value.toLong()
      is Number -> value.toLong()
      is String -> value.toLongOrNull()
      else -> null
    }

  private fun forceRelayEnabled(config: Map<String, Any?>): Boolean {
    val forceRelay = when (val raw = config["forceRelay"]) {
      is Boolean -> raw
      is Number -> raw.toInt() != 0
      is String -> raw.equals("true", ignoreCase = true) || raw == "1"
      else -> false
    }
    if (forceRelay) return true
    return normalizeTransportPolicy(config["relayMode"]?.toString()) == "relay" ||
      normalizeTransportPolicy(config["connectionMode"]?.toString()) == "relay"
  }

  private fun normalizeTransportPolicy(value: String?): String {
    val raw = value?.trim()?.lowercase().orEmpty()
    return if (raw == "relay") "relay" else "all"
  }

  private fun makeJsonSafeMap(value: Map<String, Any?>): Map<String, Any?> {
    val out = LinkedHashMap<String, Any?>()
    value.forEach { (key, raw) -> out[key] = makeJsonSafeValue(raw) }
    return out
  }

  private fun makeJsonSafeValue(value: Any?): Any? =
    when (value) {
      null -> null
      is JSONObject -> jsonObjectToMap(value)
      is JSONArray -> jsonArrayToList(value)
      is Map<*, *> -> {
        val out = LinkedHashMap<String, Any?>()
        value.forEach { (k, v) ->
          val key = k?.toString() ?: return@forEach
          out[key] = makeJsonSafeValue(v)
        }
        out
      }
      is List<*> -> value.map { makeJsonSafeValue(it) }
      is String, is Number, is Boolean -> value
      else -> value.toString()
    }

  private fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
    val out = LinkedHashMap<String, Any?>()
    val keys = obj.keys()
    while (keys.hasNext()) {
      val key = keys.next()
      val raw = obj.opt(key)
      out[key] = when (raw) {
        is JSONObject -> jsonObjectToMap(raw)
        is JSONArray -> jsonArrayToList(raw)
        JSONObject.NULL -> null
        else -> raw
      }
    }
    return out
  }

  private fun jsonArrayToList(arr: JSONArray): List<Any?> {
    val out = ArrayList<Any?>(arr.length())
    for (i in 0 until arr.length()) {
      val raw = arr.opt(i)
      out += when (raw) {
        is JSONObject -> jsonObjectToMap(raw)
        is JSONArray -> jsonArrayToList(raw)
        JSONObject.NULL -> null
        else -> raw
      }
    }
    return out
  }
}
