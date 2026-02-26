package expo.modules.vibechatnative

import android.net.Uri
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

private fun chatNativeHomeNormalized(value: Any?): String? {
  val text = value?.toString()?.trim() ?: return null
  return text.takeIf { it.isNotEmpty() }
}

private fun chatNativeHomeBuildChatsUrl(apiBaseUrl: String, userId: String): String? {
  var base = apiBaseUrl.trim()
  while (base.endsWith("/")) {
    base = base.dropLast(1)
  }
  if (base.isEmpty()) return null
  val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
  return "$pathBase/chats/${Uri.encode(userId)}"
}

private fun chatNativeHomeJsonValue(value: Any?): Any? =
  when (value) {
    JSONObject.NULL -> null
    is JSONObject -> chatNativeHomeJsonObjectToMap(value)
    is JSONArray -> chatNativeHomeJsonArrayToList(value)
    else -> value
  }

private fun chatNativeHomeJsonObjectToMap(json: JSONObject): Map<String, Any?> {
  val map = linkedMapOf<String, Any?>()
  val keys = json.keys()
  while (keys.hasNext()) {
    val key = keys.next()
    map[key] = chatNativeHomeJsonValue(json.opt(key))
  }
  return map
}

private fun chatNativeHomeJsonArrayToList(json: JSONArray): List<Any?> {
  val list = ArrayList<Any?>(json.length())
  for (index in 0 until json.length()) {
    list.add(chatNativeHomeJsonValue(json.opt(index)))
  }
  return list
}

private fun chatNativeHomeParseChats(body: String): List<Map<String, Any?>> {
  val array = JSONArray(body)
  val chats = ArrayList<Map<String, Any?>>(array.length())
  for (index in 0 until array.length()) {
    val value = array.opt(index)
    if (value is JSONObject) {
      chats.add(chatNativeHomeJsonObjectToMap(value))
    }
  }
  return chats
}

class ChatNativeHomeModule : Module() {
  companion object {
    private const val fallbackApiBaseURL = "https://modest-recreation-production-8329.up.railway.app"
    private val httpClient by lazy {
      OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(25, TimeUnit.SECONDS)
        .writeTimeout(25, TimeUnit.SECONDS)
        .callTimeout(27, TimeUnit.SECONDS)
        .build()
    }
  }

  override fun definition() = ModuleDefinition {
    Name("ChatNativeHome")

    Function("isSupported") {
      true
    }

    Function("supportsNativeHome") {
      true
    }

    AsyncFunction("fetchChats") { payload: Map<String, Any?> ->
      val userId = chatNativeHomeNormalized(payload["userId"])
        ?: throw IllegalArgumentException("userId is required")
      val apiBaseUrl = chatNativeHomeNormalized(payload["apiBaseUrl"]) ?: fallbackApiBaseURL
      val authToken = chatNativeHomeNormalized(payload["authToken"])

      val url = chatNativeHomeBuildChatsUrl(apiBaseUrl, userId)
        ?: throw IllegalArgumentException("Invalid apiBaseUrl")

      val requestBuilder = Request.Builder()
        .url(url)
        .get()
        .header("Accept", "application/json")
        .header("ngrok-skip-browser-warning", "true")
      if (!authToken.isNullOrEmpty()) {
        requestBuilder.header("Authorization", "Bearer $authToken")
      }

      val request = requestBuilder.build()
      httpClient.newCall(request).execute().use { response ->
        if (!response.isSuccessful) {
          val body = response.body?.string().orEmpty()
          throw IllegalStateException(
            "Home fetch failed with status ${response.code}: ${body.take(120)}",
          )
        }
        val bodyString = response.body?.string() ?: "[]"
        val chats = chatNativeHomeParseChats(bodyString)
        mapOf("chats" to chats)
      }
    }
  }
}
