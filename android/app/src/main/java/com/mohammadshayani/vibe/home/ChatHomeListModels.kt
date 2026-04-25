package com.mohammadshayani.vibe.home

import android.content.Context
import com.mohammadshayani.vibe.network.resolveApiBaseUrl
import com.mohammadshayani.vibe.network.resolveAvatarUri

internal data class ChatHomeListRow(
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
  val peerUserId: String?,
  val avatarUri: String?,
  val avatarFallback: String,
  val avatarGradientStartLight: String?,
  val avatarGradientEndLight: String?,
  val avatarGradientStartDark: String?,
  val avatarGradientEndDark: String?,
  val isSavedMessages: Boolean,
) {
  fun withPresence(isTyping: Boolean, isOnline: Boolean): ChatHomeListRow {
    return copy(isTyping = isTyping, isOnline = isOnline)
  }
}

internal fun parseChatHomeRows(
  rawRows: List<Map<String, Any?>>,
  context: Context,
): List<ChatHomeListRow> {
  val apiBaseUrl = resolveApiBaseUrl(context)
  return rawRows.mapNotNull { raw ->
    val chatId = raw["chatId"]?.toString()?.trim().orEmpty()
    if (chatId.isEmpty()) return@mapNotNull null
    val isSavedMessages = chatId == "saved_messages"
    val chatType = parseChatType(raw["chatType"] ?: raw["chat_type"] ?: raw["type"])
    val isDirectChat = chatType == "dm"

    val title =
      firstNonBlank(
        raw["name"],
        raw["title"],
        raw["chatName"],
        raw["chat_name"],
        raw["friendName"],
        raw["friend_name"],
        raw["displayName"],
        raw["display_name"],
        raw["fullName"],
        raw["full_name"],
        raw["username"],
        raw["handle"],
      )?.takeUnless { looksLikeUuid(it) }
        ?: "Vibegram User"
    val preview = resolvePreview(raw, isSavedMessages)
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
      firstNonBlank(
        raw["friendId"],
        raw["friend_id"],
        raw["peerUserId"],
        raw["peer_user_id"],
        raw["userId"],
        raw["user_id"],
      )
    val peerUserId = if (isDirectChat) friendId else null
    val rawAvatar =
      firstNonBlank(
        raw["avatarUri"],
        raw["avatar_uri"],
        raw["friendImage"],
        raw["friend_image"],
        raw["profileImage"],
        raw["profile_image"],
        raw["avatarUrl"],
        raw["avatar_url"],
      )
    val avatarUri = resolveRowAvatarUri(
      rawAvatar = rawAvatar,
      friendId = peerUserId,
      chatId = chatId,
      apiBaseUrl = apiBaseUrl,
    )
    val avatarFallback =
      raw["avatarFallback"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: title.take(1).uppercase()
    val avatarGradientStartLight =
      raw["avatarGradientStartLight"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["avatar_gradient_start_light"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
    val avatarGradientEndLight =
      raw["avatarGradientEndLight"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["avatar_gradient_end_light"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
    val avatarGradientStartDark =
      raw["avatarGradientStartDark"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["avatar_gradient_start_dark"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
    val avatarGradientEndDark =
      raw["avatarGradientEndDark"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        ?: raw["avatar_gradient_end_dark"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }

    ChatHomeListRow(
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
      peerUserId = peerUserId,
      avatarUri = avatarUri,
      avatarFallback = avatarFallback,
      avatarGradientStartLight = avatarGradientStartLight,
      avatarGradientEndLight = avatarGradientEndLight,
      avatarGradientStartDark = avatarGradientStartDark,
      avatarGradientEndDark = avatarGradientEndDark,
      isSavedMessages = isSavedMessages,
    )
  }
}

private fun resolvePreview(
  raw: Map<String, Any?>,
  isSavedMessages: Boolean,
): String {
  val explicit =
    raw["preview"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
      ?: raw["subtitle"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
  if (!explicit.isNullOrBlank()) {
    if (isSavedMessages && explicit.equals("Your private notes", ignoreCase = true)) {
      return ""
    }
    return explicit
  }

  val previewRows =
    (raw["previewRows"] as? List<*>)
      ?: (raw["preview_rows"] as? List<*>)
      ?: (raw["messages"] as? List<*>)
      ?: emptyList<Any?>()

  val derived =
    previewRows.firstNotNullOfOrNull { entry ->
      val row = entry as? Map<*, *> ?: return@firstNotNullOfOrNull null
      val body =
        row["body"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
          ?: row["content"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
          ?: row["text"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
      body?.takeIf { it.isNotBlank() }
    }
  if (!derived.isNullOrBlank()) return derived

  return if (isSavedMessages) "" else "Start a conversation"
}

private fun resolveRowAvatarUri(
  rawAvatar: String?,
  friendId: String?,
  chatId: String,
  apiBaseUrl: String?,
): String? {
  if (chatId == "saved_messages") return null
  return resolveAvatarUri(
    rawAvatar = rawAvatar,
    peerUserId = friendId,
    apiBaseUrl = apiBaseUrl,
    preferPushAvatar = true,
  )
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

private fun parseChatType(value: Any?): String {
  val raw = value?.toString()?.trim()?.lowercase().orEmpty()
  return when (raw) {
    "group" -> "group"
    "channel" -> "channel"
    else -> "dm"
  }
}

private fun firstNonBlank(vararg values: Any?): String? {
  return values.firstNotNullOfOrNull { value ->
    value?.toString()?.trim()?.takeIf { it.isNotEmpty() }
  }
}

private fun looksLikeUuid(value: String): Boolean {
  val trimmed = value.trim()
  if (trimmed.length != 36) return false
  return runCatching { java.util.UUID.fromString(trimmed) }.isSuccess
}
