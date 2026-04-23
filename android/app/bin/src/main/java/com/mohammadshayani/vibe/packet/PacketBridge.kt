package com.mohammadshayani.vibe.packet

object PacketBridge {
  interface LogCallback {
    fun onLog(message: String)
  }

  init {
    System.loadLibrary("phantom_client")
  }

  @JvmStatic
  external fun setLogCallback(callback: LogCallback)

  @JvmStatic
  external fun copyMeshStatsJson(): String?

  @JvmStatic
  external fun stopClient()

  @JvmStatic
  external fun startMeshClient(configJson: String, listenPort: Int): Int

  @JvmStatic
  external fun importMeshPeers(peersJson: String): Int
}
