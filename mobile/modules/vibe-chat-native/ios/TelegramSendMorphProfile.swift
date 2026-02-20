import UIKit

// ---------------------------------------------------------------------------
// TelegramSendMorphProfile: "All in one" handling for the list morph bubbles/input
// ---------------------------------------------------------------------------

public enum TelegramSendMorphProfile {
  static let duration: CFTimeInterval = 0.3

  static let horizontalTiming = CAMediaTimingFunction(
    controlPoints: Float(0.23), Float(1.0), Float(0.32), Float(1.0)
  )
  static let verticalTiming = CAMediaTimingFunction(
    controlPoints: Float(0.19919472913616398), Float(0.010644531250000006),
    Float(0.27920937042459737), Float(0.91025390625)
  )

  // Keep destination bubble partially visible early to avoid a dark "shadow ghost".
  static let bubbleFadeFrom: Float = 0.22
  static let bubbleFadeDelay: CFTimeInterval = 0.0
  static let bubbleFadeDuration: CFTimeInterval = 0.18

  // Text should enter during movement (mid-transition), not only at the end.
  static let bubbleContentFadeDelay: CFTimeInterval = 0.05
  static let bubbleContentFadeDuration: CFTimeInterval = 0.18
  static let bubbleContentMoveDuration: CFTimeInterval = 0.24

  static let sourceBackgroundStartOpacity: Float = 0.84
  static let sourceBackgroundFadeDelay: CFTimeInterval = 0.0
  static let sourceBackgroundFadeDuration: CFTimeInterval = 0.14

  static let sourceTextFadeDelay: CFTimeInterval = 0.05
  static let sourceTextFadeDuration: CFTimeInterval = 0.16
}

final class SendTransitionState: NSObject {
  weak var host: ChatListView?
  let payload: SendTransitionPayload
  let overlayContainer: UIView
  let clippingView: UIView
  let sourceBackgroundSnapshot: UIView
  let bubbleBackgroundSnapshot: UIView
  let destinationContentSnapshot: UIView
  let sourceTextSnapshot: UIView?
  let sourceBackgroundStartFrame: CGRect
  let sourceBackgroundEndFrame: CGRect
  let sourceContentStartFrame: CGRect
  let destinationContentFrame: CGRect
  let sourceScrollOffset: CGFloat

  init(
    host: ChatListView,
    payload: SendTransitionPayload,
    overlayContainer: UIView,
    clippingView: UIView,
    sourceBackgroundSnapshot: UIView,
    bubbleBackgroundSnapshot: UIView,
    destinationContentSnapshot: UIView,
    sourceTextSnapshot: UIView?,
    sourceBackgroundStartFrame: CGRect,
    sourceBackgroundEndFrame: CGRect,
    sourceContentStartFrame: CGRect,
    destinationContentFrame: CGRect,
    sourceScrollOffset: CGFloat
  ) {
    self.host = host
    self.payload = payload
    self.overlayContainer = overlayContainer
    self.clippingView = clippingView
    self.sourceBackgroundSnapshot = sourceBackgroundSnapshot
    self.bubbleBackgroundSnapshot = bubbleBackgroundSnapshot
    self.destinationContentSnapshot = destinationContentSnapshot
    self.sourceTextSnapshot = sourceTextSnapshot
    self.sourceBackgroundStartFrame = sourceBackgroundStartFrame
    self.sourceBackgroundEndFrame = sourceBackgroundEndFrame
    self.sourceContentStartFrame = sourceContentStartFrame
    self.destinationContentFrame = destinationContentFrame
    self.sourceScrollOffset = sourceScrollOffset
    super.init()
  }

  private func addScalarAnimation(
    layer: CALayer,
    keyPath: String,
    from: CGFloat,
    to: CGFloat,
    duration: CFTimeInterval,
    timing: CAMediaTimingFunction,
    key: String,
    additive: Bool = false
  ) {
    let anim = CABasicAnimation(keyPath: keyPath)
    anim.fromValue = from as NSNumber
    anim.toValue = to as NSNumber
    anim.duration = duration
    anim.timingFunction = timing
    anim.isAdditive = additive
    anim.isRemovedOnCompletion = true
    layer.add(anim, forKey: key)
  }

