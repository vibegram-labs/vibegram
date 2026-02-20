import AVFoundation
import CoreLocation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Delegate

protocol ChatInputBarDelegate: AnyObject {
  func inputBarDidSend(text: String)
  func inputBarDidTapAttachment()
  func inputBarDidTapAction()
  func inputBarTextDidChange(text: String)
  func inputBarHeightDidChange()
  // Rich attachment callbacks (mirrors AttachmentMenu.tsx)
  func inputBarDidSelectImage(uri: String)
  func inputBarDidSelectGif(
    id: String,
    url: String,
    previewUrl: String,
    width: Int,
    height: Int
  )
  func inputBarDidSelectFile(uri: String, name: String)
  func inputBarDidSelectLocation(latitude: Double, longitude: Double)
  // Recording
  func inputBarRecordingStateDidChange(isRecording: Bool, isLocked: Bool, mode: String)
  func inputBarRecordingDidCancel()
  func inputBarDidRecordVoice(uri: String, duration: Double, waveform: [Double])
  // Reply
  func inputBarReplyDismissed()
}

// MARK: - FluidVADVisualizer

final class FluidVADVisualizer: UIView {
  private let layers: [CAShapeLayer] = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
  private var displayLink: CADisplayLink?
  private var time: CGFloat = 0
  var level: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    layers.forEach {
      layer.addSublayer($0)
    }
  }
  required init?(coder: NSCoder) { nil }

  func applyColor(_ color: UIColor) {
    layers.forEach { $0.fillColor = color.cgColor }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
    let baseRadius = bounds.width / 2
    for l in layers {
      l.bounds = bounds
      l.position = center
      l.path =
        UIBezierPath(
          arcCenter: CGPoint(x: bounds.width / 2, y: bounds.height / 2),
          radius: baseRadius,
          startAngle: 0,
          endAngle: .pi * 2,
          clockwise: true
        ).cgPath
    }
  }

  func start() {
    displayLink?.invalidate()
    time = 0
    alpha = 1
    displayLink = CADisplayLink(target: self, selector: #selector(tick))
    displayLink?.add(to: .main, forMode: .common)
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    UIView.animate(withDuration: 0.25) {
      self.alpha = 0
    }
  }

  @objc private func tick() {
    for (i, l) in layers.enumerated() {
      // Offset per layer for visual stacking (1-based index helps multiplier)
      let idx = CGFloat(i + 1)

      // Calculate a base scale with some breathing room based purely on mic level.
      // E.g., at level 0: layers stay slightly different sizes near 1.0.
      // At level 1: layers scale out significantly more based on their index.
      let layerScale = 1.0 + (level * 0.4 * idx)

      // Apply pure scaling from the center without translating
      l.transform = CATransform3DMakeAffineTransform(
        CGAffineTransform(scaleX: layerScale, y: layerScale)
      )

      // Optional: adjust opacity so outermost layers are fainter
      l.opacity = Float(max(0.2, 1.0 - (level * 0.3 * idx)))
    }
  }
}

// MARK: - ChatInputBar

private func chatGifStickerGlyphImage(size: CGSize) -> UIImage {
  let format = UIGraphicsImageRendererFormat()
  format.opaque = false
  format.scale = UIScreen.main.scale
  let renderer = UIGraphicsImageRenderer(size: size, format: format)

  let image = renderer.image { _ in
    UIColor.black.setStroke()

    let scale = min(size.width, size.height) / 24.0
    let offsetX = (size.width - (24.0 * scale)) / 2.0
    let offsetY = (size.height - (24.0 * scale)) / 2.0
    let pt: (CGFloat, CGFloat) -> CGPoint = { x, y in
      CGPoint(x: offsetX + (x * scale), y: offsetY + (y * scale))
    }

    // Outer 270deg arc: M21.2 12 A9.2 9.2 0 1 1 12 2.8
    let outer = UIBezierPath()
    outer.move(to: pt(21.2, 12.0))
    let steps = 42
    for i in 1...steps {
      let t = CGFloat(i) / CGFloat(steps)
      let angle = t * (1.5 * CGFloat.pi)  // 0 -> 270deg
      let x = 12.0 + (9.2 * cos(angle))
      let y = 12.0 + (9.2 * sin(angle))
      outer.addLine(to: pt(x, y))
    }
    outer.lineWidth = 1.8 * scale
    outer.lineCapStyle = .round
    outer.lineJoinStyle = .round
    outer.stroke()

    // M12 2.8 c0 4.5 4.5 9.2 9.2 9.2
    let foldA = UIBezierPath()
    foldA.move(to: pt(12.0, 2.8))
    foldA.addCurve(
      to: pt(21.2, 12.0),
      controlPoint1: pt(12.0, 7.3),
      controlPoint2: pt(16.5, 12.0)
    )
    foldA.lineWidth = 1.8 * scale
    foldA.lineCapStyle = .round
    foldA.lineJoinStyle = .round
    foldA.stroke()

    // M12 2.8 c4.5 0 9.2 4.5 9.2 9.2
    let foldB = UIBezierPath()
    foldB.move(to: pt(12.0, 2.8))
    foldB.addCurve(
      to: pt(21.2, 12.0),
      controlPoint1: pt(16.5, 2.8),
      controlPoint2: pt(21.2, 7.3)
    )
    foldB.lineWidth = 1.8 * scale
    foldB.lineCapStyle = .round
    foldB.lineJoinStyle = .round
    foldB.stroke()
  }

  return image.withRenderingMode(.alwaysTemplate)
}

final class ChatInputBar: UIView {

  weak var delegate: ChatInputBarDelegate?

  // MARK: Subviews — layered bottom-to-top:
  // No full-bar glass. Each interactive element has its own glass surface:
  //   attachBtn (glass pill) | pill (glass) | micBtn (glass pill)

  private let contentRow = UIView()  // holds all interactive elements

  private let attachButton = UIButton(type: .system)
  private let attachGlass = UIVisualEffectView(effect: nil)

  private let pillContainer = UIView()
  private let pillGlass = UIVisualEffectView(effect: nil)
  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let gifButton = UIButton(type: .system)
  private let sendButton = UIButton(type: .system)
  private let sendGradient = CAGradientLayer()

  private let micButton = UIButton(type: .system)
  private let micGlass = UIVisualEffectView(effect: nil)
  private let micVADView = FluidVADVisualizer()
  private let gifPanel = ChatGifPanelView()
  private var gifPanelVisible = false
  private let defaultGifPanelHeight: CGFloat = 320
  private var lastKnownKeyboardHeight: CGFloat = 0
  // Width progress for right action morph: 0 = mic, 1 = send.
  private var sendProgress: CGFloat = 0
  // Recording layout morph progress: 0 = regular, 1 = expanded left.
  private var recordingExpandProgress: CGFloat = 0

  // Reply banner (inside the pill, above text row)
  private let replyBanner = UIView()
  private let replyAccentBar = UIView()
  private let replySenderLabel = UILabel()
  private let replyPreviewLabel = UILabel()
  private let replyDismissButton = UIButton(type: .system)
  private var replyBannerVisible = false
  private let replyBannerContentH: CGFloat = 36
  private let replyBannerGap: CGFloat = 4

  // Recording UI
  private let lockView = UIImageView(image: UIImage(systemName: "lock.fill"))
  private let lockPill = UIVisualEffectView(effect: nil)
  private let lockArrowView = UIImageView(image: UIImage(systemName: "chevron.up"))
  private let slideToCancelLabel = UILabel()
  private let slideChevronView = UIImageView(image: UIImage(systemName: "chevron.left"))
  private let recordingTimerLabel = UILabel()
  private let recordingDot = UIView()
  private var recordingStartTime: Date?
  private var recordingTimer: Timer?
  private var vadTimer: Timer?
  private var recordingGestureStartPoint: CGPoint = .zero
  private var audioRecorder: AVAudioRecorder?
  private var recordingFileURL: URL?
  private var recordingWaveformSamples: [CGFloat] = []

  private let cancelOverlayButton = UIButton(type: .custom)

