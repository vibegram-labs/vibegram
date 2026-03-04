import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Reusable UIKit glass morph transition (button -> floating glass panel and back).
/// Designed for over-fullscreen controllers that already manage their own backdrop/content.
final class GlassMorphTransition {
  enum MorphAnchor {
    case bottomLeading
    case bottom
    case bottomTrailing
    case topLeading
    case top
    case topTrailing
    case leading
    case trailing
    case center

    var unitPoint: CGPoint {
      switch self {
      case .bottomLeading: return CGPoint(x: 0, y: 1)
      case .bottom: return CGPoint(x: 0.5, y: 1)
      case .bottomTrailing: return CGPoint(x: 1, y: 1)
      case .topLeading: return CGPoint(x: 0, y: 0)
      case .top: return CGPoint(x: 0.5, y: 0)
      case .topTrailing: return CGPoint(x: 1, y: 0)
      case .leading: return CGPoint(x: 0, y: 0.5)
      case .trailing: return CGPoint(x: 1, y: 0.5)
      case .center: return CGPoint(x: 0.5, y: 0.5)
      }
    }
  }

  struct Config {
    enum ProgressTiming {
      case linear
      case easeOutSine
      case easeInOutSine

      func transform(_ raw: CGFloat) -> CGFloat {
        let t = min(max(raw, 0.0), 1.0)
        switch self {
        case .linear:
          return t
        case .easeOutSine:
          return sin((t * .pi) * 0.5)
        case .easeInOutSine:
          return 0.5 * (1.0 - cos(t * .pi))
        }
      }
    }

    var presentDuration: TimeInterval = 0.38
    var dismissDuration: TimeInterval = 0.26
    var presentDamping: CGFloat = 0.92
    var presentVelocity: CGFloat = 0.06
    var presentProgressTiming: ProgressTiming = .easeOutSine
    var dismissProgressTiming: ProgressTiming = .easeInOutSine
    var contentFadeDelay: TimeInterval = 0.02
    var contentFadeDuration: TimeInterval = 0.18
    var sourceIconFadeOutDuration: TimeInterval = 0.11
    var sourceIconFadeInDuration: TimeInterval = 0.12
    var anchor: MorphAnchor = .topLeading
    var blurRadius: CGFloat = 14.0
    var sourcePhaseEnd: CGFloat = 0.35
    var outerScaleXFactor: CGFloat = 0.35
    var outerScaleYFactor: CGFloat = 0.45
    var outerOffsetY: CGFloat = 75.0
  }

  weak var hostView: UIView?
  weak var sourceView: UIView?
  weak var targetView: UIView?

  var sourceFrameInHost: CGRect?
  var targetCornerRadius: CGFloat = 28
  var config = Config()

  var backdropViews: [UIView] = []
  var contentViews: [UIView] = []

  private var sourceWasHidden = false
  private var sourceWasAlpha: CGFloat = 1.0
  private var sourceWasTransform: CGAffineTransform = .identity
  private var sourceWasUserInteractionEnabled = true
  private var isSourceSuppressed = false
  private var activeDriver: ProgressDriver?
  private let ciContext = CIContext(options: nil)

  private struct MorphOverlay {
    let container: UIView
    let baseGlass: UIVisualEffectView
    let contentSharp: UIImageView
    let contentBlurred: UIImageView
    let labelContainer: UIView
    let labelSharp: UIImageView
    let labelBlurred: UIImageView
  }

  private final class ProgressDriver {
    private var displayLink: CADisplayLink?
    private let start: CFTimeInterval
    private let duration: CFTimeInterval
    private let fromValue: CGFloat
    private let toValue: CGFloat
    private let timing: (CGFloat) -> CGFloat
    private let update: (CGFloat) -> Void
    private let completion: () -> Void

    init(
      duration: TimeInterval,
      from: CGFloat,
      to: CGFloat,
      timing: @escaping (CGFloat) -> CGFloat,
      update: @escaping (CGFloat) -> Void,
      completion: @escaping () -> Void
    ) {
      self.start = CACurrentMediaTime()
      self.duration = max(0.001, duration)
      self.fromValue = from
      self.toValue = to
      self.timing = timing
      self.update = update
      self.completion = completion
    }

