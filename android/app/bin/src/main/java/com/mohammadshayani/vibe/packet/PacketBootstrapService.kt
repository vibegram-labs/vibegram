package com.mohammadshayani.vibe.packet

import android.content.Context
import com.mohammadshayani.vibe.session.AppSessionConfig
import com.mohammadshayani.vibe.storage.ChatEngineStore
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

object PacketBootstrapService {
  private val client by lazy {
    OkHttpClient.Builder()
      .connectTimeout(10, TimeUnit.SECONDS)
      .readTimeout(15, TimeUnit.SECONDS)
      .writeTimeout(15, TimeUnit.SECONDS)
      .callTimeout(18, TimeUnit.SECONDS)
      .build()
  }

  fun cachedPayload(context: Context): PacketBootstrapPayload? =
    PacketBootstrapPayload.fromConfig(ChatEngineStore.getConfig(context))

  fun prefetchIfNeeded(context: Context, config: AppSessionConfig) {
    if (config.transportMode == PacketTransportMode.OFFLINE || config.transportMode == PacketTransportMode.BRIDGE_TEXT) {
      return
    }
    runCatching { refresh(context, config) }
  }

  fun cachedOrRefresh(context: Context, config: AppSessionConfig): PacketBootstrapPayload {
    cachedPayload(context)?.let {
      it.validate()
      return it
    }
    return refresh(context, config)
  }

  fun refresh(context: Context, config: AppSessionConfig): PacketBootstrapPayload {
    val request = Request.Builder()
      .url(config.bootstrapUrl)
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
      .header("Authorization", "Bearer ${config.authToken}")
      .build()

    client.newCall(request).execute().use { response ->
      val body = response.body?.string().orEmpty()
      if (!response.isSuccessful) {
        throw IOException("Packet bootstrap request failed with status ${response.code}: ${body.take(160)}")
      }
      val payload = PacketBootstrapPayload.fromJson(JSONObject(body))
        ?: throw IOException("Packet bootstrap payload invalid")
      payload.validate()
      ChatEngineStore.updateConfig(
        context,
        mapOf(
          "packetBootstrap" to payload.storedBootstrapJson().toMap(),
          "packetTicket" to payload.packetTicket,
          "packetStatus" to (payload.packetStatus ?: "bootstrap_ready"),
          "packetProxyHost" to payload.proxyHost,
          "activePacketBridgeId" to (payload.activePacketBridgeId ?: payload.usableDescriptor?.id),
          "packetLastError" to null,
        )
      )
      return payload
    }
  }
}

private fun JSONObject.toMap(): Map<String, Any?> {
  val out = linkedMapOf<String, Any?>()
  val keys = keys()
  while (keys.hasNext()) {
    val key = keys.next()
    out[key] =
      when (val value = opt(key)) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.toMap()
        is JSONArray -> {
          val list = ArrayList<Any?>(value.length())
          for (index in 0 until value.length()) {
            val item = value.opt(index)
            list.add(if (item is JSONObject) item.toMap() else item)
          }
          list
        }
        else -> value
      }
  }
  return out
}
