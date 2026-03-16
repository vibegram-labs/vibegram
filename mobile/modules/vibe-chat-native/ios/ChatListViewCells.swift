import AVFoundation
import ImageIO
import Lottie
import UIKit

private let chatCellHoldDebugLogs = true
private let chatCellReactionDebugLogs = true
private let agentBoldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
private let chatMediaImageCache = NSCache<NSString, UIImage>()
private let chatMediaNaturalSizeCache = NSCache<NSString, NSValue>()

// MARK: - Disk-backed image cache

private let chatMediaDiskCacheQueue = DispatchQueue(label: "chat.media.disk-cache", qos: .utility)
private var chatMediaFailedURLs = Set<String>()
private var chatMediaRetryCount: [String: Int] = [:]
private let chatMediaMaxRetries = 3

private func chatMediaDiskCacheDir() -> URL {
  let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
  let dir = caches.appendingPathComponent("chat-media-images", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

/// Strips tracking query params from Giphy (and similar CDN) URLs so the same
/// media content always maps to the same cache key regardless of session tokens.
private func chatMediaNormalizedKey(_ urlString: String) -> String {
  guard var comps = URLComponents(string: urlString),
    let host = comps.host?.lowercased(),
    host.contains("giphy.com")
  else { return urlString }
  // Remove Giphy tracking params — content is identified by path alone
  let trackingParams: Set<String> = ["cid", "rid", "ct", "ep", "r"]
  comps.queryItems = comps.queryItems?.filter { !trackingParams.contains($0.name) }
  if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
  return comps.string ?? urlString
}

private func chatMediaDiskCacheKey(_ urlString: String) -> String {
  let normalized = chatMediaNormalizedKey(urlString)
  // Stable hash — use SHA-like approach via hashValue but make it hex
  let hash = UInt64(bitPattern: Int64(normalized.hashValue))
  // Preserve extension for correct UIImage decoding
  let ext = (urlString as NSString).pathExtension.lowercased()
  let suffix = ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext) ? ".\(ext)" : ".img"
  return "v2-" + String(format: "%016llx", hash) + suffix
}

private func chatMediaShouldAnimate(urlString: String, messageType: String? = nil) -> Bool {
  if messageType == "gif" {
    return true
  }
  let pathExtension: String
  if let url = URL(string: urlString), !url.pathExtension.isEmpty {
    pathExtension = url.pathExtension.lowercased()
  } else {
    pathExtension = (urlString as NSString).pathExtension.lowercased()
  }
  return pathExtension == "gif"
}

private func chatMediaAnimatedFrameDuration(
  at index: Int, source: CGImageSource
) -> TimeInterval {
  guard
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
    let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
  else {
    return 0.1
  }

  let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval
  let delay = gifProperties[kCGImagePropertyGIFDelayTime] as? TimeInterval
  let frameDuration = unclampedDelay ?? delay ?? 0.1
  return frameDuration < 0.011 ? 0.1 : frameDuration
}

private func chatMediaAnimatedImage(from data: Data) -> UIImage? {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
    return nil
  }

  let frameCount = CGImageSourceGetCount(source)
  guard frameCount > 1 else {
    return UIImage(data: data)
  }

  var frames: [UIImage] = []
  frames.reserveCapacity(frameCount)
  var totalDuration: TimeInterval = 0.0

  for index in 0..<frameCount {
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else {
      continue
    }
    frames.append(UIImage(cgImage: cgImage))
    totalDuration += chatMediaAnimatedFrameDuration(at: index, source: source)
  }

  guard !frames.isEmpty else {
    return nil
  }

  return UIImage.animatedImage(with: frames, duration: max(totalDuration, 0.1))
}

private func chatMediaDecodedImage(
  from data: Data, shouldAnimate: Bool
) -> UIImage? {
  if shouldAnimate, let animatedImage = chatMediaAnimatedImage(from: data) {
    return animatedImage
  }
  return UIImage(data: data)
}

private func chatMediaLoadImageFromFile(
  at path: String, shouldAnimate: Bool
) -> UIImage? {
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
  else {
    return nil
  }
  return chatMediaDecodedImage(from: data, shouldAnimate: shouldAnimate)
}

func chatMediaDiskCacheSave(_ data: Data, forKey urlString: String) {
  chatMediaDiskCacheQueue.async {
    let dir = chatMediaDiskCacheDir()
    let filename = chatMediaDiskCacheKey(urlString)
    let fileURL = dir.appendingPathComponent(filename)
    guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try? data.write(to: fileURL, options: [.atomic])
  }
}

func chatMediaDiskCacheLoad(_ urlString: String) -> Data? {
  let dir = chatMediaDiskCacheDir()
  let filename = chatMediaDiskCacheKey(urlString)
  let fileURL = dir.appendingPathComponent(filename)
  guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
  return try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
}

/// Pre-fetches a media URL into the in-memory + disk cache so the cell can
/// display it instantly when the optimistic row appears.
func chatMediaPrefetch(urlString: String, animated: Bool) {
  let cacheKey = chatMediaNormalizedKey(urlString)
  guard !urlString.isEmpty,
    chatMediaImageCache.object(forKey: cacheKey as NSString) == nil,
    !chatMediaFailedURLs.contains(cacheKey),
    let url = URL(string: urlString)
  else { return }
  // Check disk cache first
  if let diskData = chatMediaDiskCacheLoad(cacheKey),
    let diskImage = chatMediaDecodedImage(from: diskData, shouldAnimate: animated)
  {
    chatMediaImageCache.setObject(diskImage, forKey: cacheKey as NSString)
    return
  }
  URLSession.shared.dataTask(with: url) { data, _, error in
    guard error == nil, let data, !data.isEmpty,
      let image = chatMediaDecodedImage(from: data, shouldAnimate: animated)
    else { return }
    chatMediaImageCache.setObject(image, forKey: cacheKey as NSString)
    chatMediaDiskCacheSave(data, forKey: cacheKey)
  }.resume()
}

final class ChatCollectionFlowLayout: UICollectionViewFlowLayout {
  // Telegram approach: cells are ALWAYS fully opaque. No fade-in,
  // no fade-out, no transform. ALL visibility is position-based only.

  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    let attrs =
      super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)?.copy()
      as? UICollectionViewLayoutAttributes
    attrs?.alpha = 1.0
    attrs?.transform = .identity
    return attrs
  }

  override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    let attrs =
      super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)?.copy()
      as? UICollectionViewLayoutAttributes
    attrs?.alpha = 1.0
    attrs?.transform = .identity
    return attrs
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]?
  {
    guard let attributes = super.layoutAttributesForElements(in: rect) else { return nil }
    // During normal scrolling all attributes already have alpha=1.0.
    // Only copy + fix during batch updates when UIKit may animate alpha.
    let needsCorrection = attributes.contains { $0.alpha != 1.0 }
    guard needsCorrection else { return attributes }
    return attributes.map { attr in
      let copy = attr.copy() as! UICollectionViewLayoutAttributes
      copy.alpha = 1.0
      return copy
    }
  }

  override func layoutAttributesForItem(at indexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    let attrs = super.layoutAttributesForItem(at: indexPath)
    attrs?.alpha = 1.0
    return attrs
  }
}

final class BubbleBackgroundView: UIView {
  private let agentBorderLayer = CAShapeLayer()
  private let blurView = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let gradientLayer = CAGradientLayer()
  private let fillLayer = CAShapeLayer()
  private let bubbleMaskLayer = CAShapeLayer()
  private var appearance = ChatListAppearance.fallback
  private var shape = BubbleShape(
    isMe: false, showTail: false, borderTopLeftRadius: 18, borderTopRightRadius: 18,
    borderBottomLeftRadius: 18, borderBottomRightRadius: 18)

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(blurView)
    layer.addSublayer(gradientLayer)
    layer.addSublayer(fillLayer)
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    layer.mask = bubbleMaskLayer
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(isMe: Bool, shape: BubbleShape, hidden: Bool, appearance: ChatListAppearance) {
    let previousShape = self.shape
    self.appearance = appearance
    self.shape = shape

    // Check if only the corner radii changed (sequence boundary update).
    let shapeOnlyChange =
      bounds.width > 0 && bounds.height > 0
      && previousShape.isMe == shape.isMe
      && !hidden
      && (abs(previousShape.borderTopLeftRadius - shape.borderTopLeftRadius) > 0.5
        || abs(previousShape.borderTopRightRadius - shape.borderTopRightRadius) > 0.5
        || abs(previousShape.borderBottomLeftRadius - shape.borderBottomLeftRadius) > 0.5
        || abs(previousShape.borderBottomRightRadius - shape.borderBottomRightRadius) > 0.5)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    isHidden = hidden
    blurView.isHidden = hidden
    blurView.effect = UIBlurEffect(style: isMe ? .systemThinMaterialDark : .systemMaterialDark)
    blurView.alpha = isMe ? 0.34 : 0.44
    gradientLayer.isHidden = !isMe
    gradientLayer.colors = appearance.bubbleMeGradient.map(\.cgColor)
    gradientLayer.opacity = isMe ? 0.88 : 0.0
    fillLayer.fillColor =
      isMe
      ? UIColor.clear.cgColor
      : appearance.bubbleThemColor.withAlphaComponent(appearance.isDark ? 0.86 : 0.90).cgColor
    CATransaction.commit()

    if shapeOnlyChange {
      // Animate the shape path transition smoothly (matching Telegram's feel).
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.25)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
      applyShapePath()
      CATransaction.commit()
    } else if bounds.width > 0 && bounds.height > 0 {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyShapePath()
      CATransaction.commit()
    }
    setNeedsLayout()
  }

  func applyAgentStyle(appearance: ChatListAppearance, isMe: Bool) {
    // Agent bubble: subtle purple tint with border
    let agentColor =
      appearance.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // For agent messages (!isMe), we make the fill translucent them-color
    if !isMe {
      gradientLayer.isHidden = false
      gradientLayer.colors = [
        agentColor.withAlphaComponent(0.22).cgColor,
        agentColor.withAlphaComponent(0.08).cgColor,
      ]
      gradientLayer.opacity = 0.82
      fillLayer.fillColor =
        appearance.bubbleThemColor.withAlphaComponent(appearance.isDark ? 0.86 : 0.90).cgColor
      blurView.alpha = 0.42
    } else {
      // For my agent mentions, just add the glowing border and a slight tint
      gradientLayer.isHidden = false
      gradientLayer.colors = appearance.bubbleMeGradient.map { $0.cgColor }
      gradientLayer.opacity = 0.82
      blurView.alpha = 0.0
    }

    // Agent border
    if agentBorderLayer.superlayer == nil {
      layer.addSublayer(agentBorderLayer)
    }
    agentBorderLayer.fillColor = UIColor.clear.cgColor
    agentBorderLayer.strokeColor = agentColor.withAlphaComponent(isMe ? 0.6 : 0.28).cgColor
    agentBorderLayer.lineWidth = 1.5
    applyAgentBorderPath()
    CATransaction.commit()
  }

  func clearAgentStyle() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    agentBorderLayer.path = nil
    agentBorderLayer.strokeColor = UIColor.clear.cgColor
    CATransaction.commit()
  }

  private func applyAgentBorderPath() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    let path = bubblePath(
      rect: bounds,
      topLeft: shape.borderTopLeftRadius,
      topRight: shape.borderTopRightRadius,
      bottomRight: shape.borderBottomRightRadius,
      bottomLeft: shape.borderBottomLeftRadius
    )
    agentBorderLayer.frame = bounds
    agentBorderLayer.path = path.cgPath
  }

  private func applyShapePath() {
    let path = bubblePath(
      rect: bounds,
      topLeft: shape.borderTopLeftRadius,
      topRight: shape.borderTopRightRadius,
      bottomRight: shape.borderBottomRightRadius,
      bottomLeft: shape.borderBottomLeftRadius
    )
    blurView.frame = bounds
    bubbleMaskLayer.frame = bounds
    bubbleMaskLayer.path = path.cgPath
    gradientLayer.frame = bounds
    gradientLayer.mask = {
      let mask = CAShapeLayer()
      mask.frame = bounds
      mask.path = path.cgPath
      return mask
    }()
    fillLayer.frame = bounds
    fillLayer.path = path.cgPath
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyShapePath()
    applyAgentBorderPath()
    CATransaction.commit()
  }

  private func bubblePath(
    rect: CGRect, topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat
  ) -> UIBezierPath {
    let width = max(1.0, rect.width)
    let height = max(1.0, rect.height)
    let tl = min(max(0.0, topLeft), min(width, height) * 0.5)
    let tr = min(max(0.0, topRight), min(width, height) * 0.5)
    let br = min(max(0.0, bottomRight), min(width, height) * 0.5)
    let bl = min(max(0.0, bottomLeft), min(width, height) * 0.5)

    let path = UIBezierPath()
    path.move(to: CGPoint(x: tl, y: 0.0))
    path.addLine(to: CGPoint(x: width - tr, y: 0.0))
    path.addArc(
      withCenter: CGPoint(x: width - tr, y: tr), radius: tr, startAngle: 3 * .pi / 2, endAngle: 0.0,
      clockwise: true)
    path.addLine(to: CGPoint(x: width, y: height - br))
    path.addArc(
      withCenter: CGPoint(x: width - br, y: height - br), radius: br, startAngle: 0.0,
      endAngle: .pi / 2, clockwise: true)
    path.addLine(to: CGPoint(x: bl, y: height))
    path.addArc(
      withCenter: CGPoint(x: bl, y: height - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi,
      clockwise: true)
    path.addLine(to: CGPoint(x: 0.0, y: tl))
    path.addArc(
      withCenter: CGPoint(x: tl, y: tl), radius: tl, startAngle: .pi, endAngle: 3 * .pi / 2,
      clockwise: true)
    path.close()
    return path
  }
}

private let bubbleMessageFont = UIFont.systemFont(ofSize: 16)
private let bubbleMetaFont = UIFont.systemFont(ofSize: 10, weight: .medium)
private let bubbleMetaPendingFont = UIFont.systemFont(ofSize: 10.5, weight: .semibold)
private let bubbleMetaStatusFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
private let bubbleMetaInlineSpacing: CGFloat = 6.0
private let bubbleMetaItemGap: CGFloat = 3.0
private let bubbleStatusSlotWidth: CGFloat = 16.0
private let bubbleStatusSlotHeight: CGFloat = 14.0
private let bubbleStatusCheckStrokeWidth: CGFloat = 1.55

private func pixelAlignedRect(_ rect: CGRect) -> CGRect {
  let scale = max(UIScreen.main.scale, 1.0)
  let minX = floor(rect.minX * scale) / scale
  let minY = floor(rect.minY * scale) / scale
  let maxX = ceil(rect.maxX * scale) / scale
  let maxY = ceil(rect.maxY * scale) / scale
  return CGRect(x: minX, y: minY, width: max(0.0, maxX - minX), height: max(0.0, maxY - minY))
}

private func bubbleStatusCheckImage(double: Bool, color: UIColor) -> UIImage? {
  let size = CGSize(width: bubbleStatusSlotWidth, height: bubbleStatusSlotHeight)
  let renderer = UIGraphicsImageRenderer(size: size)
  return renderer.image { ctx in
    let sx = size.width / 24.0
    let sy = size.height / 24.0

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: x * sx, y: y * sy)
    }

    let lineWidth = bubbleStatusCheckStrokeWidth * min(sx, sy) * 1.6
    color.setStroke()

    let firstPath = UIBezierPath()
    firstPath.move(to: point(4.0, 12.9))
    firstPath.addLine(to: point(7.14286, 16.5))
    firstPath.addLine(to: point(15.0, 7.5))
    firstPath.lineWidth = lineWidth
    firstPath.lineCapStyle = .round
    firstPath.lineJoinStyle = .round
    firstPath.stroke()

    if double {
      let secondPath = UIBezierPath()
      secondPath.move(to: point(20.0, 7.5625))
      secondPath.addLine(to: point(11.4283, 16.5625))
      secondPath.addLine(to: point(11.0, 16.0))
      secondPath.lineWidth = lineWidth
      secondPath.lineCapStyle = .round
      secondPath.lineJoinStyle = .round
      secondPath.stroke()
    }
    ctx.cgContext.flush()
  }.withRenderingMode(.alwaysOriginal)
}

struct ChatMessageBubbleLayoutMetrics {
  let bubbleWidth: CGFloat
  let bubbleHeight: CGFloat
  let messageWidth: CGFloat
  let textHeight: CGFloat
  let bodyHeight: CGFloat
  let metaWidth: CGFloat
  let contentWidth: CGFloat
  let mediaHeight: CGFloat
  let isMediaLayout: Bool
  let inlineAttachmentHeight: CGFloat
  let hasInlineAttachment: Bool
}

private struct ChatBubbleMetaWidths {
  let edited: CGFloat
  let pinned: CGFloat
  let timestamp: CGFloat
  let total: CGFloat
}

private func measuredTextWidth(_ text: String, font: UIFont) -> CGFloat {
  ceil((text as NSString).size(withAttributes: [.font: font]).width)
}

private func formatBubbleDuration(seconds: Double?) -> String {
  guard let seconds, seconds.isFinite, seconds > 0 else {
    return "0:00"
  }
  let total = max(0, Int(round(seconds)))
  let minutes = total / 60
  let secs = total % 60
  return String(format: "%d:%02d", minutes, secs)
}

