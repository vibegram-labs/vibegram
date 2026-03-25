import AVFoundation
import CoreLocation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - ChatAttachmentMenuController

final class ChatAttachmentMenuController: UIViewController, UITextFieldDelegate {
  var onSelectImage: ((String, String?, ChatAttachmentTransitionCapture?) -> Void)?
  var onSelectFile: ((String, String) -> Void)?
  var onSelectLocation: ((Double, Double) -> Void)?

  var sourceButtonFrameInWindow: CGRect?
  weak var sourceButtonView: UIView?

  private let appearance: ChatListAppearance

  // ── UI ──
  private let headerTitleButton = UIButton(type: .system)
  private let contentView = UIView()
  private let galleryCollectionView: UICollectionView
  private let galleryLayout = GalleryGridLayout()
  private let galleryEmptyLabel = UILabel()
  private let fileView = UIView()
  private let fileActionButton = UIButton(type: .system)
  private let locationView = UIView()
  private let locationActionButton = UIButton(type: .system)

  // ── Soft edge masks (gradient fade at header and bottom) ──
  private let topMaskView = UIView()
  private let bottomMaskView = UIView()
  private let topMaskGradient = CAGradientLayer()
  private let bottomMaskGradient = CAGradientLayer()

  // ── Tab Bar: exact copy of ChatNativeTabBarModule subview pattern ──
  private class FloatingTabBar: UITabBar {
    override var safeAreaInsets: UIEdgeInsets { .zero }
  }
  // Tab bar is a direct subview — Apple draws its own floating glass pill.
  private let tabBar = FloatingTabBar()
  // Caption chrome — separate glass view, like vibeChromeView in ChatNativeTabBarModule.
  // Starts hidden. When an item is selected via the select toggle, this expands over the tab bar.
  private let captionChromeView = UIVisualEffectView(effect: nil)
  private let captionField = UITextField()
  private let captionSendButton = UIButton(type: .system)
  private let captionIconView = UIImageView()
  private var captionWidthConstraint: NSLayoutConstraint?
  private var captionHeightConstraint: NSLayoutConstraint?
  private var isCaptionMode = false
  private var selectedAssetIndex: Int? = nil

  // ── Tab bar container ──
  // A transparent container that holds the tab bar + caption chrome side-by-side,
  // matching the ChatNativeTabBarModule layout exactly.
  private let tabBarContainer = UIView()

  // ── State ──
  private let photoManager = PHCachingImageManager()
  private var allGalleryAssets: [PHAsset] = []
  private var galleryAssets: [PHAsset] = []
  private var galleryThumbSize: CGSize = .zero
  private var galleryBaseItem: CGFloat = 0
  private var isSelectingAsset = false
  private var activeSection: MenuSection = .gallery
  private var activeGalleryFilter: GalleryFilter = .recent

  // ── Camera ──
  private var cameraPreviewAvailable = false
  private weak var cameraPreviewHostView: UIView?
  private var isCameraLoading = true

  private let selectionFeedback = UISelectionFeedbackGenerator()

  private enum MenuSection: Int, CaseIterable {
    case gallery, file, location
    var title: String {
      switch self {
      case .gallery: return "Gallery"
      case .file: return "File"
      case .location: return "Location"
      }
    }
    var symbolName: String {
      switch self {
      case .gallery: return "photo.stack"
      case .file: return "doc"
      case .location: return "location.circle"
      }
    }
  }

  private enum GalleryFilter: String, CaseIterable {
    case recent = "Recent"
    case videos = "Videos"
    case photos = "Photos"
  }

  // MARK: - Colors (matched to theme.ts)

