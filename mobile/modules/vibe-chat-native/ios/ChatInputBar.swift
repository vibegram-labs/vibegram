import AVFoundation
import CoreLocation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Delegate

protocol ChatInputBarDelegate: AnyObject {
  func inputBarDidSend(text: String)
  func inputBarDidSendWithAgentMention(text: String, agentText: String)
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
  func inputBarDidRecordVideoNote(uri: String, duration: Double)
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
    for l in layers {
      l.bounds = bounds
      l.position = center
      l.path = UIBezierPath(ovalIn: bounds).cgPath
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
    time += 0.05
    for (i, l) in layers.enumerated() {
      let idx = CGFloat(i + 1)

      let idlePulse = sin(time * 2.0 + CGFloat(i * 2)) * 0.04
      let activePush = level * 0.4 * idx
      let finalScale = 1.0 + idlePulse + activePush

      l.transform = CATransform3DMakeScale(finalScale, finalScale, 1.0)

      let baseOpacity = max(0.0, 1.0 - (finalScale - 1.0) * 1.5)
      l.opacity = Float(baseOpacity * 0.6)
    }
  }
}

private final class ChatComposerTextView: UITextView {
  override func paste(_ sender: Any?) {
    if let clipboardText = UIPasteboard.general.string, !clipboardText.isEmpty {
      if let selected = selectedTextRange {
        replace(selected, withText: clipboardText)
      } else {
        insertText(clipboardText)
      }
      return
    }
    super.paste(sender)
  }
}

