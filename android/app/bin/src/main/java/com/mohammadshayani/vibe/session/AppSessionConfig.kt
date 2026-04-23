package com.mohammadshayani.vibe.session

import android.content.Context
import com.mohammadshayani.vibe.network.fallbackApiBaseUrl
import com.mohammadshayani.vibe.network.resolveApiBaseUrl
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.storage.ChatEngineStore

data class AppSessionConfig(
  val apiBaseUrl: String,
  val socketUrl: String,
  val userId: String,
  val authToken: String,
  val transportMode: PacketTransportMode,
  val username: String? = null,
  val secureId: String? = null,
  val publicKeyPem: String? = null,
  val privateKeyPem: String? = null,
  val encryptedPrivateKey: String? = null,
  val tokenExpiresAt: String? = null,
  val identityKey: String? = null,
  val phoneNumber: String? = null,
) {
  val bootstrapUrl: String
    get() = apiBaseUrl.trim().trimEnd('/') + "/packet/bootstrap"

  fun toPayload(): Map<String, Any> {
    val payload = linkedMapOf<String, Any>(
      "apiBaseUrl" to apiBaseUrl,
      "baseUrl" to apiBaseUrl,
      "socketUrl" to socketUrl,
      "url" to socketUrl,
      "userId" to userId,
      "authToken" to authToken,
      "token" to authToken,
      "loginToken" to authToken,
      "userChannelTopic" to "user:$userId",
      "transportMode" to transportMode.wireValue,
      "identityKey" to (identityKey ?: "v2"),
    )
    username?.let { payload["username"] = it }
    secureId?.let { payload["secureId"] = it }
    publicKeyPem?.let {
      payload["publicKeyPem"] = it
      payload["publicKey"] = it
    }
    privateKeyPem?.let {
      payload["privateKeyPem"] = it
      payload["privateKey"] = it
    }
    encryptedPrivateKey?.let { payload["encryptedPrivateKey"] = it }
    tokenExpiresAt?.let { payload["tokenExpiresAt"] = it }
    phoneNumber?.let { payload["phoneNumber"] = it }
    return payload
  }

  companion object {
    fun current(context: Context): AppSessionConfig? {
      val payload = ChatEngineStore.getConfig(context)
      val apiBaseUrl =
        normalized(payload["apiBaseUrl"] ?: payload["baseUrl"])
          ?: resolveApiBaseUrl(context)
          ?: fallbackApiBaseUrl
      val userId = normalized(payload["userId"]) ?: return null
      val authToken =
        normalized(payload["authToken"] ?: payload["token"] ?: payload["loginToken"]) ?: return null
      val socketUrl =
        normalized(payload["socketUrl"] ?: payload["url"]) ?: deriveSocketUrl(apiBaseUrl)
      return AppSessionConfig(
        apiBaseUrl = apiBaseUrl,
        socketUrl = socketUrl,
        userId = userId,
        authToken = authToken,
        transportMode = PacketTransportMode.from(payload["transportMode"]),
        username = normalized(payload["username"]),
        secureId = normalized(payload["secureId"]),
        publicKeyPem = normalized(payload["publicKeyPem"] ?: payload["publicKey"]),
        privateKeyPem = normalized(payload["privateKeyPem"] ?: payload["privateKey"]),
        encryptedPrivateKey = normalized(payload["encryptedPrivateKey"]),
        tokenExpiresAt = normalized(payload["tokenExpiresAt"]),
        identityKey = normalized(payload["identityKey"]),
        phoneNumber = normalized(payload["phoneNumber"]),
      )
    }

    fun save(
      context: Context,
      apiBaseUrl: String,
      socketUrl: String?,
      userId: String,
      authToken: String,
      transportMode: PacketTransportMode = PacketTransportMode.PACKET_MESH,
      username: String? = null,
      secureId: String? = null,
      publicKeyPem: String? = null,
      privateKeyPem: String? = null,
      encryptedPrivateKey: String? = null,
      tokenExpiresAt: String? = null,
      identityKey: String? = null,
      phoneNumber: String? = null,
    ) {
      val config = AppSessionConfig(
        apiBaseUrl = apiBaseUrl.trim(),
        socketUrl = socketUrl?.trim().takeUnless { it.isNullOrEmpty() } ?: deriveSocketUrl(apiBaseUrl),
        userId = userId.trim(),
        authToken = authToken.trim(),
        transportMode = transportMode,
        username = normalized(username),
        secureId = normalized(secureId),
        publicKeyPem = normalized(publicKeyPem),
        privateKeyPem = normalized(privateKeyPem),
        encryptedPrivateKey = normalized(encryptedPrivateKey),
        tokenExpiresAt = normalized(tokenExpiresAt),
        identityKey = normalized(identityKey),
        phoneNumber = normalized(phoneNumber),
      )
      store(context, config)
    }

    fun store(context: Context, config: AppSessionConfig) {
      ChatEngineStore.clearConfig(context)
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
