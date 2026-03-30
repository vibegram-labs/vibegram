import UIKit

private func chatNativeAgentBuilderThemeColor(_ hex: String) -> UIColor {
  let sanitized =
    hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
      of: "#", with: "")
  guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else {
    return .systemBackground
  }

  return UIColor(
    red: CGFloat((value >> 16) & 0xff) / 255.0,
    green: CGFloat((value >> 8) & 0xff) / 255.0,
    blue: CGFloat(value & 0xff) / 255.0,
    alpha: 1.0
  )
}

private func chatNativeAgentNormalizedString(_ value: Any?) -> String? {
  if let string = value as? String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if let number = value as? NSNumber {
    return number.stringValue
  }
  return nil
}

private func chatNativeAgentStatusTitle(_ status: String) -> String {
  status
    .replacingOccurrences(of: "_", with: " ")
    .split(separator: " ")
    .map { $0.capitalized }
    .joined(separator: " ")
}

private func chatNativeAgentInitials(_ value: String) -> String {
  let words =
    value
    .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    .map(String.init)
  let initials = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
  if !initials.isEmpty {
    return initials
  }
  return String(value.prefix(1)).uppercased()
}

private func chatNativeAgentMaskedSecret(_ hint: String?) -> String {
  let suffix =
    hint?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: " ", with: "")
    ?? ""
  let normalizedSuffix =
    suffix.isEmpty
    ? ""
    : (suffix.hasPrefix("-") ? suffix : "-\(suffix)")
  return "vas_\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(normalizedSuffix)"
}

private func chatNativeAgentNormalizeEventInboxMode(_ value: String?) -> String {
  switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "batched_summary", "batched", "batch", "summary":
    return "batched_summary"
  default:
    return "per_event"
  }
}

private func chatNativeAgentNormalizeSummaryWindowHours(_ value: Int?) -> Int {
  switch value ?? 24 {
  case ...4:
    return 4
  default:
    return 24
  }
}

private func chatNativeAgentEventInboxTitle(mode: String, summaryWindowHours: Int) -> String {
  let normalizedMode = chatNativeAgentNormalizeEventInboxMode(mode)
  let normalizedHours = chatNativeAgentNormalizeSummaryWindowHours(summaryWindowHours)

  if normalizedMode == "batched_summary" {
    return normalizedHours <= 4 ? "Batch summary every 4h" : "Daily batch summary"
  }

  return "Event bubbles"
}

private func chatNativeAgentIncomingChatTitle(_ enabled: Bool) -> String {
  enabled ? "Accepted" : "Disabled"
}

private func chatNativeAgentInteger(_ value: Any?) -> Int? {
  if let number = value as? NSNumber {
    return number.intValue
  }
  if let number = value as? Int {
    return number
  }
  if let number = value as? Double, number.isFinite {
    return Int(number)
  }
  if let string = value as? String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch trimmed {
    case "4h":
      return 4
    case "daily", "24h":
      return 24
    default:
      return Int(trimmed)
    }
  }
  return nil
}

private func chatNativeAgentBoolean(_ value: Any?) -> Bool? {
  if let value = value as? Bool {
    return value
  }
  if let value = value as? NSNumber {
    return value.boolValue
  }
  if let value = value as? String {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
      return true
    case "0", "false", "no", "off":
      return false
    default:
      return nil
    }
  }
  return nil
}

struct ChatNativeAgentConfigAPIContext {
  let apiBaseURL: URL
  let token: String
}

private struct ChatNativeAgentConfigTheme {
  let panelTheme: ChatBuilderPanelTheme
  let destructiveColor: UIColor
  let primaryButtonColor: UIColor
  let secondaryButtonColor: UIColor

  init(appearance: ChatListAppearance) {
    let isDarkTheme = appearance.isDark
    panelTheme = ChatBuilderPanelTheme(
      isDark: isDarkTheme,
      backgroundColor: chatNativeAgentBuilderThemeColor(isDarkTheme ? "#121212" : "#F5F4F1"),
      cardColor: chatNativeAgentBuilderThemeColor(isDarkTheme ? "#242424" : "#FFFFFF"),
      inputColor: chatNativeAgentBuilderThemeColor(isDarkTheme ? "#222222" : "#F2F2F2"),
      textColor: chatNativeAgentBuilderThemeColor(isDarkTheme ? "#E8E6F0" : "#1A1A1F"),
      secondaryTextColor: chatNativeAgentBuilderThemeColor(isDarkTheme ? "#9896A8" : "#5A5A66"),
      accentColor: chatNativeAgentBuilderThemeColor(isDarkTheme ? "#7CB8B8" : "#4A8D8E")
    )
    destructiveColor = UIColor.systemRed
    primaryButtonColor = chatNativeAgentBuilderThemeColor(isDarkTheme ? "#4E8ED7" : "#4D8BDA")
    secondaryButtonColor = chatNativeAgentBuilderThemeColor(isDarkTheme ? "#C96B5C" : "#D27465")
  }

  var backgroundColor: UIColor { panelTheme.backgroundColor }
  var cardColor: UIColor { panelTheme.cardColor }
  var inputColor: UIColor { panelTheme.inputColor }
  var textColor: UIColor { panelTheme.textColor }
  var secondaryTextColor: UIColor { panelTheme.secondaryTextColor }
  var accentColor: UIColor { panelTheme.accentColor }
}

private final class ChatNativeAgentConfigSectionView: UIView {
  let contentStack = UIStackView()

  init(title: String?, theme: ChatNativeAgentConfigTheme) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let cardView = UIView()
    cardView.translatesAutoresizingMaskIntoConstraints = false
    cardView.backgroundColor = theme.cardColor
    cardView.layer.cornerRadius = 24.0
    cardView.layer.cornerCurve = .continuous
    addSubview(cardView)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 0.0
    cardView.addSubview(contentStack)

    var constraints = [
      cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
      cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
      contentStack.topAnchor.constraint(equalTo: cardView.topAnchor),
      contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
      contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
    ]

    if let title, !title.isEmpty {
      let titleLabel = UILabel()
      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = .systemFont(ofSize: 12.0, weight: .semibold)
      titleLabel.textColor = theme.secondaryTextColor
      titleLabel.text = title.uppercased()
      addSubview(titleLabel)

      constraints.append(contentsOf: [
        titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4.0),
        titleLabel.topAnchor.constraint(equalTo: topAnchor),
        cardView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8.0),
      ])
    } else {
      constraints.append(cardView.topAnchor.constraint(equalTo: topAnchor))
    }

    NSLayoutConstraint.activate(constraints)
  }

  required init?(coder: NSCoder) {
    return nil
  }
}