  // Attachment sheet
  private var attachmentSheet: ChatAttachmentSheet?
  private let glassPressedOverlayColor = UIColor(white: 1.0, alpha: 0.08)

  // Appearance
  private var appearance = ChatListAppearance.fallback
  private var pillTint: UIColor?

  // MARK: Layout constants
  private let sideSize: CGFloat = 36
  private let sideGap: CGFloat = 6
  private let vPad: CGFloat = 6
  private let minPillH: CGFloat = 40
  private let maxPillH: CGFloat = 120
  private let textInsetH: CGFloat = 12
  private let textInsetV: CGFloat = 10

  // MARK: Public state
  var keyboardProgress: CGFloat = 0 {
    didSet { if abs(oldValue - keyboardProgress) > 0.01 { setNeedsLayout() } }
  }
  var keyboardHeightForPanels: CGFloat = 0 {
    didSet {
      if keyboardHeightForPanels > 0 {
        lastKnownKeyboardHeight = keyboardHeightForPanels
      }
    }
  }
  var activeReplyToMessageId: String?
  private(set) var barHeight: CGFloat = 0
  var bottomSafeAreaInset: CGFloat = 0 {
    didSet { if abs(oldValue - bottomSafeAreaInset) > 0.5 { setNeedsLayout() } }
  }
  var placeholder: String = "Message" {
    didSet { placeholderLabel.text = placeholder }
  }
  var currentText: String {
    textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  var isGifPanelPresented: Bool { gifPanelVisible }

  // Recording state
  private var isRecording = false
  private var isLocked = false
  private let feedback = UIImpactFeedbackGenerator(style: .medium)
  private let notificationFeedback = UINotificationFeedbackGenerator()

  func showReplyBanner(messageId: String, text: String, isMe: Bool) {
    replyBanner.layer.removeAllAnimations()
    activeReplyToMessageId = messageId
    replySenderLabel.text = isMe ? "You" : "Reply"
    replyPreviewLabel.text = text
    replyBannerVisible = true
    replyBanner.isHidden = false
    replyBanner.alpha = 1

    if gifPanelVisible {
      setGifPanelVisible(false, animated: true)
    }

    UIView.animate(
      withDuration: 0.25, delay: 0,
      usingSpringWithDamping: 0.82, initialSpringVelocity: 0.5,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.window != nil, !self.textView.isFirstResponder else { return }
      self.textView.becomeFirstResponder()
    }
  }

  func dismissReplyBanner(animated: Bool) {
    guard activeReplyToMessageId != nil || replyBannerVisible else { return }
    replyBanner.layer.removeAllAnimations()
    activeReplyToMessageId = nil
    replyBannerVisible = false

    let applyLayout = {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    if animated {
      replyBanner.alpha = 1
      replyBanner.isHidden = false
      UIView.animate(
        withDuration: 0.22, delay: 0,
        options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        applyLayout()
      } completion: { _ in
        if !self.replyBannerVisible {
          self.replyBanner.alpha = 0
          self.replyBanner.isHidden = true
        }
      }
    } else {
      replyBanner.alpha = 0
      replyBanner.isHidden = true
      UIView.performWithoutAnimation {
        applyLayout()
      }
    }
  }

  @objc private func replyDismissTapped() {
    dismissReplyBanner(animated: true)
    delegate?.inputBarReplyDismissed()
  }

  private func layoutReplyBannerContents() {
    let b = replyBanner.bounds
    guard b.width > 0, b.height > 0 else { return }
    let pad: CGFloat = 8
    let accentW: CGFloat = 3
    let dismissSize: CGFloat = 24

    replyAccentBar.frame = CGRect(x: pad, y: (b.height - 28) / 2, width: accentW, height: 28)
    let textX = replyAccentBar.frame.maxX + 8
    let textW = max(1, b.width - textX - dismissSize - pad)
    replySenderLabel.frame = CGRect(x: textX, y: (b.height - 28) / 2, width: textW, height: 14)
    replyPreviewLabel.frame = CGRect(
      x: textX, y: replySenderLabel.frame.maxY + 1, width: textW, height: 14)
    replyDismissButton.frame = CGRect(
      x: b.width - dismissSize - pad + 4,
      y: (b.height - dismissSize) / 2,
      width: dismissSize, height: dismissSize
    )
  }

  // MARK: Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    setupViews()
  }
  required init?(coder: NSCoder) { nil }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    maybePrepareGifPanel()
  }

  // MARK: - Setup

