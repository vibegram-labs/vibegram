import ExpoModulesCore
import UIKit

private struct ChatNativeTabItem: Equatable {
  let index: Int
  let key: String
  let title: String
  let sfSymbol: String?
  let iconUri: String?
  let badge: String?
  let isVibe: Bool
}

public final class ChatNativeTabBarView: ExpoView, UITabBarDelegate, UITextFieldDelegate {
  public var onIndexChange = EventDispatcher()
  public var onVibeSubmit = EventDispatcher()

  // Custom TabBar that ignores safe-area
  private class FloatingTabBar: UITabBar {
    override var safeAreaInsets: UIEdgeInsets { .zero }
  }

  // Main Tab Bar (natively applies its own glass)
  private let tabBar = FloatingTabBar()

  // Vibe Button & Input
  private let vibeChromeView = UIVisualEffectView(effect: nil)
  private let vibeIconView = UIImageView()
  private let vibeButton = UIButton(type: .system)
  private let vibeTextField = UITextField()
  private let vibeSubmitButton = UIButton(type: .system)

  private var vibeWidthConstraint: NSLayoutConstraint?
  private var vibeHeightConstraint: NSLayoutConstraint?
  private var isVibeExpanded = false

  private var tabs: [ChatNativeTabItem] = []

  private var currentIndex = 0
  private var activeTintColor = UIColor.systemBlue
  private var inactiveTintColor = UIColor.systemGray
  private var isDark = false

