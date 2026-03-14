package expo.modules.vibechatnative

import android.content.Context
import android.net.Uri
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

internal const val fallbackNativeApiBaseUrl =
  "https://modest-recreation-production-8329.up.railway.app"

internal fun resolveNativeApiBaseUrl(context: Context): String? {
  val config = ChatEngineStore.getConfig(context)
  val explicit =
    config["apiBaseUrl"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
      ?: config["baseUrl"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
  if (!explicit.isNullOrBlank()) return explicit.trimEnd('/')

  val socketUrl =
    config["socketUrl"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
      ?: config["url"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
      ?: return fallbackNativeApiBaseUrl
  val parsed = socketUrl.toHttpUrlOrNull() ?: return fallbackNativeApiBaseUrl
  val scheme =
    when (parsed.scheme) {
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
  return parsed
    .newBuilder()
    .scheme(scheme)
    .encodedPath("/${pathSegments.joinToString("/")}")
    .build()
    .toString()
    .trimEnd('/')
}

internal fun buildNativePushAvatarUrl(apiBaseUrl: String, userId: String): String {
  val base = apiBaseUrl.trimEnd('/')
  val pathBase =
    if (base.lowercase().endsWith("/api")) {
      base
    } else {
      "$base/api"
    }
  return "$pathBase/push/avatar/${Uri.encode(userId)}"
}

internal fun buildNativeRelativeUrl(apiBaseUrl: String, path: String): String {
  val base = apiBaseUrl.trimEnd('/')
  val normalizedPath = if (path.startsWith("/")) path else "/$path"
  return "$base$normalizedPath"
}

internal fun resolveNativeAvatarUri(
  context: Context,
  rawAvatar: String?,
  peerUserId: String? = null,
  preferPushAvatar: Boolean = false,
): String? {
  return resolveNativeAvatarUri(
    rawAvatar = rawAvatar,
    peerUserId = peerUserId,
    apiBaseUrl = resolveNativeApiBaseUrl(context),
    preferPushAvatar = preferPushAvatar,
  )
}

internal fun resolveNativeAvatarUri(
  rawAvatar: String?,
  peerUserId: String?,
  apiBaseUrl: String?,
  preferPushAvatar: Boolean = false,
): String? {
  val normalizedPeerUserId = peerUserId?.trim()?.takeIf { it.isNotEmpty() }
  if (preferPushAvatar && !normalizedPeerUserId.isNullOrBlank() && !apiBaseUrl.isNullOrBlank()) {
    return buildNativePushAvatarUrl(apiBaseUrl, normalizedPeerUserId)
  }
  if (rawAvatar.isNullOrBlank()) return null
  val trimmed = rawAvatar.trim()
  val parsed = trimmed.toHttpUrlOrNull()
  if (parsed != null && (parsed.scheme == "https" || parsed.scheme == "http")) {
    return parsed.toString()
  }
  if (trimmed.startsWith("/") && !apiBaseUrl.isNullOrBlank()) {
    return buildNativeRelativeUrl(apiBaseUrl, trimmed)
  }
  return null
}