  private func setupViews() {
    // ── 1. Content row ────────────────────────────────────────────────────
    // No full-bar glass. The bar background is transparent; each element
    // has its own glass surface.
    contentRow.backgroundColor = .clear
    contentRow.clipsToBounds = false
    addSubview(contentRow)

    // ── Attachment button (glass pill) ────────────────────────────────────
    attachGlass.isUserInteractionEnabled = false
    attachGlass.clipsToBounds = true
    attachButton.clipsToBounds = false
    attachButton.backgroundColor = .clear
    attachButton.addSubview(attachGlass)
    attachButton.sendSubviewToBack(attachGlass)
    let plusCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    attachButton.setImage(UIImage(systemName: "plus", withConfiguration: plusCfg), for: .normal)
    attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
    contentRow.addSubview(attachButton)

    // ── Pill container ────────────────────────────────────────────────────
    pillContainer.backgroundColor = .clear
    pillContainer.clipsToBounds = true
    pillContainer.layer.cornerCurve = .continuous
    pillContainer.layer.borderWidth = 0.6
    pillContainer.layer.borderColor = UIColor(white: 1.0, alpha: 0.12).cgColor

    // glass background of pill
    pillGlass.isUserInteractionEnabled = false
    pillGlass.clipsToBounds = true
    pillContainer.addSubview(pillGlass)
    pillContainer.sendSubviewToBack(pillGlass)

    // placeholder
    placeholderLabel.text = placeholder
    placeholderLabel.font = UIFont.systemFont(ofSize: 16)
    placeholderLabel.isUserInteractionEnabled = false
    pillContainer.addSubview(placeholderLabel)

    // text view
    textView.backgroundColor = .clear
    textView.font = UIFont.systemFont(ofSize: 16)
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.isScrollEnabled = false
    textView.returnKeyType = .send
    textView.delegate = self
    textView.showsVerticalScrollIndicator = false
    pillContainer.addSubview(textView)

    // GIF button (inside pill, trailing side before Send)
    gifButton.setImage(chatGifStickerGlyphImage(size: CGSize(width: 20, height: 20)), for: .normal)
    gifButton.addTarget(self, action: #selector(gifTapped), for: .touchUpInside)
    pillContainer.addSubview(gifButton)

    // ── Reply banner (inside pill, above text row) ────────────────────
    replyBanner.clipsToBounds = true
    replyBanner.isHidden = true
    replyBanner.alpha = 0
    pillContainer.addSubview(replyBanner)

    replyAccentBar.backgroundColor = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    replyAccentBar.layer.cornerRadius = 1.5
    replyAccentBar.layer.cornerCurve = .continuous
    replyBanner.addSubview(replyAccentBar)

    replySenderLabel.font = .systemFont(ofSize: 12, weight: .bold)
    replySenderLabel.textColor = UIColor(white: 0.92, alpha: 1.0)
    replySenderLabel.lineBreakMode = .byTruncatingTail
    replyBanner.addSubview(replySenderLabel)

    replyPreviewLabel.font = .systemFont(ofSize: 12, weight: .regular)
    replyPreviewLabel.textColor = UIColor(white: 0.87, alpha: 0.72)
    replyPreviewLabel.lineBreakMode = .byTruncatingTail
    replyBanner.addSubview(replyPreviewLabel)

    let xCfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
    replyDismissButton.setImage(UIImage(systemName: "xmark", withConfiguration: xCfg), for: .normal)
    replyDismissButton.tintColor = UIColor(white: 0.87, alpha: 0.5)
    replyDismissButton.addTarget(self, action: #selector(replyDismissTapped), for: .touchUpInside)
    replyBanner.addSubview(replyDismissButton)

    // send button
    sendButton.backgroundColor = .clear
    sendButton.clipsToBounds = true
    sendButton.layer.cornerRadius = 16
    let paperplane = UIImage(
      systemName: "paperplane.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    sendButton.setImage(paperplane, for: .normal)
    sendButton.tintColor = .white
    sendGradient.startPoint = CGPoint(x: 0, y: 0)
    sendGradient.endPoint = CGPoint(x: 1, y: 1)
    sendGradient.cornerRadius = 16
    sendButton.layer.insertSublayer(sendGradient, at: 0)
    sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    pillContainer.addSubview(sendButton)

    cancelOverlayButton.addTarget(self, action: #selector(cancelOverlayTapped), for: .touchUpInside)
    cancelOverlayButton.isHidden = true
    pillContainer.addSubview(cancelOverlayButton)

    contentRow.addSubview(pillContainer)

    // ── Mic button (glass pill) ───────────────────────────────────────────
    micVADView.alpha = 0
    contentRow.addSubview(micVADView)

    micGlass.isUserInteractionEnabled = false
    micGlass.clipsToBounds = true
    micButton.clipsToBounds = false
    micButton.addSubview(micGlass)
    micButton.sendSubviewToBack(micGlass)
    let micCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: micCfg), for: .normal)
    micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
    contentRow.addSubview(micButton)

    gifPanel.delegate = self
    gifPanel.isHidden = true
    gifPanel.alpha = 0
    addSubview(gifPanel)

    // Recording UI setup
    setupRecordingUI()

    // Default colors (visible before applyAppearance)
    attachButton.tintColor = UIColor(white: 0.85, alpha: 1.0)
    gifButton.tintColor = UIColor(white: 0.85, alpha: 0.95)
    micButton.tintColor = UIColor(white: 0.85, alpha: 1.0)
    textView.textColor = UIColor(white: 0.87, alpha: 1.0)
    textView.tintColor = UIColor(white: 0.87, alpha: 0.9)
    placeholderLabel.textColor = UIColor(white: 0.87, alpha: 0.45)
    sendGradient.colors = [
      UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0).cgColor,
      UIColor(red: 0.42, green: 0.31, blue: 0.81, alpha: 1.0).cgColor,
    ]

    // Initial button state (no text → mic visible, send hidden)
    sendButton.alpha = 0
    sendProgress = 0
    micButton.alpha = 1
    sendButton.isHidden = true
    micButton.isHidden = false

    configureGlassButtonPressFeedback()
    applyPlaceholder()
    refreshGlass()
  }

  // MARK: - Appearance

  func applyAppearance(_ a: ChatListAppearance) {
    appearance = a
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    textView.textColor = a.textColorThem
    textView.tintColor = a.textColorThem.withAlphaComponent(0.9)
    placeholderLabel.textColor = a.textColorThem.withAlphaComponent(0.45)
    attachButton.tintColor = a.textColorThem.withAlphaComponent(0.9)
    gifButton.tintColor = a.textColorThem.withAlphaComponent(gifPanelVisible ? 1.0 : 0.85)
    micButton.tintColor = a.textColorThem.withAlphaComponent(0.9)
    sendGradient.colors = a.bubbleMeGradient.map(\.cgColor)
    pillTint = a.bubbleThemColor.withAlphaComponent(0.14)
    pillContainer.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor

    if let firstColor = a.bubbleMeGradient.first {
      micVADView.applyColor(firstColor.withAlphaComponent(0.25))
    } else {
      micVADView.applyColor(a.textColorThem.withAlphaComponent(0.15))
    }

    // Reply banner
    replyAccentBar.backgroundColor = a.bubbleMeGradient.first ?? replyAccentBar.backgroundColor
    replySenderLabel.textColor = a.textColorThem.withAlphaComponent(0.92)
    replyPreviewLabel.textColor = a.textColorThem.withAlphaComponent(0.72)
    replyDismissButton.tintColor = a.textColorThem.withAlphaComponent(0.5)
    slideToCancelLabel.textColor = a.textColorThem.withAlphaComponent(0.78)
    slideChevronView.tintColor = a.textColorThem.withAlphaComponent(0.78)
    recordingTimerLabel.textColor = a.textColorThem.withAlphaComponent(0.95)
    lockView.tintColor = a.textColorThem.withAlphaComponent(0.95)
    lockArrowView.tintColor = a.textColorThem.withAlphaComponent(0.95)

    refreshGlass()
    CATransaction.commit()
  }

  // MARK: - Public helpers

  func clearText() {
    textView.text = ""
    updateButtonStates(animated: true)
    applyPlaceholder()
    // Animate pill shrinking back to single-line height
    UIView.animate(
      withDuration: 0.25, delay: 0,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }
  }

  func pillRect(in view: UIView) -> CGRect {
    pillContainer.convert(pillContainer.bounds, to: view)
  }

  /// Returns the frame of the text area in the given coordinate space (used for send transition source rect).
  func textRect(in view: UIView) -> CGRect {
    textView.convert(textView.bounds, to: view)
  }

  /// Captures a live snapshot of the text view content for crossfade transitions.
  /// Returns a view positioned in the coordinate space of `view`, or nil if capture fails.
  func textContentSnapshot(in view: UIView) -> UIView? {
    let textBounds = textView.bounds
    guard textBounds.width > 1.0, textBounds.height > 1.0 else { return nil }
    // Try resizable snapshot first (fastest, preserves subpixel rendering).
    if let snapshot = textView.resizableSnapshotView(
      from: textBounds,
      afterScreenUpdates: false,
      withCapInsets: .zero
    ) {
      snapshot.frame = textView.convert(textBounds, to: view)
      return snapshot
    }
    // Fallback: render into image.
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(size: textBounds.size, format: format)
    let image = renderer.image { _ in
      self.textView.drawHierarchy(in: self.textView.bounds, afterScreenUpdates: false)
    }
    let imageView = UIImageView(image: image)
    imageView.frame = textView.convert(textBounds, to: view)
    return imageView
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    guard w > 0 else { return }
    maybePrepareGifPanel()

    let safeBottom = max(0, bottomSafeAreaInset)
    let clampedSendProgress = max(0.0, min(1.0, sendProgress))
    let clampedRecordingExpand = max(0.0, min(1.0, recordingExpandProgress))
    let micVisibility = max(0.0, min(1.0, 1.0 - clampedSendProgress))

    // Keep horizontal geometry stable when swapping keyboard <-> GIF panel.
    let layoutKeyboardProgress = max(keyboardProgress, gifPanelVisible ? 1.0 : 0.0)
    let dynamicHPad = 26.0 - (16.0 * layoutKeyboardProgress)

    // Measure text height
    let recordingLeftExpansion = (sideSize + sideGap) * clampedRecordingExpand
    let pillX = dynamicHPad + sideSize + sideGap - recordingLeftExpansion
    let pillRight = w - dynamicHPad - (sideSize * micVisibility) - (sideGap * micVisibility)
    let sendW: CGFloat = 44
    let sendH: CGFloat = 32
    let gifButtonSize: CGFloat = 36
    let gifTextReserve: CGFloat =
      isRecording ? 0 : max(24, gifButtonSize - (8 * clampedSendProgress))
    let pillW = max(1, pillRight - pillX)
    let sendActionReserve = (sendW + 2) * clampedSendProgress
    let textW = max(1, pillW - textInsetH * 2 - sendActionReserve - gifTextReserve)
    let textH = textView.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height
    let clampedTextH = max(minPillH - textInsetV * 2, min(maxPillH - textInsetV * 2, textH))
    let bannerExtra: CGFloat = replyBannerVisible ? (replyBannerContentH + replyBannerGap) : 0
    let pillH = clampedTextH + textInsetV * 2 + bannerExtra
    let gifPanelH = gifPanelVisible ? preferredGifPanelHeight() : 0

    let totalH = vPad + pillH + (gifPanelVisible ? (vPad + gifPanelH) : vPad) + safeBottom
    let prevH = barHeight
    barHeight = totalH

    // Enable/disable scroll when text exceeds max height
    textView.isScrollEnabled = textH > maxPillH - textInsetV * 2

    // ── View frames (CAN animate when triggered from UIView.animate) ──
    let rowY = vPad
    let rowH = pillH
    contentRow.frame = CGRect(x: 0, y: rowY, width: w, height: rowH)

    // Side buttons are perfectly circular
    let textRowH = clampedTextH + textInsetV * 2
    let btnCenterY = bannerExtra + (textRowH / 2)
    let squareBounds = CGRect(origin: .zero, size: CGSize(width: sideSize, height: sideSize))

    attachButton.bounds = squareBounds
    attachButton.center = CGPoint(
      x: dynamicHPad + (sideSize / 2) - (recordingLeftExpansion * 0.85),
      y: btnCenterY
    )

    let micBaseCenterX = w - dynamicHPad - (sideSize / 2)
    let micPushOutX = (sideSize + sideGap) * clampedSendProgress

    // Position Mic Button (use center/bounds to preserve transforms)
    micButton.bounds = squareBounds
    micButton.center = CGPoint(x: micBaseCenterX + micPushOutX, y: btnCenterY)
    micVADView.bounds = squareBounds
    micVADView.center = micButton.center
    // Layout check: Initial visibility handled by updateButtonStates

    let actualPillW = max(1, pillRight - pillX)
    pillContainer.frame = CGRect(x: pillX, y: 0, width: actualPillW, height: pillH)
    // Corner radius: use the text-row height for capsule feel, capped for tall pills
    let cornerBase = (clampedTextH + textInsetV * 2)
    pillContainer.layer.cornerRadius = min(cornerBase / 2, 22)

    // Position Send Button inside pill (inline with text area)
    let sendCenterY = bannerExtra + ((clampedTextH + textInsetV * 2) / 2)
    let sendCenterX = actualPillW - 4 - (sendW / 2)
    sendButton.bounds = CGRect(origin: .zero, size: CGSize(width: sendW, height: sendH))
    sendButton.center = CGPoint(x: sendCenterX, y: sendCenterY)
    sendButton.layer.cornerRadius = 16

    // ── Reply banner layout (inside pill, top section) ──
    if replyBannerVisible {
      let bannerY: CGFloat = 6
      let bannerW = max(1, actualPillW - 16)
      replyBanner.frame = CGRect(x: 8, y: bannerY, width: bannerW, height: replyBannerContentH)
      layoutReplyBannerContents()
    }

    let tfX = textInsetH
    let tfW = max(1, actualPillW - textInsetH * 2 - sendActionReserve - gifTextReserve)
    let tfY = bannerExtra + (clampedTextH + textInsetV * 2 - clampedTextH) / 2
    textView.frame = CGRect(x: tfX, y: tfY, width: tfW, height: clampedTextH)
    placeholderLabel.frame = CGRect(x: tfX + 2, y: tfY, width: tfW - 4, height: clampedTextH)
    let gifTrailingInsetCollapsed: CGFloat = textInsetH
    let gifTrailingInsetExpanded: CGFloat = 2
    let gifTrailingInset =
      gifTrailingInsetCollapsed
      - ((gifTrailingInsetCollapsed - gifTrailingInsetExpanded) * clampedSendProgress)
    let gifX = actualPillW - gifTrailingInset - sendActionReserve - gifButtonSize
    gifButton.frame = CGRect(
      x: gifX,
      y: tfY + (clampedTextH - gifButtonSize) / 2,
      width: gifButtonSize,
      height: gifButtonSize
    )
    gifButton.isHidden = isRecording

    // Recording UI Layout
    if isRecording {
      let dotSize: CGFloat = 6
      recordingDot.frame = CGRect(x: 16, y: (pillH - dotSize) / 2, width: dotSize, height: dotSize)
      recordingDot.layer.cornerRadius = dotSize / 2

      let timerSize = recordingTimerLabel.sizeThatFits(CGSize(width: actualPillW, height: pillH))
      recordingTimerLabel.frame = CGRect(
        x: 28, y: (pillH - timerSize.height) / 2, width: timerSize.width, height: timerSize.height)

      let cancelSize = slideToCancelLabel.sizeThatFits(CGSize(width: actualPillW, height: pillH))
      slideToCancelLabel.frame = CGRect(
        x: (actualPillW - cancelSize.width) / 2 + 20,
        y: (pillH - cancelSize.height) / 2,
        width: cancelSize.width,
        height: cancelSize.height
      )
      let chevronSize = CGSize(width: 12, height: 12)
      slideChevronView.frame = CGRect(
        x: slideToCancelLabel.frame.minX - chevronSize.width - 4,
        y: (pillH - chevronSize.height) / 2,
        width: chevronSize.width,
        height: chevronSize.height
      )

      if !isLocked {
        let micCenter = contentRow.convert(micButton.center, to: self)
        let lockW: CGFloat = 46
        let lockH: CGFloat = 86
        lockPill.frame = CGRect(
          x: micCenter.x - (lockW / 2),
          y: micCenter.y - lockH - 8,
          width: lockW,
          height: lockH
        )
        lockPill.layer.cornerRadius = lockW / 2
        lockPill.clipsToBounds = true
        lockArrowView.frame = CGRect(x: (lockW - 14) / 2, y: 16, width: 14, height: 14)
        lockView.frame = CGRect(x: (lockW - 14) / 2, y: 46, width: 14, height: 18)
      }
    }

    cancelOverlayButton.frame = pillContainer.bounds

    let gifPanelX = dynamicHPad
    let gifPanelW = max(1, w - (dynamicHPad * 2))
    if gifPanelVisible {
      gifPanel.frame = CGRect(
        x: gifPanelX,
        y: contentRow.frame.maxY + vPad,
        width: gifPanelW,
        height: gifPanelH + safeBottom
      )
      gifPanel.alpha = 1
    } else {
      gifPanel.frame = CGRect(x: gifPanelX, y: contentRow.frame.maxY, width: gifPanelW, height: 0)
      gifPanel.alpha = 0
    }
    gifPanel.isHidden = !gifPanelVisible

    // ── Layer-only updates (no implicit animation wanted) ──
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    attachGlass.frame = attachButton.bounds
    micGlass.frame = micButton.bounds
    pillGlass.frame = pillContainer.bounds
    sendGradient.frame = sendButton.bounds
    sendGradient.cornerRadius = 16

    if #available(iOS 26.0, *) {
      // Use native cornerConfiguration for liquid glass shapes
      attachGlass.cornerConfiguration = .capsule()
      micGlass.cornerConfiguration = .capsule()
      // Use border radius for the pill instead of capsule, so it doesn't break banner layout
      pillGlass.layer.cornerRadius = pillContainer.layer.cornerRadius
      pillGlass.layer.cornerCurve = .continuous
      pillContainer.layer.cornerCurve = .continuous
      lockPill.cornerConfiguration = .capsule()
    } else {
      attachGlass.layer.cornerRadius = sideSize / 2
      micGlass.layer.cornerRadius = sideSize / 2
      pillGlass.layer.cornerRadius = pillContainer.layer.cornerRadius
      lockPill.layer.cornerRadius = lockPill.bounds.width / 2
    }

    refreshGlass()
    // Ensure icons render above per-button glass surfaces.
    if let attachImage = attachButton.imageView { attachButton.bringSubviewToFront(attachImage) }
    if let gifImage = gifButton.imageView { gifButton.bringSubviewToFront(gifImage) }
    if let micImage = micButton.imageView { micButton.bringSubviewToFront(micImage) }
    if let sendImage = sendButton.imageView { sendButton.bringSubviewToFront(sendImage) }
    CATransaction.commit()

    if abs(prevH - barHeight) > 0.5 {
      delegate?.inputBarHeightDidChange()
    }
  }