private func bubbleMetaWidths(for row: ChatListRow) -> ChatBubbleMetaWidths {
  if row.messageType == "agent_progress" {
    return ChatBubbleMetaWidths(edited: 0.0, pinned: 0.0, timestamp: 0.0, total: 0.0)
  }

  var items: [CGFloat] = []
  let editedWidth = measuredTextWidth("edited", font: bubbleMetaFont)
  let pinnedWidth = measuredTextWidth("pinned", font: bubbleMetaFont)
  let timestampWidth = measuredTextWidth(row.timestamp, font: bubbleMetaFont)

  if row.isEdited {
    items.append(editedWidth)
  }
  if row.isPinned {
    items.append(pinnedWidth)
  }
  items.append(timestampWidth)
  items.append(bubbleStatusSlotWidth)

  let gapWidth = CGFloat(max(0, items.count - 1)) * bubbleMetaItemGap
  let total = items.reduce(0.0, +) + gapWidth
  return ChatBubbleMetaWidths(
    edited: editedWidth,
    pinned: pinnedWidth,
    timestamp: timestampWidth,
    total: total
  )
}

private let inlineAttachmentHeight: CGFloat = 48.0
private let inlineAttachmentSpacing: CGFloat = 8.0
private let stickerMinDisplaySide: CGFloat = 72.0
private let stickerDefaultDisplaySide: CGFloat = 136.0
private let stickerMaxDisplayWidth: CGFloat = 152.0
private let stickerMaxDisplayHeight: CGFloat = 184.0
private let stickerMetaTopSpacing: CGFloat = 1.0

private func hasInlineFileAttachment(_ row: ChatListRow) -> Bool {
  guard let mediaUrl = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
    !mediaUrl.isEmpty
  else {
    return false
  }
  let hasFileNameHint =
    !(row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  let lowerMediaURL = mediaUrl.lowercased()
  let isAgentDocURL =
    lowerMediaURL.contains("/uploads/agent-docs/")
    || lowerMediaURL.contains("/api/agent/document/")
  if isAgentDocURL {
    return true
  }
  return row.isAgentMessage && (row.messageType == "file" || hasFileNameHint)
}

private func isRTL(_ text: String) -> Bool {
  return text.range(of: "[\\u0600-\\u06FF]", options: .regularExpression) != nil
}

private func cachedNaturalMediaSize(for mediaUrl: String?) -> CGSize? {
  guard let mediaUrl, !mediaUrl.isEmpty else { return nil }
  guard let value = chatMediaNaturalSizeCache.object(forKey: mediaUrl as NSString) else {
    return nil
  }
  let size = value.cgSizeValue
  guard size.width > 1.0, size.height > 1.0 else { return nil }
  return size
}

private func cacheNaturalMediaSize(_ size: CGSize, for mediaUrl: String?) {
  guard let mediaUrl, !mediaUrl.isEmpty else { return }
  guard size.width > 1.0, size.height > 1.0 else { return }
  chatMediaNaturalSizeCache.setObject(NSValue(cgSize: size), forKey: mediaUrl as NSString)
}

private func probeLocalMediaSize(for mediaUrl: String?) -> CGSize? {
  guard let mediaUrl, !mediaUrl.isEmpty else { return nil }
  let trimmed = mediaUrl.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  let resolvedPath: String? = {
    let encodedTrimmed =
      trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
    if let url = URL(string: trimmed) ?? URL(string: encodedTrimmed), url.isFileURL {
      return url.path
    }
    if trimmed.hasPrefix("/") {
      return trimmed
    }
    if let decoded = trimmed.removingPercentEncoding, decoded.hasPrefix("/") {
      return decoded
    }
    if trimmed.hasPrefix("file://") {
      let path = String(trimmed.dropFirst(7))
      return path.removingPercentEncoding ?? path
    }
    return nil
  }()

  guard let resolvedPath else { return nil }
  guard let image = UIImage(contentsOfFile: resolvedPath) else { return nil }
  guard image.size.width > 1.0, image.size.height > 1.0 else { return nil }
  return image.size
}

private func resolvedMediaNaturalSize(for row: ChatListRow) -> CGSize? {
  if let mw = row.mediaWidth, let mh = row.mediaHeight, mw > 1.0, mh > 1.0 {
    return CGSize(width: mw, height: mh)
  }
  if let cached = cachedNaturalMediaSize(for: row.mediaUrl) {
    return cached
  }
  if let local = probeLocalMediaSize(for: row.mediaUrl) {
    cacheNaturalMediaSize(local, for: row.mediaUrl)
    return local
  }
  return nil
}

private func resolvedStickerAnimationFilePath(for row: ChatListRow) -> String? {
  guard row.kind == .message, row.visualKind == .sticker else { return nil }

  let store = ChatStickerPackStore.shared
  if let stickerId = row.stickerId,
    let sticker = store.sticker(byId: stickerId),
    let path = store.lottieFilePath(for: sticker)
  {
    return path
  }

  if let bundleFileName = row.stickerBundleFileName {
    if let packId = row.stickerPackId, !packId.isEmpty {
      let sticker = StickerPackSticker(
        id: row.stickerId ?? bundleFileName,
        packId: packId,
        bundleFileName: bundleFileName,
        remoteUrl: row.mediaUrl,
        emoji: nil,
        width: Int(row.mediaWidth ?? 512.0),
        height: Int(row.mediaHeight ?? 512.0)
      )
      if let path = store.lottieFilePath(for: sticker) {
        return path
      }
    }

    for pack in store.installedPacks {
      if let sticker = pack.stickers.first(where: { $0.bundleFileName == bundleFileName }),
        let path = store.lottieFilePath(for: sticker)
      {
        return path
      }
    }

    let bundle = ChatStickerPackStore.resourceBundle() ?? Bundle.main
    if let path = bundle.path(forResource: bundleFileName, ofType: "json") {
      return path
    }
  }

  return nil
}

private func isTransparentStickerMessage(_ row: ChatListRow) -> Bool {
  row.kind == .message && row.visualKind == .sticker
}

private func usesFullBleedMediaLayout(_ row: ChatListRow) -> Bool {
  guard row.kind == .message else { return false }
  if isTransparentStickerMessage(row) {
    return false
  }
  return (row.visualKind == .media && row.messageType != "file") || row.visualKind == .video
    || row.visualKind == .videoNote
}

private func effectiveMetaTopSpacing(for row: ChatListRow) -> CGFloat {
  isTransparentStickerMessage(row) ? stickerMetaTopSpacing : bubbleMetaTopSpacing
}

private func parseAgentMarkdown(text: String, font: UIFont, textColor: UIColor? = nil)
  -> NSAttributedString
{
  let isRtl = isRTL(text)
  let paragraphStyle = NSMutableParagraphStyle()
  paragraphStyle.alignment = isRtl ? .right : .natural
  paragraphStyle.baseWritingDirection = isRtl ? .rightToLeft : .natural

  var attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .paragraphStyle: paragraphStyle,
  ]
  if let c = textColor {
    attrs[.foregroundColor] = c
  }

  let attrString = NSMutableAttributedString(string: text, attributes: attrs)

  let matches = agentBoldRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
  for match in matches.reversed() {
    if let range = Range(match.range(at: 1), in: text) {
      let boldContent = String(text[range])
      var boldAttrs = attrs
      if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
        boldAttrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
      } else {
        boldAttrs[.font] = UIFont.boldSystemFont(ofSize: font.pointSize)
      }
      let replacement = NSAttributedString(string: boldContent, attributes: boldAttrs)
      attrString.replaceCharacters(in: match.range, with: replacement)
    }
  }

  return attrString
}

private func bubbleDisplayAttributedString(
  for row: ChatListRow, font: UIFont, textColor: UIColor? = nil
) -> NSAttributedString {
  var t: String
  var addPrefix = false
  if row.isAgentMessage {
    t = row.plainContent ?? row.text
    addPrefix = true
  } else if row.isAgentMention {
    t = row.textWithoutMention
    addPrefix = true
  } else {
    t = row.text
  }

  if addPrefix {
    let prefix = isRTL(t) ? "\u{200F}✦ " : "✦ "
    t = t.isEmpty ? prefix : prefix + t
  }

  return parseAgentMarkdown(text: t, font: font, textColor: textColor)
}

private final class AgentStreamingLabel: UILabel {
  private static let revealInterval: CFTimeInterval = 0.01
  private static let tokenRegex = try! NSRegularExpression(pattern: "\\S+|\\s+")

  private var fullAttributedValue: NSAttributedString?
  private var tokenRanges: [NSRange] = []
  private var revealedTokenCount = 0
  private var displayLink: CADisplayLink?
  private var nextRevealTime: CFTimeInterval = 0

  required init?(coder: NSCoder) {
    return nil
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
  }

  deinit {
    stopStreamingAnimation()
  }

  func applyAgentText(_ attributedText: NSAttributedString, isStreaming: Bool) {
    let previousFullText = fullAttributedValue?.string ?? ""
    let nextFullText = attributedText.string
    let shouldContinueExistingAnimation =
      isStreaming
      && !previousFullText.isEmpty
      && nextFullText.hasPrefix(previousFullText)

    fullAttributedValue = attributedText
    tokenRanges = Self.tokenize(nextFullText)

    if !shouldContinueExistingAnimation {
      revealedTokenCount = isStreaming ? 0 : tokenRanges.count
      nextRevealTime = 0
    }

    revealedTokenCount = min(revealedTokenCount, tokenRanges.count)
    applyVisibleTokenState()

    if isStreaming {
      startStreamingAnimation()
    } else {
      stopStreamingAnimation()
    }
  }

  func resetStreamingState() {
    stopStreamingAnimation()
    fullAttributedValue = nil
    tokenRanges = []
    revealedTokenCount = 0
    super.attributedText = nil
  }

  private func startStreamingAnimation() {
    guard !tokenRanges.isEmpty else { return }
    guard revealedTokenCount < tokenRanges.count else {
      stopStreamingAnimation()
      return
    }
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopStreamingAnimation() {
    displayLink?.invalidate()
    displayLink = nil
    nextRevealTime = 0
  }

  @objc private func handleDisplayLink() {
    guard !tokenRanges.isEmpty else {
      stopStreamingAnimation()
      return
    }

    let now = CACurrentMediaTime()
    if nextRevealTime <= 0 {
      nextRevealTime = now
    }

    var didReveal = false
    while revealedTokenCount < tokenRanges.count, now >= nextRevealTime {
      revealedTokenCount += 1
      nextRevealTime += Self.revealInterval
      didReveal = true
    }

    if didReveal {
      applyVisibleTokenState()
    }

    if revealedTokenCount >= tokenRanges.count {
      stopStreamingAnimation()
    }
  }

  private func applyVisibleTokenState() {
    guard let fullAttributedValue else {
      super.attributedText = nil
      return
    }

    guard revealedTokenCount < tokenRanges.count else {
      super.attributedText = fullAttributedValue
      return
    }

    let mutable = NSMutableAttributedString(attributedString: fullAttributedValue)
    for index in revealedTokenCount..<tokenRanges.count {
      let range = tokenRanges[index]
      guard range.location != NSNotFound, range.length > 0, range.location < mutable.length else {
        continue
      }

      var appliedForeground = false
      mutable.enumerateAttribute(.foregroundColor, in: range, options: []) { value, subrange, _ in
        let baseColor = (value as? UIColor) ?? self.textColor ?? .white
        mutable.addAttribute(
          .foregroundColor,
          value: baseColor.withAlphaComponent(0.0),
          range: subrange
        )
        appliedForeground = true
      }

      if !appliedForeground {
        let fallbackColor = (textColor ?? .white).withAlphaComponent(0.0)
        mutable.addAttribute(.foregroundColor, value: fallbackColor, range: range)
      }
    }
    super.attributedText = mutable
  }

  private static func tokenize(_ string: String) -> [NSRange] {
    guard !string.isEmpty else { return [] }
    let nsString = string as NSString
    let fullRange = NSRange(location: 0, length: nsString.length)
    let matches = tokenRegex.matches(in: string, range: fullRange).map(\.range)
    if matches.isEmpty {
      return [fullRange]
    }
    return matches
  }
}

func measureMessageBubbleLayout(row: ChatListRow, rowWidth: CGFloat)
  -> ChatMessageBubbleLayoutMetrics
{
  let maxBubbleWidth = floor(rowWidth * bubbleMaxWidthFactor)
  let maxContentWidth = max(1.0, maxBubbleWidth - (bubbleHorizontalPadding * 2.0))
  let meta = bubbleMetaWidths(for: row)

  switch row.visualKind {
  case .voice, .video, .videoNote, .media, .sticker:
    var targetWidth: CGFloat
    var mediaHeight: CGFloat
    switch row.visualKind {
    case .voice:
      let dur = max(1.0, min(30.0, row.duration ?? 1.0))
      let frac = CGFloat((Double(dur) - log(Double(max(2.0, dur)))) / 15.0)
      let minW = 100.0 + meta.total
      targetWidth = minW + max(0.0, min(1.0, frac)) * (maxContentWidth - minW)
      mediaHeight = 50.0
    case .videoNote:
      targetWidth = 200.0
      mediaHeight = 200.0
    case .video, .media, .sticker:
      if let naturalSize = resolvedMediaNaturalSize(for: row),
        naturalSize.width > 1.0,
        naturalSize.height > 1.0
      {
        let ratio = max(0.2, min(5.0, naturalSize.height / naturalSize.width))
        let sizeLimit: CGFloat = row.visualKind == .sticker ? stickerMaxDisplayWidth : maxContentWidth
        let minWidth: CGFloat = row.visualKind == .sticker ? stickerMinDisplaySide : 120.0
        let minHeight: CGFloat = row.visualKind == .sticker ? stickerMinDisplaySide : 84.0
        targetWidth = max(minWidth, min(sizeLimit, naturalSize.width))
        mediaHeight = max(minHeight, targetWidth * ratio)
        let heightLimit: CGFloat = row.visualKind == .sticker ? stickerMaxDisplayHeight : 380.0
        if mediaHeight > heightLimit {
          mediaHeight = heightLimit
          targetWidth = mediaHeight / ratio
        }
      } else if row.visualKind == .sticker {
        // Sticker default: compact square like Telegram, but smaller than generic media.
        targetWidth = stickerDefaultDisplaySide
        mediaHeight = stickerDefaultDisplaySide
      } else {
        targetWidth = max(120.0, maxContentWidth)
        mediaHeight = targetWidth
      }
    case .text:
      targetWidth = maxContentWidth
      mediaHeight = 0.0
    }

    let isTransparentSticker = isTransparentStickerMessage(row)
    let isFullBleed = usesFullBleedMediaLayout(row)
    let metaTopSpacing = effectiveMetaTopSpacing(for: row)
    let contentWidth = min(maxContentWidth, targetWidth)
    let hasReaction = row.reactionEmoji != nil && row.reactionEmoji?.isEmpty == false
    let reactionHeightOffset: CGFloat = hasReaction ? 28.0 : 0.0
    let bodyHeight: CGFloat
    let bubbleWidth: CGFloat
    let bubbleHeight: CGFloat
    if isTransparentSticker {
      bodyHeight = mediaHeight + metaTopSpacing + bubbleMetaHeight
      bubbleWidth = max(meta.total, contentWidth)
      bubbleHeight = bodyHeight + reactionHeightOffset
    } else {
      let isVoice = row.visualKind == .voice
      bodyHeight =
        (isFullBleed || isVoice) ? mediaHeight : (mediaHeight + metaTopSpacing + bubbleMetaHeight)
      bubbleWidth =
        isFullBleed
        ? max(bubbleMinWidth, contentWidth)
        : max(bubbleMinWidth, contentWidth + (bubbleHorizontalPadding * 2.0))
      let topPad = isVoice ? 2.0 : bubbleTopPadding
      let bottomPad = isVoice ? 4.0 : bubbleBottomPadding
      bubbleHeight =
        isFullBleed
        ? max(56.0, bodyHeight + reactionHeightOffset)
        : max(48.0, bodyHeight + topPad + bottomPad + reactionHeightOffset)
    }
    return ChatMessageBubbleLayoutMetrics(
      bubbleWidth: bubbleWidth,
      bubbleHeight: bubbleHeight,
      messageWidth: contentWidth,
      textHeight: 0.0,
      bodyHeight: bodyHeight,
      metaWidth: meta.total,
      contentWidth: contentWidth,
      mediaHeight: mediaHeight,
      isMediaLayout: true,
      inlineAttachmentHeight: 0.0,
      hasInlineAttachment: false
    )

  case .text:
    break
  }

  let hasInlineAttachment = hasInlineFileAttachment(row)
  let textMaxWidth =
    hasInlineAttachment
    ? maxContentWidth
    : max(1.0, maxContentWidth - meta.total - bubbleMetaInlineSpacing)
  let font =
    row.messageType == "typing"
    ? UIFont.systemFont(ofSize: 13, weight: .regular) : bubbleMessageFont
  let displayText = bubbleDisplayAttributedString(for: row, font: font)
  let textRect = displayText.boundingRect(
    with: CGSize(width: textMaxWidth, height: .greatestFiniteMagnitude),
    options: [.usesLineFragmentOrigin, .usesFontLeading],
    context: nil
  )
  let textWidth = min(textMaxWidth, ceil(textRect.width))
  let textHeight = ceil(textRect.height)
  let attachmentBodyHeight: CGFloat = hasInlineAttachment ? inlineAttachmentHeight : 0.0
  let desiredContentWidth: CGFloat
  if hasInlineAttachment {
    let attachmentTitle = row.fileName?.isEmpty == false ? row.fileName! : "Document"
    let attachmentWidth =
      min(
        maxContentWidth,
        max(
          168.0,
          measuredTextWidth(attachmentTitle, font: UIFont.systemFont(ofSize: 13, weight: .semibold))
            + 62.0)
      )
    desiredContentWidth = max(textWidth, attachmentWidth)
  } else {
    desiredContentWidth = textWidth + bubbleMetaInlineSpacing + meta.total
  }
  let contentWidth = max(meta.total, min(maxContentWidth, desiredContentWidth))
  let messageWidth =
    hasInlineAttachment
    ? contentWidth
    : max(1.0, contentWidth - meta.total - bubbleMetaInlineSpacing)
  let bodyHeight =
    hasInlineAttachment
    ? max(textHeight, 0.0) + inlineAttachmentSpacing + attachmentBodyHeight + bubbleMetaTopSpacing
      + bubbleMetaHeight
    : max(textHeight, bubbleMetaHeight)
  let hasReaction = row.reactionEmoji != nil && row.reactionEmoji?.isEmpty == false
  let reactionHeightOffset: CGFloat = hasReaction ? 28.0 : 0.0
  let bubbleWidth = max(bubbleMinWidth, contentWidth + (bubbleHorizontalPadding * 2.0))
  let bubbleHeight = max(
    36.0, bodyHeight + bubbleTopPadding + bubbleBottomPadding + reactionHeightOffset)
  return ChatMessageBubbleLayoutMetrics(
    bubbleWidth: bubbleWidth,
    bubbleHeight: bubbleHeight,
    messageWidth: messageWidth,
    textHeight: textHeight,
    bodyHeight: bodyHeight,
    metaWidth: meta.total,
    contentWidth: contentWidth,
    mediaHeight: 0.0,
    isMediaLayout: false,
    inlineAttachmentHeight: attachmentBodyHeight,
    hasInlineAttachment: hasInlineAttachment
  )
}

private func bubbleRoundedPath(
  rect: CGRect,
  topLeft: CGFloat,
  topRight: CGFloat,
  bottomRight: CGFloat,
  bottomLeft: CGFloat
) -> UIBezierPath {
  let width = max(1.0, rect.width)
  let height = max(1.0, rect.height)
  let radiusLimit = min(width, height) * 0.5
  let tl = min(max(0.0, topLeft), radiusLimit)
  let tr = min(max(0.0, topRight), radiusLimit)
  let br = min(max(0.0, bottomRight), radiusLimit)
  let bl = min(max(0.0, bottomLeft), radiusLimit)

  let path = UIBezierPath()
  path.move(to: CGPoint(x: tl, y: 0.0))
  path.addLine(to: CGPoint(x: width - tr, y: 0.0))
  path.addArc(
    withCenter: CGPoint(x: width - tr, y: tr),
    radius: tr,
    startAngle: 3.0 * .pi / 2.0,
    endAngle: 0.0,
    clockwise: true
  )
  path.addLine(to: CGPoint(x: width, y: height - br))
  path.addArc(
    withCenter: CGPoint(x: width - br, y: height - br),
    radius: br,
    startAngle: 0.0,
    endAngle: .pi / 2.0,
    clockwise: true
  )
  path.addLine(to: CGPoint(x: bl, y: height))
  path.addArc(
    withCenter: CGPoint(x: bl, y: height - bl),
    radius: bl,
    startAngle: .pi / 2.0,
    endAngle: .pi,
    clockwise: true
  )
  path.addLine(to: CGPoint(x: 0.0, y: tl))
  path.addArc(
    withCenter: CGPoint(x: tl, y: tl),
    radius: tl,
    startAngle: .pi,
    endAngle: 3.0 * .pi / 2.0,
    clockwise: true
  )
  path.close()
  return path
}

final class BubbleUploadProgressView: UIView {
  private let trackLayer = CAShapeLayer()
  private let progressLayer = CAShapeLayer()
  private let iconView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear

    trackLayer.fillColor = UIColor.clear.cgColor
    trackLayer.strokeColor = UIColor(white: 1.0, alpha: 0.28).cgColor
    trackLayer.lineWidth = 3.0

    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.strokeColor = UIColor.white.cgColor
    progressLayer.lineWidth = 3.0
    progressLayer.lineCap = .round
    progressLayer.strokeStart = 0.0
    progressLayer.strokeEnd = 0.0

    layer.addSublayer(trackLayer)
    layer.addSublayer(progressLayer)

    iconView.image = UIImage(systemName: "xmark")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
    iconView.tintColor = .white
    iconView.contentMode = .scaleAspectFit
    addSubview(iconView)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let radius = max(1.0, (min(bounds.width, bounds.height) - 4.0) * 0.5 - 1.5)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let path = UIBezierPath(
      arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: (.pi * 3.0) / 2.0,
      clockwise: true)
    trackLayer.frame = bounds
    progressLayer.frame = bounds
    trackLayer.path = path.cgPath
    progressLayer.path = path.cgPath
    iconView.frame = CGRect(
      x: floor((bounds.width - 14.0) * 0.5),
      y: floor((bounds.height - 14.0) * 0.5),
      width: 14.0,
      height: 14.0
    )
  }

  func setProgress(_ progress: Double?) {
    guard let progress, progress.isFinite else {
      progressLayer.strokeEnd = 0.0
      return
    }
    let clamped = max(0.02, min(1.0, progress))
    progressLayer.strokeEnd = CGFloat(clamped)
  }
}

final class VoicePlayProgressView: UIView {
  private let fluidVisualizer = FluidVADVisualizer()
  private let fillView = UIView()
  private let iconView = UIImageView()
  private let ringProgressLayer = CAShapeLayer()
  private var iconTintColor = UIColor.systemBlue
  private var isUploading = false
  private var uploadProgress: CGFloat?
  private let uploadSpinAnimationKey = "voice.upload.spin"

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = true
    backgroundColor = .clear

    fluidVisualizer.isUserInteractionEnabled = false
    addSubview(fluidVisualizer)

    fillView.isUserInteractionEnabled = false
    fillView.backgroundColor = UIColor(white: 1.0, alpha: 0.96)
    fillView.layer.cornerCurve = .continuous
    addSubview(fillView)

    ringProgressLayer.fillColor = UIColor.clear.cgColor
    ringProgressLayer.strokeColor = UIColor.systemBlue.cgColor
    ringProgressLayer.lineWidth = 2.4
    ringProgressLayer.lineCap = .round
    ringProgressLayer.strokeStart = 0.0
    ringProgressLayer.strokeEnd = 0.0
    layer.addSublayer(ringProgressLayer)

    iconView.contentMode = .scaleAspectFit
    addSubview(iconView)
    setPlaybackState(isPlaying: false, progress: 0.0)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let diameter = max(1.0, min(bounds.width, bounds.height) - 6.0)
    let fillFrame = CGRect(
      x: floor((bounds.width - diameter) * 0.5),
      y: floor((bounds.height - diameter) * 0.5),
      width: diameter,
      height: diameter
    )
    fillView.frame = fillFrame
    fillView.layer.cornerRadius = diameter * 0.5

    fluidVisualizer.frame = bounds

    let ringRadius = max(2.0, (diameter * 0.5) + 1.8)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let ringPath = UIBezierPath(
      arcCenter: center,
      radius: ringRadius,
      startAngle: -.pi / 2,
      endAngle: (.pi * 3.0) / 2.0,
      clockwise: true)
    ringProgressLayer.frame = bounds
    ringProgressLayer.path = ringPath.cgPath

    iconView.frame = CGRect(
      x: floor((bounds.width - 18.0) * 0.5),
      y: floor((bounds.height - 18.0) * 0.5),
      width: 18.0,
      height: 18.0
    )
  }

  func applyStyle(fillColor: UIColor, iconTint: UIColor, ringTint: UIColor) {
    fillView.backgroundColor = fillColor
    iconTintColor = iconTint
    iconView.tintColor = iconTintColor
    fluidVisualizer.applyColor(ringTint.withAlphaComponent(0.35))
    ringProgressLayer.strokeColor = ringTint.cgColor
    if isUploading {
      updateUploadRingVisual()
    }
  }

  func setPlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat = 0.0) {
    guard !isUploading else { return }
    ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
    ringProgressLayer.strokeStart = 0.0
    ringProgressLayer.strokeEnd = 0.0 // Never show ring for playback
    let symbol = isPlaying ? "pause.fill" : "play.fill"
    let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)
    iconView.image = UIImage(systemName: symbol, withConfiguration: config)
    iconView.tintColor = iconTintColor

    fluidVisualizer.level = level
    if isPlaying {
      if fluidVisualizer.alpha < 0.05 { fluidVisualizer.start() }
    } else {
      fluidVisualizer.stop()
    }
  }

  func setUploadState(isUploading: Bool, progress: CGFloat?) {
    let normalizedProgress: CGFloat?
    if let progress, progress.isFinite {
      normalizedProgress = max(0.0, min(1.0, progress))
    } else {
      normalizedProgress = nil
    }
    if self.isUploading == isUploading, self.uploadProgress == normalizedProgress {
      return
    }
    self.isUploading = isUploading
    self.uploadProgress = normalizedProgress
    updateUploadRingVisual()
  }

  private func updateUploadRingVisual() {
    guard isUploading else {
      ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      ringProgressLayer.strokeStart = 0.0
      ringProgressLayer.strokeEnd = 0.0
      return
    }
    let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    iconView.image = UIImage(systemName: "xmark", withConfiguration: config)
    iconView.tintColor = iconTintColor

    if let uploadProgress {
      ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      // Smooth determinate progress
      let targetProgress = max(0.04, uploadProgress)
      let currentProgress = ringProgressLayer.presentation()?.strokeEnd ?? ringProgressLayer.strokeEnd

      CATransaction.begin()
      CATransaction.setDisableActions(true)
      ringProgressLayer.strokeStart = 0.0
      ringProgressLayer.strokeEnd = targetProgress
      CATransaction.commit()

      let anim = CABasicAnimation(keyPath: "strokeEnd")
      anim.fromValue = currentProgress
      anim.toValue = targetProgress
      anim.duration = 0.15
      ringProgressLayer.add(anim, forKey: "stroke_fill")
      return
    }

    // Indeterminate ring until concrete upload progress exists.
    ringProgressLayer.strokeStart = 0.08
    ringProgressLayer.strokeEnd = 0.34
    if ringProgressLayer.animation(forKey: uploadSpinAnimationKey) == nil {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0.0
      spin.toValue = (2.0 * CGFloat.pi)
      spin.duration = 0.95
      spin.repeatCount = .infinity
      spin.timingFunction = CAMediaTimingFunction(name: .linear)
      spin.isRemovedOnCompletion = true
      ringProgressLayer.add(spin, forKey: uploadSpinAnimationKey)
    }
  }
}

final class VoiceWaveformView: UIView {
  private var barCount = 40
  private var barLayers: [CALayer] = []
  private var barEnvelope: [CGFloat] = []
  private var rawSamples: [CGFloat]?
  private var playbackProgress: CGFloat = 0.0
  private var level: CGFloat = 0.0
  private var isPlaying = false
  private var activeColor = UIColor.white
  private var inactiveColor = UIColor(white: 1.0, alpha: 0.28)

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let expectedBarWidth: CGFloat = 2.0
    let expectedSpacing: CGFloat = 2.0
    let newCount = max(1, Int(bounds.width / (expectedBarWidth + expectedSpacing)))
    if newCount != barCount || barLayers.isEmpty {
      barCount = newCount
      barLayers.forEach { $0.removeFromSuperlayer() }
      barLayers.removeAll()
      for _ in 0..<barCount {
        let layer = CALayer()
        layer.backgroundColor = inactiveColor.cgColor
        layer.cornerCurve = .continuous
        barLayers.append(layer)
        self.layer.addSublayer(layer)
      }
      rebuildEnvelope()
    }
    applyBarFrames()
  }

  func applyColors(active: UIColor, inactive: UIColor) {
    activeColor = active
    inactiveColor = inactive
    applyBarFrames()
  }

  func setWaveform(_ samples: [CGFloat]?) {
    rawSamples = samples
    rebuildEnvelope()
    applyBarFrames()
  }

  private func rebuildEnvelope() {
    guard barCount > 0 else { return }
    guard let samples = rawSamples, !samples.isEmpty else {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      return
    }
    let normalized =
      samples
      .filter { $0.isFinite }
      .map { max(0.0, min(1.0, $0)) }
    guard !normalized.isEmpty else {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      return
    }

    var resampled = Array(repeating: CGFloat.zero, count: barCount)
    for index in 0..<normalized.count {
      let bucketIndex = min(barCount - 1, (index * barCount) / max(1, normalized.count))
      resampled[bucketIndex] = max(resampled[bucketIndex], normalized[index])
    }

    if let maxSample = resampled.max(), maxSample > 0.0001 {
      let inverseScale = 1.0 / maxSample
      resampled = resampled.map { max(0.0, min(1.0, $0 * inverseScale)) }
    } else {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      return
    }

    if resampled.allSatisfy({ $0 <= 0.001 }) {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      return
    }

    barEnvelope = resampled
  }

  func setPlayback(progress: CGFloat, level: CGFloat, isPlaying: Bool) {
    playbackProgress = max(0.0, min(1.0, progress))
    self.level = max(0.0, min(1.0, level))
    self.isPlaying = isPlaying
    applyBarFrames()
  }

  private func applyBarFrames() {
    guard !barLayers.isEmpty, bounds.width > 1.0, bounds.height > 1.0 else { return }
    let barWidth: CGFloat = 2.0
    let spacing: CGFloat = 2.0
    let minHeight: CGFloat = 2.0
    let peakHeight = max(minHeight, min(bounds.height, 18.0))
    let progressX = max(0.0, min(bounds.width, playbackProgress * bounds.width))
    var x: CGFloat = 0.0

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, barLayer) in barLayers.enumerated() {
      let amplitude = max(0.0, min(1.0, barEnvelope[index]))
      let barHeight = max(minHeight, peakHeight * amplitude)
      let barStart = x
      let barEnd = x + barWidth

      let fillFraction = max(0.0, min(1.0, (progressX - barStart) / max(1.0, barEnd - barStart)))
      let renderedHeight = max(1.0, floor(barHeight))
      let y = floor(bounds.height - renderedHeight)

      barLayer.frame = CGRect(x: x, y: y, width: barWidth, height: renderedHeight)
      barLayer.cornerRadius = barWidth * 0.5
      barLayer.backgroundColor = blendedColor(fraction: fillFraction)
      x += barWidth + spacing
    }
    CATransaction.commit()
  }

  private func blendedColor(fraction: CGFloat) -> CGColor {
    if fraction <= 0.0 { return inactiveColor.cgColor }
    if fraction >= 1.0 { return activeColor.cgColor }

    var ar: CGFloat = 0
    var ag: CGFloat = 0
    var ab: CGFloat = 0
    var aa: CGFloat = 0
    var ir: CGFloat = 0
    var ig: CGFloat = 0
    var ib: CGFloat = 0
    var ia: CGFloat = 0
    guard
      activeColor.getRed(&ar, green: &ag, blue: &ab, alpha: &aa),
      inactiveColor.getRed(&ir, green: &ig, blue: &ib, alpha: &ia)
    else {
      return activeColor.withAlphaComponent(fraction).cgColor
    }
    let t = fraction
    return UIColor(
      red: ir + ((ar - ir) * t),
      green: ig + ((ag - ig) * t),
      blue: ib + ((ab - ib) * t),
      alpha: ia + ((aa - ia) * t)
    ).cgColor
  }

  private static func smoothed(_ values: [CGFloat]) -> [CGFloat] {
    guard values.count > 2 else { return values }
    var result = values
    for index in values.indices {
      let left = values[max(0, index - 1)]
      let center = values[index]
      let right = values[min(values.count - 1, index + 1)]
      result[index] = max(0.14, min(1.0, (left * 0.2) + (center * 0.6) + (right * 0.2)))
    }
    return result
  }

  private static func shaped(_ values: [CGFloat]) -> [CGFloat] {
    return values.enumerated().map { index, value in
      let edgeAttenuation =
        1.0
        - (abs((CGFloat(index) / CGFloat(max(1, values.count - 1))) - 0.5) * 0.12)
      return max(0.10, min(1.0, pow(value, 0.90) * edgeAttenuation))
    }
  }

  private static func makeDefaultEnvelope(count: Int) -> [CGFloat] {
    guard count > 0 else { return [] }
    let template: [CGFloat] = [0.64, 0.49, 0.73, 0.56, 0.42, 0.78, 0.58, 0.28, 0.33, 0.67]
    return (0..<count).map { index in
      template[index % template.count]
    }
  }
}

protocol VoicePlayableCell: AnyObject {
  func applyVoicePlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat)
}

final class VoiceBubblePlaybackCoordinator: NSObject, AVAudioPlayerDelegate {
  static let shared = VoiceBubblePlaybackCoordinator()

  private weak var activeCell: VoicePlayableCell?
  private var activeMessageId: String?
  private var player: AVAudioPlayer?
  private var displayLink: CADisplayLink?
  private var playbackProgress: CGFloat = 0.0
  private var level: CGFloat = 0.0
  private var isPlaying = false
  private var activeDownloadTask: URLSessionDownloadTask?

  private override init() {
    super.init()
  }

  deinit {
    displayLink?.invalidate()
    player?.stop()
  }

