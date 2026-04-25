import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AppNativeStoryCapturedMedia: Identifiable, Equatable {
  enum Kind: String {
    case image
    case video
  }

  let id = UUID()
  let url: URL
  let kind: Kind
  let mirrored: Bool
}

struct AppNativeStoryCameraPage: View {
  let onClose: () -> Void

  @State private var capturedMedia: AppNativeStoryCapturedMedia?
  @State private var statusText: String?

  var body: some View {
    ZStack {
      if let capturedMedia {
        AppNativeStoryComposerRepresentable(media: capturedMedia) { payload in
          handleComposerEvent(payload)
        }
        .ignoresSafeArea()
        .transition(.opacity)
      } else {
        AppNativeStoryCameraRepresentable { payload in
          handleCameraEvent(payload)
        }
        .ignoresSafeArea()
      }

      if let statusText {
        VStack {
          Spacer()
          Text(statusText)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule(style: .continuous))
            .padding(.bottom, 44)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .background(Color.black.ignoresSafeArea())
    .animation(.easeInOut(duration: 0.18), value: capturedMedia)
    .animation(.easeInOut(duration: 0.18), value: statusText)
  }

  private func handleCameraEvent(_ payload: [String: Any]) {
    guard let type = payload["type"] as? String else { return }
    switch type {
    case "close":
      onClose()
    case "capture":
      guard
        let uri = payload["uri"] as? String,
        let url = URL(string: uri),
        let mediaType = payload["mediaType"] as? String
      else {
        showStatus("Capture failed")
        return
      }
      capturedMedia = AppNativeStoryCapturedMedia(
        url: url,
        kind: mediaType == "video" ? .video : .image,
        mirrored: payload["mirrored"] as? Bool ?? false
      )
    case "error":
      showStatus(payload["message"] as? String ?? "Camera unavailable")
    default:
      break
    }
  }

  private func showStatus(_ text: String) {
    statusText = text
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
      if statusText == text {
        statusText = nil
      }
    }
  }

  private func handleComposerEvent(_ payload: [String: Any]) {
    guard let type = payload["type"] as? String else { return }
    switch type {
    case "discard":
      capturedMedia = nil
    case "saveDraft":
      showStatus("Draft saved")
    case "aiEdit":
      showStatus("AI edit queued")
    case "publish":
      guard let media = capturedMedia else { return }
      let publishMedia = mediaForPublish(baseMedia: media, payload: payload)
      showStatus("Publishing...")
      Task {
        do {
          try await AppNativeStoryService.publish(media: publishMedia, payload: payload)
          await MainActor.run {
            showStatus("Story published")
            onClose()
          }
        } catch {
          await MainActor.run {
            showStatus(error.localizedDescription)
          }
        }
      }
    default:
      break
    }
  }

  private func mediaForPublish(
    baseMedia: AppNativeStoryCapturedMedia,
    payload: [String: Any]
  ) -> AppNativeStoryCapturedMedia {
    guard
      let renderedURI = payload["renderedUri"] as? String,
      let renderedURL = URL(string: renderedURI)
    else {
      return baseMedia
    }
    let renderedType = payload["renderedMediaType"] as? String
    return AppNativeStoryCapturedMedia(
      url: renderedURL,
      kind: renderedType == "video" ? .video : .image,
      mirrored: false
    )
  }
}

private struct AppNativeStoryCameraRepresentable: UIViewRepresentable {
  let onEvent: ([String: Any]) -> Void

  func makeUIView(context: Context) -> AppNativeStoryCameraView {
    let view = AppNativeStoryCameraView()
    view.onEvent = onEvent
    return view
  }

  func updateUIView(_ uiView: AppNativeStoryCameraView, context: Context) {
    uiView.onEvent = onEvent
  }
}

private enum AppNativeStoryCameraMode: String {
  case picture
  case video
}

private final class AppNativeStoryCameraPreviewView: UIView {
  override class var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }
}