  // MARK: - Glass

  /// Each interactive element (attach button, pill, mic button) has its own
  /// glass surface. On iOS 26+ we use UIGlassEffect for native liquid glass;
  /// on older iOS we fall back to UIBlurEffect(style: .systemMaterial).
  private func refreshGlass() {
    if #available(iOS 26.0, *) {
      let attachEffect = UIGlassEffect()
      attachEffect.isInteractive = true
      attachGlass.effect = attachEffect

      let micEffect = UIGlassEffect()
      micEffect.isInteractive = true
      micGlass.effect = micEffect

      let pillEffect = UIGlassEffect()
      pillEffect.isInteractive = true
      pillGlass.effect = pillEffect
      pillGlass.backgroundColor = pillTint

      let lockEffect = UIGlassEffect()
      lockPill.effect = lockEffect
      lockPill.backgroundColor = UIColor(white: 0.1, alpha: 0.2)
    } else {
      attachGlass.effect = UIBlurEffect(style: .systemMaterial)
      micGlass.effect = UIBlurEffect(style: .systemMaterial)
      pillGlass.effect = UIBlurEffect(style: .systemMaterial)
      pillGlass.backgroundColor = pillTint
      lockPill.effect = UIBlurEffect(style: .systemMaterialDark)
      lockPill.backgroundColor = UIColor(white: 0.1, alpha: 0.2)
    }
  }

  private func configureGlassButtonPressFeedback() {
    let buttons: [UIButton] = [attachButton, gifButton, sendButton, micButton]
    buttons.forEach { button in
      button.addTarget(
        self, action: #selector(handleButtonPressDown(_:)), for: [.touchDown, .touchDragEnter])
      button.addTarget(
        self, action: #selector(handleButtonPressUp(_:)),
        for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit, .touchDragOutside])
    }
  }

  @objc private func handleButtonPressDown(_ sender: UIButton) {
    setButtonPressed(sender, isPressed: true)
  }

  @objc private func handleButtonPressUp(_ sender: UIButton) {
    setButtonPressed(sender, isPressed: false)
  }

  private func setButtonPressed(_ button: UIButton, isPressed: Bool) {
    if button === micButton, isRecording { return }
    if button === sendButton, !sendButton.isUserInteractionEnabled { return }

    let duration: TimeInterval = isPressed ? 0.1 : 0.22
    let damping: CGFloat = isPressed ? 1.0 : 0.72
    let iconScale: CGFloat = isPressed ? 0.9 : 1.0
    let iconY: CGFloat = isPressed ? 0.6 : 0
    let iconTransform = CGAffineTransform(translationX: 0, y: iconY).scaledBy(
      x: iconScale, y: iconScale)

    UIView.animate(
      withDuration: duration,
      delay: 0,
      usingSpringWithDamping: damping,
      initialSpringVelocity: 0.25,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      button.imageView?.transform = isPressed ? iconTransform : .identity

      if button === self.attachButton {
        self.attachGlass.alpha = isPressed ? 0.92 : 1.0
        self.attachGlass.backgroundColor = isPressed ? self.glassPressedOverlayColor : .clear
      } else if button === self.micButton {
        self.micGlass.alpha = isPressed ? 0.92 : 1.0
        self.micGlass.backgroundColor = isPressed ? self.glassPressedOverlayColor : .clear
      } else if button === self.gifButton {
        let baseAlpha: CGFloat = self.sendButton.isUserInteractionEnabled ? 0.9 : 1.0
        self.gifButton.alpha = isPressed ? max(0.65, baseAlpha - 0.24) : baseAlpha
      } else if button === self.sendButton {
        let baseAlpha: CGFloat = self.sendButton.isUserInteractionEnabled ? 1.0 : 0.0
        self.sendButton.alpha = isPressed ? max(0.76, baseAlpha - 0.16) : baseAlpha
        self.sendGradient.opacity = isPressed ? 0.9 : 1.0
      }
    }
  }

  // MARK: - Button states

  private func updateButtonStates(animated: Bool = false) {
    let has = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let showSend = has

    // Inline send button in pill, with mic slot collapsing on the right.
    let targetProgress: CGFloat = showSend ? 1 : 0
    let hiddenSendTransform = CGAffineTransform(translationX: 10, y: 2).scaledBy(x: 0.84, y: 0.84)

    let changes = {
      self.sendProgress = targetProgress

      // Mic State
      self.micButton.alpha = showSend ? 0 : 1
      self.micButton.transform =
        showSend
        ? CGAffineTransform(translationX: 8, y: 0).scaledBy(x: 0.88, y: 0.88)
        : .identity
      self.micButton.isUserInteractionEnabled = !showSend

      // GIF State (moves in toward Send area while Send expands)
      self.gifButton.alpha = showSend ? 0.9 : 1.0
      self.gifButton.transform =
        showSend
        ? CGAffineTransform(translationX: 4, y: 0).scaledBy(x: 0.92, y: 0.92)
        : .identity

      // Send State
      self.sendButton.alpha = showSend ? 1 : 0
      self.sendButton.transform =
        showSend
        ? .identity
        : hiddenSendTransform
      self.sendButton.isUserInteractionEnabled = showSend

      self.micButton.isHidden = false
      self.sendButton.isHidden = false
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }

    if animated {
      UIView.animate(
        withDuration: 0.26,
        delay: 0,
        usingSpringWithDamping: 0.86,
        initialSpringVelocity: 0.35,
        options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
        animations: changes
      )
    } else {
      changes()
    }
  }

  private func applyPlaceholder() {
    placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
  }

  private func preferredGifPanelHeight() -> CGFloat {
    let safeBottom = max(0, bottomSafeAreaInset)
    if keyboardHeightForPanels > 0 {
      return max(220, keyboardHeightForPanels - safeBottom)
    }
    if lastKnownKeyboardHeight > 0 {
      return max(220, lastKnownKeyboardHeight - safeBottom)
    }
    return defaultGifPanelHeight
  }

  private func maybePrepareGifPanel() {
    guard window != nil else { return }
    if gifPanel.hostViewController == nil {
      gifPanel.hostViewController = findViewController()
    }
    gifPanel.prepareIfNeeded()
  }

  private func setGifPanelVisible(_ visible: Bool, animated: Bool) {
    guard visible != gifPanelVisible else { return }
    if visible {
      maybePrepareGifPanel()
    }

    gifPanelVisible = visible
    if visible, textView.isFirstResponder {
      textView.resignFirstResponder()
    }
    gifButton.tintColor = appearance.textColorThem.withAlphaComponent(visible ? 1.0 : 0.85)

    let applyChanges = {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    // Keyboard hide animation already drives the transition when opening GIF.
    let shouldAnimate = animated && !(visible && keyboardProgress > 0.01)
    if shouldAnimate {
      UIView.animate(
        withDuration: 0.25,
        delay: 0,
        options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
        animations: applyChanges
      )
    } else {
      applyChanges()
    }
  }

  // MARK: - Actions

  @objc private func gifTapped() {
    setGifPanelVisible(!gifPanelVisible, animated: true)
  }

  @objc private func attachTapped() {
    setGifPanelVisible(false, animated: true)
    // Show native attachment sheet
    guard let vc = findViewController() else {
      delegate?.inputBarDidTapAttachment()
      return
    }
    let sheet = ChatAttachmentSheet(appearance: appearance)
    sheet.onSelectImage = { [weak self] uri in self?.delegate?.inputBarDidSelectImage(uri: uri) }
    sheet.onSelectFile = { [weak self] uri, name in
      self?.delegate?.inputBarDidSelectFile(uri: uri, name: name)
    }
    sheet.onSelectLocation = { [weak self] lat, lon in
      self?.delegate?.inputBarDidSelectLocation(latitude: lat, longitude: lon)
    }
    attachmentSheet = sheet
    vc.present(sheet, animated: true)
  }

  @objc private func micTapped() {
    setGifPanelVisible(false, animated: true)
    if isRecording && isLocked {
      finishRecording()
      return
    }
    if isRecording {
      return
    }
    delegate?.inputBarDidTapAction()
  }

  @objc private func sendTapped() {
    setGifPanelVisible(false, animated: true)
    let t = currentText
    guard !t.isEmpty else { return }
    delegate?.inputBarDidSend(text: t)
  }

  @objc private func cancelOverlayTapped() {
    cancelRecording()
  }

  private func findViewController() -> UIViewController? {
    var r: UIResponder? = self
    while let next = r?.next {
      if let vc = next as? UIViewController { return vc }
      r = next
    }
    return nil
  }

  // MARK: - Recording

  private func setupRecordingUI() {
    // Lock hint pill (hidden initially)
    lockPill.isHidden = true
    lockPill.isUserInteractionEnabled = false
    addSubview(lockPill)

    lockArrowView.tintColor = .white
    lockArrowView.contentMode = .scaleAspectFit
    lockPill.contentView.addSubview(lockArrowView)

    // Lock icon
    lockView.tintColor = .white
    lockView.contentMode = .scaleAspectFit
    lockPill.contentView.addSubview(lockView)

    // Slide To Cancel
    slideToCancelLabel.text = "Slide to cancel"
    slideToCancelLabel.font = .systemFont(ofSize: 15)
    slideToCancelLabel.textColor = .secondaryLabel
    slideToCancelLabel.isHidden = true
    pillContainer.addSubview(slideToCancelLabel)

    slideChevronView.tintColor = .secondaryLabel
    slideChevronView.contentMode = .scaleAspectFit
    slideChevronView.isHidden = true
    pillContainer.addSubview(slideChevronView)

    // Timer
    recordingTimerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    recordingTimerLabel.textColor = .label
    recordingTimerLabel.text = "0:00.00"
    recordingTimerLabel.isHidden = true
    pillContainer.addSubview(recordingTimerLabel)

    // Dot
    recordingDot.backgroundColor = .systemRed
    recordingDot.layer.cornerRadius = 3
    recordingDot.isHidden = true
    pillContainer.addSubview(recordingDot)

    // Gesture
    let longPress = UILongPressGestureRecognizer(
      target: self, action: #selector(handleMicGesture(_:)))
    longPress.minimumPressDuration = 0.2
    micButton.addGestureRecognizer(longPress)
  }

  @objc private func handleMicGesture(_ g: UILongPressGestureRecognizer) {
    switch g.state {
    case .began:
      recordingGestureStartPoint = g.location(in: self)
      startRecording()
    case .changed:
      guard isRecording, !isLocked else { return }

      let point = g.location(in: self)
      let dy = point.y - recordingGestureStartPoint.y
      let dx = point.x - recordingGestureStartPoint.x

      lockPill.transform = CGAffineTransform(translationX: 0, y: min(0, dy + 6))

      if dy < -60 {
        lockRecording()
      } else if dx < -100 {
        cancelRecording()
        g.isEnabled = false  // Cancel gesture
        g.isEnabled = true
      }

    case .ended:
      if isRecording && !isLocked {
        finishRecording()
      }
    case .cancelled, .failed:
      cancelRecording()
    default: break
    }
  }

  private func startRecording() {
    guard !isRecording else { return }
    setGifPanelVisible(false, animated: false)
    setButtonPressed(micButton, isPressed: false)
    isRecording = true
    isLocked = false
    feedback.impactOccurred()

    // UI Transition
    // 1. Hide Input
    // 2. Show Timer + Cancel
    // 3. Mic scales Up

    textView.alpha = 0
    textView.isUserInteractionEnabled = false
    placeholderLabel.alpha = 0
    sendButton.isUserInteractionEnabled = false
    sendButton.alpha = 0
    slideToCancelLabel.isHidden = false
    slideChevronView.isHidden = false
    slideToCancelLabel.text = "Slide to cancel"
    recordingTimerLabel.isHidden = false
    recordingDot.isHidden = false
    lockPill.isHidden = false
    recordingTimerLabel.text = "0:00.00"

    recordingStartTime = Date()
    recordingWaveformSamples.removeAll(keepingCapacity: true)
    recordingFileURL = nil
    let timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
      self?.updateTimer()
    }
    RunLoop.main.add(timer, forMode: .common)
    recordingTimer = timer
    updateTimer()

    startRecordingHintAnimations()
    setNeedsLayout()
    layoutIfNeeded()

    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      usingSpringWithDamping: 0.88,
      initialSpringVelocity: 0.35,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.recordingExpandProgress = 1
      self.attachButton.transform = CGAffineTransform(translationX: -20, y: 0).scaledBy(
        x: 0.84, y: 0.84)
      self.attachButton.alpha = 0.18
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    // Mic Pulse / Scale
    UIView.animate(withDuration: 0.2) {
      self.micButton.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
      self.micGlass.transform = CGAffineTransform(scaleX: 2.8, y: 2.8)
      self.micVADView.transform = CGAffineTransform(scaleX: 2.8, y: 2.8)
      self.micButton.alpha = 1
    }

    micVADView.start()

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("voice-\(UUID().uuidString)")
      .appendingPathExtension("m4a")
    recordingFileURL = outputURL

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try AVAudioSession.sharedInstance().setCategory(
          .playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try AVAudioSession.sharedInstance().setActive(true)
        let settings: [String: Any] = [
          AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
          AVSampleRateKey: 44100.0,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 96_000,
          AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()

        DispatchQueue.main.async {
          guard let self = self else { return }
          if self.isRecording {
            self.audioRecorder = recorder
          } else {
            recorder.stop()
            DispatchQueue.global(qos: .userInitiated).async {
              try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
            }
          }
        }
      } catch {
        print("Failed to start VAD audio recorder: \(error)")
      }
    }

    vadTimer?.invalidate()
    vadTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self = self, self.isRecording else { return }
      if let recorder = self.audioRecorder, recorder.isRecording {
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        let minDb: Float = -45.0
        let level = max(0.0, min(1.0, CGFloat((db - minDb) / (-minDb))))
        self.micVADView.level = level
        self.recordingWaveformSamples.append(level)
        if self.recordingWaveformSamples.count > 480 {
          self.recordingWaveformSamples.removeFirst(self.recordingWaveformSamples.count - 480)
        }
      } else {
        self.micVADView.level = 0
      }
    }

    delegate?.inputBarRecordingStateDidChange(isRecording: true, isLocked: false, mode: "voice")
  }

  private func updateTimer() {
    guard let start = recordingStartTime else { return }
    let dur = Date().timeIntervalSince(start)
    let min = Int(dur) / 60
    let sec = Int(dur) % 60
    let ms = Int((dur.truncatingRemainder(dividingBy: 1)) * 100)
    recordingTimerLabel.text = String(format: "%d:%02d.%02d", min, sec, ms)

    // Blink dot
    recordingDot.alpha = (Int(dur * 2) % 2 == 0) ? 1 : 0
  }

  private func lockRecording() {
    guard isRecording, !isLocked else { return }
    isLocked = true
    notificationFeedback.notificationOccurred(.success)

    vadTimer?.invalidate()
    micVADView.stop()

    slideToCancelLabel.text = "Cancel"
    slideChevronView.isHidden = true
    lockPill.isHidden = true
    cancelOverlayButton.isHidden = false

    let sendIcon = UIImage(
      systemName: "arrow.up.circle.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))
    UIView.transition(with: micButton, duration: 0.2, options: .transitionCrossDissolve) {
      self.micButton.setImage(sendIcon, for: .normal)
      self.micButton.tintColor =
        self.appearance.bubbleMeGradient.first
        ?? self.appearance.textColorThem.withAlphaComponent(0.9)
    }

    stopRecordingHintAnimations()
    slideToCancelLabel.transform = .identity
    lockPill.transform = .identity
    setNeedsLayout()
    layoutIfNeeded()

    delegate?.inputBarRecordingStateDidChange(isRecording: true, isLocked: true, mode: "voice")
  }

  private func cancelRecording() {
    guard isRecording else { return }
    isRecording = false
    isLocked = false
    notificationFeedback.notificationOccurred(.error)

    vadTimer?.invalidate()
    vadTimer = nil
    recordingTimer?.invalidate()
    recordingTimer = nil
    micVADView.stop()

    // Setup animated UI
    let dotStart = pillContainer.convert(recordingDot.center, to: self)
    let dotEnd = contentRow.convert(attachButton.center, to: self)

    let animatedDot = UIView(frame: CGRect(x: 0, y: 0, width: 6, height: 6))
    animatedDot.backgroundColor = .systemRed
    animatedDot.layer.cornerRadius = 3
    animatedDot.center = dotStart
    addSubview(animatedDot)

    resetUI(revealAttach: false)

    // Setup Glass Trash View replacing the plus icon
    let attachHeight = attachButton.bounds.height
    let trashContainer = UIView(frame: CGRect(x: 0, y: 0, width: sideSize, height: attachHeight))
    trashContainer.center = dotEnd
    addSubview(trashContainer)

    let glassTarget = UIVisualEffectView()
    if #available(iOS 26.0, *) {
      glassTarget.effect = UIGlassEffect()
      glassTarget.cornerConfiguration = .capsule()
    } else {
      glassTarget.effect = UIBlurEffect(style: .systemMaterial)
      glassTarget.layer.cornerRadius = sideSize / 2
      glassTarget.clipsToBounds = true
    }
    glassTarget.frame = trashContainer.bounds
    glassTarget.isUserInteractionEnabled = false
    trashContainer.addSubview(glassTarget)

    let trashIcon = UIImageView(
      image: UIImage(
        systemName: "trash.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
      )
    )
    trashIcon.tintColor = .systemRed
    trashIcon.center = CGPoint(x: sideSize / 2, y: attachHeight / 2)
    trashContainer.addSubview(trashIcon)

    // Ensure dot is above the trash icon
    bringSubviewToFront(animatedDot)

    let path = UIBezierPath()
    path.move(to: dotStart)
    path.addQuadCurve(
      to: dotEnd, controlPoint: CGPoint(x: (dotStart.x + dotEnd.x) / 2, y: dotStart.y - 40))

    let jumpAnim = CAKeyframeAnimation(keyPath: "position")
    jumpAnim.path = path.cgPath
    jumpAnim.duration = 0.35
    jumpAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    CATransaction.begin()
    CATransaction.setCompletionBlock {
      // Step 2: Dot is at the trash, make it fall in
      UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseIn]) {
        animatedDot.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
        animatedDot.alpha = 0
        // Trash "closes door" with a squish
        trashIcon.transform = CGAffineTransform(scaleX: 0.8, y: 0.8).translatedBy(x: 0, y: 3)
      } completion: { _ in
        UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseOut]) {
          trashIcon.transform = .identity
        } completion: { _ in
          animatedDot.removeFromSuperview()

          // Step 3: Zigzag animation
          let jumpDist: CGFloat = 3.0
          let dur = 0.05
          UIView.animate(withDuration: dur, delay: 0, options: .curveLinear) {
            trashIcon.transform = CGAffineTransform(rotationAngle: -0.1).translatedBy(
              x: -jumpDist, y: 0)
          } completion: { _ in
            UIView.animate(withDuration: dur, delay: 0, options: .curveLinear) {
              trashIcon.transform = CGAffineTransform(rotationAngle: 0.1).translatedBy(
                x: jumpDist, y: 0)
            } completion: { _ in
              UIView.animate(withDuration: dur, delay: 0, options: .curveLinear) {
                trashIcon.transform = CGAffineTransform(rotationAngle: -0.1).translatedBy(
                  x: -jumpDist, y: 0)
              } completion: { _ in
                UIView.animate(withDuration: dur, delay: 0, options: .curveLinear) {
                  trashIcon.transform = .identity
                } completion: { _ in
                  // Step 4: Reset back to plus icon
                  UIView.animate(withDuration: 0.2, delay: 0.2, options: .curveEaseInOut) {
                    trashContainer.alpha = 0
                    trashContainer.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                    self.attachButton.alpha = 1
                  } completion: { _ in
                    trashContainer.removeFromSuperview()
                  }
                }
              }
            }
          }
        }
      }
    }
    // Step 1: Open door & jump
    UIView.animate(withDuration: 0.2) {
      // Simulate "opening door" by lifting slightly
      trashIcon.transform = CGAffineTransform(translationX: 0, y: -2).scaledBy(x: 1.1, y: 1.1)
    }
    animatedDot.layer.add(jumpAnim, forKey: "jump")
    animatedDot.center = dotEnd
    CATransaction.commit()

    delegate?.inputBarRecordingDidCancel()
  }

  private func finishRecording() {
    guard isRecording else { return }
    isRecording = false
    isLocked = false
    notificationFeedback.notificationOccurred(.success)

    micVADView.stop()

    audioRecorder?.stop()
    let dur = Date().timeIntervalSince(recordingStartTime ?? Date())
    let waveform = downsampleWaveform(recordingWaveformSamples, targetCount: 28)
    let outputURI = recordingFileURL?.absoluteString ?? ""
    if !outputURI.isEmpty {
      delegate?.inputBarDidRecordVoice(uri: outputURI, duration: dur, waveform: waveform)
    }

    resetUI()
    recordingTimer?.invalidate()
    recordingTimer = nil
  }

  private func resetUI(revealAttach: Bool = true) {
    vadTimer?.invalidate()
    vadTimer = nil
    let rec = audioRecorder
    audioRecorder = nil

    DispatchQueue.global(qos: .userInitiated).async {
      rec?.stop()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    recordingStartTime = nil
    recordingFileURL = nil
    recordingWaveformSamples.removeAll(keepingCapacity: true)
    textView.alpha = 1
    textView.isUserInteractionEnabled = true
    textView.isHidden = false
    applyPlaceholder()
    placeholderLabel.alpha = 1
    slideToCancelLabel.isHidden = true
    slideChevronView.isHidden = true
    recordingTimerLabel.isHidden = true
    recordingDot.isHidden = true
    lockPill.isHidden = true
    slideToCancelLabel.transform = .identity
    slideChevronView.transform = .identity
    lockPill.transform = .identity
    stopRecordingHintAnimations()
    updateButtonStates(animated: true)
    setNeedsLayout()
    layoutIfNeeded()

    UIView.animate(
      withDuration: 0.26,
      delay: 0,
      usingSpringWithDamping: 0.9,
      initialSpringVelocity: 0.3,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.recordingExpandProgress = 0
      self.attachButton.transform = .identity
      self.attachButton.alpha = revealAttach ? 1 : 0
      self.micButton.transform = .identity
      self.micGlass.transform = .identity
      self.micVADView.transform = .identity
      self.micButton.alpha = 1
      self.micGlass.backgroundColor = .clear

      let micCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
      self.micButton.setImage(
        UIImage(systemName: "mic.fill", withConfiguration: micCfg), for: .normal)
      self.micButton.tintColor = self.appearance.textColorThem.withAlphaComponent(0.9)

      self.cancelOverlayButton.isHidden = true

      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }
  }

  private func downsampleWaveform(_ samples: [CGFloat], targetCount: Int) -> [Double] {
    guard targetCount > 0 else { return [] }
    let sanitized = samples
      .map { max(0.0, min(1.0, $0)) }
      .filter { $0.isFinite }
    guard !sanitized.isEmpty else {
      return Array(repeating: 0.18, count: targetCount)
    }
    if sanitized.count == targetCount {
      return sanitized.map(Double.init)
    }
    let bucketSize = Double(sanitized.count) / Double(targetCount)
    var result: [Double] = []
    result.reserveCapacity(targetCount)
    for index in 0..<targetCount {
      let start = Int(floor(Double(index) * bucketSize))
      let end = min(sanitized.count, Int(floor(Double(index + 1) * bucketSize)))
      if start < end {
        let slice = sanitized[start..<end]
        let avg = slice.reduce(0.0, +) / CGFloat(slice.count)
        result.append(Double(max(0.12, avg)))
      } else {
        let clampedIndex = min(max(0, start), sanitized.count - 1)
        result.append(Double(max(0.12, sanitized[clampedIndex])))
      }
    }
    return result
  }

  private func startRecordingHintAnimations() {
    slideChevronView.layer.removeAllAnimations()
    slideToCancelLabel.layer.removeAllAnimations()
    lockArrowView.layer.removeAllAnimations()

    UIView.animate(
      withDuration: 0.55,
      delay: 0,
      options: [.allowUserInteraction, .autoreverse, .repeat, .curveEaseInOut]
    ) {
      self.slideChevronView.transform = CGAffineTransform(translationX: -8, y: 0)
      self.slideToCancelLabel.transform = CGAffineTransform(translationX: -8, y: 0)
    }

    UIView.animate(
      withDuration: 0.52,
      delay: 0,
      options: [.allowUserInteraction, .autoreverse, .repeat, .curveEaseInOut]
    ) {
      self.lockArrowView.transform = CGAffineTransform(translationX: 0, y: -6)
    }
  }

  private func stopRecordingHintAnimations() {
    slideChevronView.layer.removeAllAnimations()
    slideToCancelLabel.layer.removeAllAnimations()
    lockArrowView.layer.removeAllAnimations()
    slideChevronView.transform = .identity
    slideToCancelLabel.transform = .identity
    lockArrowView.transform = .identity
  }
}  // End Class

