import ExpoModulesCore
import UIKit

private struct ChatNativeTabItem {
  let key: String
  let title: String
  let sfSymbol: String?
  let badge: String?
  let isVibe: Bool
}

private final class ChatNativeTabButton: UIControl {
  private let contentStack = UIStackView()
  private let iconContainer = UIView()
  private let iconView = UIImageView()
  private let badgeContainer = UIView()
  private let badgeLabel = UILabel()
  private let titleLabelView = UILabel()

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

    contentStack.axis = .vertical
    contentStack.alignment = .center
    contentStack.distribution = .fill
    contentStack.spacing = 3
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentStack)

    NSLayoutConstraint.activate([
      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
    ])

    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      iconContainer.widthAnchor.constraint(equalToConstant: 30),
      iconContainer.heightAnchor.constraint(equalToConstant: 30),
    ])
    contentStack.addArrangedSubview(iconContainer)

    iconView.translatesAutoresizingMaskIntoConstraints = false
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
    contentStack.addArrangedSubview(titleLabelView)

    badgeContainer.isHidden = true
  }

  override var isHighlighted: Bool {
    didSet {
      let isPressed = isHighlighted
      let scale: CGFloat = isPressed ? 0.88 : 1.0
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
      }
    }
  }

  func apply(
    item: ChatNativeTabItem,
    index: Int,
    focused: Bool,
    activeTintColor: UIColor,
    inactiveTintColor: UIColor
  ) {
    tabIndex = index

    let iconName = item.sfSymbol ?? "circle"
    iconView.image = UIImage(systemName: iconName)
    titleLabelView.text = item.title

    let tint = focused ? activeTintColor : inactiveTintColor
    titleLabelView.textColor = tint
    iconView.tintColor = tint

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
    addSubview(glassView)

    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 24, weight: .bold)
    glassView.contentView.addSubview(iconView)
    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: glassView.contentView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: glassView.contentView.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 26),
      iconView.heightAnchor.constraint(equalToConstant: 26),
    ])
  }

  override var isHighlighted: Bool {
    didSet {
      let isPressed = isHighlighted
      let scale: CGFloat = isPressed ? 0.88 : 1.0
      let duration: TimeInterval = isPressed ? 0.1 : 0.22
      let damping: CGFloat = isPressed ? 1.0 : 0.72
      let glassPressedOverlayColor = UIColor(white: 1.0, alpha: 0.08)

      UIView.animate(
        withDuration: duration,
        delay: 0,
        usingSpringWithDamping: damping,
        initialSpringVelocity: 0.25,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        self.iconView.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.glassView.contentView.backgroundColor = isPressed ? glassPressedOverlayColor : .clear
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
    let iconName = item.sfSymbol ?? "sparkles"
    iconView.image = UIImage(systemName: iconName)
    iconView.tintColor =
      focused
      ? activeTintColor
      : (isDark ? UIColor.white.withAlphaComponent(0.86) : UIColor.black.withAlphaComponent(0.78))
  }
}

public final class ChatNativeTabBarView: ExpoView {
  public var onIndexChange = EventDispatcher()

  private let backgroundBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let containerStack = UIStackView()
  private let stack = UIStackView()
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

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupView()
  }

  public override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 96)
  }

  private func setupView() {
    backgroundColor = .clear

    containerStack.axis = .horizontal
    containerStack.alignment = .center
    containerStack.distribution = .fill
    containerStack.spacing = 8
    containerStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(containerStack)

    NSLayoutConstraint.activate([
      containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
      containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      containerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      containerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
    ])

    backgroundBlur.translatesAutoresizingMaskIntoConstraints = false
    backgroundBlur.layer.cornerRadius = 30
    backgroundBlur.layer.cornerCurve = .continuous
    backgroundBlur.clipsToBounds = true

    stack.axis = .horizontal
    stack.alignment = .fill
    stack.distribution = .fillEqually
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    backgroundBlur.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: backgroundBlur.contentView.topAnchor, constant: 4),
      stack.bottomAnchor.constraint(equalTo: backgroundBlur.contentView.bottomAnchor, constant: -4),
      stack.leadingAnchor.constraint(
        equalTo: backgroundBlur.contentView.leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(
        equalTo: backgroundBlur.contentView.trailingAnchor, constant: -6),
    ])

    vibeButton.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      vibeButton.widthAnchor.constraint(equalToConstant: 58),
      vibeButton.heightAnchor.constraint(equalToConstant: 58),
    ])
    vibeButton.addTarget(self, action: #selector(vibeTapped), for: .touchUpInside)

    containerStack.addArrangedSubview(backgroundBlur)
    containerStack.addArrangedSubview(vibeButton)

    vibeButton.isHidden = true

    applyChrome()
  }

  func setTabs(_ rawTabs: [[String: Any]]) {
    tabs = rawTabs.map { raw in
      let key = (raw["key"] as? String) ?? UUID().uuidString
      let title = (raw["title"] as? String) ?? key
      let sfSymbol = raw["sfSymbol"] as? String
      let badgeValue = raw["badge"]
      let badge = badgeValue.map { String(describing: $0) }
      let isVibe = (raw["isVibe"] as? Bool) ?? false
      return ChatNativeTabItem(
        key: key, title: title, sfSymbol: sfSymbol, badge: badge, isVibe: isVibe)
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

  @objc private func mainTabTapped(_ sender: ChatNativeTabButton) {
    onIndexChange(["index": sender.tabIndex])
  }

  @objc private func vibeTapped() {
    guard let vibeTabIndex else { return }
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
        button.addTarget(self, action: #selector(mainTabTapped(_:)), for: .touchUpInside)
        let item = mainTabs[i]
        let tabIndex = mainTabIndexes[i]
        button.apply(
          item: item,
          index: tabIndex,
          focused: tabIndex == currentIndex,
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
        activeTintColor: activeTintColor,
        inactiveTintColor: inactiveTintColor
      )
    }

    if let vibeTab {
      let focused = vibeTabIndex == currentIndex
      vibeButton.apply(
        item: vibeTab,
        focused: focused,
        activeTintColor: activeTintColor,
        isDark: isDark
      )
    }
  }

  private func applyChrome() {
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
