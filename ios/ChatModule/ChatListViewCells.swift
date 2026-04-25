import AVFoundation
import ImageIO
import LinkPresentation
import MediaPlayer
import UIKit

private let chatCellHoldDebugLogs = false
private let chatCellReactionDebugLogs = false
private let chatCellMediaDebugLogs = false
private let chatCellInlineVideoDebugLogs = false
private let bubbleBoldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
private let chatMediaImageCache = NSCache<NSString, UIImage>()
private let chatMediaNaturalSizeCache = NSCache<NSString, NSValue>()
private let chatMediaAudioAvailabilityCache = NSCache<NSString, NSNumber>()

// MARK: - Disk-backed image cache

private let chatMediaDiskCacheQueue = DispatchQueue(label: "chat.media.disk-cache", qos: .utility)
private var chatMediaFailedURLs = Set<String>()
private var chatMediaRetryCount: [String: Int] = [:]
private let chatMediaMaxRetries = 3
private let chatMediaVideoExtensions: Set<String> = [
  "mp4", "mov", "m4v", "avi", "mkv", "webm",
]

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

private func chatMediaCacheKey(_ urlString: String, mediaKey: String?) -> String {
  let normalized = chatMediaNormalizedKey(urlString)
  let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard !trimmedKey.isEmpty else { return normalized }
  return normalized + "|k:" + trimmedKey
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

private func chatCellDebugLog(_ enabled: Bool, _ format: String, _ args: CVarArg...) {
  guard enabled else { return }
  withVaList(args) { pointer in
    NSLogv(format, pointer)
  }
}

private func chatMediaDecodedImage(
  from data: Data, shouldAnimate: Bool
) -> UIImage? {
  if shouldAnimate, let animatedImage = chatMediaAnimatedImage(from: data) {
    return animatedImage
  }
  return UIImage(data: data)
}

private func chatMediaImage(fromBase64 value: String?) -> UIImage? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  let payload: String = {
    if let commaIndex = trimmed.firstIndex(of: ","),
      trimmed[..<commaIndex].contains("base64")
    {
      return String(trimmed[trimmed.index(after: commaIndex)...])
    }
    return trimmed
  }()
  guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
    return nil
  }
  return UIImage(data: data)
}

private func chatMediaPreviewVideoCacheDir() -> URL {
  let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
  let dir = caches.appendingPathComponent("chat-media-video-preview", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func chatMediaResolvedVideoExtension(
  urlString: String,
  fileName: String?,
  messageType: String
) -> String {
  let candidates: [String] = [
    fileName ?? "",
    (URL(string: urlString)?.pathExtension ?? ""),
    (urlString as NSString).pathExtension,
  ]
  for candidate in candidates {
    let ext = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ".", with: "")
      .lowercased()
    if chatMediaVideoExtensions.contains(ext) {
      return ext
    }
  }
  return messageType == "video" ? "mp4" : "mov"
}

private func chatMediaHeaderSummary(from data: Data) -> String {
  guard !data.isEmpty else { return "none" }
  let bytes = [UInt8](data.prefix(16))
  let hex = bytes.map { String(format: "%02x", $0) }.joined()
  var brand = "-"
  if data.count >= 12 {
    let brandData = data.subdata(in: 8..<12)
    brand = String(data: brandData, encoding: .ascii) ?? "-"
  }
  return "hex=\(hex) brand=\(brand)"
}

private func chatMediaFileHeaderSummary(at path: String) -> String {
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else {
    return "none"
  }
  return chatMediaHeaderSummary(from: data)
}

private func chatMediaVideoThumbnail(
  from data: Data,
  cacheKey: String,
  urlString: String,
  fileName: String?,
  messageType: String
) -> UIImage? {
  let ext = chatMediaResolvedVideoExtension(
    urlString: urlString,
    fileName: fileName,
    messageType: messageType
  )
  let safeKey = String(format: "v-%016llx", UInt64(bitPattern: Int64(cacheKey.hashValue)))
  let fileURL = chatMediaPreviewVideoCacheDir()
    .appendingPathComponent(safeKey)
    .appendingPathExtension(ext)
  do {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try? FileManager.default.removeItem(at: fileURL)
    }
    try data.write(to: fileURL, options: [.atomic])
  } catch {
    return nil
  }
  let asset = AVURLAsset(url: fileURL)
  guard let cgImage = chatMediaCopyVideoPreviewImage(from: asset, maxSize: CGSize(width: 1600.0, height: 1600.0))
  else {
    return nil
  }
  return UIImage(cgImage: cgImage)
}

private func chatMediaCopyVideoPreviewImage(
  from asset: AVAsset,
  maxSize: CGSize
) -> CGImage? {
  let generator = AVAssetImageGenerator(asset: asset)
  generator.appliesPreferredTrackTransform = true
  generator.maximumSize = maxSize
  let rawCandidates: [Double] = [0.0, 0.04, 0.12, 0.24, 0.5, 1.0]
  let durationSeconds = CMTimeGetSeconds(asset.duration)
  let effectiveDuration = durationSeconds.isFinite ? max(0.0, durationSeconds) : 0.0
  let requestedSeconds = rawCandidates
    .filter { effectiveDuration <= 0.01 || $0 <= effectiveDuration }
  for seconds in requestedSeconds {
    do {
      return try generator.copyCGImage(
        at: CMTime(seconds: seconds, preferredTimescale: 600),
        actualTime: nil
      )
    } catch {
      continue
    }
  }
  return nil
}

private func chatMediaPreviewImage(
  from data: Data,
  shouldAnimate: Bool,
  cacheKey: String,
  urlString: String,
  fileName: String?,
  messageType: String,
  preferVideoPreview: Bool
) -> UIImage? {
  if let image = chatMediaDecodedImage(from: data, shouldAnimate: shouldAnimate) {
    return image
  }
  guard preferVideoPreview else {
    return nil
  }
  return chatMediaVideoThumbnail(
    from: data,
    cacheKey: cacheKey,
    urlString: urlString,
    fileName: fileName,
    messageType: messageType
  )
}

private func chatMediaLoadImageFromFile(
  at path: String, shouldAnimate: Bool
) -> UIImage? {
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
  else {
    return nil
  }
  if let image = chatMediaDecodedImage(from: data, shouldAnimate: shouldAnimate) {
    return image
  }
  // Try video thumbnail generation as fallback.
  let url = URL(fileURLWithPath: path)
  let asset = AVURLAsset(url: url)
  guard let cgImage = chatMediaCopyVideoPreviewImage(from: asset, maxSize: CGSize(width: 1600.0, height: 1600.0))
  else { return nil }
  return UIImage(cgImage: cgImage)
}