private final class ChatNativeAgentConfigRow: UIControl {
  private let highlightView = UIView()
  private let iconContainer = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let accessoryView = UIImageView()
  private let dividerView = UIView()

  var onTap: (() -> Void)?

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.14) {
        self.highlightView.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  init(
    title: String,
    value: String?,
    theme: ChatNativeAgentConfigTheme,
    symbolName: String? = nil,
    showsChevron: Bool,
    showsAccessory: Bool = true,
    showsDivider: Bool = true,
    destructive: Bool = false
  ) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    highlightView.translatesAutoresizingMaskIntoConstraints = false
    highlightView.backgroundColor = theme.textColor.withAlphaComponent(0.05)
    highlightView.alpha = 0.0
    addSubview(highlightView)

    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.backgroundColor =
      destructive
      ? theme.destructiveColor.withAlphaComponent(0.12)
      : theme.inputColor
    iconContainer.layer.cornerRadius = 14.0
    iconContainer.layer.cornerCurve = .continuous
    iconContainer.isHidden = symbolName == nil
    addSubview(iconContainer)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image =
      symbolName.flatMap {
        UIImage(
          systemName: $0,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)
        )
      }
    iconView.tintColor =
      destructive
      ? theme.destructiveColor.withAlphaComponent(0.90)
      : theme.secondaryTextColor.withAlphaComponent(0.92)
    iconContainer.addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
    titleLabel.textColor = destructive ? theme.destructiveColor : theme.textColor
    titleLabel.numberOfLines = 1
    titleLabel.text = title
    addSubview(titleLabel)

    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    valueLabel.font = .systemFont(ofSize: 15.0, weight: .regular)
    valueLabel.textColor =
      destructive ? theme.destructiveColor.withAlphaComponent(0.80) : theme.secondaryTextColor
    valueLabel.numberOfLines = 2
    valueLabel.textAlignment = .right
    valueLabel.lineBreakMode = .byTruncatingMiddle
    valueLabel.text = value
    valueLabel.isHidden = value == nil
    addSubview(valueLabel)

    accessoryView.translatesAutoresizingMaskIntoConstraints = false
    accessoryView.image = UIImage(
      systemName: showsChevron ? "chevron.right" : "doc.on.doc",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)
    )
    accessoryView.tintColor =
      destructive
      ? theme.destructiveColor.withAlphaComponent(0.72)
      : theme.secondaryTextColor.withAlphaComponent(showsChevron ? 0.55 : 0.58)
    accessoryView.isHidden = !showsAccessory
    addSubview(accessoryView)

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    dividerView.backgroundColor = theme.secondaryTextColor.withAlphaComponent(0.12)
    dividerView.isHidden = !showsDivider
    addSubview(dividerView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 60.0),
      highlightView.topAnchor.constraint(equalTo: topAnchor),
      highlightView.leadingAnchor.constraint(equalTo: leadingAnchor),
      highlightView.trailingAnchor.constraint(equalTo: trailingAnchor),
      highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconContainer.widthAnchor.constraint(equalToConstant: 28.0),
      iconContainer.heightAnchor.constraint(equalToConstant: 28.0),

      iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      iconView.widthAnchor.constraint(lessThanOrEqualToConstant: 18.0),
      iconView.heightAnchor.constraint(lessThanOrEqualToConstant: 18.0),

      accessoryView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      accessoryView.centerYAnchor.constraint(equalTo: centerYAnchor),
      accessoryView.widthAnchor.constraint(equalToConstant: 18.0),
      accessoryView.heightAnchor.constraint(equalToConstant: 18.0),

      valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12.0),

      dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 0.5),
    ])

    if symbolName != nil {
      titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12.0)
        .isActive = true
    } else {
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0).isActive = true
    }

    titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true

    if showsAccessory {
      valueLabel.trailingAnchor.constraint(equalTo: accessoryView.leadingAnchor, constant: -8.0)
        .isActive = true
    } else {
      valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0).isActive = true
    }

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  @objc private func handleTap() {
    onTap?()
  }
}

private final class ChatNativeAgentHeroHeaderView: UIView {
  private let badgeOuterView = UIView()
  private let badgeInnerView = UIView()
  private let badgeLabel = UILabel()
  private let nameLabel = UILabel()
  private let handleLabel = UILabel()
  private let metaLabel = UILabel()
  private let statusLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    badgeOuterView.translatesAutoresizingMaskIntoConstraints = false
    badgeOuterView.layer.cornerRadius = 44.0
    badgeOuterView.layer.cornerCurve = .continuous
    addSubview(badgeOuterView)

    badgeInnerView.translatesAutoresizingMaskIntoConstraints = false
    badgeInnerView.layer.cornerRadius = 36.0
    badgeInnerView.layer.cornerCurve = .continuous
    badgeOuterView.addSubview(badgeInnerView)

    badgeLabel.translatesAutoresizingMaskIntoConstraints = false
    badgeLabel.font = .systemFont(ofSize: 28.0, weight: .semibold)
    badgeLabel.textAlignment = .center
    badgeInnerView.addSubview(badgeLabel)

    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.font = .systemFont(ofSize: 31.0, weight: .bold)
    nameLabel.textAlignment = .center
    nameLabel.numberOfLines = 2
    addSubview(nameLabel)

    handleLabel.translatesAutoresizingMaskIntoConstraints = false
    handleLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
    handleLabel.textAlignment = .center
    handleLabel.numberOfLines = 1
    addSubview(handleLabel)

    metaLabel.translatesAutoresizingMaskIntoConstraints = false
    metaLabel.font = .systemFont(ofSize: 13.0, weight: .regular)
    metaLabel.textAlignment = .center
    metaLabel.numberOfLines = 2
    addSubview(metaLabel)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .systemFont(ofSize: 12.0, weight: .semibold)
    statusLabel.textAlignment = .center
    statusLabel.layer.cornerRadius = 10.0
    statusLabel.layer.cornerCurve = .continuous
    statusLabel.clipsToBounds = true
    addSubview(statusLabel)

    NSLayoutConstraint.activate([
      badgeOuterView.topAnchor.constraint(equalTo: topAnchor),
      badgeOuterView.centerXAnchor.constraint(equalTo: centerXAnchor),
      badgeOuterView.widthAnchor.constraint(equalToConstant: 88.0),
      badgeOuterView.heightAnchor.constraint(equalToConstant: 88.0),

      badgeInnerView.centerXAnchor.constraint(equalTo: badgeOuterView.centerXAnchor),
      badgeInnerView.centerYAnchor.constraint(equalTo: badgeOuterView.centerYAnchor),
      badgeInnerView.widthAnchor.constraint(equalToConstant: 72.0),
      badgeInnerView.heightAnchor.constraint(equalToConstant: 72.0),

      badgeLabel.centerXAnchor.constraint(equalTo: badgeInnerView.centerXAnchor),
      badgeLabel.centerYAnchor.constraint(equalTo: badgeInnerView.centerYAnchor),

      nameLabel.topAnchor.constraint(equalTo: badgeOuterView.bottomAnchor, constant: 18.0),
      nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12.0),
      nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12.0),

      handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6.0),
      handleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12.0),
      handleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12.0),

      metaLabel.topAnchor.constraint(equalTo: handleLabel.bottomAnchor, constant: 8.0),
      metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18.0),
      metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18.0),

      statusLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 12.0),
      statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      statusLabel.heightAnchor.constraint(equalToConstant: 28.0),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 48.0),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48.0),
    ])
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyTheme(_ theme: ChatNativeAgentConfigTheme) {
    badgeOuterView.backgroundColor = theme.inputColor
    badgeInnerView.backgroundColor = theme.backgroundColor.withAlphaComponent(theme.panelTheme.isDark ? 0.92 : 0.84)
    badgeLabel.textColor = theme.textColor
    nameLabel.textColor = theme.textColor
    handleLabel.textColor = theme.secondaryTextColor
    metaLabel.textColor = theme.secondaryTextColor.withAlphaComponent(0.84)
    statusLabel.backgroundColor = theme.inputColor
    statusLabel.textColor = theme.textColor
  }

  func configure(card: ChatListRow.AgentCard) {
    badgeLabel.text = chatNativeAgentInitials(card.displayName)
    nameLabel.text = card.displayName
    handleLabel.text = card.username.flatMap { "@\($0)" } ?? card.identifier
    metaLabel.text = "Agent ID \(card.agentId)"
    statusLabel.text = "  \(chatNativeAgentStatusTitle(card.status))  "
  }
}

private final class ChatNativeAgentActionButton: UIButton {
  init(title: String, fillColor: UIColor, foregroundColor: UIColor = .white) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.baseBackgroundColor = fillColor
    configuration.baseForegroundColor = foregroundColor
    configuration.cornerStyle = .large
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12.0,
      leading: 18.0,
      bottom: 12.0,
      trailing: 18.0
    )
    self.configuration = configuration
    titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
  }

  required init?(coder: NSCoder) {
    return nil
  }
}

private final class ChatNativeAgentSecretCardView: UIView {
  private let cardView = UIView()
  private let titleStack = UIStackView()
  private let titleIconView = UIImageView()
  private let titleLabel = UILabel()
  private let tokenSurfaceView = UIVisualEffectView(effect: nil)
  private let tokenLabel = UILabel()
  private let revealCanvasEffectView = UIVisualEffectView(effect: nil)
  private let revealCanvasTintView = UIView()
  private let revealOverlayButton = UIControl()
  private let buttonsStack = UIStackView()
  private let copyButton = ChatNativeAgentActionButton(
    title: "Copy",
    fillColor: .systemBlue
  )
  private let rotateButton = ChatNativeAgentActionButton(
    title: "Rotate",
    fillColor: .systemRed
  )
  private let descriptionLabel = UILabel()

  var onReveal: (() -> Void)?
  var onCopy: (() -> Void)?
  var onRotate: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    cardView.translatesAutoresizingMaskIntoConstraints = false
    cardView.layer.cornerRadius = 24.0
    cardView.layer.cornerCurve = .continuous
    addSubview(cardView)

    titleStack.translatesAutoresizingMaskIntoConstraints = false
    titleStack.axis = .horizontal
    titleStack.alignment = .center
    titleStack.spacing = 10.0
    cardView.addSubview(titleStack)

