import AVFoundation
import ExpoModulesCore
import Photos
import UIKit

private enum NativeStoryComposerMediaType: String {
  case image
  case video
}

private enum NativeStoryComposerAudience: String, CaseIterable {
  case everyone
  case contacts
  case closeFriends = "close_friends"

  var title: String {
    switch self {
    case .everyone:
      return "Everyone"
    case .contacts:
      return "Contacts"
    case .closeFriends:
      return "Close Friends"
    }
  }
}

private enum NativeStoryComposerFont: String, CaseIterable {
  case system
  case serif
  case mono
  case rounded

  var title: String {
    switch self {
    case .system:
      return "Default"
    case .serif:
      return "Serif"
    case .mono:
      return "Mono"
    case .rounded:
      return "Rounded"
    }
  }

  func font(ofSize size: CGFloat) -> UIFont {
    switch self {
    case .system:
      return .systemFont(ofSize: size, weight: .bold)
    case .serif:
      return UIFont(name: "TimesNewRomanPS-BoldMT", size: size)
        ?? .systemFont(ofSize: size, weight: .bold)
    case .mono:
      return .monospacedSystemFont(ofSize: size, weight: .bold)
    case .rounded:
      let baseFont = UIFont.systemFont(ofSize: size, weight: .bold)
      let descriptor =
        baseFont.fontDescriptor.withDesign(.rounded)
        ?? baseFont.fontDescriptor
      return UIFont(descriptor: descriptor, size: size)
    }
  }
}

private struct NativeStoryComposerTextOverlay {
  let id: String
  var text: String
  var center: CGPoint
  var colorHex: String
  var fontSize: CGFloat
  var font: NativeStoryComposerFont
  var alignment: NSTextAlignment
}

private extension UIColor {
  static func nativeStoryComposerColor(from hex: String) -> UIColor {
    let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
    guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
      return .white
    }
    return UIColor(
      red: CGFloat((value >> 16) & 0xff) / 255.0,
      green: CGFloat((value >> 8) & 0xff) / 255.0,
      blue: CGFloat(value & 0xff) / 255.0,
      alpha: 1.0
    )
  }
}

private final class NativeStoryComposerMediaView: UIView {
  private let imageView = UIImageView()
  private let videoContainerView = UIView()
  private let playerLayer = AVPlayerLayer()
  private var player: AVPlayer?
  private var playbackObserver: NSObjectProtocol?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    addSubview(imageView)

    videoContainerView.clipsToBounds = true
    addSubview(videoContainerView)
    playerLayer.videoGravity = .resizeAspectFill
    videoContainerView.layer.addSublayer(playerLayer)
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    clearPlayer()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
    videoContainerView.frame = bounds
    playerLayer.frame = videoContainerView.bounds
  }

  func setMedia(uri: String?, type: NativeStoryComposerMediaType?, mirrored: Bool) {
    clearPlayer()
    imageView.image = nil
    imageView.isHidden = true
    videoContainerView.isHidden = true

    let transform = mirrored ? CGAffineTransform(scaleX: -1.0, y: 1.0) : .identity
    imageView.transform = transform
    videoContainerView.transform = transform

    guard let uri, let type else { return }
    switch type {
    case .image:
      imageView.isHidden = false
      loadImage(uri: uri)
    case .video:
      videoContainerView.isHidden = false
      loadVideo(uri: uri)
    }
  }

  func setPlaybackPaused(_ paused: Bool) {
    guard let player else { return }
    if paused {
      player.pause()
    } else {
      player.play()
    }
  }

  private func clearPlayer() {
    if let playbackObserver {
      NotificationCenter.default.removeObserver(playbackObserver)
      self.playbackObserver = nil
    }
    playerLayer.player = nil
    player?.pause()
    player = nil
  }

  private func loadImage(uri: String) {
    guard let url = URL(string: uri) else { return }
    if url.isFileURL {
      imageView.image = UIImage(contentsOfFile: url.path)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        self?.imageView.image = image
      }
    }
  }

  private func loadVideo(uri: String) {
    guard let url = URL(string: uri) else { return }
    let player = AVPlayer(url: url)
    player.actionAtItemEnd = .none
    playerLayer.player = player
    self.player = player
    playbackObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      player.seek(to: .zero)
      player.play()
    }
    player.play()
  }
}

private final class NativeStoryComposerStickerView: UIView {
  private let label = UILabel()
  private let padding = UIEdgeInsets(top: 8.0, left: 10.0, bottom: 8.0, right: 10.0)
  private var panOrigin = CGPoint.zero

  var overlayId: String = ""
  var onSelect: ((String) -> Void)?
  var onMove: ((String, CGPoint) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = true

    label.numberOfLines = 0
    addSubview(label)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)

    let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    addGestureRecognizer(panGesture)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = bounds.inset(by: padding)
  }

  func apply(overlay: NativeStoryComposerTextOverlay, selected: Bool) {
    overlayId = overlay.id
    label.text = overlay.text
    label.textColor = UIColor.nativeStoryComposerColor(from: overlay.colorHex)
    label.font = overlay.font.font(ofSize: overlay.fontSize)
    label.textAlignment = overlay.alignment
    label.shadowColor = UIColor.black.withAlphaComponent(0.55)
    label.shadowOffset = CGSize(width: 0.0, height: 1.0)

    let maxLabelSize = CGSize(width: 240.0, height: CGFloat.greatestFiniteMagnitude)
    let labelSize = label.sizeThatFits(maxLabelSize)
    bounds = CGRect(
      x: 0.0,
      y: 0.0,
      width: ceil(labelSize.width + padding.left + padding.right),
      height: ceil(labelSize.height + padding.top + padding.bottom)
    )

    layer.cornerRadius = 12.0
    layer.cornerCurve = .continuous
    layer.borderWidth = selected ? 1.0 : 0.0
    layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
    backgroundColor = selected ? UIColor.black.withAlphaComponent(0.18) : .clear
    setNeedsLayout()
  }

  @objc private func handleTap() {
    onSelect?(overlayId)
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    guard let superview else { return }
    switch gesture.state {
    case .began:
      panOrigin = center
      onSelect?(overlayId)
    case .changed:
      let translation = gesture.translation(in: superview)
      center = CGPoint(x: panOrigin.x + translation.x, y: panOrigin.y + translation.y)
    case .ended, .cancelled:
      onMove?(overlayId, center)
    default:
      break
    }
  }
}

