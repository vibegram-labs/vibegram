import Foundation

struct ChatNativeHomeListRow {
  private static let fallbackAPIBaseURL = "https://modest-recreation-production-8329.up.railway.app"
  let chatId: String
  let title: String
  let preview: String
  let timeLabel: String
  let unreadCount: Int
  let markedUnread: Bool
  let muted: Bool
  let pinned: Bool
  let isTyping: Bool
  let isOnline: Bool
  let peerUserId: String?
  let avatarUri: String?
  let avatarFallback: String
  let isSavedMessages: Bool
  let type: String?
  let isGroup: Bool
  let previewRows: [[String: Any]]

  func withPresence(isTyping: Bool, isOnline: Bool) -> ChatNativeHomeListRow {
    ChatNativeHomeListRow(
      chatId: chatId,
      title: title,
      preview: preview,
      timeLabel: timeLabel,
      unreadCount: unreadCount,
      markedUnread: markedUnread,
      muted: muted,
      pinned: pinned,
      isTyping: isTyping,
      isOnline: isOnline,
      peerUserId: peerUserId,
      avatarUri: avatarUri,
      avatarFallback: avatarFallback,
      isSavedMessages: isSavedMessages,
      type: type,
      isGroup: isGroup,
      previewRows: previewRows
    )
  }

  static func parse(_ raw: [String: Any]) -> ChatNativeHomeListRow? {
    guard let chatId = normalizedString(raw["chatId"] ?? raw["chat_id"]), !chatId.isEmpty else {
      return nil
    }
    let isSavedMessages = chatId == "saved_messages"
    let title =
      normalizedString(raw["name"] ?? raw["title"] ?? raw["chatName"] ?? raw["chat_name"])
      ?? "Unknown"
    let preview = normalizedString(raw["preview"] ?? raw["subtitle"]) ?? ""
    let timeLabel = normalizedString(raw["timeLabel"] ?? raw["time_label"] ?? raw["time"]) ?? ""
    let unreadCount = parseInt(raw["unreadCount"] ?? raw["unread_count"]) ?? 0
    let markedUnread = parseBool(raw["markedUnread"] ?? raw["marked_unread"]) ?? false
    let muted = parseBool(raw["muted"]) ?? false
    let pinned = parseBool(raw["pinned"]) ?? false
    let isTyping = parseBool(raw["isTyping"] ?? raw["is_typing"]) ?? false
    let isOnline = parseBool(raw["isOnline"] ?? raw["is_online"]) ?? false
    let friendId = normalizedString(raw["friendId"] ?? raw["friend_id"])
    let peerUserId = friendId
    let rawAvatar =
      normalizedString(
        raw["avatarUri"] ?? raw["avatar_uri"] ?? raw["friendImage"] ?? raw["friend_image"]
          ?? raw["avatarUrl"] ?? raw["avatar_url"])
    let avatarUri = resolveAvatarURI(rawAvatar: rawAvatar, friendId: friendId, chatId: chatId)
    let avatarFallback =
      normalizedString(raw["avatarFallback"] ?? raw["avatar_fallback"])
      ?? String(title.prefix(1)).uppercased()
    let type = normalizedString(raw["type"] ?? raw["chatType"] ?? raw["chat_type"])
    let isGroup =
      parseBool(raw["isGroup"] ?? raw["is_group"]) ?? (type == "group" || type == "channel")
    let previewRows = parsePreviewRows(raw["previewRows"] ?? raw["preview_rows"])

    return ChatNativeHomeListRow(
      chatId: chatId,
      title: title,
      preview: preview,
      timeLabel: timeLabel,
      unreadCount: max(0, unreadCount),
      markedUnread: markedUnread,
      muted: muted,
      pinned: pinned,
      isTyping: isTyping,
      isOnline: isOnline,
      peerUserId: peerUserId,
      avatarUri: avatarUri,
      avatarFallback: avatarFallback,
      isSavedMessages: isSavedMessages,
      type: type,
      isGroup: isGroup,
      previewRows: previewRows
    )
  }

  private static func parsePreviewRows(_ value: Any?) -> [[String: Any]] {
    guard let array = value as? [Any], !array.isEmpty else { return [] }
    return array.compactMap { item in
      item as? [String: Any]
    }
  }

  private static func resolveAvatarURI(rawAvatar: String?, friendId: String?, chatId: String)
    -> String?
  {
    if chatId == "saved_messages" {
      return nil
    }
    let apiBaseURL = resolvedAPIBaseURL()
    if let friendId, let apiBaseURL {
      return pushAvatarURL(baseURL: apiBaseURL, userId: friendId)
    }
    guard let rawAvatar else { return nil }
    let trimmed = rawAvatar.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if isHTTPURL(trimmed) {
      return trimmed
    }
    if trimmed.hasPrefix("/"), let apiBaseURL {
      return URL(string: trimmed, relativeTo: apiBaseURL)?.absoluteURL.absoluteString
    }
    return nil
  }

  private static func resolvedAPIBaseURL() -> URL? {
    let config = ChatEngineStore.shared.getConfig()
    if let explicit = normalizedString(config["apiBaseUrl"] ?? config["baseUrl"]),
      let url = URL(string: explicit)
    {
      return url
    }
    guard let socketURLString = normalizedString(config["socketUrl"] ?? config["url"]),
      var components = URLComponents(string: socketURLString)
    else {
      return URL(string: fallbackAPIBaseURL)
    }
    if components.scheme == "wss" { components.scheme = "https" }
    if components.scheme == "ws" { components.scheme = "http" }
    if components.path.hasSuffix("/socket") {
      components.path = String(components.path.dropLast("/socket".count))
    }
    if components.path.hasSuffix("/websocket") {
      components.path = String(components.path.dropLast("/websocket".count))
    }
    return components.url ?? URL(string: fallbackAPIBaseURL)
  }

  private static func pushAvatarURL(baseURL: URL, userId: String) -> String? {
    guard !userId.isEmpty else { return nil }
    let hasApiSuffix = baseURL.path.lowercased().hasSuffix("/api")
    var url = baseURL
    if !hasApiSuffix {
      url = url.appendingPathComponent("api")
    }
    return url.appendingPathComponent("push").appendingPathComponent("avatar")
      .appendingPathComponent(
        userId
      ).absoluteString
  }

  private static func isHTTPURL(_ value: String) -> Bool {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "https" || scheme == "http"
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

  private static func parseInt(_ value: Any?) -> Int? {
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = value as? String {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private static func parseBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
      return value
    }
    if let value = value as? NSNumber {
      return value.boolValue
    }
    if let value = value as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on":
        return true
      case "0", "false", "no", "off":
        return false
      default:
        return nil
      }
    }
    return nil
  }
}