    titleIconView.translatesAutoresizingMaskIntoConstraints = false
    titleIconView.image = UIImage(
      systemName: "key.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)
    )
    titleStack.addArrangedSubview(titleIconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.text = "Invoke Secret"
    titleStack.addArrangedSubview(titleLabel)

    tokenSurfaceView.translatesAutoresizingMaskIntoConstraints = false
    tokenSurfaceView.layer.cornerRadius = 18.0
    tokenSurfaceView.layer.cornerCurve = .continuous
    tokenSurfaceView.clipsToBounds = true
    cardView.addSubview(tokenSurfaceView)

    tokenLabel.translatesAutoresizingMaskIntoConstraints = false
    tokenLabel.font = .monospacedSystemFont(ofSize: 15.0, weight: .semibold)
    tokenLabel.textAlignment = .center
    tokenLabel.adjustsFontSizeToFitWidth = true
    tokenLabel.minimumScaleFactor = 0.58
    tokenLabel.lineBreakMode = .byClipping
    tokenLabel.numberOfLines = 1
    tokenSurfaceView.contentView.addSubview(tokenLabel)

    revealCanvasEffectView.translatesAutoresizingMaskIntoConstraints = false
    revealCanvasEffectView.isUserInteractionEnabled = false
    revealCanvasEffectView.layer.cornerRadius = 18.0
    revealCanvasEffectView.layer.cornerCurve = .continuous
    revealCanvasEffectView.clipsToBounds = true
    cardView.addSubview(revealCanvasEffectView)

    revealCanvasTintView.translatesAutoresizingMaskIntoConstraints = false
    revealCanvasEffectView.contentView.addSubview(revealCanvasTintView)

    revealOverlayButton.translatesAutoresizingMaskIntoConstraints = false
    cardView.addSubview(revealOverlayButton)

    buttonsStack.translatesAutoresizingMaskIntoConstraints = false
    buttonsStack.axis = .horizontal
    buttonsStack.spacing = 10.0
    buttonsStack.distribution = .fillEqually
    cardView.addSubview(buttonsStack)
    buttonsStack.addArrangedSubview(copyButton)
    buttonsStack.addArrangedSubview(rotateButton)

    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    descriptionLabel.font = .systemFont(ofSize: 13.0, weight: .regular)
    descriptionLabel.numberOfLines = 0
    descriptionLabel.textAlignment = .left
    descriptionLabel.text =
      "Use this secret to authenticate backend calls to the agent. Keep it private and rotate it if you think it was exposed."
    cardView.addSubview(descriptionLabel)

    NSLayoutConstraint.activate([
      cardView.topAnchor.constraint(equalTo: topAnchor),
      cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
      cardView.bottomAnchor.constraint(equalTo: bottomAnchor),

      titleStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18.0),
      titleStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18.0),
      titleStack.trailingAnchor.constraint(lessThanOrEqualTo: cardView.trailingAnchor, constant: -18.0),

      tokenSurfaceView.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 14.0),
      tokenSurfaceView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18.0),
      tokenSurfaceView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18.0),
      tokenSurfaceView.heightAnchor.constraint(equalToConstant: 54.0),

      tokenLabel.leadingAnchor.constraint(equalTo: tokenSurfaceView.contentView.leadingAnchor, constant: 14.0),
      tokenLabel.trailingAnchor.constraint(equalTo: tokenSurfaceView.contentView.trailingAnchor, constant: -14.0),
      tokenLabel.centerYAnchor.constraint(equalTo: tokenSurfaceView.contentView.centerYAnchor),

      revealCanvasEffectView.topAnchor.constraint(equalTo: tokenSurfaceView.topAnchor),
      revealCanvasEffectView.leadingAnchor.constraint(equalTo: tokenSurfaceView.leadingAnchor),
      revealCanvasEffectView.trailingAnchor.constraint(equalTo: tokenSurfaceView.trailingAnchor),
      revealCanvasEffectView.bottomAnchor.constraint(equalTo: tokenSurfaceView.bottomAnchor),

      revealCanvasTintView.topAnchor.constraint(equalTo: revealCanvasEffectView.contentView.topAnchor),
      revealCanvasTintView.leadingAnchor.constraint(equalTo: revealCanvasEffectView.contentView.leadingAnchor),
      revealCanvasTintView.trailingAnchor.constraint(equalTo: revealCanvasEffectView.contentView.trailingAnchor),
      revealCanvasTintView.bottomAnchor.constraint(equalTo: revealCanvasEffectView.contentView.bottomAnchor),

      revealOverlayButton.topAnchor.constraint(equalTo: tokenSurfaceView.topAnchor),
      revealOverlayButton.leadingAnchor.constraint(equalTo: tokenSurfaceView.leadingAnchor),
      revealOverlayButton.trailingAnchor.constraint(equalTo: tokenSurfaceView.trailingAnchor),
      revealOverlayButton.bottomAnchor.constraint(equalTo: tokenSurfaceView.bottomAnchor),

      buttonsStack.topAnchor.constraint(equalTo: tokenSurfaceView.bottomAnchor, constant: 12.0),
      buttonsStack.leadingAnchor.constraint(equalTo: tokenSurfaceView.leadingAnchor),
      buttonsStack.trailingAnchor.constraint(equalTo: tokenSurfaceView.trailingAnchor),

      descriptionLabel.topAnchor.constraint(equalTo: buttonsStack.bottomAnchor, constant: 14.0),
      descriptionLabel.leadingAnchor.constraint(equalTo: tokenSurfaceView.leadingAnchor),
      descriptionLabel.trailingAnchor.constraint(equalTo: tokenSurfaceView.trailingAnchor),
      descriptionLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18.0),
    ])

    revealOverlayButton.addTarget(self, action: #selector(handleRevealPressed), for: .touchUpInside)
    copyButton.addTarget(self, action: #selector(handleCopyPressed), for: .touchUpInside)
    rotateButton.addTarget(self, action: #selector(handleRotatePressed), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyTheme(_ theme: ChatNativeAgentConfigTheme) {
    cardView.backgroundColor = theme.cardColor
    titleIconView.tintColor = theme.secondaryTextColor
    titleLabel.textColor = theme.textColor
    tokenLabel.textColor = theme.textColor
    descriptionLabel.textColor = theme.secondaryTextColor
    revealCanvasTintView.backgroundColor = theme.backgroundColor.withAlphaComponent(
      theme.panelTheme.isDark ? 0.22 : 0.12)

    var copyConfiguration = copyButton.configuration
    copyConfiguration?.baseBackgroundColor = theme.primaryButtonColor
    copyButton.configuration = copyConfiguration

    var rotateConfiguration = rotateButton.configuration
    rotateConfiguration?.baseBackgroundColor = theme.secondaryButtonColor
    rotateButton.configuration = rotateConfiguration

    if #available(iOS 26.0, *) {
      let tokenEffect = UIGlassEffect()
      tokenEffect.isInteractive = false
      tokenSurfaceView.effect = tokenEffect

      let overlayEffect = UIGlassEffect()
      overlayEffect.isInteractive = false
      revealCanvasEffectView.effect = overlayEffect
    } else {
      tokenSurfaceView.effect = UIBlurEffect(
        style: theme.panelTheme.isDark ? .systemMaterialDark : .systemMaterialLight
      )
      revealCanvasEffectView.effect = UIBlurEffect(
        style: theme.panelTheme.isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight
      )
    }

    tokenSurfaceView.contentView.backgroundColor = theme.inputColor.withAlphaComponent(
      theme.panelTheme.isDark ? 0.42 : 0.78)
  }

  func configure(
    secret: String?,
    hint: String?,
    isLoading: Bool,
    isRevealed: Bool,
    canReveal: Bool
  ) {
    tokenLabel.text = secret ?? chatNativeAgentMaskedSecret(hint)
    let coverHidden = isRevealed || !canReveal
    revealCanvasEffectView.isHidden = coverHidden
    revealOverlayButton.isHidden = coverHidden
    revealOverlayButton.isUserInteractionEnabled = !isLoading && canReveal
    revealCanvasEffectView.alpha = isLoading ? 0.92 : 1.0
    copyButton.isEnabled = !isLoading
    rotateButton.isEnabled = !isLoading
    copyButton.alpha = copyButton.isEnabled ? 1.0 : 0.6
    rotateButton.alpha = rotateButton.isEnabled ? 1.0 : 0.6
  }

  @objc private func handleRevealPressed() {
    onReveal?()
  }

  @objc private func handleCopyPressed() {
    onCopy?()
  }

  @objc private func handleRotatePressed() {
    onRotate?()
  }
}

private final class ChatNativeAgentPromptViewController: UIViewController {
  private let prompt: String
  private let theme: ChatNativeAgentConfigTheme
  private let textView = UITextView()

  init(prompt: String, theme: ChatNativeAgentConfigTheme) {
    self.prompt = prompt
    self.theme = theme
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    title = "Prompt"

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.backgroundColor = theme.inputColor
    textView.textColor = theme.textColor
    textView.font = .systemFont(ofSize: 15.0, weight: .regular)
    textView.layer.cornerRadius = 16.0
    textView.layer.cornerCurve = .continuous
    textView.isEditable = false
    textView.text = prompt
    textView.textContainerInset = UIEdgeInsets(top: 16.0, left: 14.0, bottom: 16.0, right: 14.0)
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16.0),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),
      textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16.0),
    ])
  }
}

