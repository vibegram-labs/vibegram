package expo.modules.vibechatnative

import android.content.Context
import android.net.Uri
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

private const val fallbackHomeApiBaseUrl = "https://modest-recreation-production-8329.up.railway.app"

internal data class ChatNativeHomeListRow(
  val chatId: String,
  val title: String,
  val preview: String,
  val timeLabel: String,
  val unreadCount: Int,
  val markedUnread: Boolean,
  val muted: Boolean,
  val pinned: Boolean,
  val isTyping: Boolean,
  val isOnline: Boolean,
  val avatarUri: String?,
  val avatarFallback: String,
  val isSavedMessages: Boolean,
)

internal fun parseChatNativeHomeRows(
  rawRows: List<Map<String, Any?>>,
  context: Context,
): List<ChatNativeHomeListRow> {
  val apiBaseUrl = resolveNativeHomeApiBaseUrl(context)
  return rawRows.mapNotNull { raw ->
    val chatId = raw["chatId"]?.toString()?.trim().orEmpty()
    if (chatId.isEmpty()) return@mapNotNull null
    val isSavedMessages = chatId == "saved_messages"

    val title =
      raw["name"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["title"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: "Unknown"
    val preview =
      raw["preview"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["subtitle"]?.toString()?.trim().orEmpty()
    val timeLabel =
      raw["timeLabel"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["time"]?.toString()?.trim().orEmpty()

    val unreadCount = parseInt(raw["unreadCount"] ?: raw["unread_count"]) ?: 0
    val markedUnread = parseBool(raw["markedUnread"] ?: raw["marked_unread"]) ?: false
    val muted = parseBool(raw["muted"]) ?: false
    val pinned = parseBool(raw["pinned"]) ?: false
    val isTyping = parseBool(raw["isTyping"] ?: raw["is_typing"]) ?: false
    val isOnline = parseBool(raw["isOnline"] ?: raw["is_online"]) ?: false
    val friendId =
      raw["friendId"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["friend_id"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
    val rawAvatar =
      raw["avatarUri"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["avatar_uri"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["friendImage"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["friend_image"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["avatarUrl"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["avatar_url"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
    val avatarUri = resolveAvatarUri(
      rawAvatar = rawAvatar,
      friendId = friendId,
      chatId = chatId,
      apiBaseUrl = apiBaseUrl,
    )
    val avatarFallback =
      raw["avatarFallback"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: title.take(1).uppercase()

    ChatNativeHomeListRow(
      chatId = chatId,
      title = title,
      preview = preview,
      timeLabel = timeLabel,
      unreadCount = unreadCount.coerceAtLeast(0),
      markedUnread = markedUnread,
      muted = muted,
      pinned = pinned,
      isTyping = isTyping,
      isOnline = isOnline,
      avatarUri = avatarUri,
      avatarFallback = avatarFallback,
      isSavedMessages = isSavedMessages,
    )
  }
}

private fun resolveAvatarUri(
  rawAvatar: String?,
  friendId: String?,
  chatId: String,
  apiBaseUrl: String?,
): String? {
  if (chatId == "saved_messages") return null
  if (!friendId.isNullOrBlank() && !apiBaseUrl.isNullOrBlank()) {
    return buildPushAvatarUrl(apiBaseUrl, friendId)
  }
  if (rawAvatar.isNullOrBlank()) return null
  val trimmed = rawAvatar.trim()
  val parsed = trimmed.toHttpUrlOrNull()
  if (parsed != null && (parsed.scheme == "https" || parsed.scheme == "http")) {
    return parsed.toString()
  }
  if (trimmed.startsWith("/") && !apiBaseUrl.isNullOrBlank()) {
    return buildRelativeUrl(apiBaseUrl, trimmed)
  }
  return null
}

private fun resolveNativeHomeApiBaseUrl(context: Context): String? {
  val config = ChatEngineStore.getConfig(context)
  val explicit =
    config["apiBaseUrl"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
      ?: config["baseUrl"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
  if (!explicit.isNullOrBlank()) return explicit.trimEnd('/')

  val socketUrl =
    config["socketUrl"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
      ?: config["url"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
      ?: return fallbackHomeApiBaseUrl
  val parsed = socketUrl.toHttpUrlOrNull() ?: return fallbackHomeApiBaseUrl
  val scheme = when (parsed.scheme) {
    "wss" -> "https"
    "ws" -> "http"
    else -> parsed.scheme
  }
  val pathSegments = parsed.pathSegments.toMutableList()
  if (pathSegments.isNotEmpty() && pathSegments.last().equals("socket", ignoreCase = true)) {
    pathSegments.removeAt(pathSegments.lastIndex)
  }
  if (pathSegments.isNotEmpty() && pathSegments.last().equals("websocket", ignoreCase = true)) {
    pathSegments.removeAt(pathSegments.lastIndex)
  }
  return parsed.newBuilder()
    .scheme(scheme)
    .encodedPath("/${pathSegments.joinToString("/")}")
    .build()
    .toString()
    .trimEnd('/')
}

private fun buildPushAvatarUrl(apiBaseUrl: String, userId: String): String {
  val base = apiBaseUrl.trimEnd('/')
  val pathBase =
    if (base.lowercase().endsWith("/api")) {
      base
    } else {
      "$base/api"
    }
  return "$pathBase/push/avatar/${Uri.encode(userId)}"
}

private fun buildRelativeUrl(apiBaseUrl: String, path: String): String {
  val base = apiBaseUrl.trimEnd('/')
  val normalizedPath = if (path.startsWith("/")) path else "/$path"
  return "$base$normalizedPath"
}

private fun parseInt(value: Any?): Int? =
  when (value) {
    is Number -> value.toInt()
    is String -> value.trim().toIntOrNull()
    else -> null
  }

private fun parseBool(value: Any?): Boolean? =
  when (value) {
    is Boolean -> value
    is Number -> value.toInt() != 0
    is String -> {
      when (value.trim().lowercase()) {
        "1", "true", "yes", "on" -> true
        "0", "false", "no", "off" -> false
        else -> null
      }
    }
    else -> null
  }