  func bind(cell: VoicePlayableCell, messageId: String?) {
    guard let messageId, !messageId.isEmpty else {
      cell.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
      return
    }
    if activeMessageId == messageId {
      activeCell = cell
      cell.applyVoicePlaybackState(
        isPlaying: isPlaying, progress: playbackProgress, level: level
      )
      return
    }
    cell.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
  }

  func unbind(cell: VoicePlayableCell) {
    if activeCell === cell {
      activeCell = nil
    }
  }

  func toggle(cell: VoicePlayableCell, messageId: String?, mediaURL: String?) {
    let loggedMessageId = messageId ?? "-"
    let loggedMedia = shortMediaURL(mediaURL)
    NSLog(
      "[ChatListView] voice tap messageId=%@ mediaUrl=%@",
      loggedMessageId,
      loggedMedia
    )
    guard let messageId, !messageId.isEmpty, let mediaURL, !mediaURL.isEmpty else {
      NSLog("[ChatListView] voice tap ignored missing messageId/mediaUrl")
      return
    }

    if activeMessageId == messageId {
      if let player {
        if player.isPlaying {
          player.pause()
          isPlaying = false
          NSLog(
            "[ChatListView] voice pause messageId=%@ progress=%.3f", messageId, playbackProgress)
          cell.applyVoicePlaybackState(
            isPlaying: false, progress: playbackProgress, level: level
          )
        } else {
          player.play()
          isPlaying = true
          NSLog(
            "[ChatListView] voice resume messageId=%@ progress=%.3f", messageId, playbackProgress)
        }
        return
      } else if activeDownloadTask != nil {
        NSLog("[ChatListView] voice cancel download messageId=%@", messageId)
        stopActivePlayback(resetProgress: true)
        return
      }
    }

    stopActivePlayback(resetProgress: true)

    guard let resolvedURL = resolveAudioURL(from: mediaURL) else {
      NSLog(
        "[ChatListView] voice resolveAudioURL failed messageId=%@ raw=%@",
        messageId,
        shortMediaURL(mediaURL)
      )
      return
    }
    NSLog(
      "[ChatListView] voice resolved URL messageId=%@ isFile=%@ path=%@",
      messageId,
      resolvedURL.isFileURL.description,
      resolvedURL.path
    )

    if !resolvedURL.isFileURL {
      playRemoteURL(resolvedURL, messageId: messageId, cell: cell)
      return
    }

    playLocalURL(resolvedURL, messageId: messageId, cell: cell)
  }

  private func playRemoteURL(_ url: URL, messageId: String, cell: VoicePlayableCell) {
    // Use Caches directory (persists across app sessions, unlike tmp/ which is wiped)
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let cacheDir = caches.appendingPathComponent("voice-cache", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    } catch {
      NSLog("[ChatListView] failed to create voice cache dir: %@", String(describing: error))
    }

    // Preserve the original file extension from the URL for correct AVAudioPlayer decoding
    let urlExt = url.pathExtension.lowercased()
    let ext = urlExt.isEmpty ? "m4a" : urlExt
    let filename = String(format: "%016llx", url.absoluteString.hashValue) + "." + ext
    let localURL = cacheDir.appendingPathComponent(filename)

    if FileManager.default.fileExists(atPath: localURL.path) {
      playLocalURL(localURL, messageId: messageId, cell: cell)
      return
    }

    activeMessageId = messageId
    activeCell = cell
    cell.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)

    let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
      guard let tempURL = tempURL, error == nil else {
        NSLog(
          "[ChatListView] voice download failed url=%@ error=%@", url.absoluteString,
          String(describing: error))
        DispatchQueue.main.async {
          if self?.activeMessageId == messageId {
            self?.stopActivePlayback(resetProgress: true)
          }
        }
        return
      }

      // Validate HTTP response — Supabase may return HTML error pages
      if let httpResponse = response as? HTTPURLResponse {
        let statusCode = httpResponse.statusCode
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        NSLog(
          "[ChatListView] voice download response messageId=%@ status=%d contentType=%@ bytes=%lld",
          messageId,
          statusCode,
          contentType,
          (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        )
        if !(200...299).contains(statusCode) {
          NSLog(
            "[ChatListView] voice download HTTP error messageId=%@ status=%d",
            messageId,
            statusCode
          )
          DispatchQueue.main.async {
            if self?.activeMessageId == messageId {
              self?.stopActivePlayback(resetProgress: true)
            }
          }
          return
        }
        // Reject HTML/JSON responses (error pages from storage providers)
        let lowerCT = contentType.lowercased()
        if lowerCT.contains("text/html") || lowerCT.contains("application/json") {
          NSLog(
            "[ChatListView] voice download got non-audio content messageId=%@ contentType=%@",
            messageId,
            contentType
          )
          DispatchQueue.main.async {
            if self?.activeMessageId == messageId {
              self?.stopActivePlayback(resetProgress: true)
            }
          }
          return
        }
      }

      // Validate file size — audio should be at least a few hundred bytes
      let fileSize =
        (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
      if fileSize < 100 {
        NSLog(
          "[ChatListView] voice download too small messageId=%@ bytes=%lld",
          messageId,
          fileSize
        )
        DispatchQueue.main.async {
          if self?.activeMessageId == messageId {
            self?.stopActivePlayback(resetProgress: true)
          }
        }
        return
      }

      do {
        if FileManager.default.fileExists(atPath: localURL.path) {
          try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: localURL)
        DispatchQueue.main.async {
          if self?.activeMessageId == messageId {
            self?.playLocalURL(localURL, messageId: messageId, cell: cell)
          }
        }
      } catch {
        NSLog("[ChatListView] voice move failed error=%@", String(describing: error))
        DispatchQueue.main.async {
          if self?.activeMessageId == messageId {
            self?.stopActivePlayback(resetProgress: true)
          }
        }
      }
    }
    activeDownloadTask = task
    task.resume()
  }

  private func playLocalURL(_ url: URL, messageId: String, cell: VoicePlayableCell) {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .default, options: [.duckOthers])
      try AVAudioSession.sharedInstance().setActive(true)
      let nextPlayer = try AVAudioPlayer(contentsOf: url)
      nextPlayer.delegate = self
      nextPlayer.prepareToPlay()
      nextPlayer.isMeteringEnabled = true
      player = nextPlayer
      activeMessageId = messageId
      activeCell = cell
      playbackProgress = 0.0
      level = 0.0
      isPlaying = nextPlayer.play()
      NSLog(
        "[ChatListView] voice play start messageId=%@ accepted=%@ duration=%.2f",
        messageId,
        isPlaying.description,
        nextPlayer.duration
      )
      ensureDisplayLink()
      cell.applyVoicePlaybackState(isPlaying: isPlaying, progress: 0.0, level: 0.0)
    } catch {
      NSLog(
        "[ChatListView] voice play failed messageId=%@ error=%@",
        messageId,
        String(describing: error)
      )
      stopActivePlayback(resetProgress: true)
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    NSLog("[ChatListView] voice completed success=%@", flag.description)
    stopActivePlayback(resetProgress: true)
  }

  private func ensureDisplayLink() {
    if displayLink != nil {
      return
    }
    let link = CADisplayLink(target: self, selector: #selector(handleDisplayTick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func handleDisplayTick() {
    guard let player else {
      stopActivePlayback(resetProgress: true)
      return
    }
    if player.duration > 0 {
      playbackProgress = CGFloat(player.currentTime / player.duration)
    } else {
      playbackProgress = 0.0
    }
    playbackProgress = max(0.0, min(1.0, playbackProgress))
    player.updateMeters()
    let db = player.averagePower(forChannel: 0)
    let minDb: Float = -48.0
    let normalized = (db - minDb) / (-minDb)
    level = max(0.0, min(1.0, CGFloat(normalized)))
    if !player.isPlaying && playbackProgress >= 0.999 {
      stopActivePlayback(resetProgress: true)
      return
    }
    activeCell?.applyVoicePlaybackState(
      isPlaying: player.isPlaying, progress: playbackProgress, level: level
    )
  }

  private func stopActivePlayback(resetProgress: Bool) {
    activeDownloadTask?.cancel()
    activeDownloadTask = nil
    player?.stop()
    player = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    isPlaying = false
    displayLink?.invalidate()
    displayLink = nil
    if resetProgress {
      playbackProgress = 0.0
      level = 0.0
    }
    activeCell?.applyVoicePlaybackState(
      isPlaying: false,
      progress: playbackProgress,
      level: level
    )
    activeMessageId = nil
    activeCell = nil
  }

  private func resolveAudioURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Sandbox path remapping: App UUIDs change on update/build, breaking absolute paths.
    var pathString = trimmed
    if trimmed.hasPrefix("file://") {
      let encoded =
        trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
      if let url = URL(string: trimmed) ?? URL(string: encoded) {
        pathString = url.path
      } else {
        pathString =
          String(trimmed.dropFirst(7)).removingPercentEncoding ?? String(trimmed.dropFirst(7))
      }
    }

    if pathString.contains("/Application/") || pathString.contains("/Containers/") {
      let sandboxTargets = ["/Library/", "/Documents/", "/tmp/"]
      for target in sandboxTargets {
        if let range = pathString.range(of: target, options: .backwards) {
          let suffix = pathString[range.lowerBound...]
          let patchedPath = NSHomeDirectory() + suffix
          NSLog(
            "[ChatListView] voice path remap original=%@ patched=%@",
            shortMediaURL(raw),
            patchedPath
          )
          return URL(fileURLWithPath: patchedPath)
        }
      }
    }

    if let url = URL(string: trimmed), url.isFileURL {
      return url
    }
    if trimmed.hasPrefix("/") {
      return URL(fileURLWithPath: trimmed)
    }
    if let decoded = trimmed.removingPercentEncoding, decoded.hasPrefix("/") {
      return URL(fileURLWithPath: decoded)
    }
    if let url = URL(string: trimmed), let scheme = url.scheme,
      scheme == "http" || scheme == "https"
    {
      return url
    }
    if let url = URL(string: trimmed), url.scheme == nil {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }

  private func shortMediaURL(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "-" }
    if raw.count <= 120 { return raw }
    return String(raw.prefix(117)) + "..."
  }
}

final class ChatListCell: UICollectionViewCell, VoicePlayableCell {
  static let reuseIdentifier = "ChatListCell"
  private static let reactionBadgeBaseSize = CGSize(width: 34.0, height: 24.0)
  private static let reactionBadgeInsetLeft: CGFloat = 8.0
  private static let reactionBadgeInsetBottom: CGFloat = 6.0

  let bubbleView = BubbleBackgroundView()
  let tailView = BubbleTailView()

  private let messageLabel = AgentStreamingLabel()
  private let mediaContainerView = UIView()
  private let mediaImageView = UIImageView()
  private let mediaStickerAnimationView = LottieAnimationView()
  private let mediaPrimaryIconView = UIImageView()
  private let mediaVoiceButtonView = VoicePlayProgressView()
  private let mediaTitleLabel = UILabel()
  private let mediaDetailLabel = UILabel()
  private let mediaWaveformView = VoiceWaveformView()
  private let mediaDurationBadge = UILabel()
  private let mediaProgressOverlayView = UIView()
  private let mediaProgressRingView = BubbleUploadProgressView()
  private let mediaProgressSpinner = UIActivityIndicatorView(style: .medium)
  private let inlineAttachmentView = UIView()
  private let inlineAttachmentIconView = UIImageView()
  private let inlineAttachmentTitleLabel = UILabel()
  private let inlineAttachmentSubtitleLabel = UILabel()
  let metaContainerView = UIView()
  private let editedLabel = UILabel()
  private let pinnedLabel = UILabel()
  private let timestampLabel = UILabel()
  private let statusImageView = UIImageView()
  private let statusLabel = UILabel()
  private let dayLabel = UILabel()
  private let reactionPillView = UIView()
  private let reactionLabel = UILabel()
  private var appearance = ChatListAppearance.fallback
  private var row: ChatListRow?
  private var isGhostHidden = false
  private var isContextMenuExtracted = false
  private var isContextMenuHeld = false
  private var savedBubbleHiddenBeforeExtraction = false
  private var savedTailHiddenBeforeExtraction = false
  private var savedReactionHiddenBeforeExtraction = false
  private var savedMessageAlphaBeforeExtraction: CGFloat = 1.0
  private var savedMediaAlphaBeforeExtraction: CGFloat = 1.0
  private var savedMetaAlphaBeforeExtraction: CGFloat = 0.72
  private var hasSavedExtractionState = false
  private var cellHoldAnchorApplied = false
  private var contentViewHoldAnchorApplied = false
  private var externalVoiceMessageId: String?
  private var externalVoiceIsPlaying = false
  private var externalVoiceProgress: CGFloat = 0.0
  private var cachedLayoutMetrics: ChatMessageBubbleLayoutMetrics?
  private var cachedLayoutWidth: CGFloat = 0
  private var mediaImageTask: URLSessionDataTask?
  private var currentStickerAnimationKey: String?
  private let fullBleedMaskLayer = CAShapeLayer()
  private var lastReportedMediaSizeKey: String?
  private var lastReactionDebugSignature: String?
  var resolveDisplayStatus: ((ChatListRow) -> String?)?
  var onVoiceBubbleTap: ((ChatListRow) -> Void)?
  var onVoiceUploadCancelTap: ((ChatListRow) -> Void)?
  var onInlineAttachmentTap: ((ChatListRow) -> Void)?
  var onMediaNaturalSizeResolved: ((String?, String, CGSize) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)

    clipsToBounds = false
    contentView.clipsToBounds = false

    contentView.addSubview(bubbleView)
    contentView.addSubview(tailView)

    contentView.addSubview(messageLabel)
    contentView.addSubview(mediaContainerView)
    mediaContainerView.addSubview(mediaImageView)
    mediaContainerView.addSubview(mediaStickerAnimationView)
    mediaContainerView.addSubview(mediaPrimaryIconView)
    mediaContainerView.addSubview(mediaVoiceButtonView)
    mediaContainerView.addSubview(mediaTitleLabel)
    mediaContainerView.addSubview(mediaDetailLabel)
    mediaContainerView.addSubview(mediaWaveformView)
    mediaContainerView.addSubview(mediaDurationBadge)
    mediaContainerView.addSubview(mediaProgressOverlayView)
    mediaProgressOverlayView.addSubview(mediaProgressRingView)
    mediaProgressOverlayView.addSubview(mediaProgressSpinner)
    inlineAttachmentView.addSubview(inlineAttachmentIconView)
    inlineAttachmentView.addSubview(inlineAttachmentTitleLabel)
    inlineAttachmentView.addSubview(inlineAttachmentSubtitleLabel)
    contentView.addSubview(inlineAttachmentView)
    contentView.addSubview(metaContainerView)
    metaContainerView.addSubview(editedLabel)
    metaContainerView.addSubview(pinnedLabel)
    metaContainerView.addSubview(timestampLabel)
    metaContainerView.addSubview(statusImageView)
    metaContainerView.addSubview(statusLabel)
    contentView.addSubview(dayLabel)

    contentView.addSubview(reactionPillView)
    reactionPillView.addSubview(reactionLabel)

    messageLabel.numberOfLines = 0
    messageLabel.font = bubbleMessageFont
    messageLabel.textColor = .white

