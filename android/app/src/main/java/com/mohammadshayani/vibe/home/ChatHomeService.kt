package com.mohammadshayani.vibe.home

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.mohammadshayani.vibe.session.AppSessionConfig
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

object ChatHomeService {
  private val httpClient by lazy {
    OkHttpClient.Builder()
      .connectTimeout(15, TimeUnit.SECONDS)
      .readTimeout(20, TimeUnit.SECONDS)
      .writeTimeout(20, TimeUnit.SECONDS)
      .callTimeout(22, TimeUnit.SECONDS)
      .build()
  }
  private val mainHandler = Handler(Looper.getMainLooper())

  internal fun fetchChats(context: Context, callback: (Result<List<ChatHomeListRow>>) -> Unit) {
    val config = AppSessionConfig.current(context)
    if (config == null) {
      callback(Result.failure(IllegalStateException("Missing native auth config.")))
      return
    }

    Thread {
      val result = runCatching {
        val request = buildRequest(config)
        httpClient.newCall(request).execute().use { response ->
          if (!response.isSuccessful) {
            throw IOException(
              "Request failed with status ${response.code}: ${response.body?.string().orEmpty().take(160)}"
            )
          }
          val body = response.body?.string().orEmpty()
          parseChatHomeRows(parsePayload(body), context)
        }
      }
      mainHandler.post { callback(result) }
    }.start()
  }

  private fun buildRequest(config: AppSessionConfig): Request {
    val base = config.apiBaseUrl.trim().trimEnd('/')
    val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
    val url = "$pathBase/chats/${config.userId}"
    return Request.Builder()
      .url(url)
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
      .header("Authorization", "Bearer ${config.authToken}")
      .build()
  }

  private fun parsePayload(body: String): List<Map<String, Any?>> {
    val trimmed = body.trim()
    if (trimmed.startsWith("{")) {
      val obj = JSONObject(trimmed)
      val nested = obj.optJSONArray("chats") ?: obj.optJSONArray("data") ?: JSONArray()
      return parseArray(nested)
    }
    return parseArray(JSONArray(trimmed))
  }

  private fun parseArray(array: JSONArray): List<Map<String, Any?>> {
    val items = ArrayList<Map<String, Any?>>(array.length())
    for (index in 0 until array.length()) {
      val item = array.opt(index)
      if (item is JSONObject) {
        items.add(jsonObjectToMap(item))
      }
    }
    return items
  }

  private fun jsonObjectToMap(json: JSONObject): Map<String, Any?> {
    val map = linkedMapOf<String, Any?>()
    val keys = json.keys()
    while (keys.hasNext()) {
      val key = keys.next()
      map[key] = jsonValueToAny(json.opt(key))
    }
    return map
  }

  private fun jsonArrayToList(json: JSONArray): List<Any?> {
    val list = ArrayList<Any?>(json.length())
    for (index in 0 until json.length()) {
      list.add(jsonValueToAny(json.opt(index)))
    }
    return list
  }

  private fun jsonValueToAny(value: Any?): Any? {
    return when (value) {
      null, JSONObject.NULL -> null
      is JSONObject -> jsonObjectToMap(value)
      is JSONArray -> jsonArrayToList(value)
      else -> value
    }
  }
}