  private func addFrameAnimation(layer: CALayer, from: CGRect, to: CGRect, keyPrefix: String) {
    addScalarAnimation(
      layer: layer, keyPath: "position.x", from: from.midX, to: to.midX,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "\(keyPrefix).positionX")
    addScalarAnimation(
      layer: layer, keyPath: "position.y", from: from.midY, to: to.midY,
      duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
      key: "\(keyPrefix).positionY")
    addScalarAnimation(
      layer: layer, keyPath: "bounds.size.width", from: from.width, to: to.width,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "\(keyPrefix).width")
    addScalarAnimation(
      layer: layer, keyPath: "bounds.size.height", from: from.height, to: to.height,
      duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
      key: "\(keyPrefix).height")
  }

  private func addBoundsPositionAnimation(
    layer: CALayer, startBounds: CGRect, endBounds: CGRect, startPos: CGPoint, endPos: CGPoint,
    keyPrefix: String
  ) {
    addScalarAnimation(
      layer: layer, keyPath: "position.x", from: startPos.x, to: endPos.x,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "\(keyPrefix).posX")
    addScalarAnimation(
      layer: layer, keyPath: "position.y", from: startPos.y, to: endPos.y,
      duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
      key: "\(keyPrefix).posY")
    addScalarAnimation(
      layer: layer, keyPath: "bounds.size.width", from: startBounds.width, to: endBounds.width,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "\(keyPrefix).bgW")
    addScalarAnimation(
      layer: layer, keyPath: "bounds.size.height", from: startBounds.height, to: endBounds.height,
      duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
      key: "\(keyPrefix).bgH")
  }

