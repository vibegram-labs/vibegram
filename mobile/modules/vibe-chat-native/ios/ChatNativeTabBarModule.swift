import ExpoModulesCore
import UIKit

private struct ChatNativeTabItem {
  let key: String
  let title: String
  let sfSymbol: String?
  let iconUri: String?
  let badge: String?
  let isVibe: Bool
}

public final class ChatNativeTabBarView: ExpoView {
  public var onIndexChange = EventDispatcher()

  private let backgroundBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let containerStack = UIStackView()

  // System segmented control — replaces custom pill + buttons
  private let segmentedControl = UISegmentedControl()

  private var tabs: [ChatNativeTabItem] = []

  private var currentIndex = 0
  private var activeTintColor = UIColor.systemBlue
  private var inactiveTintColor = UIColor.systemGray
  private var isDark = false
  private let tabControlSide: CGFloat = 72
  private let horizontalOuterPadding: CGFloat = 18
  private let selectionFeedback = UISelectionFeedbackGenerator()
  private var remoteIconCache: [String: UIImage] = [:]
  private var remoteIconRequests: Set<String> = []

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupView()
  }

  public override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 96)
  }

  private func setupView() {
    backgroundColor = .clear
    isOpaque = false

    containerStack.axis = .horizontal
    containerStack.alignment = .center
    containerStack.distribution = .fill
    containerStack.spacing = 8
    containerStack.backgroundColor = .clear
    containerStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(containerStack)

    NSLayoutConstraint.activate([
      containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
      containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      containerStack.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: horizontalOuterPadding),
      containerStack.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -horizontalOuterPadding),
    ])

    // Glass background behind the segmented control
    backgroundBlur.translatesAutoresizingMaskIntoConstraints = false
    backgroundBlur.layer.cornerRadius = tabControlSide / 2
    backgroundBlur.layer.cornerCurve = .continuous
    backgroundBlur.clipsToBounds = true
    backgroundBlur.isUserInteractionEnabled = true

    // Segmented control setup
    segmentedControl.translatesAutoresizingMaskIntoConstraints = false
    segmentedControl.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
    backgroundBlur.contentView.addSubview(segmentedControl)

    NSLayoutConstraint.activate([
      backgroundBlur.heightAnchor.constraint(equalToConstant: tabControlSide),
      segmentedControl.topAnchor.constraint(
        equalTo: backgroundBlur.contentView.topAnchor, constant: 8),
      segmentedControl.bottomAnchor.constraint(
        equalTo: backgroundBlur.contentView.bottomAnchor, constant: -8),
      segmentedControl.leadingAnchor.constraint(
        equalTo: backgroundBlur.contentView.leadingAnchor, constant: 10),
      segmentedControl.trailingAnchor.constraint(
        equalTo: backgroundBlur.contentView.trailingAnchor, constant: -10),
    ])

    containerStack.addArrangedSubview(backgroundBlur)

    selectionFeedback.prepare()

    applyChrome()
  }

  func setTabs(_ rawTabs: [[String: Any]]) {
    tabs = rawTabs.map { raw in
      let key = (raw["key"] as? String) ?? UUID().uuidString
      let title = (raw["title"] as? String) ?? key
      let sfSymbol = raw["sfSymbol"] as? String
      let iconUri = raw["iconUri"] as? String
      let badgeValue = raw["badge"]
      let badge = badgeValue.map { String(describing: $0) }
      let isVibe = (raw["isVibe"] as? Bool) ?? false
      return ChatNativeTabItem(
        key: key, title: title, sfSymbol: sfSymbol, iconUri: iconUri, badge: badge, isVibe: isVibe)
    }

    rebuildSegments()
  }

  func setCurrentIndex(_ value: Int) {
    currentIndex = value
    applySelection()
  }

  func setActiveTintColor(_ value: UIColor?) {
    if let value {
      activeTintColor = value
      applySelection()
    }
  }

  func setInactiveTintColor(_ value: UIColor?) {
    if let value {
      inactiveTintColor = value
      applySelection()
    }
  }

  func setIsDark(_ value: Bool) {
    isDark = value
    applyChrome()
    applySelection()
  }

  @objc private func segmentChanged(_ sender: UISegmentedControl) {
    let tabIndex = sender.selectedSegmentIndex
    guard tabIndex >= 0, tabIndex < tabs.count else { return }
    if tabIndex != currentIndex {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    currentIndex = tabIndex
    applySelection()
    onIndexChange(["index": tabIndex])
  }

  private func rebuildSegments() {
    segmentedControl.removeAllSegments()
    for i in 0..<tabs.count {
      // Insert with a placeholder title; actual image is set in rebuildAndApplySegmentImages
      segmentedControl.insertSegment(withTitle: tabs[i].title, at: i, animated: false)
    }
    rebuildAndApplySegmentImages()
    applySelection()
  }

  // MARK: - Segment image rendering

  private var segmentNormalImages: [UIImage] = []
  private var segmentSelectedImages: [UIImage] = []

  private func rebuildAndApplySegmentImages() {
    let normalColor = inactiveTintColor.withAlphaComponent(isDark ? 0.78 : 0.72)
    let selectedColor = activeTintColor
    segmentNormalImages = tabs.map {
      makeSegmentImage(
        symbol: $0.sfSymbol ?? fallbackSymbol($0.key),
        title: $0.title, color: normalColor, isVibe: $0.isVibe) ?? UIImage()
    }
    segmentSelectedImages = tabs.map {
      makeSegmentImage(
        symbol: $0.sfSymbol ?? fallbackSymbol($0.key),
        title: $0.title, color: selectedColor, isVibe: $0.isVibe) ?? UIImage()
    }
    swapSegmentImages(selectedIndex: segmentedControl.selectedSegmentIndex)
  }

  private func swapSegmentImages(selectedIndex: Int) {
    for i in 0..<tabs.count {
      guard i < segmentNormalImages.count, i < segmentSelectedImages.count else { continue }
      let img = (i == selectedIndex) ? segmentSelectedImages[i] : segmentNormalImages[i]
      segmentedControl.setImage(img.withRenderingMode(.alwaysOriginal), forSegmentAt: i)
    }
  }

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

  private func resolveLogoImage() -> UIImage? {
    if let named = UIImage(named: "logotransparent") {
      return named
    }
    if let path = Bundle.main.path(forResource: "logotransparent", ofType: "png"),
      let image = UIImage(contentsOfFile: path)
    {
      return image
    }
    return nil
  }

  /// Renders an SF Symbol or image above a text label into one UIImage for use as a
  /// segment image. This gives icon + label with per-state colour control
  /// while keeping `selectedSegmentTintColor` pill rendering intact.
  private func makeSegmentImage(symbol: String, title: String, color: UIColor, isVibe: Bool)
    -> UIImage?
  {
    let fontSize: CGFloat = 11
    let gap: CGFloat = 3
    let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
    let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let textSize = (title as NSString).size(withAttributes: textAttrs)

    let iconSize: CGSize
    let iconImgToDraw: UIImage?

    if isVibe, let logo = resolveLogoImage() {
      // Use the logo image instead of a symbol
      iconSize = CGSize(width: 22, height: 22)
      iconImgToDraw = logo.withRenderingMode(.alwaysOriginal)
    } else {
      let iconPt: CGFloat = 18
      let iconCfg = UIImage.SymbolConfiguration(pointSize: iconPt, weight: .semibold)
      if let icon = UIImage(systemName: symbol, withConfiguration: iconCfg) {
        iconSize = icon.size
        iconImgToDraw = icon.withTintColor(color, renderingMode: .alwaysOriginal)
      } else {
        iconSize = .zero
        iconImgToDraw = nil
      }
    }

    let canvasW = max(iconSize.width, textSize.width) + 20
    let canvasH = iconSize.height + gap + ceil(textSize.height) + 2
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH))
    return renderer.image { _ in
      let iconX = (canvasW - iconSize.width) / 2
      if let img = iconImgToDraw {
        var alpha: CGFloat = 1.0
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        img.draw(
          in: CGRect(x: iconX, y: 1, width: iconSize.width, height: iconSize.height),
          blendMode: .normal, alpha: alpha)
      }
      let textX = (canvasW - textSize.width) / 2
      (title as NSString).draw(
        at: CGPoint(x: textX, y: 1 + iconSize.height + gap),
        withAttributes: textAttrs)
    }
  }

  private func applySelection() {
    guard !tabs.isEmpty else { return }
    let normalized = max(0, min(currentIndex, tabs.count - 1))
    if normalized != currentIndex { currentIndex = normalized }

    if segmentedControl.selectedSegmentIndex != currentIndex {
      segmentedControl.selectedSegmentIndex = currentIndex
    }

    segmentedControl.selectedSegmentTintColor =
      activeTintColor.withAlphaComponent(isDark ? 0.30 : 0.18)

    // Swap icon tint to reflect selected/unselected state
    swapSegmentImages(selectedIndex: currentIndex)
  }

  private func resolvedIcon(for item: ChatNativeTabItem) -> UIImage? {
    guard let iconUri = item.iconUri, !iconUri.isEmpty else {
      return nil
    }

    if let cachedRemote = remoteIconCache[iconUri] {
      return cachedRemote
    }

    if let localImage = localImageFromURI(iconUri) {
      return localImage
    }

    guard let url = URL(string: iconUri), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      return nil
    }

    requestRemoteIcon(from: url, cacheKey: iconUri)
    return nil
  }

  private func requestRemoteIcon(from url: URL, cacheKey: String) {
    guard !remoteIconRequests.contains(cacheKey) else { return }
    remoteIconRequests.insert(cacheKey)

    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.remoteIconRequests.remove(cacheKey)
        guard let data, let image = UIImage(data: data) else { return }
        self.remoteIconCache[cacheKey] = image
        self.rebuildSegments()
      }
    }.resume()
  }

  private func localImageFromURI(_ uriString: String) -> UIImage? {
    guard !uriString.isEmpty else { return nil }

    if let url = URL(string: uriString) {
      if url.isFileURL {
        let image = UIImage(contentsOfFile: url.path)
        if image != nil { return image }
      }

      let filename = url.lastPathComponent
      let base = (filename as NSString).deletingPathExtension
      let ext = (filename as NSString).pathExtension
      if !base.isEmpty,
        let path = Bundle.main.path(forResource: base, ofType: ext.isEmpty ? nil : ext)
      {
        return UIImage(contentsOfFile: path)
      }
    }

    if uriString.hasPrefix("/") {
      let image = UIImage(contentsOfFile: uriString)
      if image != nil { return image }
    }

    let localFilename = (uriString as NSString).lastPathComponent
    let localBase = (localFilename as NSString).deletingPathExtension
    if !localBase.isEmpty, let named = UIImage(named: localBase) {
      return named
    }

    return UIImage(named: uriString)
  }

  private func applyChrome() {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      backgroundBlur.effect = effect
    } else {
      backgroundBlur.effect = UIBlurEffect(style: .systemThinMaterial)
    }
    backgroundBlur.backgroundColor = .clear
    backgroundBlur.contentView.backgroundColor = .clear
    backgroundBlur.layer.borderWidth = 0.7
    backgroundBlur.layer.borderColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.08).cgColor
      : UIColor.black.withAlphaComponent(0.06).cgColor

    segmentedControl.backgroundColor = .clear

    // Rebuild rendered icon+text images with the current colour scheme.
    rebuildAndApplySegmentImages()
  }
}

public class ChatNativeTabBarModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeTabs")

    View(ChatNativeTabBarView.self) {
      Prop("tabs") { (view: ChatNativeTabBarView, tabs: [[String: Any]]) in
        view.setTabs(tabs)
      }

      Prop("currentIndex") { (view: ChatNativeTabBarView, index: Int) in
        view.setCurrentIndex(index)
      }

      Prop("activeTintColor") { (view: ChatNativeTabBarView, color: UIColor?) in
        view.setActiveTintColor(color)
      }

      Prop("inactiveTintColor") { (view: ChatNativeTabBarView, color: UIColor?) in
        view.setInactiveTintColor(color)
      }

      Prop("isDark") { (view: ChatNativeTabBarView, isDark: Bool) in
        view.setIsDark(isDark)
      }

      Events("onIndexChange")
    }
  }
}
