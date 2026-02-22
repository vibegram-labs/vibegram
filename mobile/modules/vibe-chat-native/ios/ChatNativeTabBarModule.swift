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

private final class ChatNativeTabButton: UIControl {
  private let pressedOverlayView = UIView()
  private let contentStack = UIStackView()
  private let iconContainer = UIView()
  private let iconView = UIImageView()
  private let badgeContainer = UIView()
  private let badgeLabel = UILabel()
  private let titleLabelView = UILabel()
  private let pressedOverlayColor = UIColor(white: 1.0, alpha: 0.08)

  private(set) var tabIndex: Int = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    backgroundColor = .clear
    translatesAutoresizingMaskIntoConstraints = false

    pressedOverlayView.translatesAutoresizingMaskIntoConstraints = false
    pressedOverlayView.backgroundColor = pressedOverlayColor
    pressedOverlayView.layer.cornerCurve = .continuous
    pressedOverlayView.layer.cornerRadius = 14
    pressedOverlayView.alpha = 0
    pressedOverlayView.isUserInteractionEnabled = false
    addSubview(pressedOverlayView)

    NSLayoutConstraint.activate([
      pressedOverlayView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      pressedOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      pressedOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      pressedOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
    ])

    contentStack.axis = .vertical
    contentStack.alignment = .center
    contentStack.distribution = .fill
    contentStack.spacing = 3
    contentStack.isUserInteractionEnabled = false
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentStack)

    NSLayoutConstraint.activate([
      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
    ])

    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.isUserInteractionEnabled = false
    NSLayoutConstraint.activate([
      iconContainer.widthAnchor.constraint(equalToConstant: 30),
      iconContainer.heightAnchor.constraint(equalToConstant: 30),
    ])
    contentStack.addArrangedSubview(iconContainer)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.isUserInteractionEnabled = false
    iconView.contentMode = .scaleAspectFit
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 22, weight: .semibold)
    iconContainer.addSubview(iconView)
    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 24),
      iconView.heightAnchor.constraint(equalToConstant: 24),
    ])

    badgeContainer.translatesAutoresizingMaskIntoConstraints = false
    badgeContainer.isUserInteractionEnabled = false
    badgeContainer.backgroundColor = UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1.0)
    badgeContainer.layer.cornerRadius = 9
    badgeContainer.layer.masksToBounds = true
    iconContainer.addSubview(badgeContainer)
    NSLayoutConstraint.activate([
      badgeContainer.leadingAnchor.constraint(greaterThanOrEqualTo: iconContainer.centerXAnchor),
      badgeContainer.centerYAnchor.constraint(equalTo: iconContainer.topAnchor, constant: 4),
      badgeContainer.heightAnchor.constraint(equalToConstant: 18),
      badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
    ])

    badgeLabel.translatesAutoresizingMaskIntoConstraints = false
    badgeLabel.isUserInteractionEnabled = false
    badgeLabel.font = UIFont.systemFont(ofSize: 10, weight: .bold)
    badgeLabel.textColor = .white
    badgeLabel.textAlignment = .center
    badgeContainer.addSubview(badgeLabel)
    NSLayoutConstraint.activate([
      badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 4),
      badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -4),
      badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 1),
      badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -1),
    ])

    titleLabelView.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    titleLabelView.textAlignment = .center
    titleLabelView.numberOfLines = 1
    titleLabelView.isUserInteractionEnabled = false
    contentStack.addArrangedSubview(titleLabelView)

    badgeContainer.isHidden = true
  }

  override var isHighlighted: Bool {
    didSet {
      let isPressed = isHighlighted
      let scale: CGFloat = isPressed ? 0.96 : 1.0
      let duration: TimeInterval = isPressed ? 0.1 : 0.22
      let damping: CGFloat = isPressed ? 1.0 : 0.72

      UIView.animate(
        withDuration: duration,
        delay: 0,
        usingSpringWithDamping: damping,
        initialSpringVelocity: 0.25,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        self.iconView.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.alpha = isPressed ? 0.7 : 1.0
        self.pressedOverlayView.alpha = isPressed ? 1.0 : 0
      }
    }
  }

  func apply(
    item: ChatNativeTabItem,
    index: Int,
    focused: Bool,
    resolvedIcon: UIImage?,
    activeTintColor: UIColor,
    inactiveTintColor: UIColor
  ) {
    tabIndex = index

    if let resolvedIcon {
      iconView.image = resolvedIcon.withRenderingMode(.alwaysTemplate)
      iconView.tintColor = focused ? activeTintColor : inactiveTintColor
      iconView.alpha = 1.0
    } else {
      let iconName = item.sfSymbol ?? "circle"
      iconView.image = UIImage(systemName: iconName)
      iconView.tintColor = focused ? activeTintColor : inactiveTintColor
      iconView.alpha = 1.0
    }

    titleLabelView.text = item.title
    titleLabelView.textColor = focused ? activeTintColor : inactiveTintColor

    if let badgeText = item.badge, !badgeText.isEmpty {
      badgeContainer.isHidden = false
      badgeLabel.text = badgeText
    } else {
      badgeContainer.isHidden = true
      badgeLabel.text = nil
    }
  }
}