private func chatMediaDecryptedDataIfNeeded(_ data: Data, mediaKey: String?) -> Data? {
  ChatEngine.shared.decryptMediaDataIfNeeded(data, mediaKey: mediaKey)
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
  private let wallpaperLayer = CALayer()
  private let blurView = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let gradientLayer = CAGradientLayer()
  private let fillLayer = CAShapeLayer()
  private let bubbleMaskLayer = CAShapeLayer()
  private var appearance = ChatListAppearance.fallback
  internal var wallpaperSnapshot: CGImage?
  internal var wallpaperContainerSize: CGSize = .zero
  internal var wallpaperSampleRect: CGRect = .zero
  private var shape = BubbleShape(
    isMe: false, showTail: false, borderTopLeftRadius: 18, borderTopRightRadius: 18,
    borderBottomLeftRadius: 18, borderBottomRightRadius: 18)

  override init(frame: CGRect) {
    super.init(frame: frame)
    wallpaperLayer.contentsGravity = .resize
    wallpaperLayer.contentsScale = UIScreen.main.scale
    layer.addSublayer(wallpaperLayer)
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

  func duplicate() -> BubbleBackgroundView {
    let replica = BubbleBackgroundView(frame: frame)
    replica.configure(isMe: shape.isMe, shape: shape, hidden: false, appearance: appearance)
    if let snapshot = wallpaperSnapshot {
      replica.applyWallpaperBackdrop(
        snapshot: snapshot,
        containerSize: wallpaperContainerSize,
        sampleRect: wallpaperSampleRect
      )
    }
    return replica
  }

  func renderToImage() -> UIImage? {
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
    return renderer.image { ctx in
      layer.render(in: ctx.cgContext)
    }
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
    applyBubbleChrome(isMe: isMe, hidden: hidden)
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
      gradientLayer.opacity = wallpaperLayer.isHidden ? 0.82 : 0.70
      fillLayer.fillColor =
        appearance.bubbleThemColor.withAlphaComponent(
          wallpaperLayer.isHidden ? (appearance.isDark ? 0.86 : 1.0) : (appearance.isDark ? 0.62 : 1.0)
        ).cgColor
      blurView.alpha = wallpaperLayer.isHidden ? 0.42 : 0.0
    } else {
      // For my agent mentions, just add the glowing border and a slight tint
      gradientLayer.isHidden = false
      gradientLayer.colors = appearance.bubbleMeGradient.map { $0.cgColor }
      gradientLayer.opacity = wallpaperLayer.isHidden ? 0.82 : 0.72
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

  func applyWallpaperBackdrop(
    snapshot: CGImage?,
    containerSize: CGSize,
    sampleRect: CGRect
  ) {
    wallpaperSnapshot = snapshot
    wallpaperContainerSize = containerSize
    wallpaperSampleRect = sampleRect
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyBubbleChrome(isMe: shape.isMe, hidden: isHidden)
    applyWallpaperBackdropLayer()
    CATransaction.commit()
    setNeedsLayout()
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
    wallpaperLayer.frame = bounds
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
    applyWallpaperBackdropLayer()
    applyAgentBorderPath()
    CATransaction.commit()
  }

  private func applyWallpaperBackdropLayer() {
    let hasBackdrop =
      wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
      && appearance.backgroundMode != "transparent"

    wallpaperLayer.isHidden = !hasBackdrop
    guard hasBackdrop, let wallpaperSnapshot else {
      wallpaperLayer.contents = nil
      return
    }

    wallpaperLayer.contents = wallpaperSnapshot
    wallpaperLayer.contentsRect = normalizedWallpaperSampleRect(
      wallpaperSampleRect,
      containerSize: wallpaperContainerSize
    )
  }

  private func applyBubbleChrome(isMe: Bool, hidden: Bool) {
    let hasWallpaperBackdrop =
      wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
      && appearance.backgroundMode != "transparent"

    isHidden = hidden
    wallpaperLayer.isHidden = hidden || !hasWallpaperBackdrop
    wallpaperLayer.opacity = Float(
      hasWallpaperBackdrop
        ? (isMe ? appearance.outgoingWallpaperSampleOpacity : appearance.incomingWallpaperSampleOpacity)
        : 1.0
    )
    blurView.isHidden = hidden
    blurView.effect = UIBlurEffect(style: isMe ? .systemThinMaterialDark : .systemMaterialDark)
    blurView.alpha = hasWallpaperBackdrop ? 0.0 : (isMe ? 0.34 : 0.44)
    if hasWallpaperBackdrop {
      gradientLayer.isHidden = true
      gradientLayer.opacity = 0.0
      let plateColor = appearance.wallpaperPlateColor(
        isMe: isMe,
        sampleRect: wallpaperSampleRect,
        containerSize: wallpaperContainerSize
      )
      let plateAlpha = isMe ? appearance.outgoingPlateFillOpacity : appearance.incomingPlateFillOpacity
      fillLayer.fillColor = plateColor.withAlphaComponent(plateAlpha).cgColor
    } else {
      gradientLayer.isHidden = !isMe
      gradientLayer.colors = appearance.bubbleMeGradient.map(\.cgColor)
      gradientLayer.opacity = Float(isMe ? 0.88 : 0.0)
      fillLayer.fillColor =
        isMe
        ? UIColor.clear.cgColor
        : appearance.bubbleThemColor.withAlphaComponent(appearance.isDark ? 0.86 : 1.0).cgColor
    }
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
private let bubbleStatusSlotWidth: CGFloat = 17.0
private let bubbleStatusSlotHeight: CGFloat = 14.0
private let bubbleStatusCheckStrokeWidth: CGFloat = 1.0

private final class ChatPendingStatusView: UIView {
  private let ringLayer = CAShapeLayer()
  private let staticHandLayer = CAShapeLayer()
  private let handLayer = CAShapeLayer()
  private var color = UIColor.white

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    ringLayer.fillColor = UIColor.clear.cgColor
    ringLayer.lineCap = .round
    ringLayer.opacity = 0.58
    staticHandLayer.fillColor = UIColor.clear.cgColor
    staticHandLayer.lineCap = .round
    handLayer.fillColor = UIColor.clear.cgColor
    handLayer.lineCap = .round
    layer.addSublayer(ringLayer)
    layer.addSublayer(staticHandLayer)
    layer.addSublayer(handLayer)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func configure(color: UIColor) {
    self.color = color
    ringLayer.strokeColor = color.cgColor
    staticHandLayer.strokeColor = color.cgColor
    handLayer.strokeColor = color.cgColor
    setNeedsLayout()
    startAnimating()
  }

  func stopAnimating() {
    handLayer.removeAnimation(forKey: "pendingClockRotation")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side = min(bounds.width, bounds.height) - 4.0
    let rect = CGRect(
      x: floor((bounds.width - side) * 0.5),
      y: floor((bounds.height - side) * 0.5),
      width: side,
      height: side
    )
    let lineWidth = max(1.2, side * 0.13)
    ringLayer.frame = bounds
    ringLayer.lineWidth = lineWidth
    ringLayer.path = UIBezierPath(ovalIn: rect).cgPath

    staticHandLayer.frame = bounds
    staticHandLayer.lineWidth = lineWidth
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = side * 0.30
    let staticPath = UIBezierPath()
    staticPath.move(to: center)
    staticPath.addLine(to: CGPoint(x: center.x + radius * 0.42, y: center.y))
    staticHandLayer.path = staticPath.cgPath

    handLayer.frame = bounds
    handLayer.lineWidth = lineWidth
    let path = UIBezierPath()
    path.move(to: center)
    path.addLine(to: CGPoint(x: center.x, y: center.y - radius * 1.12))
    handLayer.path = path.cgPath
  }

  private func startAnimating() {
    if handLayer.animation(forKey: "pendingClockRotation") != nil { return }
    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.fromValue = 0.0
    animation.toValue = CGFloat.pi * 2.0
    animation.duration = 1.05
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.isRemovedOnCompletion = false
    handLayer.add(animation, forKey: "pendingClockRotation")
  }
}

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
    let scale: CGFloat = 0.63
    let baseX = size.width - (24.0 * scale) - 0.5
    let baseY = (size.height - (24.0 * scale)) * 0.5

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: baseX + x * scale, y: baseY + y * scale)
    }

    color.setStroke()

    let firstPath = UIBezierPath()
    if double {
      firstPath.move(to: point(4.0, 12.9))
      firstPath.addLine(to: point(7.14286, 16.5))
      firstPath.addLine(to: point(15.0, 7.5))
    } else {
      firstPath.move(to: point(4.0, 12.0))
      firstPath.addLine(to: point(8.94975, 16.9497))
      firstPath.addLine(to: point(19.5572, 6.34326))
    }
    firstPath.lineWidth = (double ? 1.5 : 2.0) * scale
    firstPath.lineCapStyle = .round
    firstPath.lineJoinStyle = .round
    firstPath.stroke()

    if double {
      let secondPath = UIBezierPath()
      secondPath.move(to: point(20.0, 7.5625))
      secondPath.addLine(to: point(11.4283, 16.5625))
      secondPath.addLine(to: point(11.0, 16.0))
      secondPath.lineWidth = 1.5 * scale
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
  let replyPreviewHeight: CGFloat
  let hasReplyPreview: Bool
  let previewHeight: CGFloat
  let hasLinkPreview: Bool
  let usesBottomMetaLayout: Bool
  let usesRichTextLayout: Bool
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

private func colorLuminance(_ color: UIColor) -> CGFloat {
  var red: CGFloat = 0.0
  var green: CGFloat = 0.0
  var blue: CGFloat = 0.0
  var alpha: CGFloat = 0.0
  if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
    return (0.299 * red) + (0.587 * green) + (0.114 * blue)
  }

  var white: CGFloat = 0.0
  if color.getWhite(&white, alpha: &alpha) {
    return white
  }

  return 0.5
}

private func resolvedIncomingVoiceButtonStyle(for appearance: ChatListAppearance)
  -> (fill: UIColor, accent: UIColor)
{
  let accent = appearance.bubbleThemColor.withAlphaComponent(0.98)
  let fill: UIColor =
    colorLuminance(appearance.bubbleThemColor) > 0.72
    ? UIColor(white: 0.08, alpha: 0.16)
    : UIColor(white: 1.0, alpha: 0.90)
  return (fill, accent)
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

private func formatBubblePlaybackTimer(current: Double?, duration: Double?) -> String {
  let totalSeconds = max(0.0, duration ?? 0.0)
  let currentSeconds = max(0.0, current ?? 0.0)
  let remainingSeconds = totalSeconds > 0.0 ? max(0.0, totalSeconds - currentSeconds) : 0.0
  return formatBubbleDuration(seconds: remainingSeconds)
}

private func formatMediaByteSize(_ bytes: Int64) -> String {
  let kb = Double(bytes) / 1024.0
  if kb < 1.0 { return "\(bytes) B" }
  let mb = kb / 1024.0
  if mb < 1.0 { return String(format: "%.0f KB", kb) }
  let gb = mb / 1024.0
  if gb < 1.0 { return String(format: "%.1f MB", mb) }
  return String(format: "%.2f GB", gb)
}

private let chatTransferProgressQuantizationStep: CGFloat = 0.01
private let chatTransferProgressAnimationThreshold: CGFloat = 0.006

private func quantizedTransferProgress(_ progress: CGFloat?, minimum: CGFloat) -> CGFloat? {
  guard let progress, progress.isFinite else { return nil }
  let clamped = max(minimum, min(1.0, progress))
  let quantized =
    (clamped / chatTransferProgressQuantizationStep).rounded() * chatTransferProgressQuantizationStep
  return max(minimum, min(1.0, quantized))
}

private func usesAudioMetadataVoiceLayout(_ row: ChatListRow) -> Bool {
  row.visualKind == .voice && row.messageType.lowercased() != "voice"
}

private func normalizedChatAudioId(_ value: String?) -> String? {
  guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
    return nil
  }
  return trimmed
}

private func resolvedAudioVoiceTitle(_ row: ChatListRow) -> String {
  let rawTitle =
    row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
    ?? row.text.trimmingCharacters(in: .whitespacesAndNewlines)
  let sanitizedTitle = (rawTitle as NSString).lastPathComponent
  let displayTitle = (sanitizedTitle as NSString).deletingPathExtension
  if displayTitle.isEmpty || displayTitle.count < 2 {
    let lowerType = row.messageType.lowercased()
    if lowerType == "mp3" { return "MP3" }
    if lowerType == "music" { return "Music" }
    if row.fileName?.lowercased().hasSuffix(".mp3") ?? false { return "MP3" }
    return "Audio"
  }
  return displayTitle
}

private func resolvedAudioVoiceStaticDetail(_ row: ChatListRow) -> String {
  var components: [String] = []
  if let duration = row.duration, duration.isFinite, duration > 0 {
    components.append(formatBubbleDuration(seconds: duration))
  }
  if components.isEmpty {
    let lowerType = row.messageType.lowercased()
    if lowerType == "mp3" { return "MP3" }
    if lowerType == "music" { return "Music" }
    return "Audio"
  }
  return components.joined(separator: " • ")
}

private func trimmedBubbleText(_ row: ChatListRow) -> String {
  row.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func hasMediaCaptionLayout(_ row: ChatListRow) -> Bool {
  guard row.kind == .message else { return false }
  guard row.visualKind == .media || row.visualKind == .video || row.visualKind == .videoNote
  else {
    return false
  }
  return !trimmedBubbleText(row).isEmpty
}

private func bubbleMetaWidths(for row: ChatListRow) -> ChatBubbleMetaWidths {
  if row.messageType == "agent_progress" || usesTransparentAgentStreamingLayout(row) {
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
private let bubbleReplyPreviewHeight: CGFloat = 36.0
private let bubbleReplyPreviewSpacing: CGFloat = 6.0
private let bubbleReplyPreviewMinWidth: CGFloat = 184.0
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

private func hasInlineRelatedMessages(_ row: ChatListRow) -> Bool {
  !row.relatedMessageIds.isEmpty
}

private func hasInlineAttachment(_ row: ChatListRow) -> Bool {
  hasInlineRelatedMessages(row) || hasInlineFileAttachment(row)
}

private func hasReplyPreview(_ row: ChatListRow) -> Bool {
  guard row.kind == .message, row.visualKind == .text else { return false }
  return row.replyToId != nil
}

private func replyPreviewTitle(for row: ChatListRow) -> String {
  if let title = row.replyPreviewTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
    !title.isEmpty
  {
    return title
  }
  return "Reply"
}

private func replyPreviewText(for row: ChatListRow) -> String {
  if let text = row.replyPreviewText?.trimmingCharacters(in: .whitespacesAndNewlines),
    !text.isEmpty
  {
    return text
  }
  return "Message"
}

private func inlineAttachmentTitle(for row: ChatListRow) -> String {
  if hasInlineRelatedMessages(row) {
    if let title = row.relatedMessagesTitle, !title.isEmpty {
      return title
    }
    return row.relatedMessageIds.count == 1 ? "Related message" : "\(row.relatedMessageIds.count) related messages"
  }
  if let fileName = row.fileName, !fileName.isEmpty {
    return fileName
  }
  return "Document"
}

private func inlineAttachmentSubtitle(for row: ChatListRow) -> String {
  if hasInlineRelatedMessages(row) {
    if let subtitle = row.relatedMessagesSubtitle, !subtitle.isEmpty {
      return subtitle
    }
    return "Tap to review"
  }
  return "Tap to open"
}

private func inlineAttachmentIconName(for row: ChatListRow) -> String {
  hasInlineRelatedMessages(row) ? "list.bullet.rectangle.portrait.fill" : "doc.text.fill"
}

private func isRTL(_ text: String) -> Bool {
  return text.range(of: "[\\u0600-\\u06FF]", options: .regularExpression) != nil
}

private func usesRTLColumnLayout(_ row: ChatListRow) -> Bool {
  guard row.kind == .message, row.visualKind == .text else { return false }
  guard row.messageType != "typing" else { return false }
  return isRTL(row.text)
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

private func resolvedLocalMediaPath(_ mediaUrl: String?) -> String? {
  guard let mediaUrl, !mediaUrl.isEmpty else { return nil }
  let trimmed = mediaUrl.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

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
}

private func cachedVideoHasAudio(for mediaUrl: String?) -> Bool? {
  guard let mediaUrl, !mediaUrl.isEmpty else { return nil }
  return chatMediaAudioAvailabilityCache.object(forKey: mediaUrl as NSString)?.boolValue
}

private func cacheVideoHasAudio(_ hasAudio: Bool, for mediaUrl: String?) {
  guard let mediaUrl, !mediaUrl.isEmpty else { return }
  chatMediaAudioAvailabilityCache.setObject(NSNumber(value: hasAudio), forKey: mediaUrl as NSString)
}

private func probeLocalMediaSize(for mediaUrl: String?) -> CGSize? {
  guard let resolvedPath = resolvedLocalMediaPath(mediaUrl) else { return nil }
  guard !resolvedPath.isEmpty else { return nil }
  // Try image first.
  if let image = UIImage(contentsOfFile: resolvedPath),
    image.size.width > 1.0, image.size.height > 1.0
  {
    return image.size
  }
  // Fall back: probe as video via AVAsset.
  let fileURL = URL(fileURLWithPath: resolvedPath)
  let asset = AVURLAsset(url: fileURL)
  guard let track = asset.tracks(withMediaType: .video).first else { return nil }
  let transformed = track.naturalSize.applying(track.preferredTransform)
  let w = abs(transformed.width)
  let h = abs(transformed.height)
  guard w > 1, h > 1 else { return nil }
  return CGSize(width: w, height: h)
}

private func probeLocalVideoHasAudio(for mediaUrl: String?) -> Bool? {
  if let cached = cachedVideoHasAudio(for: mediaUrl) {
    return cached
  }
  guard let resolvedPath = resolvedLocalMediaPath(mediaUrl) else { return nil }
  let fileURL = URL(fileURLWithPath: resolvedPath)
  let asset = AVURLAsset(url: fileURL)
  guard !asset.tracks(withMediaType: .video).isEmpty else { return nil }
  let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
  cacheVideoHasAudio(hasAudio, for: mediaUrl)
  return hasAudio
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
  if hasMediaCaptionLayout(row) {
    return false
  }
  return (row.visualKind == .media && row.messageType != "file") || row.visualKind == .video
    || row.visualKind == .videoNote
}

private func usesTransparentAgentStreamingLayout(_ row: ChatListRow) -> Bool {
  guard row.kind == .message else { return false }
  return row.isAgentMessage
    && row.isStreamingText
    && row.messageType != "typing"
    && row.visualKind == .text
}

private func effectiveMetaTopSpacing(for row: ChatListRow) -> CGFloat {
  isTransparentStickerMessage(row) ? stickerMetaTopSpacing : bubbleMetaTopSpacing
}

private let bubbleLinkPreviewHeight: CGFloat = 78.0
private let bubbleLinkPreviewSpacing: CGFloat = 8.0
private let bubbleLinkPreviewMinWidth: CGFloat = 220.0
private let bubbleRichTextBlockSpacing: CGFloat = 6.0
private let bubbleURLDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
private let bubbleInternalChatIdRegex = try! NSRegularExpression(
  pattern: "[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}"
)

private struct BubbleRichTextMeasurement {
  let height: CGFloat
  let maxWidth: CGFloat
}

private struct BubbleLinkPreviewData {
  let url: URL
  let title: String
  let site: String
  let icon: UIImage?
}

private func bubbleBaseText(for row: ChatListRow) -> (text: String, addPrefix: Bool) {
  if row.isAgentMessage {
    return (row.plainContent ?? row.text, true)
  }
  if row.isAgentMention {
    return (row.textWithoutMention, true)
  }
  return (row.text, false)
}

private func bubbleDisplayText(for row: ChatListRow) -> String {
  let payload = bubbleBaseText(for: row)
  guard payload.addPrefix else { return payload.text }
  let prefix = isRTL(payload.text) ? "\u{200F}✦ " : "✦ "
  return payload.text.isEmpty ? prefix : prefix + payload.text
}

private func bubbleParsedBlocks(for row: ChatListRow) -> [AgentParsedBlock] {
  let payload = bubbleBaseText(for: row)
  var blocks = ChatNativeAgentTextRenderer.parseBlocks(payload.text)
  guard payload.addPrefix else { return blocks }

  let prefix = isRTL(payload.text) ? "\u{200F}✦ " : "✦ "
  if blocks.isEmpty {
    return [.text(prefix)]
  }

  switch blocks[0] {
  case .text(let content):
    blocks[0] = .text(content.isEmpty ? prefix : prefix + content)
  case .code:
    blocks.insert(.text(prefix.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
  }
  return blocks
}

private func bubbleUsesBlockLayout(_ row: ChatListRow) -> Bool {
  guard row.kind == .message, row.visualKind == .text, row.messageType != "typing", row.isAgentMessage
  else {
    return false
  }
  let blocks = bubbleParsedBlocks(for: row)
  return blocks.contains { block in
    if case .code = block {
      return true
    }
    return false
  } || blocks.count > 1
}

private func bubbleRichTextStorageKey(for row: ChatListRow, blockIndex: Int) -> String {
  "\(row.key)#\(blockIndex)"
}

private func bubbleInternalChatId(from url: URL) -> String? {
  let host = url.host?.lowercased() ?? ""
  guard host.contains("vibe") || host.contains("vibegram") || url.scheme == "vibe" else {
    return nil
  }

  let path = url.path
  let nsPath = path as NSString
  let pathRange = NSRange(location: 0, length: nsPath.length)
  if let match = bubbleInternalChatIdRegex.firstMatch(in: path, range: pathRange) {
    return nsPath.substring(with: match.range)
  }

  if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
    let items = components.queryItems
  {
    for item in items {
      let lowercasedName = item.name.lowercased()
      if (lowercasedName.contains("chat") || lowercasedName.contains("id")),
        let value = item.value,
        !value.isEmpty
      {
        return value
      }
    }
  }

  return nil
}

private func bubbleCanPreviewURL(_ url: URL) -> Bool {
  guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
    return false
  }
  return bubbleInternalChatId(from: url) == nil
}

private func bubblePreviewURL(for row: ChatListRow) -> URL? {
  guard row.kind == .message, row.visualKind == .text, row.messageType != "typing",
    !hasInlineAttachment(row)
  else {
    return nil
  }

  let sourceText = bubbleBaseText(for: row).text
  guard !sourceText.isEmpty else { return nil }

  let range = NSRange(sourceText.startIndex..., in: sourceText)
  let matches = bubbleURLDetector.matches(in: sourceText, options: [], range: range)
  for match in matches {
    guard let url = match.url, bubbleCanPreviewURL(url) else { continue }
    return url
  }
  return nil
}

private func bubblePreviewSiteLabel(for url: URL) -> String {
  guard let host = url.host?.lowercased(), !host.isEmpty else {
    return url.absoluteString
  }
  return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

private func bubblePreviewTitleFallback(for url: URL) -> String {
  let site = bubblePreviewSiteLabel(for: url)
  let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  guard !trimmedPath.isEmpty else { return site }
  let compactPath = trimmedPath.count > 32 ? String(trimmedPath.prefix(32)) + "..." : trimmedPath
  return site + "/" + compactPath
}

private func measureBubbleCodeBlockHeight(
  code: String,
  language: String?,
  baseFont: UIFont,
  availableWidth: CGFloat,
  storageKey: String
) -> CGFloat {
  let codeFont = UIFont.monospacedSystemFont(
    ofSize: max(12.5, baseFont.pointSize - 2.5),
    weight: .regular
  )
  let hPad: CGFloat = 12.0
  let vPad: CGFloat = 10.0
  let barHeight: CGFloat = 32.0
  let labelWidth = max(1.0, availableWidth - (hPad * 2.0))
  let totalLineCount = code.components(separatedBy: "\n").count
  let isExpanded = AgentCodeBlockView.isExpanded(
    code: code,
    language: language,
    storageKey: storageKey
  )
  let visibleCode: String
  if !isExpanded && totalLineCount > 12 {
    visibleCode = code.components(separatedBy: "\n").prefix(12).joined(separator: "\n")
  } else {
    visibleCode = code
  }

  let attributed = NSAttributedString(
    string: visibleCode,
    attributes: [
      .font: codeFont,
      .foregroundColor: UIColor.white.withAlphaComponent(0.88),
    ]
  )
  let textHeight = ceil(
    attributed.boundingRect(
      with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    ).height
  )
  let bodyHeight = max(ceil(codeFont.lineHeight), textHeight)
  return barHeight + vPad + bodyHeight + vPad + 8.0
}

private func measureBubbleRichText(for row: ChatListRow, availableWidth: CGFloat) -> BubbleRichTextMeasurement {
  let blocks = bubbleParsedBlocks(for: row)
  guard !blocks.isEmpty else {
    return BubbleRichTextMeasurement(height: 0.0, maxWidth: 0.0)
  }

  let font = bubbleMessageFont
  let textColor = row.isMe ? UIColor.white : UIColor.label
  var totalHeight: CGFloat = 0.0
  var maxWidth: CGFloat = 0.0

  for (index, block) in blocks.enumerated() {
    switch block {
    case .text(let content):
      let attributed = ChatNativeAgentTextRenderer.makeAttributedText(
        text: content,
        font: font,
        textColor: textColor
      )
      let measured = ChatNativeAgentTextRenderer.measuredSize(for: attributed, width: availableWidth)
      totalHeight += max(ceil(font.lineHeight), measured.height)
      maxWidth = max(maxWidth, min(availableWidth, measured.width))
    case .code(let content, let language):
      totalHeight += measureBubbleCodeBlockHeight(
        code: content,
        language: language,
        baseFont: font,
        availableWidth: availableWidth,
        storageKey: bubbleRichTextStorageKey(for: row, blockIndex: index)
      )
      maxWidth = max(maxWidth, availableWidth)
    }

    if index < blocks.count - 1 {
      totalHeight += bubbleRichTextBlockSpacing
    }
  }

  return BubbleRichTextMeasurement(height: totalHeight, maxWidth: maxWidth)
}

private func parseBubbleMarkdown(
  text: String,
  font: UIFont,
  textColor: UIColor? = nil,
  useSharedAgentRenderer: Bool = false
)
  -> NSAttributedString
{
  _ = useSharedAgentRenderer
  return ChatNativeAgentTextRenderer.makeAttributedText(
    text: text,
    font: font,
    textColor: textColor ?? .label
  )
}

private func bubbleDisplayAttributedString(
  for row: ChatListRow, font: UIFont, textColor: UIColor? = nil
) -> NSAttributedString {
  return parseBubbleMarkdown(
    text: bubbleDisplayText(for: row),
    font: font,
    textColor: textColor,
    useSharedAgentRenderer: row.isAgentMessage || row.isAgentMention
  )
}

private typealias AgentStreamingLabel = ChatNativeStreamingTextLabel

private final class BubbleRichTextView: UIView {
  private var blockViews: [UIView] = []
  private var blockFrames: [CGRect] = []
  private var lastSignature = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func reset() {
    blockViews.forEach { $0.removeFromSuperview() }
    blockViews = []
    blockFrames = []
    lastSignature = ""
  }

  @discardableResult
  func configure(row: ChatListRow, textColor: UIColor, availableWidth: CGFloat) -> CGFloat {
    let blocks = bubbleParsedBlocks(for: row)
    guard !blocks.isEmpty else {
      reset()
      return 0.0
    }

    let signature = blocks.enumerated().map { index, block in
      switch block {
      case .text:
        return "T\(index)"
      case .code:
        return "C\(index)"
      }
    }.joined(separator: "-")

    if signature != lastSignature || blockViews.count != blocks.count {
      reset()
      blockViews = blocks.map { block in
        switch block {
        case .text:
          let label = ChatNativeStreamingTextLabel()
          label.numberOfLines = 0
          label.backgroundColor = .clear
          addSubview(label)
          return label
        case .code:
          let card = AgentCodeBlockView()
          addSubview(card)
          return card
        }
      }
      lastSignature = signature
    }

    let baseFont = bubbleMessageFont
    var yOffset: CGFloat = 0.0
    blockFrames = []

    var lastTextIndex: Int?
    for (index, block) in blocks.enumerated() {
      if case .text = block {
        lastTextIndex = index
      }
    }

    for (index, block) in blocks.enumerated() {
      let view = blockViews[index]
      switch block {
      case .text(let content):
        let label = view as! ChatNativeStreamingTextLabel
        let attributed = ChatNativeAgentTextRenderer.makeAttributedText(
          text: content,
          font: baseFont,
          textColor: textColor
        )
        let measured = ChatNativeAgentTextRenderer.measuredSize(for: attributed, width: availableWidth)
        let height = max(ceil(baseFont.lineHeight), measured.height)
        label.applyStreamingText(
          attributed,
          rawText: content,
          isStreaming: row.isStreamingText && index == lastTextIndex
        )
        blockFrames.append(CGRect(x: 0.0, y: yOffset, width: availableWidth, height: height))
        yOffset += height
      case .code(let content, let language):
        let card = view as! AgentCodeBlockView
        let cardHeight = card.configure(
          code: content,
          language: language,
          textColor: textColor,
          baseFont: baseFont,
          availableWidth: availableWidth,
          storageKey: bubbleRichTextStorageKey(for: row, blockIndex: index)
        )
        blockFrames.append(CGRect(x: 0.0, y: yOffset, width: availableWidth, height: cardHeight))
        yOffset += cardHeight
      }

      if index < blocks.count - 1 {
        yOffset += bubbleRichTextBlockSpacing
      }
    }

    setNeedsLayout()
    return yOffset
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    for (index, blockView) in blockViews.enumerated() where index < blockFrames.count {
      blockView.frame = blockFrames[index]
    }
  }
}

private final class BubbleLinkPreviewStore {
  static let shared = BubbleLinkPreviewStore()

  private var cached: [String: BubbleLinkPreviewData] = [:]
  private var inFlight: [String: [(BubbleLinkPreviewData) -> Void]] = [:]
  private var activeProviders: [String: LPMetadataProvider] = [:]

  private init() {}

  func fetch(url: URL, completion: @escaping (BubbleLinkPreviewData) -> Void) {
    let key = url.absoluteString
    if let cachedData = cached[key] {
      DispatchQueue.main.async {
        completion(cachedData)
      }
      return
    }

    inFlight[key, default: []].append(completion)
    guard inFlight[key]?.count == 1 else { return }

    let provider = LPMetadataProvider()
  activeProviders[key] = provider
    provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
      guard let self else { return }
      let resolvedURL = metadata?.originalURL ?? metadata?.url ?? url
      let trimmedTitle = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let fallback = BubbleLinkPreviewData(
        url: resolvedURL,
        title: trimmedTitle.isEmpty ? bubblePreviewTitleFallback(for: resolvedURL) : trimmedTitle,
        site: bubblePreviewSiteLabel(for: resolvedURL),
        icon: nil
      )

      self.loadPreviewImage(from: metadata) { image in
        self.finish(
          key: key,
          data: BubbleLinkPreviewData(
            url: fallback.url,
            title: fallback.title,
            site: fallback.site,
            icon: image
          )
        )
      }
    }
  }

  private func loadPreviewImage(
    from metadata: LPLinkMetadata?,
    completion: @escaping (UIImage?) -> Void
  ) {
    let providers = [metadata?.iconProvider, metadata?.imageProvider].compactMap { $0 }
    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else {
      DispatchQueue.main.async {
        completion(nil)
      }
      return
    }

    provider.loadObject(ofClass: UIImage.self) { object, _ in
      DispatchQueue.main.async {
        completion(object as? UIImage)
      }
    }
  }

  private func finish(key: String, data: BubbleLinkPreviewData) {
    DispatchQueue.main.async {
      self.cached[key] = data
      self.activeProviders.removeValue(forKey: key)
      let callbacks = self.inFlight.removeValue(forKey: key) ?? []
      callbacks.forEach { $0(data) }
    }
  }
}

private final class BubbleReplyPreviewView: UIView {
  private let backgroundOverlay = UIView()
  private let accentView = UIView()
  private let titleLabel = UILabel()
  private let previewLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    clipsToBounds = true
    layer.cornerRadius = 6.0

    backgroundOverlay.isUserInteractionEnabled = false
    addSubview(backgroundOverlay)

    accentView.layer.cornerCurve = .continuous
    accentView.layer.cornerRadius = 1.5
    addSubview(accentView)

    titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    addSubview(titleLabel)

    previewLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
    previewLabel.numberOfLines = 1
    previewLabel.lineBreakMode = .byTruncatingTail
    addSubview(previewLabel)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func reset() {
    titleLabel.text = nil
    previewLabel.text = nil
  }

  func configure(title: String, text: String, appearance: ChatListAppearance, isMe: Bool) {
    titleLabel.text = title
    previewLabel.text = text
    applyAppearance(appearance, isMe: isMe)
  }

  func applyAppearance(_ appearance: ChatListAppearance, isMe: Bool) {
    let titleColor = isMe ? appearance.textColorMe : appearance.textColorThem
    let accentColor =
      isMe ? (appearance.bubbleMeGradient.first ?? titleColor) : appearance.bubbleThemColor

    accentView.backgroundColor = accentColor.withAlphaComponent(0.95)
    titleLabel.textColor = titleColor.withAlphaComponent(0.94)
    previewLabel.textColor = titleColor.withAlphaComponent(0.68)

    backgroundOverlay.backgroundColor = accentColor.withAlphaComponent(appearance.isDark ? 0.15 : 0.08)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    backgroundOverlay.frame = bounds

    let height = bounds.height
    let accentH = max(4.0, height - 8.0)
    accentView.frame = CGRect(x: 4.0, y: 4.0, width: 3.0, height: accentH)

    let textX = accentView.frame.maxX + 6.0
    let textW = max(1.0, bounds.width - textX - 8.0)

    titleLabel.frame = CGRect(x: textX, y: 3.0, width: textW, height: 16.0)
    previewLabel.frame = CGRect(x: textX, y: titleLabel.frame.maxY, width: textW, height: 16.0)
  }
}

private final class BubbleLinkPreviewView: UIView {
  private let accentView = UIView()
  private let iconView = UIImageView()
  private let siteLabel = UILabel()
  private let titleLabel = UILabel()
  private var currentURL: URL?
  private var currentAppearance = ChatListAppearance.fallback
  private var currentIsMe = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    layer.cornerRadius = 14.0
    layer.cornerCurve = .continuous
    layer.borderWidth = 1.0 / UIScreen.main.scale
    clipsToBounds = true

    accentView.isUserInteractionEnabled = false
    addSubview(accentView)

    iconView.contentMode = .scaleAspectFit
    iconView.clipsToBounds = true
    iconView.layer.cornerRadius = 8.0
    addSubview(iconView)

    siteLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    siteLabel.numberOfLines = 1
    addSubview(siteLabel)

    titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    titleLabel.numberOfLines = 2
    addSubview(titleLabel)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func reset() {
    currentURL = nil
    siteLabel.text = nil
    titleLabel.text = nil
    iconView.image = UIImage(systemName: "globe")
    iconView.contentMode = .scaleAspectFit
  }

  func applyAppearance(_ appearance: ChatListAppearance, isMe: Bool) {
    currentAppearance = appearance
    currentIsMe = isMe

    let accentColor = isMe
      ? (appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor)
      : appearance.bubbleThemColor
    accentView.backgroundColor = accentColor.withAlphaComponent(0.94)
    layer.borderColor = accentColor.withAlphaComponent(appearance.isDark ? 0.34 : 0.20).cgColor
    backgroundColor = isMe
      ? UIColor.white.withAlphaComponent(appearance.isDark ? 0.14 : 0.22)
      : UIColor(white: appearance.isDark ? 1.0 : 0.0, alpha: appearance.isDark ? 0.08 : 0.05)
    siteLabel.textColor = accentColor.withAlphaComponent(0.96)
    titleLabel.textColor = isMe ? appearance.textColorMe : appearance.textColorThem
    if iconView.image == nil || iconView.contentMode != .scaleAspectFill {
      iconView.image = UIImage(systemName: "globe")
      iconView.tintColor = accentColor.withAlphaComponent(0.96)
      iconView.backgroundColor = accentColor.withAlphaComponent(appearance.isDark ? 0.14 : 0.10)
      iconView.contentMode = .scaleAspectFit
    }
  }

  func configure(url: URL, appearance: ChatListAppearance, isMe: Bool) {
    currentURL = url
    applyAppearance(appearance, isMe: isMe)

    siteLabel.text = bubblePreviewSiteLabel(for: url)
    titleLabel.text = bubblePreviewTitleFallback(for: url)
    iconView.image = UIImage(systemName: "globe")
    iconView.tintColor = (isMe
      ? (appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor)
      : appearance.bubbleThemColor).withAlphaComponent(0.96)
    iconView.backgroundColor = iconView.tintColor.withAlphaComponent(appearance.isDark ? 0.14 : 0.10)
    iconView.contentMode = .scaleAspectFit

    BubbleLinkPreviewStore.shared.fetch(url: url) { [weak self] data in
      guard let self, self.currentURL?.absoluteString == url.absoluteString else { return }
      self.siteLabel.text = data.site
      self.titleLabel.text = data.title
      if let icon = data.icon {
        self.iconView.image = icon
        self.iconView.backgroundColor = .clear
        self.iconView.contentMode = .scaleAspectFill
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    accentView.frame = CGRect(x: 0.0, y: 0.0, width: 3.0, height: bounds.height)

    let leadingInset: CGFloat = 14.0
    let iconSize: CGFloat = 24.0
    iconView.frame = CGRect(
      x: leadingInset,
      y: floor((bounds.height - iconSize) * 0.5),
      width: iconSize,
      height: iconSize
    )

    let textX = iconView.frame.maxX + 10.0
    let textWidth = max(1.0, bounds.width - textX - 14.0)
    siteLabel.frame = CGRect(x: textX, y: 12.0, width: textWidth, height: 14.0)
    titleLabel.frame = CGRect(
      x: textX,
      y: siteLabel.frame.maxY + 4.0,
      width: textWidth,
      height: bounds.height - siteLabel.frame.maxY - 16.0
    )
  }

  @objc private func handleTap() {
    guard let currentURL else { return }
    InAppBrowserViewController.present(url: currentURL)
  }
}

func measureMessageBubbleLayout(row: ChatListRow, rowWidth: CGFloat)
  -> ChatMessageBubbleLayoutMetrics
{
  let maxBubbleWidth = floor(rowWidth * bubbleMaxWidthFactor)
  let maxContentWidth = max(1.0, maxBubbleWidth - (bubbleHorizontalPadding * 2.0))
  let meta = bubbleMetaWidths(for: row)

  if usesTransparentAgentStreamingLayout(row) {
    let bubbleWidth = max(1.0, rowWidth - (bubbleSideMargin * 2.0))
    let messageWidth = max(1.0, bubbleWidth - (bubbleHorizontalPadding * 2.0))
    let usesRichTextLayout = bubbleUsesBlockLayout(row)
    let previewHeight = bubblePreviewURL(for: row) == nil ? 0.0 : bubbleLinkPreviewHeight
    let textHeight: CGFloat
    if usesRichTextLayout {
      textHeight = measureBubbleRichText(for: row, availableWidth: messageWidth).height
    } else {
      let displayText = bubbleDisplayAttributedString(for: row, font: bubbleMessageFont)
      let textRect = displayText.boundingRect(
        with: CGSize(width: messageWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
      textHeight = ceil(textRect.height)
    }
    let bodyHeight = textHeight + (previewHeight > 0.0 ? (bubbleLinkPreviewSpacing + previewHeight) : 0.0)
    let bubbleHeight = max(36.0, bodyHeight + bubbleTopPadding + bubbleBottomPadding)
    return ChatMessageBubbleLayoutMetrics(
      bubbleWidth: bubbleWidth,
      bubbleHeight: bubbleHeight,
      messageWidth: messageWidth,
      textHeight: textHeight,
      bodyHeight: bodyHeight,
      metaWidth: 0.0,
      contentWidth: messageWidth,
      mediaHeight: 0.0,
      isMediaLayout: false,
      inlineAttachmentHeight: 0.0,
      hasInlineAttachment: false,
      replyPreviewHeight: 0.0,
      hasReplyPreview: false,
      previewHeight: previewHeight,
      hasLinkPreview: previewHeight > 0.0,
      usesBottomMetaLayout: previewHeight > 0.0 || usesRichTextLayout,
      usesRichTextLayout: usesRichTextLayout
    )
  }

  switch row.visualKind {
  case .voice, .video, .videoNote, .media, .sticker:
    var targetWidth: CGFloat
    var mediaHeight: CGFloat
    switch row.visualKind {
    case .voice:
      if usesAudioMetadataVoiceLayout(row) {
        let titleWidth = ceil(
          (resolvedAudioVoiceTitle(row) as NSString).size(
            withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold)]
          ).width
        )
        let detailWidth = ceil(
          (resolvedAudioVoiceStaticDetail(row) as NSString).size(
            withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .regular)]
          ).width
        )
        let textWidth = max(titleWidth, detailWidth)
        let minW = 176.0 + meta.total
        targetWidth = min(
          maxContentWidth,
          max(minW, textWidth + 86.0)
        )
      } else {
        let dur = max(1.0, min(30.0, row.duration ?? 1.0))
        let frac = CGFloat((Double(dur) - log(Double(max(2.0, dur)))) / 15.0)
        let minW = 100.0 + meta.total
        targetWidth = minW + max(0.0, min(1.0, frac)) * (maxContentWidth - minW)
      }
      mediaHeight = 60.0
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
    let hasMediaCaption = hasMediaCaptionLayout(row) && !isTransparentSticker
    let captionAttributedText =
      hasMediaCaption
      ? bubbleDisplayAttributedString(for: row, font: bubbleMessageFont)
      : nil
    let captionRect =
      captionAttributedText?.boundingRect(
        with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      ) ?? .zero
    let captionWidth = min(contentWidth, ceil(captionRect.width))
    let captionHeight = ceil(captionRect.height)
    let messageWidth = hasMediaCaption ? max(contentWidth, captionWidth) : contentWidth
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
      let captionBlockHeight: CGFloat
      if hasMediaCaption && !isVoice && !isFullBleed {
        captionBlockHeight = 8.0 + captionHeight + bubbleMetaTopSpacing + bubbleMetaHeight
      } else if isFullBleed || isVoice {
        captionBlockHeight = 0.0
      } else {
        captionBlockHeight = metaTopSpacing + bubbleMetaHeight
      }
      bodyHeight =
        (isFullBleed || isVoice) ? mediaHeight : (mediaHeight + captionBlockHeight)
      bubbleWidth =
        isFullBleed
        ? max(bubbleMinWidth, contentWidth)
        : max(bubbleMinWidth, max(contentWidth, messageWidth) + (bubbleHorizontalPadding * 2.0))
      let topPad = isVoice ? 2.0 : bubbleTopPadding
      let bottomPad = isVoice ? 7.0 : bubbleBottomPadding
      bubbleHeight =
        isFullBleed
        ? max(56.0, bodyHeight + reactionHeightOffset)
        : max(isVoice ? 66.0 : 48.0, bodyHeight + topPad + bottomPad + reactionHeightOffset)
    }
    return ChatMessageBubbleLayoutMetrics(
      bubbleWidth: bubbleWidth,
      bubbleHeight: bubbleHeight,
      messageWidth: messageWidth,
      textHeight: hasMediaCaption ? captionHeight : 0.0,
      bodyHeight: bodyHeight,
      metaWidth: meta.total,
      contentWidth: contentWidth,
      mediaHeight: mediaHeight,
      isMediaLayout: true,
      inlineAttachmentHeight: 0.0,
      hasInlineAttachment: false,
      replyPreviewHeight: 0.0,
      hasReplyPreview: false,
      previewHeight: 0.0,
      hasLinkPreview: false,
      usesBottomMetaLayout: false,
      usesRichTextLayout: false
    )

  case .text:
    break
  }

  let showsReplyPreview = hasReplyPreview(row)
  let showsInlineAttachment = hasInlineAttachment(row)
  let usesRichTextLayout = bubbleUsesBlockLayout(row)
  let previewHeight = bubblePreviewURL(for: row) == nil ? 0.0 : bubbleLinkPreviewHeight
  let usesRTLColumn = usesRTLColumnLayout(row) && !showsInlineAttachment && !usesRichTextLayout && previewHeight <= 0.0
  let replyPreviewHeight = showsReplyPreview ? bubbleReplyPreviewHeight : 0.0
  let replyPreviewBlockHeight =
    showsReplyPreview ? (bubbleReplyPreviewHeight + bubbleReplyPreviewSpacing) : 0.0
  let usesBottomMetaLayout = usesRichTextLayout || previewHeight > 0.0 || usesRTLColumn
  let textMaxWidth: CGFloat =
    showsInlineAttachment || usesBottomMetaLayout
    ? maxContentWidth
    : max(1.0, maxContentWidth - meta.total - bubbleMetaInlineSpacing)
  let font =
    row.messageType == "typing"
    ? UIFont.systemFont(ofSize: 13, weight: .regular) : bubbleMessageFont
  let textWidth: CGFloat
  let textHeight: CGFloat
  if usesRichTextLayout {
    let measured = measureBubbleRichText(for: row, availableWidth: textMaxWidth)
    textWidth = min(textMaxWidth, max(measured.maxWidth, previewHeight > 0.0 ? bubbleLinkPreviewMinWidth : 0.0))
    textHeight = measured.height
  } else {
    let displayText = bubbleDisplayAttributedString(for: row, font: font)
    let textRect = displayText.boundingRect(
      with: CGSize(width: textMaxWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    textWidth = min(textMaxWidth, ceil(textRect.width))
    textHeight = ceil(textRect.height)
  }
  let attachmentBodyHeight: CGFloat = showsInlineAttachment ? inlineAttachmentHeight : 0.0
  let desiredContentWidth: CGFloat
  let replyPreviewWidth: CGFloat
  if showsReplyPreview {
    let titleWidth = measuredTextWidth(
      replyPreviewTitle(for: row), font: UIFont.systemFont(ofSize: 13, weight: .semibold))
    let textWidth = measuredTextWidth(
      replyPreviewText(for: row), font: UIFont.systemFont(ofSize: 13, weight: .regular))
    replyPreviewWidth = min(
      maxContentWidth,
      max(bubbleReplyPreviewMinWidth, max(titleWidth, textWidth) + 24.0)
    )
  } else {
    replyPreviewWidth = 0.0
  }
  if showsInlineAttachment {
    let attachmentTitle = inlineAttachmentTitle(for: row)
    let attachmentWidth =
      min(
        maxContentWidth,
        max(
          168.0,
          measuredTextWidth(attachmentTitle, font: UIFont.systemFont(ofSize: 13, weight: .semibold))
            + 62.0)
      )
    desiredContentWidth = max(textWidth, attachmentWidth, replyPreviewWidth)
  } else if usesBottomMetaLayout {
    desiredContentWidth = max(
      textWidth,
      usesRTLColumn ? meta.total : 0.0,
      previewHeight > 0.0 ? bubbleLinkPreviewMinWidth : 0.0,
      replyPreviewWidth
    )
  } else {
    desiredContentWidth = max(textWidth + bubbleMetaInlineSpacing + meta.total, replyPreviewWidth)
  }
  let contentWidth = max(meta.total, min(maxContentWidth, desiredContentWidth))
  let messageWidth =
    showsInlineAttachment || usesBottomMetaLayout
    ? contentWidth
    : max(1.0, contentWidth - meta.total - bubbleMetaInlineSpacing)
  let bodyHeight =
    showsInlineAttachment
    ? replyPreviewBlockHeight + max(textHeight, 0.0) + inlineAttachmentSpacing
      + attachmentBodyHeight + bubbleMetaTopSpacing + bubbleMetaHeight
    : usesBottomMetaLayout
    ? replyPreviewBlockHeight + max(textHeight, 0.0)
      + (previewHeight > 0.0 ? (bubbleLinkPreviewSpacing + previewHeight) : 0.0)
      + bubbleMetaTopSpacing + bubbleMetaHeight
    : replyPreviewBlockHeight + max(textHeight, bubbleMetaHeight)
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
    hasInlineAttachment: showsInlineAttachment,
    replyPreviewHeight: replyPreviewHeight,
    hasReplyPreview: showsReplyPreview,
    previewHeight: previewHeight,
    hasLinkPreview: previewHeight > 0.0,
    usesBottomMetaLayout: usesBottomMetaLayout,
    usesRichTextLayout: usesRichTextLayout
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
  private let fillLayer = CAShapeLayer()
  private let trackLayer = CAShapeLayer()
  private let progressLayer = CAShapeLayer()
  private let iconView = UIImageView()
  private let uploadProgressAnimationKey = "media.upload.progress"
  private let uploadSpinAnimationKey = "media.upload.spin"
  private let minimumUploadProgress: CGFloat = 0.027
  private var isUploading = false
  private var needsDownload = false
  private var isDownloading = false
  private var uploadProgress: CGFloat?
  private var lastResolvedUploadProgress: CGFloat?
  private var downloadProgress: CGFloat?
  private var lastResolvedDownloadProgress: CGFloat?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear

    fillLayer.fillColor = UIColor(white: 0.0, alpha: 0.58).cgColor

    trackLayer.fillColor = UIColor.clear.cgColor
    trackLayer.strokeColor = UIColor(white: 1.0, alpha: 0.28).cgColor
    trackLayer.lineWidth = 3.0

    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.strokeColor = UIColor.white.cgColor
    progressLayer.lineWidth = 3.0
    progressLayer.lineCap = .round
    progressLayer.strokeStart = 0.0
    progressLayer.strokeEnd = 0.0

    layer.addSublayer(fillLayer)
    layer.addSublayer(trackLayer)
    layer.addSublayer(progressLayer)

    iconView.image = UIImage(systemName: "xmark")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
    iconView.tintColor = .white
    iconView.contentMode = .scaleAspectFit
    iconView.isHidden = true
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
    let fillDiameter = max(1.0, min(bounds.width, bounds.height) - 10.0)
    let fillFrame = CGRect(
      x: floor((bounds.width - fillDiameter) * 0.5),
      y: floor((bounds.height - fillDiameter) * 0.5),
      width: fillDiameter,
      height: fillDiameter
    )
    fillLayer.frame = bounds
    fillLayer.path = UIBezierPath(ovalIn: fillFrame).cgPath
    trackLayer.path = path.cgPath
    progressLayer.path = path.cgPath
    iconView.frame = CGRect(
      x: floor((bounds.width - 16.0) * 0.5),
      y: floor((bounds.height - 16.0) * 0.5),
      width: 16.0,
      height: 16.0
    )
  }

  func setUploadState(isUploading: Bool, progress: Double?) {
    if isUploading {
      needsDownload = false
      isDownloading = false
      downloadProgress = nil
      lastResolvedDownloadProgress = nil
    }
    let resolvedProgress: CGFloat?
    if isUploading {
      if let normalizedProgress = quantizedTransferProgress(
        progress.map { CGFloat($0) }, minimum: minimumUploadProgress)
      {
        lastResolvedUploadProgress = normalizedProgress
        resolvedProgress = normalizedProgress
      } else if let lastResolvedUploadProgress {
        resolvedProgress = lastResolvedUploadProgress
      } else {
        lastResolvedUploadProgress = minimumUploadProgress
        resolvedProgress = minimumUploadProgress
      }
    } else {
      resolvedProgress = nil
      lastResolvedUploadProgress = nil
    }

    if self.isUploading == isUploading, self.uploadProgress == resolvedProgress {
      return
    }

    self.isUploading = isUploading
    self.uploadProgress = resolvedProgress
    updateUploadRingVisual()
  }

  func setDownloadState(needsDownload: Bool, isDownloading: Bool, progress: Double?) {
    guard !isUploading else { return }

    let resolvedProgress: CGFloat?
    if isDownloading {
      if let normalizedProgress = quantizedTransferProgress(
        progress.map { CGFloat($0) }, minimum: minimumUploadProgress)
      {
        lastResolvedDownloadProgress = normalizedProgress
        resolvedProgress = normalizedProgress
      } else if let lastResolvedDownloadProgress {
        resolvedProgress = lastResolvedDownloadProgress
      } else {
        lastResolvedDownloadProgress = minimumUploadProgress
        resolvedProgress = minimumUploadProgress
      }
    } else {
      resolvedProgress = nil
      lastResolvedDownloadProgress = nil
    }

    if self.needsDownload == needsDownload, self.isDownloading == isDownloading,
      self.downloadProgress == resolvedProgress
    {
      return
    }

    self.needsDownload = needsDownload
    self.isDownloading = isDownloading
    self.downloadProgress = resolvedProgress
    updateDownloadRingVisual()
  }

  private func updateUploadRingVisual() {
    guard isUploading else {
      progressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
      progressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      progressLayer.strokeStart = 0.0
      progressLayer.strokeEnd = 0.0
      iconView.isHidden = true
      return
    }

    let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    iconView.image = UIImage(systemName: "xmark", withConfiguration: config)
    iconView.tintColor = .white
    iconView.isHidden = false

    let targetProgress = max(
      minimumUploadProgress,
      min(1.0, uploadProgress ?? minimumUploadProgress)
    )
    let currentProgress = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
    let shouldAnimate =
      abs(currentProgress - targetProgress) >= chatTransferProgressAnimationThreshold
      || targetProgress >= 0.999

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progressLayer.strokeStart = 0.0
    progressLayer.strokeEnd = targetProgress
    CATransaction.commit()

    if shouldAnimate {
      let progressAnimation = CABasicAnimation(keyPath: "strokeEnd")
      progressAnimation.fromValue = currentProgress
      progressAnimation.toValue = targetProgress
      progressAnimation.duration = 0.16
      progressAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
      progressLayer.add(progressAnimation, forKey: uploadProgressAnimationKey)
    } else {
      progressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
    }

    if progressLayer.animation(forKey: uploadSpinAnimationKey) == nil {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0.0
      spin.toValue = (2.0 * CGFloat.pi)
      spin.duration = 1.57
      spin.repeatCount = .infinity
      spin.timingFunction = CAMediaTimingFunction(name: .linear)
      spin.isRemovedOnCompletion = true
      progressLayer.add(spin, forKey: uploadSpinAnimationKey)
    }
  }

  private func updateDownloadRingVisual() {
    guard needsDownload else {
      progressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
      progressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      progressLayer.strokeStart = 0.0
      progressLayer.strokeEnd = 0.0
      iconView.isHidden = true
      return
    }

    guard isDownloading else {
      progressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
      progressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      progressLayer.strokeStart = 0.0
      progressLayer.strokeEnd = 0.0
      iconView.isHidden = true
      return
    }

    iconView.isHidden = true

    let targetProgress = max(
      minimumUploadProgress,
      min(1.0, downloadProgress ?? minimumUploadProgress)
    )
    let currentProgress = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
    let shouldAnimate =
      abs(currentProgress - targetProgress) >= chatTransferProgressAnimationThreshold
      || targetProgress >= 0.999

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progressLayer.strokeStart = 0.0
    progressLayer.strokeEnd = targetProgress
    CATransaction.commit()

    if shouldAnimate {
      let progressAnimation = CABasicAnimation(keyPath: "strokeEnd")
      progressAnimation.fromValue = currentProgress
      progressAnimation.toValue = targetProgress
      progressAnimation.duration = 0.16
      progressAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
      progressLayer.add(progressAnimation, forKey: uploadProgressAnimationKey)
    } else {
      progressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
    }

    if progressLayer.animation(forKey: uploadSpinAnimationKey) == nil {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0.0
      spin.toValue = (2.0 * CGFloat.pi)
      spin.duration = 1.57
      spin.repeatCount = .infinity
      spin.timingFunction = CAMediaTimingFunction(name: .linear)
      spin.isRemovedOnCompletion = true
      progressLayer.add(spin, forKey: uploadSpinAnimationKey)
    }
  }
}

final class VoicePlayProgressView: UIView {
  private let fluidVisualizer = FluidVADVisualizer()
  private let fillView = UIView()
  private let artworkImageView = UIImageView()
  private let artworkOverlayView = UIView()
  private let iconView = UIImageView()
  private let ringProgressLayer = CAShapeLayer()
  private let uploadProgressAnimationKey = "voice.upload.progress"
  private var iconTintColor = UIColor.systemBlue
  private var isUploading = false
  private var needsDownload = false
  private var isDownloading = false
  private var uploadProgress: CGFloat?
  private var lastResolvedUploadProgress: CGFloat?
  private var downloadProgress: CGFloat?
  private var lastResolvedDownloadProgress: CGFloat?
  private let uploadSpinAnimationKey = "voice.upload.spin"
  private let minimumUploadProgress: CGFloat = 0.027

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

    artworkImageView.isHidden = true
    artworkImageView.contentMode = .scaleAspectFill
    artworkImageView.clipsToBounds = true
    fillView.addSubview(artworkImageView)

    artworkOverlayView.isHidden = true
    artworkOverlayView.isUserInteractionEnabled = false
    artworkOverlayView.backgroundColor = UIColor(white: 0.0, alpha: 0.18)
    fillView.addSubview(artworkOverlayView)

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
    artworkImageView.frame = fillView.bounds
    artworkImageView.layer.cornerRadius = fillView.layer.cornerRadius
    artworkOverlayView.frame = fillView.bounds
    artworkOverlayView.layer.cornerRadius = fillView.layer.cornerRadius

    fluidVisualizer.activePushMultiplier = 0.15
    fluidVisualizer.frame = fillView.frame

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
      x: floor((bounds.width - 20.0) * 0.5),
      y: floor((bounds.height - 20.0) * 0.5),
      width: 20.0,
      height: 20.0
    )
  }

  func applyStyle(fillColor: UIColor, iconTint: UIColor, ringTint: UIColor) {
    fillView.backgroundColor = fillColor
    iconTintColor = iconTint
    iconView.tintColor = resolvedIconTintColor()
    fluidVisualizer.applyColor(ringTint.withAlphaComponent(0.35))
    ringProgressLayer.strokeColor = ringTint.cgColor
    if isUploading {
      updateUploadRingVisual()
    }
  }

  func setArtworkImage(_ image: UIImage?) {
    artworkImageView.image = image
    let hasArtwork = image != nil
    artworkImageView.isHidden = !hasArtwork
    artworkOverlayView.isHidden = !hasArtwork
    iconView.tintColor = resolvedIconTintColor()
  }

  func setPlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat = 0.0) {
    guard !isUploading, !isDownloading, !needsDownload else { return }
    ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
    ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
    ringProgressLayer.strokeStart = 0.0
    ringProgressLayer.strokeEnd = 0.0 // Never show ring for playback
    let symbol = isPlaying ? "pause.fill" : "play.fill"
    let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)
    iconView.image = UIImage(systemName: symbol, withConfiguration: config)
    iconView.tintColor = resolvedIconTintColor()

    fluidVisualizer.level = level
    if isPlaying {
      if fluidVisualizer.alpha < 0.05 { fluidVisualizer.start() }
    } else {
      fluidVisualizer.stop()
    }
  }

  func setUploadState(isUploading: Bool, progress: CGFloat?) {
    if isUploading {
      needsDownload = false
      isDownloading = false
      downloadProgress = nil
      lastResolvedDownloadProgress = nil
    }
    let resolvedProgress: CGFloat?
    if isUploading {
      if let normalizedProgress = quantizedTransferProgress(
        progress, minimum: minimumUploadProgress)
      {
        lastResolvedUploadProgress = normalizedProgress
        resolvedProgress = normalizedProgress
      } else if let lastResolvedUploadProgress {
        resolvedProgress = lastResolvedUploadProgress
      } else {
        lastResolvedUploadProgress = minimumUploadProgress
        resolvedProgress = minimumUploadProgress
      }
    } else {
      resolvedProgress = nil
      lastResolvedUploadProgress = nil
    }
    if self.isUploading == isUploading, self.uploadProgress == resolvedProgress {
      return
    }
    self.isUploading = isUploading
    self.uploadProgress = resolvedProgress
    updateUploadRingVisual()
  }

  func setDownloadState(needsDownload: Bool, isDownloading: Bool, progress: CGFloat?) {
    guard !isUploading else { return }

    let resolvedProgress: CGFloat?
    if isDownloading {
      if let normalizedProgress = quantizedTransferProgress(
        progress, minimum: minimumUploadProgress)
      {
        lastResolvedDownloadProgress = normalizedProgress
        resolvedProgress = normalizedProgress
      } else if let lastResolvedDownloadProgress {
        resolvedProgress = lastResolvedDownloadProgress
      } else {
        lastResolvedDownloadProgress = minimumUploadProgress
        resolvedProgress = minimumUploadProgress
      }
    } else {
      resolvedProgress = nil
      lastResolvedDownloadProgress = nil
    }

    if self.needsDownload == needsDownload, self.isDownloading == isDownloading,
      self.downloadProgress == resolvedProgress
    {
      return
    }

    self.needsDownload = needsDownload
    self.isDownloading = isDownloading
    self.downloadProgress = resolvedProgress

    guard needsDownload else {
      ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
      ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      ringProgressLayer.strokeStart = 0.0
      ringProgressLayer.strokeEnd = 0.0
      return
    }

    guard isDownloading else {
      ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
      ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      ringProgressLayer.strokeStart = 0.0
      ringProgressLayer.strokeEnd = 0.0
      let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)
      iconView.image = UIImage(systemName: "arrow.down", withConfiguration: config)
      iconView.tintColor = resolvedIconTintColor()
      fluidVisualizer.stop()
      return
    }

    updateDownloadRingVisual()
  }

  private func updateUploadRingVisual() {
    guard isUploading else {
      ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
      ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      ringProgressLayer.strokeStart = 0.0
      ringProgressLayer.strokeEnd = 0.0
      return
    }
    let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
    iconView.image = UIImage(systemName: "xmark", withConfiguration: config)
    iconView.tintColor = resolvedIconTintColor()

    let targetProgress = max(minimumUploadProgress, min(1.0, uploadProgress ?? minimumUploadProgress))
    let currentProgress = ringProgressLayer.presentation()?.strokeEnd ?? ringProgressLayer.strokeEnd
    let shouldAnimate =
      abs(currentProgress - targetProgress) >= chatTransferProgressAnimationThreshold
      || targetProgress >= 0.999

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ringProgressLayer.strokeStart = 0.0
    ringProgressLayer.strokeEnd = targetProgress
    CATransaction.commit()

    if shouldAnimate {
      let progressAnimation = CABasicAnimation(keyPath: "strokeEnd")
      progressAnimation.fromValue = currentProgress
      progressAnimation.toValue = targetProgress
      progressAnimation.duration = 0.16
      progressAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
      ringProgressLayer.add(progressAnimation, forKey: uploadProgressAnimationKey)
    } else {
      ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
    }

    if ringProgressLayer.animation(forKey: uploadSpinAnimationKey) == nil {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0.0
      spin.toValue = (2.0 * CGFloat.pi)
      spin.duration = 1.57
      spin.repeatCount = .infinity
      spin.timingFunction = CAMediaTimingFunction(name: .linear)
      spin.isRemovedOnCompletion = true
      ringProgressLayer.add(spin, forKey: uploadSpinAnimationKey)
    }
  }

  private func updateDownloadRingVisual() {
    guard needsDownload, isDownloading else {
      ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
      ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      ringProgressLayer.strokeStart = 0.0
      ringProgressLayer.strokeEnd = 0.0
      return
    }
    let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
    iconView.image = UIImage(systemName: "xmark", withConfiguration: config)
    iconView.tintColor = resolvedIconTintColor()

    let targetProgress = max(minimumUploadProgress, min(1.0, downloadProgress ?? minimumUploadProgress))
    let currentProgress = ringProgressLayer.presentation()?.strokeEnd ?? ringProgressLayer.strokeEnd
    let shouldAnimate =
      abs(currentProgress - targetProgress) >= chatTransferProgressAnimationThreshold
      || targetProgress >= 0.999

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ringProgressLayer.strokeStart = 0.0
    ringProgressLayer.strokeEnd = targetProgress
    CATransaction.commit()

    if shouldAnimate {
      let progressAnimation = CABasicAnimation(keyPath: "strokeEnd")
      progressAnimation.fromValue = currentProgress
      progressAnimation.toValue = targetProgress
      progressAnimation.duration = 0.16
      progressAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
      ringProgressLayer.add(progressAnimation, forKey: uploadProgressAnimationKey)
    } else {
      ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
    }

    if ringProgressLayer.animation(forKey: uploadSpinAnimationKey) == nil {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0.0
      spin.toValue = (2.0 * CGFloat.pi)
      spin.duration = 1.57
      spin.repeatCount = .infinity
      spin.timingFunction = CAMediaTimingFunction(name: .linear)
      spin.isRemovedOnCompletion = true
      ringProgressLayer.add(spin, forKey: uploadSpinAnimationKey)
    }
  }

  private func resolvedIconTintColor() -> UIColor {
    artworkImageView.image == nil ? iconTintColor : .white
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
  func applyVoiceDownloadState(needsDownload: Bool, isDownloading: Bool, progress: CGFloat?)
}

fileprivate struct ChatAudioQueueItem {
  let chatId: String
  let messageId: String
  let mediaURL: String
  let mediaKey: String?
  let fileName: String?
  let title: String
  let subtitle: String
  let artwork: UIImage?
  let duration: Double
  let track: NativeMusicPlayerTrack
}

final class ChatAudioQueueRegistry {
  static let shared = ChatAudioQueueRegistry()

  private var itemsByChatId: [String: [ChatAudioQueueItem]] = [:]

  private init() {}

  func setRows(_ rows: [ChatListRow], for chatId: String) {
    let trimmedChatId = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedChatId.isEmpty else { return }

    var nextItems: [ChatAudioQueueItem] = []
    var seenMessageIds = Set<String>()
    nextItems.reserveCapacity(rows.count)

    for row in rows {
      guard let item = makeItem(from: row, fallbackChatId: trimmedChatId) else { continue }
      if seenMessageIds.insert(item.messageId).inserted {
        nextItems.append(item)
        _ = NativeMusicPlayerStore.shared.cacheTrack(payload: item.track.toPayload())
      }
    }

    itemsByChatId[trimmedChatId] = nextItems
  }

  func tracks(for chatId: String?) -> [NativeMusicPlayerTrack] {
    items(for: chatId).map(\.track)
  }

  func tracks(for chatId: String?, fallbackTrackId: String?) -> [NativeMusicPlayerTrack] {
    if let fallbackTrackId,
      let resolvedChatId = resolvedChatId(for: fallbackTrackId, preferredChatId: chatId)
    {
      return items(for: resolvedChatId).map(\.track)
    }
    return tracks(for: chatId)
  }

  func artwork(for trackId: String, in chatId: String?) -> UIImage? {
    item(trackId: trackId, in: chatId)?.artwork
      ?? resolvedItem(trackId: trackId, preferredChatId: chatId)?.artwork
  }

  fileprivate func items(for chatId: String?) -> [ChatAudioQueueItem] {
    let trimmedChatId = chatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedChatId.isEmpty else { return [] }
    return itemsByChatId[trimmedChatId] ?? []
  }

  fileprivate func item(trackId: String, in chatId: String?) -> ChatAudioQueueItem? {
    items(for: chatId).first { $0.track.trackId == trackId }
  }

  fileprivate func resolvedItem(trackId: String, preferredChatId: String?) -> ChatAudioQueueItem? {
    if let item = item(trackId: trackId, in: preferredChatId) {
      return item
    }
    guard let resolvedChatId = resolvedChatId(for: trackId, preferredChatId: preferredChatId) else {
      return nil
    }
    return item(trackId: trackId, in: resolvedChatId)
  }

  fileprivate func adjacentItem(trackId: String, in chatId: String?, step: Int) -> ChatAudioQueueItem? {
    guard step != 0 else { return nil }
    guard let resolvedChatId = resolvedChatId(for: trackId, preferredChatId: chatId) else {
      return nil
    }
    let chatItems = items(for: resolvedChatId)
    guard let currentIndex = chatItems.firstIndex(where: {
      $0.messageId == trackId || $0.track.trackId == trackId
    }) else {
      return nil
    }
    let nextIndex = currentIndex + step
    guard chatItems.indices.contains(nextIndex) else { return nil }
    return chatItems[nextIndex]
  }

  fileprivate func resolvedChatId(for trackId: String, preferredChatId: String?) -> String? {
    let trimmedTrackId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTrackId.isEmpty else { return nil }

    let trimmedPreferredChatId = preferredChatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedPreferredChatId.isEmpty,
      itemsByChatId[trimmedPreferredChatId]?.contains(where: {
        $0.messageId == trimmedTrackId || $0.track.trackId == trimmedTrackId
      }) == true
    {
      return trimmedPreferredChatId
    }

    for (chatId, chatItems) in itemsByChatId {
      if chatItems.contains(where: {
        $0.messageId == trimmedTrackId || $0.track.trackId == trimmedTrackId
      }) {
        return chatId
      }
    }
    return nil
  }

  private func makeItem(from row: ChatListRow, fallbackChatId: String) -> ChatAudioQueueItem? {
    guard usesAudioMetadataVoiceLayout(row) else { return nil }
    guard let messageId = normalizedChatAudioId(row.messageId) else { return nil }

    let localMedia = row.localMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    let remoteMedia = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedMediaURL: String?
    if let localMedia, !localMedia.isEmpty {
      resolvedMediaURL = localMedia
    } else if let remoteMedia, !remoteMedia.isEmpty {
      resolvedMediaURL = remoteMedia
    } else {
      resolvedMediaURL = nil
    }
    guard let mediaURL = resolvedMediaURL else { return nil }

    let title = resolvedAudioVoiceTitle(row)
    let subtitle = resolvedAudioVoiceStaticDetail(row)
    let artwork = chatMediaImage(fromBase64: row.thumbnailBase64)
    let duration = max(0.0, row.duration ?? 0.0)
    let localURI = localMedia?.isEmpty == false ? localMedia : nil
    let remoteURI: String? = {
      guard let remoteMedia, !remoteMedia.isEmpty else { return nil }
      guard !(remoteMedia.hasPrefix("file://") || remoteMedia.hasPrefix("/")) else { return nil }
      return remoteMedia
    }()
    let resolvedChatId = normalizedChatAudioId(row.chatId) ?? fallbackChatId
    let track = NativeMusicPlayerTrack(
      trackId: messageId,
      videoId: nil,
      id: messageId,
      source: "chat-music",
      title: title,
      artist: subtitle,
      album: nil,
      duration: formatBubbleDuration(seconds: duration),
      durationSeconds: duration > 0.0 ? duration : nil,
      cover: nil,
      previewURL: remoteURI,
      streamURL: remoteURI,
      localURI: localURI,
      cachedAt: nil,
      playCount: 0,
      lastPlayedAt: nil,
      links: ["chat_id": resolvedChatId]
    )
    return ChatAudioQueueItem(
      chatId: resolvedChatId,
      messageId: messageId,
      mediaURL: mediaURL,
      mediaKey: row.mediaKey,
      fileName: row.fileName,
      title: title,
      subtitle: subtitle,
      artwork: artwork,
      duration: duration,
      track: track
    )
  }
}

struct VoiceBubblePlaybackSnapshot {
  let messageId: String?
  let chatId: String?
  let isPlaying: Bool
  let progress: CGFloat
  let duration: Double
  let playbackRate: Double
  let queueOrderMode: NativeMusicPlayerQueueOrderMode
  let isRepeatEnabled: Bool
  let isDownloading: Bool
  let downloadProgress: CGFloat?
  let title: String?
  let subtitle: String?
  let artwork: UIImage?
  let presentsGlobalPlayer: Bool

  static let empty = VoiceBubblePlaybackSnapshot(
    messageId: nil,
    chatId: nil,
    isPlaying: false,
    progress: 0.0,
    duration: 0.0,
    playbackRate: 1.0,
    queueOrderMode: .forward,
    isRepeatEnabled: false,
    isDownloading: false,
    downloadProgress: nil,
    title: nil,
    subtitle: nil,
    artwork: nil,
    presentsGlobalPlayer: false
  )
}

extension Notification.Name {
  static let voiceBubblePlaybackDidChange = Notification.Name(
    "ChatNative.voiceBubblePlaybackDidChange")
}

final class VoiceBubblePlaybackCoordinator: NSObject, AVAudioPlayerDelegate {
  static let shared = VoiceBubblePlaybackCoordinator()

  private weak var activeCell: VoicePlayableCell?
  private var activeMessageId: String?
  private var activeChatId: String?
  private var activeMediaURL: String?
  private var player: AVAudioPlayer?
  private var streamingPlayer: AVPlayer?
  private var streamingPlayerStatusObservation: NSKeyValueObservation?
  private var streamingTimeObserver: Any?
  private var streamingEndObserver: NSObjectProtocol?
  private var displayLink: CADisplayLink?
  private var playbackProgress: CGFloat = 0.0
  private var level: CGFloat = 0.0
  private var isPlaying = false
  private var playbackRate: Double = 1.0
  private var queueOrderMode: NativeMusicPlayerQueueOrderMode = .forward
  private var isRepeatEnabled = false
  private var activeDownloadTask: URLSessionDownloadTask?
  private var activeDownloadProgressObservation: NSKeyValueObservation?
  private var activeDownloadProgress: CGFloat?
  private var activeMediaKey: String?
  private var activeFileName: String?
  private var activeTitle: String?
  private var activeSubtitle: String?
  private var activeArtwork: UIImage?
  private var activeDuration: Double = 0.0
  private var presentsGlobalPlayer = false
  private var shouldResumeAfterInterruption = false
  private var didConfigureRemoteCommands = false
  private var lastNowPlayingSignature: String?
  private var randomizedQueueMessageIds: [String] = []
  private(set) var currentSnapshot = VoiceBubblePlaybackSnapshot.empty

  private override init() {
    super.init()
    configureSystemPlaybackIntegration()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    clearNowPlayingInfo()
    if Thread.isMainThread {
      UIApplication.shared.endReceivingRemoteControlEvents()
    } else {
      DispatchQueue.main.async {
        UIApplication.shared.endReceivingRemoteControlEvents()
      }
    }
    displayLink?.invalidate()
    player?.stop()
    cleanupStreamingPlayer()
  }

  private func configureSystemPlaybackIntegration() {
    configureRemoteCommandsIfNeeded()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleApplicationDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleApplicationWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    DispatchQueue.main.async {
      UIApplication.shared.beginReceivingRemoteControlEvents()
    }
  }

  private func configureRemoteCommandsIfNeeded() {
    guard !didConfigureRemoteCommands else { return }
    didConfigureRemoteCommands = true

    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.playCommand.addTarget { [weak self] _ in
      self?.handleRemoteCommandOnMain {
        self?.handleRemotePlayCommand() ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      self?.handleRemoteCommandOnMain {
        self?.handleRemotePauseCommand() ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.handleRemoteCommandOnMain {
        self?.handleRemoteTogglePlayPauseCommand() ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.stopCommand.addTarget { [weak self] _ in
      self?.handleRemoteCommandOnMain {
        self?.handleRemoteStopCommand() ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      return self?.handleRemoteCommandOnMain {
        self?.handleRemoteChangePlaybackPositionCommand(event) ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.nextTrackCommand.isEnabled = false
    commandCenter.previousTrackCommand.isEnabled = false
    commandCenter.seekForwardCommand.isEnabled = false
    commandCenter.seekBackwardCommand.isEnabled = false
    commandCenter.skipForwardCommand.isEnabled = false
    commandCenter.skipBackwardCommand.isEnabled = false
    syncRemoteCommandAvailability()
  }

  private func handleRemoteCommandOnMain(
    _ action: @escaping () -> MPRemoteCommandHandlerStatus
  ) -> MPRemoteCommandHandlerStatus {
    if Thread.isMainThread {
      return action()
    }
    var status: MPRemoteCommandHandlerStatus = .commandFailed
    DispatchQueue.main.sync {
      status = action()
    }
    return status
  }

  private func configurePlaybackSession() throws {
    let session = AVAudioSession.sharedInstance()
    do {
      // Keep voice/audio-file playback aligned with the native global player engine.
      // The broader option set was intermittently failing on cached remote MP3 playback.
      try session.setCategory(.playback, mode: .default)
    } catch {
      NSLog(
        "[ChatListView] voice audio session category failed error=%@",
        String(describing: error)
      )
      throw error
    }
    do {
      try session.setActive(true)
    } catch {
      NSLog(
        "[ChatListView] voice audio session activation failed error=%@",
        String(describing: error)
      )
      throw error
    }
  }

  private var hasActivePlaybackEngine: Bool {
    player != nil || streamingPlayer != nil
  }

  private func currentPlaybackDuration() -> Double {
    if let player {
      return max(player.duration, activeDuration)
    }
    if let seconds = streamingPlayer?.currentItem?.duration.seconds,
      seconds.isFinite,
      seconds > 0.0
    {
      return max(seconds, activeDuration)
    }
    return activeDuration
  }

  private func currentPlaybackTime() -> Double {
    if let player {
      return max(0.0, min(player.currentTime, currentPlaybackDuration()))
    }
    if let seconds = streamingPlayer?.currentTime().seconds,
      seconds.isFinite,
      seconds >= 0.0
    {
      return max(0.0, min(seconds, currentPlaybackDuration()))
    }
    return max(0.0, min(Double(playbackProgress) * currentPlaybackDuration(), currentPlaybackDuration()))
  }

  private func isPlaybackCurrentlyPlaying() -> Bool {
    if let player {
      return player.isPlaying
    }
    if let streamingPlayer {
      return streamingPlayer.timeControlStatus == .playing
    }
    return false
  }

  private func syncRemoteCommandAvailability() {
    let commandCenter = MPRemoteCommandCenter.shared()
    let hasPlayer = hasActivePlaybackEngine
    let canSeek = hasPlayer && currentPlaybackDuration() > 0.0

    commandCenter.togglePlayPauseCommand.isEnabled = hasPlayer
    commandCenter.playCommand.isEnabled = hasPlayer && !isPlaying
    commandCenter.pauseCommand.isEnabled = hasPlayer && isPlaying
    commandCenter.stopCommand.isEnabled = hasPlayer || activeDownloadTask != nil
    commandCenter.changePlaybackPositionCommand.isEnabled = canSeek
  }

  private func resolvedSystemPlaybackTitle() -> String {
    if let activeTitle {
      let trimmed = activeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    if let activeFileName {
      let trimmed = activeFileName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        let sanitizedTitle = (trimmed as NSString).lastPathComponent
        let displayTitle = (sanitizedTitle as NSString).deletingPathExtension
        return displayTitle.isEmpty ? sanitizedTitle : displayTitle
      }
    }
    return presentsGlobalPlayer ? "Audio" : "Voice message"
  }

  private func resolvedSystemPlaybackSubtitle() -> String? {
    if activeDownloadTask != nil {
      let progress = max(0.0, min(1.0, activeDownloadProgress ?? 0.0))
      let percent = Int((progress * 100.0).rounded())
      return percent > 0 ? "Downloading \(percent)%" : "Downloading"
    }
    if let activeSubtitle {
      let trimmed = activeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    return "Vibegram"
  }

  private func updateNowPlayingInfo(force: Bool = false) {
    guard hasActivePlaybackEngine, activeMessageId != nil else {
      clearNowPlayingInfo()
      return
    }

    let title = resolvedSystemPlaybackTitle()
    let subtitle = resolvedSystemPlaybackSubtitle()
    let duration = currentPlaybackDuration()
    let elapsed = currentPlaybackTime()
    let signature = [
      activeMessageId ?? "-",
      title,
      subtitle ?? "",
      String(Int((elapsed * 2.0).rounded())),
      String(Int((duration * 2.0).rounded())),
      isPlaying ? "1" : "0",
    ].joined(separator: "|")

    if !force && signature == lastNowPlayingSignature {
      return
    }

    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    nowPlayingInfo[MPMediaItemPropertyTitle] = title
    if let subtitle, !subtitle.isEmpty {
      nowPlayingInfo[MPMediaItemPropertyArtist] = subtitle
    } else {
      nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
    }
    if duration > 0.0 {
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
    } else {
      nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
    }
    if let activeArtwork {
      nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
        boundsSize: activeArtwork.size
      ) { _ in
        activeArtwork
      }
    } else {
      nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
    }
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
    nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    if #available(iOS 13.0, *) {
      MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
    lastNowPlayingSignature = signature
  }

  private func clearNowPlayingInfo() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    if #available(iOS 13.0, *) {
      MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    lastNowPlayingSignature = nil
  }

  private func syncSystemPlaybackState(forceNowPlaying: Bool) {
    syncRemoteCommandAvailability()
    if !hasActivePlaybackEngine {
      clearNowPlayingInfo()
      return
    }
    updateNowPlayingInfo(force: forceNowPlaying)
  }

  @discardableResult
  private func resumePlayback(updateCell: Bool = true) -> Bool {
    do {
      try configurePlaybackSession()
    } catch {
      NSLog(
        "[ChatListView] voice resume failed to activate audio session error=%@",
        String(describing: error)
      )
    }
    let accepted: Bool
    if let player {
      accepted = player.play()
      player.rate = Float(playbackRate)
    } else if let streamingPlayer {
      streamingPlayer.playImmediately(atRate: Float(playbackRate))
      accepted = true
    } else {
      return false
    }
    isPlaying = accepted
    ensureDisplayLink()
    if updateCell {
      let isDownloading = self.activeDownloadTask != nil
      activeCell?.applyVoiceDownloadState(
        needsDownload: isDownloading,
        isDownloading: isDownloading,
        progress: activeDownloadProgress
      )
      activeCell?.applyVoicePlaybackState(
        isPlaying: accepted,
        progress: playbackProgress,
        level: accepted ? max(level, 0.18) : 0.0
      )
    }
    publishSnapshot(forceNowPlaying: true)
    return accepted
  }

  private func pausePlayback(updateCell: Bool = true) {
    guard hasActivePlaybackEngine else { return }
    player?.pause()
    streamingPlayer?.pause()
    isPlaying = false
    level = 0.0
    if updateCell {
      let isDownloading = self.activeDownloadTask != nil
      activeCell?.applyVoiceDownloadState(
        needsDownload: isDownloading,
        isDownloading: isDownloading,
        progress: activeDownloadProgress
      )
      activeCell?.applyVoicePlaybackState(
        isPlaying: false,
        progress: playbackProgress,
        level: 0.0
      )
    }
    publishSnapshot(forceNowPlaying: true)
  }

  private func handleRemotePlayCommand() -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine else { return .noActionableNowPlayingItem }
    return resumePlayback(updateCell: true) ? .success : .commandFailed
  }

  private func handleRemotePauseCommand() -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine else { return .noActionableNowPlayingItem }
    pausePlayback(updateCell: true)
    return .success
  }

  private func handleRemoteTogglePlayPauseCommand() -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine else { return .noActionableNowPlayingItem }
    if isPlaybackCurrentlyPlaying() {
      pausePlayback(updateCell: true)
      return .success
    }
    return resumePlayback(updateCell: true) ? .success : .commandFailed
  }

  private func handleRemoteStopCommand() -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine || activeDownloadTask != nil else { return .noActionableNowPlayingItem }
    stopActivePlayback(resetProgress: true)
    return .success
  }

  private func handleRemoteChangePlaybackPositionCommand(
    _ event: MPChangePlaybackPositionCommandEvent
  ) -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine else { return .noActionableNowPlayingItem }
    let duration = currentPlaybackDuration()
    let targetTime = max(0.0, min(duration > 0.0 ? duration : event.positionTime, event.positionTime))
    if let player {
      player.currentTime = targetTime
      playbackProgress = duration > 0.0 ? CGFloat(targetTime / duration) : 0.0
      activeCell?.applyVoicePlaybackState(
        isPlaying: player.isPlaying,
        progress: playbackProgress,
        level: player.isPlaying ? max(level, 0.18) : 0.0
      )
    } else if let streamingPlayer {
      let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)
      streamingPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
      playbackProgress = duration > 0.0 ? CGFloat(targetTime / duration) : 0.0
      activeCell?.applyVoicePlaybackState(
        isPlaying: streamingPlayer.timeControlStatus == .playing,
        progress: playbackProgress,
        level: streamingPlayer.timeControlStatus == .playing ? max(level, 0.18) : 0.0
      )
    }
    publishSnapshot(forceNowPlaying: true)
    return .success
  }

  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard
      let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
    else {
      return
    }

    switch type {
    case .began:
      shouldResumeAfterInterruption = isPlaybackCurrentlyPlaying()
      if shouldResumeAfterInterruption {
        pausePlayback(updateCell: true)
      } else {
        publishSnapshot(forceNowPlaying: true)
      }
    case .ended:
      let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
      if shouldResumeAfterInterruption && options.contains(.shouldResume) {
        _ = resumePlayback(updateCell: true)
      } else {
        publishSnapshot(forceNowPlaying: true)
      }
      shouldResumeAfterInterruption = false
    @unknown default:
      break
    }
  }

  @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
    guard
      let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
    else {
      return
    }

    if reason == .oldDeviceUnavailable, isPlaybackCurrentlyPlaying() {
      pausePlayback(updateCell: true)
    }
  }

  @objc private func handleApplicationDidEnterBackground() {
    publishSnapshot(forceNowPlaying: true)
  }

  @objc private func handleApplicationWillEnterForeground() {
    publishSnapshot(forceNowPlaying: true)
  }

  func bind(
    cell: VoicePlayableCell,
    messageId: String?,
    mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil
  ) {
    guard let messageId, !messageId.isEmpty else {
      cell.applyVoiceDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      cell.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
      return
    }
    if activeMessageId == messageId {
      activeCell = cell
      let isDownloading = activeDownloadTask != nil
      cell.applyVoiceDownloadState(
        needsDownload: isDownloading,
        isDownloading: isDownloading,
        progress: activeDownloadProgress
      )
      cell.applyVoicePlaybackState(
        isPlaying: isPlaying,
        progress: playbackProgress,
        level: level
      )
      return
    }
    applyIdleState(
      cell: cell,
      messageId: messageId,
      mediaURL: mediaURL,
      mediaKey: mediaKey,
      fileName: fileName
    )
  }

  private func applyIdleState(
    cell: VoicePlayableCell,
    messageId: String?,
    mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil
  ) {
    let needsDownload =
      (messageId?.isEmpty == false)
      && mediaURLRequiresDownload(mediaURL, mediaKey: mediaKey, fileName: fileName)
    cell.applyVoiceDownloadState(
      needsDownload: needsDownload,
      isDownloading: false,
      progress: nil
    )
    cell.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
  }

  func unbind(cell: VoicePlayableCell) {
    if activeCell === cell {
      activeCell = nil
    }
  }

  func toggle(
    cell: VoicePlayableCell?,
    messageId: String?,
    chatId: String? = nil,
    mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil,
    title: String? = nil,
    subtitle: String? = nil,
    artwork: UIImage? = nil,
    duration: Double? = nil,
    presentsGlobalPlayer: Bool = false
  ) {
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
      if hasActivePlaybackEngine {
        if isPlaybackCurrentlyPlaying() {
          pausePlayback(updateCell: true)
          NSLog(
            "[ChatListView] voice pause messageId=%@ progress=%.3f", messageId, playbackProgress)
        } else {
          isPlaying = resumePlayback(updateCell: true)
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

    beginPlayback(
      cell: cell,
      messageId: messageId,
      chatId: chatId,
      mediaURL: mediaURL,
      mediaKey: mediaKey,
      fileName: fileName,
      title: title,
      subtitle: subtitle,
      artwork: artwork,
      duration: duration,
      presentsGlobalPlayer: presentsGlobalPlayer,
      suppressEmptySnapshotDuringTransition: false
    )
  }

  func toggleCurrentPlayback() {
    if hasActivePlaybackEngine {
      if isPlaybackCurrentlyPlaying() {
        pausePlayback(updateCell: true)
      } else {
        isPlaying = resumePlayback(updateCell: true)
      }
      return
    }

    if activeDownloadTask != nil {
      stopActivePlayback(resetProgress: true)
    }
  }

  func stopCurrentPlayback() {
    stopActivePlayback(resetProgress: true)
  }

  func playNextTrack() {
    guard let nextItem = adjacentQueueItem(step: 1, wraps: isRepeatEnabled) else { return }
    startQueueItem(nextItem, cell: nil)
  }

  func playPreviousTrack() {
    guard let previousItem = adjacentQueueItem(step: -1, wraps: isRepeatEnabled) else { return }
    startQueueItem(previousItem, cell: nil)
  }

  func selectQueuedTrack(_ trackId: String) {
    let trimmedTrackId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTrackId.isEmpty else { return }
    if activeMessageId == trimmedTrackId {
      if hasActivePlaybackEngine, !isPlaybackCurrentlyPlaying() {
        _ = resumePlayback(updateCell: true)
      }
      return
    }
    guard
      let item = ChatAudioQueueRegistry.shared.resolvedItem(
        trackId: trimmedTrackId,
        preferredChatId: activeChatId
      )
    else {
      return
    }
    if queueOrderMode == .random {
      syncRandomizedQueueMessageIds(anchorMessageId: item.messageId, regenerate: true)
    }
    startQueueItem(item, cell: nil)
  }

  func seek(toSeconds seconds: Double) {
    let clamped = max(0.0, seconds)
    let duration = currentPlaybackDuration()
    let targetTime = max(0.0, min(duration > 0.0 ? duration : clamped, clamped))
    if let player {
      player.currentTime = targetTime
      playbackProgress = duration > 0.0 ? CGFloat(targetTime / duration) : 0.0
      activeCell?.applyVoicePlaybackState(
        isPlaying: player.isPlaying,
        progress: playbackProgress,
        level: player.isPlaying ? max(level, 0.18) : 0.0
      )
    } else if let streamingPlayer {
      let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)
      streamingPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
      playbackProgress = duration > 0.0 ? CGFloat(targetTime / duration) : 0.0
      activeCell?.applyVoicePlaybackState(
        isPlaying: streamingPlayer.timeControlStatus == .playing,
        progress: playbackProgress,
        level: streamingPlayer.timeControlStatus == .playing ? max(level, 0.18) : 0.0
      )
    }
    publishSnapshot(forceNowPlaying: true)
  }

  func refreshCurrentSnapshotIfNeeded(forChatId chatId: String) {
    let trimmedChatId = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedChatId.isEmpty, activeChatId == trimmedChatId else { return }
    syncRandomizedQueueMessageIds(anchorMessageId: activeMessageId, regenerate: false)
    publishSnapshot(forceNowPlaying: true)
  }

  func currentPlaybackRate() -> Double {
    playbackRate
  }

  func setPlaybackRate(_ value: Double) {
    let nextRate = max(1.0, min(2.0, value))
    playbackRate = nextRate
    if let player {
      player.enableRate = true
      player.rate = Float(nextRate)
    }
    if let streamingPlayer, isPlaying {
      streamingPlayer.playImmediately(atRate: Float(nextRate))
    }
    publishSnapshot(forceNowPlaying: true)
  }

  func cyclePlaybackRate() {
    let rates: [Double] = [1.0, 1.5, 2.0]
    let index = rates.firstIndex(where: { abs($0 - playbackRate) < 0.05 }) ?? 0
    let nextRate = rates[(index + 1) % rates.count]
    setPlaybackRate(nextRate)
  }

  func currentQueueOrderMode() -> NativeMusicPlayerQueueOrderMode {
    queueOrderMode
  }

  func repeatEnabled() -> Bool {
    isRepeatEnabled
  }

  func toggleQueueOrderMode() {
    queueOrderMode = queueOrderMode.next()
    syncRandomizedQueueMessageIds(
      anchorMessageId: activeMessageId,
      regenerate: queueOrderMode == .random
    )
    publishSnapshot(forceNowPlaying: true)
  }

  func toggleRepeatEnabled() {
    isRepeatEnabled.toggle()
    publishSnapshot(forceNowPlaying: true)
  }

  func displayQueueTracks() -> [NativeMusicPlayerTrack] {
    orderedQueueItems().map(\.track)
  }

  private func orderedQueueItems() -> [ChatAudioQueueItem] {
    let baseItems = resolvedQueueItems()
    switch queueOrderMode {
    case .forward:
      return baseItems
    case .reverse:
      return Array(baseItems.reversed())
    case .random:
      syncRandomizedQueueMessageIds(anchorMessageId: activeMessageId, regenerate: false)
      let itemsByMessageId = Dictionary(uniqueKeysWithValues: baseItems.map { ($0.messageId, $0) })
      return randomizedQueueMessageIds.compactMap { itemsByMessageId[$0] }
    }
  }

  private func resolvedQueueItems() -> [ChatAudioQueueItem] {
    guard let activeMessageId else { return [] }
    guard
      let resolvedChatId = ChatAudioQueueRegistry.shared.resolvedChatId(
        for: activeMessageId,
        preferredChatId: activeChatId
      )
    else {
      return []
    }
    activeChatId = resolvedChatId
    return ChatAudioQueueRegistry.shared.items(for: resolvedChatId)
  }

  private func syncRandomizedQueueMessageIds(anchorMessageId: String?, regenerate: Bool) {
    let baseIds = resolvedQueueItems().map(\.messageId)
    let expected = Set(baseIds)
    let current = Set(randomizedQueueMessageIds)
    let needsRefresh =
      regenerate
      || randomizedQueueMessageIds.count != baseIds.count
      || current != expected

    guard needsRefresh else { return }

    var shuffledIds = baseIds
    if let anchorMessageId,
      let anchorIndex = shuffledIds.firstIndex(of: anchorMessageId)
    {
      shuffledIds.remove(at: anchorIndex)
      shuffledIds.shuffle()
      shuffledIds.insert(anchorMessageId, at: 0)
    } else {
      shuffledIds.shuffle()
    }
    randomizedQueueMessageIds = shuffledIds
  }

  private func startQueueItem(_ item: ChatAudioQueueItem, cell: VoicePlayableCell?) {
    beginPlayback(
      cell: cell,
      messageId: item.messageId,
      chatId: item.chatId,
      mediaURL: item.mediaURL,
      mediaKey: item.mediaKey,
      fileName: item.fileName,
      title: item.title,
      subtitle: item.subtitle,
      artwork: item.artwork,
      duration: item.duration,
      presentsGlobalPlayer: true,
      suppressEmptySnapshotDuringTransition: true,
      preserveQueueOrder: true
    )
  }

  private func adjacentQueueItem(step: Int, wraps: Bool) -> ChatAudioQueueItem? {
    guard step != 0 else { return nil }
    guard let activeMessageId else { return nil }
    let items = orderedQueueItems()
    guard !items.isEmpty else {
      return nil
    }
    guard let currentIndex = items.firstIndex(where: { $0.messageId == activeMessageId }) else {
      return nil
    }
    let nextIndex = currentIndex + step
    let nextItem: ChatAudioQueueItem?
    if items.indices.contains(nextIndex) {
      nextItem = items[nextIndex]
    } else if wraps {
      nextItem = step > 0 ? items.first : items.last
    } else {
      nextItem = nil
    }
    activeChatId = nextItem?.chatId
    return nextItem
  }

  private func beginPlayback(
    cell: VoicePlayableCell?,
    messageId: String?,
    chatId: String? = nil,
    mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil,
    title: String? = nil,
    subtitle: String? = nil,
    artwork: UIImage? = nil,
    duration: Double? = nil,
    presentsGlobalPlayer: Bool = false,
    suppressEmptySnapshotDuringTransition: Bool = false,
    preserveQueueOrder: Bool = false
  ) {
    stopActivePlayback(
      resetProgress: true,
      suppressSnapshot: suppressEmptySnapshotDuringTransition
    )
    activeChatId = presentsGlobalPlayer ? normalizedChatAudioId(chatId) : nil
    if presentsGlobalPlayer && queueOrderMode == .random && !preserveQueueOrder {
      syncRandomizedQueueMessageIds(anchorMessageId: messageId, regenerate: true)
    }
    activeMediaURL = mediaURL
    activeMediaKey = mediaKey
    activeFileName = fileName
    activeTitle = title
    activeSubtitle = subtitle
    activeArtwork = artwork
    activeDuration = max(0.0, duration ?? 0.0)
    self.presentsGlobalPlayer = presentsGlobalPlayer
    activeCell = cell

    guard let messageId, !messageId.isEmpty, let mediaURL, !mediaURL.isEmpty else {
      publishSnapshot(forceNowPlaying: true)
      return
    }

    guard let resolvedURL = resolveAudioURL(from: mediaURL) else {
      NSLog(
        "[ChatListView] voice resolveAudioURL failed messageId=%@ raw=%@",
        messageId,
        shortMediaURL(mediaURL)
      )
      publishSnapshot(forceNowPlaying: true)
      return
    }
    NSLog(
      "[ChatListView] voice resolved URL messageId=%@ isFile=%@ path=%@",
      messageId,
      resolvedURL.isFileURL.description,
      resolvedURL.path
    )

    if !resolvedURL.isFileURL {
      playRemoteURL(
        resolvedURL,
        messageId: messageId,
        cell: cell,
        mediaKey: mediaKey,
        fileName: fileName
      )
      return
    }

    playLocalURL(resolvedURL, messageId: messageId, cell: cell)
  }

  private func advanceToNextQueuedTrackIfAvailable() -> Bool {
    guard let nextItem = adjacentQueueItem(step: 1, wraps: isRepeatEnabled) else { return false }
    startQueueItem(nextItem, cell: nil)
    return true
  }

  private func playRemoteURL(
    _ url: URL,
    messageId: String,
    cell: VoicePlayableCell?,
    mediaKey: String?,
    fileName: String?
  ) {
    let localURL = cachedRemoteVoiceURL(for: url, fileName: fileName)

    if FileManager.default.fileExists(atPath: localURL.path) {
      playLocalURL(localURL, messageId: messageId, cell: cell)
      return
    }

    // For all remote files: start streaming immediately for rapid first-byte playback.
    // Download runs concurrently in background:
    //   - no mediaKey: caches a clean copy for future plays.
    //   - mediaKey (encrypted): download+decrypt gives a seekable local file; if the
    //     remote URL actually serves plaintext audio the stream plays fine, otherwise
    //     streaming fails gracefully and finishDownload auto-plays the decrypted file.
    let trimmedMediaKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    startStreamingRemotePlayback(url, messageId: messageId, cell: cell)
    beginRemoteDownloadTask(
      url,
      messageId: messageId,
      mediaKey: trimmedMediaKey.isEmpty ? nil : mediaKey,
      fileName: fileName,
      autoPlayWhenFinished: !trimmedMediaKey.isEmpty
    )
  }

  private func startStreamingRemotePlayback(
    _ url: URL,
    messageId: String,
    cell: VoicePlayableCell?
  ) {
    cleanupStreamingPlayer()
    activeMessageId = messageId
    activeMediaURL = url.absoluteString
    activeCell = cell
    activeDownloadProgress = nil
    playbackProgress = 0.0
    level = 0.0
    isPlaying = false

    do {
      try configurePlaybackSession()
    } catch {
      NSLog(
        "[ChatListView] voice stream session failed messageId=%@ error=%@",
        messageId,
        String(describing: error)
      )
    }

    let item = AVPlayerItem(url: url)
    let nextPlayer = AVPlayer(playerItem: item)
    // Play as soon as the first chunk is buffered rather than waiting to minimise stalling.
    // Gives near-instant audio start on reliable connections; may stall briefly on slow links
    // but the user hears sound much sooner than with the default true.
    nextPlayer.automaticallyWaitsToMinimizeStalling = false
    streamingPlayer = nextPlayer

    streamingPlayerStatusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self] item, _ in
      guard let self else { return }
      DispatchQueue.main.async {
        switch item.status {
        case .readyToPlay:
          if item.duration.seconds.isFinite, item.duration.seconds > 0.0 {
            self.activeDuration = max(self.activeDuration, item.duration.seconds)
          }
          _ = self.resumePlayback(updateCell: true)
        case .failed:
          NSLog(
            "[ChatListView] voice stream failed messageId=%@ error=%@",
            messageId,
            String(describing: item.error)
          )
          if self.activeDownloadTask != nil {
            // A background download is already running (encrypted/fallback path).
            // Just tear down the non-working AVPlayer; finishDownload will play
            // the decrypted local file once the download completes.
            NSLog(
              "[ChatListView] voice stream failed – keeping download alive messageId=%@",
              messageId
            )
            self.cleanupStreamingPlayer()
            self.isPlaying = false
            self.level = 0.0
            self.activeCell?.applyVoiceDownloadState(
              needsDownload: true, isDownloading: true,
              progress: self.activeDownloadProgress
            )
            self.activeCell?.applyVoicePlaybackState(
              isPlaying: false, progress: 0.0, level: 0.0
            )
            self.publishSnapshot(forceNowPlaying: true)
          } else {
            self.stopActivePlayback(resetProgress: true)
          }
        default:
          break
        }
      }
    }

    streamingTimeObserver = nextPlayer.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      let duration = self.currentPlaybackDuration()
      let currentTime = self.currentPlaybackTime()
      self.playbackProgress = duration > 0.0 ? CGFloat(currentTime / duration) : 0.0
      self.level = self.isPlaybackCurrentlyPlaying() ? 0.18 : 0.0
      self.isPlaying = self.isPlaybackCurrentlyPlaying()
      let isDownloading = self.activeDownloadTask != nil
      self.activeCell?.applyVoiceDownloadState(
        needsDownload: isDownloading,
        isDownloading: isDownloading,
        progress: self.activeDownloadProgress
      )
      self.activeCell?.applyVoicePlaybackState(
        isPlaying: self.isPlaying,
        progress: self.playbackProgress,
        level: self.level
      )
      self.publishSnapshot()
    }

    streamingEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if !self.advanceToNextQueuedTrackIfAvailable() {
        self.stopActivePlayback(resetProgress: true)
      }
    }

    // Show a buffering/loading indicator while AVPlayer is connecting.
    // The time observer will clear this once the first chunk starts playing.
    cell?.applyVoiceDownloadState(needsDownload: true, isDownloading: true, progress: nil)
    cell?.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
    ensureDisplayLink()
    publishSnapshot(forceNowPlaying: true)
  }

  private func beginRemoteDownloadTask(
    _ url: URL,
    messageId: String,
    mediaKey: String?,
    fileName: String?,
    autoPlayWhenFinished: Bool
  ) {
    let localURL = cachedRemoteVoiceURL(for: url, fileName: fileName)
    let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
    // Note: progress observation is set up below after task is assigned to activeDownloadTask.
      guard let self, let tempURL = tempURL, error == nil else {
        NSLog(
          "[ChatListView] voice download failed url=%@ error=%@", url.absoluteString,
          String(describing: error))
        DispatchQueue.main.async {
          guard self?.activeMessageId == messageId else { return }
          if self?.hasActivePlaybackEngine == true {
            self?.activeDownloadTask = nil
            self?.activeDownloadProgress = nil
            self?.publishSnapshot(forceNowPlaying: true)
          } else {
            self?.stopActivePlayback(resetProgress: true)
          }
        }
        return
      }

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
            guard self.activeMessageId == messageId else { return }
            if self.hasActivePlaybackEngine {
              self.activeDownloadTask = nil
              self.activeDownloadProgress = nil
              self.publishSnapshot(forceNowPlaying: true)
            } else {
              self.stopActivePlayback(resetProgress: true)
            }
          }
          return
        }
        let lowerCT = contentType.lowercased()
        if lowerCT.contains("text/html") || lowerCT.contains("application/json") {
          NSLog(
            "[ChatListView] voice download got non-audio content messageId=%@ contentType=%@",
            messageId,
            contentType
          )
          DispatchQueue.main.async {
            guard self.activeMessageId == messageId else { return }
            if self.hasActivePlaybackEngine {
              self.activeDownloadTask = nil
              self.activeDownloadProgress = nil
              self.publishSnapshot(forceNowPlaying: true)
            } else {
              self.stopActivePlayback(resetProgress: true)
            }
          }
          return
        }
      }

      let fileSize =
        (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
      if fileSize < 100 {
        NSLog(
          "[ChatListView] voice download too small messageId=%@ bytes=%lld",
          messageId,
          fileSize
        )
        DispatchQueue.main.async {
          guard self.activeMessageId == messageId else { return }
          if self.hasActivePlaybackEngine {
            self.activeDownloadTask = nil
            self.activeDownloadProgress = nil
            self.publishSnapshot(forceNowPlaying: true)
          } else {
            self.stopActivePlayback(resetProgress: true)
          }
        }
        return
      }

      do {
        let destinationURL: URL
        if let mediaKey, !mediaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let encryptedData = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
          guard let decryptedData = chatMediaDecryptedDataIfNeeded(encryptedData, mediaKey: mediaKey)
          else {
            throw NSError(
              domain: "VoiceBubblePlaybackCoordinator",
              code: 31,
              userInfo: [NSLocalizedDescriptionKey: "voice decrypt failed"])
          }
          try decryptedData.write(to: localURL, options: [.atomic])
          destinationURL = localURL
          try? FileManager.default.removeItem(at: tempURL)
        } else {
          if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
          }
          try FileManager.default.moveItem(at: tempURL, to: localURL)
          destinationURL = localURL
        }
        DispatchQueue.main.async {
          guard self.activeMessageId == messageId else { return }
          self.finishDownload(
            messageId: messageId,
            localMediaURL: destinationURL.absoluteString,
            autoPlayWhenFinished: autoPlayWhenFinished
          )
        }
      } catch {
        NSLog("[ChatListView] voice move failed error=%@", String(describing: error))
        DispatchQueue.main.async {
          guard self.activeMessageId == messageId else { return }
          if self.hasActivePlaybackEngine {
            self.activeDownloadTask = nil
            self.activeDownloadProgress = nil
            self.publishSnapshot(forceNowPlaying: true)
          } else {
            self.stopActivePlayback(resetProgress: true)
          }
        }
      }
    }
    activeDownloadTask = task
    // Track download progress so the cell and Now Playing show a percentage while waiting.
    // Track download progress and always push it to the cell while a download is active.
    activeDownloadProgressObservation = task.progress.observe(
      \.fractionCompleted,
      options: [.initial, .new]
    ) { [weak self] progress, _ in
      guard let self else { return }
      let value = max(0.03, min(1.0, progress.fractionCompleted))
      DispatchQueue.main.async {
        guard self.activeMessageId == messageId else { return }
        let previous = self.activeDownloadProgress ?? 0.0
        guard abs(Double(previous) - value) >= 0.01 else { return }
        self.activeDownloadProgress = CGFloat(value)
        // Always push download progress to the cell while a download task is active.
        self.activeCell?.applyVoiceDownloadState(
          needsDownload: true, isDownloading: true, progress: CGFloat(value))
        self.publishSnapshot()
      }
    }
    task.resume()
  }

  private func playLocalURL(_ url: URL, messageId: String, cell: VoicePlayableCell?) {
    do {
      try configurePlaybackSession()
      let nextPlayer = try AVAudioPlayer(contentsOf: url)
      nextPlayer.delegate = self
      nextPlayer.prepareToPlay()
      nextPlayer.enableRate = true
      nextPlayer.rate = Float(playbackRate)
      nextPlayer.isMeteringEnabled = true
      player = nextPlayer
      activeMessageId = messageId
      activeMediaURL = url.absoluteString
      activeCell = cell
      activeDownloadProgress = nil
      activeDownloadTask = nil
      playbackProgress = 0.0
      level = 0.0
      activeDuration = max(activeDuration, nextPlayer.duration)
      _ = NativeMusicPlayerStore.shared.updateLocalURI(trackId: messageId, localURI: url.absoluteString)
      isPlaying = nextPlayer.play()
      NSLog(
        "[ChatListView] voice play start messageId=%@ accepted=%@ duration=%.2f",
        messageId,
        isPlaying.description,
        nextPlayer.duration
      )
      ensureDisplayLink()
      cell?.applyVoiceDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      cell?.applyVoicePlaybackState(isPlaying: isPlaying, progress: 0.0, level: 0.0)
      publishSnapshot(forceNowPlaying: true)
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
    if !advanceToNextQueuedTrackIfAvailable() {
      stopActivePlayback(resetProgress: true)
    }
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    NSLog("[ChatListView] voice decode error=%@", String(describing: error))
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
    if let activeDownloadTask, player == nil, streamingPlayer == nil {
      let progress = activeDownloadTask.progress
      if progress.totalUnitCount > 0 {
        activeDownloadProgress = max(0.0, min(1.0, CGFloat(progress.fractionCompleted)))
      } else {
        activeDownloadProgress = nil
      }
      activeCell?.applyVoiceDownloadState(
        needsDownload: true,
        isDownloading: true,
        progress: activeDownloadProgress
      )
      activeCell?.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
      publishSnapshot()
      return
    }
    if let streamingPlayer {
      let duration = currentPlaybackDuration()
      let currentTime = currentPlaybackTime()
      playbackProgress = duration > 0.0 ? CGFloat(currentTime / duration) : 0.0
      playbackProgress = max(0.0, min(1.0, playbackProgress))
      level = streamingPlayer.timeControlStatus == .playing ? 0.18 : 0.0
      isPlaying = streamingPlayer.timeControlStatus == .playing
      let isDownloading = activeDownloadTask != nil
      activeCell?.applyVoiceDownloadState(
        needsDownload: isDownloading,
        isDownloading: isDownloading,
        progress: activeDownloadProgress
      )
      activeCell?.applyVoicePlaybackState(
        isPlaying: isPlaying,
        progress: playbackProgress,
        level: level
      )
      if streamingPlayer.currentItem?.status == .failed {
        stopActivePlayback(resetProgress: true)
        return
      }
      if !isPlaying && playbackProgress >= 0.999 {
        if !advanceToNextQueuedTrackIfAvailable() {
          stopActivePlayback(resetProgress: true)
        }
        return
      }
      publishSnapshot()
      return
    }
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
    isPlaying = player.isPlaying
    if !player.isPlaying && playbackProgress >= 0.999 {
      if !advanceToNextQueuedTrackIfAvailable() {
        stopActivePlayback(resetProgress: true)
      }
      return
    }
    activeCell?.applyVoicePlaybackState(
      isPlaying: player.isPlaying, progress: playbackProgress, level: level
    )
    publishSnapshot()
  }

  private func finishDownload(
    messageId: String,
    localMediaURL: String,
    autoPlayWhenFinished: Bool = true
  ) {
    activeDownloadTask = nil
    activeDownloadProgressObservation?.invalidate()
    activeDownloadProgressObservation = nil
    activeDownloadProgress = nil
    _ = NativeMusicPlayerStore.shared.updateLocalURI(trackId: messageId, localURI: localMediaURL)
    guard activeMessageId == messageId else { return }
    // If a streaming player is alive and playing (or buffering), the user already
    // has audio; just cache the decrypted file without interrupting playback.
    if let sp = streamingPlayer,
      sp.timeControlStatus == .playing || sp.timeControlStatus == .waitingToPlayAtSpecifiedRate
    {
      publishSnapshot(forceNowPlaying: true)
      return
    }
    // Streaming is gone or stalled – fall through and play the local file.
    if streamingPlayer != nil {
      cleanupStreamingPlayer()
    }
    let localURL: URL
    if let parsedURL = URL(string: localMediaURL), parsedURL.isFileURL {
      localURL = parsedURL
    } else {
      localURL = URL(fileURLWithPath: localMediaURL)
    }
    playLocalURL(localURL, messageId: messageId, cell: activeCell)
  }

  private func stopActivePlayback(resetProgress: Bool, suppressSnapshot: Bool = false) {
    let previousCell = activeCell
    let previousMessageId = activeMessageId
    let previousMediaURL = activeMediaURL
    shouldResumeAfterInterruption = false
    activeDownloadTask?.cancel()
    activeDownloadTask = nil
    activeDownloadProgressObservation?.invalidate()
    activeDownloadProgressObservation = nil
    activeDownloadProgress = nil
    player?.stop()
    player = nil
    cleanupStreamingPlayer()
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    isPlaying = false
    displayLink?.invalidate()
    displayLink = nil
    if resetProgress {
      playbackProgress = 0.0
      level = 0.0
    }
    if let previousCell {
      applyIdleState(
        cell: previousCell,
        messageId: previousMessageId,
        mediaURL: previousMediaURL,
        mediaKey: activeMediaKey,
        fileName: activeFileName
      )
    }
    activeMessageId = nil
    activeChatId = nil
    activeMediaURL = nil
    activeMediaKey = nil
    activeFileName = nil
    activeTitle = nil
    activeSubtitle = nil
    activeArtwork = nil
    activeDuration = 0.0
    presentsGlobalPlayer = false
    activeCell = nil
    if !suppressSnapshot {
      publishSnapshot(forceNowPlaying: true)
    }
  }

  private func cleanupStreamingPlayer() {
    if let timeObserver = streamingTimeObserver {
      streamingPlayer?.removeTimeObserver(timeObserver)
      streamingTimeObserver = nil
    }
    if let streamingEndObserver {
      NotificationCenter.default.removeObserver(streamingEndObserver)
      self.streamingEndObserver = nil
    }
    streamingPlayerStatusObservation?.invalidate()
    streamingPlayerStatusObservation = nil
    streamingPlayer?.pause()
    streamingPlayer = nil
  }

  private func mediaURLRequiresDownload(
    _ mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil
  ) -> Bool {
    guard
      let mediaURL,
      let resolvedURL = resolveAudioURL(from: mediaURL)
    else {
      return false
    }
    guard !resolvedURL.isFileURL else {
      return false
    }
    return !FileManager.default.fileExists(
      atPath: cachedRemoteVoiceURL(for: resolvedURL, fileName: fileName).path)
  }

  private func cachedRemoteVoiceURL(for remoteURL: URL, fileName: String?) -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let cacheDir = caches.appendingPathComponent("voice-cache", isDirectory: true)
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let preferredExt = (fileName as NSString?)?.pathExtension.lowercased()
    let remoteExt = remoteURL.pathExtension.lowercased()
    let ext =
      !(preferredExt?.isEmpty ?? true) ? preferredExt!
      : remoteExt == "enc" || remoteExt.isEmpty ? "m4a" : remoteExt
    let filename = String(format: "%016llx", remoteURL.absoluteString.hashValue) + "." + ext
    let preferred = cacheDir.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: preferred.path) {
      return preferred
    }
    let legacy = cacheDir.appendingPathComponent(String(format: "%016llx", remoteURL.absoluteString.hashValue) + ".m4a")
    return FileManager.default.fileExists(atPath: legacy.path) ? legacy : preferred
  }

  private func importedLocalAudioURL(for sourceURL: URL) -> URL? {
    let normalizedURL = sourceURL.standardizedFileURL
    let normalizedPath = normalizedURL.path
    let homePath = NSHomeDirectory()
    if normalizedPath == homePath || normalizedPath.hasPrefix(homePath + "/") {
      return normalizedURL
    }

    let fileManager = FileManager.default
    let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let importDir = caches.appendingPathComponent("voice-local-imports", isDirectory: true)
    try? fileManager.createDirectory(at: importDir, withIntermediateDirectories: true)

    let sourceName = normalizedURL.deletingPathExtension().lastPathComponent
    let safeBase =
      (sourceName.isEmpty ? "audio" : sourceName)
      .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    let ext = normalizedURL.pathExtension.isEmpty ? "m4a" : normalizedURL.pathExtension
    let hashComponent = String(
      format: "%016llx", UInt64(bitPattern: Int64(normalizedURL.absoluteString.hashValue)))
    let destinationURL = importDir
      .appendingPathComponent("\(safeBase)-\(hashComponent)", isDirectory: false)
      .appendingPathExtension(ext)

    if fileManager.fileExists(atPath: destinationURL.path) {
      return destinationURL
    }

    let didAccessScopedResource = normalizedURL.startAccessingSecurityScopedResource()
    defer {
      if didAccessScopedResource {
        normalizedURL.stopAccessingSecurityScopedResource()
      }
    }

    var coordinationError: NSError?
    var copyError: Error?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(readingItemAt: normalizedURL, options: [], error: &coordinationError) {
      readableURL in
      do {
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        do {
          try fileManager.copyItem(at: readableURL, to: destinationURL)
        } catch {
          let data = try Data(contentsOf: readableURL, options: [.mappedIfSafe])
          try data.write(to: destinationURL, options: [.atomic])
        }
      } catch {
        copyError = error
      }
    }

    if let copyError {
      NSLog(
        "[ChatListView] voice local import failed source=%@ error=%@",
        normalizedURL.path,
        copyError.localizedDescription
      )
    } else if let coordinationError {
      NSLog(
        "[ChatListView] voice local import coordination failed source=%@ error=%@",
        normalizedURL.path,
        coordinationError.localizedDescription
      )
    }

    return fileManager.fileExists(atPath: destinationURL.path) ? destinationURL : normalizedURL
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
          return importedLocalAudioURL(for: URL(fileURLWithPath: patchedPath))
        }
      }
    }

    if let url = URL(string: trimmed), url.isFileURL {
      return importedLocalAudioURL(for: url)
    }
    if trimmed.hasPrefix("/") {
      return importedLocalAudioURL(for: URL(fileURLWithPath: trimmed))
    }
    if let decoded = trimmed.removingPercentEncoding, decoded.hasPrefix("/") {
      return importedLocalAudioURL(for: URL(fileURLWithPath: decoded))
    }
    if let url = URL(string: trimmed), let scheme = url.scheme,
      scheme == "http" || scheme == "https"
    {
      let cachedURL = cachedRemoteVoiceURL(for: url, fileName: activeFileName)
      if FileManager.default.fileExists(atPath: cachedURL.path) {
        return cachedURL
      }
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

  private func publishSnapshot(forceNowPlaying: Bool = false) {
    let snapshot: VoiceBubblePlaybackSnapshot
    if let activeMessageId {
      let duration = currentPlaybackDuration()
      snapshot = VoiceBubblePlaybackSnapshot(
        messageId: activeMessageId,
        chatId: activeChatId,
        isPlaying: isPlaying,
        progress: playbackProgress,
        duration: duration,
        playbackRate: playbackRate,
        queueOrderMode: queueOrderMode,
        isRepeatEnabled: isRepeatEnabled,
        isDownloading: activeDownloadTask != nil,
        downloadProgress: activeDownloadProgress,
        title: activeTitle,
        subtitle: activeSubtitle,
        artwork: activeArtwork,
        presentsGlobalPlayer: presentsGlobalPlayer
      )
    } else {
      snapshot = .empty
    }
    currentSnapshot = snapshot
    syncSystemPlaybackState(forceNowPlaying: forceNowPlaying)
    NotificationCenter.default.post(name: .voiceBubblePlaybackDidChange, object: self)
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
  private let richTextView = BubbleRichTextView()
  private let replyPreviewView = BubbleReplyPreviewView()
  private let linkPreviewView = BubbleLinkPreviewView()
  private let mediaContainerView = UIView()
  private let mediaPlaceholderBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let mediaPlaceholderTintView = UIView()
  private let mediaImageView = UIImageView()
  private let mediaVideoPlayerHostView = UIView()
  private let mediaStickerAnimationView = LottieAnimationView()
  private let mediaPrimaryIconView = UIImageView()
  private let mediaBorderLayer = CAShapeLayer()
  private let mediaVoiceButtonView = VoicePlayProgressView()
  private let mediaTitleLabel = UILabel()
  private let mediaDetailLabel = UILabel()
  private let mediaWaveformView = VoiceWaveformView()
  private let mediaVideoInfoBadgeView = UIView()
  private let mediaVideoTimeIconView = UIImageView()
  private let mediaVideoAudioIconView = UIImageView()
  private let mediaDurationBadge = UILabel()
  private let mediaProgressOverlayView = UIView()
  private let mediaProgressRingView = BubbleUploadProgressView()
  private let mediaProgressSpinner = UIActivityIndicatorView(style: .medium)
  private let mediaProgressSizeLabel = UILabel()
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
  private let pendingStatusView = ChatPendingStatusView()
  private let retryButton = UIButton(type: .system)
  private let dayLabel = UILabel()
  private let reactionPillView = UIView()
  private let reactionLabel = UILabel()
  private var appearance = ChatListAppearance.fallback
  internal(set) var row: ChatListRow?
  private var isGhostHidden = false
  private var isContextMenuExtracted = false
  private var isContextMenuHeld = false
  private var savedBubbleHiddenBeforeExtraction = false
  private var savedTailHiddenBeforeExtraction = false
  private var savedReactionHiddenBeforeExtraction = false
  private var savedMessageAlphaBeforeExtraction: CGFloat = 1.0
  private var savedRichTextAlphaBeforeExtraction: CGFloat = 1.0
  private var savedReplyPreviewAlphaBeforeExtraction: CGFloat = 1.0
  private var savedLinkPreviewAlphaBeforeExtraction: CGFloat = 1.0
  private var savedInlineAttachmentAlphaBeforeExtraction: CGFloat = 1.0
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
  private let mediaVideoPlayerLayer = AVPlayerLayer()
  private var mediaVideoPlayer: AVPlayer?
  private var mediaVideoLoopObserver: NSObjectProtocol?
  private var mediaVideoStatusObserver: NSKeyValueObservation?
  private var mediaVideoTimeObserver: Any?
  private var mediaVideoPlayerURLKey: String?
  private var mediaVideoPlaybackActive = false
  private var mediaVideoReady = false
  private var mediaVideoIsMuted = true
  private var mediaVideoHasAudio = false
  private var mediaVideoCurrentTime: Double = 0.0
  private var mediaVideoTotalDuration: Double?
  private var mediaNeedsDownload = false
  private var mediaIsDownloading = false
  private var mediaDownloadProgress: Double?
  private var skipRemoteMediaLoad = false
  private var preferredLocalMediaURLOverride: String?
  private weak var wallpaperCoordinateView: UIView?
  private var wallpaperBackdropSnapshot: CGImage?
  private var wallpaperBackdropContainerSize: CGSize = .zero
  private var currentStickerAnimationKey: String?
  private let fullBleedMaskLayer = CAShapeLayer()
  private var lastReportedMediaSizeKey: String?
  private var lastReactionDebugSignature: String?
  private var renderedStatusKey: String?
  var resolveDisplayStatus: ((ChatListRow) -> String?)?
  var onVoiceBubbleTap: ((ChatListRow) -> Void)?
  var onVoiceUploadCancelTap: ((ChatListRow) -> Void)?
  var onInlineAttachmentTap: ((ChatListRow) -> Void)?
  var onMediaNaturalSizeResolved: ((String?, String, CGSize) -> Void)?
  var onRetryMessageTap: ((ChatListRow) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)

    clipsToBounds = false
    contentView.clipsToBounds = false

    contentView.addSubview(bubbleView)
    contentView.addSubview(tailView)

    contentView.addSubview(messageLabel)
    contentView.addSubview(richTextView)
    contentView.addSubview(replyPreviewView)
    contentView.addSubview(linkPreviewView)
    contentView.addSubview(mediaContainerView)
    mediaContainerView.addSubview(mediaPlaceholderBlurView)
    mediaPlaceholderBlurView.contentView.addSubview(mediaPlaceholderTintView)
    mediaContainerView.addSubview(mediaImageView)
    mediaContainerView.addSubview(mediaVideoPlayerHostView)
    mediaContainerView.addSubview(mediaStickerAnimationView)
    mediaContainerView.addSubview(mediaPrimaryIconView)
    mediaContainerView.addSubview(mediaVoiceButtonView)
    mediaContainerView.addSubview(mediaTitleLabel)
    mediaContainerView.addSubview(mediaDetailLabel)
    mediaContainerView.addSubview(mediaWaveformView)
    mediaContainerView.addSubview(mediaVideoInfoBadgeView)
    mediaVideoInfoBadgeView.addSubview(mediaVideoTimeIconView)
    mediaVideoInfoBadgeView.addSubview(mediaDurationBadge)
    mediaVideoInfoBadgeView.addSubview(mediaVideoAudioIconView)
    mediaContainerView.addSubview(mediaProgressOverlayView)
    mediaProgressOverlayView.addSubview(mediaProgressRingView)
    mediaProgressOverlayView.addSubview(mediaProgressSpinner)
    mediaProgressOverlayView.addSubview(mediaProgressSizeLabel)
    mediaBorderLayer.fillColor = UIColor.clear.cgColor
    mediaBorderLayer.isHidden = true
    mediaContainerView.layer.addSublayer(mediaBorderLayer)
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
    metaContainerView.addSubview(pendingStatusView)
    contentView.addSubview(dayLabel)
    contentView.addSubview(retryButton)

    contentView.addSubview(reactionPillView)
    reactionPillView.addSubview(reactionLabel)

    messageLabel.numberOfLines = 0
    messageLabel.font = bubbleMessageFont
    messageLabel.textColor = .white

    mediaContainerView.clipsToBounds = true
    mediaContainerView.layer.cornerCurve = .continuous
    mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.16)

    mediaPlaceholderBlurView.clipsToBounds = true
    mediaPlaceholderBlurView.isHidden = true
    mediaPlaceholderTintView.backgroundColor = UIColor(white: 0.0, alpha: 0.16)

    mediaImageView.backgroundColor = .clear
    mediaImageView.contentMode = .scaleAspectFill
    mediaImageView.clipsToBounds = true

    mediaVideoPlayerHostView.backgroundColor = .clear
    mediaVideoPlayerHostView.isHidden = true
    mediaVideoPlayerLayer.videoGravity = .resizeAspectFill
    mediaVideoPlayerLayer.opacity = 0.0
    mediaVideoPlayerHostView.layer.addSublayer(mediaVideoPlayerLayer)

    mediaStickerAnimationView.backgroundColor = .clear
    mediaStickerAnimationView.contentMode = .scaleAspectFit
    mediaStickerAnimationView.loopMode = .loop
    mediaStickerAnimationView.backgroundBehavior = .pauseAndRestore
    mediaStickerAnimationView.isUserInteractionEnabled = false
    mediaStickerAnimationView.isHidden = true

    mediaPrimaryIconView.tintColor = .white
    mediaPrimaryIconView.contentMode = .center
    mediaPrimaryIconView.clipsToBounds = true
    mediaPrimaryIconView.backgroundColor = UIColor(white: 0.0, alpha: 0.28)
    mediaPrimaryIconView.layer.cornerCurve = .circular

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

    mediaVideoInfoBadgeView.backgroundColor = UIColor(white: 0.0, alpha: 0.56)
    mediaVideoInfoBadgeView.layer.cornerRadius = 11.0
    mediaVideoInfoBadgeView.layer.cornerCurve = .continuous
    mediaVideoInfoBadgeView.clipsToBounds = true
    mediaVideoInfoBadgeView.isHidden = true

    let mediaBadgeSymbolConfig = UIImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
    mediaVideoTimeIconView.image = UIImage(systemName: "timer", withConfiguration: mediaBadgeSymbolConfig)
    mediaVideoTimeIconView.tintColor = UIColor.white.withAlphaComponent(0.88)
    mediaVideoTimeIconView.contentMode = .scaleAspectFit
    mediaVideoTimeIconView.isHidden = true

    mediaVideoAudioIconView.tintColor = UIColor.white.withAlphaComponent(0.88)
    mediaVideoAudioIconView.contentMode = .scaleAspectFit
    mediaVideoAudioIconView.isHidden = true
    mediaVideoAudioIconView.isUserInteractionEnabled = true
    let audioTap = UITapGestureRecognizer(target: self, action: #selector(handleInlineVideoMuteTap))
    mediaVideoAudioIconView.addGestureRecognizer(audioTap)

    mediaDurationBadge.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    mediaDurationBadge.textColor = .white
    mediaDurationBadge.backgroundColor = .clear
    mediaDurationBadge.textAlignment = .center
    mediaDurationBadge.clipsToBounds = false

    mediaProgressOverlayView.backgroundColor = .clear
    mediaProgressOverlayView.clipsToBounds = false

    mediaProgressRingView.isUserInteractionEnabled = true
    let ringCancelTap = UITapGestureRecognizer(
      target: self, action: #selector(handleMediaProgressCancelTap))
    mediaProgressRingView.addGestureRecognizer(ringCancelTap)

    mediaProgressSpinner.color = UIColor(white: 1.0, alpha: 0.85)
    mediaProgressSpinner.hidesWhenStopped = true
    mediaProgressSpinner.isHidden = true

    mediaProgressSizeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    mediaProgressSizeLabel.textColor = .white
    mediaProgressSizeLabel.backgroundColor = UIColor(white: 0.0, alpha: 0.50)
    mediaProgressSizeLabel.textAlignment = .center
    mediaProgressSizeLabel.clipsToBounds = true
    mediaProgressSizeLabel.layer.cornerRadius = 10.0
    mediaProgressSizeLabel.layer.cornerCurve = .continuous
    mediaProgressSizeLabel.isHidden = true
    mediaProgressSizeLabel.isUserInteractionEnabled = true
    let labelCancelTap = UITapGestureRecognizer(
      target: self, action: #selector(handleMediaProgressCancelTap))
    mediaProgressSizeLabel.addGestureRecognizer(labelCancelTap)

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
    pendingStatusView.isHidden = true
    statusLabel.font = bubbleMetaStatusFont
    statusLabel.textAlignment = .center
    retryButton.isHidden = true
    retryButton.tintColor = UIColor(red: 1.0, green: 0.48, blue: 0.48, alpha: 1.0)
    retryButton.backgroundColor = UIColor(red: 1.0, green: 0.48, blue: 0.48, alpha: 0.14)
    retryButton.layer.cornerCurve = .continuous
    retryButton.layer.cornerRadius = 14
    retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
    retryButton.imageView?.contentMode = .scaleAspectFit
    retryButton.addTarget(self, action: #selector(handleRetryTap), for: .touchUpInside)

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
    richTextView.isHidden = true
    replyPreviewView.isHidden = true
    linkPreviewView.isHidden = true
    mediaContainerView.isHidden = true
    mediaPrimaryIconView.isHidden = true
    mediaVoiceButtonView.isHidden = true
    mediaTitleLabel.isHidden = true
    mediaDetailLabel.isHidden = true
    mediaWaveformView.isHidden = true
    mediaVideoInfoBadgeView.isHidden = true
    mediaDurationBadge.isHidden = true
    mediaProgressOverlayView.isHidden = true
    mediaProgressSizeLabel.isHidden = true
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
    inlineVideoLog(
      "didMoveToWindow window=\(window != nil ? "Y" : "N") active=\(mediaVideoPlaybackActive ? "Y" : "N")"
    )
    updateStickerAnimationPlayback()
    refreshInlineVideoPlaybackIfNeeded()
    updateWallpaperBackdropLayoutIfNeeded()
  }

  func currentMediaImage() -> UIImage? {
    mediaImageView.image
  }

  func setInlineVideoPlaybackActive(_ active: Bool) {
    guard mediaVideoPlaybackActive != active else { return }
    mediaVideoPlaybackActive = active
    inlineVideoLog("setActive active=\(active ? "Y" : "N")")
    refreshInlineVideoPlaybackIfNeeded()
  }

  func applyAppearance(_ appearance: ChatListAppearance) {
    self.appearance = appearance
    dayLabel.textColor = appearance.dayTextColor
    dayLabel.backgroundColor = appearance.dayBackgroundColor
    dayLabel.layer.borderColor = appearance.dayBorderColor.cgColor
    dayLabel.layer.borderWidth = 0.5
    dayLabel.layer.cornerRadius = 12.0
    dayLabel.clipsToBounds = true
    let isCurrentRowMe = row?.isMe == true
    let currentTextColor = isCurrentRowMe ? appearance.textColorMe : appearance.textColorThem
    let incomingVoiceStyle = resolvedIncomingVoiceButtonStyle(for: appearance)
    mediaWaveformView.applyColors(
      active: currentTextColor.withAlphaComponent(0.95),
      inactive: currentTextColor.withAlphaComponent(0.34)
    )
    mediaVoiceButtonView.applyStyle(
      fillColor: isCurrentRowMe ? UIColor(white: 1.0, alpha: 0.96) : incomingVoiceStyle.fill,
      iconTint: isCurrentRowMe
        ? (appearance.bubbleMeGradient.first ?? UIColor.systemBlue)
        : incomingVoiceStyle.accent,
      ringTint: isCurrentRowMe
        ? currentTextColor.withAlphaComponent(0.74)
        : incomingVoiceStyle.accent.withAlphaComponent(0.74)
    )
    mediaPlaceholderBlurView.effect = UIBlurEffect(
      style: appearance.isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight
    )
    mediaPlaceholderTintView.backgroundColor = UIColor(
      white: appearance.isDark ? 0.02 : 0.98,
      alpha: appearance.isDark ? 0.18 : 0.10
    )
    replyPreviewView.applyAppearance(appearance, isMe: isCurrentRowMe)
    linkPreviewView.applyAppearance(appearance, isMe: isCurrentRowMe)
    updateInlineVideoAudioIcon()
    updateMediaPlaceholderVisibility()
    setNeedsLayout()
  }

  func applyWallpaperBackdrop(
    snapshot: CGImage?,
    containerSize: CGSize,
    coordinateView: UIView?
  ) {
    wallpaperBackdropSnapshot = snapshot
    wallpaperBackdropContainerSize = containerSize
    wallpaperCoordinateView = coordinateView
    updateWallpaperBackdropLayoutIfNeeded()
  }

  func configure(
    row: ChatListRow,
    hiddenMessageId: String?,
    skipRemoteMediaLoad: Bool = false,
    preferredLocalMediaURLOverride: String? = nil
  ) {
    let activeVoiceSnapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
    self.row = row
    cachedLayoutMetrics = nil
    if row.visualKind == .voice, activeVoiceSnapshot.messageId == row.messageId {
      mediaNeedsDownload = activeVoiceSnapshot.isDownloading
      mediaIsDownloading = activeVoiceSnapshot.isDownloading
      mediaDownloadProgress = activeVoiceSnapshot.downloadProgress.map(Double.init)
    } else {
      mediaNeedsDownload = false
      mediaIsDownloading = false
      mediaDownloadProgress = nil
    }
    self.skipRemoteMediaLoad = skipRemoteMediaLoad
    self.preferredLocalMediaURLOverride = preferredLocalMediaURLOverride
    switch row.kind {
    case .day:
      isGhostHidden = false
      resetStickerAnimation()
      richTextView.reset()
      replyPreviewView.reset()
      linkPreviewView.reset()
      dayLabel.text = row.label
      dayLabel.isHidden = false
      bubbleView.isHidden = true
      tailView.isHidden = true
      messageLabel.isHidden = true
      richTextView.isHidden = true
      replyPreviewView.isHidden = true
      linkPreviewView.isHidden = true
      mediaContainerView.isHidden = true
      inlineAttachmentView.isHidden = true
      metaContainerView.isHidden = true
      reactionPillView.isHidden = true
      mediaProgressSpinner.stopAnimating()
      mediaProgressOverlayView.isHidden = true
      mediaProgressSizeLabel.isHidden = true
    case .message:
      let isGhostHidden = hiddenMessageId == row.messageId
      let usesTransparentAgentStreaming = usesTransparentAgentStreamingLayout(row)
      let usesBlockLayout = bubbleUsesBlockLayout(row)
      let previewURL = bubblePreviewURL(for: row)
      let showsReplyPreview = hasReplyPreview(row)
      self.isGhostHidden = isGhostHidden
      dayLabel.isHidden = true
      bubbleView.isHidden = false
      tailView.isHidden = isGhostHidden || !row.shape.showTail
      messageLabel.isHidden = isGhostHidden || !(row.visualKind == .text || hasMediaCaptionLayout(row)) || usesBlockLayout
      richTextView.isHidden = isGhostHidden || !usesBlockLayout
      replyPreviewView.isHidden = isGhostHidden || !showsReplyPreview
      linkPreviewView.isHidden = isGhostHidden || previewURL == nil
      if row.messageType == "typing" {
        startTypingShimmer()
        messageLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
      } else {
        stopTypingShimmer()
        messageLabel.font = bubbleMessageFont
      }
      mediaContainerView.isHidden = isGhostHidden || row.visualKind == .text
      inlineAttachmentView.isHidden = isGhostHidden || !hasInlineAttachment(row)
      metaContainerView.isHidden = isGhostHidden || usesTransparentAgentStreaming

      // Agent/Mention labeling
      let isTyping = row.messageType == "typing"
      let messageFont =
        isTyping ? UIFont.systemFont(ofSize: 13, weight: .regular) : bubbleMessageFont
      let resolveTextColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
      let displayText = bubbleDisplayAttributedString(
        for: row, font: messageFont, textColor: resolveTextColor)
      messageLabel.textAlignment = usesRTLColumnLayout(row) ? .right : .natural
      messageLabel.semanticContentAttribute = usesRTLColumnLayout(row) ? .forceRightToLeft : .unspecified
      messageLabel.applyStreamingText(
        displayText,
        rawText: displayText.string,
        isStreaming: row.isAgentMessage && row.isStreamingText && row.messageType != "typing"
      )
      if let previewURL, !linkPreviewView.isHidden {
        linkPreviewView.configure(url: previewURL, appearance: appearance, isMe: row.isMe)
      } else {
        linkPreviewView.reset()
      }
      if !replyPreviewView.isHidden {
        replyPreviewView.configure(
          title: replyPreviewTitle(for: row),
          text: replyPreviewText(for: row),
          appearance: appearance,
          isMe: row.isMe
        )
      } else {
        replyPreviewView.reset()
      }
      editedLabel.text = "edited"
      pinnedLabel.text = "pinned"
      editedLabel.isHidden = !row.isEdited
      pinnedLabel.isHidden = !row.isPinned
      timestampLabel.text = row.timestamp

      if let reactionEmoji = row.reactionEmoji, !reactionEmoji.isEmpty {
        reactionPillView.isHidden = isGhostHidden || usesTransparentAgentStreaming
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
        if usesTransparentAgentStreaming {
          bubbleView.clearAgentStyle()
          tailView.clearAgentTailStyle()
          bubbleView.configure(
            isMe: false,
            shape: row.shape,
            hidden: true,
            appearance: appearance
          )
          tailView.setImage(nil)
          tailView.configure(
            isMe: false,
            visible: false,
            appearance: appearance
          )
        } else {
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
        }
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
        inlineAttachmentIconView.image = UIImage(systemName: inlineAttachmentIconName(for: row))
        inlineAttachmentTitleLabel.text = inlineAttachmentTitle(for: row)
        inlineAttachmentSubtitleLabel.text = inlineAttachmentSubtitle(for: row)
      } else {
        inlineAttachmentIconView.image = UIImage(systemName: "doc.text.fill")
        inlineAttachmentTitleLabel.text = nil
        inlineAttachmentSubtitleLabel.text = nil
      }
      configureStatus(for: row, baseColor: metaColor)
      if row.visualKind == .voice {
        VoiceBubblePlaybackCoordinator.shared.bind(
          cell: self,
          messageId: row.messageId,
          mediaURL: resolvedVoicePlaybackURL(for: row),
          mediaKey: row.mediaKey,
          fileName: row.fileName)
        applyExternalVoicePlaybackIfNeeded()
      } else {
        VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
      }
      // Use full opacity — visibility is controlled by isHidden, not alpha.
      // This eliminates the 0→1 opacity flicker that plagued updates.
      messageLabel.alpha = 1.0
      richTextView.alpha = 1.0
      replyPreviewView.alpha = 1.0
      linkPreviewView.alpha = 1.0
      inlineAttachmentView.alpha = 1.0
      mediaContainerView.alpha = 1.0
      metaContainerView.alpha = 0.72
      reactionPillView.alpha = 1.0
    }

    if hasSavedExtractionState {
      savedBubbleHiddenBeforeExtraction = bubbleView.isHidden
      savedTailHiddenBeforeExtraction = tailView.isHidden
      savedReactionHiddenBeforeExtraction = reactionPillView.isHidden
      savedMessageAlphaBeforeExtraction = messageLabel.alpha
      savedRichTextAlphaBeforeExtraction = richTextView.alpha
      savedReplyPreviewAlphaBeforeExtraction = replyPreviewView.alpha
      savedLinkPreviewAlphaBeforeExtraction = linkPreviewView.alpha
      savedInlineAttachmentAlphaBeforeExtraction = inlineAttachmentView.alpha
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
    onRetryMessageTap = nil
    row = nil
    cachedLayoutMetrics = nil
    isGhostHidden = false
    mediaProgressSpinner.stopAnimating()
    mediaProgressOverlayView.isHidden = true
    mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
    mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
    mediaProgressSizeLabel.isHidden = true
    mediaProgressSizeLabel.text = nil
    richTextView.reset()
    richTextView.isHidden = true
    replyPreviewView.reset()
    replyPreviewView.isHidden = true
    linkPreviewView.reset()
    linkPreviewView.isHidden = true
    mediaVideoInfoBadgeView.isHidden = true
    mediaVideoAudioIconView.isHidden = true
    mediaVideoAudioIconView.image = nil
    mediaNeedsDownload = false
    mediaIsDownloading = false
    mediaDownloadProgress = nil
    mediaVideoCurrentTime = 0.0
    mediaVideoTotalDuration = nil
    skipRemoteMediaLoad = false
    preferredLocalMediaURLOverride = nil
    wallpaperCoordinateView = nil
    wallpaperBackdropSnapshot = nil
    wallpaperBackdropContainerSize = .zero
    bubbleView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
    tailView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
    reactionPillView.isHidden = true
    externalVoiceMessageId = nil
    externalVoiceIsPlaying = false
    externalVoiceProgress = 0.0
    lastReportedMediaSizeKey = nil
    resolveDisplayStatus = nil
    applyVoiceDownloadState(needsDownload: false, isDownloading: false, progress: nil)
    applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
    mediaWaveformView.setWaveform(nil)
    statusImageView.isHidden = true
    statusImageView.image = nil
    pendingStatusView.isHidden = true
    pendingStatusView.stopAnimating()
    statusLabel.isHidden = true
    statusLabel.text = nil
    retryButton.isHidden = true
    renderedStatusKey = nil
    isContextMenuExtracted = false
    isContextMenuHeld = false
    hasSavedExtractionState = false
    mediaImageTask?.cancel()
    mediaImageTask = nil
    mediaImageView.image = nil
    stopInlineVideoPlayback(resetMutedState: true)
    mediaPlaceholderBlurView.isHidden = true
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
    if let cached = cachedLayoutMetrics, cachedLayoutWidth == bounds.width, !cached.usesRichTextLayout {
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
    let usesTransparentAgentStreaming = usesTransparentAgentStreamingLayout(row)
    let isFullBleed = metrics.isMediaLayout && usesFullBleedMediaLayout(row)
    let metaTopSpacing = effectiveMetaTopSpacing(for: row)

    let showTail = row.shape.showTail && !isGhostHidden
      && !(row.messageType == "typing" || isTransparentStickerMessage(row) || usesTransparentAgentStreaming)
    if showTail {
      // IMPORTANT: tailView has a rotation+flip transform applied, so we MUST NOT
      // set .frame (undefined behavior per Apple docs). Use bounds + center instead.
      let tailSize: CGFloat = 29
      let tailX = row.isMe ? bubbleFrame.maxX - 2 : bubbleFrame.minX - 27
      let tailY = bubbleFrame.maxY - tailSize + 1.0
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
      let hasMediaCaption = hasMediaCaptionLayout(row) && metrics.textHeight > 0.0 && !isFullBleed
      richTextView.frame = .zero
      replyPreviewView.frame = .zero
      linkPreviewView.frame = .zero
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
        let mediaTopInset: CGFloat = row.visualKind == .voice ? 2.0 : bubbleTopPadding
        let mediaLeftInset: CGFloat =
          row.visualKind == .voice ? max(6.0, bubbleHorizontalPadding - 2.0) : bubbleHorizontalPadding
        mediaFrame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + mediaLeftInset,
            y: bubbleFrame.minY + mediaTopInset,
            width: metrics.contentWidth,
            height: metrics.mediaHeight
          ))
      }
      mediaContainerView.frame = mediaFrame
      if let r = self.row, r.visualKind != .text && r.visualKind != .voice {
        chatCellDebugLog(
          chatCellMediaDebugLogs,
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

      if hasMediaCaption {
        messageLabel.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + bubbleHorizontalPadding,
            y: mediaFrame.maxY + 8.0,
            width: metrics.messageWidth,
            height: metrics.textHeight
          ))
      } else {
        messageLabel.frame = .zero
      }
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
        metaY = bubbleFrame.maxY - bubbleMetaHeight - 3.0
      } else if hasMediaCaption {
        metaY = messageLabel.frame.maxY + bubbleMetaTopSpacing
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
      let bubbleTextColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
      if metrics.hasInlineAttachment {
        richTextView.frame = .zero
        linkPreviewView.frame = .zero
        let contentX = bubbleFrame.minX + bubbleHorizontalPadding
        var contentY = bubbleFrame.minY + bubbleTopPadding
        if metrics.hasReplyPreview {
          replyPreviewView.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: contentY,
              width: metrics.contentWidth,
              height: metrics.replyPreviewHeight
            ))
          contentY = replyPreviewView.frame.maxY + bubbleReplyPreviewSpacing
        } else {
          replyPreviewView.frame = .zero
        }
        messageLabel.frame = pixelAlignedRect(
          CGRect(
            x: contentX,
            y: contentY,
            width: metrics.messageWidth,
            height: metrics.textHeight
          ))
        inlineAttachmentView.frame = pixelAlignedRect(
          CGRect(
            x: contentX,
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
      } else if metrics.usesBottomMetaLayout {
        let contentX = bubbleFrame.minX + bubbleHorizontalPadding
        var contentY = bubbleFrame.minY + bubbleTopPadding

        inlineAttachmentView.frame = .zero
        if metrics.hasReplyPreview {
          replyPreviewView.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: contentY,
              width: metrics.contentWidth,
              height: metrics.replyPreviewHeight
            ))
          contentY = replyPreviewView.frame.maxY + bubbleReplyPreviewSpacing
        } else {
          replyPreviewView.frame = .zero
        }
        if metrics.usesRichTextLayout {
          messageLabel.frame = .zero
          let richTextHeight = richTextView.configure(
            row: row,
            textColor: bubbleTextColor,
            availableWidth: metrics.messageWidth
          )
          richTextView.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: contentY,
              width: metrics.messageWidth,
              height: max(metrics.textHeight, richTextHeight)
            )
          )
        } else {
          richTextView.frame = .zero
          messageLabel.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: contentY,
              width: metrics.messageWidth,
              height: metrics.textHeight
            )
          )
        }

        let textBottom = metrics.usesRichTextLayout ? richTextView.frame.maxY : messageLabel.frame.maxY

        if metrics.hasLinkPreview {
          let previewTop = textBottom + bubbleLinkPreviewSpacing
          linkPreviewView.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: previewTop,
              width: metrics.contentWidth,
              height: metrics.previewHeight
            )
          )
        } else {
          linkPreviewView.frame = .zero
        }

        let metaTop = metrics.hasLinkPreview
          ? linkPreviewView.frame.maxY + bubbleMetaTopSpacing
          : textBottom + bubbleMetaTopSpacing
        metaContainerView.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.maxX - bubbleHorizontalPadding - metrics.metaWidth,
            y: metaTop,
            width: metrics.metaWidth,
            height: bubbleMetaHeight
          )
        )
      } else {
        richTextView.frame = .zero
        linkPreviewView.frame = .zero
        inlineAttachmentView.frame = .zero

        if metrics.hasReplyPreview {
          replyPreviewView.frame = pixelAlignedRect(
            CGRect(
              x: bubbleFrame.minX + bubbleHorizontalPadding,
              y: bubbleFrame.minY + bubbleTopPadding,
              width: metrics.contentWidth,
              height: metrics.replyPreviewHeight
            ))
        } else {
          replyPreviewView.frame = .zero
        }

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

    let retrySize: CGFloat = 28.0
    if retryButton.isHidden {
      retryButton.frame = .zero
    } else {
      let retryX = row.isMe
        ? max(8.0, bubbleFrame.minX - retrySize - 7.0)
        : min(bounds.width - retrySize - 8.0, bubbleFrame.maxX + 7.0)
      let retryY = min(
        max(4.0, bubbleFrame.maxY - retrySize - 5.0),
        max(4.0, bounds.height - retrySize - 2.0)
      )
      retryButton.frame = pixelAlignedRect(
        CGRect(x: retryX, y: retryY, width: retrySize, height: retrySize)
      )
      retryButton.layer.cornerRadius = retrySize * 0.5
    }

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
    updateWallpaperBackdropLayoutIfNeeded()
  }

  func updateWallpaperBackdropLayoutIfNeeded() {
    guard let coordinateView = wallpaperCoordinateView else {
      bubbleView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
      tailView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
      return
    }

    guard
      wallpaperBackdropSnapshot != nil,
      wallpaperBackdropContainerSize.width > 1.0,
      wallpaperBackdropContainerSize.height > 1.0,
      let row,
      row.kind == .message,
      !bubbleView.isHidden
    else {
      bubbleView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
      tailView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
      return
    }

    let bubbleRect = bubbleView.convert(bubbleView.bounds, to: coordinateView)
    bubbleView.applyWallpaperBackdrop(
      snapshot: wallpaperBackdropSnapshot,
      containerSize: wallpaperBackdropContainerSize,
      sampleRect: bubbleRect
    )

    if !tailView.isHidden, tailView.imageView.image == nil {
      let tailRect = tailView.convert(tailView.bounds, to: coordinateView)
      tailView.applyWallpaperBackdrop(
        snapshot: wallpaperBackdropSnapshot,
        containerSize: wallpaperBackdropContainerSize,
        sampleRect: tailRect
      )
    } else {
      tailView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
    }
  }

  private func resolvedInlineVideoPlaybackURL(
    preferredLocalMediaURL: String?,
    row: ChatListRow
  ) -> URL? {
    if let localPath = resolvedLocalMediaPath(preferredLocalMediaURL),
      FileManager.default.fileExists(atPath: localPath)
    {
      inlineVideoLog("resolvedURL source=preferredLocal path=\(localPath)")
      return URL(fileURLWithPath: localPath)
    }
    if let localPath = resolvedLocalMediaPath(row.localMediaUrl),
      FileManager.default.fileExists(atPath: localPath)
    {
      inlineVideoLog("resolvedURL source=rowLocal path=\(localPath)")
      return URL(fileURLWithPath: localPath)
    }

    let requiresLocalPlayback =
      row.visualKind == .video
      || row.visualKind == .videoNote
      || (row.visualKind == .media && row.messageType != "file")
      || !(row.mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    guard !requiresLocalPlayback else {
      inlineVideoLog(
        "resolvedURL blockedLocalOnly mediaKey=\((row.mediaKey?.isEmpty == false) ? "Y" : "N") localRaw=\(row.localMediaUrl ?? "nil") remote=\(row.mediaUrl ?? "nil")"
      )
      return nil
    }

    let trimmedKey = row.mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard trimmedKey.isEmpty,
      let remoteRaw = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      let remoteURL = URL(string: remoteRaw),
      let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      inlineVideoLog(
        "resolvedURL failed preferredLocal=\(preferredLocalMediaURL ?? "nil") localRaw=\(row.localMediaUrl ?? "nil") remote=\(row.mediaUrl ?? "nil")"
      )
      return nil
    }
    inlineVideoLog("resolvedURL source=remote url=\(remoteURL.absoluteString)")
    return remoteURL
  }

  private func stopInlineVideoPlayback(resetMutedState: Bool) {
    if mediaVideoPlayer != nil || mediaVideoPlayerURLKey != nil {
      inlineVideoLog(
        "stopPlayback resetMuted=\(resetMutedState ? "Y" : "N") ready=\(mediaVideoReady ? "Y" : "N") url=\(mediaVideoPlayerURLKey ?? "nil")"
      )
    }
    if let mediaVideoTimeObserver, let player = mediaVideoPlayer {
      player.removeTimeObserver(mediaVideoTimeObserver)
      self.mediaVideoTimeObserver = nil
    }
    mediaVideoStatusObserver?.invalidate()
    mediaVideoStatusObserver = nil
    if let mediaVideoLoopObserver {
      NotificationCenter.default.removeObserver(mediaVideoLoopObserver)
      self.mediaVideoLoopObserver = nil
    }
    mediaVideoPlayer?.pause()
    mediaVideoPlayer = nil
    mediaVideoPlayerLayer.player = nil
    mediaVideoPlayerLayer.opacity = 0.0
    mediaVideoPlayerHostView.isHidden = true
    mediaVideoPlayerURLKey = nil
    mediaVideoReady = false
    mediaVideoCurrentTime = 0.0
    if resetMutedState {
      mediaVideoIsMuted = true
    }
    mediaVideoHasAudio = false
    updateInlineVideoTimeBadge()
    updateInlineVideoAudioIcon()
    updateMediaPlaceholderVisibility()
  }

  private func updateInlineVideoAudioIcon() {
    guard let row, row.visualKind == .video || row.visualKind == .videoNote else {
      mediaVideoAudioIconView.isHidden = true
      mediaVideoAudioIconView.image = nil
      mediaVideoAudioIconView.alpha = 1.0
      return
    }

    let badgeSymbolConfig = UIImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
    let hasKnownAudio =
      mediaVideoHasAudio
      || resolvedVideoAudioState(
        preferredLocalMediaURL: effectivePreferredLocalMediaURL(nil),
        row: row
      ) == true
    let showsMutedIcon = mediaVideoIsMuted || !hasKnownAudio
    mediaVideoAudioIconView.isHidden = false
    mediaVideoAudioIconView.image = UIImage(
      systemName: showsMutedIcon ? "speaker.slash.fill" : "speaker.wave.2.fill",
      withConfiguration: badgeSymbolConfig
    )
    mediaVideoAudioIconView.alpha = hasKnownAudio ? 1.0 : 0.72
  }

  private func updateInlineVideoTimeBadge() {
    guard let row, row.visualKind == .video || row.visualKind == .videoNote else {
      mediaDurationBadge.text = nil
      return
    }
    let resolvedDuration = mediaVideoTotalDuration ?? row.duration
    let nextText = formatBubblePlaybackTimer(
      current: mediaVideoCurrentTime,
      duration: resolvedDuration
    )
    guard mediaDurationBadge.text != nextText else { return }
    mediaDurationBadge.text = nextText
    setNeedsLayout()
  }

  private func attachInlineVideoTimeObserver(to player: AVPlayer) {
    if let mediaVideoTimeObserver {
      player.removeTimeObserver(mediaVideoTimeObserver)
      self.mediaVideoTimeObserver = nil
    }
    mediaVideoTimeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      guard let self else { return }
      self.mediaVideoCurrentTime = max(0.0, CMTimeGetSeconds(time))
      self.updateInlineVideoTimeBadge()
    }
  }

  private func updateMediaPlaceholderVisibility() {
    guard let row else {
      mediaPlaceholderBlurView.isHidden = true
      return
    }
    let supportsPlaceholder =
      row.visualKind == .video
      || row.visualKind == .videoNote
      || (row.visualKind == .media && row.messageType != "file")
    let hasInlineVideo =
      !mediaVideoPlayerHostView.isHidden && mediaVideoReady && mediaVideoPlayerLayer.player != nil
    let hasVisualPreview =
      mediaImageView.image != nil || hasInlineVideo || !mediaStickerAnimationView.isHidden
    mediaPlaceholderBlurView.isHidden = !supportsPlaceholder || hasVisualPreview
  }

  private func refreshInlineVideoPlaybackIfNeeded(
    preferredLocalMediaURL: String? = nil
  ) {
    let effectivePreferredLocalMediaURL = effectivePreferredLocalMediaURL(preferredLocalMediaURL)
    guard let row else {
      inlineVideoLog("refresh skip=noRow")
      stopInlineVideoPlayback(resetMutedState: true)
      return
    }
    guard row.visualKind == .video || row.visualKind == .videoNote else {
      inlineVideoLog("refresh skip=nonVideo visualKind=\(row.visualKind)")
      stopInlineVideoPlayback(resetMutedState: true)
      return
    }
    guard mediaVideoPlaybackActive, window != nil, !isContextMenuExtracted,
      !row.shouldShowUploadOverlay, !mediaIsDownloading
    else {
      inlineVideoLog(
        "refresh pause active=\(mediaVideoPlaybackActive ? "Y" : "N") hasWindow=\(window != nil ? "Y" : "N") extracted=\(isContextMenuExtracted ? "Y" : "N") uploading=\(row.shouldShowUploadOverlay ? "Y" : "N") downloading=\(mediaIsDownloading ? "Y" : "N")"
      )
      mediaVideoPlayer?.pause()
      mediaVideoPlayerLayer.opacity = 0.0
      mediaVideoPlayerHostView.isHidden = true
      updateInlineVideoAudioIcon()
      updateMediaPlaceholderVisibility()
      return
    }
    guard let playbackURL = resolvedInlineVideoPlaybackURL(
      preferredLocalMediaURL: effectivePreferredLocalMediaURL, row: row)
    else {
      inlineVideoLog(
        "refresh noPlaybackURL preferredLocal=\(effectivePreferredLocalMediaURL ?? "nil") localRaw=\(row.localMediaUrl ?? "nil") remote=\(row.mediaUrl ?? "nil")"
      )
      stopInlineVideoPlayback(resetMutedState: false)
      return
    }

    let playbackKey = playbackURL.absoluteString
    inlineVideoLog(
      "refresh start url=\(playbackKey) ready=\(mediaVideoReady ? "Y" : "N") reuse=\(mediaVideoPlayerURLKey == playbackKey ? "Y" : "N")"
    )
    if mediaVideoPlayerURLKey != playbackKey {
      stopInlineVideoPlayback(resetMutedState: false)
      let playerItem = AVPlayerItem(url: playbackURL)
      let player = AVPlayer(playerItem: playerItem)
      player.actionAtItemEnd = .none
      player.isMuted = true
      mediaVideoCurrentTime = 0.0
      mediaVideoPlayer = player
      mediaVideoPlayerLayer.player = player
      mediaVideoPlayerURLKey = playbackKey
      mediaVideoPlayerHostView.isHidden = false
      mediaVideoReady = false
      mediaVideoHasAudio = false
      attachInlineVideoTimeObserver(to: player)
      updateInlineVideoTimeBadge()
      inlineVideoLog("player create url=\(playbackKey)")
      mediaVideoLoopObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: playerItem,
        queue: .main
      ) { [weak self] _ in
        guard let self, let player = self.mediaVideoPlayer else { return }
        self.inlineVideoLog("player loop url=\(playbackKey)")
        self.mediaVideoCurrentTime = 0.0
        self.updateInlineVideoTimeBadge()
        player.seek(to: .zero)
        player.play()
      }
      mediaVideoStatusObserver = playerItem.observe(\.status, options: [.initial, .new]) {
        [weak self] item, _ in
        guard let self else { return }
        DispatchQueue.main.async {
          switch item.status {
          case .readyToPlay:
            self.mediaVideoReady = true
            let duration = CMTimeGetSeconds(item.duration)
            if duration.isFinite, duration > 0.0 {
              self.mediaVideoTotalDuration = duration
            }
            self.mediaVideoHasAudio = !item.asset.tracks(withMediaType: .audio).isEmpty
            self.mediaVideoPlayer?.isMuted = self.mediaVideoIsMuted || !self.mediaVideoHasAudio
            self.mediaVideoPlayerLayer.opacity = 1.0
            self.mediaVideoPlayerHostView.isHidden = false
            self.mediaVideoPlayer?.play()
            self.updateInlineVideoTimeBadge()
            self.inlineVideoLog(
              "player ready url=\(playbackKey) hasAudio=\(self.mediaVideoHasAudio ? "Y" : "N") muted=\(self.mediaVideoPlayer?.isMuted == true ? "Y" : "N") duration=\(CMTimeGetSeconds(item.duration))"
            )
          case .failed:
            self.mediaVideoReady = false
            self.mediaVideoPlayerLayer.opacity = 0.0
            self.mediaVideoPlayerHostView.isHidden = true
            self.inlineVideoLog(
              "player failed url=\(playbackKey) error=\(item.error?.localizedDescription ?? "nil")"
            )
          case .unknown:
            fallthrough
          @unknown default:
            self.mediaVideoReady = false
            self.mediaVideoPlayerLayer.opacity = 0.0
            self.inlineVideoLog("player unknown url=\(playbackKey)")
          }
          self.updateInlineVideoAudioIcon()
          self.updateMediaPlaceholderVisibility()
        }
      }
    }

    mediaVideoPlayer?.isMuted = mediaVideoIsMuted || !mediaVideoHasAudio
    if mediaVideoReady {
      mediaVideoPlayerHostView.isHidden = false
      mediaVideoPlayerLayer.opacity = 1.0
      mediaVideoPlayer?.play()
      inlineVideoLog(
        "player play url=\(playbackKey) timeControl=\(mediaVideoPlayer?.timeControlStatus.rawValue ?? -1)"
      )
    }
    updateInlineVideoAudioIcon()
    updateMediaPlaceholderVisibility()
  }

  private func effectivePreferredLocalMediaURL(_ candidate: String?) -> String? {
    let trimmedCandidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedCandidate.isEmpty {
      return trimmedCandidate
    }
    let trimmedOverride = preferredLocalMediaURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmedOverride.isEmpty ? nil : trimmedOverride
  }

  private func inlineVideoLog(_ message: String) {
    guard chatCellInlineVideoDebugLogs else { return }
    let rowId = row?.messageId ?? "-"
    let visualKind = row.map { "\($0.visualKind)" } ?? "nil"
    NSLog("[ChatInlineVideo] msgId=%@ vk=%@ %@", rowId, visualKind, message)
  }

  private func resolvedVideoAudioState(
    preferredLocalMediaURL: String?,
    row: ChatListRow
  ) -> Bool? {
    let candidates = [preferredLocalMediaURL, row.localMediaUrl, row.mediaUrl]
    for candidate in candidates {
      if let cached = cachedVideoHasAudio(for: candidate) {
        return cached
      }
      if let hasAudio = probeLocalVideoHasAudio(for: candidate) {
        cacheVideoHasAudio(hasAudio, for: candidate)
        return hasAudio
      }
    }
    return nil
  }

  private func configureVideoInfoBadge(
    for row: ChatListRow,
    preferredLocalMediaURL: String?
  ) {
    let isVideo = row.visualKind == .video || row.visualKind == .videoNote
    guard isVideo else {
      mediaVideoInfoBadgeView.isHidden = true
      mediaDurationBadge.isHidden = true
      mediaDurationBadge.text = nil
      mediaVideoAudioIconView.isHidden = true
      mediaVideoAudioIconView.image = nil
      return
    }

    mediaVideoInfoBadgeView.isHidden = false
    mediaDurationBadge.isHidden = false
    mediaVideoTotalDuration = row.duration
    if mediaVideoPlayer == nil {
      mediaVideoCurrentTime = 0.0
    }
    updateInlineVideoTimeBadge()

    if let hasAudio = resolvedVideoAudioState(preferredLocalMediaURL: preferredLocalMediaURL, row: row) {
      mediaVideoHasAudio = hasAudio
    }
    updateInlineVideoAudioIcon()
  }

  private func updateMediaTransferChrome(for row: ChatListRow) {
    let hasActiveTransfer = row.shouldShowUploadOverlay || mediaIsDownloading
    mediaProgressOverlayView.backgroundColor = .clear
    mediaProgressOverlayView.isHidden = !hasActiveTransfer
    mediaProgressRingView.isHidden = !hasActiveTransfer
    mediaProgressSpinner.stopAnimating()

    if row.shouldShowUploadOverlay {
      mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      mediaProgressRingView.setUploadState(isUploading: true, progress: row.uploadProgress)
      if let totalBytes = row.fileSize, totalBytes > 0, let progress = row.uploadProgress {
        let sentBytes = Int64(Double(totalBytes) * max(0.0, min(1.0, progress)))
        let sentStr = formatMediaByteSize(sentBytes)
        let totalStr = formatMediaByteSize(totalBytes)
        mediaProgressSizeLabel.text = "  \(sentStr) / \(totalStr)  "
        mediaProgressSizeLabel.isHidden = false
      } else {
        mediaProgressSizeLabel.text = "  Processing  "
        mediaProgressSizeLabel.isHidden = false
      }
    } else if mediaIsDownloading {
      mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
      mediaProgressRingView.setDownloadState(
        needsDownload: true,
        isDownloading: true,
        progress: mediaDownloadProgress
      )
      if let totalBytes = row.fileSize, totalBytes > 0, let progress = mediaDownloadProgress {
        let receivedBytes = Int64(Double(totalBytes) * max(0.0, min(1.0, progress)))
        let receivedStr = formatMediaByteSize(receivedBytes)
        let totalStr = formatMediaByteSize(totalBytes)
        mediaProgressSizeLabel.text = "  \(receivedStr) / \(totalStr)  "
        mediaProgressSizeLabel.isHidden = false
      } else {
        mediaProgressSizeLabel.text = "  Downloading  "
        mediaProgressSizeLabel.isHidden = false
      }
    } else {
      mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
      mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      mediaProgressSizeLabel.text = nil
      mediaProgressSizeLabel.isHidden = true
    }

    let shouldShowPrimaryIcon: Bool = {
      switch row.visualKind {
      case .video, .videoNote:
        return true
      case .media:
        return row.messageType == "file"
      case .text, .voice, .sticker:
        return false
      }
    }()
    mediaPrimaryIconView.isHidden = row.shouldShowUploadOverlay || mediaIsDownloading || !shouldShowPrimaryIcon

    if row.visualKind == .video || row.visualKind == .videoNote {
      mediaVideoInfoBadgeView.isHidden = hasActiveTransfer
    } else {
      mediaVideoInfoBadgeView.isHidden = true
    }
  }

  private func resolvedVoicePlaybackURL(for row: ChatListRow) -> String? {
    let local = row.localMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let local, !local.isEmpty {
      return local
    }
    let remote = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let remote, !remote.isEmpty {
      return remote
    }
    return nil
  }

  private func refreshVoiceMetadataText() {
    guard let row, row.visualKind == .voice, usesAudioMetadataVoiceLayout(row) else { return }

    mediaTitleLabel.text = resolvedAudioVoiceTitle(row)
    if row.shouldShowUploadOverlay {
      if let totalBytes = row.fileSize, totalBytes > 0, let progress = row.uploadProgress {
        let sentBytes = Int64(Double(totalBytes) * max(0.0, min(1.0, progress)))
        mediaDetailLabel.text = "\(formatMediaByteSize(sentBytes)) / \(formatMediaByteSize(totalBytes))"
      } else {
        mediaDetailLabel.text = "Uploading"
      }
      return
    }
    if mediaIsDownloading {
      if let totalBytes = row.fileSize, totalBytes > 0, let progress = mediaDownloadProgress {
        let receivedBytes = Int64(Double(totalBytes) * max(0.0, min(1.0, progress)))
        mediaDetailLabel.text =
          "\(formatMediaByteSize(receivedBytes)) / \(formatMediaByteSize(totalBytes))"
      } else {
        mediaDetailLabel.text = "Downloading"
      }
      return
    }
    mediaDetailLabel.text = resolvedAudioVoiceStaticDetail(row)
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
    mediaVideoInfoBadgeView.isHidden = true
    mediaVideoAudioIconView.isHidden = true
    mediaVideoAudioIconView.image = nil
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
    mediaVoiceButtonView.setArtworkImage(nil)
    if row.visualKind != .voice {
      mediaVoiceButtonView.setUploadState(isUploading: false, progress: nil)
      mediaVoiceButtonView.setDownloadState(
        needsDownload: false, isDownloading: false, progress: nil)
    }
    mediaVoiceButtonView.isUserInteractionEnabled = true
    mediaVideoHasAudio = false
    mediaVideoCurrentTime = 0.0
    mediaVideoTotalDuration = row.duration

    mediaTitleLabel.textColor = textColor
    mediaTitleLabel.textAlignment = .left
    mediaTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    mediaDetailLabel.textColor = metaColor
    mediaDetailLabel.textAlignment = .right
    mediaDetailLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
    mediaContainerView.clipsToBounds = !isTransparentSticker
    mediaBorderLayer.isHidden = true
    mediaBorderLayer.lineWidth = 0.0
    mediaBorderLayer.strokeColor = nil
    mediaBorderLayer.path = nil
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
      chatCellDebugLog(
        chatCellMediaDebugLogs,
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
      mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
      mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      mediaProgressSpinner.stopAnimating()
      mediaProgressSizeLabel.isHidden = true
      return
    }

    mediaContainerView.clipsToBounds = true

    switch row.visualKind {
    case .voice:
      mediaContainerView.clipsToBounds = false
      mediaVoiceButtonView.isHidden = false
      let usesMetadataLayout = usesAudioMetadataVoiceLayout(row)
      mediaTitleLabel.isHidden = !usesMetadataLayout
      mediaDetailLabel.isHidden = false
      mediaWaveformView.isHidden = usesMetadataLayout
      mediaDetailLabel.textAlignment = .left
      mediaDetailLabel.font = UIFont.systemFont(
        ofSize: 11,
        weight: usesMetadataLayout ? .regular : .semibold
      )
      mediaContainerView.backgroundColor = .clear
      if usesMetadataLayout {
        mediaTitleLabel.text = resolvedAudioVoiceTitle(row)
        mediaTitleLabel.textAlignment = .left
        mediaTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        mediaVoiceButtonView.setArtworkImage(chatMediaImage(fromBase64: row.thumbnailBase64))
      } else {
        mediaDetailLabel.text = "\(formatBubbleDuration(seconds: row.duration)) \u{2022}"
        mediaWaveformView.setWaveform(row.waveform)
        mediaWaveformView.applyColors(
          active: textColor.withAlphaComponent(0.95),
          inactive: textColor.withAlphaComponent(0.34)
        )
      }
      let incomingVoiceStyle = resolvedIncomingVoiceButtonStyle(for: appearance)
      mediaVoiceButtonView.applyStyle(
        fillColor: row.isMe ? UIColor(white: 1.0, alpha: 0.96) : incomingVoiceStyle.fill,
        iconTint: row.isMe
          ? (appearance.bubbleMeGradient.first ?? UIColor.systemBlue)
          : incomingVoiceStyle.accent,
        ringTint: row.isMe
          ? textColor.withAlphaComponent(0.74)
          : incomingVoiceStyle.accent.withAlphaComponent(0.74)
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
      refreshVoiceMetadataText()

    case .video:
      mediaImageView.isHidden = false
      mediaPrimaryIconView.isHidden = false
      mediaPrimaryIconView.image = UIImage(systemName: "play.fill")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 24, weight: .bold))
      mediaPrimaryIconView.backgroundColor = UIColor(white: 0.0, alpha: 0.28)
      mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.35)
      let bubbleColor =
        row.isMe ? (appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor) : appearance.bubbleThemColor
      mediaBorderLayer.lineWidth = 1.0
      mediaBorderLayer.strokeColor =
        bubbleColor.withAlphaComponent(appearance.isDark ? 0.38 : 0.32).cgColor
      mediaBorderLayer.isHidden = false

    case .videoNote:
      mediaImageView.isHidden = false
      mediaPrimaryIconView.isHidden = false
      mediaPrimaryIconView.image = UIImage(systemName: "play.fill")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 26, weight: .bold))
      mediaPrimaryIconView.backgroundColor = UIColor(white: 0.0, alpha: 0.28)
      mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
      let bubbleColor =
        row.isMe ? (appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor) : appearance.bubbleThemColor
      mediaBorderLayer.lineWidth = 1.0
      mediaBorderLayer.strokeColor =
        bubbleColor.withAlphaComponent(appearance.isDark ? 0.42 : 0.34).cgColor
      mediaBorderLayer.isHidden = false

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
      mediaPrimaryIconView.backgroundColor = .clear
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

    chatCellDebugLog(
      chatCellMediaDebugLogs,
      "[ChatMediaCfg] POST-SWITCH msgId=%@ imgViewHidden=%@ imgViewImage=%@ containerBg=%@ containerFrame=%@",
      row.messageId ?? "-",
      mediaImageView.isHidden ? "Y" : "N",
      mediaImageView.image != nil ? "hasImage" : "nil",
      String(describing: mediaContainerView.backgroundColor),
      NSCoder.string(for: mediaContainerView.frame)
    )

    if mediaImageView.isHidden || row.mediaUrl == nil {
      if row.visualKind != .text && row.visualKind != .voice && row.visualKind != .sticker {
        chatCellDebugLog(
          chatCellMediaDebugLogs,
          "[ChatMediaLoad] SKIP-LOAD msgId=%@ type=%@ imgHidden=%@ mediaUrl=%@",
          row.messageId ?? "-",
          row.messageType,
          mediaImageView.isHidden ? "Y" : "N",
          row.mediaUrl == nil ? "nil" : (row.mediaUrl?.isEmpty == true ? "empty" : "present")
        )
      }
    }
    var preferredLocalMediaURL: String?
    if !mediaImageView.isHidden {
      let prefersVideoPreview = row.visualKind == .video || row.visualKind == .videoNote
      if mediaImageView.image == nil {
        let thumbCacheKey = "thumb-\(row.key)" as NSString
        if let cachedThumb = chatMediaImageCache.object(forKey: thumbCacheKey) {
          applyResolvedMediaPreviewImage(cachedThumb, for: row, mediaURL: row.mediaUrl ?? row.key)
          chatCellDebugLog(
            chatCellMediaDebugLogs,
            "[ChatMediaLoad] thumbnail memory OK msgId=%@ type=%@ hasUrl=%@",
            row.messageId ?? "-",
            row.messageType,
            row.mediaUrl == nil ? "N" : "Y"
          )
        } else if let thumbnailImage = chatMediaImage(fromBase64: row.thumbnailBase64) {
          chatMediaImageCache.setObject(thumbnailImage, forKey: thumbCacheKey)
          applyResolvedMediaPreviewImage(thumbnailImage, for: row, mediaURL: row.mediaUrl ?? row.key)
          chatCellDebugLog(
            chatCellMediaDebugLogs,
            "[ChatMediaLoad] thumbnail metadata OK msgId=%@ type=%@ hasUrl=%@",
            row.messageId ?? "-",
            row.messageType,
            row.mediaUrl == nil ? "N" : "Y"
          )
        }
      }
      preferredLocalMediaURL = {
        if let override = preferredLocalMediaURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
          !override.isEmpty
        {
          let overridePath: String
          if let parsed = URL(string: override), parsed.isFileURL {
            overridePath = parsed.path
          } else {
            overridePath = override
          }
          if FileManager.default.fileExists(atPath: overridePath) {
            return override
          }
        }
        guard
          row.visualKind == .media || row.visualKind == .sticker || row.visualKind == .video
            || row.visualKind == .videoNote,
          let localMediaUrl = row.localMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
          !localMediaUrl.isEmpty
        else {
          return nil
        }
        let localPath: String
        if let parsed = URL(string: localMediaUrl), parsed.isFileURL {
          localPath = parsed.path
        } else {
          localPath = localMediaUrl
        }
        guard FileManager.default.fileExists(atPath: localPath) else { return nil }
        return localMediaUrl
      }()
      if let urlStr = preferredLocalMediaURL ?? row.mediaUrl {
        let effectiveMediaKey = preferredLocalMediaURL == nil ? row.mediaKey : nil
        let cacheKey = chatMediaCacheKey(urlStr, mediaKey: effectiveMediaKey)
        let shortUrl = urlStr.count > 80 ? String(urlStr.prefix(77)) + "..." : urlStr
        let encodedUrlStr =
          urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr
        let shouldAnimateMedia = chatMediaShouldAnimate(
          urlString: urlStr,
          messageType: row.messageType
        )
        let naturalSizeURL = row.mediaUrl ?? urlStr
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
          chatCellDebugLog(
            chatCellMediaDebugLogs,
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
            applyResolvedMediaPreviewImage(cachedImage, for: row, mediaURL: naturalSizeURL)
          } else if url.isFileURL || urlStr.hasPrefix("/") {
            let path = url.isFileURL ? url.path : urlStr
            if let image = chatMediaLoadImageFromFile(at: path, shouldAnimate: shouldAnimateMedia) {
              chatCellDebugLog(
                chatCellMediaDebugLogs,
                "[ChatMediaLoad] local file OK msgId=%@ url=%@",
                row.messageId ?? "-",
                shortUrl
              )
              chatMediaImageCache.setObject(image, forKey: cacheKey as NSString)
              applyResolvedMediaPreviewImage(image, for: row, mediaURL: naturalSizeURL)
            } else {
              let exists = FileManager.default.fileExists(atPath: path)
              let attrs = try? FileManager.default.attributesOfItem(atPath: path)
              let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
              chatCellDebugLog(
                chatCellMediaDebugLogs,
                "[ChatMediaLoad] local file NO_PREVIEW msgId=%@ type=%@ exists=%@ bytes=%lld path=%@ hasMediaKey=%@ fileName=%@ header=%@",
                row.messageId ?? "-",
                row.messageType,
                exists ? "Y" : "N",
                bytes,
                path,
                (row.mediaKey?.isEmpty == false) ? "Y" : "N",
                row.fileName ?? "-",
                chatMediaFileHeaderSummary(at: path)
              )
            }
          } else if let diskData = chatMediaDiskCacheLoad(cacheKey),
            let diskImage = chatMediaPreviewImage(
              from: diskData,
              shouldAnimate: shouldAnimateMedia,
              cacheKey: cacheKey,
              urlString: urlStr,
              fileName: row.fileName,
              messageType: row.messageType,
              preferVideoPreview: prefersVideoPreview
            )
          {
            chatCellDebugLog(
              chatCellMediaDebugLogs,
              "[ChatMediaLoad] disk preview OK msgId=%@ type=%@ bytes=%d url=%@",
              row.messageId ?? "-", row.messageType, diskData.count, shortUrl
            )
            chatMediaImageCache.setObject(diskImage, forKey: cacheKey as NSString)
            applyResolvedMediaPreviewImage(diskImage, for: row, mediaURL: naturalSizeURL)
          } else if chatMediaFailedURLs.contains(cacheKey) {
            chatCellDebugLog(
              chatCellMediaDebugLogs,
              "[ChatMediaLoad] skipping previously failed url=%@",
              shortUrl
            )
          } else if skipRemoteMediaLoad && preferredLocalMediaURL == nil {
            chatCellDebugLog(
              chatCellMediaDebugLogs,
              "[ChatMediaLoad] SKIP-REMOTE-PREVIEW msgId=%@ type=%@ url=%@",
              row.messageId ?? "-",
              row.messageType,
              urlStr
            )
          } else {
            chatCellDebugLog(
              chatCellMediaDebugLogs,
              "[ChatMediaLoad] network fetch START msgId=%@ url=%@", row.messageId ?? "-", shortUrl)
            mediaImageTask = URLSession.shared.dataTask(with: url) {
              [weak self] data, response, error in
              if let error {
                let nsErr = error as NSError
                let isCancelled = nsErr.code == NSURLErrorCancelled
                chatCellDebugLog(
                  chatCellMediaDebugLogs,
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
              guard let self = self, let data = data else {
                return
              }
              let decodedData = chatMediaDecryptedDataIfNeeded(data, mediaKey: effectiveMediaKey)
              guard let safeData = decodedData,
                let image = chatMediaPreviewImage(
                  from: safeData,
                  shouldAnimate: shouldAnimateMedia,
                  cacheKey: cacheKey,
                  urlString: urlStr,
                  fileName: row.fileName,
                  messageType: row.messageType,
                  preferVideoPreview: prefersVideoPreview
                )
              else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyPreview = String(data: data, encoding: .utf8) ?? "nil"
                chatCellDebugLog(
                  chatCellMediaDebugLogs,
                  "[ChatMediaLoad] network fetch NO_PREVIEW msgId=%@ type=%@ dataLen=%d status=%d url=%@ fileName=%@ hasThumb=%@ body=%@ header=%@",
                  row.messageId ?? "-",
                  row.messageType,
                  data.count,
                  statusCode,
                  urlStr,
                  row.fileName ?? "-",
                  row.thumbnailBase64 == nil ? "N" : "Y",
                  String(bodyPreview.prefix(200)),
                  chatMediaHeaderSummary(from: decodedData ?? data))
                chatMediaFailedURLs.insert(cacheKey)
                return
              }
              chatCellDebugLog(
                chatCellMediaDebugLogs,
                "[ChatMediaLoad] network fetch OK msgId=%@ type=%@ bytes=%d url=%@",
                row.messageId ?? "-",
                row.messageType,
                data.count,
                shortUrl
              )
              chatMediaImageCache.setObject(image, forKey: cacheKey as NSString)
              chatMediaDiskCacheSave(safeData, forKey: cacheKey)
              DispatchQueue.main.async {
                self.applyResolvedMediaPreviewImage(image, for: row, mediaURL: naturalSizeURL)
              }
            }
            mediaImageTask?.resume()
          }
        } else {
          chatCellDebugLog(
            chatCellMediaDebugLogs,
            "[ChatMediaLoad] URL parse FAIL msgId=%@ raw=%@", row.messageId ?? "-", shortUrl)
        }
      }
    }

    configureVideoInfoBadge(for: row, preferredLocalMediaURL: preferredLocalMediaURL)
    refreshInlineVideoPlaybackIfNeeded(preferredLocalMediaURL: preferredLocalMediaURL)

    if row.visualKind == .voice {
      stopInlineVideoPlayback(resetMutedState: true)
      mediaProgressOverlayView.isHidden = true
      mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
      mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      mediaProgressSpinner.stopAnimating()
      mediaProgressSizeLabel.isHidden = true
      updateMediaPlaceholderVisibility()
      return
    }

    updateMediaTransferChrome(for: row)
    updateMediaPlaceholderVisibility()

    chatCellDebugLog(
      chatCellMediaDebugLogs,
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

  private func applyResolvedMediaPreviewImage(
    _ image: UIImage,
    for row: ChatListRow,
    mediaURL: String
  ) {
    mediaImageView.image = image
    reportNaturalMediaSizeIfNeeded(for: row, mediaURL: mediaURL, image: image)
    updateMediaPlaceholderVisibility()
    if let metrics = cachedLayoutMetrics,
      metrics.isMediaLayout, usesFullBleedMediaLayout(row)
    {
      tailView.setImage(image)
      tailView.isHidden = isGhostHidden || !row.shape.showTail
    }
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
    mediaPlaceholderBlurView.frame = mediaContainerView.bounds
    mediaPlaceholderTintView.frame = mediaPlaceholderBlurView.contentView.bounds
    mediaVideoPlayerHostView.frame = mediaContainerView.bounds
    mediaVideoPlayerLayer.frame = mediaVideoPlayerHostView.bounds
    mediaProgressOverlayView.layer.cornerRadius = 0.0
    mediaBorderLayer.frame = mediaContainerView.bounds
    if !mediaBorderLayer.isHidden && mediaBorderLayer.lineWidth > 0.0 {
      let borderInset = mediaBorderLayer.lineWidth * 0.5
      let borderBounds = mediaContainerView.bounds.insetBy(dx: borderInset, dy: borderInset)
      if row.visualKind == .videoNote {
        mediaBorderLayer.path = UIBezierPath(ovalIn: borderBounds).cgPath
      } else if isFullBleed {
        mediaBorderLayer.path =
          bubbleRoundedPath(
            rect: borderBounds,
            topLeft: max(0.0, row.shape.borderTopLeftRadius - borderInset),
            topRight: max(0.0, row.shape.borderTopRightRadius - borderInset),
            bottomRight: max(0.0, row.shape.borderBottomRightRadius - borderInset),
            bottomLeft: max(0.0, row.shape.borderBottomLeftRadius - borderInset)
          ).cgPath
      } else {
        mediaBorderLayer.path =
          UIBezierPath(
            roundedRect: borderBounds,
            cornerRadius: max(0.0, cornerRadius - borderInset)
          ).cgPath
      }
    }

    mediaPrimaryIconView.frame = .zero
    mediaVoiceButtonView.frame = .zero
    mediaWaveformView.frame = .zero
    mediaTitleLabel.frame = .zero
    mediaDetailLabel.frame = .zero
    mediaVideoInfoBadgeView.frame = .zero
    mediaVideoTimeIconView.frame = .zero
    mediaVideoAudioIconView.frame = .zero
    mediaDurationBadge.frame = .zero
    mediaProgressOverlayView.frame = .zero
    mediaProgressRingView.frame = .zero
    mediaProgressSpinner.frame = .zero
    mediaProgressSizeLabel.frame = .zero

    switch row.visualKind {
    case .voice:
      let insetX: CGFloat = 2.0
      let buttonSize: CGFloat = 52.0  // Button view size, inner rendered symbol will be smaller
      mediaVoiceButtonView.frame = CGRect(
        x: insetX,
        y: floor((height - buttonSize) * 0.5),
        width: buttonSize,
        height: buttonSize
      )
      let textStartX = mediaVoiceButtonView.frame.maxX + (usesAudioMetadataVoiceLayout(row) ? 10.0 : 4.0)
      let rightInset: CGFloat = 8.0
      if usesAudioMetadataVoiceLayout(row) {
        let textWidth = max(1.0, width - textStartX - rightInset)
        mediaTitleLabel.frame = CGRect(
          x: textStartX,
          y: 11.0,
          width: textWidth,
          height: 18.0
        )
        mediaDetailLabel.frame = CGRect(
          x: textStartX,
          y: 30.0,
          width: textWidth,
          height: 14.0
        )
      } else {
        let waveY: CGFloat = 10.0
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
      }

    case .video, .videoNote, .media, .sticker:
      let btnSize: CGFloat = 44.0
      mediaPrimaryIconView.frame = CGRect(
        x: floor((width - btnSize) * 0.5),
        y: floor((height - btnSize) * 0.5),
        width: btnSize,
        height: btnSize
      )
      mediaPrimaryIconView.layer.cornerRadius = btnSize * 0.5

      if !mediaVideoInfoBadgeView.isHidden && !mediaDurationBadge.isHidden {
        let badgeText = mediaDurationBadge.text ?? ""
        let badgeHeight: CGFloat = 22.0
        let badgeInsetX: CGFloat = row.visualKind == .videoNote ? 10.0 : 8.0
        let badgeInsetY: CGFloat = row.visualKind == .videoNote ? 10.0 : 8.0
        let audioIconSize: CGFloat = mediaVideoAudioIconView.isHidden ? 0.0 : 11.0
        let textWidth = measuredTextWidth(badgeText, font: mediaDurationBadge.font)
        let badgeWidth =
          8.0 + textWidth
          + (audioIconSize > 0.0 ? 7.0 + audioIconSize : 0.0) + 8.0
        mediaVideoInfoBadgeView.frame = CGRect(
          x: badgeInsetX,
          y: badgeInsetY,
          width: badgeWidth,
          height: badgeHeight
        )
        mediaVideoTimeIconView.frame = .zero
        let labelX: CGFloat = 8.0
        let trailingInset: CGFloat = mediaVideoAudioIconView.isHidden ? 8.0 : (8.0 + audioIconSize + 4.0)
        mediaDurationBadge.frame = CGRect(
          x: labelX,
          y: 0.0,
          width: max(1.0, badgeWidth - labelX - trailingInset),
          height: badgeHeight
        )
        if !mediaVideoAudioIconView.isHidden {
          mediaVideoAudioIconView.frame = CGRect(
            x: badgeWidth - audioIconSize - 8.0,
            y: floor((badgeHeight - audioIconSize) * 0.5),
            width: audioIconSize,
            height: audioIconSize
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

    if !mediaProgressOverlayView.isHidden {
      let isUploading = row.shouldShowUploadOverlay

      if isUploading {
        let ringSize: CGFloat = 44.0
        let overlayWidth = width
        let overlayHeight = height
        mediaProgressOverlayView.frame = CGRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight)

        let ringX = floor((width - ringSize) * 0.5)
        let ringY = floor((height - ringSize) * 0.5)
        mediaProgressRingView.frame = CGRect(x: ringX, y: ringY, width: ringSize, height: ringSize)
        mediaProgressSpinner.center = CGPoint(x: width * 0.5, y: height * 0.5)

        if !mediaProgressSizeLabel.isHidden {
          let labelText = mediaProgressSizeLabel.text ?? ""
          let labelHeight: CGFloat = 20.0
          let labelWidth = measuredTextWidth(labelText, font: mediaProgressSizeLabel.font) + 8.0
          mediaProgressSizeLabel.frame = CGRect(
             x: floor((width - labelWidth) * 0.5),
             y: ringY + ringSize + 8.0,
             width: labelWidth,
             height: labelHeight
          )
        }
      } else {
        let badgeInsetX: CGFloat = row.visualKind == .videoNote ? 10.0 : 8.0
        let badgeInsetY: CGFloat = row.visualKind == .videoNote ? 10.0 : 8.0
        let ringSize: CGFloat = 18.0
        let ringY = 0.0
        let labelHeight: CGFloat = 20.0
        let labelWidth: CGFloat
        if !mediaProgressSizeLabel.isHidden {
          let labelText = mediaProgressSizeLabel.text ?? ""
          labelWidth = min(
            max(0.0, width - badgeInsetX - ringSize - 12.0),
            measuredTextWidth(labelText, font: mediaProgressSizeLabel.font) + 8.0
          )
        } else {
          labelWidth = 0.0
        }
        let overlayHeight = max(ringSize, labelHeight)
        let overlayWidth = ringSize + (labelWidth > 0.0 ? (6.0 + labelWidth) : 0.0)
        mediaProgressOverlayView.frame = CGRect(
          x: badgeInsetX,
          y: badgeInsetY,
          width: overlayWidth,
          height: overlayHeight
        )
        mediaProgressRingView.frame = CGRect(
          x: 0.0,
          y: floor((overlayHeight - ringSize) * 0.5),
          width: ringSize,
          height: ringSize
        )
        mediaProgressSpinner.center = CGPoint(x: ringSize * 0.5, y: overlayHeight * 0.5)
        if !mediaProgressSizeLabel.isHidden {
          mediaProgressSizeLabel.frame = CGRect(
            x: ringSize + 6.0,
            y: floor((overlayHeight - labelHeight) * 0.5),
            width: labelWidth,
            height: labelHeight
          )
        }
      }
    }
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

  @objc private func handleMediaProgressCancelTap() {
    guard let row else { return }
    if row.shouldShowUploadOverlay || mediaIsDownloading {
      onVoiceUploadCancelTap?(row)
    }
  }

  @objc private func handleInlineVideoMuteTap() {
    guard mediaVideoHasAudio else { return }
    mediaVideoIsMuted.toggle()
    mediaVideoPlayer?.isMuted = mediaVideoIsMuted
    updateInlineVideoAudioIcon()
  }

  @objc private func handleVoiceTap() {
    guard let row, row.visualKind == .voice else { return }
    if row.shouldShowUploadOverlay {
      onVoiceUploadCancelTap?(row)
      return
    }
    VoiceBubblePlaybackCoordinator.shared.toggle(
      cell: self,
      messageId: row.messageId,
      chatId: row.chatId,
      mediaURL: resolvedVoicePlaybackURL(for: row),
      mediaKey: row.mediaKey,
      fileName: row.fileName,
      title: usesAudioMetadataVoiceLayout(row) ? resolvedAudioVoiceTitle(row) : nil,
      subtitle: usesAudioMetadataVoiceLayout(row) ? resolvedAudioVoiceStaticDetail(row) : nil,
      artwork: usesAudioMetadataVoiceLayout(row) ? chatMediaImage(fromBase64: row.thumbnailBase64) : nil,
      duration: row.duration,
      presentsGlobalPlayer: usesAudioMetadataVoiceLayout(row)
    )
  }

  @objc private func handleRetryTap() {
    guard let row else { return }
    onRetryMessageTap?(row)
  }

  @objc private func handleInlineAttachmentTap() {
    guard let row, hasInlineAttachment(row) else { return }
    onInlineAttachmentTap?(row)
  }

  func hitTestInlineAttachment(at pointInCell: CGPoint) -> Bool {
    guard let row, hasInlineAttachment(row), !inlineAttachmentView.isHidden else {
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
      refreshVoiceMetadataText()
      return
    }
    mediaVoiceButtonView.setUploadState(isUploading: false, progress: nil)
    mediaVoiceButtonView.setPlaybackState(isPlaying: isPlaying, progress: progress, level: level)
    mediaWaveformView.setPlayback(progress: progress, level: level, isPlaying: isPlaying)
    refreshVoiceMetadataText()
  }

  func applyVoiceDownloadState(needsDownload: Bool, isDownloading: Bool, progress: CGFloat?) {
    mediaNeedsDownload = needsDownload
    mediaIsDownloading = isDownloading
    mediaDownloadProgress = progress.map(Double.init)
    guard !(row?.shouldShowUploadOverlay == true) else { return }
    mediaVoiceButtonView.setDownloadState(
      needsDownload: needsDownload,
      isDownloading: isDownloading,
      progress: progress
    )
    if needsDownload {
      mediaWaveformView.setPlayback(progress: progress ?? 0.0, level: 0.0, isPlaying: false)
    }
    refreshVoiceMetadataText()
  }

  func applyMediaDownloadState(needsDownload: Bool, isDownloading: Bool, progress: Double?) {
    mediaNeedsDownload = needsDownload
    mediaIsDownloading = isDownloading
    mediaDownloadProgress = progress
    guard let row, !(row.shouldShowUploadOverlay) else { return }
    updateMediaTransferChrome(for: row)
    refreshInlineVideoPlaybackIfNeeded()
    updateMediaPlaceholderVisibility()
    refreshVoiceMetadataText()
    setNeedsLayout()
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
      VoiceBubblePlaybackCoordinator.shared.bind(
        cell: self,
        messageId: nil,
        mediaURL: resolvedVoicePlaybackURL(for: row),
        mediaKey: row.mediaKey,
        fileName: row.fileName
      )
      applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
      return
    }
    if rowId == externalId {
      applyVoiceDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      applyVoicePlaybackState(
        isPlaying: externalVoiceIsPlaying,
        progress: externalVoiceProgress,
        level: externalVoiceIsPlaying ? 0.20 : 0.0
      )
    } else {
      VoiceBubblePlaybackCoordinator.shared.bind(
        cell: self,
        messageId: row.messageId,
        mediaURL: resolvedVoicePlaybackURL(for: row),
        mediaKey: row.mediaKey,
        fileName: row.fileName
      )
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
    pendingStatusView.frame = statusFrame
  }

  private func configureStatus(for newRow: ChatListRow, baseColor: UIColor) {
    let newStatus = (resolveDisplayStatus?(newRow) ?? newRow.status)?.lowercased()
    let oldStatusKey = renderedStatusKey
    let nextStatusKey = newRow.isMe ? (newStatus ?? "none") : nil

    statusLabel.text = nil
    statusLabel.textColor = baseColor
    statusLabel.font = bubbleMetaStatusFont
    statusLabel.isHidden = true
    statusImageView.image = nil
    statusImageView.isHidden = true
    statusImageView.layer.opacity = 1.0
    pendingStatusView.isHidden = true
    pendingStatusView.stopAnimating()

    guard newRow.isMe else {
      renderedStatusKey = nil
      retryButton.isHidden = true
      return
    }

    switch newStatus {
    case "pending", "sending":
      pendingStatusView.configure(color: baseColor)
      pendingStatusView.isHidden = false
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

    let showRetry = newStatus == "error" && !isGhostHidden
    retryButton.isHidden = !showRetry

    let shouldAnimateCheckIn =
      oldStatusKey != nil
      && oldStatusKey != nextStatusKey
      && statusImageView.isHidden == false
      && (newStatus == "sent" || newStatus == "delivered" || newStatus == "read")
    let shouldAnimateError =
      oldStatusKey != nil
      && oldStatusKey != nextStatusKey
      && newStatus == "error"
    renderedStatusKey = nextStatusKey
    if shouldAnimateCheckIn {
      animateStatusGlyphIn()
    }
    if shouldAnimateError {
      animateBubbleErrorNudge()
    }
  }

  private func animateBubbleErrorNudge() {
    bubbleView.layer.removeAnimation(forKey: "bubbleErrorNudge")
    let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
    animation.values = [0.0, -4.0, 3.0, -2.0, 0.0]
    animation.keyTimes = [0.0, 0.24, 0.52, 0.76, 1.0]
    animation.duration = 0.28
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    animation.isRemovedOnCompletion = true
    bubbleView.layer.add(animation, forKey: "bubbleErrorNudge")
  }

  private func animateStatusGlyphIn() {
    statusImageView.layer.removeAnimation(forKey: "statusCheckScaleIn")
    statusImageView.layer.removeAnimation(forKey: "statusCheckFadeIn")
    statusImageView.layer.opacity = 1.0

    let scale = CASpringAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.82
    scale.toValue = 1.0
    scale.mass = 0.7
    scale.stiffness = 520.0
    scale.damping = 34.0
    scale.initialVelocity = 0.0
    scale.duration = 0.2
    scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
    scale.isRemovedOnCompletion = true

    statusImageView.layer.add(scale, forKey: "statusCheckScaleIn")
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
        savedRichTextAlphaBeforeExtraction = richTextView.alpha
        savedReplyPreviewAlphaBeforeExtraction = replyPreviewView.alpha
        savedLinkPreviewAlphaBeforeExtraction = linkPreviewView.alpha
        savedInlineAttachmentAlphaBeforeExtraction = inlineAttachmentView.alpha
        savedMediaAlphaBeforeExtraction = mediaContainerView.alpha
        savedMetaAlphaBeforeExtraction = metaContainerView.alpha
        hasSavedExtractionState = true
      }
      bubbleView.isHidden = true
      tailView.isHidden = true
      reactionPillView.isHidden = true
      // Keep text/media/meta rendering alive for snapshot correctness, but hide them.
      messageLabel.alpha = 0.0
      richTextView.alpha = 0.0
      replyPreviewView.alpha = 0.0
      linkPreviewView.alpha = 0.0
      inlineAttachmentView.alpha = 0.0
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
    richTextView.alpha = savedRichTextAlphaBeforeExtraction
    replyPreviewView.alpha = savedReplyPreviewAlphaBeforeExtraction
    linkPreviewView.alpha = savedLinkPreviewAlphaBeforeExtraction
    inlineAttachmentView.alpha = savedInlineAttachmentAlphaBeforeExtraction
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
    if !richTextView.isHidden {
      contentRect = contentRect.union(richTextView.frame)
    }
    if !replyPreviewView.isHidden {
      contentRect = contentRect.union(replyPreviewView.frame)
    }
    if !linkPreviewView.isHidden {
      contentRect = contentRect.union(linkPreviewView.frame)
    }
    if !mediaContainerView.isHidden {
      contentRect = contentRect.union(mediaContainerView.frame)
    }
    if !inlineAttachmentView.isHidden {
      contentRect = contentRect.union(inlineAttachmentView.frame)
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
    let richTextWasHidden = richTextView.isHidden
    let replyWasHidden = replyPreviewView.isHidden
    let previewWasHidden = linkPreviewView.isHidden
    let mediaWasHidden = mediaContainerView.isHidden
    let attachmentWasHidden = inlineAttachmentView.isHidden
    let metaWasHidden = metaContainerView.isHidden

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    messageLabel.isHidden = true
    richTextView.isHidden = true
    replyPreviewView.isHidden = true
    linkPreviewView.isHidden = true
    mediaContainerView.isHidden = true
    inlineAttachmentView.isHidden = true
    metaContainerView.isHidden = true
    contentView.layoutIfNeeded()
    CATransaction.commit()

    defer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      messageLabel.isHidden = messageWasHidden
      richTextView.isHidden = richTextWasHidden
      replyPreviewView.isHidden = replyWasHidden
      linkPreviewView.isHidden = previewWasHidden
      mediaContainerView.isHidden = mediaWasHidden
      inlineAttachmentView.isHidden = attachmentWasHidden
      metaContainerView.isHidden = metaWasHidden
      contentView.layoutIfNeeded()
      CATransaction.commit()
    }

    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
    let image = renderer.image { _ in
      contentView.drawHierarchy(
        in: CGRect(
          x: -captureRect.minX,
          y: -captureRect.minY,
          width: contentView.bounds.width,
          height: contentView.bounds.height
        ),
        afterScreenUpdates: true
      )
    }
    let imageView = UIImageView(image: image)
    imageView.frame = contentView.convert(captureRect, to: view)
    imageView.contentMode = .scaleToFill
    imageView.backgroundColor = .clear
    imageView.isOpaque = false
    imageView.clipsToBounds = false
    return imageView
  }
}

final class BubbleTailView: UIView {
  private let wallpaperLayer = CALayer()
  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
  private let gradientLayer = CAGradientLayer()
  private let fillLayer = CAShapeLayer()
  private let tailMaskLayer = CAShapeLayer()
  private let clipMaskLayer = CAShapeLayer()
  private var currentIsMe: Bool = true
  private var appearance = ChatListAppearance.fallback
  private var wallpaperSnapshot: CGImage?
  private var wallpaperContainerSize: CGSize = .zero
  private var wallpaperSampleRect: CGRect = .zero
  let imageView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    clipsToBounds = false

    wallpaperLayer.contentsGravity = .resize
    wallpaperLayer.contentsScale = UIScreen.main.scale
    layer.addSublayer(wallpaperLayer)
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
    wallpaperLayer.isHidden = image != nil || wallpaperSnapshot == nil
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
    self.appearance = appearance
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyTailChrome(isMe: isMe, visible: visible)
    applyWallpaperBackdropLayer()
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
      gradientLayer.opacity = wallpaperLayer.isHidden ? 0.82 : 0.70
      blurView.alpha = wallpaperLayer.isHidden ? 0.42 : 0.0
    } else {
      gradientLayer.isHidden = false
      gradientLayer.colors = appearance.bubbleMeGradient.map(\.cgColor)
      gradientLayer.opacity = wallpaperLayer.isHidden ? 0.82 : 0.72
      blurView.alpha = 0.0
    }
    CATransaction.commit()
  }

  func clearAgentTailStyle() {
    // No-op: regular configure resets everything
  }

  func applyWallpaperBackdrop(
    snapshot: CGImage?,
    containerSize: CGSize,
    sampleRect: CGRect
  ) {
    wallpaperSnapshot = snapshot
    wallpaperContainerSize = containerSize
    wallpaperSampleRect = sampleRect
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyTailChrome(isMe: currentIsMe, visible: !isHidden)
    applyWallpaperBackdropLayer()
    CATransaction.commit()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.height > 0 else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    blurView.frame = bounds
    imageView.frame = bounds
    wallpaperLayer.frame = bounds
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

    applyWallpaperBackdropLayer()

    CATransaction.commit()
  }

  private func applyWallpaperBackdropLayer() {
    let hasBackdrop =
      imageView.image == nil
      && wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
      && appearance.backgroundMode != "transparent"

    wallpaperLayer.isHidden = !hasBackdrop
    guard hasBackdrop, let wallpaperSnapshot else {
      wallpaperLayer.contents = nil
      return
    }

    wallpaperLayer.contents = wallpaperSnapshot
    wallpaperLayer.contentsRect = normalizedWallpaperSampleRect(
      wallpaperSampleRect,
      containerSize: wallpaperContainerSize
    )
  }

  private func applyTailChrome(isMe: Bool, visible: Bool) {
    let hasWallpaperBackdrop =
      wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
      && appearance.backgroundMode != "transparent"
      && imageView.image == nil

    isHidden = !visible

    // Keep tail styling in lockstep with BubbleBackgroundView so both read as one shape.
    wallpaperLayer.isHidden = !hasWallpaperBackdrop
    wallpaperLayer.opacity = Float(
      hasWallpaperBackdrop
        ? (isMe ? appearance.outgoingWallpaperSampleOpacity : appearance.incomingWallpaperSampleOpacity)
        : 1.0
    )
    blurView.effect = UIBlurEffect(style: isMe ? .systemThinMaterialDark : .systemMaterialDark)
    blurView.alpha = hasWallpaperBackdrop ? 0.0 : (isMe ? 0.34 : 0.44)
    if hasWallpaperBackdrop {
      gradientLayer.isHidden = true
      gradientLayer.opacity = 0.0
      let plateColor = appearance.wallpaperPlateColor(
        isMe: isMe,
        sampleRect: wallpaperSampleRect,
        containerSize: wallpaperContainerSize
      )
      let plateAlpha = isMe ? appearance.outgoingPlateFillOpacity : appearance.incomingPlateFillOpacity
      fillLayer.fillColor = plateColor.withAlphaComponent(plateAlpha).cgColor
    } else {
      gradientLayer.isHidden = !isMe
      gradientLayer.colors = appearance.bubbleMeGradient.map(\.cgColor)
      gradientLayer.opacity = Float(isMe ? 0.88 : 0.0)
      fillLayer.fillColor =
        isMe
        ? UIColor.clear.cgColor
        : appearance.bubbleThemColor.withAlphaComponent(appearance.isDark ? 0.86 : 1.0).cgColor
    }

    // For 'me': rotate CW 26.565° (tail curves right at bottom-right of bubble)
    // For 'them': flip horizontally + rotate CCW 26.565° (tail curves left at bottom-left)
    let angle = (isMe ? 26.565 : -26.565) * (.pi / 180.0)
    let rotate = CGAffineTransform(rotationAngle: angle)
    let flip = CGAffineTransform(scaleX: isMe ? 1.0 : -1.0, y: 1.0)
    // Translate slightly inward to bury the tail edge into the bubble body and prevent any 1px gaps
    let translate = CGAffineTransform(translationX: isMe ? -0.5 : 0.5, y: 0.0)
    transform = flip.concatenating(rotate).concatenating(translate)
  }
}

// MARK: - Send transition overlay helpers