    mediaContainerView.clipsToBounds = true
    mediaContainerView.layer.cornerCurve = .continuous
    mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.16)

    mediaImageView.backgroundColor = .clear
    mediaImageView.contentMode = .scaleAspectFill
    mediaImageView.clipsToBounds = true

    mediaStickerAnimationView.backgroundColor = .clear
    mediaStickerAnimationView.contentMode = .scaleAspectFit
    mediaStickerAnimationView.loopMode = .loop
    mediaStickerAnimationView.backgroundBehavior = .pauseAndRestore
    mediaStickerAnimationView.isUserInteractionEnabled = false
    mediaStickerAnimationView.isHidden = true

    mediaPrimaryIconView.tintColor = .white
    mediaPrimaryIconView.contentMode = .scaleAspectFit

    mediaVoiceButtonView.clipsToBounds = false
    mediaVoiceButtonView.isUserInteractionEnabled = true
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleVoiceTap))
    mediaVoiceButtonView.addGestureRecognizer(tap)
    mediaVoiceButtonView.applyStyle(
      fillColor: UIColor(white: 1.0, alpha: 0.96),
      iconTint: appearance.bubbleMeGradient.first ?? UIColor.systemBlue,
      ringTint: UIColor.white.withAlphaComponent(0.65))

    mediaTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    mediaTitleLabel.textColor = .white
    mediaTitleLabel.numberOfLines = 1

    mediaDetailLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
    mediaDetailLabel.textColor = UIColor(white: 1.0, alpha: 0.82)
    mediaDetailLabel.numberOfLines = 1

    mediaDurationBadge.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    mediaDurationBadge.textColor = .white
    mediaDurationBadge.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
    mediaDurationBadge.textAlignment = .center
    mediaDurationBadge.clipsToBounds = true
    mediaDurationBadge.layer.cornerRadius = 10.0
    mediaDurationBadge.layer.cornerCurve = .continuous

    mediaProgressOverlayView.backgroundColor = UIColor(white: 0.0, alpha: 0.32)
    mediaProgressOverlayView.clipsToBounds = true
    mediaProgressOverlayView.layer.cornerCurve = .continuous

    mediaProgressSpinner.color = UIColor(white: 1.0, alpha: 0.85)
    mediaProgressSpinner.hidesWhenStopped = true

    inlineAttachmentView.layer.cornerCurve = .continuous
    inlineAttachmentView.layer.cornerRadius = 12.0
    inlineAttachmentView.clipsToBounds = true
    inlineAttachmentView.isUserInteractionEnabled = true
    let attachmentTap = UITapGestureRecognizer(
      target: self, action: #selector(handleInlineAttachmentTap))
    inlineAttachmentView.addGestureRecognizer(attachmentTap)

    inlineAttachmentIconView.contentMode = .scaleAspectFit
    inlineAttachmentIconView.tintColor = .white
    inlineAttachmentIconView.image = UIImage(systemName: "doc.text.fill")

    inlineAttachmentTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    inlineAttachmentTitleLabel.textColor = .white
    inlineAttachmentTitleLabel.numberOfLines = 1

    inlineAttachmentSubtitleLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
    inlineAttachmentSubtitleLabel.textColor = UIColor(white: 1.0, alpha: 0.72)
    inlineAttachmentSubtitleLabel.numberOfLines = 1

    editedLabel.font = bubbleMetaFont
    pinnedLabel.font = bubbleMetaFont
    timestampLabel.font = bubbleMetaFont
    timestampLabel.textColor = UIColor(white: 1.0, alpha: 0.72)
    statusImageView.contentMode = .scaleAspectFit
    statusImageView.isHidden = true
    statusLabel.font = bubbleMetaStatusFont
    statusLabel.textAlignment = .center

    dayLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    dayLabel.textAlignment = .center
    dayLabel.textColor = UIColor(white: 0.95, alpha: 0.9)

    reactionPillView.backgroundColor = UIColor(white: 0.0, alpha: 0.25)
    reactionPillView.layer.cornerRadius = 12
    reactionPillView.layer.cornerCurve = .continuous
    reactionPillView.clipsToBounds = true
    reactionPillView.layer.borderWidth = 1.0 / UIScreen.main.scale
    reactionPillView.layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor

    reactionLabel.font = UIFont.systemFont(ofSize: 14)
    reactionLabel.textAlignment = .center

    bubbleView.isHidden = true
    tailView.isHidden = true
    // agentSenderLabel removed
    messageLabel.isHidden = true
    mediaContainerView.isHidden = true
    mediaPrimaryIconView.isHidden = true
    mediaVoiceButtonView.isHidden = true
    mediaTitleLabel.isHidden = true
    mediaDetailLabel.isHidden = true
    mediaWaveformView.isHidden = true
    mediaDurationBadge.isHidden = true
    mediaProgressOverlayView.isHidden = true
    inlineAttachmentView.isHidden = true
    metaContainerView.isHidden = true
    editedLabel.isHidden = true
    pinnedLabel.isHidden = true
    timestampLabel.isHidden = true
    statusImageView.isHidden = true
    statusLabel.isHidden = true
    dayLabel.isHidden = true
    reactionPillView.isHidden = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateStickerAnimationPlayback()
  }

  func currentMediaImage() -> UIImage? {
    mediaImageView.image
  }

  func applyAppearance(_ appearance: ChatListAppearance) {
    self.appearance = appearance
    dayLabel.textColor = appearance.dayTextColor
    dayLabel.backgroundColor = appearance.dayBackgroundColor
    dayLabel.layer.borderColor = appearance.dayBorderColor.cgColor
    dayLabel.layer.borderWidth = 0.5
    dayLabel.layer.cornerRadius = 12.0
    dayLabel.clipsToBounds = true
    mediaWaveformView.applyColors(
      active: appearance.textColorThem.withAlphaComponent(0.95),
      inactive: appearance.textColorThem.withAlphaComponent(0.26)
    )
    mediaVoiceButtonView.applyStyle(
      fillColor: UIColor(white: 1.0, alpha: 0.96),
      iconTint: appearance.bubbleMeGradient.first ?? UIColor.systemBlue,
      ringTint: appearance.textColorThem.withAlphaComponent(0.68))
    setNeedsLayout()
  }

  func configure(row: ChatListRow, hiddenMessageId: String?) {
    self.row = row
    cachedLayoutMetrics = nil
    switch row.kind {
    case .day:
      isGhostHidden = false
      resetStickerAnimation()
      dayLabel.text = row.label
      dayLabel.isHidden = false
      bubbleView.isHidden = true
      tailView.isHidden = true
      messageLabel.isHidden = true
      mediaContainerView.isHidden = true
      inlineAttachmentView.isHidden = true
      metaContainerView.isHidden = true
      reactionPillView.isHidden = true
      mediaProgressSpinner.stopAnimating()
      mediaProgressOverlayView.isHidden = true
    case .message:
      let isGhostHidden = hiddenMessageId == row.messageId
      self.isGhostHidden = isGhostHidden
      dayLabel.isHidden = true
      bubbleView.isHidden = false
      tailView.isHidden = isGhostHidden || !row.shape.showTail
      messageLabel.isHidden = isGhostHidden || row.visualKind != .text
      if row.messageType == "typing" {
        startTypingShimmer()
        messageLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
      } else {
        stopTypingShimmer()
        messageLabel.font = bubbleMessageFont
      }
      mediaContainerView.isHidden = isGhostHidden || row.visualKind == .text
      inlineAttachmentView.isHidden = isGhostHidden || !hasInlineFileAttachment(row)
      metaContainerView.isHidden = isGhostHidden

      // Agent/Mention labeling
      let isTyping = row.messageType == "typing"
      let messageFont =
        isTyping ? UIFont.systemFont(ofSize: 13, weight: .regular) : bubbleMessageFont
      let resolveTextColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
      let displayText = bubbleDisplayAttributedString(
        for: row, font: messageFont, textColor: resolveTextColor)
      messageLabel.applyAgentText(
        displayText,
        isStreaming: row.isAgentMessage && row.isStreamingText && row.messageType != "typing"
      )
      editedLabel.text = "edited"
      pinnedLabel.text = "pinned"
      editedLabel.isHidden = !row.isEdited
      pinnedLabel.isHidden = !row.isPinned
      timestampLabel.text = row.timestamp

      if let reactionEmoji = row.reactionEmoji, !reactionEmoji.isEmpty {
        reactionPillView.isHidden = isGhostHidden
        reactionLabel.text = reactionEmoji
        reactionPillView.backgroundColor =
          row.isMe
          ? UIColor(white: 1.0, alpha: 0.18)
          : UIColor(white: 0.0, alpha: 0.24)
        reactionDebugLog(
          "configure id=\(row.messageId ?? "nil") emoji=\(reactionEmoji) hidden=\(isGhostHidden ? "Y" : "N")"
        )
      } else {
        reactionPillView.isHidden = true
      }

      if row.isAgentMessage {
        // Agent messages use "them" styling (not isMe) with a subtle tint
        bubbleView.configure(
          isMe: false, shape: row.shape, hidden: isGhostHidden, appearance: appearance)
        bubbleView.applyAgentStyle(appearance: appearance, isMe: false)
        tailView.configure(
          isMe: false,
          visible: !isGhostHidden && row.shape.showTail,
          appearance: appearance
        )
        tailView.applyAgentTailStyle(appearance: appearance, isMe: false)
      } else if row.isAgentMention {
        // Agent mention by ME uses "me" styling with glow
        bubbleView.configure(
          isMe: true, shape: row.shape, hidden: isGhostHidden, appearance: appearance)
        bubbleView.applyAgentStyle(appearance: appearance, isMe: true)
        tailView.configure(
          isMe: true,
          visible: !isGhostHidden && row.shape.showTail,
          appearance: appearance
        )
        tailView.applyAgentTailStyle(appearance: appearance, isMe: true)
      } else {
        bubbleView.clearAgentStyle()
        tailView.clearAgentTailStyle()
        let hideBubbleForTyping = row.messageType == "typing"
        let hideBubbleForSticker = isTransparentStickerMessage(row)
        let hideBubbleForFullBleedMedia = usesFullBleedMediaLayout(row)
        let hideBubbleChrome = hideBubbleForTyping || hideBubbleForSticker || hideBubbleForFullBleedMedia
        bubbleView.configure(
          isMe: row.isMe, shape: row.shape, hidden: isGhostHidden || hideBubbleChrome,
          appearance: appearance)
        tailView.configure(
          isMe: row.isMe,
          visible: !isGhostHidden && row.shape.showTail && !hideBubbleChrome,
          appearance: appearance
        )
        if hideBubbleForSticker {
          tailView.setImage(nil)
        }
      }
      let textColor =
        row.isMe
        ? appearance.textColorMe
        : (row.isAgentMessage ? appearance.textColorThem : appearance.textColorThem)
      let metaColor = resolvedMetaColor(for: textColor)
      messageLabel.textColor = textColor
      editedLabel.textColor = metaColor
      pinnedLabel.textColor = metaColor
      timestampLabel.textColor = metaColor
      configureMediaPresentation(for: row, textColor: textColor, metaColor: metaColor)
      if !inlineAttachmentView.isHidden {
        inlineAttachmentView.backgroundColor = UIColor(white: 0.0, alpha: 0.20)
        inlineAttachmentTitleLabel.text = row.fileName?.isEmpty == false ? row.fileName : "Document"
        inlineAttachmentSubtitleLabel.text = "Tap to open"
      } else {
        inlineAttachmentTitleLabel.text = nil
        inlineAttachmentSubtitleLabel.text = nil
      }
      configureStatus(for: row, baseColor: metaColor)
      if row.visualKind == .voice {
        VoiceBubblePlaybackCoordinator.shared.bind(
          cell: self, messageId: row.messageId)
        applyExternalVoicePlaybackIfNeeded()
      } else {
        VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
      }
      // Use full opacity — visibility is controlled by isHidden, not alpha.
      // This eliminates the 0→1 opacity flicker that plagued updates.
      messageLabel.alpha = 1.0
      mediaContainerView.alpha = 1.0
      metaContainerView.alpha = 0.72
      reactionPillView.alpha = 1.0
    }

    if hasSavedExtractionState {
      savedBubbleHiddenBeforeExtraction = bubbleView.isHidden
      savedTailHiddenBeforeExtraction = tailView.isHidden
      savedReactionHiddenBeforeExtraction = reactionPillView.isHidden
      savedMessageAlphaBeforeExtraction = messageLabel.alpha
      savedMediaAlphaBeforeExtraction = mediaContainerView.alpha
      savedMetaAlphaBeforeExtraction = metaContainerView.alpha
    }

    applyContextMenuExtractionIfNeeded()
    setNeedsLayout()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
    bubbleView.clearAgentStyle()
    tailView.clearAgentTailStyle()
    onVoiceBubbleTap = nil
    onVoiceUploadCancelTap = nil
    onInlineAttachmentTap = nil
    onMediaNaturalSizeResolved = nil
    row = nil
    cachedLayoutMetrics = nil
    isGhostHidden = false
    mediaProgressSpinner.stopAnimating()
    mediaProgressOverlayView.isHidden = true
    mediaProgressRingView.setProgress(nil)
    reactionPillView.isHidden = true
    externalVoiceMessageId = nil
    externalVoiceIsPlaying = false
    externalVoiceProgress = 0.0
    lastReportedMediaSizeKey = nil
    resolveDisplayStatus = nil
    applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
    mediaWaveformView.setWaveform(nil)
    statusImageView.isHidden = true
    statusImageView.image = nil
    statusLabel.isHidden = true
    statusLabel.text = nil
    isContextMenuExtracted = false
    isContextMenuHeld = false
    hasSavedExtractionState = false
    mediaImageTask?.cancel()
    mediaImageTask = nil
    mediaImageView.image = nil
    resetStickerAnimation()
    lastReactionDebugSignature = nil
    applyContextMenuExtractionIfNeeded()
    applyContextMenuHoldIfNeeded(animated: false, strategy: "scaleCell")
    contentView.alpha = 1.0
    contentView.transform = .identity
    layer.removeAllAnimations()
    contentView.layer.removeAllAnimations()
    stopTypingShimmer()
    messageLabel.resetStreamingState()
  }

  private func startTypingShimmer() {
    stopTypingShimmer()  // Clear any existing
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.white.withAlphaComponent(0.4).cgColor,
      UIColor.white.withAlphaComponent(1.0).cgColor,
      UIColor.white.withAlphaComponent(0.4).cgColor,
    ]
    gradientLayer.locations = [0.0, 0.5, 1.0]
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
    // We update the frame after layout in layoutSubviews, but for now set a placeholder
    gradientLayer.frame = CGRect(x: -200, y: 0, width: 600, height: 40)
    messageLabel.layer.mask = gradientLayer

    let animation = CABasicAnimation(keyPath: "transform.translation.x")
    animation.fromValue = -200
    animation.toValue = 200
    animation.duration = 1.5
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false

    gradientLayer.add(animation, forKey: "shimmerTranslation")
  }

  private func stopTypingShimmer() {
    messageLabel.layer.mask?.removeAnimation(forKey: "shimmerTranslation")
    messageLabel.layer.mask = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let row else {
      return
    }

    let bounds = contentView.bounds
    if row.kind == .day {
      let textSize = dayLabel.sizeThatFits(CGSize(width: bounds.width - 16, height: 24))
      let width = min(bounds.width - 8, ceil(textSize.width) + (dayPillHorizontalPadding * 2.0))
      let height = ceil(textSize.height) + (dayPillVerticalPadding * 2.0)
      dayLabel.frame = CGRect(
        x: floor((bounds.width - width) * 0.5),
        y: floor((bounds.height - height) * 0.5),
        width: width,
        height: height
      )
      return
    }

    let metrics: ChatMessageBubbleLayoutMetrics
    if let cached = cachedLayoutMetrics, cachedLayoutWidth == bounds.width {
      metrics = cached
    } else {
      metrics = measureMessageBubbleLayout(row: row, rowWidth: bounds.width)
      cachedLayoutMetrics = metrics
      cachedLayoutWidth = bounds.width
    }
    let bubbleWidth = metrics.bubbleWidth
    let bubbleHeight = metrics.bubbleHeight
    let bubbleX = row.isMe ? bounds.width - bubbleWidth - bubbleSideMargin : bubbleSideMargin
    let bubbleY = max(0.0, bounds.height - bubbleHeight)
    let bubbleFrame = pixelAlignedRect(
      CGRect(
        x: floor(bubbleX),
        y: floor(bubbleY),
        width: ceil(bubbleWidth),
        height: ceil(bubbleHeight)
      ))

    // Agent sender label removed (now using inline icon)

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    bubbleView.frame = bubbleFrame
    let isTransparentSticker = isTransparentStickerMessage(row)
    let hideBubbleChrome = row.messageType == "typing" || isTransparentSticker
    let isFullBleed = metrics.isMediaLayout && usesFullBleedMediaLayout(row)
    let metaTopSpacing = effectiveMetaTopSpacing(for: row)

    let showTail = row.shape.showTail && !isGhostHidden
      && !(row.messageType == "typing" || isTransparentStickerMessage(row))
    if showTail {
      // IMPORTANT: tailView has a rotation+flip transform applied, so we MUST NOT
      // set .frame (undefined behavior per Apple docs). Use bounds + center instead.
      let tailSize: CGFloat = 29
      let tailX = row.isMe ? bubbleFrame.maxX - 1 : bubbleFrame.minX - 28
      let tailY = bubbleFrame.maxY - tailSize
      tailView.bounds = CGRect(origin: .zero, size: CGSize(width: tailSize, height: tailSize))
      tailView.center = CGPoint(x: tailX + tailSize * 0.5, y: tailY + tailSize * 0.5)
      tailView.isHidden = false
      if isFullBleed {
        let img = mediaImageView.image
        tailView.setImage(img)
        // Hide tail until media image loads to avoid bubble-colored tail flash
        if img == nil { tailView.isHidden = true }
      } else {
        tailView.setImage(nil)
        tailView.configure(isMe: row.isMe, visible: true, appearance: appearance)
      }
    } else {
      tailView.setImage(nil)
      tailView.isHidden = true
    }

    if metrics.isMediaLayout {
      let mediaFrame: CGRect
      if isFullBleed {
        mediaFrame = pixelAlignedRect(bubbleFrame.insetBy(dx: -0.6, dy: -0.6))
      } else if isTransparentSticker {
        let mediaX = row.isMe ? (bubbleFrame.maxX - metrics.contentWidth) : bubbleFrame.minX
        mediaFrame = pixelAlignedRect(
          CGRect(
            x: mediaX,
            y: bubbleFrame.minY,
            width: metrics.contentWidth,
            height: metrics.mediaHeight
          ))
      } else {
        mediaFrame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + bubbleHorizontalPadding,
            y: bubbleFrame.minY + bubbleTopPadding,
            width: metrics.contentWidth,
            height: metrics.mediaHeight
          ))
      }
      mediaContainerView.frame = mediaFrame
      if let r = self.row, r.visualKind != .text && r.visualKind != .voice {
        NSLog(
          "[ChatMediaLayout] msgId=%@ containerFrame=%@ hidden=%@ alpha=%.2f imgHidden=%@ hasImg=%@ bubbleFrame=%@",
          r.messageId ?? "-",
          NSCoder.string(for: mediaFrame),
          mediaContainerView.isHidden ? "Y" : "N",
          mediaContainerView.alpha,
          mediaImageView.isHidden ? "Y" : "N",
          mediaImageView.image != nil ? "Y" : "N",
          NSCoder.string(for: bubbleFrame)
        )
      }

      messageLabel.frame = .zero
      let metaX =
        isFullBleed
        ? (bubbleFrame.maxX - metrics.metaWidth - 10)
        : isTransparentSticker
        ? (bubbleFrame.maxX - metrics.metaWidth)
        : (bubbleFrame.maxX - bubbleHorizontalPadding - metrics.metaWidth)
      let metaY: CGFloat
      if isFullBleed {
        metaY = bubbleFrame.maxY - bubbleMetaHeight - 8
      } else if row.visualKind == .voice {
        metaY = mediaFrame.maxY - bubbleMetaHeight + 2.0
      } else {
        metaY = mediaFrame.maxY + metaTopSpacing
      }

      metaContainerView.frame = pixelAlignedRect(
        CGRect(
          x: metaX,
          y: metaY,
          width: metrics.metaWidth,
          height: bubbleMetaHeight
        ))

      // The background for meta inside full bleed needs to be darker so it's illegible
      // over image
      if isFullBleed {
        // Typically we add a shadow or dark background pill for meta over media.
      }

      mediaProgressOverlayView.frame = mediaContainerView.bounds
      mediaImageView.frame = mediaContainerView.bounds
      mediaStickerAnimationView.frame = mediaContainerView.bounds
      layoutMediaSubviews(for: row, in: mediaContainerView.bounds)
      inlineAttachmentView.frame = .zero
    } else {
      mediaContainerView.frame = .zero
      if metrics.hasInlineAttachment {
        messageLabel.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + bubbleHorizontalPadding,
            y: bubbleFrame.minY + bubbleTopPadding,
            width: metrics.messageWidth,
            height: metrics.textHeight
          ))
        inlineAttachmentView.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + bubbleHorizontalPadding,
            y: messageLabel.frame.maxY + inlineAttachmentSpacing,
            width: metrics.contentWidth,
            height: metrics.inlineAttachmentHeight
          ))
        metaContainerView.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.maxX - bubbleHorizontalPadding - metrics.metaWidth,
            y: inlineAttachmentView.frame.maxY + bubbleMetaTopSpacing,
            width: metrics.metaWidth,
            height: bubbleMetaHeight
          ))

        let iconSize: CGFloat = 18.0
        inlineAttachmentIconView.frame = CGRect(x: 12.0, y: 15.0, width: iconSize, height: iconSize)
        inlineAttachmentTitleLabel.frame = CGRect(
          x: inlineAttachmentIconView.frame.maxX + 10.0,
          y: 8.0,
          width: max(
            1.0, inlineAttachmentView.bounds.width - inlineAttachmentIconView.frame.maxX - 22.0),
          height: 18.0
        )
        inlineAttachmentSubtitleLabel.frame = CGRect(
          x: inlineAttachmentTitleLabel.frame.minX,
          y: inlineAttachmentTitleLabel.frame.maxY + 1.0,
          width: inlineAttachmentTitleLabel.frame.width,
          height: 15.0
        )
      } else {
        inlineAttachmentView.frame = .zero
        messageLabel.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + bubbleHorizontalPadding,
            y: bubbleFrame.minY + bubbleTopPadding
              + max(0.0, metrics.bodyHeight - metrics.textHeight),
            width: metrics.messageWidth,
            height: metrics.textHeight
          ))
        metaContainerView.frame = pixelAlignedRect(
          CGRect(
            x: messageLabel.frame.maxX + bubbleMetaInlineSpacing,
            y: bubbleFrame.minY + bubbleTopPadding + metrics.bodyHeight - bubbleMetaHeight,
            width: metrics.metaWidth,
            height: bubbleMetaHeight
          ))
      }
    }

    updateStickerAnimationPlayback()

    layoutMetaLabels(for: row)

    if row.messageType == "typing" {
      if let mask = messageLabel.layer.mask as? CAGradientLayer {
        mask.frame = CGRect(
          x: -messageLabel.bounds.width * 2, y: 0, width: messageLabel.bounds.width * 5,
          height: messageLabel.bounds.height)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -messageLabel.bounds.width * 2
        animation.toValue = messageLabel.bounds.width * 2
        animation.duration = 1.5
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        mask.add(animation, forKey: "shimmerTranslation")
      }
    }

    let reactionFrame = pixelAlignedRect(reactionBadgeFrame(in: bubbleFrame))
    reactionPillView.frame = reactionFrame
    reactionPillView.layer.cornerRadius = floor(reactionFrame.height * 0.5)
    reactionLabel.frame = CGRect(
      x: 0.0,
      y: 0.0,
      width: reactionFrame.width,
      height: reactionFrame.height
    )

    if !reactionPillView.isHidden {
      let signature =
        "\(row.messageId ?? "nil"):\(Int(reactionFrame.origin.x)):\(Int(reactionFrame.origin.y)):\(reactionLabel.text ?? "nil")"
      if signature != lastReactionDebugSignature {
        lastReactionDebugSignature = signature
        reactionDebugLog(
          "layout success id=\(row.messageId ?? "nil") frame=\(reactionFrame) hidden=\(isGhostHidden ? "Y" : "N")"
        )
      }
    }

    CATransaction.commit()
  }

  private func configureMediaPresentation(
    for row: ChatListRow, textColor: UIColor, metaColor: UIColor
  ) {
    let isTransparentSticker = isTransparentStickerMessage(row)
    if row.visualKind != .sticker {
      resetStickerAnimation()
    }
    mediaPrimaryIconView.isHidden = true
    mediaVoiceButtonView.isHidden = true
    mediaTitleLabel.isHidden = true
    mediaDetailLabel.isHidden = true
    mediaWaveformView.isHidden = true
    mediaDurationBadge.isHidden = true
    mediaImageView.isHidden = true
    mediaStickerAnimationView.isHidden = true
    mediaImageView.image = nil
    mediaImageTask?.cancel()
    mediaImageTask = nil
    mediaPrimaryIconView.image = nil
    mediaTitleLabel.text = nil
    mediaDetailLabel.text = nil
    mediaDurationBadge.text = nil
    mediaWaveformView.setWaveform(nil)
    mediaVoiceButtonView.setUploadState(isUploading: false, progress: nil)
    mediaVoiceButtonView.isUserInteractionEnabled = true

    mediaTitleLabel.textColor = textColor
    mediaTitleLabel.textAlignment = .left
    mediaTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    mediaDetailLabel.textColor = metaColor
    mediaDetailLabel.textAlignment = .right
    mediaDetailLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
    mediaContainerView.clipsToBounds = !isTransparentSticker
    let isFullBleedMedia = usesFullBleedMediaLayout(row)
    mediaContainerView.backgroundColor =
      isTransparentSticker ? .clear
      : isFullBleedMedia ? UIColor(white: 0.0, alpha: 0.28)
      : UIColor(white: 0.0, alpha: 0.16)
    mediaImageView.contentMode = isTransparentSticker ? .scaleAspectFit : .scaleAspectFill
    mediaImageView.clipsToBounds = !isTransparentSticker

    do {
      let vkName: String
      switch row.visualKind {
      case .text: vkName = "text"
      case .voice: vkName = "voice"
      case .video: vkName = "video"
      case .videoNote: vkName = "videoNote"
      case .media: vkName = "media"
      case .sticker: vkName = "sticker"
      }
      NSLog(
        "[ChatMediaCfg] msgId=%@ type=%@ vk=%@ isGhost=%@ containerHidden=%@ containerAlpha=%.2f bubbleHidden=%@ fullBleed=%@ mediaUrl=%@",
        row.messageId ?? "-",
        row.messageType,
        vkName,
        isGhostHidden ? "Y" : "N",
        mediaContainerView.isHidden ? "Y" : "N",
        mediaContainerView.alpha,
        bubbleView.isHidden ? "Y" : "N",
        isFullBleedMedia ? "Y" : "N",
        (row.mediaUrl?.prefix(80)).map(String.init) ?? "nil"
      )
    }

    guard row.visualKind != .text else {
      mediaProgressOverlayView.isHidden = true
      mediaProgressRingView.setProgress(nil)
      mediaProgressSpinner.stopAnimating()
      return
    }

    switch row.visualKind {
    case .voice:
      mediaVoiceButtonView.isHidden = false
      mediaTitleLabel.isHidden = true
      mediaDetailLabel.isHidden = false
      mediaWaveformView.isHidden = false
      mediaDetailLabel.text = "\(formatBubbleDuration(seconds: row.duration)) \u{2022}"
      mediaDetailLabel.textAlignment = .left
      mediaDetailLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
      mediaContainerView.backgroundColor = .clear
      mediaWaveformView.setWaveform(row.waveform)
      mediaWaveformView.applyColors(
        active: textColor.withAlphaComponent(0.95),
        inactive: textColor.withAlphaComponent(0.34)
      )
      mediaVoiceButtonView.applyStyle(
        fillColor: UIColor(white: 1.0, alpha: row.isMe ? 0.96 : 0.90),
        iconTint: row.isMe
          ? (appearance.bubbleMeGradient.first ?? UIColor.systemBlue)
          : textColor.withAlphaComponent(0.95),
        ringTint: textColor.withAlphaComponent(0.74)
      )
      let uploadProgress: CGFloat?
      if let value = row.uploadProgress, value.isFinite {
        uploadProgress = CGFloat(max(0.0, min(1.0, value)))
      } else {
        uploadProgress = nil
      }
      mediaVoiceButtonView.setUploadState(
        isUploading: row.shouldShowUploadOverlay,
        progress: uploadProgress
      )
      mediaVoiceButtonView.isUserInteractionEnabled = true

    case .video:
      mediaImageView.isHidden = false
      mediaPrimaryIconView.isHidden = false
      mediaPrimaryIconView.image = UIImage(systemName: "play.fill")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 26, weight: .bold))
      if row.duration != nil {
        mediaDurationBadge.isHidden = false
        mediaDurationBadge.text = "  \(formatBubbleDuration(seconds: row.duration))  "
      }
      mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.35)

    case .videoNote:
      mediaImageView.isHidden = false
      mediaPrimaryIconView.isHidden = false
      mediaPrimaryIconView.image = UIImage(systemName: "play.fill")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 30, weight: .bold))
      if row.duration != nil {
        mediaDurationBadge.isHidden = false
        mediaDurationBadge.text = "  \(formatBubbleDuration(seconds: row.duration))  "
      }
      mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.4)

    case .media, .sticker:
      mediaImageView.isHidden = false
      mediaPrimaryIconView.isHidden = false
      let symbolName: String
      switch row.messageType {
      case "image", "gif", "sticker":
        symbolName = "photo.fill"
      case "file":
        symbolName = "doc.fill"
      default:
        symbolName = "paperclip"
      }
      mediaPrimaryIconView.image = UIImage(systemName: symbolName)?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 25, weight: .semibold))
      if row.messageType == "file" {
        mediaTitleLabel.isHidden = false
        mediaTitleLabel.text = row.fileName?.isEmpty == false ? row.fileName : "File"
        mediaTitleLabel.textAlignment = .center
        mediaImageView.isHidden = true
        mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.28)
        resetStickerAnimation()
      } else if row.visualKind == .sticker {
        mediaPrimaryIconView.isHidden = true
        mediaContainerView.backgroundColor = .clear
        if configureStickerAnimation(for: row) {
          // Lottie loaded — hide static image
          mediaImageView.isHidden = true
        } else if row.mediaUrl == nil || row.mediaUrl?.isEmpty == true {
          mediaImageView.isHidden = true
          mediaTitleLabel.isHidden = true
          NSLog(
            "[ChatStickerCell] missing sticker asset msgId=%@ stickerId=%@ bundle=%@ packId=%@ mediaUrl=%@",
            row.messageId ?? "-",
            row.stickerId ?? "-",
            row.stickerBundleFileName ?? "-",
            row.stickerPackId ?? "-",
            row.mediaUrl ?? "-"
          )
        }
      } else {
        mediaPrimaryIconView.isHidden = true
      }

    case .text:
      break
    }

    NSLog(
      "[ChatMediaCfg] POST-SWITCH msgId=%@ imgViewHidden=%@ imgViewImage=%@ containerBg=%@ containerFrame=%@",
      row.messageId ?? "-",
      mediaImageView.isHidden ? "Y" : "N",
      mediaImageView.image != nil ? "hasImage" : "nil",
      String(describing: mediaContainerView.backgroundColor),
      NSCoder.string(for: mediaContainerView.frame)
    )

    if mediaImageView.isHidden || row.mediaUrl == nil {
      if row.visualKind != .text && row.visualKind != .voice && row.visualKind != .sticker {
        NSLog(
          "[ChatMediaLoad] SKIP-LOAD msgId=%@ type=%@ imgHidden=%@ mediaUrl=%@",
          row.messageId ?? "-",
          row.messageType,
          mediaImageView.isHidden ? "Y" : "N",
          row.mediaUrl == nil ? "nil" : (row.mediaUrl?.isEmpty == true ? "empty" : "present")
        )
      }
    }
    if !mediaImageView.isHidden, let urlStr = row.mediaUrl {
      let cacheKey = chatMediaNormalizedKey(urlStr)
      let shortUrl = urlStr.count > 80 ? String(urlStr.prefix(77)) + "..." : urlStr
      let encodedUrlStr =
        urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr
      let shouldAnimateMedia = chatMediaShouldAnimate(
        urlString: urlStr,
        messageType: row.messageType
      )
      if let url = URL(string: urlStr) ?? URL(string: encodedUrlStr) {
        let inMemory = chatMediaImageCache.object(forKey: cacheKey as NSString) != nil
        let isLocal = url.isFileURL || urlStr.hasPrefix("/")
        let onDisk: Bool = {
          guard !isLocal else { return false }
          let dir = chatMediaDiskCacheDir()
          let filename = chatMediaDiskCacheKey(cacheKey)
          return FileManager.default.fileExists(atPath: dir.appendingPathComponent(filename).path)
        }()
        let isFailed = chatMediaFailedURLs.contains(cacheKey)
        NSLog(
          "[ChatMediaLoad] RESOLVE msgId=%@ inMemory=%@ isLocal=%@ onDisk=%@ isFailed=%@ animate=%@ url=%@",
          row.messageId ?? "-",
          inMemory ? "Y" : "N",
          isLocal ? "Y" : "N",
          onDisk ? "Y" : "N",
          isFailed ? "Y" : "N",
          shouldAnimateMedia ? "Y" : "N",
          shortUrl
        )
        if let cachedImage = chatMediaImageCache.object(forKey: cacheKey as NSString) {
          mediaImageView.image = cachedImage
          reportNaturalMediaSizeIfNeeded(for: row, mediaURL: urlStr, image: cachedImage)
        } else if url.isFileURL || urlStr.hasPrefix("/") {
          let path = url.isFileURL ? url.path : urlStr
          if let image = chatMediaLoadImageFromFile(at: path, shouldAnimate: shouldAnimateMedia) {
            NSLog("[ChatMediaLoad] local file OK msgId=%@ url=%@", row.messageId ?? "-", shortUrl)
            chatMediaImageCache.setObject(image, forKey: cacheKey as NSString)
            mediaImageView.image = image
            reportNaturalMediaSizeIfNeeded(for: row, mediaURL: urlStr, image: image)
          } else {
            NSLog("[ChatMediaLoad] local file MISSING msgId=%@ path=%@", row.messageId ?? "-", path)
          }
        } else if let diskData = chatMediaDiskCacheLoad(cacheKey),
          let diskImage = chatMediaDecodedImage(from: diskData, shouldAnimate: shouldAnimateMedia)
        {
          // Found on disk - restore to memory cache and display immediately.
          chatMediaImageCache.setObject(diskImage, forKey: cacheKey as NSString)
          mediaImageView.image = diskImage
          reportNaturalMediaSizeIfNeeded(for: row, mediaURL: urlStr, image: diskImage)
        } else if chatMediaFailedURLs.contains(cacheKey) {
          NSLog("[ChatMediaLoad] skipping previously failed url=%@", shortUrl)
        } else {
          NSLog(
            "[ChatMediaLoad] network fetch START msgId=%@ url=%@", row.messageId ?? "-", shortUrl)
          mediaImageTask = URLSession.shared.dataTask(with: url) {
            [weak self] data, response, error in
            if let error {
              let nsErr = error as NSError
              let isCancelled = nsErr.code == NSURLErrorCancelled
              NSLog(
                "[ChatMediaLoad] network fetch FAIL msgId=%@ error=%@ cancelled=%@",
                row.messageId ?? "-", error.localizedDescription, isCancelled ? "Y" : "N")
              if !isCancelled {
                let count = (chatMediaRetryCount[cacheKey] ?? 0) + 1
                chatMediaRetryCount[cacheKey] = count
                if count >= chatMediaMaxRetries {
                  chatMediaFailedURLs.insert(cacheKey)
                }
              }
              return
            }
            guard let self = self, let data = data,
              let image = chatMediaDecodedImage(from: data, shouldAnimate: shouldAnimateMedia)
            else {
              let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
              let bodyPreview = data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
              NSLog(
                "[ChatMediaLoad] network fetch NO_IMAGE msgId=%@ dataLen=%d status=%d url=%@ body=%@",
                row.messageId ?? "-",
                data?.count ?? 0, statusCode, urlStr, String(bodyPreview.prefix(200)))
              chatMediaFailedURLs.insert(cacheKey)
              return
            }
            NSLog(
              "[ChatMediaLoad] network fetch OK msgId=%@ bytes=%d", row.messageId ?? "-", data.count
            )
            // Save to both memory and disk cache
            chatMediaImageCache.setObject(image, forKey: cacheKey as NSString)
            chatMediaDiskCacheSave(data, forKey: cacheKey)
            DispatchQueue.main.async {
              self.mediaImageView.image = image
              self.reportNaturalMediaSizeIfNeeded(for: row, mediaURL: urlStr, image: image)
              if let metrics = self.cachedLayoutMetrics,
                metrics.isMediaLayout, usesFullBleedMediaLayout(row)
              {
                self.tailView.setImage(image)
                // Reveal tail now that media has loaded
                if let currentRow = self.row, currentRow.shape.showTail {
                  self.tailView.isHidden = false
                }
              }
            }
          }
          mediaImageTask?.resume()
        }
      } else {
        NSLog(
          "[ChatMediaLoad] URL parse FAIL msgId=%@ raw=%@", row.messageId ?? "-", shortUrl)
      }
    }

    if row.visualKind == .voice {
      mediaProgressOverlayView.isHidden = true
      mediaProgressRingView.setProgress(nil)
      mediaProgressSpinner.stopAnimating()
      return
    }

    if row.shouldShowUploadOverlay {
      mediaProgressOverlayView.isHidden = false
      let progress = row.uploadProgress
      if let progress, progress > 0.001 {
        mediaProgressRingView.isHidden = false
        mediaProgressRingView.setProgress(progress)
        mediaProgressSpinner.stopAnimating()
      } else {
        mediaProgressRingView.isHidden = true
        mediaProgressRingView.setProgress(nil)
        mediaProgressSpinner.startAnimating()
      }
    } else {
      mediaProgressOverlayView.isHidden = true
      mediaProgressRingView.setProgress(nil)
      mediaProgressSpinner.stopAnimating()
    }

    NSLog(
      "[ChatMediaCfg] FINAL msgId=%@ imgHidden=%@ hasImg=%@ containerHidden=%@ containerAlpha=%.2f containerBg=%@ containerFrame=%@",
      row.messageId ?? "-",
      mediaImageView.isHidden ? "Y" : "N",
      mediaImageView.image != nil ? "Y" : "N",
      mediaContainerView.isHidden ? "Y" : "N",
      mediaContainerView.alpha,
      String(describing: mediaContainerView.backgroundColor),
      NSCoder.string(for: mediaContainerView.frame)
    )
    updateStickerAnimationPlayback()
  }

  private func reportNaturalMediaSizeIfNeeded(
    for row: ChatListRow, mediaURL: String, image: UIImage
  ) {
    let size = image.size
    guard size.width > 1.0, size.height > 1.0 else { return }
    cacheNaturalMediaSize(size, for: mediaURL)
    let sizeKey = "\(mediaURL)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    if lastReportedMediaSizeKey == sizeKey {
      return
    }
    lastReportedMediaSizeKey = sizeKey
    onMediaNaturalSizeResolved?(row.messageId, mediaURL, size)
  }

  private func layoutMediaSubviews(for row: ChatListRow, in bounds: CGRect) {
    let width = bounds.width
    let height = bounds.height

    let isTransparentSticker = isTransparentStickerMessage(row)
    let isFullBleed = usesFullBleedMediaLayout(row)
    let cornerRadius: CGFloat
    switch row.visualKind {
    case .videoNote:
      cornerRadius = floor(min(width, height) * 0.5)
    case .voice:
      cornerRadius = 10.0
    default:
      cornerRadius = 12.0
    }

    if isTransparentSticker {
      mediaContainerView.layer.cornerRadius = 0.0
      mediaContainerView.layer.mask = nil
    } else if isFullBleed {
      if row.visualKind == .videoNote {
        mediaContainerView.layer.cornerRadius = floor(min(width, height) * 0.5)
        mediaContainerView.layer.mask = nil
      } else {
        mediaContainerView.layer.cornerRadius = 0.0
        fullBleedMaskLayer.frame = mediaContainerView.bounds
        fullBleedMaskLayer.path =
          bubbleRoundedPath(
            rect: mediaContainerView.bounds,
            topLeft: row.shape.borderTopLeftRadius,
            topRight: row.shape.borderTopRightRadius,
            bottomRight: row.shape.borderBottomRightRadius,
            bottomLeft: row.shape.borderBottomLeftRadius
          ).cgPath
        mediaContainerView.layer.mask = fullBleedMaskLayer
      }
    } else {
      mediaContainerView.layer.cornerRadius = cornerRadius
      mediaContainerView.layer.mask = nil
    }
    mediaProgressOverlayView.layer.cornerRadius = mediaContainerView.layer.cornerRadius

    mediaPrimaryIconView.frame = .zero
    mediaVoiceButtonView.frame = .zero
    mediaWaveformView.frame = .zero
    mediaTitleLabel.frame = .zero
    mediaDetailLabel.frame = .zero
    mediaDurationBadge.frame = .zero

    switch row.visualKind {
    case .voice:
      let insetX: CGFloat = 6.0
      let buttonSize: CGFloat = 50.0  // Button view size, inner rendered symbol will be smaller
      mediaVoiceButtonView.frame = CGRect(
        x: insetX,
        y: floor((height - buttonSize) * 0.5),
        width: buttonSize,
        height: buttonSize
      )
      let textStartX = mediaVoiceButtonView.frame.maxX + 4.0
      let rightInset: CGFloat = 8.0
      let waveY: CGFloat = 7.0
      let waveHeight: CGFloat = 20.0
      mediaDetailLabel.frame = CGRect(
        x: textStartX,
        y: waveY + waveHeight + 4.0,
        width: 50.0,
        height: 14.0
      )
      mediaWaveformView.frame = CGRect(
        x: textStartX,
        y: waveY,
        width: max(1.0, width - textStartX - rightInset),
        height: waveHeight
      )

    case .video, .videoNote, .media, .sticker:
      let iconSize: CGFloat = row.visualKind == .videoNote ? 34.0 : 30.0
      mediaPrimaryIconView.frame = CGRect(
        x: floor((width - iconSize) * 0.5),
        y: floor((height - iconSize) * 0.5),
        width: iconSize,
        height: iconSize
      )

      if !mediaDurationBadge.isHidden {
        let badgeText = mediaDurationBadge.text ?? ""
        let badgeWidth = measuredTextWidth(badgeText, font: mediaDurationBadge.font) + 10.0
        let badgeHeight: CGFloat = 20.0
        if row.visualKind == .videoNote {
          mediaDurationBadge.frame = CGRect(
            x: floor((width - badgeWidth) * 0.5),
            y: height - badgeHeight - 10.0,
            width: badgeWidth,
            height: badgeHeight
          )
        } else {
          mediaDurationBadge.frame = CGRect(
            x: 8.0,
            y: height - badgeHeight - 8.0,
            width: badgeWidth,
            height: badgeHeight
          )
        }
      }
      if !mediaTitleLabel.isHidden && row.visualKind == .sticker
        && isTransparentStickerMessage(row)
      {
        // Emoji fallback: center in full cell area
        mediaTitleLabel.frame = CGRect(
          x: 0,
          y: 0,
          width: width,
          height: height
        )
      } else if !mediaTitleLabel.isHidden
        && (row.visualKind == .media || row.visualKind == .sticker)
      {
        mediaTitleLabel.frame = CGRect(
          x: 8.0,
          y: height - 24.0,
          width: max(1.0, width - 16.0),
          height: 16.0
        )
      }

    case .text:
      break
    }

    let ringSize: CGFloat = row.visualKind == .videoNote ? 52.0 : 46.0
    mediaProgressRingView.frame = CGRect(
      x: floor((width - ringSize) * 0.5),
      y: floor((height - ringSize) * 0.5),
      width: ringSize,
      height: ringSize
    )
    mediaProgressSpinner.center = CGPoint(x: width * 0.5, y: height * 0.5)
  }

  @discardableResult
  private func configureStickerAnimation(for row: ChatListRow) -> Bool {
    guard row.visualKind == .sticker,
      let filePath = resolvedStickerAnimationFilePath(for: row)
    else {
      NSLog(
        "[ChatStickerCell] no Lottie path for msgId=%@ stickerId=%@ bundle=%@ packId=%@ mediaUrl=%@ text=%@",
        row.messageId ?? "-",
        row.stickerId ?? "-",
        row.stickerBundleFileName ?? "-",
        row.stickerPackId ?? "-",
        row.mediaUrl ?? "-",
        row.text
      )
      resetStickerAnimation()
      return false
    }

    NSLog("[ChatStickerCell] Lottie path=%@", filePath)

    if currentStickerAnimationKey != filePath || mediaStickerAnimationView.animation == nil {
      mediaStickerAnimationView.stop()
      mediaStickerAnimationView.animation = LottieAnimation.filepath(filePath)
      currentStickerAnimationKey = filePath
    }

    let hasAnimation = mediaStickerAnimationView.animation != nil
    mediaStickerAnimationView.isHidden = !hasAnimation
    if !hasAnimation {
      NSLog("[ChatStickerCell] Lottie parse FAILED for path=%@", filePath)
      currentStickerAnimationKey = nil
    } else {
      NSLog("[ChatStickerCell] Lottie loaded OK, playing")
    }
    updateStickerAnimationPlayback()
    return hasAnimation
  }

  private func resetStickerAnimation() {
    mediaStickerAnimationView.stop()
    mediaStickerAnimationView.animation = nil
    mediaStickerAnimationView.isHidden = true
    currentStickerAnimationKey = nil
  }

  private func updateStickerAnimationPlayback() {
    let shouldPlay =
      window != nil
      && !mediaStickerAnimationView.isHidden
      && !mediaContainerView.isHidden
      && mediaContainerView.alpha > 0.01
      && !isContextMenuExtracted

    if shouldPlay {
      if !mediaStickerAnimationView.isAnimationPlaying {
        mediaStickerAnimationView.play()
      }
    } else if mediaStickerAnimationView.isAnimationPlaying {
      mediaStickerAnimationView.pause()
    }
  }

  @objc private func handleVoiceTap() {
    guard let row, row.visualKind == .voice else { return }
    if row.shouldShowUploadOverlay {
      onVoiceUploadCancelTap?(row)
      return
    }
    if let onVoiceBubbleTap {
      onVoiceBubbleTap(row)
      return
    }
    VoiceBubblePlaybackCoordinator.shared.toggle(
      cell: self, messageId: row.messageId, mediaURL: row.mediaUrl
    )
  }

  @objc private func handleInlineAttachmentTap() {
    guard let row, hasInlineFileAttachment(row) else { return }
    onInlineAttachmentTap?(row)
  }

  func hitTestInlineAttachment(at pointInCell: CGPoint) -> Bool {
    guard let row, hasInlineFileAttachment(row), !inlineAttachmentView.isHidden else {
      return false
    }
    let local = contentView.convert(pointInCell, from: self)
    return inlineAttachmentView.frame.contains(local)
  }

  func applyVoicePlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat) {
    if let row, row.shouldShowUploadOverlay {
      let uploadProgress: CGFloat?
      if let value = row.uploadProgress, value.isFinite {
        uploadProgress = CGFloat(max(0.0, min(1.0, value)))
      } else {
        uploadProgress = nil
      }
      mediaVoiceButtonView.setUploadState(isUploading: true, progress: uploadProgress)
      mediaWaveformView.setPlayback(
        progress: uploadProgress ?? 0.0,
        level: 0.0,
        isPlaying: false
      )
      return
    }
    mediaVoiceButtonView.setUploadState(isUploading: false, progress: nil)
    mediaVoiceButtonView.setPlaybackState(isPlaying: isPlaying, progress: progress, level: level)
    mediaWaveformView.setPlayback(progress: progress, level: level, isPlaying: isPlaying)
  }

  func setExternalVoicePlayback(messageId: String?, isPlaying: Bool, progress: CGFloat) {
    externalVoiceMessageId = messageId
    externalVoiceIsPlaying = isPlaying
    externalVoiceProgress = max(0.0, min(1.0, progress))
    applyExternalVoicePlaybackIfNeeded()
  }

  private func applyExternalVoicePlaybackIfNeeded() {
    guard let row, row.visualKind == .voice else { return }
    let rowId = row.messageId ?? ""
    let externalId = externalVoiceMessageId ?? ""
    guard !rowId.isEmpty else {
      applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
      return
    }
    if rowId == externalId {
      applyVoicePlaybackState(
        isPlaying: externalVoiceIsPlaying,
        progress: externalVoiceProgress,
        level: externalVoiceIsPlaying ? 0.20 : 0.0
      )
    } else {
      applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
    }
  }

  private func layoutMetaLabels(for row: ChatListRow) {
    let widths = bubbleMetaWidths(for: row)
    var cursorX: CGFloat = 0.0
    let baselineY = max(0.0, floor((bubbleMetaHeight - 12.0) * 0.5))

    func hide(_ label: UILabel) {
      label.isHidden = true
      label.frame = .zero
    }

    func place(_ label: UILabel, width: CGFloat, height: CGFloat = 12.0, centered: Bool = false) {
      label.isHidden = false
      let y = centered ? floor((bubbleMetaHeight - height) * 0.5) : baselineY
      label.frame = CGRect(x: cursorX, y: y, width: width, height: height)
      cursorX += width + bubbleMetaItemGap
    }

    if row.isEdited {
      place(editedLabel, width: widths.edited)
    } else {
      hide(editedLabel)
    }

    if row.isPinned {
      place(pinnedLabel, width: widths.pinned)
    } else {
      hide(pinnedLabel)
    }

    place(timestampLabel, width: widths.timestamp)
    let statusY = floor((bubbleMetaHeight - bubbleStatusSlotHeight) * 0.5)
    let statusFrame = pixelAlignedRect(
      CGRect(
        x: cursorX,
        y: statusY,
        width: bubbleStatusSlotWidth,
        height: bubbleStatusSlotHeight
      ))
    statusLabel.frame = statusFrame
    statusImageView.frame = statusFrame
  }

  private func configureStatus(for newRow: ChatListRow, baseColor: UIColor) {
    let newStatus = (resolveDisplayStatus?(newRow) ?? newRow.status)?.lowercased()

    statusLabel.text = nil
    statusLabel.textColor = baseColor
    statusLabel.font = bubbleMetaStatusFont
    statusLabel.isHidden = true
    statusImageView.image = nil
    statusImageView.isHidden = true

    guard newRow.isMe else {
      return
    }

    switch newStatus {
    case "pending":
      statusLabel.font = bubbleMetaPendingFont
      statusLabel.text = "◷"
      statusLabel.isHidden = false
    case "sent":
      statusImageView.image = bubbleStatusCheckImage(double: false, color: baseColor)
      statusImageView.isHidden = false
    case "delivered":
      statusImageView.image = bubbleStatusCheckImage(double: true, color: baseColor)
      statusImageView.isHidden = false
    case "read":
      statusImageView.image = bubbleStatusCheckImage(
        double: true,
        color: UIColor(red: 0.0, green: 163.0 / 255.0, blue: 1.0, alpha: 1.0)  // #00A3FF
      )
      statusImageView.isHidden = false
    case "error":
      statusLabel.text = "!"
      statusLabel.textColor = UIColor(red: 1.0, green: 0.48, blue: 0.48, alpha: 1.0)
      statusLabel.isHidden = false
    default:
      break
    }

  }

  func setContextMenuExtracted(_ extracted: Bool) {
    isContextMenuExtracted = extracted
    holdDebugLog("setExtracted extracted=\(extracted)")
    applyContextMenuExtractionIfNeeded()
  }

  func setContextMenuHeld(_ held: Bool, animated: Bool, strategy: String = "scaleCell") {
    if isContextMenuHeld == held {
      let alreadyIdentity = transform.isIdentity && contentView.transform.isIdentity
      if held || alreadyIdentity {
        holdDebugLog("setHeld skip held=\(held) animated=\(animated) strategy=\(strategy)")
        return
      }
    }
    isContextMenuHeld = held
    holdDebugLog("setHeld held=\(held) animated=\(animated) strategy=\(strategy)")
    applyContextMenuHoldIfNeeded(animated: animated, strategy: strategy)
  }

  private func holdDebugLog(_ message: String) {
    guard chatCellHoldDebugLogs else { return }
    NSLog("[ChatCellHold] %@", message)
  }

  private func reactionDebugLog(_ message: String) {
    guard chatCellReactionDebugLogs else { return }
    NSLog("[ChatCellReaction] %@", message)
  }

  private func applyContextMenuExtractionIfNeeded() {
    if isContextMenuExtracted {
      if !hasSavedExtractionState {
        savedBubbleHiddenBeforeExtraction = bubbleView.isHidden
        savedTailHiddenBeforeExtraction = tailView.isHidden
        savedReactionHiddenBeforeExtraction = reactionPillView.isHidden
        savedMessageAlphaBeforeExtraction = messageLabel.alpha
        savedMediaAlphaBeforeExtraction = mediaContainerView.alpha
        savedMetaAlphaBeforeExtraction = metaContainerView.alpha
        hasSavedExtractionState = true
      }
      bubbleView.isHidden = true
      tailView.isHidden = true
      reactionPillView.isHidden = true
      // Keep text/media/meta rendering alive for snapshot correctness, but hide them.
      messageLabel.alpha = 0.0
      mediaContainerView.alpha = 0.0
      metaContainerView.alpha = 0.0
      updateStickerAnimationPlayback()
      holdDebugLog("applyExtraction extracted=true hidden=true")
      return
    }

    guard hasSavedExtractionState else { return }
    bubbleView.isHidden = savedBubbleHiddenBeforeExtraction
    tailView.isHidden = savedTailHiddenBeforeExtraction
    reactionPillView.isHidden = savedReactionHiddenBeforeExtraction
    messageLabel.alpha = savedMessageAlphaBeforeExtraction
    mediaContainerView.alpha = savedMediaAlphaBeforeExtraction
    metaContainerView.alpha = savedMetaAlphaBeforeExtraction
    hasSavedExtractionState = false
    updateStickerAnimationPlayback()
    holdDebugLog("applyExtraction extracted=false restored=true")
  }

  // MARK: - Hold effect

  private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
    let oldOrigin = view.frame.origin
    view.layer.anchorPoint = anchorPoint
    let newOrigin = view.frame.origin
    let transition = CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y)
    view.center = CGPoint(x: view.center.x - transition.x, y: view.center.y - transition.y)
  }

  private func applyContentViewHoldAnchorIfNeeded() {
    guard contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }

    // Pivot hold-scale around the bubble center (not the full row center)
    // so right/left aligned bubbles do not drift on X during press/release.
    let bubbleCenter = bubbleView.center
    let anchorX = max(0.0, min(1.0, bubbleCenter.x / contentView.bounds.width))
    let anchorY = max(0.0, min(1.0, bubbleCenter.y / contentView.bounds.height))
    setAnchorPoint(CGPoint(x: anchorX, y: anchorY), for: contentView)
    contentViewHoldAnchorApplied = true
  }

  private func applyCellHoldAnchorIfNeeded() {
    guard bounds.width > 0, bounds.height > 0 else { return }

    let bubbleCenter = contentView.convert(bubbleView.center, to: self)
    let anchorX = max(0.0, min(1.0, bubbleCenter.x / bounds.width))
    let anchorY = max(0.0, min(1.0, bubbleCenter.y / bounds.height))
    setAnchorPoint(CGPoint(x: anchorX, y: anchorY), for: self)
    cellHoldAnchorApplied = true
  }

  private func resetCellHoldAnchorIfNeeded() {
    guard cellHoldAnchorApplied else { return }
    setAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: self)
    cellHoldAnchorApplied = false
  }

  private func resetContentViewHoldAnchorIfNeeded() {
    guard contentViewHoldAnchorApplied else { return }
    setAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: contentView)
    contentViewHoldAnchorApplied = false
  }

  private func applyContextMenuHoldIfNeeded(animated: Bool, strategy: String) {
    let scale: CGFloat =
      strategy == "scaleCell"
      ? (isContextMenuHeld ? 0.965 : 1.0)
      : (isContextMenuHeld ? 0.95 : 1.0)
    var targetTransform: CGAffineTransform = .identity
    var cellTransform: CGAffineTransform = .identity

    if isContextMenuHeld {
      if strategy == "scaleCell" {
        applyCellHoldAnchorIfNeeded()
        cellTransform = CGAffineTransform(scaleX: scale, y: scale)
      } else {
        applyContentViewHoldAnchorIfNeeded()
        targetTransform = CGAffineTransform(scaleX: scale, y: scale)
      }
    } else {
      if strategy == "scaleCell" {
        cellTransform = .identity
      } else {
        targetTransform = .identity
      }
    }

    if strategy == "scaleCell" {
      resetContentViewHoldAnchorIfNeeded()
    }

    let applyChanges = {
      if strategy == "scaleCell" {
        self.transform = cellTransform
        self.contentView.transform = .identity
      } else {
        self.transform = .identity
        self.contentView.transform = targetTransform
      }
    }

    holdDebugLog(
      "applyHold begin held=\(isContextMenuHeld) animated=\(animated) strategy=\(strategy) scale=\(String(format: "%.3f", scale)) cell=\(NSCoder.string(for: self.transform)) content=\(NSCoder.string(for: self.contentView.transform))"
    )

    if !animated {
      applyChanges()
      holdDebugLog(
        "applyHold end(noanim) held=\(isContextMenuHeld) strategy=\(strategy) cell=\(NSCoder.string(for: self.transform)) content=\(NSCoder.string(for: self.contentView.transform))"
      )
      if !isContextMenuHeld {
        if strategy == "scaleCell" {
          resetCellHoldAnchorIfNeeded()
        } else {
          resetContentViewHoldAnchorIfNeeded()
        }
      }
      return
    }

    if strategy == "scaleCell" {
      let completion: (Bool) -> Void = { _ in
        self.holdDebugLog(
          "applyHold end(anim) held=\(self.isContextMenuHeld) strategy=\(strategy) cell=\(NSCoder.string(for: self.transform)) content=\(NSCoder.string(for: self.contentView.transform))"
        )
        if !self.isContextMenuHeld {
          self.resetCellHoldAnchorIfNeeded()
        }
      }
      if isContextMenuHeld {
        UIView.animate(
          withDuration: 0.18,
          delay: 0,
          options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
          animations: {
            applyChanges()
          },
          completion: completion
        )
      } else {
        UIView.animate(
          withDuration: 0.24,
          delay: 0,
          usingSpringWithDamping: 0.90,
          initialSpringVelocity: 0,
          options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
          animations: {
            applyChanges()
          },
          completion: completion
        )
      }
      return
    }

    // A smooth, firm press using a modern UIView spring animation
    UIView.animate(
      withDuration: isContextMenuHeld ? 0.28 : 0.45,
      delay: 0,
      usingSpringWithDamping: isContextMenuHeld ? 0.95 : 0.65,
      initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
    ) {
      applyChanges()
    } completion: { _ in
      self.holdDebugLog(
        "applyHold end(anim) held=\(self.isContextMenuHeld) strategy=\(strategy) cell=\(NSCoder.string(for: self.transform)) content=\(NSCoder.string(for: self.contentView.transform))"
      )
      if !self.isContextMenuHeld {
        if strategy == "scaleCell" {
          self.resetCellHoldAnchorIfNeeded()
        } else {
          self.resetContentViewHoldAnchorIfNeeded()
        }
      }
    }
  }

  private func resolvedMetaColor(for textColor: UIColor) -> UIColor {
    var r: CGFloat = 0.0
    var g: CGFloat = 0.0
    var b: CGFloat = 0.0
    var a: CGFloat = 0.0
    guard textColor.getRed(&r, green: &g, blue: &b, alpha: &a) else {
      return UIColor(white: 1.0, alpha: 0.65)
    }
    let luminance = (0.299 * r) + (0.587 * g) + (0.114 * b)
    if luminance > 0.8 {
      return UIColor(white: 1.0, alpha: 0.65)
    }
    return UIColor(white: 0.0, alpha: 0.55)
  }

  func bubbleRect(in view: UIView) -> CGRect? {
    guard let row, row.kind == .message else {
      return nil
    }
    return bubbleView.convert(bubbleView.bounds, to: view)
  }

  func reactionBadgeCenter(in view: UIView) -> CGPoint? {
    guard row?.kind == .message else {
      return nil
    }
    contentView.layoutIfNeeded()
    let bubbleRect = bubbleView.convert(bubbleView.bounds, to: view)
    let frame = reactionBadgeFrame(in: bubbleRect)
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  func bubbleSnapshotView(in view: UIView) -> UIView? {
    guard let row = row, row.kind == .message else {
      return nil
    }

    var captureRect = bubbleView.convert(bubbleView.bounds, to: contentView)
    if !tailView.isHidden {
      let tailRect = tailView.convert(tailView.bounds, to: contentView)
      captureRect = captureRect.union(tailRect)
    }
    if !reactionPillView.isHidden {
      let reactionRect = reactionPillView.convert(reactionPillView.bounds, to: contentView)
      captureRect = captureRect.union(reactionRect)
    }
    captureRect = captureRect.integral

    guard captureRect.width > 1.0, captureRect.height > 1.0 else {
      return nil
    }

    // Take snapshot without altering contentView.transform which cancels active hold animations
    let frameInWindow = contentView.convert(captureRect, to: view)

    guard
      let snapshot = contentView.resizableSnapshotView(
        from: captureRect,
        afterScreenUpdates: false,
        withCapInsets: .zero
      )
    else {
      return nil
    }

    snapshot.frame = frameInWindow

    snapshot.clipsToBounds = false

    return snapshot
  }

  private func reactionBadgeFrame(in bubbleFrame: CGRect) -> CGRect {
    let maxBadgeWidth = max(
      20.0,
      bubbleFrame.width - Self.reactionBadgeInsetLeft - 4.0
    )
    let width = min(Self.reactionBadgeBaseSize.width, maxBadgeWidth)
    let height = Self.reactionBadgeBaseSize.height
    return CGRect(
      x: bubbleFrame.minX + Self.reactionBadgeInsetLeft,
      y: bubbleFrame.maxY - Self.reactionBadgeInsetBottom - height,
      width: width,
      height: height
    )
  }

  func transitionBubbleCaptureRects() -> (
    bubbleBodyRect: CGRect, fullBubbleRect: CGRect, contentRect: CGRect
  )? {
    guard row?.kind == .message else {
      return nil
    }
    contentView.layoutIfNeeded()

    let bubbleBodyRect = bubbleView.convert(bubbleView.bounds, to: contentView).integral
    guard bubbleBodyRect.width > 1.0, bubbleBodyRect.height > 1.0 else {
      return nil
    }
    var fullBubbleRect = bubbleBodyRect
    if !tailView.isHidden {
      let tailRect = tailView.convert(tailView.bounds, to: contentView).integral
      fullBubbleRect = fullBubbleRect.union(tailRect).integral
    }

    var contentRect = CGRect.null
    if !messageLabel.isHidden {
      contentRect = contentRect.union(messageLabel.frame)
    }
    if !mediaContainerView.isHidden {
      contentRect = contentRect.union(mediaContainerView.frame)
    }
    if !metaContainerView.isHidden {
      contentRect = contentRect.union(metaContainerView.frame)
    }
    if contentRect.isNull || contentRect.width <= 1.0 || contentRect.height <= 1.0 {
      contentRect = bubbleBodyRect.insetBy(
        dx: bubbleHorizontalPadding,
        dy: min(bubbleTopPadding, bubbleBottomPadding)
      )
    }
    contentRect = contentRect.integral
    return (bubbleBodyRect, fullBubbleRect, contentRect)
  }

  func bubbleBackgroundSnapshotView(in view: UIView) -> UIView? {
    guard row?.kind == .message else {
      return nil
    }
    guard let capture = transitionBubbleCaptureRects() else {
      return nil
    }
    let captureRect = capture.fullBubbleRect
    guard captureRect.width > 1.0, captureRect.height > 1.0 else {
      return nil
    }

    let messageWasHidden = messageLabel.isHidden
    let mediaWasHidden = mediaContainerView.isHidden

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    messageLabel.isHidden = true
    mediaContainerView.isHidden = true
    contentView.layoutIfNeeded()
    CATransaction.commit()

    defer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      messageLabel.isHidden = messageWasHidden
      mediaContainerView.isHidden = mediaWasHidden
      contentView.layoutIfNeeded()
      CATransaction.commit()
    }

    // Prefer UIKit snapshot APIs first. They tend to preserve UIVisualEffectView
    // appearance better than offscreen rasterization during transitions.
    if let snapshot = contentView.resizableSnapshotView(
      from: captureRect,
      afterScreenUpdates: true,
      withCapInsets: .zero
    ) {
      snapshot.frame = contentView.convert(captureRect, to: view)
      snapshot.clipsToBounds = false
      return snapshot
    }

    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
    let image = renderer.image { context in
      context.cgContext.translateBy(x: -captureRect.minX, y: -captureRect.minY)
      if !contentView.drawHierarchy(in: contentView.bounds, afterScreenUpdates: true) {
        contentView.layer.render(in: context.cgContext)
      }
    }
    let imageView = UIImageView(image: image)
    imageView.frame = contentView.convert(captureRect, to: view)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = false
    return imageView
  }
}