private final class AppNativeStoryCameraView: UIView, AVCapturePhotoCaptureDelegate,
  AVCaptureFileOutputRecordingDelegate, PHPickerViewControllerDelegate
{
  var onEvent: (([String: Any]) -> Void)?

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(
    label: "vibe.native.story.camera.session",
    qos: .userInitiated
  )
  private let photoOutput = AVCapturePhotoOutput()
  private let movieOutput = AVCaptureMovieFileOutput()
  private let previewView = AppNativeStoryCameraPreviewView()
  private let cardContainer = UIView()
  private let topBar = UIView()
  private let closeButton = UIButton(type: .system)
  private let galleryButton = UIButton(type: .system)
  private let flipButton = UIButton(type: .system)
  private let modeContainer = UIView()
  private let pictureModeButton = UIButton(type: .system)
  private let videoModeButton = UIButton(type: .system)
  private let shutterButton = UIButton(type: .custom)
  private let shutterRingView = UIView()
  private let shutterInnerView = UIView()
  private let permissionContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let permissionTitleLabel = UILabel()
  private let permissionButton = UIButton(type: .system)
  private let loadingSpinner = UIActivityIndicatorView(style: .large)

  private var currentMode: AppNativeStoryCameraMode = .picture
  private var currentPosition: AVCaptureDevice.Position = .back
  private var hasConfiguredSession = false
  private var didRequestInitialPermission = false
  private var isRecording = false
  private var shouldIgnoreNextVideoCapture = false
  private var videoInput: AVCaptureDeviceInput?
  private var audioInput: AVCaptureDeviceInput?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    clipsToBounds = true

    cardContainer.backgroundColor = .black
    cardContainer.layer.cornerRadius = 32.0
    cardContainer.layer.cornerCurve = .continuous
    cardContainer.clipsToBounds = true

    previewView.previewLayer.session = session
    previewView.previewLayer.videoGravity = .resizeAspectFill

    configureView()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    DispatchQueue.main.async { [weak self] in
      self?.refreshPermissionState(requestIfNeeded: true)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    let session = self.session
    let movieOutput = self.movieOutput
    sessionQueue.async {
      if movieOutput.isRecording {
        movieOutput.stopRecording()
      }
      if session.isRunning {
        session.stopRunning()
      }
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      stopSessionIfNeeded(ignoreCapture: true)
    } else {
      refreshPermissionState(requestIfNeeded: false)
      startSessionIfNeeded()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let safeTop = max(safeAreaInsets.top, 12.0)
    let safeBottom = max(safeAreaInsets.bottom, 20.0)
    let horizontalMargin: CGFloat = 10.0
    let bottomReservedHeight: CGFloat = 140.0
    let cardTop = safeTop + 4.0
    let cardWidth = max(0.0, bounds.width - (horizontalMargin * 2.0))
    let maxCardHeight = max(280.0, bounds.height - cardTop - bottomReservedHeight)
    let preferredCardHeight = max(340.0, bounds.height * 0.85)
    let cardHeight = min(preferredCardHeight, maxCardHeight)

    cardContainer.frame = CGRect(
      x: horizontalMargin,
      y: cardTop,
      width: cardWidth,
      height: cardHeight
    )
    previewView.frame = cardContainer.bounds

    topBar.frame = CGRect(x: 14.0, y: 14.0, width: max(0.0, cardWidth - 28.0), height: 44.0)
    closeButton.frame = CGRect(x: cardWidth - 44.0, y: 0.0, width: 44.0, height: 44.0)

    let shutterSize: CGFloat = 84
    let remainingSpace = bounds.height - cardContainer.frame.maxY - safeBottom
    let shutterY = cardContainer.frame.maxY + (remainingSpace - shutterSize) * 0.5 + 10.0
    shutterButton.frame = CGRect(
      x: (bounds.width - shutterSize) * 0.5,
      y: shutterY,
      width: shutterSize,
      height: shutterSize
    )
    shutterRingView.frame = shutterButton.bounds
    shutterRingView.layer.cornerRadius = shutterSize * 0.5

    let innerSize: CGFloat = isRecording ? 34 : 62
    shutterInnerView.frame = CGRect(
      x: (shutterButton.bounds.width - innerSize) * 0.5,
      y: (shutterButton.bounds.height - innerSize) * 0.5,
      width: innerSize,
      height: innerSize
    )
    shutterInnerView.layer.cornerRadius = isRecording ? 12 : innerSize * 0.5

    galleryButton.frame = CGRect(x: 18, y: bounds.height - safeBottom - 70, width: 50, height: 50)
    flipButton.frame = CGRect(x: bounds.width - 68, y: bounds.height - safeBottom - 70, width: 50, height: 50)
    modeContainer.frame = CGRect(
      x: (bounds.width - 156) * 0.5,
      y: bounds.height - safeBottom - 63,
      width: 156,
      height: 36
    )
    pictureModeButton.frame = CGRect(x: 0, y: 0, width: 78, height: 36)
    videoModeButton.frame = CGRect(x: 78, y: 0, width: 78, height: 36)

    let permissionWidth = min(bounds.width - 44, 330)
    permissionContainer.frame = CGRect(
      x: (bounds.width - permissionWidth) * 0.5,
      y: (bounds.height - 154) * 0.5,
      width: permissionWidth,
      height: 154
    )
    permissionTitleLabel.frame = CGRect(x: 22, y: 28, width: permissionWidth - 44, height: 44)
    permissionButton.frame = CGRect(x: 22, y: 88, width: permissionWidth - 44, height: 44)
    loadingSpinner.center = CGPoint(x: cardContainer.frame.midX, y: cardContainer.frame.midY)
    updatePreviewOrientation()
  }

  private func configureView() {
    addSubview(cardContainer)
    cardContainer.addSubview(previewView)

    topBar.backgroundColor = .clear
    cardContainer.addSubview(topBar)

    configureCircleButton(closeButton, symbol: "xmark")
    closeButton.addTarget(self, action: #selector(handleClosePress), for: .touchUpInside)
    topBar.addSubview(closeButton)

    configureCircleButton(galleryButton, symbol: "photo.on.rectangle.angled")
    galleryButton.addTarget(self, action: #selector(handleGalleryPress), for: .touchUpInside)
    addSubview(galleryButton)

    configureCircleButton(flipButton, symbol: "arrow.triangle.2.circlepath.camera")
    flipButton.addTarget(self, action: #selector(handleFlipPress), for: .touchUpInside)
    addSubview(flipButton)

    modeContainer.backgroundColor = UIColor.black.withAlphaComponent(0.34)
    modeContainer.layer.cornerRadius = 18
    modeContainer.layer.cornerCurve = .continuous
    modeContainer.clipsToBounds = true
    addSubview(modeContainer)

    configureModeButton(pictureModeButton, title: "Photo")
    pictureModeButton.addTarget(self, action: #selector(handlePictureModePress), for: .touchUpInside)
    modeContainer.addSubview(pictureModeButton)

    configureModeButton(videoModeButton, title: "Video")
    videoModeButton.addTarget(self, action: #selector(handleVideoModePress), for: .touchUpInside)
    modeContainer.addSubview(videoModeButton)

    shutterRingView.isUserInteractionEnabled = false
    shutterRingView.layer.borderColor = UIColor.white.cgColor
    shutterRingView.layer.borderWidth = 4
    shutterButton.addSubview(shutterRingView)

    shutterInnerView.isUserInteractionEnabled = false
    shutterInnerView.backgroundColor = .white
    shutterButton.addSubview(shutterInnerView)
    shutterButton.addTarget(self, action: #selector(handleShutterPress), for: .touchUpInside)
    addSubview(shutterButton)

    permissionContainer.layer.cornerRadius = 22
    permissionContainer.layer.cornerCurve = .continuous
    permissionContainer.clipsToBounds = true
    permissionContainer.isHidden = true
    addSubview(permissionContainer)

    permissionTitleLabel.numberOfLines = 0
    permissionTitleLabel.textAlignment = .center
    permissionTitleLabel.textColor = .white
    permissionTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    permissionContainer.contentView.addSubview(permissionTitleLabel)

    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = .white
    configuration.baseForegroundColor = .black
    configuration.cornerStyle = .capsule
    configuration.title = "Grant Permission"
    permissionButton.configuration = configuration
    permissionButton.addTarget(self, action: #selector(handlePermissionButtonPress), for: .touchUpInside)
    permissionContainer.contentView.addSubview(permissionButton)

    loadingSpinner.color = .white
    addSubview(loadingSpinner)

    updateModeAppearance()
  }

  private func configureCircleButton(_ button: UIButton, symbol: String) {
    button.setImage(UIImage(systemName: symbol), for: .normal)
    button.tintColor = .white
    button.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    button.layer.cornerRadius = 25
    button.layer.cornerCurve = .continuous
  }

  private func configureModeButton(_ button: UIButton, title: String) {
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
    button.layer.cornerRadius = 18
    button.layer.cornerCurve = .continuous
  }

  @objc private func handleWillResignActive() {
    stopSessionIfNeeded(ignoreCapture: true)
  }

  @objc private func handleDidBecomeActive() {
    refreshPermissionState(requestIfNeeded: false)
    startSessionIfNeeded()
  }

  @objc private func handleClosePress() {
    stopSessionIfNeeded(ignoreCapture: true)
    onEvent?(["type": "close"])
  }

  @objc private func handlePermissionButtonPress() {
    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
      requestVideoPermission()
      return
    }
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  @objc private func handleGalleryPress() {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.selectionLimit = 1
    configuration.filter = .any(of: [.images, .videos])
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    Self.topViewController()?.present(picker, animated: true)
  }

  @objc private func handleFlipPress() {
    guard !isRecording else { return }
    let nextPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.ensureSessionConfigured()
      self.session.beginConfiguration()
      self.replaceVideoInput(position: nextPosition)
      self.session.commitConfiguration()
      DispatchQueue.main.async {
        self.updatePreviewOrientation()
      }
    }
  }

  @objc private func handlePictureModePress() {
    setMode(.picture)
  }

  @objc private func handleVideoModePress() {
    setMode(.video)
  }

  @objc private func handleShutterPress() {
    switch currentMode {
    case .picture:
      capturePhoto()
    case .video:
      if isRecording {
        stopRecording()
      } else {
        startRecordingFlow()
      }
    }
  }

  private func refreshPermissionState(requestIfNeeded: Bool) {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      permissionContainer.isHidden = true
      if requestIfNeeded {
        requestOptionalAudioPermissionIfNeeded()
      }
      startSessionIfNeeded()
    case .notDetermined:
      permissionContainer.isHidden = false
      permissionTitleLabel.text = "Camera permission required"
      permissionButton.configuration?.title = "Grant Permission"
      if requestIfNeeded && !didRequestInitialPermission {
        didRequestInitialPermission = true
        requestVideoPermission()
      }
    default:
      permissionContainer.isHidden = false
      permissionTitleLabel.text = "Allow camera access in Settings"
      permissionButton.configuration?.title = "Open Settings"
      setLoadingVisible(false)
      stopSessionIfNeeded(ignoreCapture: true)
    }
  }

  private func requestVideoPermission() {
    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      DispatchQueue.main.async {
        self?.refreshPermissionState(requestIfNeeded: granted)
      }
    }
  }

  private func requestOptionalAudioPermissionIfNeeded() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .authorized {
      sessionQueue.async { [weak self] in
        guard let self else { return }
        self.session.beginConfiguration()
        self.addAudioInputIfPossible()
        self.session.commitConfiguration()
      }
      return
    }
    guard status == .notDetermined else { return }
    AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
      guard granted else { return }
      self?.sessionQueue.async { [weak self] in
        guard let self else { return }
        self.session.beginConfiguration()
        self.addAudioInputIfPossible()
        self.session.commitConfiguration()
      }
    }
  }

  private func startSessionIfNeeded() {
    guard window != nil else { return }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
    setLoadingVisible(true)
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.ensureSessionConfigured()
      guard self.videoInput != nil else {
        DispatchQueue.main.async {
          self.setLoadingVisible(false)
          self.emitError("Camera unavailable")
        }
        return
      }
      guard !self.session.isRunning else {
        DispatchQueue.main.async {
          self.setLoadingVisible(false)
        }
        return
      }
      self.session.startRunning()
      DispatchQueue.main.async {
        self.setLoadingVisible(false)
        self.updatePreviewOrientation()
      }
    }
  }

  private func stopSessionIfNeeded(ignoreCapture: Bool) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.movieOutput.isRecording {
        self.shouldIgnoreNextVideoCapture = ignoreCapture
        self.movieOutput.stopRecording()
      }
      if self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  private func ensureSessionConfigured() {
    guard !hasConfiguredSession else { return }
    session.beginConfiguration()
    session.sessionPreset = .high

    if session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
    }

    if session.canAddOutput(movieOutput) {
      session.addOutput(movieOutput)
      movieOutput.maxRecordedDuration = CMTime(seconds: 15, preferredTimescale: 600)
      movieOutput.movieFragmentInterval = .invalid
    }

    replaceVideoInput(position: currentPosition)
    addAudioInputIfPossible()

    session.commitConfiguration()
    hasConfiguredSession = true
  }

  private func replaceVideoInput(position: AVCaptureDevice.Position) {
    guard let device = Self.cameraDevice(for: position) else { return }
    guard let nextInput = try? AVCaptureDeviceInput(device: device) else { return }

    let previousInput = videoInput
    if let previousInput {
      session.removeInput(previousInput)
    }

    if session.canAddInput(nextInput) {
      session.addInput(nextInput)
      videoInput = nextInput
      currentPosition = position
      return
    }

    if let previousInput, session.canAddInput(previousInput) {
      session.addInput(previousInput)
      videoInput = previousInput
    }
  }

  private func addAudioInputIfPossible() {
    guard audioInput == nil else { return }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
    guard let audioDevice = AVCaptureDevice.default(for: .audio) else { return }
    guard let nextInput = try? AVCaptureDeviceInput(device: audioDevice) else { return }
    guard session.canAddInput(nextInput) else { return }
    session.addInput(nextInput)
    audioInput = nextInput
  }

  private func setMode(_ mode: AppNativeStoryCameraMode) {
    guard currentMode != mode else { return }
    currentMode = mode
    if mode == .picture, isRecording {
      shouldIgnoreNextVideoCapture = true
      stopRecording()
    }
    updateModeAppearance()
    updateShutterAppearance()
  }

  private func updateModeAppearance() {
    let selectedBackground = UIColor.white.withAlphaComponent(0.24)
    let clear = UIColor.clear
    pictureModeButton.backgroundColor = currentMode == .picture ? selectedBackground : clear
    videoModeButton.backgroundColor = currentMode == .video ? selectedBackground : clear
    pictureModeButton.setTitleColor(.white, for: .normal)
    videoModeButton.setTitleColor(.white, for: .normal)
  }

  private func updateShutterAppearance() {
    UIView.animate(withDuration: 0.18) {
      self.shutterInnerView.backgroundColor =
        self.currentMode == .video ? UIColor.systemRed : UIColor.white
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  private func updatePreviewOrientation() {
    guard let connection = previewView.previewLayer.connection else { return }
    if connection.isVideoOrientationSupported {
      connection.videoOrientation = window?.windowScene?.interfaceOrientation.storyCameraOrientation ?? .portrait
    }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = currentPosition == .front
    }
  }

  private func capturePhoto() {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      refreshPermissionState(requestIfNeeded: true)
      return
    }
    guard videoInput != nil else {
      emitError("Camera unavailable")
      return
    }
    let settings = AVCapturePhotoSettings()
    if let device = videoInput?.device, device.hasFlash {
      settings.flashMode = .off
    }
    photoOutput.capturePhoto(with: settings, delegate: self)
    flashPreview()
  }

  private func startRecordingFlow() {
    let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    if audioStatus == .notDetermined {
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
        DispatchQueue.main.async {
          self?.sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.addAudioInputIfPossible()
            self.session.commitConfiguration()
            DispatchQueue.main.async {
              self.startRecording()
            }
          }
        }
      }
      return
    }
    startRecording()
  }

  private func startRecording() {
    guard !movieOutput.isRecording else { return }
    guard videoInput != nil else {
      emitError("Camera unavailable")
      return
    }
    let url = temporaryOutputURL(fileExtension: "mov")
    if let connection = movieOutput.connection(with: .video) {
      if connection.isVideoOrientationSupported {
        connection.videoOrientation = window?.windowScene?.interfaceOrientation.storyCameraOrientation ?? .portrait
      }
      if connection.isVideoMirroringSupported {
        connection.isVideoMirrored = currentPosition == .front
      }
    }
    movieOutput.startRecording(to: url, recordingDelegate: self)
  }

  private func stopRecording() {
    guard movieOutput.isRecording else { return }
    movieOutput.stopRecording()
  }

  private func setRecording(_ recording: Bool) {
    isRecording = recording
    updateShutterAppearance()
  }

  private func setLoadingVisible(_ visible: Bool) {
    if visible {
      loadingSpinner.startAnimating()
    } else {
      loadingSpinner.stopAnimating()
    }
  }

  private func flashPreview() {
    let flash = UIView(frame: bounds)
    flash.backgroundColor = .white
    flash.alpha = 0
    addSubview(flash)
    UIView.animate(withDuration: 0.08, animations: {
      flash.alpha = 0.72
    }, completion: { _ in
      UIView.animate(withDuration: 0.16, animations: {
        flash.alpha = 0
      }, completion: { _ in
        flash.removeFromSuperview()
      })
    })
  }

  private func emitCapture(url: URL, mediaType: String, mirrored: Bool) {
    onEvent?([
      "type": "capture",
      "uri": url.absoluteString,
      "mediaType": mediaType,
      "mirrored": mirrored,
    ])
  }

  private func emitError(_ message: String) {
    onEvent?([
      "type": "error",
      "message": message,
    ])
  }

  private func temporaryOutputURL(fileExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-story-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    if let error {
      DispatchQueue.main.async {
        self.emitError(error.localizedDescription)
      }
      return
    }

    guard let data = photo.fileDataRepresentation() else {
      DispatchQueue.main.async {
        self.emitError("Unable to save photo")
      }
      return
    }

    let outputURL = temporaryOutputURL(fileExtension: "jpg")
    do {
      try data.write(to: outputURL, options: [.atomic])
      DispatchQueue.main.async {
        self.emitCapture(
          url: outputURL,
          mediaType: "image",
          mirrored: self.currentPosition == .front
        )
      }
    } catch {
      DispatchQueue.main.async {
        self.emitError(error.localizedDescription)
      }
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    DispatchQueue.main.async {
      self.setRecording(true)
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    DispatchQueue.main.async {
      self.setRecording(false)
    }

    if shouldIgnoreNextVideoCapture {
      shouldIgnoreNextVideoCapture = false
      try? FileManager.default.removeItem(at: outputFileURL)
      return
    }

    if let nsError = error as NSError?,
      nsError.domain != AVFoundationErrorDomain
        || nsError.code != AVError.Code.maximumDurationReached.rawValue
    {
      DispatchQueue.main.async {
        self.emitError(nsError.localizedDescription)
      }
      return
    }

    DispatchQueue.main.async {
      self.emitCapture(
        url: outputFileURL,
        mediaType: "video",
        mirrored: self.currentPosition == .front
      )
    }
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = results.first else { return }

    let provider = result.itemProvider
    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
        if let error {
          DispatchQueue.main.async {
            self?.emitError(error.localizedDescription)
          }
          return
        }
        guard let url else {
          DispatchQueue.main.async {
            self?.emitError("Unable to load video")
          }
          return
        }
        let destination = self?.temporaryOutputURL(fileExtension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        guard let destination else { return }
        do {
          try FileManager.default.copyItem(at: url, to: destination)
          DispatchQueue.main.async {
            self?.emitCapture(url: destination, mediaType: "video", mirrored: false)
          }
        } catch {
          DispatchQueue.main.async {
            self?.emitError(error.localizedDescription)
          }
        }
      }
      return
    }

    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, error in
      if let error {
        DispatchQueue.main.async {
          self?.emitError(error.localizedDescription)
        }
        return
      }
      guard let data else {
        DispatchQueue.main.async {
          self?.emitError("Unable to load image")
        }
        return
      }
      let destination = self?.temporaryOutputURL(fileExtension: "jpg")
      guard let destination else { return }
      do {
        try data.write(to: destination, options: [.atomic])
        DispatchQueue.main.async {
          self?.emitCapture(url: destination, mediaType: "image", mirrored: false)
        }
      } catch {
        DispatchQueue.main.async {
          self?.emitError(error.localizedDescription)
        }
      }
    }
  }

  private static func cameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    if position == .front {
      return AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
        ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        ?? AVCaptureDevice.default(for: .video)
    }
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
      ?? AVCaptureDevice.default(for: .video)
  }

  private static func topViewController(
    base: UIViewController? = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }?
      .rootViewController
  ) -> UIViewController? {
    if let navigation = base as? UINavigationController {
      return topViewController(base: navigation.visibleViewController)
    }
    if let tab = base as? UITabBarController {
      return topViewController(base: tab.selectedViewController)
    }
    if let presented = base?.presentedViewController {
      return topViewController(base: presented)
    }
    return base
  }
}

