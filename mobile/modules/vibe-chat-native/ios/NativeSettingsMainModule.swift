import ExpoModulesCore
import UIKit

private enum NativeSettingsRowKind: String {
  case link
  case toggle = "switch"
  case value
  case button
}

private struct NativeSettingsRow {
  let id: String
  let icon: String
  let label: String
  let detailText: String?
  let toggleValue: Bool
  let kind: NativeSettingsRowKind
  let iconColor: UIColor
  let divider: Bool
  let destructive: Bool

  static func parse(_ raw: [String: Any]) -> NativeSettingsRow? {
    let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let icon = (raw["icon"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let label = (raw["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let kindValue =
      (raw["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "link"
    guard !id.isEmpty, !label.isEmpty, let kind = NativeSettingsRowKind(rawValue: kindValue) else {
      return nil
    }

    let value = raw["value"]
    let detailText: String?
    let toggleValue: Bool
    switch value {
    case let text as String:
      detailText = text
      toggleValue = false
    case let boolValue as Bool:
      detailText = nil
      toggleValue = boolValue
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        detailText = nil
        toggleValue = number.boolValue
      } else {
        detailText = number.stringValue
        toggleValue = false
      }
    default:
      detailText = nil
      toggleValue = false
    }

    let color = UIColor.nativeSettingsColor(from: raw["color"] as? String) ?? .white
    let divider = (raw["divider"] as? Bool) ?? true
    let destructive = (raw["destructive"] as? Bool) ?? false

    return NativeSettingsRow(
      id: id,
      icon: icon,
      label: label,
      detailText: detailText,
      toggleValue: toggleValue,
      kind: kind,
      iconColor: color,
      divider: divider,
      destructive: destructive
    )
  }
}

private struct NativeSettingsSection {
  let title: String?
  let rows: [NativeSettingsRow]

  static func parse(_ raw: [String: Any]) -> NativeSettingsSection? {
    let title = (raw["title"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
    let rawRows = raw["rows"] as? [[String: Any]] ?? []
    let rows = rawRows.compactMap(NativeSettingsRow.parse)
    guard !rows.isEmpty else { return nil }
    return NativeSettingsSection(title: title, rows: rows)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private struct NativeSettingsTheme {
  var background = UIColor.black
  var card = UIColor(white: 0.12, alpha: 1.0)
  var text = UIColor.white
  var secondaryText = UIColor(white: 1.0, alpha: 0.65)
  var primary = UIColor(red: 0.24, green: 0.51, blue: 0.96, alpha: 1.0)
  var isDark = true
}

private final class NativeSettingsBadgeView: UIView {
  private let imageView = UIImageView()
  private let backgroundView = UIView()
  private var iconSizeConstraint: NSLayoutConstraint?

  override init(frame: CGRect) {
    super.init(frame: frame)

    translatesAutoresizingMaskIntoConstraints = false
    isHidden = true

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.layer.cornerRadius = 10
    backgroundView.clipsToBounds = true
    addSubview(backgroundView)

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    addSubview(imageView)

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      widthAnchor.constraint(equalToConstant: 20),
      heightAnchor.constraint(equalToConstant: 20),
    ])

    iconSizeConstraint = imageView.widthAnchor.constraint(equalToConstant: 12)
    iconSizeConstraint?.isActive = true
    imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor).isActive = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(tier rawTier: String?) {
    let tier = rawTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let symbolName: String
    let tintColor: UIColor

    switch tier {
    case "bronze":
      symbolName = "seal.fill"
      tintColor = UIColor(red: 205 / 255, green: 127 / 255, blue: 50 / 255, alpha: 1.0)
    case "silver":
      symbolName = "star.fill"
      tintColor = UIColor(red: 192 / 255, green: 192 / 255, blue: 192 / 255, alpha: 1.0)
    case "gold":
      symbolName = "checkmark.seal.fill"
      tintColor = UIColor(red: 184 / 255, green: 134 / 255, blue: 11 / 255, alpha: 1.0)
    case "verified", "admin":
      symbolName = "checkmark.seal.fill"
      tintColor = UIColor(red: 56 / 255, green: 151 / 255, blue: 240 / 255, alpha: 1.0)
    default:
      isHidden = true
      return
    }

    let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    imageView.image = UIImage(systemName: symbolName, withConfiguration: configuration)
    imageView.tintColor = tintColor
    backgroundView.backgroundColor = tintColor.withAlphaComponent(0.16)
    isHidden = false
  }
}

private final class NativeSettingsGlassButton: UIControl {
  private let effectView = UIVisualEffectView(effect: nil)
  private let titleLabelView = UILabel()
  private let iconView = UIImageView()
  private let overlayView = UIView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var iconSizeConstraint: NSLayoutConstraint?
  private var heightConstraint: NSLayoutConstraint?
  private var widthConstraint: NSLayoutConstraint?

  var iconTintColor: UIColor = .white {
    didSet {
      iconView.tintColor = iconTintColor
      titleLabelView.textColor = iconTintColor
      spinner.color = iconTintColor
    }
  }

  var isLoading: Bool = false {
    didSet {
      if isLoading {
        spinner.startAnimating()
      } else {
        spinner.stopAnimating()
      }
      spinner.isHidden = !isLoading
      iconView.isHidden = isLoading || iconView.image == nil
      titleLabelView.isHidden = isLoading || (titleLabelView.text?.isEmpty ?? true)
      isUserInteractionEnabled = !isLoading
      invalidateIntrinsicContentSize()
    }
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.16) {
        self.overlayView.alpha = self.isHighlighted ? 1.0 : 0.0
        self.transform =
          self.isHighlighted
          ? CGAffineTransform(scaleX: 0.96, y: 0.96)
          : .identity
      }
    }
  }

  override var intrinsicContentSize: CGSize {
    let height = heightConstraint?.constant ?? 44
    if let widthConstraint, widthConstraint.isActive {
      return CGSize(width: widthConstraint.constant, height: height)
    }

    if isLoading {
      return CGSize(width: height, height: height)
    }

    if let text = titleLabelView.text, !text.isEmpty {
      let textWidth = ceil(
        (text as NSString).size(withAttributes: [.font: titleLabelView.font as Any]).width)
      return CGSize(width: max(56, textWidth + 28), height: height)
    }

    if iconView.image != nil {
      return CGSize(width: height, height: height)
    }

    return CGSize(width: height, height: height)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    clipsToBounds = false

    effectView.translatesAutoresizingMaskIntoConstraints = false
    effectView.clipsToBounds = true
    if #available(iOS 13.0, *) {
      effectView.layer.cornerCurve = .continuous
    }
    addSubview(effectView)

    overlayView.translatesAutoresizingMaskIntoConstraints = false
    overlayView.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    overlayView.alpha = 0
    effectView.contentView.addSubview(overlayView)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.tintColor = iconTintColor
    effectView.contentView.addSubview(iconView)

    titleLabelView.translatesAutoresizingMaskIntoConstraints = false
    titleLabelView.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabelView.textAlignment = .center
    titleLabelView.textColor = iconTintColor
    effectView.contentView.addSubview(titleLabelView)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    spinner.color = iconTintColor
    effectView.contentView.addSubview(spinner)

    NSLayoutConstraint.activate([
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

      overlayView.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
      overlayView.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
      overlayView.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),

      iconView.centerXAnchor.constraint(equalTo: effectView.contentView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),

      titleLabelView.leadingAnchor.constraint(
        equalTo: effectView.contentView.leadingAnchor, constant: 14),
      titleLabelView.trailingAnchor.constraint(
        equalTo: effectView.contentView.trailingAnchor, constant: -14),
      titleLabelView.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),

      spinner.centerXAnchor.constraint(equalTo: effectView.contentView.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),
    ])

    iconSizeConstraint = iconView.widthAnchor.constraint(equalToConstant: 20)
    iconSizeConstraint?.isActive = true
    iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor).isActive = true

    heightConstraint = heightAnchor.constraint(equalToConstant: 44)
    heightConstraint?.isActive = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setGlassTheme(isDark: Bool) {
    if #available(iOS 26.0, *) {
      effectView.effect = UIGlassEffect()
      effectView.contentView.backgroundColor = .clear
    } else {
      effectView.effect = UIBlurEffect(
        style: isDark ? .systemThinMaterialDark : .systemThinMaterialLight
      )
      effectView.contentView.backgroundColor =
        (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.12 : 0.06)
    }
    effectView.layer.cornerRadius = 22
  }

  func setIcon(systemName: String?, pointSize: CGFloat = 20) {
    guard let systemName, !systemName.isEmpty else {
      iconView.image = nil
      iconView.isHidden = true
      invalidateIntrinsicContentSize()
      return
    }
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    iconView.image = UIImage(systemName: systemName, withConfiguration: configuration)
    iconView.isHidden = false
    iconSizeConstraint?.constant = pointSize
    invalidateIntrinsicContentSize()
  }

  func setTitle(_ title: String?) {
    titleLabelView.text = title
    titleLabelView.isHidden = title?.isEmpty ?? true
    invalidateIntrinsicContentSize()
  }

  func setButtonSize(width: CGFloat?, height: CGFloat = 44) {
    heightConstraint?.constant = height
    if let width {
      if widthConstraint == nil {
        widthConstraint = widthAnchor.constraint(equalToConstant: width)
        widthConstraint?.isActive = true
      } else {
        widthConstraint?.constant = width
      }
    } else {
      widthConstraint?.isActive = false
      widthConstraint = nil
    }
    effectView.layer.cornerRadius = height * 0.5
    invalidateIntrinsicContentSize()
  }
}

private final class NativeSettingsRowView: UIControl {
  private let highlightOverlayView = UIView()
  private let iconBackgroundView = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let chevronImageView = UIImageView()
  private let switchControl = UISwitch()
  private let dividerView = UIView()
  private var currentRow: NativeSettingsRow
  private var theme: NativeSettingsTheme
  private var onPress: ((String) -> Void)?
  private var onToggle: ((String, Bool) -> Void)?

