import AVFoundation
import UIKit

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
    let attributes = super.layoutAttributesForElements(in: rect)?
      .map { $0.copy() as! UICollectionViewLayoutAttributes }
    // Force alpha=1 on every layout pass — prevent UIKit from
    // ever setting a sub-1.0 alpha on any cell at any point.
    attributes?.forEach { $0.alpha = 1.0 }
    return attributes
  }

  override func layoutAttributesForItem(at indexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    let attrs = super.layoutAttributesForItem(at: indexPath)
    attrs?.alpha = 1.0
    return attrs
  }
}

private struct BubbleSurfaceStyle {
  let showsBlur: Bool
  let blurStyle: UIBlurEffect.Style
  let blurAlpha: CGFloat
  let gradientColors: [CGColor]
  let gradientOpacity: Float
  let fillColor: CGColor
}

private func bubbleSurfaceStyle(isMe: Bool, appearance: ChatListAppearance) -> BubbleSurfaceStyle {
  let gradientColors =
    appearance.bubbleMeGradient.isEmpty
    ? [appearance.bubbleThemColor.cgColor, appearance.bubbleThemColor.cgColor]
    : appearance.bubbleMeGradient.map(\.cgColor)

  if isMe {
    let fallbackMe =
      appearance.bubbleMeGradient.first
      ?? appearance.bubbleThemColor
    return BubbleSurfaceStyle(
      showsBlur: false,
      blurStyle: .systemThinMaterialDark,
      blurAlpha: 0.0,
      gradientColors: gradientColors,
      gradientOpacity: 1.0,
      fillColor: fallbackMe.withAlphaComponent(1.0).cgColor
    )
  }

  return BubbleSurfaceStyle(
    showsBlur: false,
    blurStyle: .systemMaterialDark,
    blurAlpha: 0.0,
    gradientColors: gradientColors,
    gradientOpacity: 0.0,
    fillColor: appearance.bubbleThemColor.withAlphaComponent(1.0).cgColor
  )
}

