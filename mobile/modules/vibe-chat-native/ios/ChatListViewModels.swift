import UIKit

final class ChatListRegistry {
  static let shared = ChatListRegistry()

  private final class WeakRef {
    weak var value: ChatListView?

    init(_ value: ChatListView) {
      self.value = value
    }
  }

  private var map: [String: WeakRef] = [:]

  func register(surfaceId: String, view: ChatListView) {
    map[surfaceId] = WeakRef(view)
  }

  func view(for surfaceId: String) -> ChatListView? {
    if let value = map[surfaceId]?.value {
      return value
    }
    map.removeValue(forKey: surfaceId)
    return nil
  }
}

struct BubbleShape {
  let isMe: Bool
  let showTail: Bool
  let borderTopLeftRadius: CGFloat
  let borderTopRightRadius: CGFloat
  let borderBottomLeftRadius: CGFloat
  let borderBottomRightRadius: CGFloat

  static func from(raw: [String: Any]?, isMe: Bool) -> BubbleShape {
    let fallback =
      isMe
      ? BubbleShape(
        isMe: true, showTail: true, borderTopLeftRadius: 18, borderTopRightRadius: 18,
        borderBottomLeftRadius: 18, borderBottomRightRadius: 18)
      : BubbleShape(
        isMe: false, showTail: true, borderTopLeftRadius: 18, borderTopRightRadius: 18,
        borderBottomLeftRadius: 18, borderBottomRightRadius: 18)
    guard let raw else {
      return fallback
    }
    return BubbleShape(
      isMe: isMe,
      showTail: (raw["showTail"] as? Bool) ?? true,
      borderTopLeftRadius: CGFloat((raw["borderTopLeftRadius"] as? NSNumber)?.doubleValue ?? 18),
      borderTopRightRadius: CGFloat((raw["borderTopRightRadius"] as? NSNumber)?.doubleValue ?? 18),
      borderBottomLeftRadius: CGFloat(
        (raw["borderBottomLeftRadius"] as? NSNumber)?.doubleValue ?? 18),
      borderBottomRightRadius: CGFloat(
        (raw["borderBottomRightRadius"] as? NSNumber)?.doubleValue ?? 18)
    )
  }
}

struct ChatListRow {
  enum Kind {
    case day
    case message
  }

  enum MessageVisualKind {
    case text
    case voice
    case video
    case videoNote
    case media
  }

  let kind: Kind
  let key: String
  let label: String
  let text: String
  let timestamp: String
  let isMe: Bool
  let status: String?
  let isEdited: Bool
  let isPinned: Bool
  let messageId: String?
  let reactionEmoji: String?
  let shape: BubbleShape
  let messageType: String
  let mediaUrl: String?
  let fileName: String?
  let duration: Double?
  let waveform: [CGFloat]?
  let isVideoNote: Bool
  let uploadProgress: Double?

  // Agent message fields
  let isAgentMessage: Bool
  let agentName: String?
  let plainContent: String?

  var visualKind: MessageVisualKind {
    guard kind == .message else {
      return .text
    }
    if isVideoNote {
      return .videoNote
    }
    switch messageType {
    case "voice", "music":
      return .voice
    case "video":
      return .video
    case "image", "gif", "sticker", "file":
      return .media
    default:
      return .text
    }
  }

  static func typingIndicator() -> ChatListRow {
    if let row = ChatListRow(raw: [
      "kind": "message",
      "key": "peer-typing-indicator",
      "message": [
        "id": "peer-typing-indicator",
        "text": "Typing...",
        "timestamp": "",
        "isMe": false,
        "type": "typing",
        "bubbleShape": [
          "showTail": false,
          "borderTopLeftRadius": 18,
          "borderTopRightRadius": 18,
          "borderBottomLeftRadius": 4,
          "borderBottomRightRadius": 18,
        ],
      ],
    ]) {
      return row
    }

    // Guaranteed fallback for malformed payloads.
    return ChatListRow(raw: [
      "kind": "day",
      "key": "peer-typing-indicator-fallback",
      "label": "",
    ])!
  }

