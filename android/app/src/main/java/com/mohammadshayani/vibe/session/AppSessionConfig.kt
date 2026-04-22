package com.mohammadshayani.vibe.session

import android.content.Context
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.storage.ChatEngineStore

data class AppSessionConfig(
  val apiBaseUrl: String,
  val socketUrl: String,
  val userId: String,
  val authToken: String,
  val transportMode: PacketTransportMode,
) {
  val bootstrapUrl: String
    get() = apiBaseUrl.trim().trimEnd('/') + "/packet/bootstrap"

  fun toPayload(): Map<String, Any> {
    return mapOf(
      "apiBaseUrl" to apiBaseUrl,
      "baseUrl" to apiBaseUrl,
      "socketUrl" to socketUrl,
      "url" to socketUrl,
      "userId" to userId,
      "authToken" to authToken,
      "token" to authToken,
      "userChannelTopic" to "user:$userId",
      "transportMode" to transportMode.wireValue,
    )
  }

  companion object {
    fun current(context: Context): AppSessionConfig? {
      val payload = ChatEngineStore.getConfig(context)
      val apiBaseUrl =
        normalized(payload["apiBaseUrl"] ?: payload["baseUrl"]) ?: "https://api.vibegram.io"
      val userId = normalized(payload["userId"]) ?: return null
      val authToken = normalized(payload["authToken"] ?: payload["token"]) ?: return null
      val socketUrl =
        normalized(payload["socketUrl"] ?: payload["url"]) ?: deriveSocketUrl(apiBaseUrl)
      return AppSessionConfig(
        apiBaseUrl = apiBaseUrl,
        socketUrl = socketUrl,
        userId = userId,
        authToken = authToken,
        transportMode = PacketTransportMode.from(payload["transportMode"]),
      )
    }

    fun save(
      context: Context,
      apiBaseUrl: String,
      socketUrl: String?,
      userId: String,
      authToken: String,
      transportMode: PacketTransportMode = PacketTransportMode.DIRECT,
    ) {
      val config = AppSessionConfig(
        apiBaseUrl = apiBaseUrl.trim(),
        socketUrl = socketUrl?.trim().takeUnless { it.isNullOrEmpty() } ?: deriveSocketUrl(apiBaseUrl),
        userId = userId.trim(),
        authToken = authToken.trim(),
        transportMode = transportMode,
      )
      ChatEngineStore.setConfig(context, config.toPayload())
    }

    private fun normalized(value: Any?): String? {
      val text = value?.toString()?.trim().orEmpty()
      return text.takeIf { it.isNotEmpty() }
    }

    private fun deriveSocketUrl(apiBaseUrl: String): String {
      val trimmed = apiBaseUrl.trim().trimEnd('/')
      val withoutApi =
        if (trimmed.lowercase().endsWith("/api")) {
          trimmed.dropLast(4)
        } else {
          trimmed
        }
      return when {
        withoutApi.startsWith("https://") -> withoutApi.replaceFirst("https://", "wss://") + "/socket"
        withoutApi.startsWith("http://") -> withoutApi.replaceFirst("http://", "ws://") + "/socket"
        else -> "wss://api.vibegram.io/socket"
      }
    }
  }
}