// MARK: - ChatGifPanelViewDelegate

extension ChatInputBar: ChatGifPanelViewDelegate {
  func chatGifPanel(_ panel: ChatGifPanelView, didSelectGif gif: ChatGifSelection) {
    delegate?.inputBarDidSelectGif(
      id: gif.id,
      url: gif.url,
      previewUrl: gif.previewUrl,
      width: gif.width,
      height: gif.height
    )
    setGifPanelVisible(false, animated: true)
  }

  func chatGifPanelDidRequestClose(_ panel: ChatGifPanelView) {
    setGifPanelVisible(false, animated: true)
  }
}

// MARK: - UITextViewDelegate

extension ChatInputBar: UITextViewDelegate {
  func textViewDidBeginEditing(_ textView: UITextView) {
    setGifPanelVisible(false, animated: true)
  }

  func textViewDidChange(_ tv: UITextView) {
    applyPlaceholder()
    updateButtonStates(animated: true)
    delegate?.inputBarTextDidChange(text: tv.text ?? "")
    // Animate pill height change when text wraps to new lines
    UIView.animate(
      withDuration: 0.25, delay: 0,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      // Also animate parent (ChatListView) to adjust collection view inset
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }
  }

  func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String)
    -> Bool
  {
    if text == "\n" {
      let t = currentText
      if !t.isEmpty { delegate?.inputBarDidSend(text: t) }
      return false
    }
    return true
  }
}