  private var modalBgColor: UIColor {
    appearance.isDark
      ? UIColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1.0)  // #121212
      : UIColor(red: 0.961, green: 0.957, blue: 0.945, alpha: 1.0)  // #F5F4F1
  }

  private var primaryTextColor: UIColor {
    appearance.isDark
      ? UIColor(red: 0.91, green: 0.90, blue: 0.94, alpha: 1.0)  // #E8E6F0
      : UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)  // #1A1A1F
  }

  private var secondaryTextColor: UIColor {
    primaryTextColor.withAlphaComponent(0.55)
  }

  private var accentColor: UIColor {
    appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor
  }

  // MARK: - Init

  init(appearance: ChatListAppearance) {
    self.appearance = appearance
    galleryLayout.spacing = 2
    self.galleryCollectionView = UICollectionView(frame: .zero, collectionViewLayout: galleryLayout)
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
  }

  required init?(coder: NSCoder) { nil }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = modalBgColor
    view.clipsToBounds = true

    configureSheet()
    setupContent()  // content first (behind everything)
    setupMasks()  // gradient masks on top of content
    setupHeader()  // header on top of mask
    setupTabBarAndCaption()  // tab bar on top of mask
    setActiveSection(.gallery, animated: false)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutAll()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startCameraPreview()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopCameraPreview()
  }

  deinit { stopCameraPreview() }

  // MARK: - Sheet

  private func configureSheet() {
    guard let sheet = sheetPresentationController else { return }
    sheet.detents = [.medium(), .large()]
    sheet.selectedDetentIdentifier = .medium
    sheet.prefersGrabberVisible = false
    sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    sheet.prefersEdgeAttachedInCompactHeight = true
    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
    sheet.preferredCornerRadius = 28
  }

  // MARK: - Header

  private func setupHeader() {
    headerTitleButton.tintColor = primaryTextColor
    headerTitleButton.showsMenuAsPrimaryAction = true
    view.addSubview(headerTitleButton)  // on top of mask
    updateHeaderButton()
  }

  // MARK: - Soft Edge Masks

  private func setupMasks() {
    // Top mask: fades from modalBgColor → transparent
    topMaskView.isUserInteractionEnabled = false
    topMaskGradient.colors = [modalBgColor.cgColor, modalBgColor.withAlphaComponent(0).cgColor]
    topMaskGradient.startPoint = CGPoint(x: 0.5, y: 0)
    topMaskGradient.endPoint = CGPoint(x: 0.5, y: 1)
    topMaskView.layer.addSublayer(topMaskGradient)
    view.addSubview(topMaskView)  // above content, below header

    // Bottom mask: fades from transparent → modalBgColor
    bottomMaskView.isUserInteractionEnabled = false
    bottomMaskGradient.colors = [modalBgColor.withAlphaComponent(0).cgColor, modalBgColor.cgColor]
    bottomMaskGradient.startPoint = CGPoint(x: 0.5, y: 0)
    bottomMaskGradient.endPoint = CGPoint(x: 0.5, y: 1)
    bottomMaskView.layer.addSublayer(bottomMaskGradient)
    view.addSubview(bottomMaskView)  // above content, below tab bar
  }

  // MARK: - Content

  private func setupContent() {
    contentView.backgroundColor = .clear
    view.addSubview(contentView)

    galleryCollectionView.backgroundColor = .clear
    galleryCollectionView.alwaysBounceVertical = true
    galleryCollectionView.showsVerticalScrollIndicator = true
    galleryCollectionView.contentInsetAdjustmentBehavior = .never
    galleryCollectionView.allowsMultipleSelection = false
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

    galleryEmptyLabel.text = "No photos found"
    galleryEmptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
    galleryEmptyLabel.textColor = secondaryTextColor
    galleryEmptyLabel.textAlignment = .center
    galleryEmptyLabel.numberOfLines = 0

    contentView.addSubview(galleryCollectionView)
    contentView.addSubview(galleryEmptyLabel)

    // File Rows
    let fileStack = UIStackView()
    fileStack.translatesAutoresizingMaskIntoConstraints = false
    fileStack.axis = .vertical
    fileStack.spacing = 0
    fileView.addSubview(fileStack)

    let isDark = appearance.isDark

    let galleryRow = AttachmentRowView(
      title: "Choose from Gallery",
      symbol: "photo.on.rectangle",
      color: .systemBlue,
      isDark: isDark,
      showDivider: true
    ) { [weak self] in
      self?.openFullGalleryPicker()
    }

    let docRow = AttachmentRowView(
      title: "Choose from Files",
      symbol: "folder",
      color: .systemOrange,
      isDark: isDark,
      showDivider: false
    ) { [weak self] in
      self?.openFilePicker()
    }

    fileStack.addArrangedSubview(galleryRow)
    fileStack.addArrangedSubview(docRow)

    NSLayoutConstraint.activate([
      fileStack.leadingAnchor.constraint(equalTo: fileView.leadingAnchor),
      fileStack.trailingAnchor.constraint(equalTo: fileView.trailingAnchor),
      fileStack.centerYAnchor.constraint(equalTo: fileView.centerYAnchor, constant: -20),
    ])

    contentView.addSubview(fileView)

    setupCenterAction(
      locationView, title: "Share Location", subtitle: "Send your current location",
      button: locationActionButton, buttonTitle: "Use Current Location", symbol: "location.circle"
    )
    locationActionButton.addTarget(self, action: #selector(openLocation), for: .touchUpInside)
    contentView.addSubview(locationView)
  }

  // MARK: - Tab Bar + Caption (exact ChatNativeTabBarModule subview copy)

  private func setupTabBarAndCaption() {
    // ── Container (transparent, no background, no edges) ──
    tabBarContainer.translatesAutoresizingMaskIntoConstraints = false
    tabBarContainer.backgroundColor = .clear
    tabBarContainer.isOpaque = false
    tabBarContainer.clipsToBounds = false
    view.addSubview(tabBarContainer)

    // ── Tab Bar (Apple draws its own glass pill internally) ──
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.delegate = self
    tabBar.itemPositioning = .automatic
    // We strictly do NOT clip or round tabBar. Apple handles the inner floating pill.
    tabBarContainer.addSubview(tabBar)

    // ── Caption Chrome (like vibeChromeView in ChatNativeTabBarModule) ──
    captionChromeView.translatesAutoresizingMaskIntoConstraints = false
    captionChromeView.layer.cornerRadius = 30
    captionChromeView.layer.cornerCurve = .continuous
    captionChromeView.clipsToBounds = true
    captionChromeView.isHidden = true
    tabBarContainer.addSubview(captionChromeView)

    // Caption icon
    captionIconView.translatesAutoresizingMaskIntoConstraints = false
    captionIconView.contentMode = .scaleAspectFit
    captionIconView.isUserInteractionEnabled = false
    captionIconView.image = UIImage(
      systemName: "arrow.up",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
    captionIconView.tintColor = .white
    captionIconView.alpha = 1.0
    captionChromeView.contentView.addSubview(captionIconView)

    // Caption text field
    captionField.translatesAutoresizingMaskIntoConstraints = false
    captionField.placeholder = "Add a caption…"
    captionField.font = .systemFont(ofSize: 16)
    captionField.textColor = primaryTextColor
    captionField.tintColor = accentColor
    captionField.alpha = 0
    captionField.returnKeyType = .send
    captionField.delegate = self
    captionField.addTarget(self, action: #selector(captionTextDidChange), for: .editingChanged)
    captionChromeView.contentView.addSubview(captionField)

    // Caption send button (below icon, like vibeSubmitButton)
    captionSendButton.translatesAutoresizingMaskIntoConstraints = false
    captionSendButton.backgroundColor = .clear
    captionSendButton.alpha = 0
    captionSendButton.addTarget(self, action: #selector(sendSelectedItem), for: .touchUpInside)
    captionChromeView.contentView.insertSubview(captionSendButton, belowSubview: captionIconView)

    let wC = captionChromeView.widthAnchor.constraint(equalToConstant: 0)
    let hC = captionChromeView.heightAnchor.constraint(equalToConstant: 0)
    captionWidthConstraint = wC
    captionHeightConstraint = hC

    // ── Constraints (exact ChatNativeTabBarModule pattern) ──
    NSLayoutConstraint.activate([
      // Container at bottom, full width, 64pt tall.
      // Pinned to view.bottomAnchor (NOT safeAreaLayoutGuide) — avoids the 70px gap.
      // The floating UITabBar draws its own glass pill; no safe area padding needed.
      tabBarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      tabBarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
      tabBarContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
      tabBarContainer.heightAnchor.constraint(equalToConstant: 64),

      // Tab bar: shift bounding box outward by -16 lead / +8 trail (Apple internal padding fix)
      tabBar.leadingAnchor.constraint(equalTo: tabBarContainer.leadingAnchor, constant: -16),
      tabBar.trailingAnchor.constraint(equalTo: tabBarContainer.trailingAnchor, constant: 16),
      tabBar.centerYAnchor.constraint(equalTo: tabBarContainer.centerYAnchor),

      // Caption chrome: same position as container (initially 0 width)
      captionChromeView.leadingAnchor.constraint(equalTo: tabBarContainer.leadingAnchor),
      captionChromeView.topAnchor.constraint(equalTo: tabBar.topAnchor),
      wC, hC,

      // Icon inside caption
      captionIconView.centerXAnchor.constraint(
        equalTo: captionChromeView.contentView.centerXAnchor),
      captionIconView.centerYAnchor.constraint(
        equalTo: captionChromeView.contentView.centerYAnchor),
      captionIconView.widthAnchor.constraint(equalToConstant: 24),
      captionIconView.heightAnchor.constraint(equalToConstant: 24),

      // Text field
      captionField.leadingAnchor.constraint(
        equalTo: captionChromeView.contentView.leadingAnchor, constant: 14),
      captionField.centerYAnchor.constraint(equalTo: captionChromeView.contentView.centerYAnchor),
      captionField.trailingAnchor.constraint(
        equalTo: captionSendButton.leadingAnchor, constant: -8),

      // Send button
      captionSendButton.trailingAnchor.constraint(
        equalTo: captionChromeView.contentView.trailingAnchor, constant: -6),
      captionSendButton.centerYAnchor.constraint(
        equalTo: captionChromeView.contentView.centerYAnchor),
      captionSendButton.widthAnchor.constraint(equalToConstant: 38),
      captionSendButton.heightAnchor.constraint(equalToConstant: 38),
    ])

    // Build tab items
    var items: [UITabBarItem] = []
    for section in MenuSection.allCases {
      let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
      let selCfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
      let sym = section.symbolName
      let tabItem = UITabBarItem(
        title: section.title,
        image: UIImage(systemName: sym, withConfiguration: cfg),
        tag: section.rawValue
      )
      tabItem.selectedImage =
        UIImage(systemName: sym + ".fill", withConfiguration: selCfg)
        ?? UIImage(systemName: sym, withConfiguration: selCfg)
      items.append(tabItem)
    }
    tabBar.items = items
    tabBar.selectedItem = items.first

    selectionFeedback.prepare()
    applyChrome()
  }

  // MARK: - Chrome (exact copy of ChatNativeTabBarModule.applyChrome)

  private func applyChrome() {
    let blurStyle: UIBlurEffect.Style =
      appearance.isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight

    // ── 1. UITabBar natively draws its own glass ──
    let tabAppearance = UITabBarAppearance()
    tabAppearance.configureWithDefaultBackground()
    tabAppearance.shadowColor = .clear
    // We STRICTLY do not set appearance.backgroundColor here.
    tabAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)

    let itemApp = tabAppearance.stackedLayoutAppearance
    let inactiveColor = primaryTextColor.withAlphaComponent(0.50)
    itemApp.normal.iconColor = inactiveColor
    itemApp.normal.titleTextAttributes = [.foregroundColor: inactiveColor]
    itemApp.normal.titlePositionAdjustment = .zero
    itemApp.selected.iconColor = primaryTextColor
    itemApp.selected.titleTextAttributes = [.foregroundColor: primaryTextColor]
    itemApp.selected.titlePositionAdjustment = .zero
    tabAppearance.stackedLayoutAppearance = itemApp
    tabAppearance.inlineLayoutAppearance = itemApp
    tabAppearance.compactInlineLayoutAppearance = itemApp

    tabBar.standardAppearance = tabAppearance
    if #available(iOS 15.0, *) {
      tabBar.scrollEdgeAppearance = tabAppearance
    }

    // ── 2. Caption chrome matches exact material ──
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      captionChromeView.effect = glass
    } else {
      captionChromeView.effect = UIBlurEffect(style: blurStyle)
    }
  }

  @objc private func captionTextDidChange() {
    guard isCaptionMode else { return }
    let hasText = !(captionField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    UIView.animate(withDuration: 0.2) {
      self.captionSendButton.backgroundColor =
        hasText
        ? self.accentColor
        : (self.appearance.isDark
          ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.06))
      self.captionIconView.tintColor =
        hasText
        ? .white
        : (self.appearance.isDark
          ? UIColor.white.withAlphaComponent(0.6) : UIColor.black.withAlphaComponent(0.4))
    }
  }

  // MARK: - Layout

  private func layoutAll() {
    let safe = view.safeAreaInsets
    let w = view.bounds.width
    let h = view.bounds.height

    // Header title
    let headerTop = safe.top + 8
    let titleWidth = min(240, w - 40)
    headerTitleButton.frame = CGRect(
      x: (w - titleWidth) * 0.5, y: headerTop, width: titleWidth, height: 34
    )

    // Content extends full-bleed: from top to view bottom.
    // Both header and tab bar float on top, with gradient masks for soft edges.
    contentView.frame = CGRect(x: 0, y: 0, width: w, height: h)

    galleryCollectionView.frame = contentView.bounds
    // Top inset pushes content below header; bottom inset keeps it above tab bar
    let topInset = headerTop + 42
    let tabBarOverlap: CGFloat = 80
    galleryCollectionView.contentInset = UIEdgeInsets(
      top: topInset, left: 0, bottom: tabBarOverlap, right: 0)
    galleryCollectionView.scrollIndicatorInsets = UIEdgeInsets(
      top: topInset, left: 0, bottom: tabBarOverlap, right: 0)
    galleryEmptyLabel.frame = CGRect(
      x: 20, y: topInset + 20, width: w - 40, height: h - topInset - tabBarOverlap - 40)

    // ── Soft gradient masks ──
    let topMaskH: CGFloat = topInset + 16  // covers header + fade zone
    topMaskView.frame = CGRect(x: 0, y: 0, width: w, height: topMaskH)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    topMaskGradient.frame = topMaskView.bounds
    CATransaction.commit()

    let bottomMaskH: CGFloat = 90  // fade zone above tab bar
    let bottomMaskY = h - bottomMaskH
    bottomMaskView.frame = CGRect(x: 0, y: bottomMaskY, width: w, height: bottomMaskH)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bottomMaskGradient.frame = bottomMaskView.bounds
    CATransaction.commit()

    // Gallery grid
    let spacing: CGFloat = 2
    let columns: CGFloat = w > 540 ? 5 : 3
    let itemSize = floor((w - ((columns - 1) * spacing)) / columns)
    galleryBaseItem = itemSize
    galleryLayout.columns = Int(columns)
    galleryLayout.spacing = spacing
    galleryLayout.invalidateLayout()

    let scale = view.window?.screen.scale ?? UIScreen.main.scale
    galleryThumbSize = CGSize(width: itemSize * scale, height: itemSize * scale)

    // File/Location use the visible area between header and tab bar
    let fileLocFrame = CGRect(
      x: 0, y: topInset, width: w, height: max(1, h - topInset - tabBarOverlap))
    fileView.frame = fileLocFrame
    locationView.frame = fileLocFrame
    layoutCenterViews()
    updateCameraPreviewFrame()
  }

  private func layoutCenterViews() {
    let insetBounds = contentView.bounds.insetBy(dx: 12, dy: 12)
    // Only location uses the classic center layout now
    for host in [locationView] {
      guard host.subviews.count >= 3 else { continue }
      let title = host.subviews[0]
      let subtitle = host.subviews[1]
      let button = host.subviews[2]
      title.frame = CGRect(
        x: 0, y: max(20, insetBounds.height * 0.22), width: insetBounds.width, height: 28)
      subtitle.frame = CGRect(
        x: 16, y: title.frame.maxY + 8, width: insetBounds.width - 32, height: 40)
      button.frame = CGRect(
        x: max(16, (insetBounds.width - 220) * 0.5),
        y: subtitle.frame.maxY + 18,
        width: min(220, insetBounds.width - 32), height: 44
      )
      title.center.x = host.bounds.midX
      subtitle.center.x = host.bounds.midX
      button.center.x = host.bounds.midX
    }
  }

  // MARK: - Section Switching

  private func setActiveSection(_ section: MenuSection, animated: Bool) {
    let previous = activeSection
    activeSection = section
    if section == .gallery { refreshGalleryAssets() }
    updateHeaderButton()

    guard animated && previous != section else {
      showHostView(for: section)
      return
    }

    let target = hostView(for: section)
    let from = hostView(for: previous)

    // Hide all first, then just show target and from
    [galleryCollectionView, galleryEmptyLabel, fileView, locationView].forEach {
      $0.isHidden = true
    }
    from.isHidden = false
    target.isHidden = false
    let targetEmptyLabelVisible = (section == .gallery && galleryAssets.isEmpty)
    let fromEmptyLabelVisible = (previous == .gallery && galleryAssets.isEmpty)
    if targetEmptyLabelVisible || fromEmptyLabelVisible {
      galleryEmptyLabel.isHidden = false
    }

    let dir: CGFloat = section.rawValue > previous.rawValue ? 1.0 : -1.0
    target.alpha = 0
    target.transform = CGAffineTransform(translationX: 0, y: dir * 15)
    from.transform = .identity

    // Manage empty label alpha if it belongs to target or from
    if targetEmptyLabelVisible {
      galleryEmptyLabel.alpha = 0
    } else if fromEmptyLabelVisible {
      galleryEmptyLabel.alpha = 1
    }

    UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      from.alpha = 0
      from.transform = CGAffineTransform(translationX: 0, y: -dir * 15)

      target.alpha = 1
      target.transform = .identity

      if targetEmptyLabelVisible {
        self.galleryEmptyLabel.alpha = 1
      } else if fromEmptyLabelVisible {
        self.galleryEmptyLabel.alpha = 0
      }
    } completion: { _ in
      self.showHostView(for: section)
      from.alpha = 1
      from.transform = .identity
      self.galleryEmptyLabel.alpha = 1
    }
  }

  private func showHostView(for section: MenuSection) {
    galleryCollectionView.isHidden = section != .gallery
    galleryEmptyLabel.isHidden = section != .gallery || !galleryAssets.isEmpty
    fileView.isHidden = section != .file
    locationView.isHidden = section != .location
  }

  private func hostView(for section: MenuSection) -> UIView {
    switch section {
    case .gallery: return galleryCollectionView
    case .file: return fileView
    case .location: return locationView
    }
  }

  // MARK: - Header Button

  private func updateHeaderButton() {
    let title = activeSection == .gallery ? activeGalleryFilter.rawValue : activeSection.title
    let showsArrow = activeSection == .gallery

    headerTitleButton.menu = activeSection == .gallery ? buildFilterMenu() : nil
    headerTitleButton.showsMenuAsPrimaryAction = activeSection == .gallery

    var attributes = AttributeContainer()
    attributes.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    var config = UIButton.Configuration.plain()
    config.attributedTitle = AttributedString(title, attributes: attributes)
    config.baseForegroundColor = primaryTextColor
    config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
    config.titleAlignment = .center
    if showsArrow {
      config.image = UIImage(
        systemName: "chevron.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
      )
      config.imagePlacement = .trailing
      config.imagePadding = 4
    }
    headerTitleButton.configuration = config
  }

  private func buildFilterMenu() -> UIMenu {
    UIMenu(
      children: GalleryFilter.allCases.map { filter in
        UIAction(
          title: filter.rawValue,
          image: UIImage(
            systemName: filter == .recent ? "clock" : filter == .videos ? "video" : "photo"),
          state: activeGalleryFilter == filter ? .on : .off
        ) { [weak self] _ in
          self?.setGalleryFilter(filter)
        }
      })
  }

  private func setGalleryFilter(_ filter: GalleryFilter) {
    guard activeGalleryFilter != filter else { return }
    activeGalleryFilter = filter
    updateHeaderButton()
    applyGalleryFilter()
  }

  // MARK: - Selection / Caption Mode (exact setVibeExpanded pattern)

  /// Called when the selection toggle on a cell is tapped.
  func handleSelectToggle(assetIndex: Int) {
    if selectedAssetIndex == assetIndex {
      // Deselect
      exitCaptionMode()
    } else {
      // Select (or switch selection)
      if isCaptionMode { exitCaptionMode() }
      enterCaptionMode(assetIndex: assetIndex)
    }
  }

  private func enterCaptionMode(assetIndex: Int) {
    guard !isCaptionMode else { return }
    isCaptionMode = true
    selectedAssetIndex = assetIndex
    captionChromeView.isHidden = false
    selectionFeedback.selectionChanged()
    selectionFeedback.prepare()

    // Mark cell as selected
    let ip = IndexPath(item: assetIndex + 1, section: 0)
    if let cell = galleryCollectionView.cellForItem(at: ip) as? ChatAttachmentAssetCell {
      cell.setChecked(true, animated: true)
    }

    UIView.animate(
      withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.2,
      options: .curveEaseInOut
    ) {
      let fullWidth = self.tabBarContainer.bounds.width
      self.captionWidthConstraint?.constant = fullWidth
      self.captionHeightConstraint?.constant = 50
      self.captionChromeView.layer.cornerRadius = 25

      self.tabBar.alpha = 0
      self.tabBar.transform = CGAffineTransform(translationX: -40, y: 0)

      self.captionChromeView.contentView.bringSubviewToFront(self.captionSendButton)
      self.captionChromeView.contentView.bringSubviewToFront(self.captionIconView)

      // Move icon to the send position (matching vibeExpand)
      let translationX = (fullWidth / 2.0) - 25.0
      self.captionIconView.transform = CGAffineTransform(translationX: translationX, y: 0)
        .scaledBy(x: 0.85, y: 0.85)

      self.captionSendButton.layer.cornerRadius = 19
      self.captionSendButton.backgroundColor =
        self.appearance.isDark
        ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.06)

      self.captionIconView.alpha = 1.0
      self.captionIconView.tintColor =
        self.appearance.isDark
        ? UIColor.white.withAlphaComponent(0.6) : UIColor.black.withAlphaComponent(0.4)
      self.captionField.alpha = 1.0
      self.captionSendButton.alpha = 1.0

      self.tabBarContainer.layoutIfNeeded()
    }
    // NO auto-focus on caption field — user can tap it if they want to type
  }

  private func exitCaptionMode() {
    guard isCaptionMode else { return }
    isCaptionMode = false
    captionField.resignFirstResponder()
    captionField.text = ""

    // Uncheck cell
    if let idx = selectedAssetIndex {
      let ip = IndexPath(item: idx + 1, section: 0)
      if let cell = galleryCollectionView.cellForItem(at: ip) as? ChatAttachmentAssetCell {
        cell.setChecked(false, animated: true)
      }
    }
    selectedAssetIndex = nil

    UIView.animate(
      withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.2,
      options: .curveEaseInOut
    ) {
      self.captionWidthConstraint?.constant = 0
      self.captionHeightConstraint?.constant = 0
      self.captionChromeView.layer.cornerRadius = 30

      self.tabBar.alpha = 1
      self.tabBar.transform = .identity

      self.captionIconView.transform = .identity
      self.captionIconView.alpha = 1.0
      self.captionIconView.tintColor = .white

      self.captionField.alpha = 0
      self.captionSendButton.alpha = 0
      self.captionSendButton.backgroundColor = .clear

      self.tabBarContainer.layoutIfNeeded()
    } completion: { _ in
      self.captionChromeView.isHidden = true
    }
  }

  @objc private func sendSelectedItem() {
    guard let assetIdx = selectedAssetIndex, assetIdx < galleryAssets.count else { return }
    sendSelectedAsset(galleryAssets[assetIdx], skipEditor: true)
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if isCaptionMode { sendSelectedItem() }
    return true
  }

  // MARK: - Gallery

  private func refreshGalleryAssets() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    switch status {
    case .authorized, .limited:
      loadGalleryAssets()
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
        DispatchQueue.main.async { self?.refreshGalleryAssets() }
      }
    default:
      allGalleryAssets = []
      galleryAssets = []
      galleryCollectionView.reloadData()
      galleryEmptyLabel.text = "Allow Photos access to show gallery"
      galleryEmptyLabel.isHidden = false
    }
  }

  private func loadGalleryAssets() {
    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    opts.fetchLimit = 300
    let fetch = PHAsset.fetchAssets(with: opts)
    var next: [PHAsset] = []
    next.reserveCapacity(fetch.count)
    fetch.enumerateObjects { asset, _, _ in next.append(asset) }
    allGalleryAssets = next
    applyGalleryFilter()
  }

  private func applyGalleryFilter() {
    switch activeGalleryFilter {
    case .recent: galleryAssets = allGalleryAssets
    case .videos: galleryAssets = allGalleryAssets.filter { $0.mediaType == .video }
    case .photos: galleryAssets = allGalleryAssets.filter { $0.mediaType == .image }
    }
    galleryCollectionView.reloadData()
    galleryEmptyLabel.isHidden = !galleryAssets.isEmpty
  }

  private func currentCaption() -> String? {
    let v = captionField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return v.isEmpty ? nil : v
  }

  // MARK: - Send

  private func sendSelectedAsset(_ asset: PHAsset, skipEditor: Bool = false) {
    guard !isSelectingAsset else { return }
    isSelectingAsset = true
    if asset.mediaType == .video {
      sendVideo(asset, skipEditor: skipEditor)
      return
    }
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    options.version = .current
    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
      [weak self] data, uti, _, _ in
      guard let self, let data else {
        DispatchQueue.main.async { self?.isSelectingAsset = false }
        return
      }
      let ext: String = {
        if let uti, let type = UTType(uti) { return type.preferredFilenameExtension ?? "jpg" }
        return "jpg"
      }()
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gallery-\(UUID().uuidString)")
        .appendingPathExtension(ext)
      do {
        try data.write(to: url, options: .atomic)
        DispatchQueue.main.async {
          self.isSelectingAsset = false
          if skipEditor {
            self.finishAndDismiss {
              self.onSelectImage?(url.absoluteString, self.currentCaption(), nil)
            }
          } else {
            self.presentEditor(for: url, initialImage: UIImage(data: data))
          }
        }
      } catch {
        DispatchQueue.main.async { self.isSelectingAsset = false }
      }
    }
  }

  private func presentEditor(for url: URL, initialImage: UIImage?) {
    let onSelectImage = self.onSelectImage
    ChatImageEditModule.presentEditor(
      from: self, messageId: nil, mediaURL: url.absoluteString,
      initialImage: initialImage,
      initialCaption: currentCaption(),
      dismissPresenterOnSend: true
    ) { [weak self] payload in
      if payload.eventType == .sendNew {
        let finalURL = payload.editedImageURL ?? url
        let caption = payload.caption ?? self?.currentCaption()
        if let self = self {
          self.finishAndDismiss {
            onSelectImage?(finalURL.absoluteString, caption, nil)
          }
        } else {
          onSelectImage?(finalURL.absoluteString, caption, nil)
        }
      }
    }
  }

  private func sendVideo(_ asset: PHAsset, skipEditor: Bool = false) {
    let opts = PHVideoRequestOptions()
    opts.isNetworkAccessAllowed = true
    opts.deliveryMode = .highQualityFormat
    PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) {
      [weak self] avAsset, _, _ in
      guard let self, let avAsset else {
        DispatchQueue.main.async { self?.isSelectingAsset = false }
        return
      }
      DispatchQueue.main.async {
        if skipEditor {
          self.persistSelectedVideoAsset(avAsset)
        } else {
          self.isSelectingAsset = false
          self.presentVideoEditor(for: avAsset)
        }
      }
    }
  }

  private func presentVideoEditor(for asset: AVAsset) {
    let onSelectImage = self.onSelectImage
    ChatVideoEditModule.presentEditor(
      from: self,
      asset: asset,
      initialCaption: currentCaption()
    ) { [weak self] payload in
      if let self = self {
        self.finishAndDismiss {
          onSelectImage?(
            payload.videoURL.absoluteString,
            payload.caption,
            payload.transitionCapture
          )
        }
      } else {
        onSelectImage?(
          payload.videoURL.absoluteString,
          payload.caption,
          payload.transitionCapture
        )
      }
    }
  }

  private func persistSelectedVideoAsset(_ asset: AVAsset) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      
      let exportPresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
      let preferredPresets = [
        AVAssetExportPreset1280x720,
        AVAssetExportPreset960x540,
        AVAssetExportPresetMediumQuality,
      ]

      if let presetName = preferredPresets.first(where: { exportPresets.contains($0) }),
        let exportSession = AVAssetExportSession(asset: asset, presetName: presetName),
        let outputFileType =
          ([AVFileType.mov, .mp4].first { exportSession.supportedFileTypes.contains($0) })
          ?? exportSession.supportedFileTypes.first
      {
        let outputExtension = outputFileType == .mov ? "mov" : "mp4"
        let outputURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("gallery-video-\(UUID().uuidString)")
          .appendingPathExtension(outputExtension)

        if FileManager.default.fileExists(atPath: outputURL.path) {
          try? FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = true
        NSLog(
          "[ChatAttachmentVideoExport] start preset=%@ fileType=%@ output=%@",
          presetName,
          outputFileType.rawValue,
          outputURL.lastPathComponent
        )
        exportSession.exportAsynchronously { [weak self] in
          DispatchQueue.main.async {
            guard let self else { return }
            if exportSession.status == .completed,
              self.isUsableExportedVideo(outputURL, logContext: "gallery_export")
            {
              self.isSelectingAsset = false
              self.finishAndDismiss {
                self.onSelectImage?(outputURL.absoluteString, self.currentCaption(), nil)
              }
              return
            }

            if let urlAsset = asset as? AVURLAsset,
              let fallbackURL = try? self.copyVideoToTemporaryURL(from: urlAsset.url)
            {
              self.isSelectingAsset = false
              self.finishAndDismiss {
                self.onSelectImage?(fallbackURL.absoluteString, self.currentCaption(), nil)
              }
              return
            }

            self.isSelectingAsset = false
          }
        }
        return
      }

      if let urlAsset = asset as? AVURLAsset {
        do {
          let url = try self.copyVideoToTemporaryURL(from: urlAsset.url)
          DispatchQueue.main.async {
            self.isSelectingAsset = false
            self.finishAndDismiss { self.onSelectImage?(url.absoluteString, self.currentCaption(), nil) }
          }
        } catch {
          DispatchQueue.main.async { self.isSelectingAsset = false }
        }
        return
      }

      DispatchQueue.main.async {
        self.isSelectingAsset = false
      }
    }
  }

  private func isUsableExportedVideo(_ url: URL, logContext: String) -> Bool {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let byteSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    guard byteSize > 0 else {
      NSLog("[ChatAttachmentVideoExport] %@ invalid empty path=%@", logContext, url.path)
      return false
    }
    let asset = AVURLAsset(url: url)
    let videoTracks = asset.tracks(withMediaType: .video)
    if asset.isPlayable && !videoTracks.isEmpty {
      NSLog(
        "[ChatAttachmentVideoExport] %@ validated path=%@ bytes=%lld tracks=%d",
        logContext,
        url.path,
        byteSize,
        videoTracks.count
      )
      return true
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640.0, height: 640.0)
    let probeTimes: [Double] = [0.0, 0.05, 0.12, 0.25, 0.5]
    var lastErrorDescription = "unknown"
    for seconds in probeTimes {
      do {
        _ = try generator.copyCGImage(
          at: CMTime(seconds: seconds, preferredTimescale: 600),
          actualTime: nil
        )
        NSLog(
          "[ChatAttachmentVideoExport] %@ validated by frame path=%@ bytes=%lld frame=%.2f",
          logContext,
          url.path,
          byteSize,
          seconds
        )
        return true
      } catch {
        lastErrorDescription = error.localizedDescription
      }
    }
    NSLog(
      "[ChatAttachmentVideoExport] %@ invalid path=%@ bytes=%lld tracks=%d playable=%@ error=%@",
      logContext,
      url.path,
      byteSize,
      videoTracks.count,
      asset.isPlayable ? "Y" : "N",
      lastErrorDescription
    )
    return false
  }

  private func copyVideoToTemporaryURL(from sourceURL: URL) throws -> URL {
    let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
    let destinationURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("gallery-video-\(UUID().uuidString)")
      .appendingPathExtension(ext)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private func finishAndDismiss(_ action: @escaping () -> Void) {
    if let presenter = presentingViewController {
      presenter.dismiss(animated: true) {
        action()
      }
    } else {
      dismiss(animated: true) {
        action()
      }
    }
  }

  // MARK: - Actions

  @objc private func openFullGalleryPicker() {
    view.endEditing(true)
    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = 1
    config.filter = .any(of: [.images, .videos])
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  @objc private func openFilePicker() {
    view.endEditing(true)
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  @objc private func openLocation() {
    view.endEditing(true)
    ChatAttachmentMenuLocationManager.shared.requestOnce { [weak self] coord in
      DispatchQueue.main.async {
        guard let self else { return }
        self.finishAndDismiss { self.onSelectLocation?(coord.latitude, coord.longitude) }
      }
    }
  }

  // MARK: - Camera
  
  private func bindCameraPreview(to hostView: UIView) {
    cameraPreviewHostView = hostView
    let layer = ChatAttachmentMenuCameraManager.shared.previewLayer
    if layer.superlayer !== hostView.layer {
      layer.removeFromSuperlayer()
      hostView.layer.insertSublayer(layer, at: 0)
    }
    updateCameraPreviewFrame()
  }

  private func updateCameraPreviewFrame() {
    guard let host = cameraPreviewHostView else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ChatAttachmentMenuCameraManager.shared.previewLayer.frame = host.bounds
    CATransaction.commit()
  }

  private func updateCameraTileLoadingState() {
    let indexPath = IndexPath(item: 0, section: 0)
    if let cell = galleryCollectionView.cellForItem(at: indexPath) as? ChatAttachmentCameraCell {
      cell.setLoading(isCameraLoading)
      cell.setCameraAvailable(cameraPreviewAvailable)
    }
  }

  private func startCameraPreview() {
    isCameraLoading = true
    updateCameraTileLoadingState()
    ChatAttachmentMenuCameraManager.shared.requestStart { [weak self] success in
      self?.cameraPreviewAvailable = success
      // Small delay to ensure the first frame is actually visible before removing blur
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        self?.isCameraLoading = false
        self?.updateCameraTileLoadingState()
      }
    }
  }

  private func stopCameraPreview() {
    ChatAttachmentMenuCameraManager.shared.previewLayer.removeFromSuperlayer()
    cameraPreviewHostView = nil
    ChatAttachmentMenuCameraManager.shared.requestStop()
  }

  // MARK: - Helpers

  private func setupCenterAction(
    _ host: UIView, title: String, subtitle: String,
    button: UIButton, buttonTitle: String, symbol: String
  ) {
    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
    titleLabel.textColor = primaryTextColor
    titleLabel.textAlignment = .center
    host.addSubview(titleLabel)

    let subtitleLabel = UILabel()
    subtitleLabel.text = subtitle
    subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
    subtitleLabel.textColor = secondaryTextColor
    subtitleLabel.textAlignment = .center
    subtitleLabel.numberOfLines = 2
    host.addSubview(subtitleLabel)

    button.layer.cornerRadius = 15
    button.layer.cornerCurve = .continuous
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: symbol)
    config.imagePlacement = .leading
    config.imagePadding = 6
    config.baseForegroundColor = primaryTextColor
    config.title = buttonTitle
    config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12)
    button.configuration = config
    button.backgroundColor = primaryTextColor.withAlphaComponent(appearance.isDark ? 0.06 : 0.05)
    host.addSubview(button)
  }
}

