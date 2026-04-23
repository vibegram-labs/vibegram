package com.mohammadshayani.vibe.packet

import android.content.Context
import com.mohammadshayani.vibe.storage.ChatEngineStore
import com.mohammadshayani.vibe.session.AppSessionConfig
import okhttp3.ConnectionSpec
import okhttp3.OkHttpClient
import okhttp3.TlsVersion
import java.net.InetSocketAddress
import java.net.Proxy

object PacketRuntime {
  private val lock = Any()
  private var currentSnapshot: PacketRuntimeSnapshot? = null
  private var installedLogCallback = false

  fun ensureStarted(context: Context, config: AppSessionConfig): PacketRuntimeSnapshot {
    val bootstrap = PacketBootstrapService.cachedOrRefresh(context, config)
    synchronized(lock) {
      bootstrap.validate()
      val desiredBridgeId = bootstrap.activePacketBridgeId ?: bootstrap.usableDescriptor?.id
      currentSnapshot?.let { existing ->
        if (existing.activeBridgeId == desiredBridgeId && existing.proxyPort > 0) {
          return existing
        }
      }

      installLogCallbackIfNeeded(context)
      stop(context, resetToDirect = false)

      val port = PacketBridge.startMeshClient(bootstrap.toMeshStartJson().toString(), 0)
      if (port <= 0) {
        ChatEngineStore.updateConfig(
          context,
          mapOf(
            "packetStatus" to "failed",
            "packetLastError" to "packet mesh start failed",
            "packetProxyPort" to null,
          )
        )
        error("packet mesh start failed")
      }

      val stats = PacketMeshStats.fromJson(PacketBridge.copyMeshStatsJson())
      val snapshot = PacketRuntimeSnapshot(
        status = stats?.status ?: "running",
        proxyHost = bootstrap.proxyHost,
        proxyPort = stats?.proxyPort ?: port,
        activeBridgeId = stats?.activeBridgeId ?: desiredBridgeId,
        lastError = stats?.lastError,
      )
      currentSnapshot = snapshot
      ChatEngineStore.updateConfig(
        context,
        mapOf(
          "packetStatus" to snapshot.status,
          "packetProxyHost" to snapshot.proxyHost,
          "packetProxyPort" to snapshot.proxyPort,
          "activePacketBridgeId" to snapshot.activeBridgeId,
          "packetLastError" to snapshot.lastError,
        )
      )
      return snapshot
    }
  }

  fun stop(context: Context, resetToDirect: Boolean) {
    synchronized(lock) {
      PacketBridge.stopClient()
      currentSnapshot = null
      ChatEngineStore.updateConfig(
        context,
        mapOf(
          "packetStatus" to if (resetToDirect) PacketTransportMode.DIRECT.wireValue else "idle",
          "packetProxyPort" to null,
          "packetLastError" to null,
        )
      )
    }
  }

  fun buildHttpClient(snapshot: PacketRuntimeSnapshot): OkHttpClient {
    return OkHttpClient.Builder()
      .proxy(Proxy(Proxy.Type.SOCKS, InetSocketAddress(snapshot.proxyHost, snapshot.proxyPort)))
      .connectionSpecs(
        listOf(
          ConnectionSpec.Builder(ConnectionSpec.MODERN_TLS)
            .tlsVersions(TlsVersion.TLS_1_2, TlsVersion.TLS_1_3)
            .build()
        )
      )
      .build()
  }

  private fun installLogCallbackIfNeeded(context: Context) {
    if (installedLogCallback) return
    val appContext = context.applicationContext
    PacketBridge.setLogCallback(
      object : PacketBridge.LogCallback {
        override fun onLog(message: String) {
          ChatEngineStore.appendJournal(
            appContext,
            mapOf(
              "at" to System.currentTimeMillis(),
              "source" to "packet",
              "message" to message,
            )
          )
        }
      }
    )
    installedLogCallback = true
  }
}
