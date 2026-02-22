import CoreLocation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

final class ChatAttachmentMenuController: UIViewController {
  var onSelectImage: ((String) -> Void)?
  var onSelectFile: ((String, String) -> Void)?
  var onSelectLocation: ((Double, Double) -> Void)?

  var sourceButtonFrameInWindow: CGRect?
  weak var sourceButtonView: UIView?

  private let appearance: ChatListAppearance

  private let backdropView = UIVisualEffectView(effect: nil)
  private let dimView = UIView()
  private let panelView = UIView()
  private let panelGlass = UIVisualEffectView(effect: nil)
  private let headerLabel = UILabel()
  private let closeButton = UIButton(type: .system)
  private let contentView = UIView()
  private let tabBar = UISegmentedControl(items: ["Gallery", "File", "Location", "Contact"])
  private let inputField = UITextField()

  // Gallery dashboard (AttachmentMenu.tsx inspired)
  private let galleryDashboard = UIView()
  private let cameraHeroButton = UIButton(type: .custom)
  private let galleryTileButton = UIButton(type: .custom)
  private let fileTileButton = UIButton(type: .custom)
  private let locationTileButton = UIButton(type: .custom)
  private let contactTileButton = UIButton(type: .custom)
  private let quickActionBottomRow = UIStackView()
  private let pickLibraryButton = UIButton(type: .system)
  private let pickCameraButton = UIButton(type: .system)

  // Simple alternate tab views
  private let fileView = UIView()
  private let locationView = UIView()
  private let contactView = UIView()
  private let fileActionButton = UIButton(type: .system)
  private let locationActionButton = UIButton(type: .system)
  private let contactPlaceholderLabel = UILabel()

  private var hasAnimatedIn = false
  private var isDismissingMenu = false
  private var activeTabIndex = 0
  private let morphTransition = GlassMorphTransition()

  init(appearance: ChatListAppearance) {
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    setupBackdrop()
    setupPanel()
    setupContent()
    configureMorphTransition()
    setActiveTab(0, animated: false)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutChrome()
    if !hasAnimatedIn {
      prepareInitialMorphState()
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !hasAnimatedIn else { return }
    hasAnimatedIn = true
    animateInFromSource()
  }

  private func setupBackdrop() {
    backdropView.frame = view.bounds
    backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .clear)
      effect.isInteractive = true
      backdropView.effect = effect
    } else {
      backdropView.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    }
    backdropView.alpha = 0
    view.addSubview(backdropView)

    dimView.frame = view.bounds
    dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    dimView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
    dimView.alpha = 0
    view.addSubview(dimView)

    let tap = UITapGestureRecognizer(target: self, action: #selector(backdropTapped))
    dimView.addGestureRecognizer(tap)
  }

  private func configureMorphTransition() {
    morphTransition.hostView = view
    morphTransition.sourceView = sourceButtonView
    morphTransition.targetView = panelView
    morphTransition.targetCornerRadius = 28
    morphTransition.backdropViews = [backdropView, dimView]
    morphTransition.contentViews = [headerLabel, closeButton, inputField, contentView, tabBar]
  }