// MARK: - UITabBarDelegate

extension ChatAttachmentMenuController: UITabBarDelegate {
  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard let section = MenuSection(rawValue: item.tag) else { return }
    if section != activeSection {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    if isCaptionMode { exitCaptionMode() }
    setActiveSection(section, animated: true)
  }
}

// MARK: - UIDocumentPickerDelegate

extension ChatAttachmentMenuController: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    guard let url = urls.first else { return }
    finishAndDismiss { self.onSelectFile?(url.absoluteString, url.lastPathComponent) }
  }
}

// MARK: - Collection View

extension ChatAttachmentMenuController:
  UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout
{
  func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    galleryAssets.count + 1
  }

  func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    if indexPath.item == 0 {
      guard
        let cell = cv.dequeueReusableCell(
          withReuseIdentifier: ChatAttachmentCameraCell.reuseIdentifier, for: indexPath
        ) as? ChatAttachmentCameraCell
      else { return UICollectionViewCell() }
      cell.setCameraAvailable(cameraPreviewAvailable)
      cell.setLoading(isCameraLoading)
      bindCameraPreview(to: cell.previewView)
      return cell
    }
    guard
      let cell = cv.dequeueReusableCell(
        withReuseIdentifier: ChatAttachmentAssetCell.reuseIdentifier, for: indexPath
      ) as? ChatAttachmentAssetCell
    else { return UICollectionViewCell() }

    let assetIdx = indexPath.item - 1
    guard assetIdx < galleryAssets.count else { return cell }
    let asset = galleryAssets[assetIdx]
    cell.representedAssetId = asset.localIdentifier
    cell.imageView.image = nil
    cell.configureVideoBadge(isVideo: asset.mediaType == .video, duration: asset.duration)
    cell.onSelectToggle = { [weak self] in
      self?.handleSelectToggle(assetIndex: assetIdx)
    }
    // Show checked state if this cell matches current selection
    cell.setChecked(selectedAssetIndex == assetIdx, animated: false)

    let targetSize = galleryThumbSize == .zero ? CGSize(width: 300, height: 300) : galleryThumbSize
    let opts = PHImageRequestOptions()
    opts.deliveryMode = .opportunistic
    opts.resizeMode = .fast
    opts.isNetworkAccessAllowed = true
    photoManager.requestImage(
      for: asset, targetSize: targetSize, contentMode: .aspectFill, options: opts
    ) { image, _ in
      guard cell.representedAssetId == asset.localIdentifier else { return }
      cell.imageView.image = image
    }
    return cell
  }

  // Tap on cell body = open editor directly (not selection)
  func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    cv.deselectItem(at: indexPath, animated: false)
    if indexPath.item == 0 {
      openSystemCamera()
      return
    }
    let assetIdx = indexPath.item - 1
    guard assetIdx < galleryAssets.count else { return }
    // Direct tap = open editor
    sendSelectedAsset(galleryAssets[assetIdx])
  }

  // This goes through the generic FlowLayout delegate method, but
  // GalleryGridLayout doesn't actually use this. It's safe to keep or remove.
  func collectionView(
    _ cv: UICollectionView,
    layout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let base = max(1, galleryBaseItem)
    return CGSize(width: base, height: base)
  }
}

