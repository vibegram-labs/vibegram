package com.mohammadshayani.vibe.chat

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.mohammadshayani.vibe.home.ChatHomeListRow
import com.mohammadshayani.vibe.home.parseChatHomeRows
import com.mohammadshayani.vibe.packet.PacketBootstrapService
import com.mohammadshayani.vibe.packet.PacketRuntime
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.session.AppSessionConfig
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit

object ChatEngineApi {
  private const val CACHE_PREFS = "vibe_android_chat_home_cache"
  private const val CACHE_CHATS = "chats_payload_v1"

  private val httpClient by lazy {
    OkHttpClient.Builder()
      .connectTimeout(15, TimeUnit.SECONDS)
      .readTimeout(20, TimeUnit.SECONDS)
      .writeTimeout(20, TimeUnit.SECONDS)
      .callTimeout(22, TimeUnit.SECONDS)
      .build()
  }
  private val mainHandler = Handler(Looper.getMainLooper())

  internal data class PeerLookupResult(
    val userId: String,
    val displayName: String,
    val username: String?,
    val phoneNumber: String?,
    val avatarUri: String?,
    val publicKey: String?,
    val isOnline: Boolean,
  ) {
    val subtitle: String
      get() {
        if (!phoneNumber.isNullOrBlank()) return phoneNumber
        val handle = username?.trim()?.removePrefix("@").orEmpty()
        if (handle.isNotEmpty() && !looksLikeUuid(handle) && !handle.equals(displayName, ignoreCase = true)) {
          return "@$handle"
        }
        return "User is in Vibegram"
      }
  }

  internal fun fetchChats(context: Context, callback: (Result<List<ChatHomeListRow>>) -> Unit) {
    val config = AppSessionConfig.current(context)
    if (config == null) {
      callback(Result.failure(IllegalStateException("Missing native auth config.")))
      return
    }

    Thread {
      val result = runCatching {
        val request = buildRequest(config)
        when (config.transportMode) {
          PacketTransportMode.OFFLINE ->
            throw IOException("Transport mode offline is not available in the standalone native app.")
          PacketTransportMode.BRIDGE_TEXT ->
            throw IOException("Transport mode bridge_text is not available in the standalone native app.")
          PacketTransportMode.PACKET_MESH -> {
            try {
              val snapshot = PacketRuntime.ensureStarted(context, config)
              execute(PacketRuntime.buildHttpClient(snapshot), request, context)
            } catch (_: Throwable) {
              execute(httpClient, request, context)
            }
          }
          PacketTransportMode.DIRECT -> {
            try {
              val rows = execute(httpClient, request, context)
              PacketRuntime.stop(context, resetToDirect = true)
              PacketBootstrapService.prefetchIfNeeded(context, config)
              rows
            } catch (_: Throwable) {
              val snapshot = PacketRuntime.ensureStarted(context, config)
              execute(PacketRuntime.buildHttpClient(snapshot), request, context)
            }
          }
        }
      }
      val resolvedResult =
        if (result.isFailure) {
          cachedRows(context)?.let { Result.success(it) } ?: result
        } else {
          result
        }
      mainHandler.post { callback(resolvedResult) }
    }.start()
  }

  internal fun startDirectChat(
    context: Context,
    lookup: String,
    callback: (Result<ChatHomeListRow>) -> Unit,
  ) {
    findUser(context, lookup) { result ->
      result.onSuccess { peer ->
        startDirectChat(context, peer, callback)
      }.onFailure { error ->
        callback(Result.failure(error))
      }
    }
  }

  internal fun findUser(
    context: Context,
    lookup: String,
    callback: (Result<PeerLookupResult>) -> Unit,
  ) {
    val config = AppSessionConfig.current(context)
    if (config == null) {
      callback(Result.failure(IllegalStateException("Missing native auth config.")))
      return
    }
    val normalizedLookup = lookup.trim().removePrefix("@")
    if (normalizedLookup.isBlank()) {
      callback(Result.failure(IllegalArgumentException("Enter a username, phone, or user id.")))
      return
    }

    Thread {
      val result = runCatching {
        val executor: (OkHttpClient) -> PeerLookupResult = { client ->
          resolvePeer(client, config, normalizedLookup)
        }
        when (config.transportMode) {
          PacketTransportMode.OFFLINE ->
            throw IOException("Transport mode offline is not available in the standalone native app.")
          PacketTransportMode.BRIDGE_TEXT ->
            throw IOException("Transport mode bridge_text is not available in the standalone native app.")
          PacketTransportMode.PACKET_MESH -> {
            try {
              val snapshot = PacketRuntime.ensureStarted(context, config)
              executor(PacketRuntime.buildHttpClient(snapshot))
            } catch (_: Throwable) {
              executor(httpClient)
            }
          }
          PacketTransportMode.DIRECT -> {
            try {
              val row = executor(httpClient)
              PacketRuntime.stop(context, resetToDirect = true)
              PacketBootstrapService.prefetchIfNeeded(context, config)
              row
            } catch (_: Throwable) {
              val snapshot = PacketRuntime.ensureStarted(context, config)
              executor(PacketRuntime.buildHttpClient(snapshot))
            }
          }
        }
      }
      mainHandler.post { callback(result) }
    }.start()
  }