// MARK: - ChatAttachmentSheet
// Native bottom sheet matching AttachmentMenu.tsx: Gallery | File | Location | Contact tabs

final class ChatAttachmentSheet: UIViewController {

  var onSelectImage: ((String) -> Void)?
  var onSelectFile: ((String, String) -> Void)?
  var onSelectLocation: ((Double, Double) -> Void)?

  private let appearance: ChatListAppearance
  private let tabs = ["Gallery", "File", "Location", "Contact"]
  private var activeTab = 0

  private let handleBar = UIView()
  private let tabBar = UISegmentedControl()
  private let contentArea = UIView()
  private let backgroundGlass = UIVisualEffectView(effect: nil)

  init(appearance: ChatListAppearance) {
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
    if let sheet = sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 24
    }
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    // Glass background
    applyGlass(to: backgroundGlass)
    backgroundGlass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(backgroundGlass)

    // Handle bar
    handleBar.backgroundColor = UIColor(white: 0.5, alpha: 0.4)
    handleBar.layer.cornerRadius = 2.5
    view.addSubview(handleBar)

    // Tab bar (mirrors AttachmentMenu tabs)
    tabBar.insertSegment(withTitle: "📷 Gallery", at: 0, animated: false)
    tabBar.insertSegment(withTitle: "📄 File", at: 1, animated: false)
    tabBar.insertSegment(withTitle: "📍 Location", at: 2, animated: false)
    tabBar.insertSegment(withTitle: "👤 Contact", at: 3, animated: false)
    tabBar.selectedSegmentIndex = 0
    tabBar.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
    view.addSubview(tabBar)