// MARK: - Camera Picker

extension ChatAttachmentMenuController: UIImagePickerControllerDelegate,
  UINavigationControllerDelegate
{
  private func openSystemCamera() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = ["public.image", "public.movie"]
    picker.delegate = self
    present(picker, animated: true)
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true) { [weak self] in
      if let image = info[.originalImage] as? UIImage {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
          "camera-\(UUID().uuidString).jpg")
        if let data = image.jpegData(compressionQuality: 0.9) {
          try? data.write(to: tempURL)
          self?.finishAndDismiss { self?.onSelectImage?(tempURL.absoluteString, nil, nil) }
        }
      } else if let videoURL = info[.mediaURL] as? URL, let self {
        let stableURL = (try? self.copyVideoToTemporaryURL(from: videoURL)) ?? videoURL
        self.presentVideoEditor(for: AVURLAsset(url: stableURL))
      }
    }
  }
}

// MARK: - Location Manager

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

  func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
    guard let loc = locs.first else { return }
    callback?(loc.coordinate)
    callback = nil
  }

  func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
    callback = nil
  }
}

// MARK: - Asset Cell (2-state selection toggle at top-right)

private final class ChatAttachmentAssetCell: UICollectionViewCell {
  static let reuseIdentifier = "ChatAttachmentAssetCell"
  let imageView = UIImageView()
  var representedAssetId = ""
  var onSelectToggle: (() -> Void)?

