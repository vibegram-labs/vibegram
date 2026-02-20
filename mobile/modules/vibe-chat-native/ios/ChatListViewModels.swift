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
  let shape: BubbleShape
  let messageType: String
  let mediaUrl: String?
  let fileName: String?
  let duration: Double?
  let waveform: [CGFloat]?
  let isVideoNote: Bool
  let uploadProgress: Double?

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
    messageId = message["id"] as? String
    messageType = ((message["type"] as? String) ?? "text").lowercased()
    shape = BubbleShape.from(raw: message["bubbleShape"] as? [String: Any], isMe: isMe)

    let metadata = message["metadata"] as? [String: Any]
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

    let mediaUrlCandidates: [String?] = [
      mediaUrl1, mediaUrl2, mediaUrl3, mediaUrl4, mediaUrl5,
      metaUrl1, metaUrl2, metaUrl3, metaUrl4, metaUrl5,
    ]
    mediaUrl = mediaUrlCandidates.compactMap { value in
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
  let normalized = mapped
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
    && lhs.status == rhs.status && lhs.isEdited == rhs.isEdited && lhs.isPinned == rhs.isPinned
    && lhs.messageId == rhs.messageId && lhs.messageType == rhs.messageType
    && lhs.mediaUrl == rhs.mediaUrl && lhs.fileName == rhs.fileName
    && optionalDoubleEqual(lhs.duration, rhs.duration) && lhs.isVideoNote == rhs.isVideoNote
    && optionalWaveformEqual(lhs.waveform, rhs.waveform)
    && optionalDoubleEqual(lhs.uploadProgress, rhs.uploadProgress)
    && bubbleShapeEqual(lhs.shape, rhs.shape)
}

struct SendTransitionPayload {
  let messageId: String
  let text: String
  let timestamp: String
  let startRect: CGRect
  let backgroundStartRect: CGRect?
  /// Live snapshot of the input text view, captured before clearText().
  /// When present the overlay factory uses this instead of a synthetic UILabel
  /// for a pixel-accurate crossfade.
  var sourceTextContentView: UIView?

  /// Direct initializer for native send (no bridge, no parsing).
  init(
    messageId: String,
    text: String,
    timestamp: String,
    startRect: CGRect,
    backgroundStartRect: CGRect? = nil,
    sourceTextContentView: UIView? = nil
  ) {
    self.messageId = messageId
    self.text = text
    self.timestamp = timestamp
    self.startRect = startRect
    self.backgroundStartRect = backgroundStartRect
    self.sourceTextContentView = sourceTextContentView
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

    var backgroundStartRect: CGRect?
    if let bgX = number("startBackgroundX"),
      let bgY = number("startBackgroundY"),
      let bgWidth = number("startBackgroundWidth"),
      let bgHeight = number("startBackgroundHeight")
    {
      backgroundStartRect = rectInHost(x: bgX, y: bgY, width: bgWidth, height: bgHeight)
    }

    self.messageId = messageId
    self.text = text
    self.timestamp = timestamp
    self.startRect = textStartRect
    self.backgroundStartRect = backgroundStartRect
  }
}