  override var isHighlighted: Bool {
    didSet {
      updateHighlightAppearance(animated: true)
    }
  }

  init(
    row: NativeSettingsRow,
    theme: NativeSettingsTheme,
    onPress: ((String) -> Void)?,
    onToggle: ((String, Bool) -> Void)?
  ) {
    currentRow = row
    self.theme = theme
    self.onPress = onPress
    self.onToggle = onToggle
    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)

    highlightOverlayView.translatesAutoresizingMaskIntoConstraints = false
    highlightOverlayView.isUserInteractionEnabled = false
    highlightOverlayView.alpha = 0
    addSubview(highlightOverlayView)

    iconBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    iconBackgroundView.layer.cornerRadius = 8
    iconBackgroundView.clipsToBounds = true
    addSubview(iconBackgroundView)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    addSubview(titleLabel)

    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    valueLabel.font = .systemFont(ofSize: 15, weight: .regular)
    valueLabel.textAlignment = .right
    addSubview(valueLabel)

    chevronImageView.translatesAutoresizingMaskIntoConstraints = false
    chevronImageView.contentMode = .scaleAspectFit
    chevronImageView.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    )
    addSubview(chevronImageView)

    switchControl.translatesAutoresizingMaskIntoConstraints = false
    switchControl.addTarget(self, action: #selector(handleSwitchChanged), for: .valueChanged)
    addSubview(switchControl)

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dividerView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 58),

      highlightOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      highlightOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      highlightOverlayView.topAnchor.constraint(equalTo: topAnchor),
      highlightOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      iconBackgroundView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconBackgroundView.widthAnchor.constraint(equalToConstant: 32),
      iconBackgroundView.heightAnchor.constraint(equalToConstant: 32),

      iconView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),

      titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevronImageView.widthAnchor.constraint(equalToConstant: 14),
      chevronImageView.heightAnchor.constraint(equalToConstant: 14),

      valueLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
      valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      valueLabel.trailingAnchor.constraint(equalTo: chevronImageView.leadingAnchor, constant: -8),

      switchControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      switchControl.centerYAnchor.constraint(equalTo: centerYAnchor),
      switchControl.leadingAnchor.constraint(
        greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),

      dividerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 60),
      dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

      topAnchor.constraint(lessThanOrEqualTo: titleLabel.topAnchor, constant: 16),
      bottomAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor, constant: 16),
    ])

    configure(with: row, theme: theme)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with row: NativeSettingsRow, theme: NativeSettingsTheme) {
    currentRow = row
    self.theme = theme

    iconBackgroundView.backgroundColor = row.iconColor
    iconView.image = UIImage(
      systemName: row.icon,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    )
    iconView.tintColor = .white
    titleLabel.text = row.label
    titleLabel.textColor =
      row.destructive
      ? UIColor(red: 239 / 255, green: 68 / 255, blue: 68 / 255, alpha: 1.0) : theme.text
    valueLabel.textColor = theme.secondaryText
    valueLabel.text = row.detailText
    dividerView.isHidden = !row.divider
    dividerView.backgroundColor =
      (theme.isDark ? UIColor.white : UIColor.black).withAlphaComponent(theme.isDark ? 0.05 : 0.06)

    switch row.kind {
    case .link:
      chevronImageView.isHidden = false
      valueLabel.isHidden = row.detailText == nil
      switchControl.isHidden = true
    case .value:
      chevronImageView.isHidden = true
      valueLabel.isHidden = row.detailText == nil
      switchControl.isHidden = true
    case .button:
      chevronImageView.isHidden = true
      valueLabel.isHidden = row.detailText == nil
      switchControl.isHidden = true
    case .toggle:
      chevronImageView.isHidden = true
      valueLabel.isHidden = true
      switchControl.isHidden = false
      switchControl.onTintColor = theme.primary
      switchControl.setOn(row.toggleValue, animated: false)
    }

    chevronImageView.tintColor =
      (theme.isDark ? UIColor.white : UIColor.black).withAlphaComponent(theme.isDark ? 0.5 : 0.32)
    updateHighlightAppearance(animated: false)
  }

  @objc private func handleTap() {
    switch currentRow.kind {
    case .toggle:
      let nextValue = !switchControl.isOn
      switchControl.setOn(nextValue, animated: true)
      onToggle?(currentRow.id, nextValue)
    default:
      onPress?(currentRow.id)
    }
  }

  @objc private func handleSwitchChanged() {
    onToggle?(currentRow.id, switchControl.isOn)
  }

  private func updateHighlightAppearance(animated: Bool) {
    let targetAlpha: CGFloat = currentRow.kind == .toggle ? 0 : (isHighlighted ? 1 : 0)
    let targetTransform: CGAffineTransform =
      currentRow.kind == .toggle || !isHighlighted
      ? .identity
      : CGAffineTransform(scaleX: 0.97, y: 0.97)
    let targetOverlayColor =
      theme.isDark
      ? UIColor.white.withAlphaComponent(0.08)
      : UIColor.black.withAlphaComponent(0.05)

    let updates = {
      self.highlightOverlayView.backgroundColor = targetOverlayColor
      self.highlightOverlayView.alpha = targetAlpha
      self.iconBackgroundView.transform = targetTransform
    }

    if animated {
      UIView.animate(
        withDuration: 0.16,
        delay: 0,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
        animations: updates
      )
    } else {
      updates()
    }
  }
}

