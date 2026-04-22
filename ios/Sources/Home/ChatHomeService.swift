import Foundation

enum ChatHomeService {
  static func fetchChats(config: AppSessionConfig) async throws -> [ChatHomeListRow] {
    let request = try buildRequest(config: config)
    switch config.transportMode {
    case .offline:
      throw ChatHomeServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatHomeServiceError.transportUnavailable("bridge_text")
    case .packetMesh:
      let packetSnapshot = try await PacketRuntime.shared.ensureStarted(config: config)
      return try await perform(request, session: PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot))
    case .direct:
      do {
        let rows = try await perform(request, session: .shared)
        PacketRuntime.shared.stop(resetToDirect: true)
        Task.detached {
          await PacketBootstrapService.prefetchIfNeeded(config: config)
        }
        return rows
      } catch {
        guard shouldAttemptPacketFallback(for: error) else {
          throw error
        }
        let packetSnapshot = try await PacketRuntime.shared.ensureStarted(config: config)
        return try await perform(request, session: PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot))
      }
    }
  }

  private static func buildRequest(config: AppSessionConfig) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard
      let encodedUserID = config.userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(pathBase)/chats/\(encodedUserID)")
    else {
      throw ChatHomeServiceError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func perform(_ request: URLRequest, session: URLSession) async throws -> [ChatHomeListRow] {
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ChatHomeServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ChatHomeServiceError.http(httpResponse.statusCode, body)
    }

    let payload = try parsePayload(data)
    return payload.compactMap(ChatHomeListRow.parse)
  }

  private static func shouldAttemptPacketFallback(for error: Error) -> Bool {
    if let homeError = error as? ChatHomeServiceError {
      switch homeError {
      case let .http(statusCode, _):
        return statusCode >= 500
      case .transportUnavailable:
        return false
      default:
        return true
      }
    }
    return true
  }

  private static func parsePayload(_ data: Data) throws -> [[String: Any]] {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    if let items = object as? [[String: Any]] {
      return items
    }
    if let object = object as? [String: Any] {
      if let items = object["data"] as? [[String: Any]] {
        return items
      }
      if let items = object["chats"] as? [[String: Any]] {
        return items
      }
    }
    if let items = object as? [Any] {
      return items.compactMap { $0 as? [String: Any] }
    }
    throw ChatHomeServiceError.invalidPayload
  }
}

enum ChatHomeServiceError: LocalizedError {
  case invalidURL
  case invalidResponse
  case invalidPayload
  case http(Int, String)
  case transportUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case .invalidPayload:
      return "The chat payload could not be parsed."
    case let .http(status, body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Request failed with status \(status)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
    case let .transportUnavailable(mode):
      return "Transport mode \(mode) is not available in the standalone native app."
    }
  }
}