final class BubbleBackgroundView: UIView {
  private let blurView = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let gradientLayer = CAGradientLayer()
  private let fillLayer = CAShapeLayer()
  private let bubbleMaskLayer = CAShapeLayer()
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
    self.shape = shape
    let style = bubbleSurfaceStyle(isMe: isMe, appearance: appearance)

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
    blurView.isHidden = hidden || !style.showsBlur || style.blurAlpha <= 0.001
    if !blurView.isHidden {
      blurView.effect = UIBlurEffect(style: style.blurStyle)
    }
    blurView.alpha = style.blurAlpha
    gradientLayer.isHidden = style.gradientOpacity <= 0.001
    gradientLayer.colors = style.gradientColors
    gradientLayer.opacity = style.gradientOpacity
    fillLayer.fillColor = style.fillColor
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

func measureMessageBubbleLayout(row: ChatListRow, rowWidth: CGFloat)
  -> ChatMessageBubbleLayoutMetrics
{
  let maxBubbleWidth = rowWidth * bubbleMaxWidthFactor
  let maxContentWidth = max(1.0, maxBubbleWidth - (bubbleHorizontalPadding * 2.0))
  let meta = bubbleMetaWidths(for: row)

  switch row.visualKind {
  case .voice, .video, .videoNote, .media:
    let targetWidth: CGFloat
    let mediaHeight: CGFloat
    switch row.visualKind {
    case .voice:
      targetWidth = 242.0
      mediaHeight = 56.0
    case .video:
      targetWidth = 224.0
      mediaHeight = 140.0
    case .videoNote:
      targetWidth = 200.0
      mediaHeight = 200.0
    case .media:
      targetWidth = 210.0
      mediaHeight = 132.0
    case .text:
      targetWidth = maxContentWidth
      mediaHeight = 0.0
    }

    let contentWidth = min(maxContentWidth, targetWidth)
    let bodyHeight = mediaHeight + bubbleMetaTopSpacing + bubbleMetaHeight
    let bubbleWidth = max(bubbleMinWidth, contentWidth + (bubbleHorizontalPadding * 2.0))
    let bubbleHeight = max(56.0, bodyHeight + bubbleTopPadding + bubbleBottomPadding)
    return ChatMessageBubbleLayoutMetrics(
      bubbleWidth: bubbleWidth,
      bubbleHeight: bubbleHeight,
      messageWidth: contentWidth,
      textHeight: 0.0,
      bodyHeight: bodyHeight,
      metaWidth: meta.total,
      contentWidth: contentWidth,
      mediaHeight: mediaHeight,
      isMediaLayout: true
    )

  case .text:
    break
  }

  let textMaxWidth = max(1.0, maxContentWidth - meta.total - bubbleMetaInlineSpacing)
  let textRect = (row.text as NSString).boundingRect(
    with: CGSize(width: textMaxWidth, height: .greatestFiniteMagnitude),
    options: [.usesLineFragmentOrigin, .usesFontLeading],
    attributes: [.font: bubbleMessageFont],
    context: nil
  )
  let textWidth = min(textMaxWidth, ceil(textRect.width))
  let textHeight = ceil(textRect.height)
  let desiredContentWidth = textWidth + bubbleMetaInlineSpacing + meta.total
  let contentWidth = max(meta.total, min(maxContentWidth, desiredContentWidth))
  let messageWidth = max(1.0, contentWidth - meta.total - bubbleMetaInlineSpacing)
  let bodyHeight = max(textHeight, bubbleMetaHeight)
  let bubbleWidth = max(bubbleMinWidth, contentWidth + (bubbleHorizontalPadding * 2.0))
  let bubbleHeight = max(36.0, bodyHeight + bubbleTopPadding + bubbleBottomPadding)
  return ChatMessageBubbleLayoutMetrics(
    bubbleWidth: bubbleWidth,
    bubbleHeight: bubbleHeight,
    messageWidth: messageWidth,
    textHeight: textHeight,
    bodyHeight: bodyHeight,
    metaWidth: meta.total,
    contentWidth: contentWidth,
    mediaHeight: 0.0,
    isMediaLayout: false
  )
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
  private let fillView = UIView()
  private let iconView = UIImageView()
  private let ringTrackLayer = CAShapeLayer()
  private let ringProgressLayer = CAShapeLayer()
  private var iconTintColor = UIColor.systemBlue

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = true
    backgroundColor = .clear

    fillView.isUserInteractionEnabled = false
    fillView.backgroundColor = UIColor(white: 1.0, alpha: 0.96)
    fillView.layer.cornerCurve = .continuous
    addSubview(fillView)

    ringTrackLayer.fillColor = UIColor.clear.cgColor
    ringTrackLayer.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
    ringTrackLayer.lineWidth = 2.2
    ringTrackLayer.lineCap = .round
    layer.addSublayer(ringTrackLayer)

    ringProgressLayer.fillColor = UIColor.clear.cgColor
    ringProgressLayer.strokeColor = UIColor.systemBlue.cgColor
    ringProgressLayer.lineWidth = 2.2
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

    let ringRadius = max(2.0, (diameter * 0.5) + 1.8)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let ringPath = UIBezierPath(
      arcCenter: center,
      radius: ringRadius,
      startAngle: -.pi / 2,
      endAngle: (.pi * 3.0) / 2.0,
      clockwise: true)
    ringTrackLayer.frame = bounds
    ringProgressLayer.frame = bounds
    ringTrackLayer.path = ringPath.cgPath
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
    ringTrackLayer.strokeColor = ringTint.withAlphaComponent(0.28).cgColor
    ringProgressLayer.strokeColor = ringTint.cgColor
  }

  func setPlaybackState(isPlaying: Bool, progress: CGFloat) {
    let symbol = isPlaying ? "pause.fill" : "play.fill"
    let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)
    iconView.image = UIImage(systemName: symbol, withConfiguration: config)
    iconView.tintColor = iconTintColor

    let clamped = max(0.0, min(1.0, progress))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ringProgressLayer.strokeEnd = clamped
    CATransaction.commit()
  }
}