  // Selection toggle button at top-right
  private let toggleButton = UIButton(type: .system)
  private let videoBadgeView = UIView()
  private let videoBadgeIconView = UIImageView()
  private let videoBadgeLabel = UILabel()
  private var isChecked = false

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

    // 2-state toggle: circle (unchecked) / checkmark.circle.fill (checked)
    toggleButton.setImage(
      UIImage(
        systemName: "circle",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)),
      for: .normal
    )
    toggleButton.tintColor = UIColor.white.withAlphaComponent(0.8)
    toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
    // Large hit area
    toggleButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
    contentView.addSubview(toggleButton)

    videoBadgeView.backgroundColor = UIColor(white: 0.0, alpha: 0.64)
    videoBadgeView.layer.cornerRadius = 8
    videoBadgeView.layer.cornerCurve = .continuous
    videoBadgeView.isHidden = true
    contentView.addSubview(videoBadgeView)

    videoBadgeIconView.image = UIImage(
      systemName: "video.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    videoBadgeIconView.tintColor = .white
    videoBadgeIconView.contentMode = .scaleAspectFit
    videoBadgeIconView.isHidden = true
    videoBadgeView.addSubview(videoBadgeIconView)

    videoBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    videoBadgeLabel.textColor = .white
    videoBadgeLabel.textAlignment = .center
    videoBadgeView.addSubview(videoBadgeLabel)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    let size: CGFloat = 32
    toggleButton.frame = CGRect(
      x: bounds.width - size - 4, y: 4, width: size, height: size
    )

    let badgeText = videoBadgeLabel.text ?? ""
    let labelWidth = ceil((badgeText as NSString).size(withAttributes: [.font: videoBadgeLabel.font as Any]).width)
    let badgeWidth = max(34.0, labelWidth + 16.0)
    let badgeHeight: CGFloat = 20.0
    videoBadgeView.frame = CGRect(
      x: bounds.width - badgeWidth - 6.0,
      y: bounds.height - badgeHeight - 6.0,
      width: badgeWidth,
      height: badgeHeight
    )
    videoBadgeLabel.frame = CGRect(
      x: 8.0,
      y: 2.0,
      width: max(1.0, badgeWidth - 16.0),
      height: badgeHeight - 4.0
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedAssetId = ""
    imageView.image = nil
    onSelectToggle = nil
    videoBadgeView.isHidden = true
    videoBadgeLabel.text = nil
    setChecked(false, animated: false)
  }

  @objc private func toggleTapped() {
    onSelectToggle?()
  }

  func setChecked(_ checked: Bool, animated: Bool) {
    isChecked = checked
    let symbol = checked ? "checkmark.circle.fill" : "circle"
    let tint: UIColor = checked ? UIColor.systemBlue : UIColor.white.withAlphaComponent(0.8)
    let image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
    )

    if animated {
      UIView.transition(with: toggleButton, duration: 0.18, options: .transitionCrossDissolve) {
        self.toggleButton.setImage(image, for: .normal)
        self.toggleButton.tintColor = tint
      }
    } else {
      toggleButton.setImage(image, for: .normal)
      toggleButton.tintColor = tint
    }
  }

  func configureVideoBadge(isVideo: Bool, duration: TimeInterval) {
    guard isVideo else {
      videoBadgeView.isHidden = true
      videoBadgeLabel.text = nil
      return
    }
    videoBadgeLabel.text = Self.formattedDuration(duration)
    videoBadgeView.isHidden = false
    setNeedsLayout()
  }

  private static func formattedDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }
}