  var shouldShowUploadOverlay: Bool {
    guard isMe else {
      return false
    }
    let normalized = status?.lowercased() ?? ""
    return normalized == "sending" || normalized == "pending"
  }

  init?(raw: [String: Any]) {
    guard let kindRaw = raw["kind"] as? String else {
      return nil
    }
    let keyValue =
      (raw["key"] as? String)?.isEmpty == false ? (raw["key"] as? String)! : UUID().uuidString
    key = keyValue

    if kindRaw == "day" {
      kind = .day
      label = (raw["label"] as? String) ?? ""
      text = ""
      timestamp = ""
      isMe = false
      status = nil
      isEdited = false
      isPinned = false
      messageId = nil
      reactionEmoji = nil
      shape = BubbleShape(
        isMe: false, showTail: false, borderTopLeftRadius: 18, borderTopRightRadius: 18,
        borderBottomLeftRadius: 18, borderBottomRightRadius: 18)
      messageType = "text"
      mediaUrl = nil
      fileName = nil
      duration = nil
      waveform = nil
      isVideoNote = false
      uploadProgress = nil
      isAgentMessage = false
      agentName = nil
      plainContent = nil
      return
    }

    guard kindRaw == "message", let message = raw["message"] as? [String: Any] else {
      return nil
    }
    kind = .message
    label = ""
    text = (message["text"] as? String) ?? ""
    timestamp = (message["timestamp"] as? String) ?? ""
    isMe = (message["isMe"] as? Bool) ?? false
    status = message["status"] as? String
    isEdited = (message["isEdited"] as? Bool) ?? false
    isPinned = (message["isPinned"] as? Bool) ?? false
    messageId = parseNonEmptyString(message["id"])
    reactionEmoji = message["reactionEmoji"] as? String
    messageType = ((message["type"] as? String) ?? "text").lowercased()
    shape = BubbleShape.from(raw: message["bubbleShape"] as? [String: Any], isMe: isMe)

    let metadata = message["metadata"] as? [String: Any]
    let localMediaUrl1 = message["localMediaUrl"] as? String
    let localMediaUrl2 = message["local_media_url"] as? String
    let metaLocalMediaUrl1 = metadata?["localMediaUrl"] as? String
    let metaLocalMediaUrl2 = metadata?["local_media_url"] as? String
    let mediaUrl1 = message["mediaUrl"] as? String
    let mediaUrl2 = message["media_url"] as? String
    let mediaUrl3 = message["uri"] as? String
    let mediaUrl4 = message["audioUrl"] as? String
    let mediaUrl5 = message["audio_url"] as? String
    let metaUrl1 = metadata?["mediaUrl"] as? String
    let metaUrl2 = metadata?["media_url"] as? String
    let metaUrl3 = metadata?["uri"] as? String
    let metaUrl4 = metadata?["audioUrl"] as? String
    let metaUrl5 = metadata?["audio_url"] as? String

    let isVoiceLike = messageType == "voice" || messageType == "music"
    var mediaUrlCandidates: [String?] = []
    if isVoiceLike {
      mediaUrlCandidates.append(contentsOf: [
        localMediaUrl1, localMediaUrl2, metaLocalMediaUrl1, metaLocalMediaUrl2,
      ])
    }
    mediaUrlCandidates.append(contentsOf: [
      mediaUrl1, mediaUrl2, mediaUrl3, mediaUrl4, mediaUrl5,
      metaUrl1, metaUrl2, metaUrl3, metaUrl4, metaUrl5,
    ])
    mediaUrl =
      mediaUrlCandidates.compactMap { value in
        guard let value, !value.isEmpty else { return nil }
        return value
      }.first
    fileName =
      (message["fileName"] as? String)
      ?? (message["file_name"] as? String)
      ?? (metadata?["fileName"] as? String)
      ?? (metadata?["file_name"] as? String)
    duration =
      parseDouble(message["duration"])
      ?? parseDouble(metadata?["duration"])
    waveform =
      parseWaveform(message["waveform"])
      ?? parseWaveform(metadata?["waveform"])
    isVideoNote =
      (message["isVideoNote"] as? Bool)
      ?? (metadata?["isVideoNote"] as? Bool)
      ?? false
    uploadProgress =
      parseDouble(message["uploadProgress"])
      ?? parseDouble(message["upload_progress"])
      ?? parseDouble(metadata?["uploadProgress"])
      ?? parseDouble(metadata?["upload_progress"])

    // Agent message fields
    isAgentMessage = (message["isAgentMessage"] as? Bool) ?? false
    agentName = message["agentName"] as? String
    plainContent = message["plainContent"] as? String
  }
}