    func startAnimating() {
      displayLink = CADisplayLink(target: self, selector: #selector(tick))
      displayLink?.add(to: .main, forMode: .common)
      update(fromValue)
    }

    func cancel() {
      displayLink?.invalidate()
      displayLink = nil
    }

    deinit {
      cancel()
    }

    @objc private func tick() {
      let elapsed = CACurrentMediaTime() - start
      let t = min(1.0, max(0.0, elapsed / duration))
      let easedT = timing(CGFloat(t))
      let value = fromValue + ((toValue - fromValue) * easedT)
      update(value)
      guard t >= 1.0 else { return }
      cancel()
      completion()
    }
  }

  deinit {
    cancelActiveDriver()
    restoreSourceIfNeeded()
  }

  func suppressTargetForInitialState() {
    targetView?.alpha = 0.001
    contentViews.forEach { $0.alpha = 0.0 }
    backdropViews.forEach { $0.alpha = 0.0 }
  }

  func animatePresent(completion: (() -> Void)? = nil) {
    guard let hostView, let targetView else {
      backdropViews.forEach { $0.alpha = 1.0 }
      self.targetView?.alpha = 1.0
      contentViews.forEach { $0.alpha = 1.0 }
      completion?()
      return
    }
    cancelActiveDriver()

    let finalFrame = targetView.frame
    let sourceRect = resolvedSourceRect(in: hostView)

    guard let sourceRect else {
      targetView.alpha = 0.001
      contentViews.forEach { $0.alpha = 0.0 }
      UIView.animate(
        withDuration: config.presentDuration,
        delay: 0,
        usingSpringWithDamping: config.presentDamping,
        initialSpringVelocity: config.presentVelocity,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        self.backdropViews.forEach { $0.alpha = 1.0 }
        targetView.alpha = 1.0
      } completion: { _ in
        UIView.animate(
          withDuration: self.config.contentFadeDuration,
          delay: 0,
          options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
        ) {
          self.contentViews.forEach { $0.alpha = 1.0 }
        } completion: { _ in
          completion?()
        }
      }
      return
    }

    guard
      let sourceImage = sourceImage(in: hostView, sourceRect: sourceRect),
      let targetImage = snapshotImage(of: targetView, forceVisible: true)
    else {
      fallbackPresent(targetView: targetView, completion: completion)
      return
    }

    let sourceBlurred = blurredImage(sourceImage, radius: config.blurRadius) ?? sourceImage
    let targetBlurred = blurredImage(targetImage, radius: config.blurRadius) ?? targetImage
    let overlay = makeProgressOverlay(
      sourceRect: sourceRect,
      hostView: hostView,
      sourceImage: sourceImage,
      sourceBlurred: sourceBlurred,
      targetImage: targetImage,
      targetBlurred: targetBlurred
    )

    suppressSourceIfNeeded()
    targetView.alpha = 0.001
    contentViews.forEach { $0.alpha = 0.0 }
    backdropViews.forEach { $0.alpha = 0.0 }
    applyMorphProgress(
      progress: 0.0,
      overlay: overlay,
      sourceRect: sourceRect,
      targetRect: finalFrame
    )

    runProgress(
      from: 0.0,
      to: 1.0,
      duration: config.presentDuration,
      timing: config.presentProgressTiming,
      update: { [weak self] progress in
        guard let self else { return }
        self.applyMorphProgress(
          progress: progress,
          overlay: overlay,
          sourceRect: sourceRect,
          targetRect: finalFrame
        )
      },
      completion: { [weak self] in
        guard let self else { return }
        overlay.container.removeFromSuperview()
        self.backdropViews.forEach { $0.alpha = 1.0 }
        targetView.alpha = 1.0
        self.contentViews.forEach { $0.alpha = 1.0 }
        completion?()
      }
    )
  }