private final class VideoNoteRecorderViewController: UIViewController,
  AVCaptureFileOutputRecordingDelegate
{
  var onFinished: ((URL?, Double, Bool) -> Void)?

  private let session = AVCaptureSession()
  private let movieOutput = AVCaptureMovieFileOutput()
  private let sessionQueue = DispatchQueue(label: "chat.video.note.session", qos: .userInitiated)
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private let backdropBlur = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let circleContainer = UIView()
  private let circleLoadingBlur = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemMaterialDark))
  private let circleLoadingShade = UIView()
  private let circleSpinner = UIActivityIndicatorView(style: .large)
  private let hintLabel = UILabel()

  private var startedAt: Date?
  private var pendingSend = true
  private var stopRequested = false
  private var hasAppeared = false
  private var didFinish = false
  private var isSessionConfigured = false
  private var hasStartedFileRecording = false
  private var recordingStartTimeoutWorkItem: DispatchWorkItem?

  private let progressLayer = CAShapeLayer()
  private var displayLink: CADisplayLink?
  private let maxDuration: TimeInterval = 60.0
  private let closeButton = UIButton(type: .system)

  override var prefersStatusBarHidden: Bool { true }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = true
    backdropBlur.frame = view.bounds
    backdropBlur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    backdropBlur.alpha = 0.88
    view.addSubview(backdropBlur)

    circleContainer.backgroundColor = .black
    circleContainer.clipsToBounds = true
    circleContainer.alpha = 0
    circleContainer.transform = CGAffineTransform(translationX: 0, y: 28).scaledBy(x: 0.92, y: 0.92)
    view.addSubview(circleContainer)

    circleLoadingBlur.isUserInteractionEnabled = false
    circleLoadingBlur.alpha = 1.0
    circleContainer.addSubview(circleLoadingBlur)

    circleLoadingShade.backgroundColor = UIColor.black.withAlphaComponent(0.12)
    circleLoadingShade.isUserInteractionEnabled = false
    circleLoadingShade.alpha = 1.0
    circleContainer.addSubview(circleLoadingShade)

    circleSpinner.hidesWhenStopped = true
    circleSpinner.color = UIColor.white.withAlphaComponent(0.9)
    circleSpinner.startAnimating()
    circleContainer.addSubview(circleSpinner)

    progressLayer.strokeColor = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0).cgColor
    progressLayer.lineWidth = 4
    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.lineCap = .round
    progressLayer.strokeEnd = 0
    // Put progress layer directly in view so it perfectly aligns over circleContainer without being clipped by it
    view.layer.addSublayer(progressLayer)

    let xCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: xCfg), for: .normal)
    closeButton.tintColor = .white
    closeButton.backgroundColor = UIColor(white: 0, alpha: 0.5)
    closeButton.layer.cornerRadius = 20
    closeButton.alpha = 0
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    view.addSubview(closeButton)

    hintLabel.text = "Recording Video Note..."
    hintLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    hintLabel.textColor = UIColor.white.withAlphaComponent(0.92)
    hintLabel.textAlignment = .center
    hintLabel.numberOfLines = 1
    hintLabel.alpha = 0
    view.addSubview(hintLabel)
  }

  deinit {
    recordingStartTimeoutWorkItem?.cancel()
    displayLink?.invalidate()
  }

  @objc private func closeTapped() {
    stopRecording(send: false)
  }

  @objc private func updateProgress() {
    guard let start = startedAt else { return }
    let elapsed = Date().timeIntervalSince(start)
    let progress = min(1.0, CGFloat(elapsed / maxDuration))
    progressLayer.strokeEnd = progress
    if elapsed >= maxDuration {
      stopRecording(send: true)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let side = min(view.bounds.width - 52, 300)
    let circleFrame = CGRect(
      x: (view.bounds.width - side) * 0.5,
      y: (view.bounds.height - side) * 0.5 - 20,
      width: side,
      height: side
    )
    circleContainer.frame = circleFrame
    circleContainer.layer.cornerRadius = side * 0.5
    circleLoadingBlur.frame = circleContainer.bounds
    circleLoadingShade.frame = circleContainer.bounds
    circleSpinner.center = CGPoint(x: circleContainer.bounds.midX, y: circleContainer.bounds.midY)

    let path = UIBezierPath(
      arcCenter: CGPoint(x: circleFrame.midX, y: circleFrame.midY),
      radius: (side * 0.5) + 3.0,
      startAngle: -.pi / 2,
      endAngle: (-.pi / 2) + (.pi * 2),
      clockwise: true
    )
    progressLayer.path = path.cgPath

    closeButton.frame = CGRect(
      x: circleFrame.midX - 20,
      y: circleFrame.maxY + 24,
      width: 40,
      height: 40
    )

    hintLabel.frame = CGRect(
      x: 24,
      y: closeButton.frame.maxY + 16,
      width: view.bounds.width - 48,
      height: 22
    )
    previewLayer?.frame = circleContainer.bounds
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !hasAppeared else { return }
    hasAppeared = true
    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      usingSpringWithDamping: 0.86,
      initialSpringVelocity: 0.36,
      options: [.curveEaseOut, .beginFromCurrentState]
    ) {
      self.circleContainer.alpha = 1
      self.circleContainer.transform = .identity
      self.hintLabel.alpha = 1
      self.closeButton.alpha = 1
    }
    beginRecordingFlow()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    displayLink?.invalidate()
    displayLink = nil
    if isBeingDismissed || isMovingFromParent {
      stopSession()
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || isMovingFromParent, !didFinish {
      finish(url: nil, duration: 0.0, shouldSend: false)
    }
  }

  func stopRecording(send: Bool) {
    guard !didFinish else { return }
    pendingSend = send
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.movieOutput.isRecording {
        self.movieOutput.stopRecording()
      } else {
        self.stopRequested = true
        // If recording has not started yet, allow immediate cancel so the overlay
        // never gets stuck waiting for AVCapture callbacks that may not arrive.
        guard !send else { return }
        DispatchQueue.main.async {
          self.finish(url: nil, duration: 0.0, shouldSend: false)
        }
      }
    }
  }

  private func beginRecordingFlow() {
    requestCapturePermissions { [weak self] videoGranted, audioGranted in
      guard let self else { return }
      guard videoGranted else {
        self.finish(url: nil, duration: 0.0, shouldSend: false)
        return
      }
      self.configureSessionIfNeeded(includeAudio: audioGranted)
      self.startSessionAndRecording()
    }
  }

  private func requestCapturePermissions(
    completion: @escaping (_ videoGranted: Bool, _ audioGranted: Bool) -> Void
  ) {
    let completeOnMain: (Bool, Bool) -> Void = { video, audio in
      DispatchQueue.main.async { completion(video, audio) }
    }

    let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
    let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    func resolveAudio(givenVideo videoGranted: Bool) {
      if audioStatus == .authorized {
        completeOnMain(videoGranted, true)
        return
      }
      if audioStatus == .notDetermined {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          completeOnMain(videoGranted, granted)
        }
        return
      }
      completeOnMain(videoGranted, false)
    }

    if videoStatus == .authorized {
      resolveAudio(givenVideo: true)
      return
    }
    if videoStatus == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { granted in
        guard granted else {
          completeOnMain(false, false)
          return
        }
        let refreshedAudioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if refreshedAudioStatus == .authorized {
          completeOnMain(true, true)
        } else if refreshedAudioStatus == .notDetermined {
          AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
            completeOnMain(true, audioGranted)
          }
        } else {
          completeOnMain(true, false)
        }
      }
      return
    }
    completeOnMain(false, false)
  }

  private func configureSessionIfNeeded(includeAudio: Bool) {
    sessionQueue.sync {
      guard !isSessionConfigured else { return }

      session.beginConfiguration()
      if session.canSetSessionPreset(.vga640x480) {
        session.sessionPreset = .vga640x480
      }

      if let videoDevice = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .front)
        ?? AVCaptureDevice.default(for: .video),
        let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
        session.canAddInput(videoInput)
      {
        session.addInput(videoInput)
      }

      if includeAudio,
        let audioDevice = AVCaptureDevice.default(for: .audio),
        let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
        session.canAddInput(audioInput)
      {
        session.addInput(audioInput)
      }

      if session.canAddOutput(movieOutput) {
        session.addOutput(movieOutput)
      }
      movieOutput.maxRecordedDuration = CMTime(seconds: maxDuration, preferredTimescale: 600)

      if let connection = movieOutput.connection(with: .video) {
        if connection.isVideoMirroringSupported {
          connection.isVideoMirrored = true
        }
        if connection.isVideoStabilizationSupported {
          connection.preferredVideoStabilizationMode = .auto
        }
      }

      session.commitConfiguration()
      isSessionConfigured = true

      DispatchQueue.main.async {
        let preview = AVCaptureVideoPreviewLayer(session: self.session)
        preview.videoGravity = .resizeAspectFill
        self.previewLayer?.removeFromSuperlayer()
        self.previewLayer = preview
        self.circleContainer.layer.insertSublayer(preview, at: 0)
        self.view.setNeedsLayout()
      }
    }
  }

  private func startSessionAndRecording() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      guard self.isSessionConfigured, !self.didFinish else { return }
      if !self.session.isRunning {
        self.session.startRunning()
      }
      if self.stopRequested && !self.pendingSend {
        DispatchQueue.main.async {
          self.finish(url: nil, duration: 0.0, shouldSend: false)
        }
        return
      }
      let fm = FileManager.default
      let base =
        fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? fm.temporaryDirectory
      let dir = base.appendingPathComponent("video-notes", isDirectory: true)
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let outputURL =
        dir
        .appendingPathComponent("video-note-\(UUID().uuidString)")
        .appendingPathExtension("mov")
      self.startedAt = Date()

      DispatchQueue.main.async {
        self.displayLink?.invalidate()
        self.displayLink = CADisplayLink(target: self, selector: #selector(self.updateProgress))
        self.displayLink?.add(to: .main, forMode: .common)
        self.armRecordingStartTimeout()
      }

      self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
    }
  }

  private func stopSession() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.movieOutput.isRecording {
        self.movieOutput.stopRecording()
      }
      if self.session.isRunning {
        self.session.stopRunning()
      }
      DispatchQueue.main.async {
        self.displayLink?.invalidate()
        self.displayLink = nil
      }
    }
  }

  private func finish(url: URL?, duration: Double, shouldSend: Bool) {
    guard !didFinish else { return }
    didFinish = true
    recordingStartTimeoutWorkItem?.cancel()
    recordingStartTimeoutWorkItem = nil

    let callback = {
      let cb = self.onFinished
      self.onFinished = nil
      cb?(url, duration, shouldSend)
    }

    if presentingViewController != nil {
      dismiss(animated: true) {
        callback()
      }
    } else {
      callback()
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    hasStartedFileRecording = true
    DispatchQueue.main.async {
      self.recordingStartTimeoutWorkItem?.cancel()
      self.recordingStartTimeoutWorkItem = nil
      self.revealCameraPreviewIfReady(animated: true)
    }
    sessionQueue.async { [weak self] in
      guard let self else { return }
      guard self.stopRequested else { return }
      self.movieOutput.stopRecording()
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    DispatchQueue.main.async {
      self.recordingStartTimeoutWorkItem?.cancel()
      self.recordingStartTimeoutWorkItem = nil
    }
    let elapsed = max(0.0, Date().timeIntervalSince(startedAt ?? Date()))
    let shouldSend = pendingSend && error == nil
    stopSession()
    DispatchQueue.main.async {
      self.finish(
        url: shouldSend ? outputFileURL : nil,
        duration: elapsed,
        shouldSend: shouldSend
      )
    }
  }

  private func armRecordingStartTimeout() {
    recordingStartTimeoutWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      guard !self.didFinish, !self.hasStartedFileRecording else { return }
      self.pendingSend = false
      self.stopRequested = true
      self.finish(url: nil, duration: 0.0, shouldSend: false)
    }
    recordingStartTimeoutWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
  }

  private func revealCameraPreviewIfReady(animated: Bool) {
    let animations = {
      self.circleLoadingBlur.alpha = 0.0
      self.circleLoadingShade.alpha = 0.0
    }
    if animated {
      UIView.animate(
        withDuration: 0.26,
        delay: 0.06,
        options: [.curveEaseOut, .beginFromCurrentState]
      ) {
        animations()
      } completion: { _ in
        self.circleSpinner.stopAnimating()
      }
    } else {
      animations()
      circleSpinner.stopAnimating()
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
  private let pillTapOverlay = UIView()
  private let textView = ChatComposerTextView()
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
  private var isVideoMode: Bool = false
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
  private var replyBannerAnimatingOut = false
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
  private var attachmentSheet: ChatAttachmentMenuController?
  private let glassPressedOverlayColor = UIColor(white: 1.0, alpha: 0.08)

  // Background Mask (for fade-out blur behind input)
  private let backgroundMaskView = UIView()
  private let backgroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let backgroundOverlayView = UIView()
  private let backgroundGradientLayer = CAGradientLayer()

  // Appearance
  private var appearance = ChatListAppearance.fallback
  private var pillTint: UIColor? = ChatListAppearance.fallback.bubbleThemColor.withAlphaComponent(
    0.14)

  // MARK: Layout constants
  private let sideSize: CGFloat = 36
  private let sideGap: CGFloat = 6
  private let topVPad: CGFloat = 6
  private let bottomVPad: CGFloat = 5
  private let panelGapV: CGFloat = 6
  private let composerSafeBottomReduction: CGFloat = 6
  private let backgroundMaskTopOverlap: CGFloat = 0
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

  // Mention suggestion banner (inside pill, above text row — like reply banner)
  private let mentionBanner = UIView()
  private let mentionIconContainer = UIView()
  private let mentionIconLabel = UILabel()
  private let mentionNameLabel = UILabel()
  private let mentionDescLabel = UILabel()
  private var mentionBannerVisible = false
  private let mentionBannerContentH: CGFloat = 40
  private let mentionBannerGap: CGFloat = 4
  private var mentionActive = false  // true when @vibe is confirmed in text
  private let mentionBorderGlowLayer = CALayer()

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
  private enum RecordingMode {
    case none
    case voice
    case video
  }

  private var isRecording = false
  private var isLocked = false
  private var recordingMode: RecordingMode = .none
  private var isVideoRecordingActive = false
  private var pendingVideoStopShouldSend = true
  private var suppressNextMicTap = false
  private var isCancelZoneActive = false

  private var lastMeasuredTextHeight: CGFloat = -1

  private weak var videoNoteRecorderController: VideoNoteRecorderViewController?
  private let feedback = UIImpactFeedbackGenerator(style: .medium)
  private let notificationFeedback = UINotificationFeedbackGenerator()
  private let inputTapFeedback = UISelectionFeedbackGenerator()

  private func recordingModeString(_ mode: RecordingMode? = nil) -> String {
    switch mode ?? recordingMode {
    case .voice: return "voice"
    case .video: return "video"
    case .none: return "voice"
    }
  }

  func showReplyBanner(messageId: String, text: String, isMe: Bool) {
    replyBanner.layer.removeAllAnimations()
    restorePillGlassVisualState()
    activeReplyToMessageId = messageId
    replySenderLabel.text = isMe ? "You" : "Reply"
    replyPreviewLabel.text = text
    replyBanner.transform = .identity
    replyBannerAnimatingOut = false
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
    replyBannerAnimatingOut = false

    let applyLayout = {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    if animated {
      restorePillGlassVisualState()
      replyBannerAnimatingOut = true
      replyBanner.alpha = 1
      replyBanner.transform = .identity
      replyBanner.isHidden = false
      UIView.animate(
        withDuration: 0.1, delay: 0,
        options: [.curveEaseOut, .beginFromCurrentState]
      ) {
        self.replyBanner.alpha = 0
      }
      UIView.animate(
        withDuration: 0.18, delay: 0,
        options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        applyLayout()
      } completion: { _ in
        if !self.replyBannerVisible {
          self.replyBannerAnimatingOut = false
          self.replyBanner.transform = .identity
          self.replyBanner.alpha = 0
          self.replyBanner.isHidden = true
          self.restorePillGlassVisualState()
        }
      }
    } else {
      replyBannerAnimatingOut = false
      replyBanner.transform = .identity
      replyBanner.alpha = 0
      replyBanner.isHidden = true
      UIView.performWithoutAnimation {
        applyLayout()
      }
      restorePillGlassVisualState()
    }
  }

  private func restorePillGlassVisualState() {
    pillContainer.isHidden = false
    pillContainer.alpha = 1
    pillContainer.backgroundColor = .clear
    pillContainer.transform = .identity

    pillGlass.isHidden = false
    pillGlass.alpha = 1
    pillTapOverlay.alpha = 0
    refreshGlass()
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
    // ── 0. Background Masked Blur ─────────────────────────────────────────
    backgroundMaskView.isUserInteractionEnabled = false
    addSubview(backgroundMaskView)

    backgroundMaskView.addSubview(backgroundBlurView)
    backgroundBlurView.contentView.addSubview(backgroundOverlayView)

    backgroundGradientLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.92).cgColor,
    ]
    backgroundGradientLayer.locations = [0.1, 1.0]
    backgroundMaskView.layer.mask = backgroundGradientLayer

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

    pillTapOverlay.isUserInteractionEnabled = false
    pillTapOverlay.backgroundColor = glassPressedOverlayColor
    pillTapOverlay.alpha = 0
    pillTapOverlay.layer.cornerCurve = .continuous
    pillContainer.addSubview(pillTapOverlay)

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
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsEditingTextAttributes = false
    textView.isScrollEnabled = false
    // Keep multiline input behavior: show "return" key instead of iOS blue "send".
    textView.returnKeyType = .default
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

    // ── Mention suggestion banner (INSIDE pill, above text row — like reply banner) ──
    mentionBanner.backgroundColor = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 0.10)
    mentionBanner.clipsToBounds = true
    mentionBanner.isHidden = true
    mentionBanner.alpha = 0

    let mentionTap = UITapGestureRecognizer(target: self, action: #selector(mentionBannerTapped))
    mentionBanner.addGestureRecognizer(mentionTap)
    pillContainer.addSubview(mentionBanner)

    mentionIconContainer.backgroundColor = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 0.18)
    mentionIconContainer.layer.cornerRadius = 8
    mentionIconContainer.layer.cornerCurve = .continuous
    mentionBanner.addSubview(mentionIconContainer)

    mentionIconLabel.text = "\u{2726}"
    mentionIconLabel.font = UIFont.systemFont(ofSize: 14, weight: .bold)
    mentionIconLabel.textColor = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    mentionIconLabel.textAlignment = .center
    mentionIconContainer.addSubview(mentionIconLabel)

    mentionNameLabel.text = "@vibe"
    mentionNameLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    mentionNameLabel.textColor = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    mentionBanner.addSubview(mentionNameLabel)

    mentionDescLabel.text = "Ask AI"
    mentionDescLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    mentionDescLabel.textColor = UIColor(white: 0.7, alpha: 1.0)
    mentionBanner.addSubview(mentionDescLabel)

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
    let micCfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    micButton.setImage(UIImage(systemName: "mic", withConfiguration: micCfg), for: .normal)
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
    configureInputTapFeedback()
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

    // Evaluate if theme is light or dark based on textColorThem luminance roughly
    var white: CGFloat = 0
    if a.textColorThem.getWhite(&white, alpha: nil) {
      let isDark = white > 0.5
      backgroundBlurView.effect = UIBlurEffect(style: isDark ? .dark : .light)
    } else {
      backgroundBlurView.effect = UIBlurEffect(style: .regular)
    }

    let baseColor = a.wallpaperGradient.first ?? UIColor.black
    backgroundOverlayView.backgroundColor = baseColor.withAlphaComponent(0.88)

    // Mention suggestion banner (inside pill)
    mentionBanner.backgroundColor =
      (a.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0))
      .withAlphaComponent(0.10)
    mentionDescLabel.textColor = a.textColorThem.withAlphaComponent(0.5)
    mentionNameLabel.textColor =
      a.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    mentionIconLabel.textColor =
      a.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    mentionIconContainer.backgroundColor =
      (a.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0))
      .withAlphaComponent(0.18)

    refreshGlass()
    CATransaction.commit()
  }

  // MARK: - Public helpers

  func clearText() {
    textView.text = ""
    setMentionBannerVisible(false, animated: false)
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

  struct SendTransitionCapture {
    let sourceContainerRect: CGRect
    let sourceBackgroundRectInContainer: CGRect
    let sourceContentRectInContainer: CGRect
    let sourceScrollOffset: CGFloat
    let sourceBackgroundSnapshotView: UIView?
    let sourceContentSnapshotView: UIView?
  }

  private func makeTextContentSnapshot() -> UIView? {
    let textBounds = textView.bounds
    guard textBounds.width > 1.0, textBounds.height > 1.0 else { return nil }
    let previousTint = textView.tintColor
    textView.tintColor = .clear
    defer {
      textView.tintColor = previousTint
    }
    guard let snapshot = textView.snapshotView(afterScreenUpdates: true) else {
      return nil
    }
    return snapshot
  }

  private func makeBackgroundSnapshot(captureRect: CGRect) -> UIView? {
    guard captureRect.width > 1.0, captureRect.height > 1.0 else { return nil }
    let emptyView = UIView(frame: captureRect)
    emptyView.backgroundColor = .clear  // Native transparent pill snapshot just like Telegram!
    emptyView.isOpaque = false
    emptyView.clipsToBounds = false
    return emptyView
  }

  /// Captures Telegram-style transition inputs in one call:
  ///   - source container rect (host coords)
  ///   - source background rect (container-local)
  ///   - source content rect + snapshot (container-local)
  ///   - source content scroll offset
  func captureSendTransition(in view: UIView) -> SendTransitionCapture? {
    guard !textView.bounds.isEmpty, !pillContainer.bounds.isEmpty else {
      return nil
    }
    layoutIfNeeded()

    let sourceContainerRect = pillContainer.convert(pillContainer.bounds.integral, to: view)
    guard sourceContainerRect.width > 1.0, sourceContainerRect.height > 1.0 else {
      return nil
    }

    let containerBounds = pillContainer.bounds.insetBy(dx: 1, dy: 1)
    var backgroundRect = containerBounds
    if !sendButton.isHidden, sendButton.alpha > 0.01 {
      let maxX = max(backgroundRect.minX + 1.0, sendButton.frame.minX - 2.0)
      backgroundRect.size.width = max(1.0, maxX - backgroundRect.minX)
    }
    backgroundRect = backgroundRect.intersection(containerBounds)
    if backgroundRect.isNull || backgroundRect.width <= 1.0 || backgroundRect.height <= 1.0 {
      backgroundRect = containerBounds
    }

    var contentRect = textView.frame
    contentRect = contentRect.intersection(pillContainer.bounds.insetBy(dx: 1, dy: 1))
    if contentRect.isNull || contentRect.width <= 1.0 || contentRect.height <= 1.0 {
      contentRect = backgroundRect.insetBy(dx: 8, dy: 8)
    }
    let sourceBackgroundRectInContainer = backgroundRect.integral
    let sourceContentRectInContainer = contentRect.integral

    let sourceBackgroundSnapshotView: UIView? = {
      guard let imageView = makeBackgroundSnapshot(captureRect: sourceBackgroundRectInContainer)
      else { return nil }
      imageView.frame = sourceBackgroundRectInContainer
      return imageView
    }()

    let sourceContentSnapshotView: UIView? = {
      guard let imageView = makeTextContentSnapshot() else { return nil }
      imageView.frame = sourceContentRectInContainer
      imageView.backgroundColor = .clear
      imageView.isOpaque = false
      imageView.clipsToBounds = false
      return imageView
    }()

    return SendTransitionCapture(
      sourceContainerRect: sourceContainerRect,
      sourceBackgroundRectInContainer: sourceBackgroundRectInContainer,
      sourceContentRectInContainer: sourceContentRectInContainer,
      sourceScrollOffset: textView.contentOffset.y,
      sourceBackgroundSnapshotView: sourceBackgroundSnapshotView,
      sourceContentSnapshotView: sourceContentSnapshotView
    )
  }

  /// Approximate Telegram's text-input background frame (without side action icons).
  func transitionBackgroundRect(in view: UIView) -> CGRect {
    if let capture = captureSendTransition(in: view) {
      return CGRect(
        x: capture.sourceContainerRect.minX + capture.sourceBackgroundRectInContainer.minX,
        y: capture.sourceContainerRect.minY + capture.sourceBackgroundRectInContainer.minY,
        width: capture.sourceBackgroundRectInContainer.width,
        height: capture.sourceBackgroundRectInContainer.height
      )
    }
    return pillRect(in: view)
  }

  /// Deprecated path kept for compatibility with existing call sites.
  func transitionBackgroundSnapshot(in view: UIView) -> UIView? {
    guard let capture = captureSendTransition(in: view) else { return nil }
    if let snapshot = capture.sourceBackgroundSnapshotView {
      snapshot.frame = CGRect(
        x: capture.sourceContainerRect.minX + capture.sourceBackgroundRectInContainer.minX,
        y: capture.sourceContainerRect.minY + capture.sourceBackgroundRectInContainer.minY,
        width: capture.sourceBackgroundRectInContainer.width,
        height: capture.sourceBackgroundRectInContainer.height
      )
      return snapshot
    }
    return nil
  }

  /// Returns the frame of the text area in the given coordinate space (used for send transition source rect).
  func textRect(in view: UIView) -> CGRect {
    if let capture = captureSendTransition(in: view) {
      return CGRect(
        x: capture.sourceContainerRect.minX + capture.sourceContentRectInContainer.minX,
        y: capture.sourceContainerRect.minY + capture.sourceContentRectInContainer.minY,
        width: capture.sourceContentRectInContainer.width,
        height: capture.sourceContentRectInContainer.height
      )
    }
    return textView.convert(textView.bounds, to: view)
  }

  /// Captures a live snapshot of the text view content for crossfade transitions.
  /// Returns a view positioned in the coordinate space of `view`, or nil if capture fails.
  func textContentSnapshot(in view: UIView) -> UIView? {
    guard let capture = captureSendTransition(in: view) else {
      return nil
    }
    guard let snapshot = capture.sourceContentSnapshotView else {
      return nil
    }
    snapshot.frame = CGRect(
      x: capture.sourceContainerRect.minX + capture.sourceContentRectInContainer.minX,
      y: capture.sourceContainerRect.minY + capture.sourceContentRectInContainer.minY,
      width: capture.sourceContentRectInContainer.width,
      height: capture.sourceContentRectInContainer.height
    )
    return snapshot
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    guard w > 0 else { return }
    maybePrepareGifPanel()

    // Keep the composer slightly closer to the bottom while still respecting
    // the home indicator area.
    let safeBottomReduction = gifPanelVisible ? 0 : composerSafeBottomReduction
    let safeBottom = max(0, bottomSafeAreaInset - safeBottomReduction)
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
    let replyBannerExtra: CGFloat = replyBannerVisible ? (replyBannerContentH + replyBannerGap) : 0
    let mentionBannerExtra: CGFloat =
      mentionBannerVisible ? (mentionBannerContentH + mentionBannerGap) : 0
    let bannerExtra: CGFloat = replyBannerExtra + mentionBannerExtra
    let pillH = clampedTextH + textInsetV * 2 + bannerExtra
    let gifPanelH = gifPanelVisible ? preferredGifPanelHeight() : 0

    let totalH =
      topVPad + pillH + (gifPanelVisible ? (panelGapV + gifPanelH) : 0) + bottomVPad
      + safeBottom
    let prevH = barHeight
    barHeight = totalH

    // Enable/disable scroll when text exceeds max height
    textView.isScrollEnabled = textH > maxPillH - textInsetV * 2

    // ── View frames (CAN animate when triggered from UIView.animate) ──
    let blurExtraY = backgroundMaskTopOverlap
    let blurTotalH = barHeight + blurExtraY
    backgroundMaskView.frame = CGRect(x: 0, y: -blurExtraY, width: w, height: blurTotalH)
    backgroundBlurView.frame = backgroundMaskView.bounds
    backgroundOverlayView.frame = backgroundBlurView.bounds

    let rowY = topVPad
    let rowH = pillH
    contentRow.frame = CGRect(x: 0, y: rowY, width: w, height: rowH)

    // Side buttons are perfectly circular
    // Pin them to the bottom of the pill, aligned with the text input box,
    // so they don't float up when text expands or banners are added.
    let textRowH = clampedTextH + textInsetV * 2
    let btnCenterY = pillH - (textRowH / 2)
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

    // ── Mention banner layout (inside pill, top section) ──
    if mentionBannerVisible {
      let mBannerY: CGFloat = 6
      let mBannerW = max(1, actualPillW - 16)
      mentionBanner.frame = CGRect(
        x: 8, y: mBannerY, width: mBannerW, height: mentionBannerContentH)
      layoutMentionBannerContents()
    }

    // ── Reply banner layout (inside pill, below mention if present) ──
    if replyBannerVisible || replyBannerAnimatingOut || !replyBanner.isHidden {
      let replyBannerY: CGFloat = 6 + mentionBannerExtra
      let bannerW = max(1, actualPillW - 16)
      replyBanner.frame = CGRect(x: 8, y: replyBannerY, width: bannerW, height: replyBannerContentH)
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
        y: contentRow.frame.maxY + panelGapV,
        width: gifPanelW,
        height: gifPanelH + safeBottom
      )
      gifPanel.alpha = 1
    } else {
      gifPanel.frame = CGRect(x: gifPanelX, y: contentRow.frame.maxY, width: gifPanelW, height: 0)
      gifPanel.alpha = 0
    }
    gifPanel.isHidden = !gifPanelVisible

    // ── Mention banner is now inside the pill — no floating layout needed ──

    // ── Pill border glow when @vibe mention is active ──
    updateMentionBorderGlow(pillFrame: pillContainer.frame)

    // ── View frame updates that should inherit UIView animations ──
    attachGlass.frame = attachButton.bounds
    micGlass.frame = micButton.bounds
    pillGlass.frame = pillContainer.bounds
    pillTapOverlay.frame = pillContainer.bounds

    if #available(iOS 26.0, *) {
      // Use native cornerConfiguration for liquid glass shapes
      attachGlass.cornerConfiguration = .capsule()
      micGlass.cornerConfiguration = .capsule()
      // Use border radius for the pill instead of capsule, so it doesn't break banner layout
      pillGlass.layer.cornerRadius = pillContainer.layer.cornerRadius
      pillGlass.layer.cornerCurve = .continuous
      pillTapOverlay.layer.cornerRadius = pillContainer.layer.cornerRadius
      pillTapOverlay.layer.cornerCurve = .continuous
      pillContainer.layer.cornerCurve = .continuous
      lockPill.cornerConfiguration = .capsule()
    } else {
      attachGlass.layer.cornerRadius = sideSize / 2
      micGlass.layer.cornerRadius = sideSize / 2
      pillGlass.layer.cornerRadius = pillContainer.layer.cornerRadius
      pillTapOverlay.layer.cornerRadius = pillContainer.layer.cornerRadius
      lockPill.layer.cornerRadius = lockPill.bounds.width / 2
    }

    // ── Layer-only updates (no implicit animation wanted) ──
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    sendGradient.frame = sendButton.bounds
    sendGradient.cornerRadius = 16

    backgroundGradientLayer.frame = backgroundMaskView.bounds

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

  private func configureInputTapFeedback() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleInputTap(_:)))
    tap.cancelsTouchesInView = false
    tap.delaysTouchesBegan = false
    tap.delegate = self
    pillContainer.addGestureRecognizer(tap)
    inputTapFeedback.prepare()
  }

  @objc private func handleInputTap(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended else { return }
    guard !isRecording else { return }
    animateInputTapFeedback()
  }

  private func animateInputTapFeedback() {
    let scale: CGFloat = 0.992
    inputTapFeedback.selectionChanged()
    inputTapFeedback.prepare()

    UIView.animate(
      withDuration: 0.1,
      delay: 0,
      usingSpringWithDamping: 1.0,
      initialSpringVelocity: 0.25,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.pillContainer.transform = CGAffineTransform(scaleX: scale, y: scale)
      self.pillTapOverlay.alpha = 1
    } completion: { _ in
      UIView.animate(
        withDuration: 0.22,
        delay: 0,
        usingSpringWithDamping: 0.72,
        initialSpringVelocity: 0.25,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        self.pillContainer.transform = .identity
        self.pillTapOverlay.alpha = 0
      }
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
    let standardTabScale: CGFloat = isPressed ? 0.96 : 1.0
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
      if button === self.attachButton || button === self.micButton {
        button.imageView?.transform = CGAffineTransform(
          scaleX: standardTabScale, y: standardTabScale)
      } else {
        button.imageView?.transform = isPressed ? iconTransform : .identity
      }

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
      gifPanel.setPanelVisible(true)
    } else {
      gifPanel.setPanelVisible(false)
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
    let sheet = ChatAttachmentMenuController(appearance: appearance)
    sheet.sourceButtonView = attachButton
    if let window = vc.view.window {
      sheet.sourceButtonFrameInWindow = attachButton.convert(attachButton.bounds, to: window)
    } else {
      sheet.sourceButtonFrameInWindow = attachButton.convert(attachButton.bounds, to: nil)
    }
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
    if suppressNextMicTap {
      suppressNextMicTap = false
      return
    }
    setGifPanelVisible(false, animated: true)
    if isRecording && isLocked {
      finishActiveRecording()
      return
    }
    if isRecording {
      return
    }
    if isVideoRecordingActive {
      return
    }

    isVideoMode.toggle()
    let iconName = isVideoMode ? "video" : "mic"
    UIView.transition(with: micButton, duration: 0.2, options: .transitionCrossDissolve) {
      let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
      self.micButton.setImage(UIImage(systemName: iconName, withConfiguration: cfg), for: .normal)
    }
  }

  @objc private func sendTapped() {
    setGifPanelVisible(false, animated: true)
    let t = currentText
    guard !t.isEmpty else { return }

    // Detect @vibe mention for group agent
    let lowered = t.lowercased()
    if lowered.contains("@vibe") {
      // Strip the @vibe prefix from the agent text to get the actual query
      let agentText =
        t
        .replacingOccurrences(of: "@vibe", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      // Don't auto-send if only @vibe is typed with no actual message
      guard !agentText.isEmpty else {
        // Keep focus in the text view so user can type their message
        textView.becomeFirstResponder()
        return
      }
      setMentionBannerVisible(false, animated: false)
      delegate?.inputBarDidSendWithAgentMention(text: t, agentText: agentText)
    } else {
      setMentionBannerVisible(false, animated: false)
      delegate?.inputBarDidSend(text: t)
    }
  }

  @objc private func mentionBannerTapped() {
    // Find the last @ in the current text and replace @partial with @vibe
    let text = textView.text ?? ""
    if let lastAtRange = text.range(of: "@", options: .backwards) {
      let beforeAt = text[text.startIndex..<lastAtRange.lowerBound]
      textView.text = beforeAt + "@vibe "
    } else {
      textView.text = (text.isEmpty ? "" : text + " ") + "@vibe "
    }
    setMentionBannerVisible(false, animated: true)
    setMentionActive(true)
    // Trigger text change processing
    textViewDidChange(textView)
    // Keep focus so user can type their question
    textView.becomeFirstResponder()
  }

  private func setMentionBannerVisible(_ visible: Bool, animated: Bool) {
    guard mentionBannerVisible != visible else { return }
    mentionBannerVisible = visible

    if visible {
      mentionBanner.isHidden = false
      mentionBanner.alpha = 0

      if animated {
        UIView.animate(
          withDuration: 0.28, delay: 0,
          usingSpringWithDamping: 0.82, initialSpringVelocity: 0.5,
          options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
        ) {
          self.mentionBanner.alpha = 1
          self.setNeedsLayout()
          self.layoutIfNeeded()
          self.superview?.setNeedsLayout()
          self.superview?.layoutIfNeeded()
        }
      } else {
        mentionBanner.alpha = 1
        setNeedsLayout()
        layoutIfNeeded()
      }
    } else {
      if animated {
        UIView.animate(
          withDuration: 0.2, delay: 0,
          options: [.curveEaseIn, .allowUserInteraction, .beginFromCurrentState]
        ) {
          self.mentionBanner.alpha = 0
          self.setNeedsLayout()
          self.layoutIfNeeded()
          self.superview?.setNeedsLayout()
          self.superview?.layoutIfNeeded()
        } completion: { _ in
          if !self.mentionBannerVisible {
            self.mentionBanner.isHidden = true
          }
        }
      } else {
        mentionBanner.alpha = 0
        mentionBanner.isHidden = true
        setNeedsLayout()
        layoutIfNeeded()
      }
    }
  }

  private func layoutMentionBannerContents() {
    let b = mentionBanner.bounds
    guard b.width > 0, b.height > 0 else { return }
    let pad: CGFloat = 10
    let iconSize: CGFloat = 26
    mentionIconContainer.frame = CGRect(
      x: pad, y: (b.height - iconSize) / 2, width: iconSize, height: iconSize)
    mentionIconLabel.frame = mentionIconContainer.bounds
    let textX = mentionIconContainer.frame.maxX + 8
    mentionNameLabel.frame = CGRect(x: textX, y: (b.height - 16) / 2, width: 46, height: 16)
    mentionDescLabel.frame = CGRect(
      x: mentionNameLabel.frame.maxX + 6, y: (b.height - 14) / 2, width: 50, height: 14)
  }

  private func setMentionActive(_ active: Bool) {
    guard mentionActive != active else { return }
    mentionActive = active
    let agentColor =
      appearance.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      if active {
        self.pillContainer.layer.borderColor = agentColor.withAlphaComponent(0.55).cgColor
        self.pillContainer.layer.borderWidth = 1.2
      } else {
        self.pillContainer.layer.borderColor = UIColor(white: 1.0, alpha: 0.12).cgColor
        self.pillContainer.layer.borderWidth = 0.6
      }
    }
  }

  private func updateMentionBorderGlow(pillFrame: CGRect) {
    let textString = (textView.text ?? "").lowercased()
    let hasVibeMention = textString.contains("@vibe")
    if hasVibeMention != mentionActive {
      setMentionActive(hasVibeMention)
    }
  }

  @objc private func cancelOverlayTapped() {
    cancelActiveRecording()
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
      suppressNextMicTap = true
      recordingGestureStartPoint = g.location(in: nil)
      if isVideoMode {
        startVideoRecording()
      } else {
        startVoiceRecording()
      }
    case .changed:
      guard isRecording, !isLocked else { return }
      if recordingMode == .video, let startedAt = recordingStartTime,
        Date().timeIntervalSince(startedAt) < 0.22
      {
        return
      }

      let point = g.location(in: nil)
      let dy = point.y - recordingGestureStartPoint.y
      let dx = point.x - recordingGestureStartPoint.x

      lockPill.transform = CGAffineTransform(translationX: 0, y: min(0, dy + 6))

      if dy < -60 {
        lockActiveRecording()
      } else if dx < -100 {
        cancelActiveRecording()
        g.isEnabled = false  // Cancel gesture
        g.isEnabled = true
      }

    case .ended:
      if isRecording && !isLocked {
        finishActiveRecording()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.suppressNextMicTap = false
      }
    case .cancelled, .failed:
      cancelActiveRecording()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.suppressNextMicTap = false
      }
    default: break
    }
  }

  private func startVoiceRecording() {
    recordingMode = .voice
    startRecording()
  }

  private func startVideoRecording() {
    recordingMode = .video
    startRecording()
  }

  private func lockActiveRecording() {
    lockRecording()
  }

  private func cancelActiveRecording() {
    cancelRecording()
  }

  private func finishActiveRecording() {
    finishRecording()
  }

  @discardableResult
  private func startVideoNoteRecording() -> Bool {
    guard !isVideoRecordingActive else { return false }
    guard let hostVC = findViewController() else { return false }
    var presenter = hostVC
    while let next = presenter.presentedViewController, !next.isBeingDismissed {
      presenter = next
    }
    guard presenter.presentedViewController == nil else { return false }

    isVideoRecordingActive = true

    let recorder = VideoNoteRecorderViewController()
    recorder.modalPresentationStyle = .overFullScreen
    recorder.modalTransitionStyle = .crossDissolve
    recorder.onFinished = { [weak self] url, duration, shouldSend in
      guard let self else { return }
      self.videoNoteRecorderController = nil
      self.isVideoRecordingActive = false
      if shouldSend, let url {
        self.delegate?.inputBarDidRecordVideoNote(uri: url.absoluteString, duration: duration)
      } else if self.pendingVideoStopShouldSend {
        self.delegate?.inputBarRecordingDidCancel()
      }
      self.pendingVideoStopShouldSend = true
    }
    videoNoteRecorderController = recorder
    presenter.present(recorder, animated: true)
    return true
  }

  private func stopVideoNoteRecording(send: Bool) {
    guard isVideoRecordingActive else { return }
    pendingVideoStopShouldSend = send

    guard let recorder = videoNoteRecorderController else {
      isVideoRecordingActive = false
      return
    }
    recorder.stopRecording(send: send)
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

    if recordingMode == .video {
      micVADView.stop()
      guard startVideoNoteRecording() else {
        isRecording = false
        isLocked = false
        recordingMode = .none
        resetUI()
        recordingTimer?.invalidate()
        recordingTimer = nil
        return
      }
    } else {
      micVADView.start()

      let fileManager = FileManager.default
      let baseCacheDirectory =
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
      let voiceCacheDirectory = baseCacheDirectory.appendingPathComponent(
        "voice-recordings", isDirectory: true)
      try? fileManager.createDirectory(
        at: voiceCacheDirectory, withIntermediateDirectories: true)

      let outputURL =
        voiceCacheDirectory
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
    }

    delegate?.inputBarRecordingStateDidChange(
      isRecording: true,
      isLocked: false,
      mode: recordingModeString()
    )
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

    if recordingMode == .voice {
      vadTimer?.invalidate()
      micVADView.stop()
    }

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
      self.micButton.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
    }

    stopRecordingHintAnimations()
    slideToCancelLabel.transform = .identity
    lockPill.transform = .identity
    setNeedsLayout()
    layoutIfNeeded()

    delegate?.inputBarRecordingStateDidChange(
      isRecording: true,
      isLocked: true,
      mode: recordingModeString()
    )
  }

  private func cancelRecording() {
    guard isRecording else { return }
    let modeString = recordingModeString()
    let isVideoRecordingMode = recordingMode == .video
    isRecording = false
    isLocked = false
    notificationFeedback.notificationOccurred(.error)

    if isVideoRecordingMode {
      stopVideoNoteRecording(send: false)
    }
    vadTimer?.invalidate()
    vadTimer = nil
    recordingTimer?.invalidate()
    recordingTimer = nil
    micVADView.stop()

    // Save dot starting point
    let dotStart = pillContainer.convert(recordingDot.center, to: self)

    // Layout updates and shrink UI immediately, hiding real dot.
    resetUI(revealAttach: false)

    // Re-calculate layout to get accurate attachButton frames back at identity
    layoutIfNeeded()

    // The dot end is the normal untranslated position of attachButton
    let attachHeight = attachButton.bounds.height
    let dotEndX = attachButton.frame.minX + sideSize / 2
    let dotEndY = contentRow.frame.minY + attachHeight / 2
    let dotEnd = CGPoint(x: dotEndX, y: dotEndY)

    // Create animated fake dot
    let animatedDot = UIView(frame: CGRect(x: 0, y: 0, width: 6, height: 6))
    animatedDot.backgroundColor = .systemRed
    animatedDot.layer.cornerRadius = 3
    animatedDot.center = dotStart
    addSubview(animatedDot)

    // Setup Glass Trash View replacing the plus icon
    let trashContainer = UIView(frame: CGRect(x: 0, y: 0, width: sideSize, height: attachHeight))
    trashContainer.center = dotEnd
    trashContainer.alpha = 0
    trashContainer.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
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

    let trashIconContainer = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    trashIconContainer.center = CGPoint(x: sideSize / 2, y: attachHeight / 2)
    trashContainer.addSubview(trashIconContainer)

    let trashIcon = UIImageView(
      image: UIImage(
        systemName: "trash",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
      )
    )
    trashIcon.tintColor = .systemRed
    trashIcon.frame = trashIconContainer.bounds
    trashIconContainer.addSubview(trashIcon)

    bringSubviewToFront(animatedDot)

    // Animate Trash Container fading in slightly before the dot jumps
    UIView.animate(withDuration: 0.2, delay: 0.05, options: .curveEaseOut) {
      trashContainer.alpha = 1
      trashContainer.transform = .identity
    } completion: { _ in
      // Step 1: Open door & jump
      let path = UIBezierPath()
      path.move(to: dotStart)

      let jumpHeight: CGFloat = 40
      // Ensure the curve goes "up and over"
      let controlY = min(dotStart.y, dotEnd.y) - jumpHeight
      let controlX = (dotStart.x + dotEnd.x) / 2
      path.addQuadCurve(
        to: dotEnd, controlPoint: CGPoint(x: controlX, y: controlY))

      let jumpAnim = CAKeyframeAnimation(keyPath: "position")
      jumpAnim.path = path.cgPath
      jumpAnim.duration = 0.35
      // Use EaseIn to accelerate into the trash can
      jumpAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)

      // Open Trash Can Lid (Translate Up + Scale)
      UIView.animate(
        withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.2,
        options: .curveEaseOut
      ) {
        trashIconContainer.transform = CGAffineTransform(translationX: 0, y: -4).scaledBy(
          x: 1.15, y: 1.15)
      }

      CATransaction.begin()
      CATransaction.setCompletionBlock {
        // Step 2: Dot falls in, make it shrink rapidly
        UIView.animate(withDuration: 0.1, delay: 0, options: [.curveLinear]) {
          animatedDot.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
          animatedDot.alpha = 0

          // Trash "closes door" with a sudden drop
          trashIconContainer.transform = CGAffineTransform(translationX: 0, y: 2).scaledBy(
            x: 0.9, y: 0.9)
        } completion: { _ in
          animatedDot.removeFromSuperview()
          // Step 3: Bounce back to identity smoothly (Trash settles)
          UIView.animate(
            withDuration: 0.15, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.5,
            options: [.curveEaseOut]
          ) {
            trashIconContainer.transform = .identity
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
      animatedDot.layer.add(jumpAnim, forKey: "jump")
      animatedDot.center = dotEnd
      CATransaction.commit()
    }

    delegate?.inputBarRecordingStateDidChange(isRecording: false, isLocked: false, mode: modeString)
    delegate?.inputBarRecordingDidCancel()
    recordingMode = .none
  }

  private func finishRecording() {
    guard isRecording else { return }
    let modeString = recordingModeString()
    let isVideoRecordingMode = recordingMode == .video

    if !isVideoRecordingMode {
      let dur = Date().timeIntervalSince(recordingStartTime ?? Date())
      if audioRecorder == nil || dur <= 0.6 {
        cancelRecording()
        return
      }
    }

    isRecording = false
    isLocked = false
    notificationFeedback.notificationOccurred(.success)

    micVADView.stop()
    if isVideoRecordingMode {
      stopVideoNoteRecording(send: true)
    } else {
      let dur = Date().timeIntervalSince(recordingStartTime ?? Date())
      if let recorder = audioRecorder {
        recorder.stop()
        let waveform = downsampleWaveform(recordingWaveformSamples, targetCount: 28)
        let outputURI = recordingFileURL?.absoluteString ?? ""
        if !outputURI.isEmpty {
          delegate?.inputBarDidRecordVoice(uri: outputURI, duration: dur, waveform: waveform)
        }
      }
    }

    delegate?.inputBarRecordingStateDidChange(isRecording: false, isLocked: false, mode: modeString)
    resetUI()
    recordingTimer?.invalidate()
    recordingTimer = nil
    recordingMode = .none
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

      let micCfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
      let iconName = self.isVideoMode ? "video" : "mic"
      self.micButton.setImage(
        UIImage(systemName: iconName, withConfiguration: micCfg), for: .normal)
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
    let sanitized =
      samples
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

    let textString = tv.text ?? ""
    delegate?.inputBarTextDidChange(text: textString)

    // Detect @ typing for mention suggestion banner
    let shouldShowMention: Bool = {
      guard !textString.isEmpty else { return false }
      guard let lastAtIndex = textString.lastIndex(of: "@") else { return false }
      let afterAt = textString[textString.index(after: lastAtIndex)...].lowercased()
      // Must be at start or preceded by space
      let isAtStart = lastAtIndex == textString.startIndex
      let isPrecededBySpace = !isAtStart && textString[textString.index(before: lastAtIndex)] == " "
      guard isAtStart || isPrecededBySpace else { return false }
      // No space in the partial match
      guard !afterAt.contains(" ") else { return false }
      // "vibe" must start with what's typed after @
      return "vibe".hasPrefix(afterAt) || afterAt.isEmpty
    }()
    setMentionBannerVisible(shouldShowMention, animated: true)

    // Highlight @vibe in real-time
    if let textStorage = tv.textStorage as NSTextStorage? {
      let fullRange = NSRange(location: 0, length: textStorage.length)
      let selectedRange = tv.selectedRange

      textStorage.beginEditing()
      textStorage.removeAttribute(.foregroundColor, range: fullRange)
      textStorage.removeAttribute(.font, range: fullRange)
      textStorage.addAttribute(.foregroundColor, value: appearance.textColorThem, range: fullRange)
      textStorage.addAttribute(.font, value: UIFont.systemFont(ofSize: 16), range: fullRange)

      if let regex = try? NSRegularExpression(pattern: "@vibe", options: .caseInsensitive) {
        let matches = regex.matches(in: textString, options: [], range: fullRange)
        let highlightColor =
          appearance.bubbleMeGradient.last
          ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
        for match in matches {
          textStorage.addAttribute(.foregroundColor, value: highlightColor, range: match.range)
        }
      }
      textStorage.endEditing()

      // Restore cursor position seamlessly
      tv.selectedRange = selectedRange
    }

    let newHeight = tv.contentSize.height
    if abs(newHeight - lastMeasuredTextHeight) > 1.0 {
      lastMeasuredTextHeight = newHeight
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
  }

  func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String)
    -> Bool
  {
    // Allow newline insertion from keyboard return key.
    return true
  }
}

extension ChatInputBar: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    guard gestureRecognizer.view === pillContainer else { return true }
    guard let touchedView = touch.view else { return true }

    if touchedView.isDescendant(of: textView) {
      // Do not intercept UITextView touches; keep native select/copy/paste menu behavior.
      return false
    }

    if touchedView.isDescendant(of: gifButton)
      || touchedView.isDescendant(of: sendButton)
      || touchedView.isDescendant(of: replyDismissButton)
      || touchedView.isDescendant(of: cancelOverlayButton)
    {
      return false
    }
    return true
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
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
    tabBar.backgroundColor = .clear
    tabBar.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.16)
    tabBar.setTitleTextAttributes(
      [
        .foregroundColor: UIColor(white: 0.95, alpha: 0.84),
        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
      ],
      for: .normal
    )
    tabBar.setTitleTextAttributes(
      [
        .foregroundColor: UIColor.white,
        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
      ],
      for: .selected
    )
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