private func bubbleShapeEqual(_ lhs: BubbleShape, _ rhs: BubbleShape) -> Bool {
  let epsilon: CGFloat = 0.1
  return lhs.isMe == rhs.isMe && lhs.showTail == rhs.showTail
    && abs(lhs.borderTopLeftRadius - rhs.borderTopLeftRadius) <= epsilon
    && abs(lhs.borderTopRightRadius - rhs.borderTopRightRadius) <= epsilon
    && abs(lhs.borderBottomLeftRadius - rhs.borderBottomLeftRadius) <= epsilon
    && abs(lhs.borderBottomRightRadius - rhs.borderBottomRightRadius) <= epsilon
}

private func parseDouble(_ raw: Any?) -> Double? {
  if let value = raw as? NSNumber {
    return value.doubleValue
  }
  if let value = raw as? Double {
    return value
  }
  if let value = raw as? Int {
    return Double(value)
  }
  if let value = raw as? String {
    return Double(value)
  }
  return nil
}

private func parseNonEmptyString(_ raw: Any?) -> String? {
  if let value = raw as? String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if let value = raw as? NSNumber {
    return value.stringValue
  }
  if let value = raw as? Int {
    return String(value)
  }
  if let value = raw as? Double, value.isFinite {
    return String(value)
  }
  return nil
}

private func parseWaveform(_ raw: Any?) -> [CGFloat]? {
  guard let array = raw as? [Any], !array.isEmpty else {
    return nil
  }
  let mapped: [CGFloat] = array.compactMap { item in
    if let num = item as? NSNumber {
      return CGFloat(truncating: num)
    }
    if let dbl = item as? Double {
      return CGFloat(dbl)
    }
    if let int = item as? Int {
      return CGFloat(int)
    }
    if let str = item as? String, let dbl = Double(str) {
      return CGFloat(dbl)
    }
    return nil
  }
  let normalized =
    mapped
    .filter { $0.isFinite }
    .map { max(0.0, min(1.0, $0)) }
  return normalized.isEmpty ? nil : normalized
}

private func optionalDoubleEqual(_ lhs: Double?, _ rhs: Double?, epsilon: Double = 0.0001) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil):
    return true
  case (let l?, let r?):
    return abs(l - r) <= epsilon
  default:
    return false
  }
}

private func optionalWaveformEqual(_ lhs: [CGFloat]?, _ rhs: [CGFloat]?, epsilon: CGFloat = 0.001)
  -> Bool
{
  switch (lhs, rhs) {
  case (nil, nil):
    return true
  case (let l?, let r?):
    guard l.count == r.count else { return false }
    for (a, b) in zip(l, r) {
      if abs(a - b) > epsilon {
        return false
      }
    }
    return true
  default:
    return false
  }
}

func chatListRowContentEqual(_ lhs: ChatListRow, _ rhs: ChatListRow) -> Bool {
  return lhs.kind == rhs.kind && lhs.key == rhs.key && lhs.label == rhs.label
    && lhs.text == rhs.text && lhs.timestamp == rhs.timestamp && lhs.isMe == rhs.isMe
    && lhs.status == rhs.status
    && lhs.isEdited == rhs.isEdited && lhs.isPinned == rhs.isPinned
    && lhs.messageId == rhs.messageId && lhs.reactionEmoji == rhs.reactionEmoji
    && lhs.messageType == rhs.messageType
    && lhs.mediaUrl == rhs.mediaUrl && lhs.fileName == rhs.fileName
    && optionalDoubleEqual(lhs.duration, rhs.duration) && lhs.isVideoNote == rhs.isVideoNote
    && optionalWaveformEqual(lhs.waveform, rhs.waveform)
    && optionalDoubleEqual(lhs.uploadProgress, rhs.uploadProgress)
    && bubbleShapeEqual(lhs.shape, rhs.shape)
    && lhs.isAgentMessage == rhs.isAgentMessage
    && lhs.agentName == rhs.agentName
    && lhs.plainContent == rhs.plainContent
}