private final class ChatNativeVibeButton: UIControl {
  private let glassView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
  private let iconView = UIImageView()
  private let glassPressedOverlayColor = UIColor(white: 1.0, alpha: 0.08)

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    backgroundColor = .clear
    translatesAutoresizingMaskIntoConstraints = false

    glassView.translatesAutoresizingMaskIntoConstraints = false
    glassView.clipsToBounds = true
    glassView.layer.cornerCurve = .continuous
    glassView.isUserInteractionEnabled = false
    addSubview(glassView)

    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.isUserInteractionEnabled = false
    iconView.contentMode = .scaleAspectFit
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 24, weight: .bold)
    glassView.contentView.addSubview(iconView)
    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: glassView.contentView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: glassView.contentView.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 30),
      iconView.heightAnchor.constraint(equalToConstant: 30),
    ])

    refreshGlass()
  }

  override var isHighlighted: Bool {
    didSet {
      let isPressed = isHighlighted
      let scale: CGFloat = isPressed ? 0.96 : 1.0
      let duration: TimeInterval = isPressed ? 0.1 : 0.22
      let damping: CGFloat = isPressed ? 1.0 : 0.72

      UIView.animate(
        withDuration: duration,
        delay: 0,
        usingSpringWithDamping: damping,
        initialSpringVelocity: 0.25,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        self.iconView.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.glassView.contentView.backgroundColor =
          isPressed ? self.glassPressedOverlayColor : .clear
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glassView.layer.cornerRadius = bounds.height / 2
  }

  func apply(
    item: ChatNativeTabItem,
    focused: Bool,
    activeTintColor: UIColor,
    isDark: Bool
  ) {
    refreshGlass()

    if let logo = resolveLogoImage(from: item) {
      iconView.image = logo.withRenderingMode(.alwaysOriginal)
      iconView.tintColor = nil
      iconView.alpha = focused ? 1.0 : 0.82
      return
    }

    let iconName = item.sfSymbol ?? "sparkles"
    iconView.image = UIImage(systemName: iconName)
    iconView.tintColor =
      focused
      ? activeTintColor
      : (isDark ? UIColor.white.withAlphaComponent(0.86) : UIColor.black.withAlphaComponent(0.78))
    iconView.alpha = 1.0
  }

  private func refreshGlass() {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      glassView.effect = effect
      glassView.backgroundColor = .clear
    } else {
      glassView.effect = UIBlurEffect(style: .systemMaterial)
      glassView.backgroundColor = .clear
    }
  }

  private func resolveLogoImage(from item: ChatNativeTabItem) -> UIImage? {
    if let iconUri = item.iconUri, let image = imageFromURI(iconUri) {
      return image
    }
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

  private func imageFromURI(_ uriString: String) -> UIImage? {
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
}

public final class ChatNativeTabBarView: ExpoView {
  public var onIndexChange = EventDispatcher()

  private let backgroundBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let containerStack = UIStackView()
  private let stack = UIStackView()

  // The animated active tab pill
  private let activePillGlass = UIVisualEffectView(effect: nil)
  private var activePillCenterXConstraint: NSLayoutConstraint?
  private var activePillWidthConstraint: NSLayoutConstraint?

  private let vibeButton = ChatNativeVibeButton()

  private var tabs: [ChatNativeTabItem] = []
  private var mainTabs: [ChatNativeTabItem] = []
  private var mainTabIndexes: [Int] = []
  private var vibeTab: ChatNativeTabItem?
  private var vibeTabIndex: Int?
  private var buttons: [ChatNativeTabButton] = []

  private var currentIndex = 0
  private var activeTintColor = UIColor.systemBlue
  private var inactiveTintColor = UIColor.systemGray
  private var isDark = false
  private let tabControlSide: CGFloat = 64
  private let horizontalOuterPadding: CGFloat = 18
  private let horizontalInnerPadding: CGFloat = 10
  private let segmentVerticalInset: CGFloat = 4
  private let activePillHorizontalInset: CGFloat = 2
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

    backgroundBlur.translatesAutoresizingMaskIntoConstraints = false
    backgroundBlur.layer.cornerRadius = tabControlSide / 2
    backgroundBlur.layer.cornerCurve = .continuous
    backgroundBlur.clipsToBounds = true
    backgroundBlur.isUserInteractionEnabled = true

    activePillGlass.translatesAutoresizingMaskIntoConstraints = false
    activePillGlass.isUserInteractionEnabled = false
    activePillGlass.clipsToBounds = true
    activePillGlass.layer.cornerCurve = .continuous
    backgroundBlur.contentView.addSubview(activePillGlass)

    stack.axis = .horizontal
    stack.alignment = .fill
    stack.distribution = .fillEqually
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.isUserInteractionEnabled = true
    backgroundBlur.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      backgroundBlur.heightAnchor.constraint(equalToConstant: tabControlSide),
      stack.topAnchor.constraint(
        equalTo: backgroundBlur.contentView.topAnchor, constant: segmentVerticalInset),
      stack.bottomAnchor.constraint(
        equalTo: backgroundBlur.contentView.bottomAnchor, constant: -segmentVerticalInset),
      stack.leadingAnchor.constraint(
        equalTo: backgroundBlur.contentView.leadingAnchor, constant: horizontalInnerPadding),
      stack.trailingAnchor.constraint(
        equalTo: backgroundBlur.contentView.trailingAnchor, constant: -horizontalInnerPadding),

      activePillGlass.topAnchor.constraint(
        equalTo: backgroundBlur.contentView.topAnchor, constant: segmentVerticalInset),
      activePillGlass.bottomAnchor.constraint(
        equalTo: backgroundBlur.contentView.bottomAnchor, constant: -segmentVerticalInset),
    ])

    // Initial dummy constraints for pill width/X
    activePillWidthConstraint = activePillGlass.widthAnchor.constraint(equalToConstant: 0)
    activePillCenterXConstraint = activePillGlass.centerXAnchor.constraint(
      equalTo: backgroundBlur.contentView.leadingAnchor)
    activePillWidthConstraint?.isActive = true
    activePillCenterXConstraint?.isActive = true

    vibeButton.translatesAutoresizingMaskIntoConstraints = false
    vibeButton.setContentHuggingPriority(.required, for: .horizontal)
    vibeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      vibeButton.widthAnchor.constraint(equalToConstant: tabControlSide),
      vibeButton.heightAnchor.constraint(equalToConstant: tabControlSide),
    ])
    vibeButton.addTarget(self, action: #selector(vibeTapped), for: .touchUpInside)
    vibeButton.addTarget(self, action: #selector(vibeTapped), for: .primaryActionTriggered)

    containerStack.addArrangedSubview(backgroundBlur)
    containerStack.addArrangedSubview(vibeButton)

    vibeButton.isHidden = true
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

    if let vibeIndex = tabs.firstIndex(where: { $0.isVibe }) {
      vibeTabIndex = vibeIndex
      vibeTab = tabs[vibeIndex]
    } else {
      vibeTabIndex = nil
      vibeTab = nil
    }

    let filtered = tabs.enumerated().filter { !$0.element.isVibe }
    mainTabs = filtered.map(\.element)
    mainTabIndexes = filtered.map(\.offset)

    rebuildButtons()
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

  @objc private func mainTabTapped(_ sender: UIControl) {
    guard let button = sender as? ChatNativeTabButton else { return }
    if button.tabIndex != currentIndex {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    onIndexChange(["index": button.tabIndex])
  }

  @objc private func vibeTapped() {
    guard let vibeTabIndex else { return }
    if vibeTabIndex != currentIndex {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    onIndexChange(["index": vibeTabIndex])
  }

  private func rebuildButtons() {
    buttons.removeAll()
    stack.arrangedSubviews.forEach { view in
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    if !mainTabs.isEmpty {
      for i in 0..<mainTabs.count {
        let button = ChatNativeTabButton()
        button.isUserInteractionEnabled = true
        button.addTarget(self, action: #selector(mainTabTapped(_:)), for: .touchUpInside)
        button.addTarget(self, action: #selector(mainTabTapped(_:)), for: .primaryActionTriggered)
        let item = mainTabs[i]
        let tabIndex = mainTabIndexes[i]
        button.apply(
          item: item,
          index: tabIndex,
          focused: tabIndex == currentIndex,
          resolvedIcon: resolvedIcon(for: item),
          activeTintColor: activeTintColor,
          inactiveTintColor: inactiveTintColor
        )
        buttons.append(button)
        stack.addArrangedSubview(button)
      }
    }

    vibeButton.isHidden = vibeTab == nil
    applySelection()
  }

  private func applySelection() {
    guard !tabs.isEmpty else { return }
    let normalized = max(0, min(currentIndex, tabs.count - 1))
    if normalized != currentIndex {
      currentIndex = normalized
    }

    for button in buttons {
      let index = button.tabIndex
      guard index >= 0, index < tabs.count else { continue }
      button.apply(
        item: tabs[index],
        index: index,
        focused: index == currentIndex,
        resolvedIcon: resolvedIcon(for: tabs[index]),
        activeTintColor: isDark ? .white : .black,
        inactiveTintColor: inactiveTintColor
      )
    }

    if let vibeTab {
      let focused = vibeTabIndex == currentIndex
      vibeButton.apply(
        item: vibeTab,
        focused: focused,
        activeTintColor: isDark ? .white : .black,
        isDark: isDark
      )
    }

    animatePillToActiveTab()
  }

  private func animatePillToActiveTab() {
    layoutIfNeeded()
    guard let targetButton = buttons.first(where: { $0.tabIndex == currentIndex }) else {
      activePillGlass.alpha = 0
      return
    }

    activePillGlass.alpha = 1
    let buttonCenter = targetButton.convert(
      CGPoint(x: targetButton.bounds.midX, y: targetButton.bounds.midY),
      to: backgroundBlur.contentView)

    // Leave a slight inset so the selected segment reads like UISegmentedControl.
    activePillWidthConstraint?.constant = max(
      0, targetButton.bounds.width - (activePillHorizontalInset * 2))
    activePillCenterXConstraint?.isActive = false
    activePillCenterXConstraint = activePillGlass.centerXAnchor.constraint(
      equalTo: backgroundBlur.contentView.leadingAnchor, constant: buttonCenter.x)
    activePillCenterXConstraint?.isActive = true

    // Animate the pill constraint change
    UIView.animate(
      withDuration: 0.22,
      delay: 0,
      options: [.curveEaseInOut, .beginFromCurrentState]
    ) {
      self.layoutIfNeeded()
    }
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    let radius = activePillGlass.bounds.height / 2
    activePillGlass.layer.cornerRadius = radius
    if #available(iOS 26.0, *) {
      activePillGlass.cornerConfiguration = .uniformCorners(radius: .fixed(Double(radius)))
    }
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
        self.applySelection()
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

      // Match UISegmentedControl selectedSegmentTintColor more closely:
      // plain tinted capsule over the glass container (no extra glass inside the pill).
      activePillGlass.effect = nil
      activePillGlass.backgroundColor = .clear
      activePillGlass.contentView.backgroundColor =
        isDark
        ? UIColor.white.withAlphaComponent(0.16)
        : UIColor.black.withAlphaComponent(0.10)
    } else {
      backgroundBlur.effect = UIBlurEffect(style: .systemThinMaterial)

      activePillGlass.effect = nil
      activePillGlass.backgroundColor = .clear
      activePillGlass.contentView.backgroundColor =
        isDark
        ? UIColor.white.withAlphaComponent(0.16)
        : UIColor.black.withAlphaComponent(0.10)
    }
    backgroundBlur.backgroundColor = .clear
    activePillGlass.backgroundColor = .clear
    backgroundBlur.contentView.backgroundColor = .clear
    backgroundBlur.layer.borderWidth = 0.7
    backgroundBlur.layer.borderColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.08).cgColor
      : UIColor.black.withAlphaComponent(0.06).cgColor
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