// MARK: - Camera Cell

private final class ChatAttachmentCameraCell: UICollectionViewCell {
  static let reuseIdentifier = "ChatAttachmentCameraCell"
  let previewView = UIView()
  private let gridLayer = CAShapeLayer()
  private let unavailableOverlay = UIView()
  private let unavailableIcon = UIImageView()
  private let unavailableLabel = UILabel()
  private let loadingBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))

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
    
    loadingBlurView.frame = bounds
    loadingBlurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentView.addSubview(loadingBlurView)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    let cy = bounds.midY
    unavailableIcon.frame = CGRect(x: (bounds.width - 20) * 0.5, y: cy - 16, width: 20, height: 20)
    unavailableLabel.frame = CGRect(
      x: 6, y: unavailableIcon.frame.maxY + 2, width: bounds.width - 12, height: 14)

    let b = previewView.bounds
    let path = UIBezierPath()
    let tx = b.width / 3
    let ttx = tx * 2
    let ty = b.height / 3
    let tty = ty * 2
    for x in [tx, ttx] {
      path.move(to: CGPoint(x: x, y: b.minY))
      path.addLine(to: CGPoint(x: x, y: b.maxY))
    }
    for y in [ty, tty] {
      path.move(to: CGPoint(x: b.minX, y: y))
      path.addLine(to: CGPoint(x: b.maxX, y: y))
    }
    gridLayer.path = path.cgPath
    gridLayer.frame = b
  }

  func setCameraAvailable(_ available: Bool) {
    unavailableOverlay.isHidden = available
  }
  
  func setLoading(_ isLoading: Bool) {
    if isLoading {
      loadingBlurView.alpha = 1
    } else {
      UIView.animate(withDuration: 0.25) {
        self.loadingBlurView.alpha = 0
      }
    }
  }
}