    // Content area
    contentArea.backgroundColor = .clear
    view.addSubview(contentArea)

    showTab(0)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let w = view.bounds.width
    let safeTop = view.safeAreaInsets.top

    backgroundGlass.frame = view.bounds

    handleBar.frame = CGRect(x: (w - 36) / 2, y: safeTop + 8, width: 36, height: 5)
    tabBar.frame = CGRect(x: 16, y: handleBar.frame.maxY + 16, width: w - 32, height: 36)
    contentArea.frame = CGRect(
      x: 0, y: tabBar.frame.maxY + 12,
      width: w, height: view.bounds.height - tabBar.frame.maxY - 12)
  }

  @objc private func tabChanged() {
    showTab(tabBar.selectedSegmentIndex)
  }

  private func showTab(_ index: Int) {
    activeTab = index
    contentArea.subviews.forEach { $0.removeFromSuperview() }

    switch index {
    case 0: showGalleryTab()
    case 1: pickFile()
    case 2: pickLocation()
    case 3: showContactPlaceholder()
    default: break
    }
  }

  // MARK: Gallery tab

  private func showGalleryTab() {
    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = 10
    config.filter = .any(of: [.images, .videos])
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    addChild(picker)
    picker.view.frame = contentArea.bounds
    picker.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentArea.addSubview(picker.view)
    picker.didMove(toParent: self)
  }

  // MARK: File tab

  private func pickFile() {
    let types: [UTType] = [.item]
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  // MARK: Location tab

  private func pickLocation() {
    // Simple: use device location
    let label = UILabel()
    label.text = "Fetching location…"
    label.textAlignment = .center
    label.textColor = .secondaryLabel
    label.frame = contentArea.bounds
    label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentArea.addSubview(label)

    // CoreLocation fetch
    let locMgr = CLLocationManagerWrapper.shared
    locMgr.requestOnce { [weak self] coord in
      DispatchQueue.main.async {
        guard let self else { return }
        self.onSelectLocation?(coord.latitude, coord.longitude)
        self.dismiss(animated: true)
      }
    }
  }

  // MARK: Contact placeholder

  private func showContactPlaceholder() {
    let label = UILabel()
    label.text = "Contact sharing coming soon"
    label.textAlignment = .center
    label.textColor = .secondaryLabel
    label.frame = contentArea.bounds
    label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentArea.addSubview(label)
  }

  // MARK: Glass helper

  private func applyGlass(to v: UIVisualEffectView) {
    if #available(iOS 26.0, *) {
      v.effect = UIGlassEffect()
    } else {
      v.effect = UIBlurEffect(style: .systemMaterial)
    }
  }
}

// MARK: PHPickerViewControllerDelegate

extension ChatAttachmentSheet: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    dismiss(animated: true)
    guard let first = results.first else { return }
    first.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
      [weak self] url, _ in
      guard let url else { return }
      DispatchQueue.main.async {
        self?.onSelectImage?(url.absoluteString)
        self?.dismiss(animated: true)
      }
    }
  }
}

// MARK: UIDocumentPickerDelegate

extension ChatAttachmentSheet: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    guard let url = urls.first else { return }
    onSelectFile?(url.absoluteString, url.lastPathComponent)
    dismiss(animated: true)
  }
}

// MARK: - CLLocationManagerWrapper (simple one-shot)

private final class CLLocationManagerWrapper: NSObject, CLLocationManagerDelegate {
  static let shared = CLLocationManagerWrapper()
  private let manager = CLLocationManager()
  private var callback: ((CLLocationCoordinate2D) -> Void)?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  func requestOnce(_ cb: @escaping (CLLocationCoordinate2D) -> Void) {
    callback = cb
    manager.requestWhenInUseAuthorization()
    manager.requestLocation()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let loc = locations.first else { return }
    callback?(loc.coordinate)
    callback = nil
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    callback = nil
  }
}