private enum AppNativeStoryService {
  private enum StoryServiceError: LocalizedError {
    case missingSession
    case invalidEndpoint
    case missingLocalFile
    case uploadFailed(String)
    case publishFailed(String)

    var errorDescription: String? {
      switch self {
      case .missingSession:
        return "Sign in again to publish stories."
      case .invalidEndpoint:
        return "Story endpoint is unavailable."
      case .missingLocalFile:
        return "Story media is no longer available."
      case .uploadFailed(let reason):
        return "Upload failed: \(reason)"
      case .publishFailed(let reason):
        return "Publish failed: \(reason)"
      }
    }
  }

  static func publish(media: AppNativeStoryCapturedMedia, payload: [String: Any]) async throws {
    guard let config = AppSessionConfig.current else {
      throw StoryServiceError.missingSession
    }

    let remoteMediaURL = try await upload(media: media, config: config)
    try await createStory(media: media, mediaURL: remoteMediaURL, payload: payload, config: config)
  }

  private static func upload(
    media: AppNativeStoryCapturedMedia,
    config: AppSessionConfig
  ) async throws -> String {
    guard FileManager.default.fileExists(atPath: media.url.path) else {
      throw StoryServiceError.missingLocalFile
    }
    guard let uploadURL = apiURL(base: config.apiBaseURLString, path: "/media/upload") else {
      throw StoryServiceError.invalidEndpoint
    }

    let fileData = try Data(contentsOf: media.url, options: [.mappedIfSafe])
    let boundary = "----VibeStoryBoundary\(UUID().uuidString)"
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    appendMultipartField(body: &body, boundary: boundary, name: "user_id", value: config.userID)
    appendMultipartField(body: &body, boundary: boundary, name: "type", value: media.kind.rawValue)
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName(for: media))\"\r\n"
        .data(using: .utf8) ?? Data()
    )
    body.append("Content-Type: \(mimeType(for: media))\r\n\r\n".data(using: .utf8) ?? Data())
    body.append(fileData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8) ?? Data())

    let (data, response) = try await URLSession.shared.upload(for: request, from: body)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw StoryServiceError.uploadFailed(responseMessage(from: data))
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let remoteURL = normalizedString(json["url"] ?? json["media_url"] ?? json["mediaUrl"])
    else {
      throw StoryServiceError.uploadFailed("missing media URL")
    }
    return remoteURL
  }

  private static func createStory(
    media: AppNativeStoryCapturedMedia,
    mediaURL: String,
    payload: [String: Any],
    config: AppSessionConfig
  ) async throws {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/stories") else {
      throw StoryServiceError.invalidEndpoint
    }
    let audience = normalizedString(payload["audience"]) ?? "everyone"
    let duration = normalizedInt(payload["duration"]) ?? 24
    let visibility = audience == "close_friends" ? "close_friends" : audience
    let body: [String: Any] = [
      "user_id": config.userID,
      "media_url": mediaURL,
      "media_type": media.kind.rawValue,
      "visibility": visibility,
      "visible_to": [],
      "hidden_from": [],
      "duration": duration,
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw StoryServiceError.publishFailed(responseMessage(from: data))
    }
  }

  private static func apiURL(base rawBase: String, path: String) -> URL? {
    var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if base.hasSuffix("/api") {
      base = String(base.dropLast(4))
    }
    return URL(string: base + "/api" + path)
  }

  private static func fileName(for media: AppNativeStoryCapturedMedia) -> String {
    let fallbackExtension = media.kind == .video ? "mov" : "jpg"
    let fileExtension = media.url.pathExtension.isEmpty ? fallbackExtension : media.url.pathExtension
    return "story-\(UUID().uuidString).\(fileExtension)"
  }

  private static func mimeType(for media: AppNativeStoryCapturedMedia) -> String {
    if media.kind == .video {
      return media.url.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/quicktime"
    }
    return "image/jpeg"
  }

  private static func appendMultipartField(
    body: inout Data,
    boundary: String,
    name: String,
    value: String
  ) {
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
    body.append("\(value)\r\n".data(using: .utf8) ?? Data())
  }

  private static func normalizedString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizedInt(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let string = normalizedString(value) {
      return Int(string)
    }
    return nil
  }

  private static func responseMessage(from data: Data) -> String {
    if
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = normalizedString(json["error"] ?? json["message"] ?? json["reason"])
    {
      return message
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "unknown error"
  }
}

private extension UIInterfaceOrientation {
  var storyCameraOrientation: AVCaptureVideoOrientation {
    switch self {
    case .portraitUpsideDown:
      return .portraitUpsideDown
    case .landscapeLeft:
      return .landscapeRight
    case .landscapeRight:
      return .landscapeLeft
    default:
      return .portrait
    }
  }
}
