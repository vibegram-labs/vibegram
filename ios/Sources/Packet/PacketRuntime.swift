import CryptoKit
import Foundation
import Security

enum PacketRuntimeError: LocalizedError {
  case invalidBootstrap(String)
  case startFailed(String)

  var errorDescription: String? {
    switch self {
    case let .invalidBootstrap(message), let .startFailed(message):
      return message
    }
  }
}

private func vibePacketLogCallback(_ message: UnsafePointer<CChar>?) {
  guard let message else { return }
  ChatEngineStore.shared.appendJournal([
    "at": Int(Date().timeIntervalSince1970 * 1000),
    "source": "packet",
    "message": String(cString: message),
  ])
}

final class PacketRuntime {
  static let shared = PacketRuntime()

  private let queue = DispatchQueue(label: "vibe.packet.runtime")
  private var currentSnapshot: PacketTransportSnapshot?

  private init() {
    phantom_set_log_callback(vibePacketLogCallback)
  }

  func ensureStarted(config: AppSessionConfig) async throws -> PacketTransportSnapshot {
    let bootstrap = try await PacketBootstrapService.cachedOrRefresh(config: config)
    return try queue.sync {
      try startLocked(bootstrap: bootstrap)
    }
  }

  func stop(resetToDirect: Bool = false) {
    queue.sync {
      stopLocked(resetToDirect: resetToDirect)
    }
  }

  func makeURLSession(snapshot: PacketTransportSnapshot) -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.connectionProxyDictionary = [
      kCFNetworkProxiesSOCKSEnable as String: 1,
      kCFNetworkProxiesSOCKSProxy as String: snapshot.proxyHost,
      kCFNetworkProxiesSOCKSPort as String: snapshot.proxyPort,
    ]
    return URLSession(
      configuration: configuration,
      delegate: PacketPinnedSessionDelegate(),
      delegateQueue: nil
    )
  }

  private func startLocked(bootstrap: PacketBootstrapPayload) throws -> PacketTransportSnapshot {
    try bootstrap.validate()

    if let currentSnapshot,
       currentSnapshot.activeBridgeID == (bootstrap.activePacketBridgeId ?? bootstrap.usableDescriptor?.id),
       currentSnapshot.proxyPort > 0
    {
      return currentSnapshot
    }

    stopLocked(resetToDirect: false)

    let startPayload = try bootstrap.meshStartPayload()
    guard JSONSerialization.isValidJSONObject(startPayload),
          let data = try? JSONSerialization.data(withJSONObject: startPayload),
          let text = String(data: data, encoding: .utf8)
    else {
      throw PacketRuntimeError.startFailed("packet mesh config serialization failed")
    }

    let port = text.withCString { value in
      Int(phantom_start_mesh(value, 0))
    }

    guard port > 0 else {
      ChatEngineStore.shared.updateConfig([
        "packetStatus": "failed",
        "packetLastError": "packet mesh start failed",
        "packetProxyPort": nil,
      ])
      throw PacketRuntimeError.startFailed("packet mesh start failed")
    }

    let stats = meshStatsLocked()
    let snapshot = PacketTransportSnapshot(
      status: stats?.status ?? "running",
      proxyHost: bootstrap.proxyHost,
      proxyPort: stats?.proxyPort ?? port,
      activeBridgeID: stats?.activeBridgeID ?? bootstrap.activePacketBridgeId ?? bootstrap.usableDescriptor?.id,
      lastError: stats?.lastError
    )

    currentSnapshot = snapshot
    ChatEngineStore.shared.updateConfig([
      "packetStatus": snapshot.status,
      "packetProxyHost": snapshot.proxyHost,
      "packetProxyPort": snapshot.proxyPort,
      "activePacketBridgeId": snapshot.activeBridgeID,
      "packetLastError": snapshot.lastError,
    ])
    return snapshot
  }

  private func stopLocked(resetToDirect: Bool) {
    phantom_stop_client()
    currentSnapshot = nil
    ChatEngineStore.shared.updateConfig([
      "packetStatus": resetToDirect ? PacketTransportMode.direct.rawValue : "idle",
      "packetProxyPort": nil,
      "packetLastError": nil,
    ])
  }

  private func meshStatsLocked() -> PacketMeshStats? {
    guard let raw = phantom_copy_mesh_stats_json() else { return nil }
    defer { phantom_free_string(raw) }
    let json = String(cString: raw)
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(PacketMeshStats.self, from: data)
  }
}

private final class PacketPinnedSessionDelegate: NSObject, URLSessionDelegate {
  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let serverTrust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }

    var error: CFError?
    guard SecTrustEvaluateWithError(serverTrust, &error) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    completionHandler(.useCredential, URLCredential(trust: serverTrust))
  }
}
