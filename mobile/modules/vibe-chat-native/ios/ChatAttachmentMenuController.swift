import AVFoundation
import CoreLocation
import Photos
import UIKit
import UniformTypeIdentifiers

final class ChatAttachmentMenuController: UIViewController {
  var onSelectImage: ((String, String?) -> Void)?
  var onSelectFile: ((String, String) -> Void)?
  var onSelectLocation: ((Double, Double) -> Void)?

  // Kept for API compatibility with existing call sites.
  var sourceButtonFrameInWindow: CGRect?
  weak var sourceButtonView: UIView?

  private let appearance: ChatListAppearance

  private let headerGlass = UIVisualEffectView(effect: nil)
  private let sectionDropdownButton = UIButton(type: .system)
  private let filterDropdownButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)
  private let contentView = UIView()

  private let galleryDashboard = UIView()
  private let galleryLayout = UICollectionViewFlowLayout()
  private lazy var galleryCollectionView = UICollectionView(
    frame: .zero,
    collectionViewLayout: galleryLayout
  )
  private let galleryEmptyLabel = UILabel()

  private let locationView = UIView()
  private let locationActionButton = UIButton(type: .system)

  private let photoManager = PHCachingImageManager()
  private var allGalleryAssets: [PHAsset] = []
  private var galleryAssets: [PHAsset] = []
  private var galleryThumbSize: CGSize = .zero
  private var galleryBaseItem: CGFloat = 0
  private var isSelectingAsset = false

  private var cameraPreviewAvailable = false
  private weak var cameraPreviewHostView: UIView?
  private let cameraSession = AVCaptureSession()
  private let cameraPreviewLayer = AVCaptureVideoPreviewLayer()
  private let cameraSessionQueue = DispatchQueue(
    label: "chat.attachment.menu.camera.session",
    qos: .userInitiated
  )
  private var isCameraConfigured = false

  private var activeSection: MenuSection = .gallery
  private var activeGalleryFilter: GalleryFilter = .recent

  private enum MenuSection: String {
    case gallery = "Gallery"
    case location = "Location"
  }

  private enum GalleryFilter: String {
    case recent = "Recent"
    case videos = "Videos"
    case photos = "Photos"
  }

  init(appearance: ChatListAppearance) {
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    cameraPreviewLayer.videoGravity = .resizeAspectFill
    view.backgroundColor = UIColor.systemBackground

    configureNativeSheetPresentation()
    setupHeader()
    setupContent()
    setupMenus()

    setActiveSection(.gallery, animated: false)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutChrome()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startCameraPreview()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopCameraPreview()
  }

  deinit {
    stopCameraPreview()
  }

  private func configureNativeSheetPresentation() {
    guard let sheet = sheetPresentationController else { return }
    sheet.detents = [.medium(), .large()]
    sheet.selectedDetentIdentifier = .medium
    sheet.prefersGrabberVisible = true
    sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    sheet.prefersEdgeAttachedInCompactHeight = true
    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
    sheet.preferredCornerRadius = 28
  }

  private func setupHeader() {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = true
      headerGlass.effect = effect
      headerGlass.cornerConfiguration = .capsule()
    } else {
      headerGlass.effect = UIBlurEffect(style: .systemMaterial)
      headerGlass.layer.cornerRadius = 20
      headerGlass.layer.cornerCurve = .continuous
      headerGlass.clipsToBounds = true
    }
    view.addSubview(headerGlass)

    sectionDropdownButton.showsMenuAsPrimaryAction = true
    filterDropdownButton.showsMenuAsPrimaryAction = true

    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    headerGlass.contentView.addSubview(sectionDropdownButton)
    headerGlass.contentView.addSubview(filterDropdownButton)
    headerGlass.contentView.addSubview(closeButton)

    styleCloseButton()
  }

  private func setupMenus() {
    updateSectionDropdownMenu()
    updateFilterDropdownMenu()
  }

  private func updateSectionDropdownMenu() {
    let galleryAction = UIAction(
      title: MenuSection.gallery.rawValue,
      image: UIImage(systemName: "photo.on.rectangle.angled"),
      state: activeSection == .gallery ? .on : .off
    ) { [weak self] _ in
      self?.setActiveSection(.gallery, animated: true)
    }

    let locationAction = UIAction(
      title: MenuSection.location.rawValue,
      image: UIImage(systemName: "location.circle"),
      state: activeSection == .location ? .on : .off
    ) { [weak self] _ in
      self?.setActiveSection(.location, animated: true)
    }

    let fileAction = UIAction(
      title: "Choose File…",
      image: UIImage(systemName: "doc")
    ) { [weak self] _ in
      self?.openFilePicker()
    }

    sectionDropdownButton.menu = UIMenu(children: [galleryAction, locationAction, fileAction])
    styleDropdownButton(
      sectionDropdownButton,
      title: activeSection.rawValue,
      symbol: "chevron.up.chevron.down",
      prominent: true
    )
  }

  private func updateFilterDropdownMenu() {
    let recentAction = UIAction(
      title: GalleryFilter.recent.rawValue,
      image: UIImage(systemName: "clock"),
      state: activeGalleryFilter == .recent ? .on : .off
    ) { [weak self] _ in
      self?.setGalleryFilter(.recent, animated: true)
    }

    let videosAction = UIAction(
      title: GalleryFilter.videos.rawValue,
      image: UIImage(systemName: "video"),
      state: activeGalleryFilter == .videos ? .on : .off
    ) { [weak self] _ in
      self?.setGalleryFilter(.videos, animated: true)
    }

    let photosAction = UIAction(
      title: GalleryFilter.photos.rawValue,
      image: UIImage(systemName: "photo"),
      state: activeGalleryFilter == .photos ? .on : .off
    ) { [weak self] _ in
      self?.setGalleryFilter(.photos, animated: true)
    }

    filterDropdownButton.menu = UIMenu(children: [recentAction, videosAction, photosAction])
    styleDropdownButton(
      filterDropdownButton,
      title: activeGalleryFilter.rawValue,
      symbol: "line.3.horizontal.decrease.circle",
      prominent: false
    )
  }

  private func styleDropdownButton(
    _ button: UIButton,
    title: String,
    symbol: String,
    prominent: Bool
  ) {
    if #available(iOS 26.0, *) {
      var config =
        prominent
        ? UIButton.Configuration.prominentGlass()
        : UIButton.Configuration.glass()
      config.cornerStyle = .capsule
      config.title = title
      config.image = UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
      )
      config.imagePlacement = .trailing
      config.imagePadding = 6
      config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
      button.configuration = config
      return
    }

    var config = UIButton.Configuration.filled()
    config.title = title
    config.image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    )
    config.imagePlacement = .trailing
    config.imagePadding = 6
    config.baseBackgroundColor = UIColor.secondarySystemFill
    config.baseForegroundColor = UIColor.label
    config.cornerStyle = .capsule
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    button.configuration = config
  }

  private func styleCloseButton() {
    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.cornerStyle = .capsule
      config.image = UIImage(
        systemName: "xmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
      )
      config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
      closeButton.configuration = config
      return
    }

    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.image = UIImage(
      systemName: "xmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    )
    config.baseBackgroundColor = UIColor.secondarySystemFill
    config.baseForegroundColor = UIColor.label
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    closeButton.configuration = config
  }

  private func setupContent() {
    contentView.backgroundColor = .clear
    view.addSubview(contentView)

    setupGalleryDashboard()
    setupLocationView()

    [galleryDashboard, locationView].forEach {
      $0.backgroundColor = .clear
      contentView.addSubview($0)
    }
  }

  private func setupGalleryDashboard() {
    galleryCollectionView.backgroundColor = .clear
    galleryCollectionView.alwaysBounceVertical = true
    galleryCollectionView.showsVerticalScrollIndicator = true
    galleryCollectionView.contentInsetAdjustmentBehavior = .always
    galleryCollectionView.dataSource = self
    galleryCollectionView.delegate = self
    galleryCollectionView.register(
      ChatAttachmentAssetCell.self,
      forCellWithReuseIdentifier: ChatAttachmentAssetCell.reuseIdentifier
    )
    galleryCollectionView.register(
      ChatAttachmentCameraCell.self,
      forCellWithReuseIdentifier: ChatAttachmentCameraCell.reuseIdentifier
    )
    galleryDashboard.addSubview(galleryCollectionView)

    galleryEmptyLabel.text = "No photos found"
    galleryEmptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
    galleryEmptyLabel.textColor = UIColor.secondaryLabel
    galleryEmptyLabel.textAlignment = .center
    galleryEmptyLabel.numberOfLines = 0
    galleryDashboard.addSubview(galleryEmptyLabel)
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
    locationActionButton.addTarget(
      self, action: #selector(openLocationFromTile), for: .touchUpInside)
  }

  private func layoutChrome() {
    let safe = view.safeAreaInsets
    let w = view.bounds.width
    let h = view.bounds.height

    let headerX: CGFloat = 12
    let headerY = safe.top + 8
    let headerH: CGFloat = 42
    let headerW = max(1, w - (headerX * 2))
    headerGlass.frame = CGRect(x: headerX, y: headerY, width: headerW, height: headerH)

    let closeSize: CGFloat = 30
    closeButton.frame = CGRect(
      x: headerW - closeSize - 6, y: 6, width: closeSize, height: closeSize)

    let filterW: CGFloat = filterDropdownButton.isHidden ? 0 : min(122, headerW * 0.30)
    let sectionW = max(96, min(160, headerW - closeSize - filterW - 30))
    sectionDropdownButton.frame = CGRect(x: 8, y: 4, width: sectionW, height: 34)

    if filterDropdownButton.isHidden {
      filterDropdownButton.frame = .zero
    } else {
      filterDropdownButton.frame = CGRect(
        x: closeButton.frame.minX - filterW - 8,
        y: 4,
        width: filterW,
        height: 34
      )
    }

    let contentTop = headerGlass.frame.maxY + 8
    let contentBottom = h - safe.bottom
    contentView.frame = CGRect(
      x: 0, y: contentTop, width: w, height: max(1, contentBottom - contentTop))

    [galleryDashboard, locationView].forEach { $0.frame = contentView.bounds }
    layoutGalleryDashboard()
    layoutCenterTabViews()
    updateCameraPreviewFrame()
  }

  private func layoutGalleryDashboard() {
    let bounds = galleryDashboard.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }

    galleryCollectionView.frame = bounds
    galleryEmptyLabel.frame = bounds.insetBy(dx: 20, dy: 20)

    let spacing: CGFloat = 2
    let columns: CGFloat = bounds.width > 540 ? 5 : 3
    let item = floor((bounds.width - ((columns - 1) * spacing)) / columns)
    galleryBaseItem = item

    galleryLayout.scrollDirection = .vertical
    galleryLayout.minimumLineSpacing = spacing
    galleryLayout.minimumInteritemSpacing = spacing
    galleryLayout.itemSize = CGSize(width: item, height: item)
    galleryLayout.invalidateLayout()

    let scale = view.window?.screen.scale ?? UIScreen.main.scale
    galleryThumbSize = CGSize(width: item * scale, height: item * scale)
  }

  private func layoutCenterTabViews() {
    let insetBounds = contentView.bounds.insetBy(dx: 12, dy: 12)
    [locationView].forEach { view in
      guard view.subviews.count >= 3 else { return }
      let title = view.subviews[0]
      let subtitle = view.subviews[1]
      let button = view.subviews[2]

      title.frame = CGRect(
        x: 0,
        y: max(10, insetBounds.height * 0.20),
        width: insetBounds.width,
        height: 28
      )
      subtitle.frame = CGRect(
        x: 10,
        y: title.frame.maxY + 6,
        width: insetBounds.width - 20,
        height: 40
      )
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
  }

  private func setActiveSection(_ section: MenuSection, animated: Bool) {
    let changed = activeSection != section
    activeSection = section

    galleryDashboard.isHidden = activeSection != .gallery
    locationView.isHidden = activeSection != .location
    filterDropdownButton.isHidden = activeSection != .gallery

    updateSectionDropdownMenu()

    if activeSection == .gallery {
      refreshGalleryAssets()
    }

    view.setNeedsLayout()

    guard animated && changed else { return }
    let targetView = activeSection == .gallery ? galleryDashboard : locationView
    targetView.alpha = 0.0
    UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      targetView.alpha = 1.0
    }
  }

  private func setGalleryFilter(_ filter: GalleryFilter, animated: Bool) {
    guard activeGalleryFilter != filter else { return }
    activeGalleryFilter = filter
    updateFilterDropdownMenu()
    applyGalleryFilter()

    guard animated else { return }
    galleryDashboard.alpha = 0.0
    UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      self.galleryDashboard.alpha = 1.0
    }
  }

  private func applyGalleryFilter() {
    switch activeGalleryFilter {
    case .recent:
      galleryAssets = allGalleryAssets
      galleryEmptyLabel.text = "No media found"
    case .videos:
      galleryAssets = allGalleryAssets.filter { $0.mediaType == .video }
      galleryEmptyLabel.text = "No videos found"
    case .photos:
      galleryAssets = allGalleryAssets.filter { $0.mediaType == .image }
      galleryEmptyLabel.text = "No photos found"
    }

    galleryCollectionView.reloadData()
    galleryEmptyLabel.isHidden = !galleryAssets.isEmpty
  }

  private func refreshGalleryAssets() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    switch status {
    case .authorized, .limited:
      loadGalleryAssets()
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
        DispatchQueue.main.async {
          self?.refreshGalleryAssets()
        }
      }
    case .denied, .restricted:
      allGalleryAssets = []
      galleryAssets = []
      galleryCollectionView.reloadData()
      galleryEmptyLabel.text = "Allow Photos access to show your gallery"
      galleryEmptyLabel.isHidden = false
    @unknown default:
      allGalleryAssets = []
      galleryAssets = []
      galleryCollectionView.reloadData()
      galleryEmptyLabel.text = "Photos unavailable"
      galleryEmptyLabel.isHidden = false
    }
  }

  private func loadGalleryAssets() {
    let fetchOptions = PHFetchOptions()
    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    fetchOptions.fetchLimit = 300

    let fetch = PHAsset.fetchAssets(with: fetchOptions)
    var next: [PHAsset] = []
    next.reserveCapacity(fetch.count)
    fetch.enumerateObjects { asset, _, _ in
      next.append(asset)
    }

    allGalleryAssets = next
    applyGalleryFilter()
  }

  private func sendSelectedAsset(_ asset: PHAsset) {
    guard !isSelectingAsset else { return }
    isSelectingAsset = true

    if asset.mediaType == .video {
      sendSelectedVideoAsset(asset)
      return
    }

    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    options.version = .current

    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
      [weak self] data, uti, _, _ in
      guard let self else { return }
      guard let data else {
        DispatchQueue.main.async { self.isSelectingAsset = false }
        return
      }

      let ext: String = {
        if let uti, let type = UTType(uti) {
          return type.preferredFilenameExtension ?? "jpg"
        }
        return "jpg"
      }()

      let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("gallery-\(UUID().uuidString)")
        .appendingPathExtension(ext)

      do {
        try data.write(to: tempURL, options: .atomic)
        DispatchQueue.main.async {
          self.isSelectingAsset = false
          self.presentEditor(for: tempURL, initialImage: UIImage(data: data))
        }
      } catch {
        DispatchQueue.main.async {
          self.isSelectingAsset = false
        }
      }
    }
  }

  private func presentEditor(for url: URL, initialImage: UIImage?) {
    ChatImageEditModule.presentEditor(
      from: self,
      messageId: nil,
      mediaURL: url.absoluteString,
      initialImage: initialImage,
      initialCaption: nil
    ) { [weak self] payload in
      if payload.eventType == .sendNew {
        let finalURL = payload.editedImageURL ?? url
        self?.finishAndDismiss {
          self?.onSelectImage?(finalURL.absoluteString, payload.caption)
        }
      }
    }
  }

  private func sendSelectedVideoAsset(_ asset: PHAsset) {
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat

    PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
      [weak self] avAsset, _, _ in
      guard let self else { return }
      guard let urlAsset = avAsset as? AVURLAsset else {
        DispatchQueue.main.async { self.isSelectingAsset = false }
        return
      }

      let ext = urlAsset.url.pathExtension.isEmpty ? "mov" : urlAsset.url.pathExtension
      let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("gallery-video-\(UUID().uuidString)")
        .appendingPathExtension(ext)

      do {
        if FileManager.default.fileExists(atPath: tempURL.path) {
          try FileManager.default.removeItem(at: tempURL)
        }
        try FileManager.default.copyItem(at: urlAsset.url, to: tempURL)
        DispatchQueue.main.async {
          self.isSelectingAsset = false
          self.finishAndDismiss {
            self.onSelectImage?(tempURL.absoluteString, nil)
          }
        }
      } catch {
        DispatchQueue.main.async {
          self.isSelectingAsset = false
        }
      }
    }
  }

  private func bindCameraPreview(to hostView: UIView) {
    cameraPreviewHostView = hostView
    cameraPreviewLayer.session = cameraSession
    if cameraPreviewLayer.superlayer !== hostView.layer {
      cameraPreviewLayer.removeFromSuperlayer()
      hostView.layer.insertSublayer(cameraPreviewLayer, at: 0)
    }
    updateCameraPreviewFrame()
  }

  private func updateCameraPreviewFrame() {
    guard let host = cameraPreviewHostView else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    cameraPreviewLayer.frame = host.bounds
    CATransaction.commit()
  }

  private func reloadCameraTile() {
    guard galleryCollectionView.numberOfSections > 0 else { return }
    guard galleryCollectionView.numberOfItems(inSection: 0) > 0 else { return }
    galleryCollectionView.reloadItems(at: [IndexPath(item: 0, section: 0)])
  }

  private func startCameraPreview() {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      configureAndStartCameraSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          self.cameraPreviewAvailable = granted
          self.reloadCameraTile()
        }
        guard granted else { return }
        self?.configureAndStartCameraSession()
      }
    case .denied, .restricted:
      cameraPreviewAvailable = false
      reloadCameraTile()
    @unknown default:
      cameraPreviewAvailable = false
      reloadCameraTile()
    }
  }

  private func configureAndStartCameraSession() {
    cameraSessionQueue.async { [weak self] in
      guard let self else { return }
      if !self.isCameraConfigured {
        self.cameraSession.beginConfiguration()
        self.cameraSession.sessionPreset = .photo

        self.cameraSession.inputs.forEach { self.cameraSession.removeInput($0) }
        let camera =
          AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
          ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard
          let camera,
          let input = try? AVCaptureDeviceInput(device: camera),
          self.cameraSession.canAddInput(input)
        else {
          self.cameraSession.commitConfiguration()
          DispatchQueue.main.async {
            self.cameraPreviewAvailable = false
            self.reloadCameraTile()
          }
          return
        }

        self.cameraSession.addInput(input)
        self.cameraSession.commitConfiguration()
        self.isCameraConfigured = true
      }

      guard !self.cameraSession.isRunning else { return }
      self.cameraSession.startRunning()
      DispatchQueue.main.async {
        self.cameraPreviewAvailable = true
        self.reloadCameraTile()
      }
    }
  }

  private func stopCameraPreview() {
    cameraPreviewLayer.session = nil
    cameraPreviewHostView = nil
    let session = cameraSession
    cameraSessionQueue.async {
      if session.isRunning {
        session.stopRunning()
      }
    }
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

  private func finishAndDismiss(_ action: () -> Void) {
    action()
    dismiss(animated: true)
  }

  private func openFilePicker() {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  @objc private func openLocationFromTile() {
    ChatAttachmentMenuLocationManager.shared.requestOnce { [weak self] coord in
      DispatchQueue.main.async {
        guard let self else { return }
        self.finishAndDismiss {
          self.onSelectLocation?(coord.latitude, coord.longitude)
        }
      }
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

extension ChatAttachmentMenuController: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    guard let url = urls.first else { return }
    finishAndDismiss {
      self.onSelectFile?(url.absoluteString, url.lastPathComponent)
    }
  }
}

extension ChatAttachmentMenuController:
  UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout
{
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
    -> Int
  {
    galleryAssets.count + 1
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    if indexPath.item == 0 {
      guard
        let cameraCell = collectionView.dequeueReusableCell(
          withReuseIdentifier: ChatAttachmentCameraCell.reuseIdentifier,
          for: indexPath
        ) as? ChatAttachmentCameraCell
      else {
        return UICollectionViewCell()
      }
      cameraCell.setCameraAvailable(cameraPreviewAvailable)
      bindCameraPreview(to: cameraCell.previewView)
      return cameraCell
    }

    guard
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: ChatAttachmentAssetCell.reuseIdentifier,
        for: indexPath
      ) as? ChatAttachmentAssetCell
    else {
      return UICollectionViewCell()
    }

    let assetIndex = indexPath.item - 1
    guard assetIndex >= 0, assetIndex < galleryAssets.count else { return cell }

    let asset = galleryAssets[assetIndex]
    cell.representedAssetId = asset.localIdentifier
    cell.imageView.image = nil

    let targetSize = galleryThumbSize == .zero ? CGSize(width: 300, height: 300) : galleryThumbSize
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true

    photoManager.requestImage(
      for: asset,
      targetSize: targetSize,
      contentMode: .aspectFill,
      options: options
    ) { image, _ in
      guard cell.representedAssetId == asset.localIdentifier else { return }
      cell.imageView.image = image
    }

    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard indexPath.item > 0 else { return }
    let assetIndex = indexPath.item - 1
    guard assetIndex < galleryAssets.count else { return }
    sendSelectedAsset(galleryAssets[assetIndex])
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let base = max(1, galleryBaseItem)
    if indexPath.item == 0 {
      return CGSize(width: base, height: floor(base * (16.0 / 9.0)))
    }
    return CGSize(width: base, height: base)
  }
}

private final class ChatAttachmentAssetCell: UICollectionViewCell {
  static let reuseIdentifier = "ChatAttachmentAssetCell"

  let imageView = UIImageView()
  var representedAssetId: String = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 8

    imageView.frame = bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    imageView.contentMode = .scaleAspectFill
    imageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    contentView.addSubview(imageView)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedAssetId = ""
    imageView.image = nil
  }
}

