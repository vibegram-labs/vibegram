import Foundation

enum ChatHomeService {
  static func cachedRows(config: AppSessionConfig) -> [ChatHomeListRow] {
    ChatHomeRowsCache.rows(userID: config.userID)
  }

  static func isOfflineError(_ error: Error) -> Bool {
    if let homeError = error as? ChatHomeServiceError {
      switch homeError {
      case let .transportUnavailable(reason):
        return reason == "offline"
      default:
        return false
      }
    }

    guard let urlError = firstURLError(in: error) else { return false }
    switch urlError.code {
    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
      return true
    default:
      return false
    }
  }

  static func fetchChats(config: AppSessionConfig) async throws -> [ChatHomeListRow] {
    let request = try buildRequest(config: config)
    switch config.transportMode {
    case .offline:
      throw ChatHomeServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatHomeServiceError.transportUnavailable("bridge_text")
    case .packetMesh:
      do {
        let packetSnapshot = try await PacketRuntime.shared.ensureStarted(config: config)
        return try await loadRows(
          config: config,
          request: request,
          session: PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot)
        )
      } catch {
        // Packet mesh unavailable — fall back to direct HTTP so the home
        // list still loads instead of showing a permanent "Connecting" state.
        NSLog("[ChatHomeService] packetMesh failed, falling back to direct: %@", error.localizedDescription)
        return try await loadRows(config: config, request: request, session: .shared)
      }
    case .direct:
      do {
        let rows = try await loadRows(config: config, request: request, session: .shared)
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
        return try await loadRows(
          config: config,
          request: request,
          session: PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot)
        )
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
    request.timeoutInterval = 18
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func loadRows(
    config: AppSessionConfig,
    request: URLRequest,
    session: URLSession
  ) async throws -> [ChatHomeListRow] {
    async let chats = perform(request, session: session)
    async let savedMessagesRow = fetchSavedMessagesRow(config: config, session: session)

    let rows = try await chats
    let filteredRows = rows.filter { !$0.isSavedMessages }

    let combinedRows: [ChatHomeListRow]
    let resolvedSavedMessagesRow =
      await savedMessagesRow
      ?? ChatHomeRowsCache.rows(userID: config.userID).first(where: \.isSavedMessages)
    if let resolvedSavedMessagesRow {
      combinedRows = [resolvedSavedMessagesRow] + filteredRows
    } else {
      combinedRows = filteredRows
    }
    ChatHomeRowsCache.store(combinedRows, userID: config.userID)
    return combinedRows
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

  private static func fetchSavedMessagesRow(
    config: AppSessionConfig,
    session: URLSession
  ) async -> ChatHomeListRow? {
    guard let request = try? buildSavedMessagesRequest(config: config) else { return nil }

    do {
      let (data, response) = try await session.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else { return nil }
      guard (200...299).contains(httpResponse.statusCode) else { return nil }

      let messages = try parsePayload(data)
      guard !messages.isEmpty else { return nil }

      let latestMessage = messages.max { lhs, rhs in
        savedMessageTimestamp(lhs) < savedMessageTimestamp(rhs)
      }

      return ChatHomeListRow(
        chatId: "saved_messages",
        title: "Saved Messages",
        preview: latestMessage.map(ChatHomeListRow.homePreviewText(from:)) ?? "",
        timeLabel: latestMessage.map(ChatHomeListRow.homeTimeLabel(from:)) ?? "",
        unreadCount: 0,
        markedUnread: false,
        muted: false,
        pinned: true,
        isTyping: false,
        isOnline: false,
        peerUserId: nil,
        avatarUri: nil,
        avatarFallback: "V",
        avatarGradientStartLight: nil,
        avatarGradientEndLight: nil,
        avatarGradientStartDark: nil,
        avatarGradientEndDark: nil,
        isSavedMessages: true,
        type: "saved_messages",
        isGroup: false,
        previewRows: [],
        initialMessages: ChatHomeListRow.parseServerMessages(messages)
      )
    } catch {
      return nil
    }
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

  private static func buildSavedMessagesRequest(config: AppSessionConfig) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard
      let encodedUserID = config.userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(pathBase)/saved_messages/\(encodedUserID)")
    else {
      throw ChatHomeServiceError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 18
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func savedMessageTimestamp(_ raw: [String: Any]) -> Int64 {
    if let value = raw["timestamp"] as? NSNumber {
      return value.int64Value
    }
    if let value = raw["timestamp"] as? String {
      return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    return 0
  }

  private static func firstURLError(in error: Error) -> URLError? {
    if let urlError = error as? URLError {
      return urlError
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
      return URLError(URLError.Code(rawValue: nsError.code))
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return firstURLError(in: underlying)
    }
    return nil
  }
}

private enum ChatHomeRowsCache {
  private static let keyPrefix = "vibe.ios.chatHome.rows.v1"

  static func rows(userID: String) -> [ChatHomeListRow] {
    let defaults = UserDefaults.standard
    guard let data = defaults.data(forKey: cacheKey(userID: userID)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      NSLog("[ChatHomeRowsCache] restored rows=0 user=%@", String(userID.prefix(8)))
      return []
    }
    let rows = object.compactMap(ChatHomeListRow.parse)
    NSLog("[ChatHomeRowsCache] restored rows=%d user=%@", rows.count, String(userID.prefix(8)))
    return rows
  }

  static func store(_ rows: [ChatHomeListRow], userID: String) {
    var payload = rows.map { $0.cachePayload() }
    if !JSONSerialization.isValidJSONObject(payload) {
      payload = rows.map { $0.cachePayload(messageLimit: 0) }
    }
    guard JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
    else {
      NSLog("[ChatHomeRowsCache] skipped invalid payload rows=%d", rows.count)
      return
    }
    UserDefaults.standard.set(data, forKey: cacheKey(userID: userID))
    UserDefaults.standard.synchronize()
    NSLog("[ChatHomeRowsCache] stored rows=%d user=%@", rows.count, String(userID.prefix(8)))
  }

  private static func cacheKey(userID: String) -> String {
    let safeUserID =
      userID
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .unicodeScalars
      .map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
      }
    let suffix = String(safeUserID).isEmpty ? "default" : String(safeUserID)
    return "\(keyPrefix).\(suffix)"
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
