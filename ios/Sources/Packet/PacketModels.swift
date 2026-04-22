import Foundation

enum PacketTransportMode: String {
  case direct = "direct"
  case packetMesh = "packet_mesh"
  case bridgeText = "bridge_text"
  case offline = "offline"

  init(_ rawValue: Any?) {
    let normalized = (rawValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    self = PacketTransportMode(rawValue: normalized ?? "") ?? .direct
  }
}

struct PacketBridgeDescriptor: Codable {
  let id: String
  let baseURL: String
  let spkiPins: [String]
  let priority: Int?
  let expiresAt: Int64?
  let capabilities: [String]
  let signature: String?

  enum CodingKeys: String, CodingKey {
    case id
    case baseURL = "baseUrl"
    case spkiPins
    case priority
    case expiresAt
    case capabilities
    case signature
  }

  var isExpired: Bool {
    guard let expiresAt else { return false }
    return expiresAt <= Int64(Date().timeIntervalSince1970 * 1000)
  }
}

struct PacketBridgeBundle: Codable {
  let version: Int
  let generatedAt: Int64?
  let expiresAt: Int64?
  let descriptors: [PacketBridgeDescriptor]
}

struct PacketPeerDescriptor: Codable {
  let peerID: String
  let relayURLs: [String]
  let trustScore: Int?
  let lastSeenAt: Int64?
  let capabilities: [String]

  enum CodingKeys: String, CodingKey {
    case peerID = "peerId"
    case relayURLs = "relayUrls"
    case trustScore
    case lastSeenAt
    case capabilities
  }
}

struct PacketBootstrapPayload: Codable {
  let transportMode: String
  let packetStatus: String?
  let packetTicket: String
  let packetProxyHost: String?
  let activePacketBridgeId: String?
  let packetBridgeBundle: PacketBridgeBundle
  let packetPeers: [PacketPeerDescriptor]

  enum CodingKeys: String, CodingKey {
    case transportMode
    case packetStatus
    case packetTicket
    case packetProxyHost
    case activePacketBridgeId
    case packetBridgeBundle
    case packetPeers
  }

  var proxyHost: String {
    packetProxyHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? packetProxyHost!.trimmingCharacters(in: .whitespacesAndNewlines)
      : "127.0.0.1"
  }

  var usableDescriptor: PacketBridgeDescriptor? {
    packetBridgeBundle.descriptors
      .filter { !$0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.isExpired }
      .sorted { ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }
      .first { descriptor in
        if let preferred = activePacketBridgeId {
          return descriptor.id == preferred
        }
        return true
      } ?? packetBridgeBundle.descriptors
      .filter { !$0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.isExpired }
      .sorted { ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }
      .first
  }

  func validate() throws {
    guard !packetTicket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PacketRuntimeError.invalidBootstrap("packet ticket missing")
    }
    guard let descriptor = usableDescriptor else {
      throw PacketRuntimeError.invalidBootstrap("packet bridge descriptor missing or expired")
    }
    guard descriptor.baseURL.lowercased().hasPrefix("https://") else {
      throw PacketRuntimeError.invalidBootstrap("packet bridge must use https")
    }
    guard !descriptor.spkiPins.isEmpty else {
      throw PacketRuntimeError.invalidBootstrap("packet bridge pins missing")
    }
  }

  func storedBootstrapObject() -> [String: Any]? {
    var payload = packetJSONObject(self) ?? [:]
    payload.removeValue(forKey: "packetTicket")
    return payload
  }

  func meshStartPayload() throws -> [String: Any] {
    try validate()
    guard let descriptor = usableDescriptor else {
      throw PacketRuntimeError.invalidBootstrap("packet bridge descriptor unavailable")
    }

    var bridge: [String: Any] = [
      "id": descriptor.id,
      "base_url": descriptor.baseURL,
      "spki_pins": descriptor.spkiPins,
      "capabilities": descriptor.capabilities,
    ]
    if let priority = descriptor.priority {
      bridge["priority"] = priority
    }
    if let expiresAt = descriptor.expiresAt {
      bridge["expires_at"] = expiresAt
    }
    if let signature = descriptor.signature, !signature.isEmpty {
      bridge["signature"] = signature
    }

    let peers = packetPeers.map { peer -> [String: Any] in
      var value: [String: Any] = [
        "peer_id": peer.peerID,
        "relay_urls": peer.relayURLs,
        "capabilities": peer.capabilities,
      ]
      if let trustScore = peer.trustScore {
        value["trust_score"] = trustScore
      }
      if let lastSeenAt = peer.lastSeenAt {
        value["last_seen_at"] = lastSeenAt
      }
      return value
    }

    return [
      "server_url": descriptor.baseURL,
      "ticket": packetTicket,
      "transport_mode": "auto",
      "bootstrap": [
        "ticket": packetTicket,
        "bridges": [bridge],
        "peers": peers,
        "preferred_bridge_id": activePacketBridgeId ?? descriptor.id,
      ],
    ]
  }

  static func fromConfig(_ config: [String: Any]) -> PacketBootstrapPayload? {
    guard var stored = config["packetBootstrap"] as? [String: Any] else {
      return nil
    }
    if let packetTicket = config["packetTicket"] as? String, !packetTicket.isEmpty {
      stored["packetTicket"] = packetTicket
    }
    return packetDecode(PacketBootstrapPayload.self, from: stored)
  }
}

struct PacketMeshStats: Codable {
  let status: String
  let activeBridgeID: String?
  let proxyPort: Int?
  let knownPeers: Int?
  let trustedPeers: Int?
  let importedBridges: Int?
  let lastError: String?

  enum CodingKeys: String, CodingKey {
    case status
    case activeBridgeID = "active_bridge_id"
    case proxyPort = "proxy_port"
    case knownPeers = "known_peers"
    case trustedPeers = "trusted_peers"
    case importedBridges = "imported_bridges"
    case lastError = "last_error"
  }
}

struct PacketTransportSnapshot {
  let status: String
  let proxyHost: String
  let proxyPort: Int
  let activeBridgeID: String?
  let lastError: String?
}

func packetDecode<T: Decodable>(_ type: T.Type, from object: Any) -> T? {
  guard JSONSerialization.isValidJSONObject(object),
        let data = try? JSONSerialization.data(withJSONObject: object)
  else { return nil }
  return try? JSONDecoder().decode(type, from: data)
}

func packetJSONObject<T: Encodable>(_ value: T) -> [String: Any]? {
  guard let data = try? JSONEncoder().encode(value),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return nil }
  return object
}