  func animateDismiss(fallbackOffsetY: CGFloat = 24, completion: @escaping () -> Void) {
    guard let hostView, let targetView else {
      cancelActiveDriver()
      restoreSourceIfNeeded()
      completion()
      return
    }
    cancelActiveDriver()

    let sourceRect = resolvedSourceRect(in: hostView)
    let targetFrame = targetView.frame

    // When source is gone/unavailable, fall back to fade + small drop.
    guard let sourceRect else {
      UIView.animate(
        withDuration: config.dismissDuration,
        delay: 0,
        options: [.curveEaseInOut, .beginFromCurrentState]
      ) {
        self.backdropViews.forEach { $0.alpha = 0.0 }
        self.contentViews.forEach { $0.alpha = 0.0 }
        targetView.alpha = 0.0
        targetView.frame = targetFrame.offsetBy(dx: 0, dy: fallbackOffsetY)
      } completion: { _ in
        self.restoreSourceIfNeeded()
        completion()
      }
      return
    }

    guard
      let sourceImage = sourceImage(in: hostView, sourceRect: sourceRect),
      let targetImage = snapshotImage(of: targetView, forceVisible: true)
    else {
      fallbackDismiss(
        targetView: targetView, targetFrame: targetFrame, fallbackOffsetY: fallbackOffsetY
      ) {
        completion()
      }
      return
    }

    let sourceBlurred = blurredImage(sourceImage, radius: config.blurRadius) ?? sourceImage
    let targetBlurred = blurredImage(targetImage, radius: config.blurRadius) ?? targetImage
    let overlay = makeProgressOverlay(
      sourceRect: sourceRect,
      hostView: hostView,
      sourceImage: sourceImage,
      sourceBlurred: sourceBlurred,
      targetImage: targetImage,
      targetBlurred: targetBlurred
    )

    targetView.alpha = 0.001
    contentViews.forEach { $0.alpha = 0.0 }
    backdropViews.forEach { $0.alpha = 1.0 }
    applyMorphProgress(
      progress: 1.0,
      overlay: overlay,
      sourceRect: sourceRect,
      targetRect: targetFrame
    )

    runProgress(
      from: 1.0,
      to: 0.0,
      duration: config.dismissDuration,
      timing: config.dismissProgressTiming,
      update: { [weak self] progress in
        guard let self else { return }
        self.applyMorphProgress(
          progress: progress,
          overlay: overlay,
          sourceRect: sourceRect,
          targetRect: targetFrame
        )
      },
      completion: { [weak self] in
        guard let self else { return }
        overlay.container.removeFromSuperview()
        self.backdropViews.forEach { $0.alpha = 0.0 }
        self.restoreSourceIfNeeded()
        completion()
      }
    )
  }

  private func resolvedSourceRect(in hostView: UIView) -> CGRect? {
    if let sourceView, let sourceSuperview = sourceView.superview {
      return sourceSuperview.convert(sourceView.frame, to: hostView)
    }
    return sourceFrameInHost
  }

  private func suppressSourceIfNeeded() {
    guard let sourceView, !isSourceSuppressed else { return }
    sourceWasHidden = sourceView.isHidden
    sourceWasAlpha = sourceView.alpha
    sourceWasTransform = sourceView.transform
    sourceWasUserInteractionEnabled = sourceView.isUserInteractionEnabled
    sourceView.isHidden = false
    sourceView.alpha = 0.0
    sourceView.transform = sourceWasTransform
    sourceView.isUserInteractionEnabled = false
    isSourceSuppressed = true
  }

  private func restoreSourceIfNeeded() {
    guard let sourceView, isSourceSuppressed else { return }
    sourceView.isHidden = sourceWasHidden
    sourceView.alpha = sourceWasAlpha
    sourceView.transform = sourceWasTransform
    sourceView.isUserInteractionEnabled = sourceWasUserInteractionEnabled
    isSourceSuppressed = false
  }