  func start(sourceRect: CGRect, targetRect: CGRect) {
    overlayContainer.frame = targetRect

    let dx = sourceRect.minX - targetRect.minX
    let dy = sourceRect.maxY - targetRect.maxY

    let animX = CABasicAnimation(keyPath: "position.x")
    animX.fromValue = dx as NSNumber
    animX.toValue = 0.0 as NSNumber
    animX.isAdditive = true
    animX.duration = TelegramSendMorphProfile.duration
    animX.timingFunction = TelegramSendMorphProfile.horizontalTiming
    animX.isRemovedOnCompletion = true
    overlayContainer.layer.add(animX, forKey: "sendTransitionX")

    let animY = CABasicAnimation(keyPath: "position.y")
    animY.fromValue = dy as NSNumber
    animY.toValue = 0.0 as NSNumber
    animY.isAdditive = true
    animY.duration = TelegramSendMorphProfile.duration
    animY.timingFunction = TelegramSendMorphProfile.verticalTiming
    animY.isRemovedOnCompletion = true
    animY.delegate = self
    overlayContainer.layer.add(animY, forKey: "sendTransitionY")

    // Morph the clipping envelope
    let clipStartCorner = min(sourceBackgroundStartFrame.height * 0.5, 22.0)
    let clipEndCorner = min(sourceBackgroundEndFrame.height * 0.5, 18.0)
    clippingView.layer.cornerCurve = .continuous
    clippingView.layer.cornerRadius = clipEndCorner
    clippingView.frame = sourceBackgroundEndFrame
    addFrameAnimation(
      layer: clippingView.layer, from: sourceBackgroundStartFrame, to: sourceBackgroundEndFrame,
      keyPrefix: "clipEnvelope")
    addScalarAnimation(
      layer: clippingView.layer, keyPath: "cornerRadius", from: clipStartCorner, to: clipEndCorner,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.verticalTiming,
      key: "clipEnvelope.cornerRadius")

    // Morph background views inside clipping envelope
    let startBounds = CGRect(origin: .zero, size: sourceBackgroundStartFrame.size)
    let endBounds = CGRect(origin: .zero, size: sourceBackgroundEndFrame.size)
    let startPos = CGPoint(
      x: sourceBackgroundStartFrame.width / 2, y: sourceBackgroundStartFrame.height / 2)
    let endPos = CGPoint(
      x: sourceBackgroundEndFrame.width / 2, y: sourceBackgroundEndFrame.height / 2)

    sourceBackgroundSnapshot.bounds = endBounds
    sourceBackgroundSnapshot.center = endPos
    addBoundsPositionAnimation(
      layer: sourceBackgroundSnapshot.layer, startBounds: startBounds, endBounds: endBounds,
      startPos: startPos, endPos: endPos, keyPrefix: "sourceBgMorph")

    bubbleBackgroundSnapshot.bounds = endBounds
    bubbleBackgroundSnapshot.center = endPos
    addBoundsPositionAnimation(
      layer: bubbleBackgroundSnapshot.layer, startBounds: startBounds, endBounds: endBounds,
      startPos: startPos, endPos: endPos, keyPrefix: "bubbleBgMorph")

    // Destination bubble background crossfade
    bubbleBackgroundSnapshot.layer.opacity = TelegramSendMorphProfile.bubbleFadeFrom
    let backgroundFade = CABasicAnimation(keyPath: "opacity")
    backgroundFade.fromValue = TelegramSendMorphProfile.bubbleFadeFrom
    backgroundFade.toValue = 1.0
    backgroundFade.beginTime = CACurrentMediaTime() + TelegramSendMorphProfile.bubbleFadeDelay
    backgroundFade.duration = TelegramSendMorphProfile.bubbleFadeDuration
    backgroundFade.timingFunction = CAMediaTimingFunction(name: .easeIn)
    backgroundFade.fillMode = .backwards
    backgroundFade.isRemovedOnCompletion = false
    bubbleBackgroundSnapshot.layer.add(backgroundFade, forKey: "bubbleBackgroundFadeIn")
    bubbleBackgroundSnapshot.layer.opacity = 1.0

    // Source background crossfade out
    sourceBackgroundSnapshot.layer.opacity = TelegramSendMorphProfile.sourceBackgroundStartOpacity
    let sourceBgFade = CABasicAnimation(keyPath: "opacity")
    sourceBgFade.fromValue = TelegramSendMorphProfile.sourceBackgroundStartOpacity
    sourceBgFade.toValue = 0.0
    sourceBgFade.beginTime =
      CACurrentMediaTime() + TelegramSendMorphProfile.sourceBackgroundFadeDelay
    sourceBgFade.duration = TelegramSendMorphProfile.sourceBackgroundFadeDuration
    sourceBgFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    sourceBgFade.fillMode = .backwards
    sourceBgFade.isRemovedOnCompletion = false
    sourceBackgroundSnapshot.layer.add(sourceBgFade, forKey: "sourceBgFade")
    sourceBackgroundSnapshot.layer.opacity = 0.0

    // Source text fade out
    if let sourceTextSnapshot {
      sourceTextSnapshot.frame = sourceContentStartFrame
      sourceTextSnapshot.layer.opacity = 1.0
      let textDeltaX = destinationContentFrame.minX - sourceContentStartFrame.minX
      let textDeltaY = destinationContentFrame.minY - sourceContentStartFrame.minY
      addScalarAnimation(
        layer: sourceTextSnapshot.layer, keyPath: "position.x", from: 0.0, to: textDeltaX,
        duration: TelegramSendMorphProfile.bubbleContentMoveDuration,
        timing: TelegramSendMorphProfile.horizontalTiming, key: "sourceText.positionX",
        additive: true)
      addScalarAnimation(
        layer: sourceTextSnapshot.layer, keyPath: "position.y", from: 0.0, to: textDeltaY,
        duration: TelegramSendMorphProfile.bubbleContentMoveDuration,
        timing: TelegramSendMorphProfile.verticalTiming, key: "sourceText.positionY",
        additive: true)
      let textFadeOut = CABasicAnimation(keyPath: "opacity")
      textFadeOut.fromValue = 1.0
      textFadeOut.toValue = 0.0
      textFadeOut.beginTime = CACurrentMediaTime() + TelegramSendMorphProfile.sourceTextFadeDelay
      textFadeOut.duration = TelegramSendMorphProfile.sourceTextFadeDuration
      textFadeOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
      textFadeOut.fillMode = .backwards
      textFadeOut.isRemovedOnCompletion = false
      sourceTextSnapshot.layer.add(textFadeOut, forKey: "sourceTextFadeOut")
      sourceTextSnapshot.layer.opacity = 0.0
    }

    destinationContentSnapshot.frame = destinationContentFrame
    destinationContentSnapshot.layer.opacity = 0.0

    let widthDifference = sourceBackgroundEndFrame.width - sourceBackgroundStartFrame.width
    let rawOffsetX =
      (sourceContentStartFrame.minX - destinationContentFrame.minX) - (widthDifference * 0.22)
    let rawOffsetY = (sourceContentStartFrame.minY - destinationContentFrame.minY) - sourceScrollOffset
    let offsetX = max(-180.0, min(180.0, rawOffsetX))
    let offsetY = max(-120.0, min(120.0, rawOffsetY))

    addScalarAnimation(
      layer: destinationContentSnapshot.layer, keyPath: "position.x", from: offsetX, to: 0.0,
      duration: TelegramSendMorphProfile.bubbleContentMoveDuration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "destContent.positionX",
      additive: true)
    addScalarAnimation(
      layer: destinationContentSnapshot.layer, keyPath: "position.y", from: offsetY, to: 0.0,
      duration: TelegramSendMorphProfile.bubbleContentMoveDuration,
      timing: TelegramSendMorphProfile.verticalTiming,
      key: "destContent.positionY", additive: true)

    let contentFadeIn = CABasicAnimation(keyPath: "opacity")
    contentFadeIn.fromValue = 0.0
    contentFadeIn.toValue = 1.0
    contentFadeIn.beginTime = CACurrentMediaTime() + TelegramSendMorphProfile.bubbleContentFadeDelay
    contentFadeIn.duration = TelegramSendMorphProfile.bubbleContentFadeDuration
    contentFadeIn.timingFunction = CAMediaTimingFunction(name: .easeIn)
    contentFadeIn.fillMode = .backwards
    contentFadeIn.isRemovedOnCompletion = false
    destinationContentSnapshot.layer.add(contentFadeIn, forKey: "destContentFadeIn")
    destinationContentSnapshot.layer.opacity = 1.0
  }