final class BubbleTailView: UIView {
  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
  private let gradientLayer = CAGradientLayer()
  private let fillLayer = CAShapeLayer()
  private let tailMaskLayer = CAShapeLayer()
  private let clipMaskLayer = CAShapeLayer()
  private var currentIsMe: Bool = true
  let imageView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    clipsToBounds = false

    addSubview(blurView)
    addSubview(imageView)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.isHidden = true
    layer.addSublayer(gradientLayer)
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    layer.addSublayer(fillLayer)
    layer.mask = tailMaskLayer
  }

  func setImage(_ image: UIImage?) {
    imageView.image = image
    imageView.isHidden = image == nil
    blurView.isHidden = image != nil
    fillLayer.isHidden = image != nil
    if image != nil {
      gradientLayer.isHidden = true
    } else {
      gradientLayer.isHidden = !currentIsMe
    }
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(isMe: Bool, visible: Bool, appearance: ChatListAppearance) {
    currentIsMe = isMe
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    isHidden = !visible

    // MUST match BubbleBackgroundView.configure exactly so tail+bubble look identical.
    // Bubble uses:  blur .systemThinMaterialDark α0.34 + gradient 0.88  (me)
    //               blur .systemMaterialDark     α0.44 + fill    ~0.88  (them)
    blurView.effect = UIBlurEffect(style: isMe ? .systemThinMaterialDark : .systemMaterialDark)
    blurView.alpha = isMe ? 0.34 : 0.44
    gradientLayer.isHidden = !isMe
    gradientLayer.colors = appearance.bubbleMeGradient.map(\.cgColor)
    gradientLayer.opacity = isMe ? 0.88 : 0.0
    fillLayer.fillColor =
      isMe
      ? UIColor.clear.cgColor
      : appearance.bubbleThemColor.withAlphaComponent(appearance.isDark ? 0.86 : 0.90).cgColor

    // For 'me': rotate CW 25° (tail curves right at bottom-right of bubble)
    // For 'them': flip horizontally + rotate CCW 25° (tail curves left at bottom-left)
    let angle = (isMe ? 25.0 : -25.0) * (.pi / 180.0)
    let rotate = CGAffineTransform(rotationAngle: angle)
    let flip = CGAffineTransform(scaleX: isMe ? 1.0 : -1.0, y: 1.0)
    transform = flip.concatenating(rotate)
    CATransaction.commit()
    setNeedsLayout()
  }

  func applyAgentTailStyle(appearance: ChatListAppearance, isMe: Bool) {
    let agentColor =
      appearance.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    if !isMe {
      gradientLayer.isHidden = false
      gradientLayer.colors = [
        agentColor.withAlphaComponent(0.22).cgColor,
        agentColor.withAlphaComponent(0.08).cgColor,
      ]
      gradientLayer.opacity = 0.82
      blurView.alpha = 0.42
    } else {
      gradientLayer.isHidden = false
      gradientLayer.colors = appearance.bubbleMeGradient.map(\.cgColor)
      gradientLayer.opacity = 0.82
      blurView.alpha = 0.0
    }
    CATransaction.commit()
  }

  func clearAgentTailStyle() {
    // No-op: regular configure resets everything
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.height > 0 else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    blurView.frame = bounds
    imageView.frame = bounds
    gradientLayer.frame = bounds
    fillLayer.frame = bounds

    // Tail path in 29×29 coordinate space.
    let basePath = UIBezierPath()
    basePath.move(to: CGPoint(x: 0, y: 0))
    basePath.addQuadCurve(to: CGPoint(x: 14, y: 25), controlPoint: CGPoint(x: -5, y: 22))
    basePath.addQuadCurve(to: CGPoint(x: 0, y: 29), controlPoint: CGPoint(x: 10.5, y: 29))
    basePath.close()

    let scale = CGAffineTransform(scaleX: bounds.width / 29.0, y: bounds.height / 29.0)
    basePath.apply(scale)

    fillLayer.path = basePath.cgPath

    // Use the tail shape as mask for the entire view (blur + gradient + fill)
    // but clip the top ~40% where the thin closing line is visible.
    let clipTop = bounds.height * 0.4
    let clippedPath = UIBezierPath()
    clippedPath.move(to: CGPoint(x: 0, y: 0))
    clippedPath.addQuadCurve(to: CGPoint(x: 14, y: 25), controlPoint: CGPoint(x: -5, y: 22))
    clippedPath.addQuadCurve(to: CGPoint(x: 0, y: 29), controlPoint: CGPoint(x: 10.5, y: 29))
    clippedPath.close()
    clippedPath.apply(CGAffineTransform(scaleX: bounds.width / 29.0, y: bounds.height / 29.0))

    // Create compound mask: tail shape intersected with bottom clip rect
    let combinedPath = UIBezierPath(
      rect: CGRect(x: -5, y: clipTop, width: bounds.width + 10, height: bounds.height - clipTop + 5)
    )
    combinedPath.usesEvenOddFillRule = false

    tailMaskLayer.frame = bounds
    tailMaskLayer.path = clippedPath.cgPath

    // Also clip to bottom portion
    let clipLayer = CAShapeLayer()
    clipLayer.frame = bounds
    clipLayer.path =
      UIBezierPath(
        rect: CGRect(
          x: -5, y: clipTop, width: bounds.width + 10, height: bounds.height - clipTop + 5)
      ).cgPath
    tailMaskLayer.mask = clipLayer

    // Gradient mask for me bubbles
    if !gradientLayer.isHidden {
      let gradMask = CAShapeLayer()
      gradMask.frame = bounds
      gradMask.path = basePath.cgPath
      gradientLayer.mask = gradMask
    }

    CATransaction.commit()
  }
}

// MARK: - Send transition overlay helpers