final class NativeSettingsMainView: ExpoView, UIScrollViewDelegate {
  public var onNativeEvent = EventDispatcher()

  private let backgroundView = UIView()
  private let scrollView = UIScrollView()
  private let scrollContentView = UIView()
  private let contentStack = UIStackView()
  private let headerMaskContainer = UIView()
  private let headerMaskLayer = CAGradientLayer()
  private let qrButton = NativeSettingsGlassButton()
  private let editButton = NativeSettingsGlassButton()
  private let avatarView: NativeProfileAvatarView
  private let avatarActionHost = UIView()
  private let penButton = NativeSettingsGlassButton()
  private let heroSpacerView = UIView()
  private let profileHeaderStack = UIStackView()
  private let profileNameRow = UIStackView()
  private let nameLabel = UILabel()
  private let badgeView = NativeSettingsBadgeView()
  private let subtitleLabel = UILabel()
  private let footerLabel = UILabel()

  private var headerMaskHeightConstraint: NSLayoutConstraint?
  private var qrTopConstraint: NSLayoutConstraint?
  private var editTopConstraint: NSLayoutConstraint?
  private var avatarHeightConstraint: NSLayoutConstraint?
  private var avatarPenTopConstraint: NSLayoutConstraint?
  private var avatarActionWidthConstraint: NSLayoutConstraint?
  private var avatarActionHeightConstraint: NSLayoutConstraint?
  private var heroSpacerHeightConstraint: NSLayoutConstraint?

  private var theme = NativeSettingsTheme()
  private var sections: [NativeSettingsSection] = []
  private var currentBadgeTier: String?
  private var currentHeroTop: CGFloat = 0
  private var currentCollapsedTop: CGFloat = 0

  required init(appContext: AppContext? = nil) {
    avatarView = NativeProfileAvatarView(appContext: appContext)
    super.init(appContext: appContext)
    configureView()
    rebuildSections()
    updateMetrics()
    updateScrollAnimations(offsetY: 0)
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    updateMetrics()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    headerMaskLayer.frame = headerMaskContainer.bounds
  }

  func setIsDark(_ value: Bool) {
    guard theme.isDark != value else { return }
    theme.isDark = value
    applyTheme()
  }

  func setBackgroundColorHex(_ value: String?) {
    if let resolved = UIColor.nativeSettingsColor(from: value) {
      theme.background = resolved
      applyTheme()
    }
  }

  func setCardColorHex(_ value: String?) {
    if let resolved = UIColor.nativeSettingsColor(from: value) {
      theme.card = resolved
      applyTheme()
    }
  }

  func setTextColorHex(_ value: String?) {
    if let resolved = UIColor.nativeSettingsColor(from: value) {
      theme.text = resolved
      applyTheme()
    }
  }

