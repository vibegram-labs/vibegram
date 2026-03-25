import Foundation
import UIKit

enum ChatNativeAvatarURLResolver {
  private static let fallbackAPIBaseURL =
    "https://api.vibegram.io"

  static func resolve(
    rawAvatar: String?,
    peerUserId: String? = nil,
    chatId: String? = nil,
    preferPushAvatar: Bool = false
  ) -> String? {
    if chatId == "saved_messages" {
      return nil
    }

    let apiBaseURL = resolvedAPIBaseURL()
    if preferPushAvatar,
      let normalizedPeerUserId = normalizedString(peerUserId),
      let apiBaseURL
    {
      return pushAvatarURL(baseURL: apiBaseURL, userId: normalizedPeerUserId)
    }

    guard let trimmed = normalizedString(rawAvatar) else { return nil }
    if isHTTPURL(trimmed) {
      return trimmed
    }
    if trimmed.hasPrefix("/"), let apiBaseURL {
      return URL(string: trimmed, relativeTo: apiBaseURL)?.absoluteURL.absoluteString
    }
    return nil
  }

  static func resolvedAPIBaseURL() -> URL? {
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
    return url.appendingPathComponent("push")
      .appendingPathComponent("avatar")
      .appendingPathComponent(userId)
      .absoluteString
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
}

struct ChatNativeHomeListRow {
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
  let avatarGradientStartLight: String?
  let avatarGradientEndLight: String?
  let avatarGradientStartDark: String?
  let avatarGradientEndDark: String?
  let isSavedMessages: Bool
  let type: String?
  let isGroup: Bool
  let previewRows: [[String: Any]]

  func withPresence(isTyping: Bool, isOnline: Bool, preview: String? = nil) -> ChatNativeHomeListRow {
    ChatNativeHomeListRow(
      chatId: chatId,
      title: title,
      preview: preview ?? self.preview,
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
      avatarGradientStartLight: avatarGradientStartLight,
      avatarGradientEndLight: avatarGradientEndLight,
      avatarGradientStartDark: avatarGradientStartDark,
      avatarGradientEndDark: avatarGradientEndDark,
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
    let avatarGradientStartLight =
      normalizedString(raw["avatarGradientStartLight"] ?? raw["avatar_gradient_start_light"])
    let avatarGradientEndLight =
      normalizedString(raw["avatarGradientEndLight"] ?? raw["avatar_gradient_end_light"])
    let avatarGradientStartDark =
      normalizedString(raw["avatarGradientStartDark"] ?? raw["avatar_gradient_start_dark"])
    let avatarGradientEndDark =
      normalizedString(raw["avatarGradientEndDark"] ?? raw["avatar_gradient_end_dark"])
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
      avatarGradientStartLight: avatarGradientStartLight,
      avatarGradientEndLight: avatarGradientEndLight,
      avatarGradientStartDark: avatarGradientStartDark,
      avatarGradientEndDark: avatarGradientEndDark,
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
    return ChatNativeAvatarURLResolver.resolve(
      rawAvatar: rawAvatar,
      peerUserId: friendId,
      chatId: chatId,
      preferPushAvatar: true
    )
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

enum ChatNativeHomeSwipeEdge {
  case leading
  case trailing
}

struct ChatNativeHomeSwipeActionSpec {
  let eventType: String
  let title: String
  let systemImageName: String
  let backgroundColor: UIColor
  let foregroundColor: UIColor
  let style: UIContextualAction.Style
  let isFullSwipeTarget: Bool
}

extension ChatNativeHomeListRow {
  var leadingSwipeActionSpecs: [ChatNativeHomeSwipeActionSpec] {
    let hasUnread = unreadCount > 0 || markedUnread
    return [
      ChatNativeHomeSwipeActionSpec(
        eventType: "swipePin",
        title: pinned ? "Unpin" : "Pin",
        systemImageName: pinned ? "pin.slash.fill" : "pin.fill",
        backgroundColor: ChatNativeHomeSwipePalette.pin,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: true
      ),
      ChatNativeHomeSwipeActionSpec(
        eventType: "swipeMarkRead",
        title: hasUnread ? "Read" : "Unread",
        systemImageName: hasUnread ? "message.fill" : "circle.fill",
        backgroundColor: ChatNativeHomeSwipePalette.read,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: false
      ),
    ]
  }

  var trailingSwipeActionSpecs: [ChatNativeHomeSwipeActionSpec] {
    [
      ChatNativeHomeSwipeActionSpec(
        eventType: "swipeDelete",
        title: "Delete",
        systemImageName: "trash.fill",
        backgroundColor: ChatNativeHomeSwipePalette.delete,
        foregroundColor: .white,
        style: .destructive,
        isFullSwipeTarget: true
      ),
      ChatNativeHomeSwipeActionSpec(
        eventType: "swipeMute",
        title: muted ? "Unmute" : "Mute",
        systemImageName: muted ? "speaker.wave.2.fill" : "speaker.slash.fill",
        backgroundColor: ChatNativeHomeSwipePalette.mute,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: false
      ),
      ChatNativeHomeSwipeActionSpec(
        eventType: "swipeArchive",
        title: "Archive",
        systemImageName: "archivebox.fill",
        backgroundColor: ChatNativeHomeSwipePalette.archive,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: false
      ),
    ]
  }
}

private enum ChatNativeHomeSwipePalette {
  static let pin = UIColor(red: 0.20, green: 0.47, blue: 0.90, alpha: 1)
  static let read = UIColor(red: 0.24, green: 0.61, blue: 0.86, alpha: 1)
  static let mute = UIColor(red: 0.86, green: 0.53, blue: 0.04, alpha: 1)
  static let delete = UIColor(red: 0.88, green: 0.10, blue: 0.10, alpha: 1)
  static let archive = UIColor(red: 0.51, green: 0.51, blue: 0.53, alpha: 1)
}
