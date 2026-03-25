package expo.modules.vibechatnative

import android.net.Uri
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import okhttp3.OkHttpClient
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
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

private fun chatNativeHomeBuildBridgeUrl(bridgeBaseUrl: String, path: String): String? {
  val base = bridgeBaseUrl.trim().trimEnd('/')
  if (base.isBlank()) return null
  return base + "/" + path.trimStart('/')
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
  val trimmed = body.trim()
  if (trimmed.startsWith("{")) {
    val obj = JSONObject(trimmed)
    val nested =
      obj.optJSONArray("chats")
        ?: obj.optJSONArray("data")
        ?: JSONArray()
    val chats = ArrayList<Map<String, Any?>>(nested.length())
    for (index in 0 until nested.length()) {
      val value = nested.opt(index)
      if (value is JSONObject) {
        chats.add(chatNativeHomeJsonObjectToMap(value))
      }
    }
    return chats
  }
  val array = JSONArray(trimmed)
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
    private const val fallbackApiBaseURL = "https://api.vibegram.io"
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
      val transportMode =
        chatNativeHomeNormalized(payload["transportMode"])
          ?: (ChatEngine.getTransportStatus()["transportMode"] as? String)
          ?: "direct"
      val bridgeBaseUrl =
        chatNativeHomeNormalized(payload["bridgeBaseUrl"])
          ?: (ChatEngine.getTransportStatus()["bridgeBaseUrl"] as? String)
      val authToken = chatNativeHomeNormalized(payload["authToken"])

      val url = chatNativeHomeBuildChatsUrl(apiBaseUrl, userId)
        ?: throw IllegalArgumentException("Invalid apiBaseUrl")

      val requestBuilder = Request.Builder()
        .header("Accept", "application/json")
        .header("ngrok-skip-browser-warning", "true")
      if (transportMode == "bridge_text") {
        val bridgeUrl = chatNativeHomeBuildBridgeUrl(
          bridgeBaseUrl ?: throw IllegalArgumentException("Invalid bridgeBaseUrl"),
          "/bridge/v1/home/snapshot",
        ) ?: throw IllegalArgumentException("Invalid bridgeBaseUrl")
        requestBuilder
          .url(bridgeUrl)
          .post(
            JSONObject(mapOf("userId" to userId)).toString().toRequestBody(
              "application/json".toMediaTypeOrNull(),
            ),
          )
          .header("Content-Type", "application/json")
      } else {
        requestBuilder.url(url).get()
      }
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
