package com.mohammadshayani.vibe.packet

import org.json.JSONArray
import org.json.JSONObject

enum class PacketTransportMode(val wireValue: String) {
  DIRECT("direct"),
  PACKET_MESH("packet_mesh"),
  BRIDGE_TEXT("bridge_text"),
  OFFLINE("offline");

  companion object {
    fun from(value: Any?): PacketTransportMode {
      val normalized = value?.toString()?.trim()?.lowercase().orEmpty()
      return values().firstOrNull { it.wireValue == normalized } ?: PACKET_MESH
    }
  }
}

data class PacketBridgeDescriptor(
  val id: String,
  val baseUrl: String,
  val spkiPins: List<String>,
  val priority: Int?,
  val expiresAt: Long?,
  val capabilities: List<String>,
  val signature: String?,
) {
  val isExpired: Boolean
    get() = expiresAt != null && expiresAt <= System.currentTimeMillis()

  fun toJson(): JSONObject =
    JSONObject()
      .put("id", id)
      .put("baseUrl", baseUrl)
      .put("spkiPins", JSONArray(spkiPins))
      .put("priority", priority)
      .put("expiresAt", expiresAt)
      .put("capabilities", JSONArray(capabilities))
      .put("signature", signature)

  companion object {
    fun fromJson(json: JSONObject): PacketBridgeDescriptor {
      return PacketBridgeDescriptor(
        id = json.optString("id"),
        baseUrl = json.optString("baseUrl"),
        spkiPins = jsonArrayStrings(json.optJSONArray("spkiPins")),
        priority = json.optInt("priority").takeIf { it > 0 || json.has("priority") },
        expiresAt = json.optLong("expiresAt").takeIf { it > 0L },
        capabilities = jsonArrayStrings(json.optJSONArray("capabilities")),
        signature = json.optString("signature").takeIf { it.isNotBlank() },
      )
    }
  }
}

data class PacketBridgeBundle(
  val version: Int,
  val generatedAt: Long?,
  val expiresAt: Long?,
  val descriptors: List<PacketBridgeDescriptor>,
) {
  fun toJson(): JSONObject =
    JSONObject()
      .put("version", version)
      .put("generatedAt", generatedAt)
      .put("expiresAt", expiresAt)
      .put("descriptors", JSONArray(descriptors.map { it.toJson() }))

  companion object {
    fun fromJson(json: JSONObject): PacketBridgeBundle {
      return PacketBridgeBundle(
        version = json.optInt("version", 1),
        generatedAt = json.optLong("generatedAt").takeIf { it > 0L },
        expiresAt = json.optLong("expiresAt").takeIf { it > 0L },
        descriptors = jsonArrayToList(json.optJSONArray("descriptors")).mapNotNull { item ->
          (item as? JSONObject)?.let(PacketBridgeDescriptor::fromJson)
        },
      )
    }
  }
}

data class PacketPeerDescriptor(
  val peerId: String,
  val relayUrls: List<String>,
  val trustScore: Int?,
  val lastSeenAt: Long?,
  val capabilities: List<String>,
) {
  fun toJson(): JSONObject =
    JSONObject()
      .put("peerId", peerId)
      .put("relayUrls", JSONArray(relayUrls))
      .put("trustScore", trustScore)
      .put("lastSeenAt", lastSeenAt)
      .put("capabilities", JSONArray(capabilities))

  companion object {
    fun fromJson(json: JSONObject): PacketPeerDescriptor {
      return PacketPeerDescriptor(
        peerId = json.optString("peerId"),
        relayUrls = jsonArrayStrings(json.optJSONArray("relayUrls")),
        trustScore = json.optInt("trustScore").takeIf { it != 0 || json.has("trustScore") },
        lastSeenAt = json.optLong("lastSeenAt").takeIf { it > 0L },
        capabilities = jsonArrayStrings(json.optJSONArray("capabilities")),
      )
    }
  }
}