final class ChatNativeAgentConfigPanelController: UIViewController {
  private var card: ChatListRow.AgentCard
  private let apiContext: ChatNativeAgentConfigAPIContext?
  private let theme: ChatNativeAgentConfigTheme
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let stackView = UIStackView()
  private let secretCardView = ChatNativeAgentSecretCardView()
  private let topMaskView = UIView()
  private let bottomMaskView = UIView()
  private let topMaskGradient = CAGradientLayer()
  private let bottomMaskGradient = CAGradientLayer()

  private var currentSecret: String?
  private var isSecretLoading = false
  private var isSecretRevealed = false
  private var activeSecretRequest: URLSessionDataTask?

  var onToast: ((String) -> Void)?
  var onDeleteAgent: ((ChatListRow.AgentCard, @escaping () -> Void) -> Void)?

  init(
    card: ChatListRow.AgentCard,
    appearance: ChatListAppearance,
    apiContext: ChatNativeAgentConfigAPIContext? = nil
  ) {
    self.card = card
    self.apiContext = apiContext
    self.theme = ChatNativeAgentConfigTheme(appearance: appearance)
    self.currentSecret = card.latestSecret
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    activeSecretRequest?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    configureNavigation()
    configureLayout()
    configureEdgeMasks()
    buildContent()
    configureCallbacks()
    refreshHeaderAndSecret()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutEdgeMasks()
  }