final class VoiceWaveformView: UIView {
  private let barCount = 34
  private var barLayers: [CALayer] = []
  private var barEnvelope: [CGFloat] = []
  private var playbackProgress: CGFloat = 0.0
  private var level: CGFloat = 0.0
  private var isPlaying = false
  private var activeColor = UIColor.white
  private var inactiveColor = UIColor(white: 1.0, alpha: 0.28)

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    barEnvelope = Self.makeDefaultEnvelope(count: barCount)
    for _ in 0..<barCount {
      let layer = CALayer()
      layer.backgroundColor = inactiveColor.cgColor
      barLayers.append(layer)
      self.layer.addSublayer(layer)
    }
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    applyBarFrames()
  }

  func applyColors(active: UIColor, inactive: UIColor) {
    activeColor = active
    inactiveColor = inactive
    applyBarFrames()
  }

  func setWaveform(_ samples: [CGFloat]?) {
    guard let samples, !samples.isEmpty else {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      applyBarFrames()
      return
    }
    let normalized =
      samples
      .filter { $0.isFinite }
      .map { max(0.0, min(1.0, $0)) }
    guard !normalized.isEmpty else {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      applyBarFrames()
      return
    }

    let resampled: [CGFloat]
    if normalized.count == barCount {
      resampled = normalized
    } else {
      var output: [CGFloat] = []
      output.reserveCapacity(barCount)
      let bucketSize = CGFloat(normalized.count) / CGFloat(barCount)
      for index in 0..<barCount {
        let start = Int(floor(CGFloat(index) * bucketSize))
        let end = min(normalized.count, Int(floor(CGFloat(index + 1) * bucketSize)))
        if start < end {
          let slice = normalized[start..<end]
          let sumSquares = slice.reduce(CGFloat(0.0)) { partial, value in
            partial + (value * value)
          }
          let rms = sqrt(sumSquares / CGFloat(slice.count))
          let peak = slice.max() ?? rms
          // RMS gives stable body; peak preserves consonant spikes.
          let energy = (rms * 0.58) + (peak * 0.42)
          output.append(max(0.0, min(1.0, pow(energy, 0.76))))
        } else {
          output.append(normalized[min(max(0, start), normalized.count - 1)])
        }
      }
      resampled = output
    }

    barEnvelope = Self.shaped(Self.smoothed(Self.smoothed(resampled)))
    applyBarFrames()
  }

  func setPlayback(progress: CGFloat, level: CGFloat, isPlaying: Bool) {
    let clamped = max(0.0, min(1.0, progress))
    playbackProgress =
      isPlaying
      ? (playbackProgress + ((clamped - playbackProgress) * 0.35))
      : clamped
    self.level = max(0.0, min(1.0, level))
    self.isPlaying = isPlaying
    applyBarFrames()
  }

  private func applyBarFrames() {
    guard !barLayers.isEmpty, bounds.width > 1.0, bounds.height > 1.0 else { return }
    let spacing: CGFloat = 2.0
    let totalSpacing = spacing * CGFloat(max(0, barCount - 1))
    let barWidth = max(1.0, floor((bounds.width - totalSpacing) / CGFloat(barCount)))
    let minHeight = max(1.0, floor(bounds.height * 0.22))
    let maxHeight = max(minHeight + 1.0, floor(bounds.height * 0.92))
    let dynamicGain = isPlaying ? (1.0 + (level * 0.22)) : 1.0
    let progressX = max(0.0, min(bounds.width, playbackProgress * bounds.width))
    var x: CGFloat = 0.0

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, barLayer) in barLayers.enumerated() {
      let spectralBias = 0.92 + (0.12 * CGFloat(sin(Double(index) * 0.52)))
      let amplitude = max(0.16, min(1.0, barEnvelope[index] * dynamicGain * spectralBias))
      let barHeight = minHeight + ((maxHeight - minHeight) * amplitude)
      let y = floor((bounds.height - barHeight) * 0.5)
      let barStart = x
      let barEnd = x + barWidth
      let fillFraction = max(0.0, min(1.0, (progressX - barStart) / max(1.0, barEnd - barStart)))
      barLayer.frame = CGRect(x: x, y: y, width: barWidth, height: floor(barHeight))
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
        - (abs((CGFloat(index) / CGFloat(max(1, values.count - 1))) - 0.5) * 0.18)
      return max(0.14, min(1.0, pow(value, 0.86) * edgeAttenuation))
    }
  }

  private static func makeDefaultEnvelope(count: Int) -> [CGFloat] {
    guard count > 0 else { return [] }
    let template: [CGFloat] = [0.74, 0.58, 0.81, 0.63, 0.48, 0.86, 0.62, 0.22, 0.26, 0.71]
    return (0..<count).map { index in
      template[index % template.count]
    }
  }
}