data class PacketBootstrapPayload(
  val transportMode: String,
  val packetStatus: String?,
  val packetTicket: String,
  val packetProxyHost: String?,
  val activePacketBridgeId: String?,
  val packetBridgeBundle: PacketBridgeBundle,
  val packetPeers: List<PacketPeerDescriptor> = emptyList(),
) {
  val proxyHost: String
    get() = packetProxyHost?.trim().takeUnless { it.isNullOrEmpty() } ?: "127.0.0.1"

  val usableDescriptor: PacketBridgeDescriptor?
    get() {
      val live = packetBridgeBundle.descriptors
        .filter { it.baseUrl.isNotBlank() && !it.isExpired }
        .sortedBy { it.priority ?: Int.MAX_VALUE }
      return activePacketBridgeId?.let { preferred ->
        live.firstOrNull { it.id == preferred }
      } ?: live.firstOrNull()
    }

  fun validate() {
    require(packetTicket.isNotBlank()) { "packet ticket missing" }
    val descriptor = usableDescriptor ?: error("packet bridge descriptor missing or expired")
    require(descriptor.baseUrl.startsWith("https://", ignoreCase = true)) { "packet bridge must use https" }
    require(descriptor.spkiPins.isNotEmpty()) { "packet bridge pins missing" }
  }

  fun toJson(): JSONObject =
    JSONObject()
      .put("transportMode", transportMode)
      .put("packetStatus", packetStatus)
      .put("packetTicket", packetTicket)
      .put("packetProxyHost", packetProxyHost)
      .put("activePacketBridgeId", activePacketBridgeId)
      .put("packetBridgeBundle", packetBridgeBundle.toJson())
      .put("packetPeers", JSONArray(packetPeers.map { it.toJson() }))

  fun storedBootstrapJson(): JSONObject =
    toJson().apply { remove("packetTicket") }

  fun toMeshStartJson(): JSONObject {
    validate()
    val descriptor = usableDescriptor ?: error("packet bridge descriptor unavailable")
    val bridge = JSONObject()
      .put("id", descriptor.id)
      .put("base_url", descriptor.baseUrl)
      .put("spki_pins", JSONArray(descriptor.spkiPins))
      .put("capabilities", JSONArray(descriptor.capabilities))
    descriptor.priority?.let { bridge.put("priority", it) }
    descriptor.expiresAt?.let { bridge.put("expires_at", it) }
    descriptor.signature?.takeIf { it.isNotBlank() }?.let { bridge.put("signature", it) }

    val peers = JSONArray(
      packetPeers.map { peer ->
        JSONObject()
          .put("peer_id", peer.peerId)
          .put("relay_urls", JSONArray(peer.relayUrls))
          .put("capabilities", JSONArray(peer.capabilities))
          .apply {
            peer.trustScore?.let { put("trust_score", it) }
            peer.lastSeenAt?.let { put("last_seen_at", it) }
          }
      }
    )

    return JSONObject()
      .put("server_url", descriptor.baseUrl)
      .put("ticket", packetTicket)
      .put("transport_mode", "auto")
      .put(
        "bootstrap",
        JSONObject()
          .put("ticket", packetTicket)
          .put("bridges", JSONArray().put(bridge))
          .put("peers", peers)
          .put("preferred_bridge_id", activePacketBridgeId ?: descriptor.id)
      )
  }

  companion object {
    fun fromConfig(config: Map<String, Any?>): PacketBootstrapPayload? {
      val stored = config["packetBootstrap"] ?: return null
      val json = toJsonObject(stored) ?: return null
      val ticket = config["packetTicket"]?.toString()?.trim().orEmpty()
      if (ticket.isNotEmpty()) {
        json.put("packetTicket", ticket)
      }
      return fromJson(json)
    }

    fun fromJson(json: JSONObject): PacketBootstrapPayload? {
      return try {
        PacketBootstrapPayload(
          transportMode = json.optString("transportMode", PacketTransportMode.PACKET_MESH.wireValue),
          packetStatus = json.optString("packetStatus").takeIf { it.isNotBlank() },
          packetTicket = json.optString("packetTicket"),
          packetProxyHost = json.optString("packetProxyHost").takeIf { it.isNotBlank() },
          activePacketBridgeId = json.optString("activePacketBridgeId").takeIf { it.isNotBlank() },
          packetBridgeBundle = PacketBridgeBundle.fromJson(json.optJSONObject("packetBridgeBundle") ?: JSONObject()),
          packetPeers = jsonArrayToList(json.optJSONArray("packetPeers")).mapNotNull { item ->
            (item as? JSONObject)?.let(PacketPeerDescriptor::fromJson)
          },
        )
      } catch (_: Throwable) {
        null
      }
    }
  }
}

data class PacketMeshStats(
  val status: String,
  val activeBridgeId: String?,
  val proxyPort: Int?,
  val lastError: String?,
) {
  companion object {
    fun fromJson(raw: String?): PacketMeshStats? {
      if (raw.isNullOrBlank()) return null
      return try {
        val json = JSONObject(raw)
        PacketMeshStats(
          status = json.optString("status", "running"),
          activeBridgeId = json.optString("active_bridge_id").takeIf { it.isNotBlank() },
          proxyPort = json.optInt("proxy_port").takeIf { it > 0 },
          lastError = json.optString("last_error").takeIf { it.isNotBlank() },
        )
      } catch (_: Throwable) {
        null
      }
    }
  }
}

data class PacketRuntimeSnapshot(
  val status: String,
  val proxyHost: String,
  val proxyPort: Int,
  val activeBridgeId: String?,
  val lastError: String?,
)

private fun jsonArrayStrings(array: JSONArray?): List<String> =
  jsonArrayToList(array).mapNotNull { it?.toString()?.trim()?.takeIf { value -> value.isNotEmpty() } }

private fun jsonArrayToList(array: JSONArray?): List<Any?> {
  if (array == null) return emptyList()
  val list = ArrayList<Any?>(array.length())
  for (index in 0 until array.length()) {
    list.add(array.opt(index))
  }
  return list
}

private fun toJsonObject(value: Any?): JSONObject? =
  when (value) {
    is JSONObject -> value
    is Map<*, *> -> JSONObject(value)
    is String -> runCatching { JSONObject(value) }.getOrNull()
    else -> null
  }
