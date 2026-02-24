package expo.modules.vibechatnative

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

internal object ChatEngineStore {
  private const val PREFS = "vibe_chat_engine"
  private const val KEY_CONFIG = "config_v1"
  private const val KEY_JOURNAL = "journal_v1"
  private const val MAX_JOURNAL = 300

  private fun prefs(context: Context) =
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  fun setConfig(context: Context, payload: Map<String, Any?>) {
    // Migrate sensitive values (private keys, auth tokens) to EncryptedSharedPreferences,
    // replacing them with sentinels in the plaintext config blob.
    val sanitized = SecureKeyStore.migrateAndSanitize(context, payload)
    prefs(context).edit().putString(KEY_CONFIG, JSONObject(sanitized).toString()).apply()
  }

  fun getConfig(context: Context): Map<String, Any?> {
    val raw = prefs(context).getString(KEY_CONFIG, null) ?: return emptyMap()
    return try {
      val config = jsonObjectToMap(JSONObject(raw))
      // Reassemble: replace sentinels with actual secrets from encrypted storage.
      SecureKeyStore.reassemble(context, config)
    } catch (_: Throwable) {
      emptyMap()
    }
  }

  fun appendJournal(context: Context, entry: Map<String, Any?>) {
    val current = getJournal(context).toMutableList()
    current.add(entry)
    val trimmed = if (current.size > MAX_JOURNAL) current.takeLast(MAX_JOURNAL) else current
    val array = JSONArray()
    trimmed.forEach { array.put(JSONObject(it)) }
    prefs(context).edit().putString(KEY_JOURNAL, array.toString()).apply()
  }

  fun getJournal(context: Context, limit: Int? = null): List<Map<String, Any?>> {
    val raw = prefs(context).getString(KEY_JOURNAL, null) ?: return emptyList()
    return try {
      val array = JSONArray(raw)
      val out = ArrayList<Map<String, Any?>>(array.length())
      for (i in 0 until array.length()) {
        out.add(jsonObjectToMap(array.optJSONObject(i) ?: JSONObject()))
      }
      if (limit != null && limit > 0 && out.size > limit) out.takeLast(limit) else out
    } catch (_: Throwable) {
      emptyList()
    }
  }

  fun clearJournal(context: Context) {
    prefs(context).edit().remove(KEY_JOURNAL).apply()
  }

  private fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    val keys = obj.keys()
    while (keys.hasNext()) {
      val key = keys.next()
      out[key] = jsonToAny(obj.opt(key))
    }
    return out
  }

  private fun jsonArrayToList(arr: JSONArray): List<Any?> {
    val out = ArrayList<Any?>(arr.length())
    for (i in 0 until arr.length()) {
      out.add(jsonToAny(arr.opt(i)))
    }
    return out
  }

  private fun jsonToAny(value: Any?): Any? =
    when (value) {
      null, JSONObject.NULL -> null
      is JSONObject -> jsonObjectToMap(value)
      is JSONArray -> jsonArrayToList(value)
      else -> value
    }
}

