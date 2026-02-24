package expo.modules.vibechatnative.notifications

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

private const val VIBE_CALL_STORE_PREFS = "vibe_native_call_store"
private const val KEY_PENDING_EVENTS = "pending_events"
private const val KEY_FCM_TOKEN = "fcm_token"
private const val KEY_NATIVE_ENGINE_CONFIG = "native_engine_config"
private const val KEY_NATIVE_ICE_CONFIG = "native_ice_config"
private const val KEY_NATIVE_SIGNALING_EVENTS = "native_signaling_events"
private const val MAX_NATIVE_SIGNALING_EVENTS = 240

internal object VibeNativeCallStore {
  private fun prefs(context: Context) =
    context.applicationContext.getSharedPreferences(VIBE_CALL_STORE_PREFS, Context.MODE_PRIVATE)

  fun setFcmToken(context: Context, token: String?) {
    prefs(context).edit().putString(KEY_FCM_TOKEN, token?.trim().orEmpty()).apply()
  }

  fun getFcmToken(context: Context): String? {
    val value = prefs(context).getString(KEY_FCM_TOKEN, null)?.trim().orEmpty()
    return value.ifEmpty { null }
  }

  fun enqueueEvent(
    context: Context,
    eventType: String,
    payload: Map<String, String>,
  ) {
    try {
      val now = System.currentTimeMillis()
      val event = JSONObject().apply {
        put("type", eventType)
        put("timestamp", now)
        put("payload", JSONObject(payload))
      }
      val current = prefs(context).getString(KEY_PENDING_EVENTS, null)
      val array = if (current.isNullOrBlank()) JSONArray() else JSONArray(current)
      array.put(event)
      prefs(context).edit().putString(KEY_PENDING_EVENTS, array.toString()).apply()
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "enqueueEvent failed type=$eventType ${t.message}", t)
    }
  }

  fun setNativeEngineConfig(context: Context, payload: Map<String, Any?>) {
    try {
      val json = JSONObject()
      payload.forEach { (key, value) -> json.put(key, value) }
      prefs(context).edit().putString(KEY_NATIVE_ENGINE_CONFIG, json.toString()).apply()
      Log.d("VibeCallStore", "setNativeEngineConfig keys=${payload.keys.sorted().joinToString(",")}")
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "setNativeEngineConfig failed ${t.message}", t)
    }
  }

  fun getNativeEngineConfig(context: Context): Map<String, Any?> {
    val raw = prefs(context).getString(KEY_NATIVE_ENGINE_CONFIG, null)
    if (raw.isNullOrBlank()) return emptyMap()
    return try {
      jsonObjectToMap(JSONObject(raw))
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "getNativeEngineConfig failed ${t.message}", t)
      emptyMap()
    }
  }

  fun setNativeIceConfig(context: Context, payload: Map<String, Any?>) {
    try {
      val json = JSONObject()
      payload.forEach { (key, value) -> json.put(key, value) }
      prefs(context).edit().putString(KEY_NATIVE_ICE_CONFIG, json.toString()).apply()
      Log.d("VibeCallStore", "setNativeIceConfig keys=${payload.keys.sorted().joinToString(",")}")
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "setNativeIceConfig failed ${t.message}", t)
    }
  }

  fun getNativeIceConfig(context: Context): Map<String, Any?> {
    val raw = prefs(context).getString(KEY_NATIVE_ICE_CONFIG, null)
    if (raw.isNullOrBlank()) return emptyMap()
    return try {
      jsonObjectToMap(JSONObject(raw))
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "getNativeIceConfig failed ${t.message}", t)
      emptyMap()
    }
  }

  fun appendNativeSignalingEvent(context: Context, payload: Map<String, Any?>) {
    try {
      val current = prefs(context).getString(KEY_NATIVE_SIGNALING_EVENTS, null)
      val array = if (current.isNullOrBlank()) JSONArray() else JSONArray(current)
      val item = JSONObject()
      payload.forEach { (key, value) -> item.put(key, value) }
      array.put(item)
      val out = if (array.length() > MAX_NATIVE_SIGNALING_EVENTS) {
        val trimmed = JSONArray()
        val start = array.length() - MAX_NATIVE_SIGNALING_EVENTS
        for (i in start until array.length()) trimmed.put(array.opt(i))
        trimmed
      } else {
        array
      }
      prefs(context).edit().putString(KEY_NATIVE_SIGNALING_EVENTS, out.toString()).apply()
      Log.d(
        "VibeCallStore",
        "appendNativeSignalingEvent dir=${payload["direction"] ?: "-"} event=${payload["event"] ?: "-"} count=${out.length()}"
      )
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "appendNativeSignalingEvent failed ${t.message}", t)
    }
  }

  fun getNativeSignalingEvents(context: Context, limit: Int? = null): List<Map<String, Any?>> {
    val raw = prefs(context).getString(KEY_NATIVE_SIGNALING_EVENTS, null)
    if (raw.isNullOrBlank()) return emptyList()
    return try {
      val array = JSONArray(raw)
      val results = ArrayList<Map<String, Any?>>(array.length())
      for (index in 0 until array.length()) {
        val item = array.optJSONObject(index) ?: continue
        results.add(jsonObjectToMap(item))
      }
      if (limit != null && limit > 0 && results.size > limit) {
        results.takeLast(limit)
      } else {
        results
      }
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "getNativeSignalingEvents failed ${t.message}", t)
      emptyList()
    }
  }

  fun clearNativeSignalingEvents(context: Context) {
    prefs(context).edit().remove(KEY_NATIVE_SIGNALING_EVENTS).apply()
    Log.d("VibeCallStore", "clearNativeSignalingEvents")
  }

  fun enqueueIncomingCall(context: Context, payload: Map<String, String>) {
    enqueueEvent(context, "incomingCall", payload)
  }

  fun enqueueAction(
    context: Context,
    action: String,
    payload: Map<String, String>,
  ) {
    enqueueEvent(
      context,
      "callAction",
      payload + mapOf("action" to action),
    )
  }

  fun drainEvents(context: Context): List<Map<String, Any?>> {
    val raw = prefs(context).getString(KEY_PENDING_EVENTS, null)
    if (raw.isNullOrBlank()) return emptyList()
    return try {
      val array = JSONArray(raw)
      val results = ArrayList<Map<String, Any?>>(array.length())
      for (index in 0 until array.length()) {
        val item = array.optJSONObject(index) ?: continue
        results.add(jsonObjectToMap(item))
      }
      prefs(context).edit().remove(KEY_PENDING_EVENTS).apply()
      results
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "drainEvents failed ${t.message}", t)
      emptyList()
    }
  }

  private fun jsonObjectToMap(value: JSONObject): Map<String, Any?> {
    val map = LinkedHashMap<String, Any?>()
    val keys = value.keys()
    while (keys.hasNext()) {
      val key = keys.next()
      val raw = value.opt(key)
      map[key] =
        when (raw) {
          is JSONObject -> jsonObjectToMap(raw)
          is JSONArray -> jsonArrayToList(raw)
          JSONObject.NULL -> null
          else -> raw
        }
    }
    return map
  }

  private fun jsonArrayToList(value: JSONArray): List<Any?> {
    val list = ArrayList<Any?>(value.length())
    for (index in 0 until value.length()) {
      val raw = value.opt(index)
      list.add(
        when (raw) {
          is JSONObject -> jsonObjectToMap(raw)
          is JSONArray -> jsonArrayToList(raw)
          JSONObject.NULL -> null
          else -> raw
        }
      )
    }
    return list
  }
}