  private func setupPanel() {
    panelView.backgroundColor = .clear
    panelView.clipsToBounds = false
    panelView.layer.cornerCurve = .continuous
    view.addSubview(panelView)

    panelGlass.isUserInteractionEnabled = false
    panelGlass.clipsToBounds = true
    panelGlass.layer.cornerCurve = .continuous
    panelView.addSubview(panelGlass)

    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      panelGlass.effect = effect
      panelGlass.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.05)
    } else {
      panelGlass.effect = UIBlurEffect(style: .systemMaterialDark)
      panelGlass.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.03)
    }
    panelView.layer.borderWidth = 0.6
    panelView.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor

    headerLabel.text = "Attachments"
    headerLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    headerLabel.textColor = UIColor(white: 0.98, alpha: 0.95)
    panelView.addSubview(headerLabel)

    let closeCfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: closeCfg), for: .normal)
    closeButton.tintColor = UIColor(white: 0.96, alpha: 0.9)
    closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    closeButton.layer.cornerRadius = 16
    closeButton.layer.cornerCurve = .continuous
    closeButton.layer.borderWidth = 0.35
    closeButton.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    panelView.addSubview(closeButton)

    inputField.borderStyle = .none
    inputField.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    inputField.textColor = UIColor.white.withAlphaComponent(0.92)
    inputField.attributedPlaceholder = NSAttributedString(
      string: "Search or add caption",
      attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.45)]
    )
    inputField.layer.cornerRadius = 14
    inputField.layer.cornerCurve = .continuous
    inputField.clearButtonMode = .whileEditing
    inputField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    inputField.leftViewMode = .always
    panelView.addSubview(inputField)

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
    panelView.addSubview(tabBar)

    contentView.backgroundColor = .clear
    panelView.addSubview(contentView)
  }

  private func setupContent() {
    setupGalleryDashboard()
    setupFileView()
    setupLocationView()
    setupContactView()

    [galleryDashboard, fileView, locationView, contactView].forEach {
      $0.backgroundColor = .clear
      contentView.addSubview($0)
    }
  }

  private func setupGalleryDashboard() {
    configureCard(cameraHeroButton, title: "Camera", subtitle: "16:9 Preview", symbol: "camera.fill")
    configureCard(galleryTileButton, title: "Gallery", subtitle: "Photos & videos", symbol: "photo.on.rectangle")
    configureCard(fileTileButton, title: "File", subtitle: "Documents", symbol: "doc.fill")
    configureCard(locationTileButton, title: "Location", subtitle: "Send pin", symbol: "location.fill")
    configureCard(contactTileButton, title: "Contact", subtitle: "Coming soon", symbol: "person.crop.circle")

    cameraHeroButton.contentHorizontalAlignment = .left
    cameraHeroButton.contentVerticalAlignment = .top
    cameraHeroButton.backgroundColor = UIColor.white.withAlphaComponent(0.03)

    let cameraPreviewShade = CAGradientLayer()
    cameraPreviewShade.colors = [
      UIColor(white: 0.03, alpha: 0.92).cgColor,
      UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 0.75).cgColor,
      UIColor(white: 0.02, alpha: 0.96).cgColor,
    ]
    cameraPreviewShade.startPoint = CGPoint(x: 0.0, y: 0.0)
    cameraPreviewShade.endPoint = CGPoint(x: 1.0, y: 1.0)
    cameraPreviewShade.name = "cameraPreviewShade"
    cameraHeroButton.layer.insertSublayer(cameraPreviewShade, at: 0)

    [cameraHeroButton, galleryTileButton, fileTileButton, locationTileButton, contactTileButton]
      .forEach { galleryDashboard.addSubview($0) }

    cameraHeroButton.addTarget(self, action: #selector(openCameraFromHero), for: .touchUpInside)
    galleryTileButton.addTarget(self, action: #selector(openLibraryPicker), for: .touchUpInside)
    fileTileButton.addTarget(self, action: #selector(openFilePickerFromTile), for: .touchUpInside)
    locationTileButton.addTarget(self, action: #selector(openLocationFromTile), for: .touchUpInside)
    contactTileButton.addTarget(self, action: #selector(showContactPlaceholderToast), for: .touchUpInside)

    quickActionBottomRow.axis = .horizontal
    quickActionBottomRow.alignment = .fill
    quickActionBottomRow.distribution = .fillEqually
    quickActionBottomRow.spacing = 10
    galleryDashboard.addSubview(quickActionBottomRow)

    configureFooterPillButton(pickLibraryButton, title: "Open Gallery", symbol: "photo")
    configureFooterPillButton(pickCameraButton, title: "Open Camera", symbol: "camera")
    pickLibraryButton.addTarget(self, action: #selector(openLibraryPicker), for: .touchUpInside)
    pickCameraButton.addTarget(self, action: #selector(openCameraFromHero), for: .touchUpInside)
    quickActionBottomRow.addArrangedSubview(pickLibraryButton)
    quickActionBottomRow.addArrangedSubview(pickCameraButton)
  }

  private func setupFileView() {
    configureCenterActionView(
      fileView,
      title: "Share a File",
      subtitle: "Pick any document from Files",
      actionButton: fileActionButton,
      actionTitle: "Choose File",
      actionSymbol: "doc.badge.plus"
    )
    fileActionButton.addTarget(self, action: #selector(openFilePickerFromTile), for: .touchUpInside)
  }

  private func setupLocationView() {
    configureCenterActionView(
      locationView,
      title: "Share Location",
      subtitle: "Send your current location quickly",
      actionButton: locationActionButton,
      actionTitle: "Use Current Location",
      actionSymbol: "location.circle"
    )
    locationActionButton.addTarget(self, action: #selector(openLocationFromTile), for: .touchUpInside)
  }

  private func setupContactView() {
    contactPlaceholderLabel.text = "Contact sharing coming soon"
    contactPlaceholderLabel.font = .systemFont(ofSize: 14, weight: .medium)
    contactPlaceholderLabel.textColor = UIColor(white: 0.92, alpha: 0.75)
    contactPlaceholderLabel.textAlignment = .center
    contactPlaceholderLabel.numberOfLines = 0
    contactView.addSubview(contactPlaceholderLabel)
  }

  private func layoutChrome() {
    let safe = view.safeAreaInsets
    let w = view.bounds.width
    let h = view.bounds.height
    let sideInset: CGFloat = 12
    let bottomInset: CGFloat = max(safe.bottom, 8) + 14
    let panelWidth = w - (sideInset * 2)
    let panelHeight = min(max(420, h * 0.58), h - safe.top - bottomInset - 20)
    let panelFrame = CGRect(
      x: sideInset,
      y: h - bottomInset - panelHeight,
      width: panelWidth,
      height: panelHeight
    ).integral

    if hasAnimatedIn && !isDismissingMenu {
      panelView.frame = panelFrame
    } else if !hasAnimatedIn {
      panelView.frame = panelFrame
    }
    panelGlass.frame = panelView.bounds
    panelGlass.layer.cornerRadius = panelView.layer.cornerRadius

    let headerInset: CGFloat = 16
    headerLabel.frame = CGRect(x: headerInset, y: 14, width: panelWidth - 80, height: 24)
    closeButton.frame = CGRect(x: panelWidth - 16 - 32, y: 10, width: 32, height: 32)
    inputField.frame = CGRect(x: 16, y: headerLabel.frame.maxY + 10, width: panelWidth - 32, height: 36)

    let tabH: CGFloat = 34
    let tabY = panelFrame.height - tabH - 14
    tabBar.frame = CGRect(x: 16, y: tabY, width: panelWidth - 32, height: tabH)

    let contentBottom = tabBar.frame.minY - 10
    contentView.frame = CGRect(
      x: 12,
      y: inputField.frame.maxY + 10,
      width: panelWidth - 24,
      height: max(1, contentBottom - (inputField.frame.maxY + 10))
    )

    [galleryDashboard, fileView, locationView, contactView].forEach { $0.frame = contentView.bounds }
    layoutGalleryDashboard()
    layoutCenterTabViews()
  }

  private func layoutGalleryDashboard() {
    let bounds = galleryDashboard.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }

    let gap: CGFloat = 10
    let footerH: CGFloat = 42
    let dashboardH = max(1, bounds.height - footerH - gap)

    let rightColW = floor((bounds.width - gap) * 0.36)
    let leftW = bounds.width - gap - rightColW
    let cameraH = min(floor(leftW * 9.0 / 16.0), dashboardH * 0.62)
    let bottomY = cameraH + gap
    let bottomH = max(1, dashboardH - bottomY)

    cameraHeroButton.frame = CGRect(x: 0, y: 0, width: leftW, height: cameraH).integral
    if let shade = cameraHeroButton.layer.sublayers?.first(where: { $0.name == "cameraPreviewShade" }) as? CAGradientLayer {
      shade.frame = cameraHeroButton.bounds
      shade.cornerRadius = cameraHeroButton.layer.cornerRadius
    }

    let rightTileH = floor((dashboardH - gap) * 0.5)
    galleryTileButton.frame = CGRect(x: leftW + gap, y: 0, width: rightColW, height: rightTileH).integral
    fileTileButton.frame = CGRect(
      x: leftW + gap, y: rightTileH + gap, width: rightColW, height: dashboardH - rightTileH - gap
    ).integral

    let bottomTileGap: CGFloat = 10
    let bottomTileW = floor((leftW - bottomTileGap) * 0.5)
    locationTileButton.frame = CGRect(x: 0, y: bottomY, width: bottomTileW, height: bottomH).integral
    contactTileButton.frame = CGRect(
      x: bottomTileW + bottomTileGap, y: bottomY, width: leftW - bottomTileW - bottomTileGap, height: bottomH
    ).integral

    quickActionBottomRow.frame = CGRect(x: 0, y: bounds.height - footerH, width: bounds.width, height: footerH)
  }

  private func layoutCenterTabViews() {
    let insetBounds = contentView.bounds.insetBy(dx: 12, dy: 12)
    [fileView, locationView, contactView].forEach { view in
      guard view.subviews.count >= 3 else { return }
      let title = view.subviews[0]
      let subtitle = view.subviews[1]
      let button = view.subviews[2]
      title.frame = CGRect(x: 0, y: max(10, insetBounds.height * 0.20), width: insetBounds.width, height: 28)
      subtitle.frame = CGRect(x: 10, y: title.frame.maxY + 6, width: insetBounds.width - 20, height: 40)
      button.frame = CGRect(
        x: max(16, (insetBounds.width - 220) * 0.5),
        y: subtitle.frame.maxY + 16,
        width: min(220, insetBounds.width - 32),
        height: 42
      )
      title.center.x = view.bounds.midX
      subtitle.center.x = view.bounds.midX
      button.center.x = view.bounds.midX
    }
    contactPlaceholderLabel.frame = contactView.bounds.insetBy(dx: 20, dy: 24)
  }

  private func configureCard(
    _ button: UIButton,
    title: String,
    subtitle: String,
    symbol: String
  ) {
    button.clipsToBounds = true
    button.layer.cornerRadius = 16
    button.layer.cornerCurve = .continuous
    button.layer.borderWidth = 0.45
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
    button.backgroundColor = UIColor.white.withAlphaComponent(0.05)

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: symbol)
    config.imagePlacement = .top
    config.imagePadding = 8
    config.baseForegroundColor = UIColor.white.withAlphaComponent(0.96)
    config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    config.attributedTitle = AttributedString(
      title,
      attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)])
    )
    config.attributedSubtitle = AttributedString(
      subtitle,
      attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 11, weight: .regular)])
    )
    button.configuration = config
  }

  private func configureFooterPillButton(_ button: UIButton, title: String, symbol: String) {
    button.layer.cornerRadius = 14
    button.layer.cornerCurve = .continuous
    button.layer.borderWidth = 0.35
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
    button.backgroundColor = UIColor.white.withAlphaComponent(0.07)
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: symbol)
    config.imagePlacement = .leading
    config.imagePadding = 6
    config.baseForegroundColor = UIColor.white.withAlphaComponent(0.95)
    config.title = title
    config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    button.configuration = config
  }

  private func configureCenterActionView(
    _ host: UIView,
    title: String,
    subtitle: String,
    actionButton: UIButton,
    actionTitle: String,
    actionSymbol: String
  ) {
    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    titleLabel.textColor = UIColor.white.withAlphaComponent(0.96)
    titleLabel.textAlignment = .center
    host.addSubview(titleLabel)

    let subtitleLabel = UILabel()
    subtitleLabel.text = subtitle
    subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
    subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
    subtitleLabel.textAlignment = .center
    subtitleLabel.numberOfLines = 2
    host.addSubview(subtitleLabel)

    configureFooterPillButton(actionButton, title: actionTitle, symbol: actionSymbol)
    host.addSubview(actionButton)
  }

  private func setActiveTab(_ index: Int, animated: Bool) {
    activeTabIndex = max(0, min(index, 3))
    tabBar.selectedSegmentIndex = activeTabIndex
    galleryDashboard.isHidden = activeTabIndex != 0
    fileView.isHidden = activeTabIndex != 1
    locationView.isHidden = activeTabIndex != 2
    contactView.isHidden = activeTabIndex != 3

    let placeholder: String
    switch activeTabIndex {
    case 0: placeholder = "Search or add caption"
    case 1: placeholder = "File name (optional)"
    case 2: placeholder = "Location note (optional)"
    case 3: placeholder = "Search contacts"
    default: placeholder = "Search"
    }
    inputField.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.45)]
    )

    guard animated else { return }
    let targetView: UIView = [galleryDashboard, fileView, locationView, contactView][activeTabIndex]
    targetView.alpha = 0.0
    UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      targetView.alpha = 1.0
    }
  }

  private func prepareInitialMorphState() {
    panelView.layer.cornerRadius = 28
    morphTransition.hostView = view
    morphTransition.sourceView = sourceButtonView
    morphTransition.sourceFrameInHost = resolvedSourceFrameInLocalCoords()
    morphTransition.targetView = panelView
    morphTransition.targetCornerRadius = 28
    morphTransition.suppressTargetForInitialState()
  }

  private func animateInFromSource() {
    panelView.layer.removeAllAnimations()
    panelView.layer.cornerRadius = 28
    morphTransition.animatePresent()
  }

  private func animateOutAndDismiss() {
    guard !isDismissingMenu else { return }
    isDismissingMenu = true

    morphTransition.hostView = view
    morphTransition.sourceView = sourceButtonView
    morphTransition.sourceFrameInHost = resolvedSourceFrameInLocalCoords()
    morphTransition.targetView = panelView
    morphTransition.targetCornerRadius = 28
    morphTransition.animateDismiss(fallbackOffsetY: 24) {
      self.dismiss(animated: false)
    }
  }

  private func targetPanelFrame() -> CGRect {
    let safe = view.safeAreaInsets
    let w = view.bounds.width
    let h = view.bounds.height
    let sideInset: CGFloat = 12
    let bottomInset: CGFloat = max(safe.bottom, 8) + 14
    let panelWidth = w - (sideInset * 2)
    let panelHeight = min(max(420, h * 0.58), h - safe.top - bottomInset - 20)
    return CGRect(
      x: sideInset,
      y: h - bottomInset - panelHeight,
      width: panelWidth,
      height: panelHeight
    ).integral
  }

  private func resolvedSourceFrameInLocalCoords() -> CGRect? {
    guard let sourceButtonFrameInWindow else { return nil }
    if let window = view.window {
      return window.convert(sourceButtonFrameInWindow, to: view)
    }
    return sourceButtonFrameInWindow
  }

  private func finishAndDismiss(_ action: () -> Void) {
    action()
    animateOutAndDismiss()
  }

  @objc private func backdropTapped() {
    animateOutAndDismiss()
  }

  @objc private func closeTapped() {
    animateOutAndDismiss()
  }

  @objc private func tabChanged() {
    setActiveTab(tabBar.selectedSegmentIndex, animated: true)
  }

  @objc private func openLibraryPicker() {
    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = 10
    config.filter = .any(of: [.images, .videos])
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  @objc private func openCameraFromHero() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      openLibraryPicker()
      return
    }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = self
    picker.mediaTypes = [UTType.image.identifier]
    picker.cameraCaptureMode = .photo
    picker.videoQuality = .typeMedium
    present(picker, animated: true)
  }

  @objc private func openFilePickerFromTile() {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  @objc private func openLocationFromTile() {
    inputField.resignFirstResponder()
    ChatAttachmentMenuLocationManager.shared.requestOnce { [weak self] coord in
      DispatchQueue.main.async {
        guard let self else { return }
        self.finishAndDismiss {
          self.onSelectLocation?(coord.latitude, coord.longitude)
        }
      }
    }
  }

  @objc private func showContactPlaceholderToast() {
    setActiveTab(3, animated: true)
  }
}