struct SendTransitionPayload {
  let messageId: String
  let text: String
  let timestamp: String
  /// Legacy source text rect in host coordinates.
  /// Still accepted for backward compatibility with existing JS payloads.
  let startRect: CGRect
  /// Legacy source background rect in host coordinates.
  /// Still accepted for backward compatibility with existing JS payloads.
  let backgroundStartRect: CGRect?
  /// Telegram-style source container rect in host coordinates.
  /// This is the coordinate space for sourceBackgroundRectInContainer/sourceContentRectInContainer.
  let sourceContainerRect: CGRect?
  /// Source background rect in source-container local coordinates.
  let sourceBackgroundRectInContainer: CGRect?
  /// Source content rect in source-container local coordinates.
  let sourceContentRectInContainer: CGRect?
  /// Source text content scroll offset (used to align destination text motion).
  let sourceScrollOffset: CGFloat
  /// Optional live source background snapshot captured before input clear.
  var sourceBackgroundSnapshotView: UIView?
  /// Optional live source content snapshot captured before input clear.
  var sourceContentSnapshotView: UIView?

  var resolvedSourceContainerRect: CGRect {
    if let sourceContainerRect {
      return sourceContainerRect
    }
    if let backgroundStartRect {
      return backgroundStartRect
    }
    return startRect
  }

  var resolvedSourceBackgroundRect: CGRect {
    if let sourceContainerRect, let sourceBackgroundRectInContainer {
      return CGRect(
        x: sourceContainerRect.minX + sourceBackgroundRectInContainer.minX,
        y: sourceContainerRect.minY + sourceBackgroundRectInContainer.minY,
        width: sourceBackgroundRectInContainer.width,
        height: sourceBackgroundRectInContainer.height
      )
    }
    if let backgroundStartRect {
      return backgroundStartRect
    }
    return startRect
  }

  var resolvedSourceContentRect: CGRect {
    if let sourceContainerRect, let sourceContentRectInContainer {
      return CGRect(
        x: sourceContainerRect.minX + sourceContentRectInContainer.minX,
        y: sourceContainerRect.minY + sourceContentRectInContainer.minY,
        width: sourceContentRectInContainer.width,
        height: sourceContentRectInContainer.height
      )
    }
    return startRect
  }

  /// Direct initializer for native send (no bridge, no parsing).
  init(
    messageId: String,
    text: String,
    timestamp: String,
    startRect: CGRect,
    backgroundStartRect: CGRect? = nil,
    sourceContainerRect: CGRect? = nil,
    sourceBackgroundRectInContainer: CGRect? = nil,
    sourceContentRectInContainer: CGRect? = nil,
    sourceScrollOffset: CGFloat = 0.0,
    sourceBackgroundSnapshotView: UIView? = nil,
    sourceContentSnapshotView: UIView? = nil
  ) {
    self.messageId = messageId
    self.text = text
    self.timestamp = timestamp
    self.startRect = startRect
    if let backgroundStartRect {
      self.backgroundStartRect = backgroundStartRect
    } else if let sourceContainerRect, let sourceBackgroundRectInContainer {
      self.backgroundStartRect = CGRect(
        x: sourceContainerRect.minX + sourceBackgroundRectInContainer.minX,
        y: sourceContainerRect.minY + sourceBackgroundRectInContainer.minY,
        width: sourceBackgroundRectInContainer.width,
        height: sourceBackgroundRectInContainer.height
      )
    } else {
      self.backgroundStartRect = nil
    }
    self.sourceContainerRect = sourceContainerRect
    self.sourceBackgroundRectInContainer = sourceBackgroundRectInContainer
    self.sourceContentRectInContainer = sourceContentRectInContainer
    self.sourceScrollOffset = sourceScrollOffset
    self.sourceBackgroundSnapshotView = sourceBackgroundSnapshotView
    self.sourceContentSnapshotView = sourceContentSnapshotView
  }