private final class ChatAttachmentCameraCell: UICollectionViewCell {
  static let reuseIdentifier = "ChatAttachmentCameraCell"

  let previewView = UIView()
  private let gridLayer = CAShapeLayer()
  private let unavailableOverlay = UIView()
  private let unavailableIcon = UIImageView()
  private let unavailableLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 10
    layer.borderWidth = 0.4
    layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor

    previewView.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
    previewView.frame = bounds
    previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    previewView.clipsToBounds = true
    contentView.addSubview(previewView)

    gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.24).cgColor
    gridLayer.fillColor = UIColor.clear.cgColor
    gridLayer.lineWidth = 0.9
    previewView.layer.addSublayer(gridLayer)

    unavailableOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.34)
    unavailableOverlay.frame = bounds
    unavailableOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentView.addSubview(unavailableOverlay)

    unavailableIcon.image = UIImage(
      systemName: "camera.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    )
    unavailableIcon.tintColor = UIColor.white.withAlphaComponent(0.92)
    unavailableIcon.contentMode = .scaleAspectFit
    unavailableOverlay.addSubview(unavailableIcon)

    unavailableLabel.text = "Camera"
    unavailableLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    unavailableLabel.textColor = UIColor.white.withAlphaComponent(0.92)
    unavailableLabel.textAlignment = .center
    unavailableOverlay.addSubview(unavailableLabel)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let centerY = bounds.midY
    unavailableIcon.frame = CGRect(
      x: (bounds.width - 20) * 0.5,
      y: centerY - 16,
      width: 20,
      height: 20
    )
    unavailableLabel.frame = CGRect(
      x: 6,
      y: unavailableIcon.frame.maxY + 2,
      width: bounds.width - 12,
      height: 14
    )

    let b = previewView.bounds
    let path = UIBezierPath()
    let thirdX = b.width / 3.0
    let twoThirdX = thirdX * 2.0
    let thirdY = b.height / 3.0
    let twoThirdY = thirdY * 2.0

    [thirdX, twoThirdX].forEach { x in
      path.move(to: CGPoint(x: x, y: b.minY))
      path.addLine(to: CGPoint(x: x, y: b.maxY))
    }
    [thirdY, twoThirdY].forEach { y in
      path.move(to: CGPoint(x: b.minX, y: y))
      path.addLine(to: CGPoint(x: b.maxX, y: y))
    }

    gridLayer.path = path.cgPath
    gridLayer.frame = b
  }

  func setCameraAvailable(_ available: Bool) {
    unavailableOverlay.isHidden = available
  }
}