extension ChatAttachmentMenuController: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let first = results.first else { return }

    let provider = first.itemProvider
    let typeId = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
      ? UTType.image.identifier
      : (provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie.identifier : UTType.image.identifier)

    provider.loadFileRepresentation(forTypeIdentifier: typeId) { [weak self] url, _ in
      guard let self, let url else { return }
      DispatchQueue.main.async {
        self.finishAndDismiss {
          self.onSelectImage?(url.absoluteString)
        }
      }
    }
  }
}

extension ChatAttachmentMenuController: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    finishAndDismiss {
      self.onSelectFile?(url.absoluteString, url.lastPathComponent)
    }
  }
}

extension ChatAttachmentMenuController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    var mediaURL = (info[.imageURL] as? URL) ?? (info[.mediaURL] as? URL)
    if mediaURL == nil, let image = info[.originalImage] as? UIImage,
      let data = image.jpegData(compressionQuality: 0.92)
    {
      let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("camera-\(UUID().uuidString)")
        .appendingPathExtension("jpg")
      do {
        try data.write(to: tempURL, options: .atomic)
        mediaURL = tempURL
      } catch {
        mediaURL = nil
      }
    }
    picker.dismiss(animated: true)
    guard let mediaURL else { return }
    finishAndDismiss {
      self.onSelectImage?(mediaURL.absoluteString)
    }
  }
}

private final class ChatAttachmentMenuLocationManager: NSObject, CLLocationManagerDelegate {
  static let shared = ChatAttachmentMenuLocationManager()
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