  init?(payload: [String: Any], hostView: UIView) {
    guard let messageId = payload["messageId"] as? String, !messageId.isEmpty else {
      return nil
    }
    let text = (payload["text"] as? String) ?? ""
    let timestamp = (payload["timestamp"] as? String) ?? ""

    func number(_ key: String) -> CGFloat? {
      if let value = payload[key] as? NSNumber {
        return CGFloat(value.doubleValue)
      }
      if let value = payload[key] as? Double {
        return CGFloat(value)
      }
      if let value = payload[key] as? Int {
        return CGFloat(value)
      }
      if let value = payload[key] as? String, let parsed = Double(value) {
        return CGFloat(parsed)
      }
      return nil
    }

    guard
      let startX = number("startX"),
      let startY = number("startY"),
      let startWidth = number("startWidth"),
      let startHeight = number("startHeight")
    else {
      return nil
    }

    func rectInHost(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
      let originInHost: CGPoint
      if let window = hostView.window {
        originInHost = hostView.convert(CGPoint(x: x, y: y), from: window)
      } else {
        originInHost = CGPoint(x: x, y: y)
      }
      return CGRect(x: originInHost.x, y: originInHost.y, width: width, height: height)
    }

    let textStartRect = rectInHost(x: startX, y: startY, width: startWidth, height: startHeight)

    var parsedBackgroundStartRect: CGRect?
    if let bgX = number("startBackgroundX"),
      let bgY = number("startBackgroundY"),
      let bgWidth = number("startBackgroundWidth"),
      let bgHeight = number("startBackgroundHeight")
    {
      parsedBackgroundStartRect = rectInHost(x: bgX, y: bgY, width: bgWidth, height: bgHeight)
    }

    var parsedContentStartRect: CGRect?
    if let contentX = number("startContentX"),
      let contentY = number("startContentY"),
      let contentWidth = number("startContentWidth"),
      let contentHeight = number("startContentHeight")
    {
      parsedContentStartRect = rectInHost(
        x: contentX,
        y: contentY,
        width: contentWidth,
        height: contentHeight
      )
    }

    var parsedSourceContainerRect: CGRect?
    if let containerX = number("sourceContainerX"),
      let containerY = number("sourceContainerY"),
      let containerWidth = number("sourceContainerWidth"),
      let containerHeight = number("sourceContainerHeight")
    {
      parsedSourceContainerRect = rectInHost(
        x: containerX,
        y: containerY,
        width: containerWidth,
        height: containerHeight
      )
    }

    let sourceContainerRect =
      parsedSourceContainerRect
      ?? parsedBackgroundStartRect
      ?? parsedContentStartRect
      ?? textStartRect

    let sourceBackgroundRectInContainer: CGRect? = {
      guard let parsedBackgroundStartRect else { return nil }
      return CGRect(
        x: parsedBackgroundStartRect.minX - sourceContainerRect.minX,
        y: parsedBackgroundStartRect.minY - sourceContainerRect.minY,
        width: parsedBackgroundStartRect.width,
        height: parsedBackgroundStartRect.height
      )
    }()

    let resolvedContentStartRect = parsedContentStartRect ?? textStartRect
    let sourceContentRectInContainer = CGRect(
      x: resolvedContentStartRect.minX - sourceContainerRect.minX,
      y: resolvedContentStartRect.minY - sourceContainerRect.minY,
      width: resolvedContentStartRect.width,
      height: resolvedContentStartRect.height
    )

    let sourceScrollOffset = number("sourceScrollOffset") ?? 0.0

    self.messageId = messageId
    self.text = text
    self.timestamp = timestamp
    self.startRect = textStartRect
    self.backgroundStartRect = parsedBackgroundStartRect
    self.sourceContainerRect = sourceContainerRect
    self.sourceBackgroundRectInContainer = sourceBackgroundRectInContainer
    self.sourceContentRectInContainer = sourceContentRectInContainer
    self.sourceScrollOffset = sourceScrollOffset
    self.sourceBackgroundSnapshotView = nil
    self.sourceContentSnapshotView = nil
  }
}