  func setSecondaryTextColorHex(_ value: String?) {
    if let resolved = UIColor.nativeSettingsColor(from: value) {
      theme.secondaryText = resolved
      applyTheme()
    }
  }

  func setPrimaryColorHex(_ value: String?) {
    if let resolved = UIColor.nativeSettingsColor(from: value) {
      theme.primary = resolved
      applyTheme()
    }
  }

  func setDisplayName(_ value: String?) {
    nameLabel.text = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Guest"
  }

  func setSubtitle(_ value: String?) {
    subtitleLabel.text = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? ""
  }

  func setEditLabel(_ value: String?) {
    editButton.setTitle(value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Edit")
  }

  func setFooterText(_ value: String?) {
    footerLabel.text = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? ""
  }

  func setAvatarImageUri(_ value: String?) {
    avatarView.setImageUri(value)
  }

  func setAvatarFallbackText(_ value: String?) {
    avatarView.setFallbackText(value)
  }

  func setAvatarLoading(_ value: Bool) {
    penButton.isLoading = value
  }

  func setBadgeTier(_ value: String?) {
    currentBadgeTier = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    badgeView.configure(tier: currentBadgeTier)
  }

  func setSections(_ rawSections: [[String: Any]]) {
    sections = rawSections.compactMap(NativeSettingsSection.parse)
    rebuildSections()
  }

  private func configureView() {
    backgroundColor = .clear
    clipsToBounds = false

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.showsVerticalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.alwaysBounceVertical = true
    scrollView.delegate = self
    addSubview(scrollView)

    scrollContentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(scrollContentView)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 24
    scrollContentView.addSubview(contentStack)

    headerMaskContainer.translatesAutoresizingMaskIntoConstraints = false
    headerMaskContainer.isUserInteractionEnabled = false
    headerMaskContainer.layer.zPosition = 10
    addSubview(headerMaskContainer)

    headerMaskLayer.locations = [0.0, 0.7, 1.0]
    headerMaskLayer.startPoint = CGPoint(x: 0.5, y: 0)
    headerMaskLayer.endPoint = CGPoint(x: 0.5, y: 1)
    headerMaskContainer.layer.addSublayer(headerMaskLayer)

    qrButton.setIcon(systemName: "qrcode", pointSize: 20)
    qrButton.setButtonSize(width: 44)
    qrButton.addTarget(self, action: #selector(handleHeaderQrPress), for: .touchUpInside)
    qrButton.layer.zPosition = 40
    addSubview(qrButton)

    editButton.setTitle("Edit")
    editButton.setButtonSize(width: nil)
    editButton.addTarget(self, action: #selector(handleHeaderEditPress), for: .touchUpInside)
    editButton.layer.zPosition = 40
    addSubview(editButton)

    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.clipsToBounds = false
    avatarView.layer.zPosition = 30
    addSubview(avatarView)

    avatarActionHost.translatesAutoresizingMaskIntoConstraints = false
    avatarActionHost.isUserInteractionEnabled = true
    avatarActionHost.layer.zPosition = 50
    addSubview(avatarActionHost)

    penButton.setIcon(systemName: "pencil", pointSize: 16)
    penButton.setButtonSize(width: 36, height: 36)
    penButton.addTarget(self, action: #selector(handleAvatarEditPress), for: .touchUpInside)
    penButton.isUserInteractionEnabled = true
    avatarActionHost.addSubview(penButton)

    heroSpacerView.translatesAutoresizingMaskIntoConstraints = false
    contentStack.addArrangedSubview(heroSpacerView)

    profileHeaderStack.translatesAutoresizingMaskIntoConstraints = false
    profileHeaderStack.axis = .vertical
    profileHeaderStack.alignment = .center
    profileHeaderStack.spacing = 2
    contentStack.addArrangedSubview(profileHeaderStack)

    profileNameRow.translatesAutoresizingMaskIntoConstraints = false
    profileNameRow.axis = .horizontal
    profileNameRow.alignment = .center
    profileNameRow.spacing = 6
    profileHeaderStack.addArrangedSubview(profileNameRow)

    nameLabel.font = .systemFont(ofSize: 28, weight: .regular)
    nameLabel.textAlignment = .center
    profileNameRow.addArrangedSubview(nameLabel)
    profileNameRow.addArrangedSubview(badgeView)

    subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
    subtitleLabel.textAlignment = .center
    profileHeaderStack.addArrangedSubview(subtitleLabel)

    footerLabel.translatesAutoresizingMaskIntoConstraints = false
    footerLabel.font = .systemFont(ofSize: 12, weight: .regular)
    footerLabel.textAlignment = .center

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollContentView.leadingAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      scrollContentView.trailingAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      scrollContentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      scrollContentView.bottomAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      scrollContentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      contentStack.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
      contentStack.trailingAnchor.constraint(
        equalTo: scrollContentView.trailingAnchor, constant: -16),
      contentStack.topAnchor.constraint(equalTo: scrollContentView.topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: scrollContentView.bottomAnchor, constant: -100),

      headerMaskContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      headerMaskContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      headerMaskContainer.topAnchor.constraint(equalTo: topAnchor),

      qrButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      editButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

      avatarView.leadingAnchor.constraint(equalTo: leadingAnchor),
      avatarView.trailingAnchor.constraint(equalTo: trailingAnchor),
      avatarView.topAnchor.constraint(equalTo: topAnchor),

      avatarActionHost.centerXAnchor.constraint(equalTo: centerXAnchor),

      penButton.trailingAnchor.constraint(equalTo: avatarActionHost.trailingAnchor),
      penButton.bottomAnchor.constraint(equalTo: avatarActionHost.bottomAnchor),
    ])

    headerMaskHeightConstraint = headerMaskContainer.heightAnchor.constraint(equalToConstant: 104)
    headerMaskHeightConstraint?.isActive = true

    qrTopConstraint = qrButton.topAnchor.constraint(equalTo: topAnchor, constant: 8)
    qrTopConstraint?.isActive = true

    editTopConstraint = editButton.topAnchor.constraint(equalTo: topAnchor, constant: 8)
    editTopConstraint?.isActive = true

    avatarHeightConstraint = avatarView.heightAnchor.constraint(equalToConstant: 220)
    avatarHeightConstraint?.isActive = true

    avatarPenTopConstraint = avatarActionHost.topAnchor.constraint(
      equalTo: topAnchor, constant: 120)
    avatarPenTopConstraint?.isActive = true

    avatarActionWidthConstraint = avatarActionHost.widthAnchor.constraint(
      equalToConstant: NativeProfileAvatarHeroMetrics.expandedSize)
    avatarActionWidthConstraint?.isActive = true

    avatarActionHeightConstraint = avatarActionHost.heightAnchor.constraint(
      equalToConstant: NativeProfileAvatarHeroMetrics.expandedSize)
    avatarActionHeightConstraint?.isActive = true

    heroSpacerHeightConstraint = heroSpacerView.heightAnchor.constraint(equalToConstant: 220)
    heroSpacerHeightConstraint?.isActive = true

    bringSubviewToFront(avatarView)
    bringSubviewToFront(qrButton)
    bringSubviewToFront(editButton)
    bringSubviewToFront(avatarActionHost)

    applyTheme()
  }

  private func rebuildSections() {
    while contentStack.arrangedSubviews.count > 2 {
      let subview = contentStack.arrangedSubviews[2]
      contentStack.removeArrangedSubview(subview)
      subview.removeFromSuperview()
    }

    for section in sections {
      let wrapper = makeSectionView(section)
      contentStack.addArrangedSubview(wrapper)
    }

    contentStack.addArrangedSubview(makeFooterView())
  }

  private func makeSectionView(_ section: NativeSettingsSection) -> UIView {
    let wrapper = UIStackView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    wrapper.axis = .vertical
    wrapper.spacing = 8

    if let title = section.title, !title.isEmpty {
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = .systemFont(ofSize: 13, weight: .semibold)
      label.textColor = theme.secondaryText
      label.text = title.uppercased()
      label.alpha = 0.6
      wrapper.addArrangedSubview(label)
    }

    let card = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = theme.card
    card.layer.cornerRadius = 26
    if #available(iOS 13.0, *) {
      card.layer.cornerCurve = .continuous
    }
    card.clipsToBounds = true
    wrapper.addArrangedSubview(card)

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 0
    card.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      stack.topAnchor.constraint(equalTo: card.topAnchor),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
    ])

