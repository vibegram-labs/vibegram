import UIKit

/// Reusable UIKit glass morph transition (button -> floating glass panel and back).
/// Designed for over-fullscreen controllers that already manage their own backdrop/content.
final class GlassMorphTransition {
  struct Config {
    var presentDuration: TimeInterval = 0.34
    var dismissDuration: TimeInterval = 0.22
    var presentDamping: CGFloat = 0.88
    var presentVelocity: CGFloat = 0.18
    var contentFadeDelay: TimeInterval = 0.05
    var contentFadeDuration: TimeInterval = 0.20
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
  private var sourceWasUserInteractionEnabled = true
  private var isSourceSuppressed = false

  deinit {
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
        } completion: { _ in completion?() }
      }
      return
    }

    let overlay = makeMorphOverlay(from: sourceRect, in: hostView)
    suppressSourceIfNeeded()
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
      overlay.frame = finalFrame
      overlay.layer.cornerRadius = self.targetCornerRadius
      overlay.subviews.first?.frame = overlay.bounds
      targetView.alpha = 1.0
    } completion: { _ in
      UIView.animate(
        withDuration: self.config.contentFadeDuration,
        delay: self.config.contentFadeDelay,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        self.contentViews.forEach { $0.alpha = 1.0 }
        overlay.alpha = 0.0
      } completion: { _ in
        overlay.removeFromSuperview()
        completion?()
      }
    }
  }

  func animateDismiss(fallbackOffsetY: CGFloat = 24, completion: @escaping () -> Void) {
    guard let hostView, let targetView else {
      restoreSourceIfNeeded()
      completion()
      return
    }

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

    let overlay = makePanelSnapshotOverlay(from: targetView, in: hostView)
    overlay.frame = targetFrame
    overlay.layer.cornerRadius = targetCornerRadius
    hostView.addSubview(overlay)

    UIView.animate(
      withDuration: config.dismissDuration,
      delay: 0,
      options: [.curveEaseInOut, .beginFromCurrentState]
    ) {
      self.backdropViews.forEach { $0.alpha = 0.0 }
      self.contentViews.forEach { $0.alpha = 0.0 }
      targetView.alpha = 0.001
      overlay.frame = sourceRect
      overlay.layer.cornerRadius = max(12.0, sourceRect.height * 0.5)
      overlay.subviews.first?.frame = overlay.bounds
    } completion: { _ in
      overlay.removeFromSuperview()
      self.restoreSourceIfNeeded()
      completion()
    }
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
    sourceWasUserInteractionEnabled = sourceView.isUserInteractionEnabled
    sourceView.isHidden = true
    sourceView.isUserInteractionEnabled = false
    isSourceSuppressed = true
  }

  private func restoreSourceIfNeeded() {
    guard let sourceView, isSourceSuppressed else { return }
    sourceView.isHidden = sourceWasHidden
    sourceView.isUserInteractionEnabled = sourceWasUserInteractionEnabled
    isSourceSuppressed = false
  }

  private func makeMorphOverlay(from sourceRect: CGRect, in hostView: UIView) -> UIView {
    let overlay = UIView(frame: sourceRect)
    overlay.clipsToBounds = true
    overlay.layer.cornerCurve = .continuous
    overlay.layer.cornerRadius = max(12.0, sourceRect.height * 0.5)
    overlay.backgroundColor = .clear

    let content: UIView
    if let sourceView, let snapshot = sourceView.snapshotView(afterScreenUpdates: false) {
      snapshot.frame = overlay.bounds
      content = snapshot
    } else {
      let fallbackGlass = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
      fallbackGlass.frame = overlay.bounds
      fallbackGlass.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
      content = fallbackGlass
    }
    content.isUserInteractionEnabled = false
    overlay.addSubview(content)

    hostView.addSubview(overlay)
    return overlay
  }

  private func makePanelSnapshotOverlay(from targetView: UIView, in hostView: UIView) -> UIView {
    let frame = targetView.frame
    let overlay = UIView(frame: frame)
    overlay.clipsToBounds = true
    overlay.layer.cornerCurve = .continuous
    overlay.backgroundColor = .clear

    let content = targetView.snapshotView(afterScreenUpdates: false) ?? UIView(frame: overlay.bounds)
    content.frame = overlay.bounds
    content.isUserInteractionEnabled = false
    overlay.addSubview(content)
    return overlay
  }
}