  private func runProgress(
    from: CGFloat,
    to: CGFloat,
    duration: TimeInterval,
    timing: Config.ProgressTiming,
    update: @escaping (CGFloat) -> Void,
    completion: @escaping () -> Void
  ) {
    cancelActiveDriver()
    let driver = ProgressDriver(
      duration: duration,
      from: from,
      to: to,
      timing: timing.transform,
      update: update,
      completion: { [weak self] in
        self?.activeDriver = nil
        completion()
      }
    )
    activeDriver = driver
    driver.startAnimating()
  }

  private func cancelActiveDriver() {
    activeDriver?.cancel()
    activeDriver = nil
  }

  private func fallbackPresent(targetView: UIView, completion: (() -> Void)?) {
    targetView.alpha = 0.001
    contentViews.forEach { $0.alpha = 0.0 }
    backdropViews.forEach { $0.alpha = 0.0 }
    UIView.animate(
      withDuration: config.presentDuration,
      delay: 0,
      usingSpringWithDamping: config.presentDamping,
      initialSpringVelocity: config.presentVelocity,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.backdropViews.forEach { $0.alpha = 1.0 }
      targetView.alpha = 1.0
      self.contentViews.forEach { $0.alpha = 1.0 }
    } completion: { _ in
      completion?()
    }
  }

  private func fallbackDismiss(
    targetView: UIView,
    targetFrame: CGRect,
    fallbackOffsetY: CGFloat,
    completion: @escaping () -> Void
  ) {
    UIView.animate(
      withDuration: config.dismissDuration,
      delay: 0,
      options: [.curveEaseInOut, .beginFromCurrentState]
    ) {
      self.backdropViews.forEach { $0.alpha = 0.0 }
      self.contentViews.forEach { $0.alpha = 0.0 }
      targetView.alpha = 0.0
      targetView.frame = targetFrame.offsetBy(dx: 0, dy: fallbackOffsetY)
    } completion: { _ in
      self.restoreSourceIfNeeded()
      completion()
    }
  }

  private func makeProgressOverlay(
    sourceRect: CGRect,
    hostView: UIView,
    sourceImage: UIImage,
    sourceBlurred: UIImage,
    targetImage: UIImage,
    targetBlurred: UIImage
  ) -> MorphOverlay {
    let container = UIView(frame: sourceRect)
    container.backgroundColor = .clear
    container.clipsToBounds = true
    container.layer.cornerCurve = .continuous
    container.layer.cornerRadius = max(12.0, sourceRect.height * 0.5)

    let baseGlass = UIVisualEffectView(effect: nil)
    baseGlass.isUserInteractionEnabled = false
    baseGlass.frame = container.bounds
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      baseGlass.effect = effect
      baseGlass.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    } else {
      baseGlass.effect = UIBlurEffect(style: .systemMaterialDark)
      baseGlass.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    }

    let contentSharp = UIImageView(image: targetImage)
    contentSharp.contentMode = .scaleToFill
    contentSharp.frame = container.bounds

    let contentBlurred = UIImageView(image: targetBlurred)
    contentBlurred.contentMode = .scaleToFill
    contentBlurred.frame = container.bounds

    let labelContainer = UIView(frame: CGRect(origin: .zero, size: sourceRect.size))
    labelContainer.backgroundColor = .clear
    labelContainer.clipsToBounds = false

    let labelSharp = UIImageView(image: sourceImage)
    labelSharp.contentMode = .scaleToFill
    labelSharp.frame = labelContainer.bounds

    let labelBlurred = UIImageView(image: sourceBlurred)
    labelBlurred.contentMode = .scaleToFill
    labelBlurred.frame = labelContainer.bounds

    labelContainer.addSubview(labelSharp)
    labelContainer.addSubview(labelBlurred)

    container.addSubview(baseGlass)
    container.addSubview(contentSharp)
    container.addSubview(contentBlurred)
    container.addSubview(labelContainer)
    hostView.addSubview(container)

    return MorphOverlay(
      container: container,
      baseGlass: baseGlass,
      contentSharp: contentSharp,
      contentBlurred: contentBlurred,
      labelContainer: labelContainer,
      labelSharp: labelSharp,
      labelBlurred: labelBlurred
    )
  }