    for row in section.rows {
      let rowView = NativeSettingsRowView(
        row: row,
        theme: theme,
        onPress: { [weak self] rowId in
          self?.onNativeEvent(["type": "rowPress", "rowId": rowId])
        },
        onToggle: { [weak self] rowId, value in
          self?.onNativeEvent(["type": "rowToggle", "rowId": rowId, "value": value])
        }
      )
      stack.addArrangedSubview(rowView)
    }

    return wrapper
  }

  private func makeFooterView() -> UIView {
    let footerContainer = UIView()
    footerContainer.translatesAutoresizingMaskIntoConstraints = false
    footerLabel.removeFromSuperview()
    footerContainer.addSubview(footerLabel)
    NSLayoutConstraint.activate([
      footerLabel.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
      footerLabel.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),
      footerLabel.topAnchor.constraint(equalTo: footerContainer.topAnchor, constant: 10),
      footerLabel.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor, constant: -30),
    ])
    return footerContainer
  }

  private func applyTheme() {
    backgroundView.backgroundColor = theme.background
    headerMaskLayer.colors = [
      theme.background.withAlphaComponent(theme.isDark ? 0.16 : 0.10).cgColor,
      theme.background.withAlphaComponent(theme.isDark ? 0.05 : 0.03).cgColor,
      UIColor.clear.cgColor,
    ]
    nameLabel.textColor = theme.text
    subtitleLabel.textColor = theme.secondaryText
    footerLabel.textColor = theme.secondaryText
    footerLabel.alpha = 0.5
    qrButton.iconTintColor = theme.text
    editButton.iconTintColor = theme.text
    penButton.iconTintColor = theme.text
    qrButton.setGlassTheme(isDark: theme.isDark)
    editButton.setGlassTheme(isDark: theme.isDark)
    penButton.setGlassTheme(isDark: theme.isDark)
    badgeView.configure(tier: currentBadgeTier)
    rebuildSections()
  }

  private func updateMetrics() {
    let topInset = safeAreaInsets.top
    let headerHeight = topInset + 60
    let heroTop = NativeProfileAvatarHeroMetrics.expandedTop(for: topInset)
    let collapsedTop = NativeProfileAvatarHeroMetrics.collapsedTop(for: topInset)
    let hostHeight = NativeProfileAvatarHeroMetrics.hostHeight(for: topInset)

    currentHeroTop = heroTop
    currentCollapsedTop = collapsedTop

    headerMaskHeightConstraint?.constant = headerHeight
    qrTopConstraint?.constant = topInset
    editTopConstraint?.constant = topInset
    avatarHeightConstraint?.constant = hostHeight
    avatarPenTopConstraint?.constant = heroTop
    heroSpacerHeightConstraint?.constant = hostHeight

    avatarView.setExpandedSize(NativeProfileAvatarHeroMetrics.expandedSize)
    avatarView.setCollapsedSize(NativeProfileAvatarHeroMetrics.collapsedSize)
    avatarView.setExpandedTopInset(heroTop)
    avatarView.setCollapsedTopInset(collapsedTop)

    avatarView.setScrollOffset(scrollView.contentOffset.y)
  }

  private func updateScrollAnimations(offsetY: CGFloat) {
    let resolvedOffset = max(0, offsetY)
    let travelDistance = max(1.0, currentHeroTop - currentCollapsedTop)
    let progress = max(0.0, min(1.0, resolvedOffset / travelDistance))

    // Smooth scroll tracking on all iOS versions.
    avatarView.setScrollOffset(resolvedOffset)

    // Pen-button tracking — UIKit layer, independent of glass morph.
    let currentAvatarTop = max(
      currentCollapsedTop,
      currentHeroTop - resolvedOffset
    )
    let currentAvatarSize =
      NativeProfileAvatarHeroMetrics.expandedSize
      + ((NativeProfileAvatarHeroMetrics.collapsedSize - NativeProfileAvatarHeroMetrics.expandedSize)
        * progress)

    avatarPenTopConstraint?.constant = currentAvatarTop
    avatarActionWidthConstraint?.constant = currentAvatarSize
    avatarActionHeightConstraint?.constant = currentAvatarSize

    // Pen button fades out as avatar shrinks.
    let penAlpha = max(0, min(1, 1.0 - progress * 2.0))
    avatarActionHost.alpha = penAlpha
    avatarActionHost.isUserInteractionEnabled = penAlpha > 0.5
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateScrollAnimations(offsetY: scrollView.contentOffset.y)
  }

  @objc private func handleHeaderQrPress() {
    onNativeEvent(["type": "headerQr"])
  }

  @objc private func handleHeaderEditPress() {
    onNativeEvent(["type": "headerEdit"])
  }

  @objc private func handleAvatarEditPress() {
    onNativeEvent(["type": "avatarEdit"])
  }
}