  private let selectionFeedback = UISelectionFeedbackGenerator()
  private var remoteIconCache: [String: UIImage] = [:]
  private var remoteIconRequests: Set<String> = []

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupView()
  }

  deinit {}

  public override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 64)
  }

  private func setupView() {
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false

    // ── Tab Bar ──
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.delegate = self
    // We strictly do NOT clip or round tabBar. Apple handles the inner floating pill.
    addSubview(tabBar)

    // ── Vibe Chrome ──
    vibeChromeView.translatesAutoresizingMaskIntoConstraints = false
    vibeChromeView.layer.cornerRadius = 30
    vibeChromeView.layer.cornerCurve = .continuous
    vibeChromeView.clipsToBounds = true
    addSubview(vibeChromeView)

    // Vibe icon centered
    vibeIconView.translatesAutoresizingMaskIntoConstraints = false
    vibeIconView.contentMode = .scaleAspectFit
    vibeIconView.isUserInteractionEnabled = false  // Never swallow touches!
    vibeChromeView.contentView.addSubview(vibeIconView)

    // Touch target
    vibeButton.translatesAutoresizingMaskIntoConstraints = false
    vibeButton.addTarget(self, action: #selector(handleVibePress), for: .touchUpInside)
    vibeChromeView.contentView.addSubview(vibeButton)

    // Text Field
    vibeTextField.translatesAutoresizingMaskIntoConstraints = false
    vibeTextField.placeholder = "Message Vibe..."
    vibeTextField.font = .systemFont(ofSize: 16)
    vibeTextField.alpha = 0
    vibeTextField.returnKeyType = .send
    vibeTextField.delegate = self
    vibeTextField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)
    vibeChromeView.contentView.addSubview(vibeTextField)

    // Submit Button - Inserted BELOW icon so it acts as background pill and doesn't obscure the SVG!
    vibeSubmitButton.translatesAutoresizingMaskIntoConstraints = false
    vibeSubmitButton.backgroundColor = .clear
    vibeSubmitButton.alpha = 0  // Initially invisible touch target
    vibeSubmitButton.addTarget(self, action: #selector(handleVibeSubmitAction), for: .touchUpInside)
    vibeChromeView.contentView.insertSubview(vibeSubmitButton, belowSubview: vibeIconView)

    let widthConstraint = vibeChromeView.widthAnchor.constraint(equalToConstant: 60)
    let heightConstraint = vibeChromeView.heightAnchor.constraint(equalToConstant: 60)
    self.vibeWidthConstraint = widthConstraint
    self.vibeHeightConstraint = heightConstraint

    // ── Direct Constraints ──
    NSLayoutConstraint.activate([
      // Shift the bounding box outward by 16pt on leading and 8pt on trailing to translate the invisible box leftward.
      // This mathematically balances Apple's inner padding so the visible glass pill aligns perfectly with the 10pt JS container padding.
      tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -16),
      tabBar.trailingAnchor.constraint(equalTo: vibeChromeView.leadingAnchor, constant: 8),
      tabBar.centerYAnchor.constraint(equalTo: centerYAnchor),

      // Vibe chrome explicitly sized to ~60pt to exactly match Apple's iOS 18 floating pill limits
      vibeChromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
      vibeChromeView.topAnchor.constraint(equalTo: tabBar.topAnchor),
      heightConstraint,
      widthConstraint,

      // Icon inside vibe
      vibeIconView.centerXAnchor.constraint(equalTo: vibeChromeView.contentView.centerXAnchor),
      vibeIconView.centerYAnchor.constraint(equalTo: vibeChromeView.contentView.centerYAnchor),
      vibeIconView.widthAnchor.constraint(equalToConstant: 24),
      vibeIconView.heightAnchor.constraint(equalToConstant: 24),

      // Text Field Constraints
      vibeTextField.leadingAnchor.constraint(
        equalTo: vibeChromeView.contentView.leadingAnchor, constant: 14),
      vibeTextField.centerYAnchor.constraint(equalTo: vibeChromeView.contentView.centerYAnchor),
      vibeTextField.trailingAnchor.constraint(
        equalTo: vibeSubmitButton.leadingAnchor, constant: -8),

      // Submit Button Constraints
      vibeSubmitButton.trailingAnchor.constraint(
        equalTo: vibeChromeView.contentView.trailingAnchor, constant: -6),
      vibeSubmitButton.centerYAnchor.constraint(equalTo: vibeChromeView.contentView.centerYAnchor),
      vibeSubmitButton.widthAnchor.constraint(equalToConstant: 38),
      vibeSubmitButton.heightAnchor.constraint(equalToConstant: 38),

      // Tap area fills vibe
      vibeButton.leadingAnchor.constraint(equalTo: vibeChromeView.contentView.leadingAnchor),
      vibeButton.trailingAnchor.constraint(equalTo: vibeChromeView.contentView.trailingAnchor),
      vibeButton.topAnchor.constraint(equalTo: vibeChromeView.contentView.topAnchor),
      vibeButton.bottomAnchor.constraint(equalTo: vibeChromeView.contentView.bottomAnchor),
    ])

    tabBar.itemPositioning = .automatic
    selectionFeedback.prepare()
    applyChrome()
  }

  func setTabs(_ rawTabs: [[String: Any]]) {
    let newTabs: [ChatNativeTabItem] = rawTabs.enumerated().map { index, raw in
      let key = (raw["key"] as? String) ?? UUID().uuidString
      let title = (raw["title"] as? String) ?? key
      let sfSymbol = raw["sfSymbol"] as? String
      let iconUri = raw["iconUri"] as? String
      let badgeValue = raw["badge"]
      let badge = badgeValue.map { String(describing: $0) }
      let isVibe = (raw["isVibe"] as? Bool) ?? false
      return ChatNativeTabItem(
        index: index, key: key, title: title,
        sfSymbol: sfSymbol, iconUri: iconUri,
        badge: badge, isVibe: isVibe)
    }

    if tabs == newTabs { return }

    let itemsChanged =
      tabs.count != newTabs.count || zip(tabs, newTabs).contains { a, b in a.key != b.key }
    tabs = newTabs

    if itemsChanged {
      rebuildSegments()
    } else {
      updateExistingSegments()
    }
  }

  func setCurrentIndex(_ value: Int) {
    guard value != currentIndex else { return }
    currentIndex = value
    applySelection()
  }

  func setActiveTintColor(_ value: UIColor?) {
    if let value, activeTintColor != value {
      activeTintColor = value
      applyChrome()
      applySelection()
    }
  }

  func setInactiveTintColor(_ value: UIColor?) {
    if let value, inactiveTintColor != value {
      inactiveTintColor = value
      applyChrome()
      applySelection()
    }
  }

  func setIsDark(_ value: Bool) {
    guard value != isDark else { return }
    isDark = value
    applyChrome()
    applySelection()
  }

  public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    let tabIndex = item.tag
    guard tabIndex >= 0, tabIndex < tabs.count else { return }
    if tabIndex != currentIndex {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    currentIndex = tabIndex
    onIndexChange(["index": tabIndex])
  }

  private func updateExistingSegments() {
    let mainTabs = tabs.filter { !$0.isVibe }
    let vibeTab = tabs.first(where: \.isVibe)

    guard let items = tabBar.items, items.count == mainTabs.count else {
      rebuildSegments()
      return
    }

    for (index, tab) in mainTabs.enumerated() {
      let item = items[index]
      item.title = tab.title
      item.badgeValue = tab.badge
    }

    updateVibeButton(for: vibeTab)
    applySelection()
  }

  private func rebuildSegments() {
    let mainTabs = tabs.filter { !$0.isVibe }
    let vibeTab = tabs.first(where: \.isVibe)
    var tabBarItems: [UITabBarItem] = []
    tabBar.isHidden = mainTabs.isEmpty

    for tab in mainTabs {
      let symbol = tab.sfSymbol ?? fallbackSymbol(tab.key)

      var normalImage: UIImage?
      var selectedImage: UIImage?

      let item = UITabBarItem(title: tab.title, image: nil, tag: tab.index)

      if let customIcon = resolvedIcon(for: tab) {
        // We resize the avatar image to 24x24 so it aligns perfectly with the standard 24x24 SF Symbols
        let cgSize = CGSize(width: 24, height: 24)
        if let resized = resizeImage(image: customIcon, targetSize: cgSize) {
          let originalImage = resized.withRenderingMode(.alwaysOriginal)
          let finalImage = withRoundedCorners(image: originalImage, radius: 12) ?? originalImage
          item.image = finalImage
          item.selectedImage = finalImage

          // Push the custom image down slightly to align its baseline with the SF Symbols!
          item.imageInsets = UIEdgeInsets(top: 2, left: 0, bottom: -2, right: 0)
        }
      } else {
        let iconCfg = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        normalImage = UIImage(systemName: symbol, withConfiguration: iconCfg)
        let selectedCfg = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        selectedImage =
          UIImage(systemName: symbol + ".fill", withConfiguration: selectedCfg)
          ?? UIImage(systemName: symbol, withConfiguration: selectedCfg)

        item.image = normalImage
        item.selectedImage = selectedImage
      }

      item.badgeValue = tab.badge
      tabBarItems.append(item)
    }

    tabBar.items = tabBarItems
    updateVibeButton(for: vibeTab)
    applySelection()
  }

  private func applySelection() {
    guard !tabs.isEmpty else { return }
    let normalized = max(0, min(currentIndex, tabs.count - 1))
    if normalized != currentIndex { currentIndex = normalized }

    tabBar.tintColor = activeTintColor
    tabBar.unselectedItemTintColor = inactiveTintColor
    updateVibeButton(for: tabs.first(where: \.isVibe))

    if let items = tabBar.items {
      tabBar.selectedItem = items.first(where: { $0.tag == currentIndex })
    }
  }

  func setVibeExpanded(_ expanded: Bool) {
    guard self.isVibeExpanded != expanded else { return }
    self.isVibeExpanded = expanded

    UIView.animate(
      withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.2,
      options: .curveEaseInOut,
      animations: {
        if expanded {
          let fullWidth = self.bounds.width  // span entire width inherently aligning to outer container padding
          self.vibeWidthConstraint?.constant = fullWidth
          self.vibeHeightConstraint?.constant = 50
          self.vibeChromeView.layer.cornerRadius = 25
          self.tabBar.alpha = 0.0
          self.tabBar.transform = CGAffineTransform(translationX: -40, y: 0)

          self.vibeChromeView.contentView.bringSubviewToFront(self.vibeSubmitButton)
          self.vibeChromeView.contentView.bringSubviewToFront(self.vibeIconView)

          // Center of the layout shifts natively to fullWidth/2.
          // Target position of the center is fullWidth - 26.
          // Translation          // Translation = targetCenter - currentLayoutCenter
          // center of submit button = fullWidth - 6 - (38/2) = fullWidth - 25.
          let translationX = (fullWidth / 2.0) - 25.0
          self.vibeIconView.transform = CGAffineTransform(translationX: translationX, y: 0)
            .scaledBy(x: 0.85, y: 0.85)

          self.vibeSubmitButton.layer.cornerRadius = 19
          self.textDidChange()  // dynamically apply colors based on text

          self.vibeIconView.alpha = 1.0
          self.vibeTextField.alpha = 1.0
          self.vibeSubmitButton.alpha = 1.0  // Becomes visible colored pill
          self.vibeButton.isUserInteractionEnabled = false
        } else {
          self.vibeWidthConstraint?.constant = 60
          self.vibeHeightConstraint?.constant = 60
          self.vibeChromeView.layer.cornerRadius = 30
          self.tabBar.alpha = 1.0
          self.tabBar.transform = .identity

          self.vibeIconView.transform = .identity
          self.vibeIconView.alpha = 1.0
          self.vibeIconView.tintColor = .white

          self.vibeTextField.alpha = 0.0
          self.vibeSubmitButton.alpha = 0.0
          self.vibeSubmitButton.backgroundColor = .clear
          self.vibeButton.isUserInteractionEnabled = true
          self.vibeTextField.resignFirstResponder()
        }
        self.layoutIfNeeded()
      }
    ) { _ in
      self.updateVibeButton(for: self.tabs.first(where: \.isVibe))
    }
  }

  @objc private func handleVibeSubmitAction() {
    print("[VibeTabBar] Submit native pressed! Text length: \(vibeTextField.text?.count ?? 0)")
    guard let text = vibeTextField.text,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    onVibeSubmit(["text": text])
    vibeTextField.text = ""
    textDidChange()  // reset colors
  }

  public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    handleVibeSubmitAction()
    vibeTextField.resignFirstResponder()
    return true
  }

  @objc private func textDidChange() {
    guard self.isVibeExpanded else { return }
    let text = vibeTextField.text ?? ""
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    UIView.animate(withDuration: 0.2) {
      if hasText {
        self.vibeSubmitButton.backgroundColor = self.activeTintColor
        self.vibeIconView.tintColor = .white
      } else {
        self.vibeSubmitButton.backgroundColor =
          self.isDark
          ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.06)
        self.vibeIconView.tintColor =
          self.isDark
          ? UIColor.white.withAlphaComponent(0.6) : UIColor.black.withAlphaComponent(0.4)
      }
    }
  }

  // MARK: - Chrome Application

  private func applyChrome() {
    let blurStyle: UIBlurEffect.Style =
      isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight
    let matchingGlassColor =
      isDark ? UIColor.white.withAlphaComponent(0.16) : UIColor.black.withAlphaComponent(0.20)

    // ── 1. UITabBar natively draws its own glass ──
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.shadowColor = .clear

    // We STRICTLY do not set appearance.backgroundColor here.
    // Doing so would color the invisible bounding box and create the giant outer dark shadow you saw!

    if #available(iOS 26.0, *) {
      // If we are injecting a native glass effect internally into the UITabBar background
      // Note: UIGlassEffect belongs to UIVisualEffectView. UITabBarAppearance uses UIBlurEffect.
      appearance.backgroundEffect = UIBlurEffect(style: blurStyle)
    } else {
      appearance.backgroundEffect = UIBlurEffect(style: blurStyle)
    }

    // Using UITabBar's internal layout allows it to naturally sort out the text/icon
    // so they do not overlap when we override standard dimensions.
    let itemAppearance = appearance.stackedLayoutAppearance
    itemAppearance.normal.iconColor = inactiveTintColor
    itemAppearance.normal.titleTextAttributes = [.foregroundColor: inactiveTintColor]

    // Let UITabBar naturally center it, don't force adjustments
    itemAppearance.normal.titlePositionAdjustment = .zero
    itemAppearance.selected.iconColor = activeTintColor
    itemAppearance.selected.titleTextAttributes = [.foregroundColor: activeTintColor]
    itemAppearance.selected.titlePositionAdjustment = .zero

    appearance.stackedLayoutAppearance = itemAppearance
    appearance.inlineLayoutAppearance = itemAppearance
    appearance.compactInlineLayoutAppearance = itemAppearance

    tabBar.standardAppearance = appearance
    if #available(iOS 15.0, *) {
      tabBar.scrollEdgeAppearance = appearance
    }

    // ── 3. Vibe Button explicitly matches the exact material and tint ──
    if #available(iOS 26.0, *) {
      let vibeEffect = UIGlassEffect()
      vibeEffect.isInteractive = true
      vibeChromeView.effect = vibeEffect
    } else {
      vibeChromeView.effect = UIBlurEffect(style: blurStyle)
    }
  }

  private func updateVibeButton(for tab: ChatNativeTabItem?) {
    guard let tab else {
      vibeChromeView.isHidden = true
      return
    }

    vibeChromeView.isHidden = false

    let isActive = currentIndex == tab.index
    let foregroundColor = isActive ? activeTintColor : inactiveTintColor

    // Exclusively rely on the optimized Native SVG path.
    // This allows it to scale crisply when it transforms into a send button!
    print("[VibeTabBar] Drawing native SVG path for vibe logo")
    let image = resolveLogoImage(targetSize: CGSize(width: 26, height: 26))?.withRenderingMode(
      .alwaysTemplate)

    vibeIconView.image = image
    vibeIconView.tintColor = .white

    vibeButton.setTitle(nil, for: .normal)
    vibeButton.setImage(nil, for: .normal)
  }

  @objc
  private func handleVibePress() {
    guard let vibeTab = tabs.first(where: \.isVibe) else { return }
    if vibeTab.index != currentIndex {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    currentIndex = vibeTab.index
    applySelection()
    onIndexChange(["index": vibeTab.index])
  }

  // MARK: - Utilities

  private func fallbackSymbol(_ key: String) -> String {
    switch key.lowercased() {
    case "chat", "chats", "messages": return "bubble.left.and.bubble.right"
    case "vibe": return "sparkles"
    case "profile", "me": return "person"
    case "settings": return "gearshape"
    case "explore", "discover": return "safari"
    default: return "circle"
    }
  }

  private func resolveLogoImage(targetSize: CGSize) -> UIImage? {
    let canvasSize = CGSize(width: 699, height: 699)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = UIScreen.main.scale
    format.opaque = false

    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    return renderer.image { context in
      let cgContext = context.cgContext
      let sizeScale = min(
        targetSize.width / canvasSize.width, targetSize.height / canvasSize.height)
      let scaledWidth = canvasSize.width * sizeScale
      let scaledHeight = canvasSize.height * sizeScale
      let offsetX = (targetSize.width - scaledWidth) * 0.5
      let offsetY = (targetSize.height - scaledHeight) * 0.5
      cgContext.translateBy(x: offsetX, y: offsetY)
      cgContext.scaleBy(x: sizeScale, y: sizeScale)
      UIColor.black.setFill()

      let path1 = UIBezierPath()
      path1.move(to: CGPoint(x: 79, y: 136))
      path1.addLine(to: CGPoint(x: 230, y: 156))
      path1.addLine(to: CGPoint(x: 291, y: 286))
      path1.addLine(to: CGPoint(x: 176, y: 199))
      path1.close()
      path1.fill()

      let path2 = UIBezierPath()
      path2.move(to: CGPoint(x: 327, y: 174))
      path2.addLine(to: CGPoint(x: 540, y: 199))
      path2.addLine(to: CGPoint(x: 503, y: 321))
      path2.close()
      path2.fill()

      let path3 = UIBezierPath()
      path3.move(to: CGPoint(x: 215, y: 103))
      path3.addLine(to: CGPoint(x: 284, y: 239))
      path3.addLine(to: CGPoint(x: 328, y: 352))
      path3.addLine(to: CGPoint(x: 368, y: 492))
      path3.addLine(to: CGPoint(x: 398, y: 644))
      path3.addLine(to: CGPoint(x: 498, y: 338))
      path3.close()
      path3.fill()
    }
  }

  private func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage? {
    let size = image.size
    let widthRatio = targetSize.width / size.width
    let heightRatio = targetSize.height / size.height
    let ratio = min(widthRatio, heightRatio)
    let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
    let rect = CGRect(origin: .zero, size: newSize)

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = UIScreen.main.scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    return renderer.image { _ in image.draw(in: rect) }
  }

  private func withRoundedCorners(image: UIImage, radius: CGFloat) -> UIImage? {
    let rect = CGRect(origin: .zero, size: image.size)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = image.scale
    format.opaque = false

    let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
    return renderer.image { _ in
      UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
      image.draw(in: rect)
    }
  }

  // MARK: - Icons

  private func resolvedIcon(for item: ChatNativeTabItem) -> UIImage? {
    guard let iconUri = item.iconUri, !iconUri.isEmpty else { return nil }
    print("[VibeTabBar] resolving icon for: \(item.key) with uri: \(iconUri)")
    if let cachedRemote = remoteIconCache[iconUri] {
      print("[VibeTabBar] Found in remote cache: \(iconUri)")
      return cachedRemote
    }
    if let localImage = localImageFromURI(iconUri) {
      print("[VibeTabBar] Found local image: \(iconUri)")
      return localImage
    }
    guard let url = URL(string: iconUri), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      print("[VibeTabBar] Invalid remote URL or scheme for: \(iconUri)")
      return nil
    }
    print("[VibeTabBar] Requesting remote icon: \(iconUri)")
    requestRemoteIcon(from: url, cacheKey: iconUri)
    return nil
  }

  private func requestRemoteIcon(from url: URL, cacheKey: String) {
    guard !remoteIconRequests.contains(cacheKey) else { return }
    print("[VibeTabBar] Downloading remote image: \(url)")
    remoteIconRequests.insert(cacheKey)

    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.remoteIconRequests.remove(cacheKey)
        guard let data, let image = UIImage(data: data) else {
          print("[VibeTabBar] Failed to create UIImage from downloaded data for: \(url)")
          return
        }
        print("[VibeTabBar] Successfully downloaded & decoded image: \(url)")
        self.remoteIconCache[cacheKey] = image
        self.rebuildSegments()
      }
    }.resume()
  }

  private func localImageFromURI(_ uriString: String) -> UIImage? {
    guard !uriString.isEmpty else { return nil }
    print("[VibeTabBar] Attempting to load local image from: \(uriString)")

    if let url = URL(string: uriString) {
      if url.isFileURL {
        if let image = UIImage(contentsOfFile: url.path) {
          print("[VibeTabBar] Found local file URL image: \(url.path)")
          return image
        }
      }
      let filename = url.lastPathComponent
      let base = (filename as NSString).deletingPathExtension
      let ext = (filename as NSString).pathExtension
      if !base.isEmpty,
        let path = Bundle.main.path(forResource: base, ofType: ext.isEmpty ? nil : ext)
      {
        print("[VibeTabBar] Found image in Main Bundle: \(path)")
        return UIImage(contentsOfFile: path)
      }
    }
    if uriString.hasPrefix("/") {
      if let image = UIImage(contentsOfFile: uriString) {
        print("[VibeTabBar] Found absolute path image: \(uriString)")
        return image
      }
    }
    let localFilename = (uriString as NSString).lastPathComponent
    let localBase = (localFilename as NSString).deletingPathExtension
    if !localBase.isEmpty, let named = UIImage(named: localBase) {
      print("[VibeTabBar] Found named image: \(localBase)")
      return named
    }

    if let named = UIImage(named: uriString) {
      print("[VibeTabBar] Found exactly named image: \(uriString)")
      return named
    }

    print("[VibeTabBar] Could not find any local image for: \(uriString)")
    return nil
  }
}

public class ChatNativeTabBarModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeTabs")
    View(ChatNativeTabBarView.self) {
      Prop("tabs") { (view: ChatNativeTabBarView, tabs: [[String: Any]]) in view.setTabs(tabs) }
      Prop("currentIndex") { (view: ChatNativeTabBarView, index: Int) in view.setCurrentIndex(index)
      }
      Prop("activeTintColor") { (view: ChatNativeTabBarView, color: UIColor?) in
        view.setActiveTintColor(color)
      }
      Prop("inactiveTintColor") { (view: ChatNativeTabBarView, color: UIColor?) in
        view.setInactiveTintColor(color)
      }
      Prop("isDark") { (view: ChatNativeTabBarView, isDark: Bool) in view.setIsDark(isDark) }
      Prop("isVibeExpanded") { (view: ChatNativeTabBarView, expanded: Bool) in
        view.setVibeExpanded(expanded)
      }
      Events("onIndexChange", "onVibeSubmit")
    }
  }
}
