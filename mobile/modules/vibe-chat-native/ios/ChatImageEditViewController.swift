import UIKit

private final class ChatImageDrawingCanvasView: UIView {
  private var completedPaths: [UIBezierPath] = []
  private var activePath: UIBezierPath?
  private(set) var drawingEnabled = false

  var hasStrokeContent: Bool {
    !completedPaths.isEmpty || activePath != nil
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
    clipsToBounds = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func setDrawingEnabled(_ value: Bool) {
    drawingEnabled = value
    isUserInteractionEnabled = value
  }

  func clearAll() {
    completedPaths.removeAll()
    activePath = nil
    setNeedsDisplay()
  }

  @discardableResult
  func undoLastStroke() -> Bool {
    guard !completedPaths.isEmpty else { return false }
    completedPaths.removeLast()
    setNeedsDisplay()
    return true
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard drawingEnabled, let point = touches.first?.location(in: self) else { return }
    let path = UIBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = 3.5
    path.move(to: point)
    activePath = path
    setNeedsDisplay()
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard drawingEnabled, let point = touches.first?.location(in: self), let path = activePath
    else {
      return
    }
    path.addLine(to: point)
    setNeedsDisplay()
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard drawingEnabled, let path = activePath else { return }
    completedPaths.append(path)
    activePath = nil
    setNeedsDisplay()
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    touchesEnded(touches, with: event)
  }

  override func draw(_ rect: CGRect) {
    UIColor.white.withAlphaComponent(0.95).setStroke()
    for path in completedPaths {
      path.stroke()
    }
    activePath?.stroke()
  }
}

final class ChatImageEditViewController: UIViewController, UITextViewDelegate,
  UIGestureRecognizerDelegate
{
  private let messageId: String?
  private let mediaURL: String
  private let initialImage: UIImage?
  private let initialCaption: String
  private var captionText: String

  var onAction: ((ChatImageEditActionPayload) -> Void)?

  private let stageView = UIView()
  private let renderSurfaceView = UIView()
  private let imageView = UIImageView()
  private let textOverlayView = UIView()
  private let drawingView = ChatImageDrawingCanvasView()

  private let topContainer = UIView()
  private let backButton = UIButton(type: .system)
  private let titlePill = UIView()
  private let titleLabel = UILabel()
  private let menuButton = UIButton(type: .system)

  private let bottomContainer = UIView()
  private let captionBlurContainer = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let captionTextView = UITextView()
  private let captionPlaceholderLabel = UILabel()

  private let bottomToolbar = UIView()
  private let replyButton = UIButton(type: .system)
  private let toolsPill = UIView()
  private let toolsStack = UIStackView()
  private let editToggleButton = UIButton(type: .system)
  private let textButton = UIButton(type: .system)
  private let drawButton = UIButton(type: .system)
  private let cropButton = UIButton(type: .system)
  private let undoButton = UIButton(type: .system)
  private let sendButton = UIButton(type: .system)
  private let qualityButton = UIButton(type: .system)

  private let backgroundTapGesture = UITapGestureRecognizer()

  private var remoteImageTask: URLSessionDataTask?
  private var originalImage: UIImage?
  private var imageWasCropped = false
  private var hasVisualEdits = false
  private var keyboardHeight: CGFloat = 0
  private var uiHidden = false
  private var isToolMenuExpanded = false
  private var isHighQuality = false

  init(
    messageId: String?,
    mediaURL: String,
    initialImage: UIImage?,
    initialCaption: String?
  ) {
    self.messageId = messageId
    self.mediaURL = mediaURL
    self.initialImage = initialImage
    let normalizedCaption = initialCaption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.initialCaption = normalizedCaption
    self.captionText = normalizedCaption
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    remoteImageTask?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    stageView.backgroundColor = .clear
    stageView.clipsToBounds = true
    view.addSubview(stageView)

    renderSurfaceView.clipsToBounds = true
    renderSurfaceView.backgroundColor = .clear
    stageView.addSubview(renderSurfaceView)

    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true
    renderSurfaceView.addSubview(imageView)

    textOverlayView.clipsToBounds = true
    textOverlayView.backgroundColor = .clear
    renderSurfaceView.addSubview(textOverlayView)
    renderSurfaceView.addSubview(drawingView)

    topContainer.backgroundColor = .clear
    view.addSubview(topContainer)

    configureCircleButton(backButton, symbol: "chevron.backward", weight: .semibold, pointSize: 20)
    backButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    topContainer.addSubview(backButton)

    configureGlassPill(titlePill, cornerRadius: 16.0)
    topContainer.addSubview(titlePill)

    titleLabel.text = "Photo"
    titleLabel.textColor = .white
    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.textAlignment = .center
    titlePill.addSubview(titleLabel)

    configureCircleButton(menuButton, symbol: "ellipsis", weight: .regular, pointSize: 20)
    if #available(iOS 14.0, *) {
      menuButton.showsMenuAsPrimaryAction = true
    } else {
      menuButton.addTarget(self, action: #selector(handleLegacyMenuPressed), for: .touchUpInside)
    }
    topContainer.addSubview(menuButton)

    bottomContainer.backgroundColor = .clear
    view.addSubview(bottomContainer)

    captionBlurContainer.clipsToBounds = true
    captionBlurContainer.layer.cornerRadius = 20.0
    captionBlurContainer.layer.cornerCurve = .continuous
    bottomContainer.addSubview(captionBlurContainer)

    captionTextView.backgroundColor = .clear
    captionTextView.textColor = .white
    captionTextView.tintColor = .systemBlue
    captionTextView.font = .systemFont(ofSize: 16, weight: .regular)
    captionTextView.autocorrectionType = .yes
    captionTextView.autocapitalizationType = .sentences
    captionTextView.keyboardAppearance = .dark
    captionTextView.returnKeyType = .default
    captionTextView.isScrollEnabled = false
    captionTextView.textContainerInset = UIEdgeInsets(
      top: 10.0, left: 14.0, bottom: 10.0, right: 14.0)
    captionTextView.delegate = self
    captionTextView.text = captionText
    captionBlurContainer.contentView.addSubview(captionTextView)

    captionPlaceholderLabel.text = "Add a caption..."
    captionPlaceholderLabel.textColor = UIColor(white: 1.0, alpha: 0.5)
    captionPlaceholderLabel.font = .systemFont(ofSize: 16, weight: .regular)
    captionPlaceholderLabel.isUserInteractionEnabled = false
    captionBlurContainer.contentView.addSubview(captionPlaceholderLabel)

    bottomContainer.addSubview(bottomToolbar)

    configureCircleButton(
      replyButton, symbol: "arrowshape.turn.up.left", weight: .medium, pointSize: 20)
    replyButton.addTarget(self, action: #selector(handleReply), for: .touchUpInside)
    bottomToolbar.addSubview(replyButton)
    configureGlassPill(toolsPill, cornerRadius: 22.0)
    bottomToolbar.addSubview(toolsPill)

    toolsStack.axis = .horizontal
    toolsStack.distribution = .equalSpacing
    toolsStack.alignment = .center
    toolsStack.spacing = 0
    toolsPill.addSubview(toolsStack)

    configureToolButton(editToggleButton, symbol: "pencil")
    editToggleButton.addTarget(self, action: #selector(handleEditToggle), for: .touchUpInside)
    toolsStack.addArrangedSubview(editToggleButton)

    configureToolButton(textButton, symbol: "t.square")
    textButton.addTarget(self, action: #selector(handleText), for: .touchUpInside)
    toolsStack.addArrangedSubview(textButton)

    configureToolButton(drawButton, symbol: "pencil.tip")
    drawButton.addTarget(self, action: #selector(handleDraw), for: .touchUpInside)
    toolsStack.addArrangedSubview(drawButton)

    configureToolButton(cropButton, symbol: "crop")
    cropButton.addTarget(self, action: #selector(handleCrop), for: .touchUpInside)
    toolsStack.addArrangedSubview(cropButton)

    configureToolButton(undoButton, symbol: "arrow.uturn.backward")
    undoButton.addTarget(self, action: #selector(handleUndo), for: .touchUpInside)
    toolsStack.addArrangedSubview(undoButton)

    configureCircleButton(sendButton, symbol: "arrow.up", weight: .semibold, pointSize: 19)
    sendButton.backgroundColor = .systemBlue
    sendButton.layer.borderWidth = 0.0
    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
    bottomToolbar.addSubview(sendButton)

    qualityButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
    qualityButton.setTitle("SD", for: .normal)
    qualityButton.setTitleColor(.white, for: .normal)
    qualityButton.backgroundColor = UIColor(white: 0.14, alpha: 0.76)
    qualityButton.layer.cornerCurve = .continuous
    qualityButton.layer.borderWidth = 0.8
    qualityButton.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
    qualityButton.clipsToBounds = true
    qualityButton.addTarget(self, action: #selector(handleQualityToggle), for: .touchUpInside)
    bottomToolbar.addSubview(qualityButton)

    refreshCaptionInputState()
    loadImage()
    isToolMenuExpanded = true
    setToolMenuExpanded(false, animated: false)
    rebuildTopMenu()

    backgroundTapGesture.addTarget(self, action: #selector(handleBackgroundTap))
    backgroundTapGesture.cancelsTouchesInView = false
    backgroundTapGesture.delegate = self
    view.addGestureRecognizer(backgroundTapGesture)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillChangeFrame),
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )
  }

  private func configureGlassPill(_ target: UIView, cornerRadius: CGFloat) {
    target.backgroundColor = UIColor(white: 0.14, alpha: 0.76)
    target.layer.cornerCurve = .continuous
    target.layer.cornerRadius = cornerRadius
    target.layer.borderWidth = 0.8
    target.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
    target.clipsToBounds = true
  }

  private func configureCircleButton(
    _ button: UIButton,
    symbol: String,
    weight: UIImage.SymbolWeight,
    pointSize: CGFloat
  ) {
    let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
    button.tintColor = .white
    button.backgroundColor = UIColor(white: 0.14, alpha: 0.76)
    button.layer.cornerCurve = .continuous
    button.layer.borderWidth = 0.8
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
    button.clipsToBounds = true
  }

  private func configureToolButton(_ button: UIButton, symbol: String) {
    let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
    button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
    button.tintColor = .white
    button.backgroundColor = .clear
  }

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    guard
      let info = notification.userInfo,
      let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else {
      return
    }

    let localFrame = view.convert(endFrame, from: nil)
    let overlap = max(0.0, view.bounds.maxY - localFrame.minY)
    keyboardHeight = overlap

    UIView.animate(
      withDuration: 0.24, delay: 0.0, options: [.curveEaseInOut, .beginFromCurrentState]
    ) {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safe = view.safeAreaInsets

    topContainer.frame = CGRect(x: 0.0, y: safe.top + 6.0, width: view.bounds.width, height: 54.0)
    let topButtonSize: CGFloat = 44.0
    backButton.frame = CGRect(x: 16.0, y: 5.0, width: topButtonSize, height: topButtonSize)
    backButton.layer.cornerRadius = topButtonSize * 0.5

    menuButton.frame = CGRect(
      x: view.bounds.width - 16.0 - topButtonSize,
      y: 5.0,
      width: topButtonSize,
      height: topButtonSize
    )
    menuButton.layer.cornerRadius = topButtonSize * 0.5

    titleLabel.sizeToFit()
    let titleWidth = max(132.0, titleLabel.bounds.width + 34.0)
    titlePill.frame = CGRect(
      x: (view.bounds.width - titleWidth) * 0.5,
      y: 8.0,
      width: titleWidth,
      height: 38.0
    )
    titleLabel.frame = titlePill.bounds.insetBy(dx: 12.0, dy: 0.0)

    let maxCaptionWidth = view.bounds.width - 32.0
    let captionSize = captionTextView.sizeThatFits(
      CGSize(width: maxCaptionWidth, height: CGFloat.greatestFiniteMagnitude)
    )
    let captionHeight = max(44.0, min(120.0, captionSize.height))

    let toolbarHeight: CGFloat = 46.0
    let toolbarSpacing: CGFloat = 14.0
    let bottomInset = keyboardHeight > 0.0 ? (keyboardHeight + 6.0) : (safe.bottom + 10.0)

    let bottomContainerHeight = captionHeight + toolbarSpacing + toolbarHeight
    bottomContainer.frame = CGRect(
      x: 0.0,
      y: view.bounds.height - bottomInset - bottomContainerHeight,
      width: view.bounds.width,
      height: bottomContainerHeight
    )

    captionBlurContainer.frame = CGRect(
      x: 16.0, y: 0.0, width: maxCaptionWidth, height: captionHeight)
    captionTextView.frame = captionBlurContainer.bounds
    captionPlaceholderLabel.frame = CGRect(
      x: 18.0,
      y: 0.0,
      width: maxCaptionWidth - 36.0,
      height: captionHeight
    )

    bottomToolbar.frame = CGRect(
      x: 0.0,
      y: captionHeight + toolbarSpacing,
      width: view.bounds.width,
      height: toolbarHeight
    )

    let circleSize: CGFloat = 46.0
    replyButton.frame = CGRect(x: 16.0, y: 0.0, width: circleSize, height: circleSize)
    replyButton.layer.cornerRadius = circleSize * 0.5

    sendButton.frame = CGRect(
      x: view.bounds.width - 16.0 - circleSize,
      y: 0.0,
      width: circleSize,
      height: circleSize
    )
    sendButton.layer.cornerRadius = circleSize * 0.5

    let qualitySize: CGFloat = 36.0
    qualityButton.frame = CGRect(
      x: sendButton.frame.minX - 12.0 - qualitySize,
      y: (circleSize - qualitySize) * 0.5,
      width: qualitySize,
      height: qualitySize
    )
    qualityButton.layer.cornerRadius = qualitySize * 0.5

    let toolsWidth: CGFloat = isToolMenuExpanded ? 220.0 : 58.0
    toolsPill.frame = CGRect(
      x: (view.bounds.width - toolsWidth) * 0.5,
      y: 0.0,
      width: toolsWidth,
      height: circleSize
    )
    toolsStack.frame = toolsPill.bounds.insetBy(dx: 4.0, dy: 4.0)

    stageView.frame = view.bounds
    if let imageSize = imageView.image?.size, imageSize.width > 0.0, imageSize.height > 0.0 {
      let imageRect = fittingRect(container: view.bounds, mediaSize: imageSize)
      renderSurfaceView.frame = imageRect
    } else {
      renderSurfaceView.frame = view.bounds
    }
    imageView.frame = renderSurfaceView.bounds
    textOverlayView.frame = renderSurfaceView.bounds
    drawingView.frame = renderSurfaceView.bounds
  }

  private func loadImage() {
    if let initialImage {
      originalImage = initialImage
      imageView.image = initialImage
      view.setNeedsLayout()
      return
    }

    let trimmed = mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if let parsed = URL(string: trimmed), parsed.isFileURL {
      if let image = UIImage(contentsOfFile: parsed.path) {
        originalImage = image
        imageView.image = image
        view.setNeedsLayout()
      }
      return
    }

    if trimmed.hasPrefix("/") {
      if let image = UIImage(contentsOfFile: trimmed) {
        originalImage = image
        imageView.image = image
        view.setNeedsLayout()
      }
      return
    }

    guard let remoteURL = URL(string: trimmed) else { return }

    // Check disk cache first (shared with ChatListViewCells)
    if let diskImage = chatMediaDiskCacheLoad(trimmed) {
      originalImage = diskImage
      imageView.image = diskImage
      view.setNeedsLayout()
      return
    }

    remoteImageTask?.cancel()
    remoteImageTask = URLSession.shared.dataTask(with: remoteURL) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      // Persist to shared disk cache so it's available everywhere
      chatMediaDiskCacheSave(image, forKey: trimmed)
      DispatchQueue.main.async {
        self.originalImage = image
        self.imageView.image = image
        self.view.setNeedsLayout()
      }
    }
    remoteImageTask?.resume()
  }

  private func refreshCaptionInputState() {
    captionText = captionTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    captionPlaceholderLabel.isHidden = !captionText.isEmpty
  }

  private func fittingRect(container: CGRect, mediaSize: CGSize) -> CGRect {
    guard container.width > 1.0, container.height > 1.0 else { return .zero }
    let clampedSize = CGSize(width: max(1.0, mediaSize.width), height: max(1.0, mediaSize.height))
    let scale = min(container.width / clampedSize.width, container.height / clampedSize.height)
    let fitted = CGSize(width: clampedSize.width * scale, height: clampedSize.height * scale)
    return CGRect(
      x: container.minX + (container.width - fitted.width) * 0.5,
      y: container.minY + (container.height - fitted.height) * 0.5,
      width: fitted.width,
      height: fitted.height
    )
  }

  private func snapshotEditedImage() -> UIImage? {
    guard renderSurfaceView.bounds.width > 1.0, renderSurfaceView.bounds.height > 1.0 else {
      return imageView.image
    }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = max(UIScreen.main.scale, 2.0)
    let renderer = UIGraphicsImageRenderer(size: renderSurfaceView.bounds.size, format: format)
    return renderer.image { context in
      renderSurfaceView.layer.render(in: context.cgContext)
    }
  }

  private func writeJPEGToTemp(_ image: UIImage) -> URL? {
    let maxDimension: CGFloat = isHighQuality ? 2048.0 : 1080.0
    let scale = min(1.0, maxDimension / max(image.size.width, image.size.height))
    let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1.0
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    let resizedImage = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }

    let quality: CGFloat = isHighQuality ? 0.85 : 0.70
    guard let data = resizedImage.jpegData(compressionQuality: quality) else { return nil }
    let fileName = "chat-edit-\(UUID().uuidString).jpg"
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  @objc private func handleQualityToggle() {
    isHighQuality.toggle()
    qualityButton.setTitle(isHighQuality ? "HD" : "SD", for: .normal)
    qualityButton.backgroundColor = isHighQuality ? .systemBlue : UIColor(white: 0.14, alpha: 0.76)
    qualityButton.layer.borderColor =
      isHighQuality ? UIColor.clear.cgColor : UIColor.white.withAlphaComponent(0.14).cgColor
  }

  private func emit(_ eventType: ChatImageEditEventType) {
    refreshCaptionInputState()
    let editedImageURL: URL? = {
      if hasVisualEdits, let snapshot = snapshotEditedImage() {
        return writeJPEGToTemp(snapshot)
      } else if let cachedOriginal = originalImage {
        return writeJPEGToTemp(cachedOriginal)
      }
      return nil
    }()

    onAction?(
      ChatImageEditActionPayload(
        eventType: eventType,
        messageId: messageId,
        mediaURL: mediaURL,
        caption: captionText.isEmpty ? nil : captionText,
        editedImageURL: editedImageURL
      )
    )
    dismiss(animated: true)
  }

  private func updateHasVisualEditsState() {
    hasVisualEdits =
      imageWasCropped || drawingView.hasStrokeContent || !textOverlayView.subviews.isEmpty
    rebuildTopMenu()
  }

  private func resetVisualEdits() {
    drawingView.clearAll()
    for subview in textOverlayView.subviews {
      subview.removeFromSuperview()
    }
    if let originalImage {
      imageView.image = originalImage
      view.setNeedsLayout()
    }
    imageWasCropped = false
    drawingView.setDrawingEnabled(false)
    drawButton.tintColor = .white
    updateHasVisualEditsState()
  }

  private func setToolMenuExpanded(_ expanded: Bool, animated: Bool) {
    guard isToolMenuExpanded != expanded else { return }
    isToolMenuExpanded = expanded

    let secondaryButtons = [textButton, drawButton, cropButton, undoButton]
    if expanded {
      for button in secondaryButtons {
        button.isHidden = false
        button.alpha = 0.0
        button.transform = CGAffineTransform(translationX: 8.0, y: 0.0)
        button.isUserInteractionEnabled = true
      }
    }

    if !expanded {
      drawingView.setDrawingEnabled(false)
      drawButton.tintColor = .white
    }

    let applyState = {
      let toggleSymbol = expanded ? "xmark" : "pencil"
      let toggleConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
      self.editToggleButton.setImage(
        UIImage(systemName: toggleSymbol, withConfiguration: toggleConfig), for: .normal)
      self.editToggleButton.tintColor = expanded ? .systemBlue : .white

      for button in secondaryButtons {
        button.alpha = expanded ? 1.0 : 0.0
        button.transform = expanded ? .identity : CGAffineTransform(translationX: 8.0, y: 0.0)
      }

      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }

    let completion: (Bool) -> Void = { _ in
      if !expanded {
        for button in secondaryButtons {
          button.isHidden = true
          button.isUserInteractionEnabled = false
        }
      }
      self.rebuildTopMenu()
    }

    if animated {
      UIView.animate(
        withDuration: 0.22,
        delay: 0.0,
        options: [.curveEaseInOut, .beginFromCurrentState],
        animations: applyState,
        completion: completion
      )
    } else {
      applyState()
      completion(true)
    }
  }

  private func rebuildTopMenu() {
    guard #available(iOS 14.0, *) else { return }

    let editActionTitle = isToolMenuExpanded ? "Close Tools" : "Open Tools"
    let toggleAction = UIAction(
      title: editActionTitle,
      image: UIImage(systemName: "pencil")
    ) { [weak self] _ in
      guard let self else { return }
      self.setToolMenuExpanded(!self.isToolMenuExpanded, animated: true)
    }

    let resetAction = UIAction(
      title: "Reset Edits",
      image: UIImage(systemName: "arrow.uturn.backward"),
      attributes: hasVisualEdits ? [] : [.disabled]
    ) { [weak self] _ in
      self?.resetVisualEdits()
    }

    let replyAction = UIAction(
      title: "Reply",
      image: UIImage(systemName: "arrowshape.turn.up.left")
    ) { [weak self] _ in
      self?.emit(.reply)
    }

    let sendAction = UIAction(
      title: "Send",
      image: UIImage(systemName: "arrow.up")
    ) { [weak self] _ in
      self?.handleSend()
    }

    menuButton.menu = UIMenu(children: [toggleAction, resetAction, replyAction, sendAction])
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  @objc private func handleLegacyMenuPressed() {
    guard let presenter = presentingViewController ?? view.window?.rootViewController else {
      return
    }
    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    sheet.addAction(
      UIAlertAction(title: isToolMenuExpanded ? "Close Tools" : "Open Tools", style: .default) {
        [weak self] _ in
        guard let self else { return }
        self.setToolMenuExpanded(!self.isToolMenuExpanded, animated: true)
      })
    sheet.addAction(
      UIAlertAction(title: "Reset Edits", style: .default) { [weak self] _ in
        self?.resetVisualEdits()
      })
    sheet.addAction(
      UIAlertAction(title: "Reply", style: .default) { [weak self] _ in
        self?.emit(.reply)
      })
    sheet.addAction(
      UIAlertAction(title: "Send", style: .default) { [weak self] _ in
        self?.handleSend()
      })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    presenter.present(sheet, animated: true)
  }

  @objc private func handleText() {
    if !isToolMenuExpanded {
      setToolMenuExpanded(true, animated: true)
    }

    let alert = UIAlertController(title: "Add Text", message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "Text"
      field.autocapitalizationType = .sentences
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Add", style: .default) { [weak self] _ in
        guard let self else { return }
        let text =
          alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }

        let label = UILabel()
        label.text = text
        label.font = .boldSystemFont(ofSize: 26.0)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.38)
        label.layer.cornerRadius = 12.0
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.sizeToFit()
        label.frame = label.frame.insetBy(dx: -14.0, dy: -8.0)
        label.center = CGPoint(
          x: self.textOverlayView.bounds.midX, y: self.textOverlayView.bounds.midY)
        label.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(
          target: self, action: #selector(self.handleTextLabelPan(_:)))
        label.addGestureRecognizer(pan)
        self.textOverlayView.addSubview(label)
        self.updateHasVisualEditsState()
      })
    present(alert, animated: true)
  }

  @objc private func handleDraw() {
    if !isToolMenuExpanded {
      setToolMenuExpanded(true, animated: true)
    }

    let next = !drawingView.drawingEnabled
    drawingView.setDrawingEnabled(next)
    drawButton.tintColor = next ? .systemBlue : .white
    if next {
      hasVisualEdits = true
      rebuildTopMenu()
    }
  }

  @objc private func handleCrop() {
    if !isToolMenuExpanded {
      setToolMenuExpanded(true, animated: true)
    }

    guard let current = snapshotEditedImage() ?? imageView.image else { return }
    let side = min(current.size.width, current.size.height)
    let rect = CGRect(
      x: (current.size.width - side) * 0.5,
      y: (current.size.height - side) * 0.5,
      width: side,
      height: side
    ).integral
    guard let cgImage = current.cgImage?.cropping(to: rect) else { return }

    imageView.image = UIImage(
      cgImage: cgImage, scale: current.scale, orientation: current.imageOrientation)
    drawingView.clearAll()
    for subview in textOverlayView.subviews {
      subview.removeFromSuperview()
    }

    imageWasCropped = true
    drawingView.setDrawingEnabled(false)
    drawButton.tintColor = .white
    updateHasVisualEditsState()
    view.setNeedsLayout()
  }

  @objc private func handleUndo() {
    if drawingView.undoLastStroke() {
      updateHasVisualEditsState()
      return
    }

    if let lastText = textOverlayView.subviews.last {
      lastText.removeFromSuperview()
      updateHasVisualEditsState()
      return
    }

    if imageWasCropped, let originalImage {
      imageView.image = originalImage
      imageWasCropped = false
      updateHasVisualEditsState()
      view.setNeedsLayout()
    }
  }

  @objc private func handleReply() {
    emit(.reply)
  }

  @objc private func handleEditToggle() {
    setToolMenuExpanded(!isToolMenuExpanded, animated: true)
  }

  @objc private func handleSend() {
    refreshCaptionInputState()
    let didChangeCaption = captionText != initialCaption
    let eventType: ChatImageEditEventType =
      (messageId == nil) ? .sendNew : ((hasVisualEdits || didChangeCaption) ? .edit : .resend)
    emit(eventType)
  }

  @objc private func handleBackgroundTap() {
    if captionTextView.isFirstResponder {
      view.endEditing(true)
      return
    }

    uiHidden.toggle()
    UIView.animate(
      withDuration: 0.22, delay: 0.0, options: [.curveEaseInOut, .beginFromCurrentState]
    ) {
      self.topContainer.alpha = self.uiHidden ? 0.0 : 1.0
      self.bottomContainer.alpha = self.uiHidden ? 0.0 : 1.0
    }
  }

  @objc private func handleTextLabelPan(_ gesture: UIPanGestureRecognizer) {
    guard let label = gesture.view else { return }
    let translation = gesture.translation(in: textOverlayView)
    label.center = CGPoint(x: label.center.x + translation.x, y: label.center.y + translation.y)
    gesture.setTranslation(.zero, in: textOverlayView)
    updateHasVisualEditsState()
  }

  func textViewDidChange(_ textView: UITextView) {
    guard textView === captionTextView else { return }
    refreshCaptionInputState()
    UIView.animate(
      withDuration: 0.10, delay: 0.0, options: [.curveEaseInOut, .beginFromCurrentState]
    ) {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    guard gestureRecognizer === backgroundTapGesture else { return true }
    guard let touchedView = touch.view else { return true }
    if touchedView.isDescendant(of: topContainer) || touchedView.isDescendant(of: bottomContainer) {
      return false
    }
    return true
  }
}