  internal fun startDirectChat(
    context: Context,
    peer: PeerLookupResult,
    callback: (Result<ChatHomeListRow>) -> Unit,
  ) {
    val config = AppSessionConfig.current(context)
    if (config == null) {
      callback(Result.failure(IllegalStateException("Missing native auth config.")))
      return
    }

    Thread {
      val result = runCatching {
        val executor: (OkHttpClient) -> ChatHomeListRow = { client ->
          val chatId = createDirectChat(client, config, peer.userId)
          ChatEngine.seedChatPeerInfo(
            mapOf(
              "chatId" to chatId,
              "peerUserId" to peer.userId,
              "publicKey" to peer.publicKey,
            ),
          )
          ChatHomeListRow(
            chatId = chatId,
            title = peer.displayName,
            preview = "Start a conversation",
            timeLabel = "",
            unreadCount = 0,
            markedUnread = false,
            muted = false,
            pinned = false,
            isTyping = false,
            isOnline = peer.isOnline,
            peerUserId = peer.userId,
            avatarUri = peer.avatarUri,
            avatarFallback = peer.displayName.take(1).uppercase().ifBlank { "?" },
            avatarGradientStartLight = null,
            avatarGradientEndLight = null,
            avatarGradientStartDark = null,
            avatarGradientEndDark = null,
            isSavedMessages = false,
          )
        }
        when (config.transportMode) {
          PacketTransportMode.OFFLINE ->
            throw IOException("Transport mode offline is not available in the standalone native app.")
          PacketTransportMode.BRIDGE_TEXT ->
            throw IOException("Transport mode bridge_text is not available in the standalone native app.")
          PacketTransportMode.PACKET_MESH -> {
            try {
              val snapshot = PacketRuntime.ensureStarted(context, config)
              executor(PacketRuntime.buildHttpClient(snapshot))
            } catch (_: Throwable) {
              executor(httpClient)
            }
          }
          PacketTransportMode.DIRECT -> {
            try {
              val row = executor(httpClient)
              PacketRuntime.stop(context, resetToDirect = true)
              PacketBootstrapService.prefetchIfNeeded(context, config)
              row
            } catch (_: Throwable) {
              val snapshot = PacketRuntime.ensureStarted(context, config)
              executor(PacketRuntime.buildHttpClient(snapshot))
            }
          }
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

  private fun resolvePeer(
    client: OkHttpClient,
    config: AppSessionConfig,
    lookup: String,
  ): PeerLookupResult {
    val candidates = lookupCandidates(config, lookup)
    var lastFailure: IOException? = null
    for (request in candidates) {
      try {
        client.newCall(request).execute().use { response ->
          val body = response.body?.string().orEmpty()
          if (!response.isSuccessful) {
            lastFailure = IOException("User lookup failed with status ${response.code}: ${body.take(160)}")
            return@use
          }
          val json = JSONObject(body)
          val source = json.optJSONObject("data") ?: json
          val userId = firstNonBlank(
            source.opt("userId"),
            source.opt("user_id"),
            source.opt("id"),
          )
          if (userId.isNullOrBlank()) {
            lastFailure = IOException("User lookup returned no user id.")
            return@use
          }
          val username = firstNonBlank(source.opt("username"), source.opt("handle"))
          val title = firstNonBlank(
            source.opt("displayName"),
            source.opt("display_name"),
            source.opt("fullName"),
            source.opt("full_name"),
            source.opt("name"),
            username,
          )?.takeUnless { looksLikeUuid(it) }
            ?: username?.takeUnless { looksLikeUuid(it) }
            ?: "Vibegram User"
          return PeerLookupResult(
            userId = userId,
            displayName = title,
            username = username,
            phoneNumber = firstNonBlank(source.opt("phoneNumber"), source.opt("phone_number"), source.opt("phone")),
            avatarUri = firstNonBlank(source.opt("profileImage"), source.opt("profile_image"), source.opt("avatarUrl"), source.opt("avatar_url")),
            publicKey = firstNonBlank(source.opt("publicKey"), source.opt("public_key"), source.opt("friendKey"), source.opt("friendPublicKey")),
            isOnline = parseBool(source.opt("online") ?: source.opt("isOnline") ?: source.opt("is_online")) ?: false,
          )
        }
      } catch (error: IOException) {
        lastFailure = error
      }
    }
    throw lastFailure ?: IOException("User not found.")
  }

  private fun createDirectChat(
    client: OkHttpClient,
    config: AppSessionConfig,
    peerUserId: String,
  ): String {
    val base = config.apiBaseUrl.trim().trimEnd('/')
    val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
    val body =
      JSONObject()
        .put("myId", config.userId)
        .put("friendId", peerUserId)
        .toString()
        .toRequestBody("application/json; charset=utf-8".toMediaType())
    val request =
      Request.Builder()
        .url("$pathBase/chat")
        .post(body)
        .header("Accept", "application/json")
        .header("ngrok-skip-browser-warning", "true")
        .header("Authorization", "Bearer ${config.authToken}")
        .build()
    client.newCall(request).execute().use { response ->
      val payload = response.body?.string().orEmpty()
      if (!response.isSuccessful) {
        throw IOException("Chat create failed with status ${response.code}: ${payload.take(160)}")
      }
      val chatId = JSONObject(payload).optString("chatId").trim()
      if (chatId.isBlank()) throw IOException("Chat create returned no chat id.")
      return chatId
    }
  }

  private fun lookupCandidates(
    config: AppSessionConfig,
    lookup: String,
  ): List<Request> {
    val base = config.apiBaseUrl.trim().trimEnd('/')
    val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
    val encoded = URLEncoder.encode(lookup, StandardCharsets.UTF_8.name())
    val paths =
      when {
        lookup.startsWith("+") || lookup.any { it.isDigit() } && lookup.none { it.isLetter() } ->
          listOf("user/phone/$encoded", "user/$encoded")
        else ->
          listOf("user/name/$encoded", "user/$encoded")
      }
    return paths.map { path ->
      Request.Builder()
        .url("$pathBase/$path")
        .get()
        .header("Accept", "application/json")
        .header("ngrok-skip-browser-warning", "true")
        .header("Authorization", "Bearer ${config.authToken}")
        .build()
    }
  }

  private fun execute(
    client: OkHttpClient,
    request: Request,
    context: Context,
  ): List<ChatHomeListRow> {
    client.newCall(request).execute().use { response ->
      if (!response.isSuccessful) {
        throw IOException(
          "Request failed with status ${response.code}: ${response.body?.string().orEmpty().take(160)}"
        )
      }
      val body = response.body?.string().orEmpty()
      cachePayload(context, body)
      return parseChatHomeRows(parsePayload(body), context)
    }
  }

  private fun cachePayload(context: Context, body: String) {
    if (body.isBlank()) return
    context.getSharedPreferences(CACHE_PREFS, Context.MODE_PRIVATE)
      .edit()
      .putString(CACHE_CHATS, body)
      .apply()
  }

  internal fun cachedRows(context: Context): List<ChatHomeListRow>? {
    val body =
      context.getSharedPreferences(CACHE_PREFS, Context.MODE_PRIVATE)
        .getString(CACHE_CHATS, null)
        ?: return null
    return runCatching { parseChatHomeRows(parsePayload(body), context) }
      .getOrNull()
      ?.takeIf { it.isNotEmpty() }
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

  private fun firstNonBlank(vararg values: Any?): String? {
    return values.firstNotNullOfOrNull { value ->
      when (value) {
        null, JSONObject.NULL -> null
        is String -> value.trim().takeIf { it.isNotEmpty() }
        else -> value.toString().trim().takeIf { it.isNotEmpty() }
      }
    }
  }

  private fun parseBool(value: Any?): Boolean? {
    return when (value) {
      is Boolean -> value
      is Number -> value.toInt() != 0
      is String -> when (value.trim().lowercase()) {
        "1", "true", "yes", "on" -> true
        "0", "false", "no", "off" -> false
        else -> null
      }
      else -> null
    }
  }

  private fun looksLikeUuid(value: String): Boolean {
    val trimmed = value.trim()
    if (trimmed.length != 36) return false
    return runCatching { java.util.UUID.fromString(trimmed) }.isSuccess
  }
}