private final class NativeStoryComposerSliderTrackView: UIView {
  private let shapeLayer = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    shapeLayer.fillColor = UIColor.white.withAlphaComponent(0.24).cgColor
    layer.addSublayer(shapeLayer)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset: CGFloat = 3.0
    let path = UIBezierPath()
    path.move(to: CGPoint(x: inset, y: 0.0))
    path.addLine(to: CGPoint(x: bounds.width - inset, y: 0.0))
    path.addLine(to: CGPoint(x: bounds.width * 0.56, y: bounds.height))
    path.addLine(to: CGPoint(x: bounds.width * 0.44, y: bounds.height))
    path.close()
    shapeLayer.frame = bounds
    shapeLayer.path = path.cgPath
  }
}

public final class NativeStoryComposerView: ExpoView, UITextViewDelegate {
  public var onNativeEvent = EventDispatcher()

  private let cardContainer = UIView()
  private let mediaView = NativeStoryComposerMediaView()
  private let overlaysContainer = UIView()
  private let topBar = UIView()
  private let closeButton = UIButton(type: .system)
  private let topActionsView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let downloadButton = UIButton(type: .system)
  private let addTextButton = UIButton(type: .system)
  private let emojiButton = UIButton(type: .system)
  private let musicButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)
  private let nextButton = UIButton(type: .system)
  private let bottomBar = UIView()
  private let promptChromeView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let promptTextView = UITextView()
  private let promptPlaceholderLabel = UILabel()
  private let promptSendButton = UIButton(type: .system)

  private let selectedActionBar = UIView()
  private let selectedEditButton = UIButton(type: .system)
  private let selectedDeleteButton = UIButton(type: .system)

  private let editorOverlay = UIView()
  private let editorCancelButton = UIButton(type: .system)
  private let editorDoneButton = UIButton(type: .system)
  private let editorTextView = UITextView()
  private let editorSliderContainer = UIView()
  private let editorSliderTrackView = NativeStoryComposerSliderTrackView()
  private let editorSliderHandleView = UIView()
  private let editorControlsView = UIView()
  private let colorToggleButton = UIButton(type: .system)
  private let fontCycleButton = UIButton(type: .system)
  private let alignCycleButton = UIButton(type: .system)
  private let colorsScrollView = UIScrollView()

  private let publishBackdropView = UIView()
  private let publishSheetView = UIView()
  private let publishTitleLabel = UILabel()
  private let audienceStackView = UIStackView()
  private let allowScreenshotsLabel = UILabel()
  private let allowScreenshotsSwitch = UISwitch()
  private let postToProfileLabel = UILabel()
  private let postToProfileSwitch = UISwitch()
  private let durationTitleLabel = UILabel()
  private let durationStackView = UIStackView()
  private let publishCancelButton = UIButton(type: .system)
  private let saveDraftButton = UIButton(type: .system)
  private let publishButton = UIButton(type: .system)

  private let composerColors = [
    "#FFFFFF", "#000000", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#5AC8FA", "#007AFF",
    "#5856D6", "#AF52DE", "#FF2D55", "#8E8E93",
  ]
  private var colorButtons: [UIButton] = []
  private var audienceButtons: [NativeStoryComposerAudience: UIButton] = [:]
  private var durationButtons: [Int: UIButton] = [:]

  private var mediaUri: String?
  private var mediaType: NativeStoryComposerMediaType?
  private var mirrored = false

  private var overlays: [NativeStoryComposerTextOverlay] = []
  private var stickerViews: [String: NativeStoryComposerStickerView] = [:]
  private var selectedOverlayId: String?
  private var editingOverlayId: String?
  private var editorColorHex = "#FFFFFF"
  private var editorFontSize: CGFloat = 30.0
  private var editorFont: NativeStoryComposerFont = .system
  private var editorAlignment: NSTextAlignment = .center
  private var editorShowsColorPicker = false
  private var keyboardHeight: CGFloat = 0.0
  private var promptText = ""

  private var selectedAudience: NativeStoryComposerAudience = .everyone
  private var selectedDuration = 24

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = UIColor(white: 0.04, alpha: 1.0)
    clipsToBounds = true
    configureView()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleKeyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleKeyboardWillHide),
      name: UIResponder.keyboardWillHideNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override public func didMoveToWindow() {
    super.didMoveToWindow()
    mediaView.setPlaybackPaused(window == nil)
  }

  override public func layoutSubviews() {
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
    mediaView.frame = cardContainer.bounds
    overlaysContainer.frame = cardContainer.bounds

    topBar.frame = CGRect(x: 14.0, y: 14.0, width: max(0.0, cardWidth - 28.0), height: 44.0)
    closeButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    let topActionButtonWidth: CGFloat = 40.0
    let topActionSpacing: CGFloat = 4.0
    let topActionCount: CGFloat = 5.0
    let topActionsWidth = (topActionButtonWidth * topActionCount) + (topActionSpacing * 2.0)
    topActionsView.frame = CGRect(
      x: max(52.0, topBar.bounds.width - topActionsWidth),
      y: 0.0,
      width: topActionsWidth,
      height: 44.0
    )
    let topButtons = [downloadButton, addTextButton, emojiButton, musicButton, settingsButton]
    for (index, button) in topButtons.enumerated() {
      button.frame = CGRect(
        x: topActionSpacing + (CGFloat(index) * topActionButtonWidth),
        y: 2.0,
        width: topActionButtonWidth,
        height: 40.0
      )
    }

    bottomBar.frame = CGRect(
      x: 10.0,
      y: cardContainer.frame.maxY + 18.0,
      width: max(0.0, bounds.width - 20.0),
      height: 56.0
    )
    let promptExpanded = isPromptExpanded
    let nextButtonWidth: CGFloat = promptExpanded ? 0.0 : 80.0
    let nextGap: CGFloat = promptExpanded ? 0.0 : 8.0
    let promptWidth = max(0.0, bottomBar.bounds.width - nextButtonWidth - nextGap)
    promptChromeView.frame = CGRect(x: 0.0, y: 0.0, width: promptWidth, height: bottomBar.bounds.height)
    nextButton.frame = CGRect(
      x: promptChromeView.frame.maxX + nextGap,
      y: 0.0,
      width: nextButtonWidth,
      height: bottomBar.bounds.height
    )
    nextButton.alpha = promptExpanded ? 0.0 : 1.0
    promptTextView.frame = CGRect(
      x: 14.0,
      y: 8.0,
      width: max(0.0, promptChromeView.bounds.width - 64.0),
      height: promptChromeView.bounds.height - 16.0
    )
    promptPlaceholderLabel.frame = CGRect(
      x: promptTextView.frame.minX + 4.0,
      y: 0.0,
      width: max(0.0, promptChromeView.bounds.width - 88.0),
      height: promptChromeView.bounds.height
    )
    promptSendButton.frame = CGRect(
      x: max(0.0, promptChromeView.bounds.width - 44.0),
      y: 6.0,
      width: 38.0,
      height: 38.0
    )

    if let selectedOverlayId, stickerViews[selectedOverlayId] != nil, !editorOverlay.isHidden {
      selectedActionBar.isHidden = true
    } else if let selectedOverlayId, let stickerView = stickerViews[selectedOverlayId] {
      selectedActionBar.isHidden = false
      let stickerFrame = overlaysContainer.convert(stickerView.frame, to: cardContainer)
      let barWidth: CGFloat = 92.0
      let barHeight: CGFloat = 36.0
      let barX = min(max(12.0, stickerFrame.midX - (barWidth * 0.5)), max(12.0, cardContainer.bounds.width - barWidth - 12.0))
      let barY = max(16.0, stickerFrame.minY - barHeight - 10.0)
      selectedActionBar.frame = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
      selectedEditButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: barHeight)
      selectedDeleteButton.frame = CGRect(x: barWidth - 44.0, y: 0.0, width: 44.0, height: barHeight)
    } else {
      selectedActionBar.isHidden = true
    }

    editorOverlay.frame = bounds
    let editorTop = safeTop + 14.0
    editorCancelButton.frame = CGRect(x: 20.0, y: editorTop, width: 70.0, height: 32.0)
    editorDoneButton.frame = CGRect(x: bounds.width - 90.0, y: editorTop, width: 70.0, height: 32.0)
    let controlsHeight: CGFloat = editorShowsColorPicker ? 104.0 : 48.0
    editorControlsView.frame = CGRect(
      x: 16.0,
      y: bounds.height - safeBottom - controlsHeight - max(0.0, keyboardHeight),
      width: max(0.0, bounds.width - 32.0),
      height: controlsHeight
    )
    editorSliderContainer.frame = CGRect(
      x: 4.0,
      y: max(editorTop + 72.0, min(bounds.height * 0.28, editorControlsView.frame.minY - 260.0)),
      width: 56.0,
      height: 240.0
    )
    editorSliderTrackView.frame = CGRect(x: 8.0, y: 0.0, width: 40.0, height: 240.0)
    editorSliderHandleView.frame = CGRect(x: 10.0, y: sliderHandleY(for: editorFontSize), width: 36.0, height: 36.0)
    let textWidth = max(120.0, bounds.width - 112.0)
    editorTextView.frame = CGRect(
      x: 56.0,
      y: max(editorTop + 48.0, ((editorControlsView.frame.minY - 180.0) * 0.5)),
      width: textWidth,
      height: min(200.0, editorControlsView.frame.minY - editorTop - 80.0)
    )

    colorToggleButton.frame = CGRect(x: 8.0, y: 6.0, width: 36.0, height: 36.0)
    fontCycleButton.frame = CGRect(x: 52.0, y: 6.0, width: 90.0, height: 36.0)
    alignCycleButton.frame = CGRect(x: editorControlsView.bounds.width - 44.0, y: 6.0, width: 36.0, height: 36.0)
    colorsScrollView.frame = CGRect(
      x: 8.0,
      y: 50.0,
      width: max(0.0, editorControlsView.bounds.width - 16.0),
      height: editorShowsColorPicker ? 44.0 : 0.0
    )

    let colorButtonSize: CGFloat = 34.0
    for (index, button) in colorButtons.enumerated() {
      button.frame = CGRect(
        x: CGFloat(index) * (colorButtonSize + 10.0),
        y: 7.0,
        width: colorButtonSize,
        height: colorButtonSize
      )
    }
    colorsScrollView.contentSize = CGSize(
      width: CGFloat(colorButtons.count) * (colorButtonSize + 10.0),
      height: 48.0
    )

    publishBackdropView.frame = bounds
    let sheetHeight: CGFloat = 330.0 + safeBottom
    publishSheetView.frame = CGRect(
      x: 12.0,
      y: bounds.height - sheetHeight - 10.0,
      width: max(0.0, bounds.width - 24.0),
      height: sheetHeight
    )
    publishTitleLabel.frame = CGRect(x: 20.0, y: 18.0, width: publishSheetView.bounds.width - 40.0, height: 24.0)
    audienceStackView.frame = CGRect(x: 20.0, y: 56.0, width: publishSheetView.bounds.width - 40.0, height: 42.0)
    durationTitleLabel.frame = CGRect(x: 20.0, y: audienceStackView.frame.maxY + 16.0, width: 140.0, height: 22.0)
    durationStackView.frame = CGRect(x: 20.0, y: durationTitleLabel.frame.maxY + 10.0, width: publishSheetView.bounds.width - 40.0, height: 40.0)

    let switchRowY = durationStackView.frame.maxY + 22.0
    allowScreenshotsLabel.frame = CGRect(x: 20.0, y: switchRowY, width: 200.0, height: 24.0)
    allowScreenshotsSwitch.frame = CGRect(
      x: publishSheetView.bounds.width - allowScreenshotsSwitch.bounds.width - 20.0,
      y: switchRowY - 4.0,
      width: allowScreenshotsSwitch.bounds.width,
      height: allowScreenshotsSwitch.bounds.height
    )
    postToProfileLabel.frame = CGRect(x: 20.0, y: switchRowY + 42.0, width: 200.0, height: 24.0)
    postToProfileSwitch.frame = CGRect(
      x: publishSheetView.bounds.width - postToProfileSwitch.bounds.width - 20.0,
      y: switchRowY + 38.0,
      width: postToProfileSwitch.bounds.width,
      height: postToProfileSwitch.bounds.height
    )

    let actionY = publishSheetView.bounds.height - safeBottom - 56.0
    let buttonWidth = floor((publishSheetView.bounds.width - 52.0) / 3.0)
    publishCancelButton.frame = CGRect(x: 16.0, y: actionY, width: buttonWidth, height: 44.0)
    saveDraftButton.frame = CGRect(x: publishCancelButton.frame.maxX + 10.0, y: actionY, width: buttonWidth, height: 44.0)
    publishButton.frame = CGRect(x: saveDraftButton.frame.maxX + 10.0, y: actionY, width: buttonWidth, height: 44.0)
  }

  func setMediaUri(_ value: String?) {
    mediaUri = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    applyMedia()
  }

  func setMediaType(_ value: String?) {
    mediaType = value.flatMap(NativeStoryComposerMediaType.init(rawValue:))
    applyMedia()
  }

  func setMirrored(_ value: Bool) {
    mirrored = value
    applyMedia()
  }

  @objc private func handleKeyboardWillChangeFrame(_ notification: Notification) {
    guard
      let userInfo = notification.userInfo,
      let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
    else { return }

    let convertedFrame = convert(endFrame, from: nil)
    keyboardHeight = max(0.0, bounds.maxY - convertedFrame.minY)
    let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    UIView.animate(withDuration: duration) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  @objc private func handleKeyboardWillHide() {
    keyboardHeight = 0.0
    UIView.animate(withDuration: 0.25) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  @objc private func handleCanvasTap() {
    selectedOverlayId = nil
    updateStickerSelection()
  }

  @objc private func handleClosePress() {
    let alert = UIAlertController(
      title: "Discard Edits?",
      message: "Are you sure you want to discard your story? This cannot be undone.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "discard"])
      }
    )
    if let controller = presentingViewController() {
      controller.present(alert, animated: true)
    } else {
      onNativeEvent(["type": "discard"])
    }
  }

  @objc private func handleAddTextPress() {
    beginEditingOverlay(nil)
  }

  @objc private func handleDownloadPress() {
    saveCurrentMediaToLibrary()
  }

  @objc private func handleEmojiPress() {
    presentInfoAlert(title: "Not Available Yet", message: "Emoji stickers are not wired in the native composer yet.")
  }

  @objc private func handleMusicPress() {
    presentInfoAlert(title: "Not Available Yet", message: "Music stickers are not wired in the native composer yet.")
  }

  @objc private func handleSettingsPress() {
    presentInfoAlert(title: "No Settings Yet", message: "Story settings are still using the publish sheet for now.")
  }

  @objc private func handleNextPress() {
    endEditing(true)
    showPublishSheet(true)
  }

  @objc private func handleSelectedEditPress() {
    guard let selectedOverlayId else { return }
    beginEditingOverlay(selectedOverlayId)
  }

  @objc private func handleSelectedDeletePress() {
    guard let selectedOverlayId else { return }
    deleteOverlay(withId: selectedOverlayId)
  }

  @objc private func handleEditorCancelPress() {
    endEditing(true)
    hideEditor()
  }

  @objc private func handleEditorDonePress() {
    let trimmed = editorTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      if let editingOverlayId {
        deleteOverlay(withId: editingOverlayId)
      } else {
        selectedOverlayId = nil
      }
      hideEditor()
      return
    }

    if let editingOverlayId, let index = overlays.firstIndex(where: { $0.id == editingOverlayId }) {
      overlays[index].text = trimmed
      overlays[index].colorHex = editorColorHex
      overlays[index].fontSize = editorFontSize
      overlays[index].font = editorFont
      overlays[index].alignment = editorAlignment
      selectedOverlayId = editingOverlayId
    } else {
      let newId = UUID().uuidString
      let overlay = NativeStoryComposerTextOverlay(
        id: newId,
        text: trimmed,
        center: CGPoint(x: overlaysContainer.bounds.midX, y: overlaysContainer.bounds.midY * 0.65),
        colorHex: editorColorHex,
        fontSize: editorFontSize,
        font: editorFont,
        alignment: editorAlignment
      )
      overlays.append(overlay)
      selectedOverlayId = newId
    }

    syncStickers()
    hideEditor()
  }

  @objc private func handleColorTogglePress() {
    editorShowsColorPicker.toggle()
    UIView.animate(withDuration: 0.2) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  @objc private func handleFontCyclePress() {
    let allFonts = NativeStoryComposerFont.allCases
    guard let currentIndex = allFonts.firstIndex(of: editorFont) else { return }
    editorFont = allFonts[(currentIndex + 1) % allFonts.count]
    updateEditorControls()
  }

  @objc private func handleAlignCyclePress() {
    switch editorAlignment {
    case .left:
      editorAlignment = .center
    case .center:
      editorAlignment = .right
    default:
      editorAlignment = .left
    }
    updateEditorControls()
  }

  @objc private func handleEditorSliderPan(_ gesture: UIPanGestureRecognizer) {
    let location = gesture.location(in: editorSliderContainer)
    updateEditorFontSize(fromSliderY: location.y)
  }

  @objc private func handlePromptSendPress() {
    let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    promptText = ""
    promptTextView.text = ""
    promptTextView.resignFirstResponder()
    updatePromptUI(animated: true)
    onNativeEvent([
      "type": "aiEdit",
      "prompt": prompt,
    ])
  }

  @objc private func handlePublishCancelPress() {
    showPublishSheet(false)
  }

  @objc private func handleSaveDraftPress() {
    showPublishSheet(false)
    onNativeEvent(["type": "saveDraft"])
  }

  @objc private func handlePublishPress() {
    showPublishSheet(false)
    onNativeEvent([
      "type": "publish",
      "audience": selectedAudience.rawValue,
      "allowScreenshots": allowScreenshotsSwitch.isOn,
      "postToProfile": postToProfileSwitch.isOn,
      "duration": selectedDuration,
    ])
  }

  private func configureView() {
    cardContainer.backgroundColor = UIColor(white: 0.06, alpha: 1.0)
    cardContainer.layer.cornerRadius = 32.0
    cardContainer.layer.cornerCurve = .continuous
    cardContainer.layer.borderWidth = 1.0
    cardContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    cardContainer.clipsToBounds = true
    addSubview(cardContainer)

    cardContainer.addSubview(mediaView)

    overlaysContainer.backgroundColor = .clear
    cardContainer.addSubview(overlaysContainer)

    let canvasTap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap))
    canvasTap.cancelsTouchesInView = false
    overlaysContainer.addGestureRecognizer(canvasTap)

    topBar.backgroundColor = .clear
    cardContainer.addSubview(topBar)

    configureChromeButton(closeButton, symbol: "xmark")
    closeButton.addTarget(self, action: #selector(handleClosePress), for: .touchUpInside)
    topBar.addSubview(closeButton)

    topActionsView.clipsToBounds = true
    topActionsView.layer.cornerRadius = 22.0
    topActionsView.layer.cornerCurve = .continuous
    topActionsView.contentView.backgroundColor = UIColor.black.withAlphaComponent(0.15)
    topBar.addSubview(topActionsView)

    configureTopActionButton(downloadButton, symbol: "arrow.down.circle")
    downloadButton.addTarget(self, action: #selector(handleDownloadPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(downloadButton)

    configureTopActionButton(addTextButton, symbol: "textformat")
    addTextButton.addTarget(self, action: #selector(handleAddTextPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(addTextButton)

    configureTopActionButton(emojiButton, symbol: "face.smiling")
    emojiButton.addTarget(self, action: #selector(handleEmojiPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(emojiButton)

    configureTopActionButton(musicButton, symbol: "music.note")
    musicButton.addTarget(self, action: #selector(handleMusicPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(musicButton)

    configureTopActionButton(settingsButton, symbol: "gearshape")
    settingsButton.addTarget(self, action: #selector(handleSettingsPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(settingsButton)

    selectedActionBar.backgroundColor = UIColor.black.withAlphaComponent(0.42)
    selectedActionBar.layer.cornerRadius = 18.0
    selectedActionBar.layer.cornerCurve = .continuous
    selectedActionBar.layer.borderWidth = 1.0
    selectedActionBar.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    selectedActionBar.isHidden = true
    cardContainer.addSubview(selectedActionBar)

    configureSmallActionButton(selectedEditButton, symbol: "pencil")
    selectedEditButton.addTarget(self, action: #selector(handleSelectedEditPress), for: .touchUpInside)
    selectedActionBar.addSubview(selectedEditButton)

    configureSmallActionButton(selectedDeleteButton, symbol: "trash")
    selectedDeleteButton.tintColor = UIColor(red: 1.0, green: 0.36, blue: 0.32, alpha: 1.0)
    selectedDeleteButton.addTarget(self, action: #selector(handleSelectedDeletePress), for: .touchUpInside)
    selectedActionBar.addSubview(selectedDeleteButton)

    bottomBar.backgroundColor = .clear
    addSubview(bottomBar)

    promptChromeView.clipsToBounds = true
    promptChromeView.layer.cornerRadius = 28.0
    promptChromeView.layer.cornerCurve = .continuous
    promptChromeView.contentView.backgroundColor = UIColor.black.withAlphaComponent(0.14)
    bottomBar.addSubview(promptChromeView)

    promptTextView.backgroundColor = .clear
    promptTextView.textColor = .white
    promptTextView.tintColor = .white
    promptTextView.font = .systemFont(ofSize: 16.0, weight: .medium)
    promptTextView.textContainerInset = UIEdgeInsets(top: 10.0, left: 0.0, bottom: 10.0, right: 0.0)
    promptTextView.textContainer.lineFragmentPadding = 0.0
    promptTextView.returnKeyType = .send
    promptTextView.autocorrectionType = .yes
    promptTextView.delegate = self
    promptChromeView.contentView.addSubview(promptTextView)

    promptPlaceholderLabel.text = "Ask AI to edit..."
    promptPlaceholderLabel.textColor = UIColor.white.withAlphaComponent(0.55)
    promptPlaceholderLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
    promptChromeView.contentView.addSubview(promptPlaceholderLabel)

    promptSendButton.layer.cornerRadius = 19.0
    promptSendButton.layer.cornerCurve = .continuous
    promptSendButton.tintColor = .white
    promptSendButton.setImage(
      UIImage(
        systemName: "arrow.up",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .bold)
      ),
      for: .normal
    )
    promptSendButton.addTarget(self, action: #selector(handlePromptSendPress), for: .touchUpInside)
    promptChromeView.contentView.addSubview(promptSendButton)

    nextButton.backgroundColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.92)
    nextButton.layer.cornerRadius = 28.0
    nextButton.layer.cornerCurve = .continuous
    nextButton.setTitle("Next", for: .normal)
    nextButton.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
    nextButton.setTitleColor(.white, for: .normal)
    nextButton.addTarget(self, action: #selector(handleNextPress), for: .touchUpInside)
    bottomBar.addSubview(nextButton)

    editorOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.3)
    editorOverlay.isHidden = true
    addSubview(editorOverlay)

    editorCancelButton.setTitle("Cancel", for: .normal)
    editorCancelButton.setTitleColor(.white, for: .normal)
    editorCancelButton.titleLabel?.font = .systemFont(ofSize: 17.0, weight: .medium)
    editorCancelButton.addTarget(self, action: #selector(handleEditorCancelPress), for: .touchUpInside)
    editorOverlay.addSubview(editorCancelButton)

    editorDoneButton.setTitle("Done", for: .normal)
    editorDoneButton.setTitleColor(.white, for: .normal)
    editorDoneButton.titleLabel?.font = .systemFont(ofSize: 17.0, weight: .semibold)
    editorDoneButton.addTarget(self, action: #selector(handleEditorDonePress), for: .touchUpInside)
    editorOverlay.addSubview(editorDoneButton)

    editorTextView.backgroundColor = .clear
    editorTextView.textColor = .white
    editorTextView.font = .systemFont(ofSize: editorFontSize, weight: .bold)
    editorTextView.textAlignment = editorAlignment
    editorTextView.returnKeyType = .default
    editorTextView.tintColor = .white
    editorTextView.textContainerInset = .zero
    editorTextView.textContainer.lineFragmentPadding = 0.0
    editorTextView.delegate = self
    editorOverlay.addSubview(editorTextView)

    editorSliderContainer.backgroundColor = .clear
    let sliderPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleEditorSliderPan(_:)))
    editorSliderContainer.addGestureRecognizer(sliderPanGesture)
    editorOverlay.addSubview(editorSliderContainer)

    editorSliderContainer.addSubview(editorSliderTrackView)

    editorSliderHandleView.backgroundColor = .white
    editorSliderHandleView.layer.cornerRadius = 18.0
    editorSliderHandleView.layer.cornerCurve = .continuous
    editorSliderHandleView.layer.shadowColor = UIColor.black.cgColor
    editorSliderHandleView.layer.shadowOpacity = 0.2
    editorSliderHandleView.layer.shadowRadius = 8.0
    editorSliderHandleView.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
    editorSliderContainer.addSubview(editorSliderHandleView)

    editorControlsView.backgroundColor = UIColor.black.withAlphaComponent(0.42)
    editorControlsView.layer.cornerRadius = 22.0
    editorControlsView.layer.cornerCurve = .continuous
    editorControlsView.layer.borderWidth = 1.0
    editorControlsView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    editorOverlay.addSubview(editorControlsView)

    configureRoundSymbolButton(colorToggleButton, symbol: "circle.fill")
    colorToggleButton.addTarget(self, action: #selector(handleColorTogglePress), for: .touchUpInside)
    editorControlsView.addSubview(colorToggleButton)

    configureRoundButton(fontCycleButton, title: editorFont.title)
    fontCycleButton.addTarget(self, action: #selector(handleFontCyclePress), for: .touchUpInside)
    editorControlsView.addSubview(fontCycleButton)

    configureRoundSymbolButton(alignCycleButton, symbol: "text.aligncenter")
    alignCycleButton.addTarget(self, action: #selector(handleAlignCyclePress), for: .touchUpInside)
    editorControlsView.addSubview(alignCycleButton)

    colorsScrollView.showsHorizontalScrollIndicator = false
    editorControlsView.addSubview(colorsScrollView)
    configureColorButtons()

    publishBackdropView.backgroundColor = UIColor.black.withAlphaComponent(0.48)
    publishBackdropView.alpha = 0.0
    publishBackdropView.isHidden = true
    let publishTap = UITapGestureRecognizer(target: self, action: #selector(handlePublishCancelPress))
    publishBackdropView.addGestureRecognizer(publishTap)
    addSubview(publishBackdropView)

    publishSheetView.backgroundColor = UIColor(white: 0.09, alpha: 0.98)
    publishSheetView.layer.cornerRadius = 28.0
    publishSheetView.layer.cornerCurve = .continuous
    publishSheetView.layer.borderWidth = 1.0
    publishSheetView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    publishSheetView.alpha = 0.0
    publishSheetView.transform = CGAffineTransform(translationX: 0.0, y: 40.0)
    publishSheetView.isHidden = true
    addSubview(publishSheetView)

    publishTitleLabel.text = "Publish Story"
    publishTitleLabel.textColor = .white
    publishTitleLabel.font = .systemFont(ofSize: 20.0, weight: .semibold)
    publishSheetView.addSubview(publishTitleLabel)

    audienceStackView.axis = .horizontal
    audienceStackView.alignment = .fill
    audienceStackView.distribution = .fillEqually
    audienceStackView.spacing = 10.0
    publishSheetView.addSubview(audienceStackView)
    configureAudienceButtons()

    durationTitleLabel.text = "Duration"
    durationTitleLabel.textColor = UIColor.white.withAlphaComponent(0.8)
    durationTitleLabel.font = .systemFont(ofSize: 14.0, weight: .medium)
    publishSheetView.addSubview(durationTitleLabel)

    durationStackView.axis = .horizontal
    durationStackView.alignment = .fill
    durationStackView.distribution = .fillEqually
    durationStackView.spacing = 10.0
    publishSheetView.addSubview(durationStackView)
    configureDurationButtons()

    allowScreenshotsLabel.text = "Allow Screenshots"
    allowScreenshotsLabel.textColor = .white
    allowScreenshotsLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
    publishSheetView.addSubview(allowScreenshotsLabel)

    allowScreenshotsSwitch.isOn = true
    publishSheetView.addSubview(allowScreenshotsSwitch)

    postToProfileLabel.text = "Post To Profile"
    postToProfileLabel.textColor = .white
    postToProfileLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
    publishSheetView.addSubview(postToProfileLabel)

    postToProfileSwitch.isOn = true
    publishSheetView.addSubview(postToProfileSwitch)

    configureSheetActionButton(publishCancelButton, title: "Cancel", fillColor: UIColor.white.withAlphaComponent(0.12))
    publishCancelButton.addTarget(self, action: #selector(handlePublishCancelPress), for: .touchUpInside)
    publishSheetView.addSubview(publishCancelButton)

    configureSheetActionButton(saveDraftButton, title: "Draft", fillColor: UIColor.white.withAlphaComponent(0.16))
    saveDraftButton.addTarget(self, action: #selector(handleSaveDraftPress), for: .touchUpInside)
    publishSheetView.addSubview(saveDraftButton)

    configureSheetActionButton(publishButton, title: "Publish", fillColor: UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.92))
    publishButton.addTarget(self, action: #selector(handlePublishPress), for: .touchUpInside)
    publishSheetView.addSubview(publishButton)

    updateEditorControls()
    updateAudienceButtons()
    updateDurationButtons()
  }

  private func configureChromeButton(_ button: UIButton, symbol: String) {
    button.backgroundColor = UIColor.black.withAlphaComponent(0.28)
    button.layer.cornerRadius = 22.0
    button.layer.cornerCurve = .continuous
    button.layer.borderWidth = 1.0
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    button.tintColor = .white
    button.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)
      ),
      for: .normal
    )
  }

  private func configureTopActionButton(_ button: UIButton, symbol: String) {
    button.tintColor = .white
    button.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)
      ),
      for: .normal
    )
  }

  private func configureSmallActionButton(_ button: UIButton, symbol: String) {
    button.tintColor = .white
    button.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)
      ),
      for: .normal
    )
  }

  private func configureRoundButton(_ button: UIButton, title: String) {
    button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    button.layer.cornerRadius = 18.0
    button.layer.cornerCurve = .continuous
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 13.0, weight: .semibold)
  }

  private func configureRoundSymbolButton(_ button: UIButton, symbol: String) {
    button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    button.layer.cornerRadius = 18.0
    button.layer.cornerCurve = .continuous
    button.tintColor = .white
    button.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)
      ),
      for: .normal
    )
  }

  private func configureColorButtons() {
    colorButtons.forEach { $0.removeFromSuperview() }
    colorButtons.removeAll()
    for hex in composerColors {
      let button = UIButton(type: .custom)
      button.layer.cornerRadius = 17.0
      button.layer.cornerCurve = .continuous
      button.backgroundColor = UIColor.nativeStoryComposerColor(from: hex)
      button.layer.borderWidth = 2.0
      button.layer.borderColor = UIColor.clear.cgColor
      button.accessibilityLabel = hex
      button.addAction(
        UIAction { [weak self] _ in
          self?.editorColorHex = hex
          self?.updateEditorControls()
        },
        for: .touchUpInside
      )
      colorsScrollView.addSubview(button)
      colorButtons.append(button)
    }
  }

  private func configureAudienceButtons() {
    NativeStoryComposerAudience.allCases.forEach { audience in
      let button = UIButton(type: .system)
      button.layer.cornerRadius = 18.0
      button.layer.cornerCurve = .continuous
      button.titleLabel?.font = .systemFont(ofSize: 13.0, weight: .semibold)
      button.setTitle(audience.title, for: .normal)
      button.addAction(
        UIAction { [weak self] _ in
          self?.selectedAudience = audience
          self?.updateAudienceButtons()
        },
        for: .touchUpInside
      )
      audienceButtons[audience] = button
      audienceStackView.addArrangedSubview(button)
    }
  }

  private func configureDurationButtons() {
    [12, 24, 48].forEach { duration in
      let button = UIButton(type: .system)
      button.layer.cornerRadius = 18.0
      button.layer.cornerCurve = .continuous
      button.titleLabel?.font = .systemFont(ofSize: 14.0, weight: .semibold)
      button.setTitle("\(duration)h", for: .normal)
      button.addAction(
        UIAction { [weak self] _ in
          self?.selectedDuration = duration
          self?.updateDurationButtons()
        },
        for: .touchUpInside
      )
      durationButtons[duration] = button
      durationStackView.addArrangedSubview(button)
    }
  }

  private func configureSheetActionButton(_ button: UIButton, title: String, fillColor: UIColor) {
    button.backgroundColor = fillColor
    button.layer.cornerRadius = 16.0
    button.layer.cornerCurve = .continuous
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 14.0, weight: .semibold)
  }

  private func applyMedia() {
    mediaView.setMedia(uri: mediaUri, type: mediaType, mirrored: mirrored)
  }

  private func beginEditingOverlay(_ overlayId: String?) {
    editingOverlayId = overlayId
    if let overlayId, let overlay = overlays.first(where: { $0.id == overlayId }) {
      editorTextView.text = overlay.text
      editorColorHex = overlay.colorHex
      editorFontSize = overlay.fontSize
      editorFont = overlay.font
      editorAlignment = overlay.alignment
    } else {
      editorTextView.text = ""
      editorColorHex = "#FFFFFF"
      editorFontSize = 30.0
      editorFont = .system
      editorAlignment = .center
    }
    editorShowsColorPicker = false
    updateEditorControls()
    editorOverlay.isHidden = false
    bringSubviewToFront(editorOverlay)
    setNeedsLayout()
    layoutIfNeeded()
    editorTextView.becomeFirstResponder()
  }

  private func hideEditor() {
    editingOverlayId = nil
    endEditing(true)
    editorShowsColorPicker = false
    editorOverlay.isHidden = true
    updateEditorControls()
    setNeedsLayout()
  }

  private func updateEditorControls() {
    editorTextView.textColor = UIColor.nativeStoryComposerColor(from: editorColorHex)
    editorTextView.font = editorFont.font(ofSize: editorFontSize)
    editorTextView.textAlignment = editorAlignment
    fontCycleButton.setTitle(editorFont.title, for: .normal)

    colorButtons.forEach { button in
      let isSelected = button.accessibilityLabel == editorColorHex
      button.layer.borderColor = isSelected ? UIColor.white.cgColor : UIColor.clear.cgColor
    }

    let activeColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.9)
    fontCycleButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    fontCycleButton.setTitleColor(.white, for: .normal)
    colorToggleButton.tintColor = UIColor.nativeStoryComposerColor(from: editorColorHex)
    colorToggleButton.backgroundColor = editorShowsColorPicker
      ? activeColor
      : UIColor.white.withAlphaComponent(0.12)
    alignCycleButton.backgroundColor = activeColor
    alignCycleButton.tintColor = .white
    switch editorAlignment {
    case .left:
      alignCycleButton.setImage(
        UIImage(
          systemName: "text.alignleft",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)
        ),
        for: .normal
      )
    case .center:
      alignCycleButton.setImage(
        UIImage(
          systemName: "text.aligncenter",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)
        ),
        for: .normal
      )
    case .right:
      alignCycleButton.setImage(
        UIImage(
          systemName: "text.alignright",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)
        ),
        for: .normal
      )
    default:
      break
    }
    updatePromptUI(animated: false)
  }

  private func syncStickers() {
    let overlayIds = Set(overlays.map(\.id))

    let removedIds = stickerViews.keys.filter { !overlayIds.contains($0) }
    for id in removedIds {
      guard let stickerView = stickerViews[id] else { continue }
      stickerView.removeFromSuperview()
      stickerViews.removeValue(forKey: id)
    }

    for overlay in overlays {
      let stickerView: NativeStoryComposerStickerView
      if let existing = stickerViews[overlay.id] {
        stickerView = existing
      } else {
        let created = NativeStoryComposerStickerView()
        created.onSelect = { [weak self] overlayId in
          self?.selectedOverlayId = overlayId
          self?.updateStickerSelection()
        }
        created.onMove = { [weak self] overlayId, center in
          self?.updateOverlayPosition(id: overlayId, center: center)
        }
        overlaysContainer.addSubview(created)
        stickerViews[overlay.id] = created
        stickerView = created
      }

      stickerView.apply(overlay: overlay, selected: selectedOverlayId == overlay.id)
      stickerView.center = clampedCenter(for: overlay.center, stickerBounds: stickerView.bounds)
    }

    updateStickerSelection()
  }

  private func updateStickerSelection() {
    for overlay in overlays {
      if let stickerView = stickerViews[overlay.id] {
        stickerView.apply(overlay: overlay, selected: selectedOverlayId == overlay.id)
        stickerView.center = clampedCenter(for: overlay.center, stickerBounds: stickerView.bounds)
      }
    }
    setNeedsLayout()
  }

  private func updateOverlayPosition(id: String, center: CGPoint) {
    guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }
    overlays[index].center = clampedCenter(for: center, stickerBounds: stickerViews[id]?.bounds ?? .zero)
    if let stickerView = stickerViews[id] {
      stickerView.center = overlays[index].center
    }
    setNeedsLayout()
  }

  private func deleteOverlay(withId id: String) {
    overlays.removeAll { $0.id == id }
    stickerViews[id]?.removeFromSuperview()
    stickerViews.removeValue(forKey: id)
    if selectedOverlayId == id {
      selectedOverlayId = nil
    }
    setNeedsLayout()
  }

  private var isPromptExpanded: Bool {
    promptTextView.isFirstResponder || !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func sliderHandleY(for fontSize: CGFloat) -> CGFloat {
    let clamped = max(10.0, min(100.0, fontSize))
    let progress = 1.0 - ((clamped - 10.0) / 90.0)
    return min(204.0, max(0.0, progress * 204.0))
  }

  private func updateEditorFontSize(fromSliderY y: CGFloat) {
    let clampedY = min(max(0.0, y), 240.0)
    let progress = 1.0 - (clampedY / 240.0)
    editorFontSize = max(10.0, min(100.0, 10.0 + (progress * 90.0)))
    updateEditorControls()
    setNeedsLayout()
  }

  private func updatePromptUI(animated: Bool) {
    let applyChanges = {
      let trimmed = self.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasPrompt = !trimmed.isEmpty
      self.promptPlaceholderLabel.isHidden = !self.promptText.isEmpty
      self.promptSendButton.backgroundColor = hasPrompt
        ? UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.92)
        : UIColor.white.withAlphaComponent(0.12)
      self.promptSendButton.alpha = hasPrompt ? 1.0 : 0.82
      self.promptSendButton.isEnabled = hasPrompt
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }

    if animated {
      UIView.animate(withDuration: 0.22, animations: applyChanges)
    } else {
      applyChanges()
    }
  }

  private func clampedCenter(for center: CGPoint, stickerBounds: CGRect) -> CGPoint {
    let halfWidth = stickerBounds.width * 0.5
    let halfHeight = stickerBounds.height * 0.5
    let insetX = max(halfWidth + 12.0, 12.0)
    let insetY = max(halfHeight + 12.0, 12.0)
    return CGPoint(
      x: min(max(insetX, center.x), max(insetX, overlaysContainer.bounds.width - insetX)),
      y: min(max(insetY, center.y), max(insetY, overlaysContainer.bounds.height - insetY))
    )
  }

  private func saveCurrentMediaToLibrary() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    switch status {
    case .authorized, .limited:
      performSaveCurrentMedia()
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] nextStatus in
        DispatchQueue.main.async {
          if nextStatus == .authorized || nextStatus == .limited {
            self?.performSaveCurrentMedia()
          } else {
            self?.presentInfoAlert(
              title: "Permission Needed",
              message: "Allow Photos access to save this story."
            )
          }
        }
      }
    default:
      presentInfoAlert(title: "Permission Needed", message: "Allow Photos access to save this story.")
    }
  }

  private func performSaveCurrentMedia() {
    guard let uri = mediaUri else {
      presentInfoAlert(title: "Save Failed", message: "No media is loaded.")
      return
    }
    guard let url = URL(string: uri) else {
      presentInfoAlert(title: "Save Failed", message: "The media URL is invalid.")
      return
    }

    switch mediaType {
    case .video:
      guard url.isFileURL else {
        presentInfoAlert(title: "Save Failed", message: "Video can only be saved from a local file.")
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      }) { [weak self] success, _ in
        DispatchQueue.main.async {
          if success {
            self?.presentInfoAlert(title: "Saved", message: "Story saved to your gallery.")
          } else {
            self?.presentInfoAlert(title: "Save Failed", message: "Could not save this video.")
          }
        }
      }
    case .image:
      guard let image = imageForSave(from: uri) else {
        presentInfoAlert(title: "Save Failed", message: "Could not load this image.")
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAsset(from: image)
      }) { [weak self] success, _ in
        DispatchQueue.main.async {
          if success {
            self?.presentInfoAlert(title: "Saved", message: "Story saved to your gallery.")
          } else {
            self?.presentInfoAlert(title: "Save Failed", message: "Could not save this image.")
          }
        }
      }
    case .none:
      presentInfoAlert(title: "Save Failed", message: "No media is loaded.")
    }
  }

  private func imageForSave(from uri: String) -> UIImage? {
    if uri.hasPrefix("data:image"), let commaIndex = uri.firstIndex(of: ",") {
      let payload = String(uri[uri.index(after: commaIndex)...])
      if let data = Data(base64Encoded: payload) {
        return UIImage(data: data)
      }
    }

    guard let url = URL(string: uri) else { return nil }
    if url.isFileURL {
      return UIImage(contentsOfFile: url.path)
    }
    if let data = try? Data(contentsOf: url) {
      return UIImage(data: data)
    }
    return nil
  }

  private func presentInfoAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    if let controller = presentingViewController() {
      controller.present(alert, animated: true)
    }
  }

  private func showPublishSheet(_ visible: Bool) {
    if visible {
      publishBackdropView.isHidden = false
      publishSheetView.isHidden = false
      bringSubviewToFront(publishBackdropView)
      bringSubviewToFront(publishSheetView)
      UIView.animate(withDuration: 0.22) {
        self.publishBackdropView.alpha = 1.0
        self.publishSheetView.alpha = 1.0
        self.publishSheetView.transform = .identity
      }
      return
    }

    UIView.animate(withDuration: 0.18) {
      self.publishBackdropView.alpha = 0.0
      self.publishSheetView.alpha = 0.0
      self.publishSheetView.transform = CGAffineTransform(translationX: 0.0, y: 40.0)
    } completion: { _ in
      self.publishBackdropView.isHidden = true
      self.publishSheetView.isHidden = true
    }
  }

  private func updateAudienceButtons() {
    for (audience, button) in audienceButtons {
      let active = audience == selectedAudience
      button.backgroundColor = active
        ? UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.9)
        : UIColor.white.withAlphaComponent(0.1)
      button.setTitleColor(.white, for: .normal)
    }
  }

  private func updateDurationButtons() {
    for (duration, button) in durationButtons {
      let active = duration == selectedDuration
      button.backgroundColor = active
        ? UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.9)
        : UIColor.white.withAlphaComponent(0.1)
      button.setTitleColor(.white, for: .normal)
    }
  }

  public func textViewDidBeginEditing(_ textView: UITextView) {
    if textView === promptTextView {
      updatePromptUI(animated: true)
    }
  }

  public func textViewDidEndEditing(_ textView: UITextView) {
    if textView === promptTextView {
      updatePromptUI(animated: true)
    }
  }

  public func textViewDidChange(_ textView: UITextView) {
    if textView === promptTextView {
      promptText = textView.text ?? ""
      updatePromptUI(animated: false)
    }
  }

  public func textView(
    _ textView: UITextView,
    shouldChangeTextIn range: NSRange,
    replacementText text: String
  ) -> Bool {
    if textView === promptTextView, text == "\n" {
      handlePromptSendPress()
      return false
    }
    return true
  }

  private func presentingViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let current = responder {
      if let controller = current as? UIViewController {
        return controller
      }
      responder = current.next
    }
    return nil
  }
}

public final class NativeStoryComposerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("NativeStoryComposer")

    View(NativeStoryComposerView.self) {
      Prop("mediaUri") { (view: NativeStoryComposerView, value: String?) in
        view.setMediaUri(value)
      }

      Prop("mediaType") { (view: NativeStoryComposerView, value: String?) in
        view.setMediaType(value)
      }

      Prop("mirrored") { (view: NativeStoryComposerView, value: Bool?) in
        view.setMirrored(value ?? false)
      }

      Events("onNativeEvent")
    }
  }
}