// MARK: - PHPickerViewControllerDelegate

extension ChatAttachmentMenuController: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = results.first else { return }

    // Attempt to load item safely
    let itemProvider = result.itemProvider
    if itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) {
        [weak self] url, _ in
        guard let url = url else { return }
        guard let self else { return }
        let stableURL = (try? self.copyVideoToTemporaryURL(from: url)) ?? url
        DispatchQueue.main.async {
          self.isSelectingAsset = false
          self.presentVideoEditor(for: AVURLAsset(url: stableURL))
        }
      }
    } else if itemProvider.canLoadObject(ofClass: UIImage.self) {
      itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
        guard let image = object as? UIImage, let data = image.jpegData(compressionQuality: 0.9)
        else { return }
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("gallery-\(UUID().uuidString).jpg")
        try? data.write(to: url)
        DispatchQueue.main.async {
          self?.finishAndDismiss { self?.onSelectImage?(url.absoluteString, nil, nil) }
        }
      }
    }
  }
}

// MARK: - Attachment Row View

private final class AttachmentRowView: UIControl {
  private let iconContainer = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let chevronView = UIImageView()
  private let divider = UIView()
  private var onPress: (() -> Void)?

  init(
    title: String, symbol: String, color: UIColor, isDark: Bool, showDivider: Bool,
    onPress: @escaping () -> Void
  ) {
    self.onPress = onPress
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)

    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.layer.cornerRadius = 8
    iconContainer.backgroundColor = color.withAlphaComponent(isDark ? 0.18 : 0.12)
    addSubview(iconContainer)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
    iconView.tintColor = color
    iconContainer.addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textColor = isDark ? .white : .black
    titleLabel.text = title
    addSubview(titleLabel)

