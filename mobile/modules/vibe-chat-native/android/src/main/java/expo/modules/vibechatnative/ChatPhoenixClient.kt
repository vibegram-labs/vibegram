package expo.modules.vibechatnative

import android.os.Handler
import android.os.Looper
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong

internal class ChatPhoenixClient(
  private val socketUrl: String,
  private val params: Map<String, String>,
  private val callbacks: Callbacks,
) {
  interface Callbacks {
    fun onOpen()
    fun onClosed(code: Int, reason: String?)
    fun onError(error: String)
    fun onEvent(
      topic: String,
      event: String,
      payload: Map<String, Any?>,
      ref: String?,
      joinRef: String?,
    )
  }

  private val okHttp = OkHttpClient()
  private val refCounter = AtomicLong(1L)
  private val mainHandler = Handler(Looper.getMainLooper())
  @Volatile private var webSocket: WebSocket? = null
  @Volatile private var isClosing = false
  private var heartbeatRunnable: Runnable? = null

  fun connect() {
    val httpUrl = buildUrl() ?: run {
      callbacks.onError("invalid_socket_url")
      return
    }
    disconnect()
    isClosing = false
    val request = Request.Builder().url(httpUrl).build()
    webSocket = okHttp.newWebSocket(
      request,
      object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
          startHeartbeat()
          callbacks.onOpen()
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
          handleMessage(text)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
          webSocket.close(code, reason)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
          stopHeartbeat()
          if (!isClosing) {
            callbacks.onClosed(code, reason)
          }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
          stopHeartbeat()
          if (!isClosing) {
            callbacks.onError("ws_failure:${t.message ?: t.javaClass.simpleName}")
            callbacks.onClosed(-1, t.message)
          }
        }
      },
    )
  }

  fun disconnect() {
    isClosing = true
    stopHeartbeat()
    webSocket?.close(1000, "client_disconnect")
    webSocket = null
  }

  fun join(topic: String, payload: Map<String, Any?> = emptyMap()): String {
    val ref = nextRef()
    sendFrame(joinRef = ref, ref = ref, topic = topic, event = "phx_join", payload = payload)
    return ref
  }

  fun leave(topic: String): String {
    val ref = nextRef()
    sendFrame(joinRef = ref, ref = ref, topic = topic, event = "phx_leave", payload = emptyMap())
    return ref
  }

  fun push(topic: String, event: String, payload: Map<String, Any?> = emptyMap()): String {
    val ref = nextRef()
    sendFrame(joinRef = null, ref = ref, topic = topic, event = event, payload = payload)
    return ref
  }

  private fun nextRef(): String = refCounter.getAndIncrement().toString()

  private fun buildUrl() =
    socketUrl.toHttpUrlOrNull()?.newBuilder()?.apply {
      params.forEach { (key, value) ->
        if (key.isNotBlank()) {
          removeAllQueryParameters(key)
          addQueryParameter(key, value)
        }
      }
    }?.build()

  private fun startHeartbeat() {
    stopHeartbeat()
    val runnable = object : Runnable {
      override fun run() {
        if (isClosing || webSocket == null) return
        sendFrame(
          joinRef = null,
          ref = nextRef(),
          topic = "phoenix",
          event = "heartbeat",
          payload = emptyMap(),
        )
        mainHandler.postDelayed(this, 25_000L)
      }
    }
    heartbeatRunnable = runnable
    mainHandler.postDelayed(runnable, 25_000L)
  }

  private fun stopHeartbeat() {
    heartbeatRunnable?.let { mainHandler.removeCallbacks(it) }
    heartbeatRunnable = null
  }

  private fun sendFrame(
    joinRef: String?,
    ref: String?,
    topic: String,
    event: String,
    payload: Map<String, Any?>,
  ) {
    val ws = webSocket ?: return
    val array = JSONArray()
    array.put(joinRef ?: JSONObject.NULL)
    array.put(ref ?: JSONObject.NULL)
    array.put(topic)
    array.put(event)
    array.put(anyToJson(payload))
    val ok = ws.send(array.toString())
    if (!ok) {
      callbacks.onError("send_failed:$event")
    }
  }

  private fun handleMessage(text: String) {
    try {
      val arr = JSONArray(text)
      if (arr.length() < 5) return
      val topic = arr.optString(2)
      val event = arr.optString(3)
      if (topic.isBlank() || event.isBlank()) return
      val payload = (jsonToAny(arr.opt(4)) as? Map<*, *>)?.entries?.associate { (k, v) ->
        k?.toString().orEmpty() to v
      }?.filterKeys { it.isNotBlank() } ?: emptyMap()
      val joinRef = arr.optNullableString(0)
      val ref = arr.optNullableString(1)
      callbacks.onEvent(topic, event, payload, ref, joinRef)
    } catch (_: Throwable) {
      callbacks.onError("parse_frame_failed")
    }
  }

  private fun JSONArray.optNullableString(index: Int): String? {
    if (index < 0 || index >= length()) return null
    val v = opt(index)
    return when (v) {
      null, JSONObject.NULL -> null
      else -> v.toString().takeIf { it.isNotBlank() }
    }
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

  private fun anyToJson(value: Any?): Any =
    when (value) {
      null -> JSONObject.NULL
      is JSONObject, is JSONArray, is Number, is Boolean, is String -> value
      is Map<*, *> -> {
        val obj = JSONObject()
        value.forEach { (k, v) ->
          if (k != null) obj.put(k.toString(), anyToJson(v))
        }
        obj
      }
      is Iterable<*> -> {
        val arr = JSONArray()
        value.forEach { arr.put(anyToJson(it)) }
        arr
      }
      is Array<*> -> {
        val arr = JSONArray()
        value.forEach { arr.put(anyToJson(it)) }
        arr
      }
      else -> value.toString()
    }
}