  private func configureNavigation() {
    title = ""
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = theme.backgroundColor
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: theme.textColor]
    navigationController?.navigationBar.standardAppearance = appearance
    navigationController?.navigationBar.scrollEdgeAppearance = appearance
    navigationController?.navigationBar.compactAppearance = appearance
    navigationController?.navigationBar.tintColor = theme.accentColor

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(handleClose)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Copy Env",
      style: .done,
      target: self,
      action: #selector(handleCopyEnv)
    )
  }

  private func configureLayout() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = theme.backgroundColor
    scrollView.alwaysBounceVertical = true
    scrollView.contentInsetAdjustmentBehavior = .never
    view.addSubview(scrollView)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    contentView.backgroundColor = theme.backgroundColor
    scrollView.addSubview(contentView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.spacing = 18.0
    contentView.addSubview(stackView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18.0),
      stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16.0),
      stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16.0),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28.0),
    ])
  }

  private func configureEdgeMasks() {
    topMaskView.isUserInteractionEnabled = false
    bottomMaskView.isUserInteractionEnabled = false
    topMaskView.backgroundColor = .clear
    bottomMaskView.backgroundColor = .clear

    topMaskGradient.colors = [
      theme.backgroundColor.cgColor,
      theme.backgroundColor.withAlphaComponent(0.0).cgColor,
    ]
    topMaskGradient.startPoint = CGPoint(x: 0.5, y: 0.0)
    topMaskGradient.endPoint = CGPoint(x: 0.5, y: 1.0)
    topMaskView.layer.addSublayer(topMaskGradient)

    bottomMaskGradient.colors = [
      theme.backgroundColor.withAlphaComponent(0.0).cgColor,
      theme.backgroundColor.cgColor,
    ]
    bottomMaskGradient.startPoint = CGPoint(x: 0.5, y: 0.0)
    bottomMaskGradient.endPoint = CGPoint(x: 0.5, y: 1.0)
    bottomMaskView.layer.addSublayer(bottomMaskGradient)

    view.addSubview(topMaskView)
    view.addSubview(bottomMaskView)
  }

  private func layoutEdgeMasks() {
    let width = view.bounds.width
    let height = view.bounds.height
    let safeTop = view.safeAreaInsets.top

    let topMaskHeight = max(84.0, safeTop + 44.0)
    topMaskView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: topMaskHeight)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    topMaskGradient.frame = topMaskView.bounds
    CATransaction.commit()

    let bottomMaskHeight: CGFloat = 96.0
    bottomMaskView.frame = CGRect(
      x: 0.0,
      y: max(0.0, height - bottomMaskHeight),
      width: width,
      height: bottomMaskHeight
    )
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bottomMaskGradient.frame = bottomMaskView.bounds
    CATransaction.commit()
  }

  private func buildContent() {
    secretCardView.applyTheme(theme)

    stackView.addArrangedSubview(secretCardView)

    let agentSection = ChatNativeAgentConfigSectionView(title: "Agent", theme: theme)
    let nameRow = ChatNativeAgentConfigRow(
      title: "Name",
      value: card.displayName,
      theme: theme,
      symbolName: "person.crop.square",
      showsChevron: true
    )
    nameRow.onTap = { [weak self] in
      self?.promptRename()
    }
    agentSection.contentStack.addArrangedSubview(nameRow)
    agentSection.contentStack.addArrangedSubview(
      makeCopyRow(
        title: "Agent ID",
        value: card.agentId,
        copyValue: card.agentId,
        symbolName: "number"
      ))
    agentSection.contentStack.addArrangedSubview(
      makeCopyRow(
        title: "Invoke ID",
        value: card.identifier,
        copyValue: card.identifier,
        symbolName: "paperplane.circle"
      ))
    if let username = card.username {
      agentSection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Handle",
          value: "@\(username)",
          copyValue: username,
          symbolName: "at"
        ))
    }
    agentSection.contentStack.addArrangedSubview(
      makeCopyRow(
        title: "Status",
        value: chatNativeAgentStatusTitle(card.status),
        copyValue: nil,
        symbolName: "checkmark.seal"
      ))
    stackView.addArrangedSubview(agentSection)

    let integrationSection = ChatNativeAgentConfigSectionView(title: "Integration", theme: theme)
    if let apiBaseURL = card.apiBaseURL {
      integrationSection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "API Base",
          value: apiBaseURL,
          copyValue: apiBaseURL,
          symbolName: "network"
        ))
    }
    if let eventsURL = card.eventsURL {
      integrationSection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Events URL",
          value: eventsURL,
          copyValue: eventsURL,
          symbolName: "bolt.horizontal.circle"
        ))
    }
    if let invokeURL = card.invokeURL {
      integrationSection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Invoke URL",
          value: invokeURL,
          copyValue: invokeURL,
          symbolName: "paperplane"
        ))
    }
    if let callbackURL = card.callbackURL {
      integrationSection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Callback",
          value: callbackURL,
          copyValue: callbackURL,
          symbolName: "arrow.triangle.2.circlepath.circle"
        ))
    }
    stackView.addArrangedSubview(integrationSection)

    let deliverySection = ChatNativeAgentConfigSectionView(title: "Delivery", theme: theme)
    if let defaultChat = card.defaultDestinationChat {
      let label = defaultChat.name ?? defaultChat.chatId
      deliverySection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Default Chat",
          value: label,
          copyValue: defaultChat.chatId,
          symbolName: "message.circle"
        ))
    }
    for attachedChat in card.attachedChats {
      let label = attachedChat.name ?? attachedChat.chatId
      deliverySection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Attached Chat",
          value: label,
          copyValue: attachedChat.chatId,
          symbolName: "person.2.circle"
        ))
    }
    let inboxModeRow = ChatNativeAgentConfigRow(
      title: "Inbox Mode",
      value: chatNativeAgentEventInboxTitle(
        mode: card.eventInboxMode,
        summaryWindowHours: card.summaryWindowHours
      ),
      theme: theme,
      symbolName: "tray.full",
      showsChevron: true,
      showsDivider: false
    )
    inboxModeRow.onTap = { [weak self] in
      self?.promptEventInboxMode()
    }
    deliverySection.contentStack.addArrangedSubview(inboxModeRow)
    let incomingChatRow = ChatNativeAgentConfigRow(
      title: "Incoming Chat",
      value: chatNativeAgentIncomingChatTitle(card.incomingChatEnabled),
      theme: theme,
      symbolName: "bubble.left.and.bubble.right",
      showsChevron: true,
      showsDivider: false
    )
    incomingChatRow.onTap = { [weak self] in
      self?.promptIncomingChatMode()
    }
    deliverySection.contentStack.addArrangedSubview(incomingChatRow)
    stackView.addArrangedSubview(deliverySection)

    let behaviorSection = ChatNativeAgentConfigSectionView(title: "Behavior", theme: theme)
    if !card.enabledTools.isEmpty {
      behaviorSection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Tools",
          value: card.enabledTools.joined(separator: ", "),
          copyValue: nil,
          symbolName: "wrench.and.screwdriver"
        ))
    }
    if !card.outputModes.isEmpty {
      behaviorSection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Outputs",
          value: card.outputModes.joined(separator: ", "),
          copyValue: nil,
          symbolName: "square.stack.3d.up"
        ))
    }
    if let voiceProfile = card.voiceProfile {
      behaviorSection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Voice",
          value: voiceProfile,
          copyValue: nil,
          symbolName: "waveform"
        ))
    }
    if let promptStatus = card.promptStatus {
      behaviorSection.contentStack.addArrangedSubview(
        makeCopyRow(
          title: "Prompt Status",
          value: promptStatus,
          copyValue: nil,
          symbolName: "text.badge.checkmark"
        ))
    }
    if let systemPrompt = card.systemPrompt,
      !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let row = ChatNativeAgentConfigRow(
        title: "Prompt",
        value: "View full prompt",
        theme: theme,
        symbolName: "text.quote",
        showsChevron: true,
        showsDivider: false
      )
      row.onTap = { [weak self] in
        guard let self else { return }
        let controller = ChatNativeAgentPromptViewController(prompt: systemPrompt, theme: self.theme)
        self.navigationController?.pushViewController(controller, animated: true)
      }
      behaviorSection.contentStack.addArrangedSubview(row)
    }
    stackView.addArrangedSubview(behaviorSection)

    if card.canDelete {
      let dangerSection = ChatNativeAgentConfigSectionView(title: nil, theme: theme)
      let deleteRow = ChatNativeAgentConfigRow(
        title: "Delete Agent",
        value: "Archive and remove it",
        theme: theme,
        symbolName: "trash",
        showsChevron: true,
        showsDivider: false,
        destructive: true
      )
      deleteRow.onTap = { [weak self] in
        self?.confirmDelete()
      }
      dangerSection.contentStack.addArrangedSubview(deleteRow)
      stackView.addArrangedSubview(dangerSection)
    }
  }

  private func configureCallbacks() {
    secretCardView.onReveal = { [weak self] in
      self?.handleRevealSecret()
    }
    secretCardView.onCopy = { [weak self] in
      self?.handleCopySecret()
    }
    secretCardView.onRotate = { [weak self] in
      self?.confirmRotateSecret()
    }
  }

  private func refreshHeaderAndSecret() {
    secretCardView.configure(
      secret: currentSecret,
      hint: card.secretHint,
      isLoading: isSecretLoading,
      isRevealed: isSecretRevealed,
      canReveal: currentSecret != nil || apiContext != nil
    )
  }

  private func rebuildContent() {
    stackView.arrangedSubviews.forEach { view in
      stackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    buildContent()
    configureCallbacks()
    refreshHeaderAndSecret()
  }

  private func makeCopyRow(
    title: String,
    value: String,
    copyValue: String?,
    symbolName: String
  ) -> ChatNativeAgentConfigRow {
    let row = ChatNativeAgentConfigRow(
      title: title,
      value: value,
      theme: theme,
      symbolName: symbolName,
      showsChevron: false,
      showsAccessory: copyValue != nil
    )
    row.onTap = { [weak self] in
      guard let self else { return }
      guard let copyValue, !copyValue.isEmpty else { return }
      UIPasteboard.general.string = copyValue
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      self.onToast?("Copied \(title)")
    }
    return row
  }

  private func apiRequestURL(path: String) -> URL? {
    guard let apiContext else { return nil }
    let encodedAgentId =
      card.agentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? card.agentId
    let resolvedPath =
      path
      .replacingOccurrences(of: "{agent_id}", with: encodedAgentId)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedPath = resolvedPath.hasPrefix("/") ? String(resolvedPath.dropFirst()) : resolvedPath
    return URL(string: normalizedPath, relativeTo: apiContext.apiBaseURL)
      ?? apiContext.apiBaseURL.appendingPathComponent(normalizedPath)
  }

  private func apiHeaders(_ request: inout URLRequest) {
    guard let apiContext else { return }
    request.setValue("Bearer \(apiContext.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
  }

  private func updateCard(
    displayName: String? = nil,
    secret: String? = nil,
    secretHint: String? = nil,
    eventInboxMode: String? = nil,
    summaryWindowHours: Int? = nil,
    incomingChatEnabled: Bool? = nil
  ) {
    card = ChatListRow.AgentCard(
      id: card.id,
      style: card.style,
      agentId: card.agentId,
      displayName: displayName ?? card.displayName,
      username: card.username,
      identifier: card.identifier,
      status: card.status,
      promptStatus: card.promptStatus,
      promptPreview: card.promptPreview,
      systemPrompt: card.systemPrompt,
      enabledTools: card.enabledTools,
      outputModes: card.outputModes,
      voiceProfile: card.voiceProfile,
      callbackURL: card.callbackURL,
      apiBaseURL: card.apiBaseURL,
      invokeURL: card.invokeURL,
      eventsURL: card.eventsURL,
      builderLink: card.builderLink,
      agentDMURL: card.agentDMURL,
      secretHint: secretHint ?? card.secretHint,
      latestSecret: secret ?? card.latestSecret,
      defaultDestinationChat: card.defaultDestinationChat,
      attachedChats: card.attachedChats,
      eventInboxMode:
        chatNativeAgentNormalizeEventInboxMode(eventInboxMode ?? card.eventInboxMode),
      summaryWindowHours:
        chatNativeAgentNormalizeSummaryWindowHours(summaryWindowHours ?? card.summaryWindowHours),
      incomingChatEnabled: incomingChatEnabled ?? card.incomingChatEnabled,
      canDelete: card.canDelete
    )
  }

  private func promptRename() {
    let alert = UIAlertController(
      title: "Rename Agent",
      message: "Choose the name shown for this agent across Vibe.",
      preferredStyle: .alert
    )
    alert.addTextField { textField in
      textField.placeholder = "Agent name"
      textField.text = self.card.displayName
      textField.clearButtonMode = .whileEditing
      textField.autocapitalizationType = .words
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
      guard let self else { return }
      let proposedName =
        alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      self.renameAgent(to: proposedName)
    })
    present(alert, animated: true)
  }

  private func renameAgent(to proposedName: String) {
    let normalizedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      onToast?("Name cannot be empty")
      return
    }
    guard normalizedName != card.displayName else {
      onToast?("Name unchanged")
      return
    }
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["display_name": normalizedName])

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          NSLog("[ChatNativeAgentConfig] rename agent failed %@", error.localizedDescription)
          self.onToast?("Could not rename agent")
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode), let data else {
          self.onToast?("Could not rename agent")
          return
        }

        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let updatedName =
          chatNativeAgentNormalizedString(payload?["displayName"])
          ?? chatNativeAgentNormalizedString(payload?["display_name"])
          ?? normalizedName

        self.updateCard(displayName: updatedName)
        self.rebuildContent()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Renamed agent")
      }
    }

    task.resume()
  }

  private func promptEventInboxMode() {
    let alert = UIAlertController(
      title: "Inbox Mode",
      message: "Choose how external notifications are shown in this chat.",
      preferredStyle: .actionSheet
    )

    alert.addAction(UIAlertAction(title: "Event bubbles", style: .default) { [weak self] _ in
      self?.updateEventInboxMode(mode: "per_event", summaryWindowHours: 24)
    })
    alert.addAction(UIAlertAction(title: "Batch summary every 4h", style: .default) { [weak self] _ in
      self?.updateEventInboxMode(mode: "batched_summary", summaryWindowHours: 4)
    })
    alert.addAction(UIAlertAction(title: "Daily batch summary", style: .default) { [weak self] _ in
      self?.updateEventInboxMode(mode: "batched_summary", summaryWindowHours: 24)
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    if let popover = alert.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(
        x: view.bounds.midX,
        y: view.bounds.midY,
        width: 1.0,
        height: 1.0
      )
    }

    present(alert, animated: true)
  }

  private func updateEventInboxMode(mode: String, summaryWindowHours: Int) {
    let normalizedMode = chatNativeAgentNormalizeEventInboxMode(mode)
    let normalizedHours = chatNativeAgentNormalizeSummaryWindowHours(summaryWindowHours)

    guard
      normalizedMode != card.eventInboxMode || normalizedHours != card.summaryWindowHours
    else {
      onToast?("Inbox mode unchanged")
      return
    }

    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      return
    }

    let payload: [String: Any] = [
      "approval_rules": [
        "event_inbox": [
          "mode": normalizedMode,
          "summary_window_hours": normalizedHours,
        ],
        "chat_input": [
          "enabled": card.incomingChatEnabled
        ],
      ]
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          NSLog("[ChatNativeAgentConfig] update inbox mode failed %@", error.localizedDescription)
          self.onToast?("Could not update inbox mode")
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode), let data else {
          self.onToast?("Could not update inbox mode")
          return
        }

        let responsePayload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let approvalRules =
          (responsePayload?["approvalRules"] as? [String: Any])
          ?? (responsePayload?["approval_rules"] as? [String: Any])
        let eventInbox =
          (approvalRules?["event_inbox"] as? [String: Any])
          ?? (approvalRules?["eventInbox"] as? [String: Any])

        let resolvedMode =
          chatNativeAgentNormalizeEventInboxMode(
            chatNativeAgentNormalizedString(eventInbox?["mode"])
              ?? chatNativeAgentNormalizedString(eventInbox?["event_inbox_mode"])
              ?? normalizedMode
          )
        let resolvedHours =
          chatNativeAgentNormalizeSummaryWindowHours(
            chatNativeAgentInteger(eventInbox?["summary_window_hours"])
              ?? chatNativeAgentInteger(eventInbox?["summaryWindowHours"])
              ?? chatNativeAgentInteger(eventInbox?["cadence"])
              ?? normalizedHours
          )
        let chatInput =
          (approvalRules?["chat_input"] as? [String: Any])
          ?? (approvalRules?["chatInput"] as? [String: Any])
        let resolvedIncomingChat =
          chatNativeAgentBoolean(chatInput?["enabled"])
          ?? self.card.incomingChatEnabled

        self.updateCard(
          eventInboxMode: resolvedMode,
          summaryWindowHours: resolvedHours,
          incomingChatEnabled: resolvedIncomingChat
        )
        self.rebuildContent()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Updated inbox mode")
      }
    }

    task.resume()
  }

  private func promptIncomingChatMode() {
    let alert = UIAlertController(
      title: "Incoming Chat",
      message: "Choose whether this agent accepts direct chat messages in its main Vibe chat.",
      preferredStyle: .actionSheet
    )

    alert.addAction(UIAlertAction(title: "Accept messages", style: .default) { [weak self] _ in
      self?.updateIncomingChatMode(enabled: true)
    })
    alert.addAction(UIAlertAction(title: "Disable messages", style: .default) { [weak self] _ in
      self?.updateIncomingChatMode(enabled: false)
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    if let popover = alert.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(
        x: view.bounds.midX,
        y: view.bounds.midY,
        width: 1.0,
        height: 1.0
      )
    }

    present(alert, animated: true)
  }

  private func updateIncomingChatMode(enabled: Bool) {
    guard enabled != card.incomingChatEnabled else {
      onToast?("Incoming chat unchanged")
      return
    }

    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      return
    }

    let payload: [String: Any] = [
      "approval_rules": [
        "event_inbox": [
          "mode": card.eventInboxMode,
          "summary_window_hours": card.summaryWindowHours,
        ],
        "chat_input": [
          "enabled": enabled
        ],
      ]
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          NSLog("[ChatNativeAgentConfig] update incoming chat failed %@", error.localizedDescription)
          self.onToast?("Could not update incoming chat")
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode), let data else {
          self.onToast?("Could not update incoming chat")
          return
        }

        let responsePayload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let approvalRules =
          (responsePayload?["approvalRules"] as? [String: Any])
          ?? (responsePayload?["approval_rules"] as? [String: Any])
        let chatInput =
          (approvalRules?["chat_input"] as? [String: Any])
          ?? (approvalRules?["chatInput"] as? [String: Any])
        let eventInbox =
          (approvalRules?["event_inbox"] as? [String: Any])
          ?? (approvalRules?["eventInbox"] as? [String: Any])

        let resolvedMode =
          chatNativeAgentNormalizeEventInboxMode(
            chatNativeAgentNormalizedString(eventInbox?["mode"])
              ?? chatNativeAgentNormalizedString(eventInbox?["event_inbox_mode"])
              ?? self.card.eventInboxMode
          )
        let resolvedHours =
          chatNativeAgentNormalizeSummaryWindowHours(
            chatNativeAgentInteger(eventInbox?["summary_window_hours"])
              ?? chatNativeAgentInteger(eventInbox?["summaryWindowHours"])
              ?? self.card.summaryWindowHours
          )
        let resolvedIncomingChat =
          chatNativeAgentBoolean(chatInput?["enabled"])
          ?? enabled

        self.updateCard(
          eventInboxMode: resolvedMode,
          summaryWindowHours: resolvedHours,
          incomingChatEnabled: resolvedIncomingChat
        )
        self.rebuildContent()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Updated incoming chat")
      }
    }

    task.resume()
  }

  private func loadSecret(
    revealAfterLoad: Bool,
    userInitiated: Bool,
    completion: ((String) -> Void)?
  ) {
    if let currentSecret, !currentSecret.isEmpty {
      if revealAfterLoad {
        isSecretRevealed = true
        refreshHeaderAndSecret()
      }
      completion?(currentSecret)
      return
    }

    guard !isSecretLoading else { return }
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}/secret") else {
      if userInitiated {
        onToast?("Missing API session")
      }
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    apiHeaders(&request)

    isSecretLoading = true
    refreshHeaderAndSecret()

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.activeSecretRequest = nil
        self.isSecretLoading = false

        if let error {
          NSLog("[ChatNativeAgentConfig] fetch secret failed %@", error.localizedDescription)
          if userInitiated {
            self.onToast?("Could not load secret")
          }
          self.refreshHeaderAndSecret()
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode), let data else {
          if userInitiated {
            self.onToast?("Could not load secret")
          }
          self.refreshHeaderAndSecret()
          return
        }

        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let secret = chatNativeAgentNormalizedString(payload?["secret"])
        let secretHint =
          chatNativeAgentNormalizedString(payload?["secretHint"])
          ?? chatNativeAgentNormalizedString(payload?["secret_hint"])

        guard let secret, !secret.isEmpty else {
          if userInitiated {
            self.onToast?("Secret unavailable")
          }
          self.refreshHeaderAndSecret()
          return
        }

        self.currentSecret = secret
        self.updateCard(secret: secret, secretHint: secretHint)
        if revealAfterLoad {
          self.isSecretRevealed = true
        }
        self.refreshHeaderAndSecret()
        completion?(secret)
      }
    }

    activeSecretRequest?.cancel()
    activeSecretRequest = task
    task.resume()
  }

  private func handleRevealSecret() {
    if let currentSecret, !currentSecret.isEmpty {
      isSecretRevealed = true
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      refreshHeaderAndSecret()
      return
    }

    loadSecret(revealAfterLoad: true, userInitiated: true, completion: nil)
  }

  private func handleCopySecret() {
    loadSecret(revealAfterLoad: false, userInitiated: true) { [weak self] secret in
      UIPasteboard.general.string = secret
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      self?.onToast?("Copied secret")
    }
  }

  private func confirmRotateSecret() {
    let alert = UIAlertController(
      title: "Rotate Secret",
      message: "This will invalidate the current invoke secret and generate a new one.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Rotate", style: .destructive) { [weak self] _ in
      self?.rotateSecret()
    })
    present(alert, animated: true)
  }

  private func rotateSecret() {
    guard !isSecretLoading else { return }
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}/secret/rotate") else {
      onToast?("Missing API session")
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    apiHeaders(&request)

    isSecretLoading = true
    refreshHeaderAndSecret()

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.activeSecretRequest = nil
        self.isSecretLoading = false

        if let error {
          NSLog("[ChatNativeAgentConfig] rotate secret failed %@", error.localizedDescription)
          self.onToast?("Could not rotate secret")
          self.refreshHeaderAndSecret()
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode), let data else {
          self.onToast?("Could not rotate secret")
          self.refreshHeaderAndSecret()
          return
        }

        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let secret = chatNativeAgentNormalizedString(payload?["secret"])
        let agentPayload = payload?["agent"] as? [String: Any]
        let secretHint =
          chatNativeAgentNormalizedString(agentPayload?["secretHint"])
          ?? chatNativeAgentNormalizedString(agentPayload?["secret_hint"])

        guard let secret, !secret.isEmpty else {
          self.onToast?("Could not rotate secret")
          self.refreshHeaderAndSecret()
          return
        }

        self.currentSecret = secret
        self.isSecretRevealed = true
        self.updateCard(secret: secret, secretHint: secretHint)
        self.refreshHeaderAndSecret()
        UIPasteboard.general.string = secret
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        self.onToast?("Rotated secret")
      }
    }

    activeSecretRequest?.cancel()
    activeSecretRequest = task
    task.resume()
  }

  private func envExportBlock(secret: String) -> String {
    let destinationChat = card.defaultDestinationChat?.chatId ?? ""
    return [
      "VIBE_API_BASE_URL=\(card.apiBaseURL ?? "https://api.vibegram.io")",
      "VIBE_AGENT_IDENTIFIER=\(card.identifier)",
      "VIBE_AGENT_SECRET=\(secret)",
      "VIBE_DESTINATION_CHAT_ID=\(destinationChat)",
      "VIBE_SOURCE=external_app",
      "VIBE_TIMEOUT_SECONDS=10",
    ].joined(separator: "\n")
  }

  private func confirmDelete() {
    let alert = UIAlertController(
      title: "Delete Agent",
      message: "Archive \(card.displayName)? This removes it from your active agent list.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      guard let self else { return }
      self.onDeleteAgent?(self.card) { [weak self] in
        self?.dismiss(animated: true)
      }
    })
    present(alert, animated: true)
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  @objc private func handleCopyEnv() {
    loadSecret(revealAfterLoad: false, userInitiated: true) { [weak self] secret in
      guard let self else { return }
      UIPasteboard.general.string = self.envExportBlock(secret: secret)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      self.onToast?("Copied env pack")
    }
  }
}