  func compensateScroll(targetRect: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    overlayContainer.frame = targetRect
    CATransaction.commit()
  }

  func invalidate() {
    overlayContainer.layer.removeAllAnimations()
    clippingView.layer.removeAllAnimations()
    sourceBackgroundSnapshot.layer.removeAllAnimations()
    bubbleBackgroundSnapshot.layer.removeAllAnimations()
    destinationContentSnapshot.layer.removeAllAnimations()
    sourceTextSnapshot?.layer.removeAllAnimations()
  }
}

extension SendTransitionState: CAAnimationDelegate {
  func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
    host?.completeTransition(self)
  }
}

enum SendTransitionOverlayFactory {
  struct Result {
    let container: UIView
    let clippingView: UIView
    let sourceBackgroundSnapshot: UIView
    let bubbleBackgroundSnapshot: UIView
    let destinationContentSnapshot: UIView
    let sourceTextSnapshot: UIView?
    let sourceBackgroundStartFrame: CGRect
    let sourceBackgroundEndFrame: CGRect
    let sourceContentStartFrame: CGRect
    let destinationContentFrame: CGRect
    let sourceScrollOffset: CGFloat
    let sourceRect: CGRect
  }

  private static func mapSourceRectToContainer(
    _ sourceRect: CGRect, motionSourceRect: CGRect, targetRect: CGRect
  ) -> CGRect {
    let startContainerOriginY = motionSourceRect.maxY - targetRect.height
    return CGRect(
      x: sourceRect.minX - motionSourceRect.minX,
      y: sourceRect.minY - startContainerOriginY,
      width: max(1.0, sourceRect.width),
      height: max(1.0, sourceRect.height)
    )
  }

  private static func makeRenderedSnapshotView(
    from sourceView: UIView, captureRect: CGRect, targetFrame: CGRect
  ) -> UIView? {
    guard captureRect.width > 1.0, captureRect.height > 1.0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
    let image = renderer.image { context in
      context.cgContext.translateBy(x: -captureRect.minX, y: -captureRect.minY)
      if !sourceView.drawHierarchy(in: sourceView.bounds, afterScreenUpdates: true) {
        sourceView.layer.render(in: context.cgContext)
      }
    }
    let imageView = UIImageView(image: image)
    imageView.frame = targetFrame
    imageView.backgroundColor = .clear
    imageView.isOpaque = false
    imageView.clipsToBounds = false
    return imageView
  }