private final class VoiceBubblePlaybackCoordinator: NSObject, AVAudioPlayerDelegate {
  static let shared = VoiceBubblePlaybackCoordinator()

  private weak var activeCell: ChatListCell?
  private var activeMessageId: String?
  private var player: AVAudioPlayer?
  private var displayLink: CADisplayLink?
  private var playbackProgress: CGFloat = 0.0
  private var level: CGFloat = 0.0
  private var isPlaying = false

  private override init() {
    super.init()
  }

  deinit {
    displayLink?.invalidate()
    player?.stop()
  }

  func bind(cell: ChatListCell, messageId: String?) {
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

  func unbind(cell: ChatListCell) {
    if activeCell === cell {
      activeCell = nil
    }
  }

  func toggle(cell: ChatListCell, messageId: String?, mediaURL: String?) {
    guard let messageId, !messageId.isEmpty, let mediaURL, !mediaURL.isEmpty else {
      return
    }

    if activeMessageId == messageId, let player {
      if player.isPlaying {
        player.pause()
        isPlaying = false
        cell.applyVoicePlaybackState(
          isPlaying: false, progress: playbackProgress, level: level
        )
      } else {
        player.play()
        isPlaying = true
      }
      return
    }

    stopActivePlayback(resetProgress: true)

    guard let resolvedURL = resolveAudioURL(from: mediaURL) else {
      return
    }

    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .default, options: [.duckOthers])
      try AVAudioSession.sharedInstance().setActive(true)
      let nextPlayer = try AVAudioPlayer(contentsOf: resolvedURL)
      nextPlayer.delegate = self
      nextPlayer.prepareToPlay()
      nextPlayer.isMeteringEnabled = true
      player = nextPlayer
      activeMessageId = messageId
      activeCell = cell
      playbackProgress = 0.0
      level = 0.0
      isPlaying = nextPlayer.play()
      ensureDisplayLink()
      cell.applyVoicePlaybackState(isPlaying: isPlaying, progress: 0.0, level: 0.0)
    } catch {
      stopActivePlayback(resetProgress: true)
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
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
      if let url = URL(string: trimmed) {
        pathString = url.path
      } else if let decoded = trimmed.removingPercentEncoding, let url = URL(string: decoded) {
        pathString = url.path
      }
    }