extension UIColor {
  fileprivate static func nativeSettingsColor(from raw: String?) -> UIColor? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    if value.hasPrefix("#") {
      return nativeSettingsHexColor(from: value)
    }

    if value.hasPrefix("rgba"),
      let match = nativeSettingsMatchPattern(
        "^rgba\\s*\\((\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*([0-9]*\\.?[0-9]+)\\)$",
        in: value
      )
    {
      let red = CGFloat((match[1] as NSString).doubleValue) / 255.0
      let green = CGFloat((match[2] as NSString).doubleValue) / 255.0
      let blue = CGFloat((match[3] as NSString).doubleValue) / 255.0
      let alpha = CGFloat((match[4] as NSString).doubleValue)
      return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    if value.hasPrefix("rgb"),
      let match = nativeSettingsMatchPattern(
        "^rgb\\s*\\((\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\)$",
        in: value
      )
    {
      let red = CGFloat((match[1] as NSString).doubleValue) / 255.0
      let green = CGFloat((match[2] as NSString).doubleValue) / 255.0
      let blue = CGFloat((match[3] as NSString).doubleValue) / 255.0
      return UIColor(red: red, green: green, blue: blue, alpha: 1.0)
    }

    return nil
  }

  private static func nativeSettingsHexColor(from raw: String) -> UIColor? {
    var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") {
      hex.removeFirst()
    }