  private func applyMorphProgress(
    progress rawProgress: CGFloat,
    overlay: MorphOverlay,
    sourceRect: CGRect,
    targetRect: CGRect
  ) {
    let progress = clamp(rawProgress)
    let sourcePhase = max(0.0001, min(config.sourcePhaseEnd, 0.9999))
    let labelOpacity = min(progress / sourcePhase, 1.0)
    let contentOpacity = min(max(progress - sourcePhase, 0.0) / (1.0 - sourcePhase), 1.0)
    let blurProgress = progress > 0.5 ? ((1.0 - progress) / 0.5) : (progress / 0.5)

    let widthDiff = targetRect.width - sourceRect.width
    let heightDiff = targetRect.height - sourceRect.height
    let currentSize = CGSize(
      width: sourceRect.width + (widthDiff * contentOpacity),
      height: sourceRect.height + (heightDiff * contentOpacity)
    )
    let frame = frame(
      size: currentSize,
      sourceRect: sourceRect,
      targetRect: targetRect,
      progress: contentOpacity,
      anchor: config.anchor
    )
    overlay.container.transform = .identity
    overlay.container.frame = frame.integral
    overlay.container.layer.cornerRadius = lerp(
      from: max(12.0, sourceRect.height * 0.5),
      to: targetCornerRadius,
      progress: contentOpacity
    )

    let outerScaleX = 1.0 - (blurProgress * config.outerScaleXFactor)
    let outerScaleY = 1.0 + (blurProgress * config.outerScaleYFactor)
    let outerScaleTransform = anchoredScaleTransform(
      scaleX: outerScaleX,
      scaleY: outerScaleY,
      bounds: overlay.container.bounds,
      anchor: config.anchor.unitPoint
    )
    let outerOffsetY = outerOffset(for: config.anchor) * blurProgress
    overlay.container.transform = outerScaleTransform.concatenating(
      CGAffineTransform(translationX: 0, y: outerOffsetY)
    )

    let bounds = overlay.container.bounds
    overlay.baseGlass.frame = bounds
    overlay.contentSharp.frame = bounds
    overlay.contentBlurred.frame = bounds

    let minAspectScale = min(
      sourceRect.width / max(targetRect.width, 1), sourceRect.height / max(targetRect.height, 1))
    let contentScale = minAspectScale + ((1.0 - minAspectScale) * progress)
    let contentTransform = anchoredScaleTransform(
      scaleX: contentScale,
      scaleY: contentScale,
      bounds: bounds,
      anchor: config.anchor.unitPoint
    )
    overlay.contentSharp.transform = contentTransform
    overlay.contentBlurred.transform = contentTransform
    overlay.contentSharp.alpha = contentOpacity * (1.0 - blurProgress)
    overlay.contentBlurred.alpha = contentOpacity * blurProgress

    let labelSize = sourceRect.size
    overlay.labelContainer.frame = itemFrame(in: bounds, itemSize: labelSize, anchor: config.anchor)
    overlay.labelSharp.frame = overlay.labelContainer.bounds
    overlay.labelBlurred.frame = overlay.labelContainer.bounds
    overlay.labelSharp.alpha = (1.0 - labelOpacity) * (1.0 - blurProgress)
    overlay.labelBlurred.alpha = (1.0 - labelOpacity) * blurProgress

    backdropViews.forEach { $0.alpha = progress }
  }

  private func frame(
    size: CGSize,
    sourceRect: CGRect,
    targetRect: CGRect,
    progress: CGFloat,
    anchor: MorphAnchor
  ) -> CGRect {
    let t = clamp(progress)
    let anchorPoint = anchor.unitPoint
    let sourceAnchor = CGPoint(
      x: sourceRect.minX + (sourceRect.width * anchorPoint.x),
      y: sourceRect.minY + (sourceRect.height * anchorPoint.y)
    )
    let targetAnchor = CGPoint(
      x: targetRect.minX + (targetRect.width * anchorPoint.x),
      y: targetRect.minY + (targetRect.height * anchorPoint.y)
    )
    let mixedAnchor = CGPoint(
      x: sourceAnchor.x + ((targetAnchor.x - sourceAnchor.x) * t),
      y: sourceAnchor.y + ((targetAnchor.y - sourceAnchor.y) * t)
    )
    return CGRect(
      x: mixedAnchor.x - (size.width * anchorPoint.x),
      y: mixedAnchor.y - (size.height * anchorPoint.y),
      width: size.width,
      height: size.height
    )
  }

