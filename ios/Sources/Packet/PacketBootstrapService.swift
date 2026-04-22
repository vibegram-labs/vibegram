import Foundation

enum PacketBootstrapService {
  static func cachedPayload() -> PacketBootstrapPayload? {
    PacketBootstrapPayload.fromConfig(ChatEngineStore.shared.getConfig())
  }

  static func prefetchIfNeeded(config: AppSessionConfig) async {
    guard config.transportMode != .offline, config.transportMode != .bridgeText else {
      return
    }
    _ = try? await refresh(config: config)
  }

  static func cachedOrRefresh(config: AppSessionConfig) async throws -> PacketBootstrapPayload {
    if let cached = cachedPayload() {
      try cached.validate()
      return cached
    }
    return try await refresh(config: config)
  }

  static func refresh(config: AppSessionConfig) async throws -> PacketBootstrapPayload {
    guard let url = config.bootstrapURL else {
      throw PacketRuntimeError.invalidBootstrap("packet bootstrap url invalid")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw PacketRuntimeError.invalidBootstrap("packet bootstrap response invalid")
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw PacketRuntimeError.invalidBootstrap(
        "packet bootstrap request failed with status \(httpResponse.statusCode)\(body.isEmpty ? "" : ": \(body)")"
      )
    }

    let payload = try JSONDecoder().decode(PacketBootstrapPayload.self, from: data)
    try payload.validate()
    ChatEngineStore.shared.updateConfig([
      "packetBootstrap": payload.storedBootstrapObject(),
      "packetTicket": payload.packetTicket,
      "packetStatus": payload.packetStatus ?? "bootstrap_ready",
      "packetProxyHost": payload.proxyHost,
      "activePacketBridgeId": payload.activePacketBridgeId ?? payload.usableDescriptor?.id,
      "packetLastError": nil,
    ])
    return payload
  }
}