    if hex.count == 3 {
      hex = hex.map { "\($0)\($0)" }.joined()
    }

    guard hex.count == 6 || hex.count == 8 else { return nil }
    var value: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

    if hex.count == 6 {
      let red = CGFloat((value >> 16) & 0xFF) / 255.0
      let green = CGFloat((value >> 8) & 0xFF) / 255.0
      let blue = CGFloat(value & 0xFF) / 255.0
      return UIColor(red: red, green: green, blue: blue, alpha: 1.0)
    }

    let red = CGFloat((value >> 24) & 0xFF) / 255.0
    let green = CGFloat((value >> 16) & 0xFF) / 255.0
    let blue = CGFloat((value >> 8) & 0xFF) / 255.0
    let alpha = CGFloat(value & 0xFF) / 255.0
    return UIColor(red: red, green: green, blue: blue, alpha: alpha)
  }

  private static func nativeSettingsMatchPattern(_ pattern: String, in value: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let nsValue = value as NSString
    let range = NSRange(location: 0, length: nsValue.length)
    guard let match = regex.firstMatch(in: value, options: [], range: range) else {
      return nil
    }

    return (0..<match.numberOfRanges).compactMap { index in
      let matchRange = match.range(at: index)
      guard matchRange.location != NSNotFound else { return nil }
      return nsValue.substring(with: matchRange)
    }
  }
}

public final class NativeSettingsMainModule: Module {
  public func definition() -> ModuleDefinition {
    Name("NativeSettingsMain")

    View(NativeSettingsMainView.self) {
      Prop("isDark") { (view: NativeSettingsMainView, value: Bool) in
        view.setIsDark(value)
      }

      Prop("backgroundColor") { (view: NativeSettingsMainView, value: String?) in
        view.setBackgroundColorHex(value)
      }

      Prop("cardColor") { (view: NativeSettingsMainView, value: String?) in
        view.setCardColorHex(value)
      }

      Prop("textColor") { (view: NativeSettingsMainView, value: String?) in
        view.setTextColorHex(value)
      }

      Prop("textSecondaryColor") { (view: NativeSettingsMainView, value: String?) in
        view.setSecondaryTextColorHex(value)
      }

      Prop("primaryColor") { (view: NativeSettingsMainView, value: String?) in
        view.setPrimaryColorHex(value)
      }

      Prop("displayName") { (view: NativeSettingsMainView, value: String?) in
        view.setDisplayName(value)
      }

      Prop("subtitle") { (view: NativeSettingsMainView, value: String?) in
        view.setSubtitle(value)
      }

      Prop("editLabel") { (view: NativeSettingsMainView, value: String?) in
        view.setEditLabel(value)
      }

      Prop("footerText") { (view: NativeSettingsMainView, value: String?) in
        view.setFooterText(value)
      }

      Prop("imageUri") { (view: NativeSettingsMainView, value: String?) in
        view.setAvatarImageUri(value)
      }

      Prop("fallbackText") { (view: NativeSettingsMainView, value: String?) in
        view.setAvatarFallbackText(value)
      }

      Prop("avatarLoading") { (view: NativeSettingsMainView, value: Bool) in
        view.setAvatarLoading(value)
      }

      Prop("badgeTier") { (view: NativeSettingsMainView, value: String?) in
        view.setBadgeTier(value)
      }

      Prop("sections") { (view: NativeSettingsMainView, value: [[String: Any]]) in
        view.setSections(value)
      }

      Events("onNativeEvent")
    }
  }
}