    chevronView.translatesAutoresizingMaskIntoConstraints = false
    chevronView.contentMode = .scaleAspectFit
    chevronView.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    chevronView.tintColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(
      isDark ? 0.5 : 0.32)
    addSubview(chevronView)

    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.backgroundColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(
      isDark ? 0.05 : 0.06)
    divider.isHidden = !showDivider
    addSubview(divider)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 58),

      iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconContainer.widthAnchor.constraint(equalToConstant: 30),
      iconContainer.heightAnchor.constraint(equalToConstant: 30),

      iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),

      titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 14),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
      chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),

      divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 64),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor),
      divider.bottomAnchor.constraint(equalTo: bottomAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
    ])
  }

  required init?(coder: NSCoder) { nil }

  @objc private func handleTap() { onPress?() }

  override var isHighlighted: Bool {
    didSet {
      backgroundColor = isHighlighted ? UIColor(white: 0.5, alpha: 0.1) : .clear
    }
  }
}

// MARK: - Shared Camera Manager

private final class ChatAttachmentMenuCameraManager {
  static let shared = ChatAttachmentMenuCameraManager()
  
  let session = AVCaptureSession()
  let previewLayer = AVCaptureVideoPreviewLayer()
  private let queue = DispatchQueue(label: "chat.attachment.menu.camera.session", qos: .userInitiated)
  private var isConfigured = false
  private(set) var isAvailable = false
  
  private init() {
    previewLayer.session = session
    previewLayer.videoGravity = .resizeAspectFill
  }
  
  func requestStart(completion: @escaping (Bool) -> Void) {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      configureAndStart(completion)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        if granted {
          self?.configureAndStart(completion)
        } else {
          DispatchQueue.main.async { completion(false) }
        }
      }
    default:
      DispatchQueue.main.async { completion(false) }
    }
  }
  
  private func configureAndStart(_ completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      
      let notify: (Bool) -> Void = { success in
        DispatchQueue.main.async {
          self.isAvailable = success
          completion(success)
        }
      }
      
      if !self.isConfigured {
        self.session.beginConfiguration()
        self.session.sessionPreset = .photo
        self.session.inputs.forEach { self.session.removeInput($0) }
        let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let cam, let input = try? AVCaptureDeviceInput(device: cam), self.session.canAddInput(input) else {
          self.session.commitConfiguration()
          notify(false)
          return
        }
        self.session.addInput(input)
        self.session.commitConfiguration()
        self.isConfigured = true
      }
      if !self.session.isRunning {
        self.session.startRunning()
      }
      notify(true)
    }
  }
  
  func requestStop() {
    queue.async { [weak self] in
      if self?.session.isRunning == true {
        self?.session.stopRunning()
      }
    }
  }
}

// MARK: - GalleryGridLayout

private final class GalleryGridLayout: UICollectionViewLayout {
  var spacing: CGFloat = 2
  var columns: Int = 3

  private var cache: [UICollectionViewLayoutAttributes] = []
  private var contentHeight: CGFloat = 0

  override func prepare() {
    super.prepare()
    guard let cv = collectionView, cv.numberOfSections > 0 else { return }
    cache.removeAll()

    let itemsCount = cv.numberOfItems(inSection: 0)
    guard itemsCount > 0 else {
      contentHeight = 0
      return
    }

    let width = cv.bounds.width
    let itemW = floor((width - CGFloat(columns - 1) * spacing) / CGFloat(columns))

    // Make first item (camera) height equal to exactly two rows + spacing
    // This perfectly aligns it with two grid squares next to it.
    let cameraH = itemW * 2 + spacing

    // We keep track of the current Y offset for each column
    var yOffsets = Array(repeating: CGFloat(0), count: max(1, columns))

    for item in 0..<itemsCount {
      let indexPath = IndexPath(item: item, section: 0)
      let attr = UICollectionViewLayoutAttributes(forCellWith: indexPath)

      if item == 0 {
        // Camera span column 0, two rows
        attr.frame = CGRect(x: 0, y: 0, width: itemW, height: cameraH)
        yOffsets[0] = cameraH + spacing
      } else {
        // Find shortest column to place the next item
        var minCol = 0
        var minH = yOffsets[0]
        for col in 1..<columns {
          if yOffsets[col] < minH {
            minH = yOffsets[col]
            minCol = col
          }
        }

        let xOffset = CGFloat(minCol) * (itemW + spacing)
        attr.frame = CGRect(x: xOffset, y: minH, width: itemW, height: itemW)
        yOffsets[minCol] = minH + itemW + spacing
      }
      cache.append(attr)
    }

    contentHeight = (yOffsets.max() ?? 0) - spacing
  }

  override var collectionViewContentSize: CGSize {
    return CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]?
  {
    var visible: [UICollectionViewLayoutAttributes] = []
    for attr in cache {
      if attr.frame.intersects(rect) { visible.append(attr) }
    }
    return visible
  }

  override func layoutAttributesForItem(at indexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    guard indexPath.item < cache.count else { return nil }
    return cache[indexPath.item]
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    guard let cv = collectionView else { return false }
    return cv.bounds.width != newBounds.width
  }
}