  private func itemFrame(in bounds: CGRect, itemSize: CGSize, anchor: MorphAnchor) -> CGRect {
    let p = anchor.unitPoint
    let origin = CGPoint(
      x: (bounds.width - itemSize.width) * p.x,
      y: (bounds.height - itemSize.height) * p.y
    )
    return CGRect(origin: origin, size: itemSize)
  }

  private func anchoredScaleTransform(
    scaleX: CGFloat,
    scaleY: CGFloat,
    bounds: CGRect,
    anchor: CGPoint
  ) -> CGAffineTransform {
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let anchorPoint = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
    let tx = (1.0 - scaleX) * (anchorPoint.x - center.x)
    let ty = (1.0 - scaleY) * (anchorPoint.y - center.y)
    return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scaleX, y: scaleY)
  }

  private func sourceImage(in hostView: UIView, sourceRect: CGRect) -> UIImage? {
    if let sourceView, let image = snapshotImage(of: sourceView, forceVisible: false) {
      return image
    }
    return snapshotImage(in: hostView, rect: sourceRect)
  }

  private func snapshotImage(of view: UIView, forceVisible: Bool) -> UIImage? {
    let originalAlpha = view.alpha
    let originalHidden = view.isHidden
    if forceVisible {
      view.isHidden = false
      view.alpha = 1.0
      view.superview?.layoutIfNeeded()
      view.layoutIfNeeded()
    }
    defer {
      if forceVisible {
        view.alpha = originalAlpha
        view.isHidden = originalHidden
      }
    }
    let renderer = UIGraphicsImageRenderer(
      size: view.bounds.size,
      format: rendererFormat(scale: view.window?.screen.scale ?? UIScreen.main.scale)
    )
    return renderer.image { _ in
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
  }

  private func snapshotImage(in view: UIView, rect: CGRect) -> UIImage? {
    guard rect.width > 0, rect.height > 0 else { return nil }
    let renderer = UIGraphicsImageRenderer(
      size: rect.size,
      format: rendererFormat(scale: view.window?.screen.scale ?? UIScreen.main.scale)
    )
    return renderer.image { _ in
      let drawRect = CGRect(
        x: -rect.minX, y: -rect.minY, width: view.bounds.width, height: view.bounds.height)
      view.drawHierarchy(in: drawRect, afterScreenUpdates: true)
    }
  }

  private func blurredImage(_ image: UIImage, radius: CGFloat) -> UIImage? {
    guard let ciImage = CIImage(image: image) else { return nil }
    let filter = CIFilter.gaussianBlur()
    filter.inputImage = ciImage
    filter.radius = Float(radius)
    guard let output = filter.outputImage else { return nil }
    let cropped = output.cropped(to: ciImage.extent)
    guard let cgImage = ciContext.createCGImage(cropped, from: ciImage.extent) else { return nil }
    return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
  }

  private func rendererFormat(scale: CGFloat) -> UIGraphicsImageRendererFormat {
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    format.scale = scale
    return format
  }

  private func clamp(_ value: CGFloat) -> CGFloat {
    min(max(value, 0.0), 1.0)
  }

  private func lerp(from: CGFloat, to: CGFloat, progress: CGFloat) -> CGFloat {
    from + ((to - from) * clamp(progress))
  }

  private func outerOffset(for anchor: MorphAnchor) -> CGFloat {
    switch anchor {
    case .bottom, .bottomLeading, .bottomTrailing:
      return -config.outerOffsetY
    case .top, .topLeading, .topTrailing:
      return config.outerOffsetY
    case .leading, .trailing, .center:
      return 0.0
    }
  }
}