  private static func makeContentSnapshot(
    snapshotCell: ChatListCell, captureRect: CGRect, targetFrame: CGRect
  ) -> UIView? {
    let wasBubbleHidden = snapshotCell.bubbleView.isHidden
    let wasTailHidden = snapshotCell.tailView.isHidden
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    snapshotCell.bubbleView.isHidden = true
    snapshotCell.tailView.isHidden = true
    snapshotCell.contentView.layoutIfNeeded()
    CATransaction.commit()
    defer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      snapshotCell.bubbleView.isHidden = wasBubbleHidden
      snapshotCell.tailView.isHidden = wasTailHidden
      snapshotCell.contentView.layoutIfNeeded()
      CATransaction.commit()
    }
    if let rendered = makeRenderedSnapshotView(
      from: snapshotCell.contentView, captureRect: captureRect, targetFrame: targetFrame)
    {
      return rendered
    }
    if let snapshot = snapshotCell.contentView.resizableSnapshotView(
      from: captureRect, afterScreenUpdates: false, withCapInsets: .zero)
    {
      snapshot.frame = targetFrame
      return snapshot
    }
    return nil
  }

  static func make(
    appearance: ChatListAppearance,
    snapshotCell: ChatListCell,
    targetBubbleRect: CGRect,
    payload: SendTransitionPayload,
    hostView: UIView
  ) -> Result {
    let motionSourceRect = payload.resolvedSourceBackgroundRect.integral
    let container = UIView()
    container.isUserInteractionEnabled = false
    container.clipsToBounds = false

    guard let captureRects = snapshotCell.transitionBubbleCaptureRects() else {
      let fallbackBg = UIView(frame: CGRect(origin: .zero, size: targetBubbleRect.size))
      let fallbackBubbleColor =
        appearance.bubbleMeGradient.first
        ?? appearance.bubbleThemColor
      fallbackBg.backgroundColor = fallbackBubbleColor.withAlphaComponent(1.0)
      fallbackBg.layer.cornerRadius = 18.0
      fallbackBg.layer.cornerCurve = .continuous

      let sourceBg = UIView(frame: fallbackBg.bounds)
      sourceBg.backgroundColor = fallbackBubbleColor.withAlphaComponent(1.0)
      sourceBg.layer.cornerRadius = 18.0
      sourceBg.layer.cornerCurve = .continuous

      let fallbackContentFrame = fallbackBg.frame.insetBy(dx: 12, dy: 9)
      let fallbackContent = UILabel(frame: fallbackContentFrame)
      fallbackContent.font = UIFont.systemFont(ofSize: 16)
      fallbackContent.textColor = appearance.textColorThem.withAlphaComponent(0.95)
      fallbackContent.text = payload.text
      fallbackContent.numberOfLines = 0

      let clippingView = UIView(frame: fallbackBg.frame)
      clippingView.clipsToBounds = true
      clippingView.addSubview(sourceBg)
      clippingView.addSubview(fallbackBg)
      container.addSubview(clippingView)
      container.addSubview(fallbackContent)

      return Result(
        container: container,
        clippingView: clippingView,
        sourceBackgroundSnapshot: sourceBg,
        bubbleBackgroundSnapshot: fallbackBg,
        destinationContentSnapshot: fallbackContent,
        sourceTextSnapshot: nil,
        sourceBackgroundStartFrame: fallbackBg.frame,
        sourceBackgroundEndFrame: fallbackBg.frame,
        sourceContentStartFrame: fallbackContentFrame,
        destinationContentFrame: fallbackContentFrame,
        sourceScrollOffset: payload.sourceScrollOffset,
        sourceRect: payload.resolvedSourceBackgroundRect
      )
    }

    let bubbleBodyRect = captureRects.bubbleBodyRect
    let fullCaptureRect = captureRects.fullBubbleRect
    var contentCaptureRect = captureRects.contentRect.intersection(fullCaptureRect)
    if contentCaptureRect.isNull || contentCaptureRect.width <= 1.0
      || contentCaptureRect.height <= 1.0
    {
      contentCaptureRect = bubbleBodyRect.insetBy(dx: 10, dy: 6)
    }
    contentCaptureRect = contentCaptureRect.integral

    let bubbleBackgroundEndFrame = CGRect(
      x: fullCaptureRect.minX - bubbleBodyRect.minX,
      y: fullCaptureRect.minY - bubbleBodyRect.minY,
      width: fullCaptureRect.width,
      height: fullCaptureRect.height
    )

    let destinationContentFrame = CGRect(
      x: contentCaptureRect.minX - bubbleBodyRect.minX,
      y: contentCaptureRect.minY - bubbleBodyRect.minY,
      width: contentCaptureRect.width,
      height: contentCaptureRect.height
    )

    let sourceBackgroundRect = payload.resolvedSourceBackgroundRect.integral
    let sourceContentRect = payload.resolvedSourceContentRect.integral

    let sourceBackgroundStartFrame = mapSourceRectToContainer(
      sourceBackgroundRect, motionSourceRect: motionSourceRect, targetRect: targetBubbleRect)
    let sourceContentStartFrame = mapSourceRectToContainer(
      sourceContentRect, motionSourceRect: motionSourceRect, targetRect: targetBubbleRect)

    let bubbleBackgroundSnapshot: UIView = {
      if let snapshot = snapshotCell.bubbleBackgroundSnapshotView(in: snapshotCell.contentView) {
        snapshot.frame = bubbleBackgroundEndFrame
        return snapshot
      }
      let fallback = UIView(frame: bubbleBackgroundEndFrame)
      fallback.backgroundColor =
        appearance.bubbleMeGradient.first
        ?? appearance.bubbleThemColor.withAlphaComponent(1.0)
      fallback.layer.cornerCurve = .continuous
      fallback.layer.cornerRadius = 18.0
      return fallback
    }()

    let sourceBackgroundSnapshot: UIView = {
      if let snapshot = payload.sourceBackgroundSnapshotView {
        snapshot.frame = sourceBackgroundStartFrame
        return snapshot
      }
      let view = UIView(frame: CGRect(origin: .zero, size: sourceBackgroundStartFrame.size))
      // Opaque to match bubble body and avoid transparency mismatch during fallback.
      view.backgroundColor = appearance.bubbleThemColor.withAlphaComponent(1.0)
      view.layer.cornerRadius = min(sourceBackgroundStartFrame.height / 2, 22.0)
      view.layer.cornerCurve = .continuous
      return view
    }()

    let destinationContentSnapshot: UIView = {
      if let contentOnly = makeContentSnapshot(
        snapshotCell: snapshotCell, captureRect: contentCaptureRect,
        targetFrame: destinationContentFrame)
      {
        return contentOnly
      }
      let label = UILabel(frame: destinationContentFrame)
      label.font = UIFont.systemFont(ofSize: 16)
      label.textColor = appearance.textColorThem.withAlphaComponent(0.95)
      label.textAlignment = .left
      label.numberOfLines = 0
      label.text = payload.text
      return label
    }()

    let sourceTextSnapshot: UIView? = {
      if let snapshot = payload.sourceContentSnapshotView {
        snapshot.frame = sourceContentStartFrame
        return snapshot
      }
      let label = UILabel(frame: sourceContentStartFrame)
      label.font = UIFont.systemFont(ofSize: 16)
      label.textColor = appearance.textColorThem.withAlphaComponent(0.95)
      label.textAlignment = .left
      label.numberOfLines = 1
      label.lineBreakMode = .byTruncatingTail
      label.text = payload.text
      return label
    }()

    let clippingView = UIView(frame: sourceBackgroundStartFrame)
    clippingView.clipsToBounds = true
    clippingView.isUserInteractionEnabled = false
    clippingView.layer.cornerCurve = .continuous
    clippingView.layer.cornerRadius = min(sourceBackgroundStartFrame.height * 0.5, 22.0)

    bubbleBackgroundSnapshot.layer.opacity = 0.0

    clippingView.addSubview(sourceBackgroundSnapshot)
    clippingView.addSubview(bubbleBackgroundSnapshot)
    container.addSubview(clippingView)

    if let sourceTextSnapshot {
      sourceTextSnapshot.layer.opacity = 1.0
      container.addSubview(sourceTextSnapshot)
    }

    destinationContentSnapshot.layer.opacity = 0.0
    container.addSubview(destinationContentSnapshot)

    return Result(
      container: container,
      clippingView: clippingView,
      sourceBackgroundSnapshot: sourceBackgroundSnapshot,
      bubbleBackgroundSnapshot: bubbleBackgroundSnapshot,
      destinationContentSnapshot: destinationContentSnapshot,
      sourceTextSnapshot: sourceTextSnapshot,
      sourceBackgroundStartFrame: sourceBackgroundStartFrame,
      sourceBackgroundEndFrame: bubbleBackgroundEndFrame,
      sourceContentStartFrame: sourceContentStartFrame,
      destinationContentFrame: destinationContentFrame,
      sourceScrollOffset: payload.sourceScrollOffset,
      sourceRect: motionSourceRect
    )
  }
}