    if pathString.contains("/Application/") || pathString.contains("/Containers/") {
      let sandboxTargets = ["/Library/", "/Documents/", "/tmp/"]
      for target in sandboxTargets {
        if let range = pathString.range(of: target, options: .backwards) {
          let suffix = pathString[range.lowerBound...]
          let patchedPath = NSHomeDirectory() + suffix
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
    if let url = URL(string: trimmed), url.scheme == nil {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }
}

final class ChatListCell: UICollectionViewCell {
  static let reuseIdentifier = "ChatListCell"

  let bubbleView = BubbleBackgroundView()
  let tailView = BubbleTailView()
  private let messageLabel = UILabel()
  private let mediaContainerView = UIView()
  private let mediaPrimaryIconView = UIImageView()
  private let mediaVoiceButtonView = VoicePlayProgressView()
  private let mediaTitleLabel = UILabel()
  private let mediaDetailLabel = UILabel()
  private let mediaWaveformView = VoiceWaveformView()
  private let mediaDurationBadge = UILabel()
  private let mediaProgressOverlayView = UIView()
  private let mediaProgressRingView = BubbleUploadProgressView()
  private let mediaProgressSpinner = UIActivityIndicatorView(style: .medium)
  private let metaContainerView = UIView()
  private let editedLabel = UILabel()
  private let pinnedLabel = UILabel()
  private let timestampLabel = UILabel()
  private let statusLabel = UILabel()
  private let dayLabel = UILabel()
  private let reactionPillView = UIView()
  private let reactionLabel = UILabel()
  private var appearance = ChatListAppearance.fallback
  private var row: ChatListRow?
  private var isGhostHidden = false
  private var externalVoiceMessageId: String?
  private var externalVoiceIsPlaying = false
  private var externalVoiceProgress: CGFloat = 0.0
  var onVoiceBubbleTap: ((ChatListRow) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)

    clipsToBounds = false
    contentView.clipsToBounds = false

    contentView.addSubview(bubbleView)
    contentView.addSubview(tailView)
    contentView.addSubview(messageLabel)
    contentView.addSubview(mediaContainerView)
    mediaContainerView.addSubview(mediaPrimaryIconView)
    mediaContainerView.addSubview(mediaVoiceButtonView)
    mediaContainerView.addSubview(mediaTitleLabel)
    mediaContainerView.addSubview(mediaDetailLabel)
    mediaContainerView.addSubview(mediaWaveformView)
    mediaContainerView.addSubview(mediaDurationBadge)
    mediaContainerView.addSubview(mediaProgressOverlayView)
    mediaProgressOverlayView.addSubview(mediaProgressRingView)
    mediaProgressOverlayView.addSubview(mediaProgressSpinner)
    contentView.addSubview(metaContainerView)
    metaContainerView.addSubview(editedLabel)
    metaContainerView.addSubview(pinnedLabel)
    metaContainerView.addSubview(timestampLabel)
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

    editedLabel.font = bubbleMetaFont
    pinnedLabel.font = bubbleMetaFont
    timestampLabel.font = bubbleMetaFont
    timestampLabel.textColor = UIColor(white: 1.0, alpha: 0.72)
    statusLabel.font = bubbleMetaStatusFont
    statusLabel.textAlignment = .center

    dayLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    dayLabel.textAlignment = .center
    dayLabel.textColor = UIColor(white: 0.95, alpha: 0.9)

    reactionPillView.backgroundColor = UIColor(white: 0.0, alpha: 0.25)
    reactionPillView.layer.cornerRadius = 14
    reactionPillView.layer.cornerCurve = .continuous
    reactionPillView.clipsToBounds = true

    reactionLabel.font = UIFont.systemFont(ofSize: 15)
    reactionLabel.textAlignment = .center

    bubbleView.isHidden = true
    tailView.isHidden = true
    messageLabel.isHidden = true
    mediaContainerView.isHidden = true
    mediaPrimaryIconView.isHidden = true
    mediaVoiceButtonView.isHidden = true
    mediaTitleLabel.isHidden = true
    mediaDetailLabel.isHidden = true
    mediaWaveformView.isHidden = true
    mediaDurationBadge.isHidden = true
    mediaProgressOverlayView.isHidden = true
    metaContainerView.isHidden = true
    editedLabel.isHidden = true
    pinnedLabel.isHidden = true
    timestampLabel.isHidden = true
    statusLabel.isHidden = true
    dayLabel.isHidden = true
    reactionPillView.isHidden = true
  }

  required init?(coder: NSCoder) {
    return nil
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
    switch row.kind {
    case .day:
      isGhostHidden = false
      dayLabel.text = row.label
      dayLabel.isHidden = false
      bubbleView.isHidden = true
      tailView.isHidden = true
      messageLabel.isHidden = true
      mediaContainerView.isHidden = true
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
      mediaContainerView.isHidden = isGhostHidden || row.visualKind == .text
      metaContainerView.isHidden = isGhostHidden
      messageLabel.text = row.text
      editedLabel.text = "edited"
      pinnedLabel.text = "pinned"
      editedLabel.isHidden = !row.isEdited
      pinnedLabel.isHidden = !row.isPinned
      timestampLabel.text = row.timestamp

      if let reactionEmoji = row.reactionEmoji, !reactionEmoji.isEmpty {
        reactionPillView.isHidden = isGhostHidden
        reactionLabel.text = reactionEmoji
      } else {
        reactionPillView.isHidden = true
      }

      bubbleView.configure(
        isMe: row.isMe, shape: row.shape, hidden: isGhostHidden, appearance: appearance)
      tailView.configure(
        isMe: row.isMe,
        visible: !isGhostHidden && row.shape.showTail,
        appearance: appearance
      )
      let textColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
      let metaColor = resolvedMetaColor(for: textColor)
      messageLabel.textColor = textColor
      editedLabel.textColor = metaColor
      pinnedLabel.textColor = metaColor
      timestampLabel.textColor = metaColor
      configureMediaPresentation(for: row, textColor: textColor, metaColor: metaColor)
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
    }
    setNeedsLayout()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
    onVoiceBubbleTap = nil
    row = nil
    isGhostHidden = false
    mediaProgressSpinner.stopAnimating()
    mediaProgressOverlayView.isHidden = true
    mediaProgressRingView.setProgress(nil)
    reactionPillView.isHidden = true
    externalVoiceMessageId = nil
    externalVoiceIsPlaying = false
    externalVoiceProgress = 0.0
    applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
    mediaWaveformView.setWaveform(nil)
    contentView.alpha = 1.0
    contentView.transform = .identity
    // Strip any residual UIKit animations from the previous lifecycle.
    layer.removeAllAnimations()
    contentView.layer.removeAllAnimations()
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

    let metrics = measureMessageBubbleLayout(row: row, rowWidth: bounds.width)
    let bubbleWidth = metrics.bubbleWidth
    let bubbleHeight = metrics.bubbleHeight
    let bubbleX = row.isMe ? bounds.width - bubbleWidth - bubbleSideMargin : bubbleSideMargin
    let bubbleY = max(0.0, bounds.height - bubbleHeight)

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    bubbleView.frame = CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight)
    if row.shape.showTail && !isGhostHidden {
      // IMPORTANT: tailView has a rotation+flip transform applied, so we MUST NOT
      // set .frame (undefined behavior per Apple docs). Use bounds + center instead.
      let tailSize: CGFloat = 29
      let tailX = row.isMe ? bubbleX + bubbleWidth - 1 : bubbleX - 28
      let tailY = bubbleY + bubbleHeight - tailSize
      tailView.bounds = CGRect(origin: .zero, size: CGSize(width: tailSize, height: tailSize))
      tailView.center = CGPoint(x: tailX + tailSize * 0.5, y: tailY + tailSize * 0.5)
      tailView.isHidden = false
    } else {
      tailView.isHidden = true
    }

    if metrics.isMediaLayout {
      let mediaFrame = CGRect(
        x: bubbleX + bubbleHorizontalPadding,
        y: bubbleY + bubbleTopPadding,
        width: metrics.contentWidth,
        height: metrics.mediaHeight
      )
      mediaContainerView.frame = mediaFrame
      messageLabel.frame = .zero
      metaContainerView.frame = CGRect(
        x: bubbleX + bubbleWidth - bubbleHorizontalPadding - metrics.metaWidth,
        y: mediaFrame.maxY + bubbleMetaTopSpacing,
        width: metrics.metaWidth,
        height: bubbleMetaHeight
      )
      mediaProgressOverlayView.frame = mediaContainerView.bounds
      layoutMediaSubviews(for: row, in: mediaContainerView.bounds)
    } else {
      mediaContainerView.frame = .zero
      messageLabel.frame = CGRect(
        x: bubbleX + bubbleHorizontalPadding,
        y: bubbleY + bubbleTopPadding + max(0.0, metrics.bodyHeight - metrics.textHeight),
        width: metrics.messageWidth,
        height: metrics.textHeight
      )
      metaContainerView.frame = CGRect(
        x: messageLabel.frame.maxX + bubbleMetaInlineSpacing,
        y: bubbleY + bubbleTopPadding + metrics.bodyHeight - bubbleMetaHeight,
        width: metrics.metaWidth,
        height: bubbleMetaHeight
      )
    }
    layoutMetaLabels(for: row)

    if !reactionPillView.isHidden {
      let reactionSize = CGSize(width: 38.0, height: 28.0)
      reactionLabel.frame = CGRect(
        x: 0, y: 0, width: reactionSize.width, height: reactionSize.height)

      let rx = row.isMe ? bubbleX + bubbleWidth - reactionSize.width + 4.0 : bubbleX - 4.0
      let ry = bubbleY + bubbleHeight - 12.0
      reactionPillView.frame = CGRect(
        x: rx, y: ry, width: reactionSize.width, height: reactionSize.height)
    }

    CATransaction.commit()
  }

  private func configureMediaPresentation(
    for row: ChatListRow, textColor: UIColor, metaColor: UIColor
  ) {
    mediaPrimaryIconView.isHidden = true
    mediaVoiceButtonView.isHidden = true
    mediaTitleLabel.isHidden = true
    mediaDetailLabel.isHidden = true
    mediaWaveformView.isHidden = true
    mediaDurationBadge.isHidden = true
    mediaPrimaryIconView.image = nil
    mediaTitleLabel.text = nil
    mediaDetailLabel.text = nil
    mediaDurationBadge.text = nil
    mediaWaveformView.setWaveform(nil)

    mediaTitleLabel.textColor = textColor
    mediaTitleLabel.textAlignment = .left
    mediaTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    mediaDetailLabel.textColor = metaColor
    mediaDetailLabel.textAlignment = .right
    mediaDetailLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
    mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.16)

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
      mediaDetailLabel.text = formatBubbleDuration(seconds: row.duration)
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

    case .video:
      mediaPrimaryIconView.isHidden = false
      mediaPrimaryIconView.image = UIImage(systemName: "play.fill")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 26, weight: .bold))
      if row.duration != nil {
        mediaDurationBadge.isHidden = false
        mediaDurationBadge.text = "  \(formatBubbleDuration(seconds: row.duration))  "
      }
      mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.35)

    case .videoNote:
      mediaPrimaryIconView.isHidden = false
      mediaPrimaryIconView.image = UIImage(systemName: "play.fill")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 30, weight: .bold))
      if row.duration != nil {
        mediaDurationBadge.isHidden = false
        mediaDurationBadge.text = "  \(formatBubbleDuration(seconds: row.duration))  "
      }
      mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.4)

    case .media:
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
      }
      mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.28)

    case .text:
      break
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
  }

  private func layoutMediaSubviews(for row: ChatListRow, in bounds: CGRect) {
    let width = bounds.width
    let height = bounds.height

    let cornerRadius: CGFloat
    switch row.visualKind {
    case .videoNote:
      cornerRadius = floor(min(width, height) * 0.5)
    case .voice:
      cornerRadius = 10.0
    default:
      cornerRadius = 12.0
    }

    mediaContainerView.layer.cornerRadius = cornerRadius
    mediaProgressOverlayView.layer.cornerRadius = cornerRadius

    mediaPrimaryIconView.frame = .zero
    mediaVoiceButtonView.frame = .zero
    mediaWaveformView.frame = .zero
    mediaTitleLabel.frame = .zero
    mediaDetailLabel.frame = .zero
    mediaDurationBadge.frame = .zero

    switch row.visualKind {
    case .voice:
      let insetX: CGFloat = 4.0
      let buttonSize: CGFloat = 44.0
      mediaVoiceButtonView.frame = CGRect(
        x: insetX,
        y: floor((height - buttonSize) * 0.5),
        width: buttonSize,
        height: buttonSize
      )
      let textStartX = mediaVoiceButtonView.frame.maxX + 10.0
      let rightInset: CGFloat = 8.0
      let waveY: CGFloat = 10.0
      let waveHeight: CGFloat = 16.0
      mediaDetailLabel.frame = CGRect(
        x: textStartX,
        y: waveY + waveHeight + 2.0,
        width: 56.0,
        height: 14.0
      )
      mediaWaveformView.frame = CGRect(
        x: textStartX,
        y: waveY,
        width: max(1.0, width - textStartX - rightInset),
        height: waveHeight
      )

    case .video, .videoNote, .media:
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
      if !mediaTitleLabel.isHidden && row.visualKind == .media {
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

  @objc private func handleVoiceTap() {
    guard let row, row.visualKind == .voice else { return }
    if let onVoiceBubbleTap {
      onVoiceBubbleTap(row)
      return
    }
    VoiceBubblePlaybackCoordinator.shared.toggle(
      cell: self, messageId: row.messageId, mediaURL: row.mediaUrl
    )
  }

  fileprivate func applyVoicePlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat) {
    mediaVoiceButtonView.setPlaybackState(isPlaying: isPlaying, progress: progress)
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
    place(statusLabel, width: bubbleStatusSlotWidth, height: bubbleStatusSlotHeight, centered: true)
  }

  private func configureStatus(for row: ChatListRow, baseColor: UIColor) {
    statusLabel.text = nil
    statusLabel.textColor = baseColor
    statusLabel.font = bubbleMetaStatusFont
    statusLabel.isHidden = false

    guard row.isMe else {
      return
    }

    switch row.status?.lowercased() {
    case "pending":
      statusLabel.font = bubbleMetaPendingFont
      statusLabel.text = "◷"
    case "sent":
      statusLabel.text = "✓"
    case "delivered":
      statusLabel.text = "✓✓"
    case "read":
      statusLabel.text = "✓✓"
      statusLabel.textColor = UIColor(red: 0.0, green: 0.64, blue: 1.0, alpha: 1.0)
    case "error":
      statusLabel.text = "!"
      statusLabel.textColor = UIColor(red: 1.0, green: 0.48, blue: 0.48, alpha: 1.0)
    default:
      break
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

  func bubbleSnapshotView(in view: UIView) -> UIView? {
    guard let row, row.kind == .message else {
      return nil
    }
    contentView.layoutIfNeeded()

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

    guard
      let snapshot = contentView.resizableSnapshotView(
        from: captureRect,
        afterScreenUpdates: false,
        withCapInsets: .zero
      )
    else {
      return nil
    }

    snapshot.frame = contentView.convert(captureRect, to: view)
    snapshot.clipsToBounds = false
    return snapshot
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
    let metaWasHidden = metaContainerView.isHidden

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    messageLabel.isHidden = true
    mediaContainerView.isHidden = true
    metaContainerView.isHidden = true
    contentView.layoutIfNeeded()
    CATransaction.commit()

    defer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      messageLabel.isHidden = messageWasHidden
      mediaContainerView.isHidden = mediaWasHidden
      metaContainerView.isHidden = metaWasHidden
      contentView.layoutIfNeeded()
      CATransaction.commit()
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

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    clipsToBounds = false

    addSubview(blurView)
    layer.addSublayer(gradientLayer)
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    layer.addSublayer(fillLayer)
    layer.mask = tailMaskLayer
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(isMe: Bool, visible: Bool, appearance: ChatListAppearance) {
    currentIsMe = isMe
    let style = bubbleSurfaceStyle(isMe: isMe, appearance: appearance)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    isHidden = !visible

    // MUST match BubbleBackgroundView.configure exactly so tail+bubble look identical.
    blurView.isHidden = !visible || !style.showsBlur || style.blurAlpha <= 0.001
    if !blurView.isHidden {
      blurView.effect = UIBlurEffect(style: style.blurStyle)
    }
    blurView.alpha = style.blurAlpha
    gradientLayer.isHidden = style.gradientOpacity <= 0.001
    gradientLayer.colors = style.gradientColors
    gradientLayer.opacity = style.gradientOpacity
    fillLayer.fillColor = style.fillColor

    // For 'me': rotate CW 25° (tail curves right at bottom-right of bubble)
    // For 'them': flip horizontally + rotate CCW 25° (tail curves left at bottom-left)
    let angle = (isMe ? 25.0 : -25.0) * (.pi / 180.0)
    let rotate = CGAffineTransform(rotationAngle: angle)
    let flip = CGAffineTransform(scaleX: isMe ? 1.0 : -1.0, y: 1.0)
    transform = flip.concatenating(rotate)
    CATransaction.commit()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.height > 0 else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    blurView.frame = bounds
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
