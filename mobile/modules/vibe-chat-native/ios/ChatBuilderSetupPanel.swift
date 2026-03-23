import UIKit

private func chatBuilderTrimmedString(_ value: Any?) -> String? {
  if let text = value as? String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if let number = value as? NSNumber {
    return number.stringValue
  }
  return nil
}

private func chatBuilderBool(_ value: Any?, default defaultValue: Bool = false) -> Bool {
  if let boolValue = value as? Bool {
    return boolValue
  }
  if let number = value as? NSNumber {
    return number.boolValue
  }
  if let text = value as? String {
    switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "1", "yes", "on":
      return true
    case "false", "0", "no", "off":
      return false
    default:
      break
    }
  }
  return defaultValue
}

private func chatBuilderDouble(_ value: Any?) -> Double? {
  if let value = value as? Double, value.isFinite {
    return value
  }
  if let value = value as? NSNumber {
    let number = value.doubleValue
    return number.isFinite ? number : nil
  }
  if let value = value as? String, let parsed = Double(value), parsed.isFinite {
    return parsed
  }
  return nil
}

private func chatBuilderStringArray(_ value: Any?) -> [String] {
  guard let items = value as? [Any] else { return [] }
  return items.compactMap(chatBuilderTrimmedString)
}

struct ChatBuilderSetupState {
  let status: String
  let phase: String
  let summary: String?
  let confidence: Double?

  init?(raw: [String: Any]?) {
    guard let raw else { return nil }
    let status = chatBuilderTrimmedString(raw["status"]) ?? "idle"
    let phase = chatBuilderTrimmedString(raw["phase"]) ?? "understand"
    self.status = status
    self.phase = phase
    self.summary = chatBuilderTrimmedString(raw["summary"])
    self.confidence = chatBuilderDouble(raw["confidence"])
  }

  var phaseTitle: String {
    switch phase {
    case "configure":
      return "Configure"
    case "review":
      return "Review"
    default:
      return "Understand"
    }
  }

  var statusTitle: String {
    switch status {
    case "clarifying":
      return "Clarifying"
    case "assembling":
      return "Assembling"
    case "review_ready":
      return "Review Ready"
    case "draft_created":
      return "Draft Created"
    case "discovering":
      return "Understanding"
    default:
      return phaseTitle
    }
  }
}

struct ChatBuilderActivityItem {
  let id: String
  let title: String
  let status: String
  let detail: String?
  let agentLabel: String?
  let prompt: String?
  let parentId: String?
  let depth: Int

  init?(raw: [String: Any]) {
    guard
      let id = chatBuilderTrimmedString(raw["id"]),
      let title = chatBuilderTrimmedString(raw["title"])
    else { return nil }
    self.id = id
    self.title = title
    self.status = chatBuilderTrimmedString(raw["status"]) ?? "pending"
    self.detail = chatBuilderTrimmedString(raw["detail"])
    self.agentLabel = chatBuilderTrimmedString(raw["agentLabel"] ?? raw["agent_label"])
    self.prompt = chatBuilderTrimmedString(raw["prompt"])
    self.parentId = chatBuilderTrimmedString(raw["parentId"] ?? raw["parent_id"])
    if let depthNumber = raw["depth"] as? NSNumber {
      self.depth = depthNumber.intValue
    } else if let depth = raw["depth"] as? Int {
      self.depth = depth
    } else {
      self.depth = parentId == nil ? 0 : 1
    }
  }

  var displayText: String {
    if let agentLabel, let detail {
      return "\(agentLabel) • \(detail)"
    }
    if let detail {
      return "\(title) • \(detail)"
    }
    if let agentLabel { return "\(agentLabel) • \(title)" }
    return title
  }

  var secondaryText: String? {
    detail ?? prompt
  }
}

struct ChatBuilderFieldOption {
  let id: String
  let label: String
  let hint: String?

  init?(raw: [String: Any]) {
    guard
      let id = chatBuilderTrimmedString(raw["id"]),
      let label = chatBuilderTrimmedString(raw["label"])
    else { return nil }
    self.id = id
    self.label = label
    self.hint = chatBuilderTrimmedString(raw["hint"])
  }
}

enum ChatBuilderFieldType: String {
  case singleSelect = "single_select"
  case multiSelect = "multi_select"
  case text
  case longText = "long_text"
  case chatPicker = "chat_picker"
}

struct ChatBuilderField {
  let key: String
  let type: ChatBuilderFieldType
  let label: String
  let required: Bool
  let options: [ChatBuilderFieldOption]
  let renderHint: String
  let allowCustom: Bool
  let placeholder: String?
  let value: Any?

  init?(raw: [String: Any]) {
    guard
      let key = chatBuilderTrimmedString(raw["key"]),
      let typeValue = chatBuilderTrimmedString(raw["type"]),
      let type = ChatBuilderFieldType(rawValue: typeValue),
      let label = chatBuilderTrimmedString(raw["label"])
    else { return nil }

    self.key = key
    self.type = type
    self.label = label
    self.required = chatBuilderBool(raw["required"])
    self.options =
      ((raw["options"] as? [[String: Any]]) ?? [])
      .compactMap(ChatBuilderFieldOption.init(raw:))
    self.renderHint = chatBuilderTrimmedString(raw["renderHint"]) ?? "chips"
    self.allowCustom = chatBuilderBool(raw["allowCustom"])
    self.placeholder = chatBuilderTrimmedString(raw["placeholder"])
    self.value = raw["value"]
  }
}

struct ChatBuilderUiRequest {
  let id: String
  let title: String
  let description: String?
  let submitLabel: String
  let allowSkip: Bool
  let fields: [ChatBuilderField]

  init(
    id: String,
    title: String,
    description: String?,
    submitLabel: String,
    allowSkip: Bool,
    fields: [ChatBuilderField]
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.submitLabel = submitLabel
    self.allowSkip = allowSkip
    self.fields = fields
  }

  init?(raw: [String: Any]?) {
    guard
      let raw,
      let id = chatBuilderTrimmedString(raw["id"]),
      let title = chatBuilderTrimmedString(raw["title"])
    else { return nil }

    let fields =
      ((raw["fields"] as? [[String: Any]]) ?? [])
      .compactMap(ChatBuilderField.init(raw:))

    guard !fields.isEmpty else { return nil }

    self.id = id
    self.title = title
    self.description = chatBuilderTrimmedString(raw["description"])
    self.submitLabel = chatBuilderTrimmedString(raw["submitLabel"]) ?? "Continue"
    self.allowSkip = chatBuilderBool(raw["allowSkip"])
    self.fields = fields
  }
}

struct ChatBuilderReviewSection {
  let id: String
  let title: String
  let summary: String
  let editable: Bool
  let requestId: String
  let fields: [ChatBuilderField]

  init?(raw: [String: Any]) {
    guard
      let id = chatBuilderTrimmedString(raw["id"]),
      let title = chatBuilderTrimmedString(raw["title"]),
      let requestId = chatBuilderTrimmedString(raw["requestId"] ?? raw["request_id"])
    else { return nil }
    self.id = id
    self.title = title
    self.summary = chatBuilderTrimmedString(raw["summary"]) ?? ""
    self.editable = raw["editable"] as? Bool ?? true
    self.requestId = requestId
    self.fields =
      ((raw["fields"] as? [[String: Any]]) ?? [])
      .compactMap(ChatBuilderField.init(raw:))
  }
}

struct ChatBuilderPanelPayload {
  let setupState: ChatBuilderSetupState?
  let pendingUiRequest: ChatBuilderUiRequest?
  let reviewSections: [ChatBuilderReviewSection]
  let activity: [ChatBuilderActivityItem]

  init?(raw: [String: Any]?) {
    guard let raw else { return nil }

    self.setupState = ChatBuilderSetupState(raw: raw["setupState"] as? [String: Any])
    self.pendingUiRequest = ChatBuilderUiRequest(raw: raw["pendingUiRequest"] as? [String: Any])
    self.reviewSections =
      ((raw["reviewSections"] as? [[String: Any]]) ?? [])
      .compactMap(ChatBuilderReviewSection.init(raw:))
    self.activity =
      ((raw["activity"] as? [[String: Any]]) ?? [])
      .compactMap(ChatBuilderActivityItem.init(raw:))

    if setupState == nil && pendingUiRequest == nil && reviewSections.isEmpty && activity.isEmpty {
      return nil
    }
  }

  var shouldShowBanner: Bool {
    if pendingUiRequest != nil || !reviewSections.isEmpty || !activity.isEmpty {
      return true
    }
    return setupState?.status != "idle" && setupState != nil
  }
}

struct ChatBuilderPanelTheme {
  let isDark: Bool
  let backgroundColor: UIColor
  let cardColor: UIColor
  let textColor: UIColor
  let secondaryTextColor: UIColor
  let accentColor: UIColor
}

final class ChatBuilderSetupBannerView: UIControl {
  static let preferredHeight: CGFloat = 84.0

  private let blurView = UIVisualEffectView(effect: nil)
  private let iconContainerView = UIView()
  private let iconView = UIImageView()
  private let phaseLabel = UILabel()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let actionPillView = UIView()
  private let actionLabel = UILabel()
  private let shimmerLayer = CAGradientLayer()

  private var theme = ChatBuilderPanelTheme(
    isDark: false,
    backgroundColor: .systemBackground,
    cardColor: .secondarySystemBackground,
    textColor: .label,
    secondaryTextColor: .secondaryLabel,
    accentColor: .systemBlue
  )

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    layer.cornerCurve = .continuous

    blurView.isUserInteractionEnabled = false
    blurView.layer.cornerCurve = .continuous
    blurView.clipsToBounds = true
    addSubview(blurView)

    iconContainerView.layer.cornerCurve = .continuous
    iconContainerView.clipsToBounds = true
    blurView.contentView.addSubview(iconContainerView)

    iconView.contentMode = .scaleAspectFit
    iconContainerView.addSubview(iconView)

    phaseLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    phaseLabel.textAlignment = .left
    blurView.contentView.addSubview(phaseLabel)

    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.numberOfLines = 2
    blurView.contentView.addSubview(titleLabel)

    subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    subtitleLabel.numberOfLines = 2
    blurView.contentView.addSubview(subtitleLabel)

    actionPillView.layer.cornerCurve = .continuous
    actionPillView.clipsToBounds = true
    blurView.contentView.addSubview(actionPillView)

    actionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    actionLabel.textAlignment = .center
    actionPillView.addSubview(actionLabel)

    shimmerLayer.opacity = 0.0
    shimmerLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
    shimmerLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
    shimmerLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.white.withAlphaComponent(0.18).cgColor,
      UIColor.clear.cgColor,
    ]
    blurView.contentView.layer.addSublayer(shimmerLayer)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurView.frame = bounds
    blurView.layer.cornerRadius = bounds.height / 2.0
    shimmerLayer.frame = blurView.bounds

    let contentBounds = bounds.insetBy(dx: 14.0, dy: 12.0)
    let iconSize: CGFloat = 36.0
    iconContainerView.frame = CGRect(x: contentBounds.minX, y: contentBounds.minY + 6.0, width: iconSize, height: iconSize)
    iconContainerView.layer.cornerRadius = 14.0
    iconView.frame = iconContainerView.bounds.insetBy(dx: 8.0, dy: 8.0)

    let actionVisible = !actionPillView.isHidden
    let actionWidth: CGFloat = actionVisible ? 90.0 : 0.0
    let actionX = bounds.width - 14.0 - actionWidth
    actionPillView.frame = actionVisible
      ? CGRect(x: actionX, y: (bounds.height - 34.0) * 0.5, width: actionWidth, height: 34.0)
      : .zero
    actionPillView.layer.cornerRadius = actionPillView.bounds.height / 2.0
    actionLabel.frame = actionPillView.bounds.insetBy(dx: 12.0, dy: 0.0)

    let textLeft = iconContainerView.frame.maxX + 12.0
    let textRight = (actionVisible ? actionPillView.frame.minX : bounds.width - 14.0) - 10.0
    let textWidth = max(0.0, textRight - textLeft)

    phaseLabel.frame = CGRect(x: textLeft, y: contentBounds.minY, width: textWidth, height: 14.0)
    let titleSize = titleLabel.sizeThatFits(CGSize(width: textWidth, height: 40.0))
    titleLabel.frame = CGRect(x: textLeft, y: phaseLabel.frame.maxY + 2.0, width: textWidth, height: min(40.0, titleSize.height))
    let subtitleHeight = max(16.0, min(34.0, subtitleLabel.sizeThatFits(CGSize(width: textWidth, height: 34.0)).height))
    subtitleLabel.frame = CGRect(x: textLeft, y: titleLabel.frame.maxY + 2.0, width: textWidth, height: subtitleHeight)
  }

  func applyTheme(_ theme: ChatBuilderPanelTheme) {
    self.theme = theme
    blurView.effect =
      UIBlurEffect(style: theme.isDark ? .systemThinMaterialDark : .systemThinMaterialLight)
    blurView.contentView.backgroundColor = theme.backgroundColor.withAlphaComponent(theme.isDark ? 0.28 : 0.18)
    iconContainerView.backgroundColor = theme.accentColor.withAlphaComponent(theme.isDark ? 0.28 : 0.16)
    iconView.tintColor = theme.accentColor
    phaseLabel.textColor = theme.secondaryTextColor
    titleLabel.textColor = theme.textColor
    subtitleLabel.textColor = theme.secondaryTextColor
    actionPillView.backgroundColor = theme.accentColor.withAlphaComponent(theme.isDark ? 0.92 : 0.14)
    actionLabel.textColor = theme.isDark ? .white : theme.accentColor
  }

  func configure(panel: ChatBuilderPanelPayload?) {
    guard let panel, panel.shouldShowBanner else {
      isHidden = true
      alpha = 0.0
      stopShimmer()
      return
    }

    let activeItem =
      panel.activity.first(where: { $0.status == "in_progress" })
      ?? panel.activity.first(where: { $0.status == "attention" })

    let actionTitle: String?
    if let request = panel.pendingUiRequest {
      phaseLabel.text = (panel.setupState?.phaseTitle ?? "Understand").uppercased()
      titleLabel.text = request.title
      subtitleLabel.text =
        request.description
        ?? activeItem?.displayText
        ?? panel.setupState?.summary
      actionTitle = request.submitLabel
    } else if !panel.reviewSections.isEmpty {
      phaseLabel.text = (panel.setupState?.phaseTitle ?? "Review").uppercased()
      titleLabel.text = panel.setupState?.summary ?? "Review the draft before you create it"
      subtitleLabel.text =
        activeItem?.displayText
        ?? "Edit any section, then create the draft when it looks right."
      actionTitle = "Review"
    } else {
      phaseLabel.text = (panel.setupState?.phaseTitle ?? "Configure").uppercased()
      titleLabel.text = panel.setupState?.summary ?? panel.setupState?.statusTitle ?? "Building your agent"
      subtitleLabel.text = activeItem?.displayText
      actionTitle = nil
    }

    iconView.image = UIImage(
      systemName:
        panel.reviewSections.isEmpty
        ? (panel.pendingUiRequest == nil ? "sparkles" : "slider.horizontal.3")
        : "checkmark.seal"
    )
    actionLabel.text = actionTitle
    actionPillView.isHidden = actionTitle == nil
    isHidden = false
    alpha = 1.0
    if activeItem?.status == "in_progress" {
      startShimmer()
    } else {
      stopShimmer()
    }
    setNeedsLayout()
  }

  private func startShimmer() {
    shimmerLayer.opacity = 1.0
    if shimmerLayer.animation(forKey: "builderShimmer") != nil {
      return
    }
    let animation = CABasicAnimation(keyPath: "transform.translation.x")
    animation.fromValue = -bounds.width
    animation.toValue = bounds.width
    animation.duration = 1.2
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    shimmerLayer.add(animation, forKey: "builderShimmer")
  }

  private func stopShimmer() {
    shimmerLayer.removeAnimation(forKey: "builderShimmer")
    shimmerLayer.opacity = 0.0
  }
}

private final class ChatBuilderActivityTreeRowView: UIView {
  private let item: ChatBuilderActivityItem
  private let theme: ChatBuilderPanelTheme
  private let connectorView = UIView()
  private let statusView = UIView()
  private let titleLabel = UILabel()
  private let metaLabel = UILabel()
  private let detailLabel = UILabel()

  init(item: ChatBuilderActivityItem, theme: ChatBuilderPanelTheme) {
    self.item = item
    self.theme = theme
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    connectorView.translatesAutoresizingMaskIntoConstraints = false
    connectorView.backgroundColor = theme.secondaryTextColor.withAlphaComponent(0.18)
    addSubview(connectorView)

    statusView.translatesAutoresizingMaskIntoConstraints = false
    statusView.layer.cornerCurve = .continuous
    statusView.clipsToBounds = true
    addSubview(statusView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: item.depth == 0 ? 15 : 14, weight: item.depth == 0 ? .semibold : .medium)
    titleLabel.textColor = theme.textColor
    titleLabel.numberOfLines = 0
    titleLabel.text = item.title
    addSubview(titleLabel)

    metaLabel.translatesAutoresizingMaskIntoConstraints = false
    metaLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    metaLabel.textColor = theme.accentColor
    metaLabel.numberOfLines = 1
    metaLabel.text = item.agentLabel?.uppercased()
    metaLabel.isHidden = (metaLabel.text ?? "").isEmpty
    addSubview(metaLabel)

    detailLabel.translatesAutoresizingMaskIntoConstraints = false
    detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
    detailLabel.textColor = theme.secondaryTextColor
    detailLabel.numberOfLines = 0
    detailLabel.text = item.secondaryText
    detailLabel.isHidden = (detailLabel.text ?? "").isEmpty
    addSubview(detailLabel)

    let leftInset = CGFloat(12 + (max(0, item.depth) * 18))
    NSLayoutConstraint.activate([
      connectorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leftInset + 4.0),
      connectorView.topAnchor.constraint(equalTo: topAnchor),
      connectorView.bottomAnchor.constraint(equalTo: bottomAnchor),
      connectorView.widthAnchor.constraint(equalToConstant: item.depth == 0 ? 0.0 : 1.0),

      statusView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leftInset),
      statusView.topAnchor.constraint(equalTo: topAnchor, constant: item.depth == 0 ? 4.0 : 6.0),
      statusView.widthAnchor.constraint(equalToConstant: item.depth == 0 ? 10.0 : 8.0),
      statusView.heightAnchor.constraint(equalTo: statusView.widthAnchor),

      metaLabel.topAnchor.constraint(equalTo: topAnchor),
      metaLabel.leadingAnchor.constraint(equalTo: statusView.trailingAnchor, constant: 12.0),
      metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

      titleLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: metaLabel.isHidden ? 0.0 : 2.0),
      titleLabel.leadingAnchor.constraint(equalTo: statusView.trailingAnchor, constant: 12.0),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    if detailLabel.isHidden {
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    } else {
      NSLayoutConstraint.activate([
        detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4.0),
        detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    applyStatusStyle()
  }

  required init?(coder: NSCoder) {
    nil
  }

  private func applyStatusStyle() {
    switch item.status {
    case "completed":
      statusView.backgroundColor = UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
      detailLabel.textColor = theme.secondaryTextColor
    case "attention":
      statusView.backgroundColor = UIColor(red: 1.0, green: 187.0 / 255.0, blue: 92.0 / 255.0, alpha: 1.0)
      detailLabel.textColor = theme.accentColor
    case "in_progress":
      statusView.backgroundColor = theme.accentColor
      startPulse()
    default:
      statusView.backgroundColor = theme.secondaryTextColor.withAlphaComponent(0.28)
    }
  }

  private func startPulse() {
    if layer.animation(forKey: "builderPulse") != nil {
      return
    }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 0.45
    animation.toValue = 1.0
    animation.duration = 0.9
    animation.repeatCount = .infinity
    animation.autoreverses = true
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(animation, forKey: "builderPulse")
  }
}

private final class ChatBuilderOptionButton: UIButton {
  let optionId: String
  let optionLabel: String

  init(option: ChatBuilderFieldOption) {
    self.optionId = option.id
    self.optionLabel = option.label
    super.init(frame: .zero)
    contentHorizontalAlignment = .left
    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12.0,
      leading: 14.0,
      bottom: 12.0,
      trailing: 14.0
    )
    self.configuration = configuration
    titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel?.numberOfLines = 2
    layer.cornerRadius = 16.0
    layer.cornerCurve = .continuous
    clipsToBounds = true
    setTitle(option.label, for: .normal)
  }

  required init?(coder: NSCoder) {
    nil
  }
}

private final class ChatBuilderFormFieldView: UIView {
  let field: ChatBuilderField

  private let theme: ChatBuilderPanelTheme
  private let titleLabel = UILabel()
  private let stackView = UIStackView()
  private let optionsStack = UIStackView()
  private let helperLabel = UILabel()

  private var segmentedControl: UISegmentedControl?
  private var optionButtons: [ChatBuilderOptionButton] = []
  private var selectedSingleValue: String?
  private var selectedMultiValues = Set<String>()
  private var singleTextField: UITextField?
  private var multiLineTextView: UITextView?
  private var customTextField: UITextField?

  init(field: ChatBuilderField, theme: ChatBuilderPanelTheme) {
    self.field = field
    self.theme = theme
    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = theme.cardColor
    layer.cornerRadius = 22.0
    layer.cornerCurve = .continuous

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.numberOfLines = 0
    titleLabel.textColor = theme.textColor
    titleLabel.text = field.required ? "\(field.label) *" : field.label
    addSubview(titleLabel)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.spacing = 12.0
    addSubview(stackView)

    helperLabel.translatesAutoresizingMaskIntoConstraints = false
    helperLabel.font = .systemFont(ofSize: 12, weight: .medium)
    helperLabel.textColor = theme.secondaryTextColor
    helperLabel.numberOfLines = 0
    if field.allowCustom {
      helperLabel.text = "You can also type a custom value."
    } else if let placeholder = field.placeholder {
      helperLabel.text = placeholder
    } else {
      helperLabel.text = nil
    }

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16.0),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      stackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12.0),
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16.0),
    ])

    buildFieldContent()
    applyInitialValue()
  }

  required init?(coder: NSCoder) {
    nil
  }

  private func buildFieldContent() {
    switch field.type {
    case .singleSelect:
      buildSingleSelectField()
    case .multiSelect:
      buildMultiSelectField()
    case .text, .chatPicker:
      buildTextField(multiline: false)
    case .longText:
      buildTextField(multiline: true)
    }

    if field.allowCustom && (field.type == .singleSelect || field.type == .multiSelect) {
      let textField = makeTextField(placeholder: field.placeholder ?? "Custom value")
      customTextField = textField
      stackView.addArrangedSubview(textField)
    }

    if let text = helperLabel.text, !text.isEmpty {
      stackView.addArrangedSubview(helperLabel)
    }
  }

  private func buildSingleSelectField() {
    if field.renderHint == "tabs" && field.options.count > 1 && field.options.count <= 4 && !field.allowCustom {
      let control = UISegmentedControl(items: field.options.map(\.label))
      control.translatesAutoresizingMaskIntoConstraints = false
      control.addTarget(self, action: #selector(handleSegmentChanged(_:)), for: .valueChanged)
      segmentedControl = control
      stackView.addArrangedSubview(control)
      return
    }

    optionsStack.translatesAutoresizingMaskIntoConstraints = false
    optionsStack.axis = .vertical
    optionsStack.spacing = 10.0
    stackView.addArrangedSubview(optionsStack)

    for option in field.options {
      let button = ChatBuilderOptionButton(option: option)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.addTarget(self, action: #selector(handleOptionButtonPressed(_:)), for: .touchUpInside)
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46.0).isActive = true
      optionButtons.append(button)
      optionsStack.addArrangedSubview(button)
    }
    refreshOptionButtonStyles()
  }

  private func buildMultiSelectField() {
    optionsStack.translatesAutoresizingMaskIntoConstraints = false
    optionsStack.axis = .vertical
    optionsStack.spacing = 10.0
    stackView.addArrangedSubview(optionsStack)

    for option in field.options {
      let button = ChatBuilderOptionButton(option: option)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.addTarget(self, action: #selector(handleOptionButtonPressed(_:)), for: .touchUpInside)
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46.0).isActive = true
      optionButtons.append(button)
      optionsStack.addArrangedSubview(button)
    }
    refreshOptionButtonStyles()
  }

  private func buildTextField(multiline: Bool) {
    if multiline {
      let textView = UITextView()
      textView.translatesAutoresizingMaskIntoConstraints = false
      textView.font = .systemFont(ofSize: 15, weight: .medium)
      textView.textColor = theme.textColor
      textView.backgroundColor = theme.backgroundColor.withAlphaComponent(theme.isDark ? 0.5 : 0.75)
      textView.layer.cornerRadius = 16.0
      textView.textContainerInset = UIEdgeInsets(top: 12.0, left: 12.0, bottom: 12.0, right: 12.0)
      textView.isScrollEnabled = false
      multiLineTextView = textView
      stackView.addArrangedSubview(textView)
      textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120.0).isActive = true
    } else {
      let placeholder =
        field.placeholder
        ?? (field.type == .chatPicker ? "Enter the destination chat ID" : "Type your answer")
      let textField = makeTextField(placeholder: placeholder)
      singleTextField = textField
      stackView.addArrangedSubview(textField)
    }
  }

  private func makeTextField(placeholder: String) -> UITextField {
    let textField = UITextField()
    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.borderStyle = .none
    textField.font = .systemFont(ofSize: 15, weight: .medium)
    textField.textColor = theme.textColor
    textField.tintColor = theme.accentColor
    textField.backgroundColor = theme.backgroundColor.withAlphaComponent(theme.isDark ? 0.5 : 0.75)
    textField.layer.cornerRadius = 16.0
    textField.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 12.0, height: 1.0))
    textField.leftViewMode = .always
    textField.rightView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 12.0, height: 1.0))
    textField.rightViewMode = .always
    textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 48.0).isActive = true
    textField.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: theme.secondaryTextColor.withAlphaComponent(0.72)]
    )
    return textField
  }

  private func applyInitialValue() {
    switch field.type {
    case .singleSelect:
      if let value = chatBuilderTrimmedString(field.value) {
        if field.options.contains(where: { $0.id == value }) {
          selectedSingleValue = value
        } else if field.allowCustom {
          customTextField?.text = value
        }
      }
      if let control = segmentedControl, let selectedSingleValue,
        let index = field.options.firstIndex(where: { $0.id == selectedSingleValue })
      {
        control.selectedSegmentIndex = index
      }
      refreshOptionButtonStyles()
    case .multiSelect:
      let values = chatBuilderStringArray(field.value)
      let optionIds = Set(field.options.map(\.id))
      selectedMultiValues = Set(values.filter { optionIds.contains($0) })
      if field.allowCustom {
        let customValues = values.filter { !optionIds.contains($0) }
        if !customValues.isEmpty {
          customTextField?.text = customValues.joined(separator: ", ")
        }
      }
      refreshOptionButtonStyles()
    case .text, .chatPicker:
      singleTextField?.text = chatBuilderTrimmedString(field.value)
    case .longText:
      multiLineTextView?.text = chatBuilderTrimmedString(field.value)
    }
  }

  @objc private func handleSegmentChanged(_ sender: UISegmentedControl) {
    let index = sender.selectedSegmentIndex
    guard index >= 0, index < field.options.count else { return }
    selectedSingleValue = field.options[index].id
  }

  @objc private func handleOptionButtonPressed(_ sender: ChatBuilderOptionButton) {
    switch field.type {
    case .singleSelect:
      if selectedSingleValue == sender.optionId {
        selectedSingleValue = nil
      } else {
        selectedSingleValue = sender.optionId
      }
      if let control = segmentedControl {
        if let selectedSingleValue,
          let index = field.options.firstIndex(where: { $0.id == selectedSingleValue })
        {
          control.selectedSegmentIndex = index
        } else {
          control.selectedSegmentIndex = UISegmentedControl.noSegment
        }
      }
    case .multiSelect:
      if selectedMultiValues.contains(sender.optionId) {
        selectedMultiValues.remove(sender.optionId)
      } else {
        selectedMultiValues.insert(sender.optionId)
      }
    default:
      break
    }
    refreshOptionButtonStyles()
  }

  private func refreshOptionButtonStyles() {
    for button in optionButtons {
      let isSelected: Bool
      switch field.type {
      case .singleSelect:
        isSelected = selectedSingleValue == button.optionId
      case .multiSelect:
        isSelected = selectedMultiValues.contains(button.optionId)
      default:
        isSelected = false
      }
      button.backgroundColor =
        isSelected
        ? theme.accentColor.withAlphaComponent(theme.isDark ? 0.30 : 0.14)
        : theme.backgroundColor.withAlphaComponent(theme.isDark ? 0.45 : 0.65)
      button.setTitle(isSelected ? "✓ \(button.optionLabel)" : button.optionLabel, for: .normal)
      button.setTitleColor(isSelected ? theme.accentColor : theme.textColor, for: .normal)
    }
  }

  func validate() -> String? {
    guard field.required else { return nil }
    let answer = currentAnswer()

    switch answer {
    case let value as String:
      return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? field.label : nil
    case let values as [String]:
      return values.isEmpty ? field.label : nil
    case nil:
      return field.label
    default:
      return nil
    }
  }

  func currentAnswer() -> Any? {
    switch field.type {
    case .singleSelect:
      if let custom = chatBuilderTrimmedString(customTextField?.text), !custom.isEmpty {
        return custom
      }
      if let control = segmentedControl, control.selectedSegmentIndex >= 0,
        control.selectedSegmentIndex < field.options.count
      {
        return field.options[control.selectedSegmentIndex].id
      }
      return selectedSingleValue
    case .multiSelect:
      var values = field.options.compactMap { option in
        selectedMultiValues.contains(option.id) ? option.id : nil
      }
      if let custom = chatBuilderTrimmedString(customTextField?.text), !custom.isEmpty {
        values.append(custom)
      }
      return values.isEmpty ? nil : values
    case .text, .chatPicker:
      return chatBuilderTrimmedString(singleTextField?.text)
    case .longText:
      return chatBuilderTrimmedString(multiLineTextView?.text)
    }
  }

  func summarySnippet() -> String? {
    switch currentAnswer() {
    case let value as String:
      return value
    case let values as [String]:
      return values.joined(separator: ", ")
    default:
      return nil
    }
  }
}

private final class ChatBuilderReviewSectionCardView: UIControl {
  private let titleLabel = UILabel()
  private let summaryLabel = UILabel()
  private let actionLabel = UILabel()
  private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))

  init(section: ChatBuilderReviewSection, theme: ChatBuilderPanelTheme) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = theme.cardColor
    layer.cornerRadius = 22.0
    layer.cornerCurve = .continuous

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textColor = theme.textColor
    titleLabel.text = section.title
    addSubview(titleLabel)

    summaryLabel.translatesAutoresizingMaskIntoConstraints = false
    summaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
    summaryLabel.textColor = theme.secondaryTextColor
    summaryLabel.numberOfLines = 0
    summaryLabel.text = section.summary.isEmpty ? "Edit this section" : section.summary
    addSubview(summaryLabel)

    actionLabel.translatesAutoresizingMaskIntoConstraints = false
    actionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    actionLabel.textColor = theme.accentColor
    actionLabel.text = section.editable ? "Edit" : "View"
    addSubview(actionLabel)

    chevronView.translatesAutoresizingMaskIntoConstraints = false
    chevronView.contentMode = .scaleAspectFit
    chevronView.tintColor = theme.secondaryTextColor
    addSubview(chevronView)

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16.0),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionLabel.leadingAnchor, constant: -12.0),
      summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6.0),
      summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -44.0),
      summaryLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16.0),
      actionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      actionLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -4.0),
      chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      chevronView.widthAnchor.constraint(equalToConstant: 10.0),
      chevronView.heightAnchor.constraint(equalToConstant: 16.0),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }
}

enum ChatBuilderPanelMode {
  case progress
  case request(ChatBuilderUiRequest)
  case review([ChatBuilderReviewSection])
}

final class ChatBuilderPanelController: UIViewController {
  private let mode: ChatBuilderPanelMode
  private let theme: ChatBuilderPanelTheme
  private let setupState: ChatBuilderSetupState?
  private let activity: [ChatBuilderActivityItem]

  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let stackView = UIStackView()

  private var fieldViews: [ChatBuilderFormFieldView] = []
  var onSubmitRequest: ((String, [String: Any], String?) -> Void)?
  var onCreateDraft: (() -> Void)?
  var onControllerDismissed: (() -> Void)?

  init(
    mode: ChatBuilderPanelMode,
    theme: ChatBuilderPanelTheme,
    setupState: ChatBuilderSetupState?,
    activity: [ChatBuilderActivityItem]
  ) {
    self.mode = mode
    self.theme = theme
    self.setupState = setupState
    self.activity = activity
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    configureNavigation()
    configureLayout()
    buildContent()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      onControllerDismissed?()
    }
  }

  private func configureNavigation() {
    switch mode {
    case .progress:
      title = "Agent Progress"
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(handleClosePressed)
      )
    case .request(let request):
      title = request.title
      if request.allowSkip {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
          title: "Skip",
          style: .plain,
          target: self,
          action: #selector(handleSkipPressed)
        )
      }
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: request.submitLabel,
        style: .done,
        target: self,
        action: #selector(handleSubmitPressed)
      )
    case .review:
      title = "Review Draft"
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(handleClosePressed)
      )
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: "Create Draft",
        style: .done,
        target: self,
        action: #selector(handleCreateDraftPressed)
      )
    }
    navigationController?.navigationBar.tintColor = theme.accentColor
  }

  private func configureLayout() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    view.addSubview(scrollView)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.spacing = 14.0
    contentView.addSubview(stackView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20.0),
      stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16.0),
      stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16.0),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24.0),
    ])
  }

  private func buildContent() {
    if let headerCard = makeHeaderCard() {
      stackView.addArrangedSubview(headerCard)
    }

    switch mode {
    case .progress:
      buildProgressContent()
    case .request(let request):
      buildRequestContent(request)
    case .review(let sections):
      buildReviewContent(sections)
    }
  }

  private func makeHeaderCard() -> UIView? {
    guard setupState != nil || !activity.isEmpty else { return nil }

    let card = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = theme.cardColor
    card.layer.cornerRadius = 22.0
    card.layer.cornerCurve = .continuous

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 10.0
    card.addSubview(stack)

    if let setupState {
      let phaseLabel = UILabel()
      phaseLabel.font = .systemFont(ofSize: 12, weight: .semibold)
      phaseLabel.textColor = theme.secondaryTextColor
      phaseLabel.text = "\(setupState.phaseTitle) • \(setupState.statusTitle)"
      stack.addArrangedSubview(phaseLabel)

      if let summary = setupState.summary, !summary.isEmpty {
        let summaryLabel = UILabel()
        summaryLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        summaryLabel.textColor = theme.textColor
        summaryLabel.numberOfLines = 0
        summaryLabel.text = summary
        stack.addArrangedSubview(summaryLabel)
      }
    }

    let sortedActivity = activity

    if !sortedActivity.isEmpty {
      let activityLabel = UILabel()
      activityLabel.font = .systemFont(ofSize: 12, weight: .semibold)
      activityLabel.textColor = theme.secondaryTextColor
      activityLabel.text = "LIVE WORKERS"
      stack.addArrangedSubview(activityLabel)
    }

    for item in sortedActivity {
      let row = ChatBuilderActivityTreeRowView(item: item, theme: theme)
      stack.addArrangedSubview(row)
    }

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16.0),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16.0),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16.0),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16.0),
    ])

    return card
  }

  private func buildRequestContent(_ request: ChatBuilderUiRequest) {
    if let description = request.description, !description.isEmpty {
      let descriptionLabel = UILabel()
      descriptionLabel.font = .systemFont(ofSize: 15, weight: .medium)
      descriptionLabel.textColor = theme.secondaryTextColor
      descriptionLabel.numberOfLines = 0
      descriptionLabel.text = description
      stackView.addArrangedSubview(descriptionLabel)
    }

    for field in request.fields {
      let fieldView = ChatBuilderFormFieldView(field: field, theme: theme)
      fieldViews.append(fieldView)
      stackView.addArrangedSubview(fieldView)
    }
  }

  private func buildProgressContent() {
    let introLabel = UILabel()
    introLabel.font = .systemFont(ofSize: 15, weight: .medium)
    introLabel.textColor = theme.secondaryTextColor
    introLabel.numberOfLines = 0
    introLabel.text = "The builder is still working. These hidden workers are deciding the prompt, tools, and safety rules in real time."
    stackView.addArrangedSubview(introLabel)
  }

  private func buildReviewContent(_ sections: [ChatBuilderReviewSection]) {
    let introLabel = UILabel()
    introLabel.font = .systemFont(ofSize: 15, weight: .medium)
    introLabel.textColor = theme.secondaryTextColor
    introLabel.numberOfLines = 0
    introLabel.text = "Edit any section that needs work. Create the draft when everything looks correct."
    stackView.addArrangedSubview(introLabel)

    for section in sections {
      let card = ChatBuilderReviewSectionCardView(section: section, theme: theme)
      card.addTarget(self, action: #selector(handleReviewSectionTapped(_:)), for: .touchUpInside)
      card.accessibilityIdentifier = section.requestId
      stackView.addArrangedSubview(card)
    }

    let secondaryButton = makeSecondaryButton(title: "Keep Refining", action: #selector(handleClosePressed))
    stackView.addArrangedSubview(secondaryButton)
  }

  private func makeSecondaryButton(title: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 14.0, leading: 16.0, bottom: 14.0, trailing: 16.0)
    button.configuration = configuration
    button.layer.cornerRadius = 18.0
    button.layer.cornerCurve = .continuous
    button.backgroundColor = theme.cardColor
    button.setTitle(title, for: .normal)
    button.setTitleColor(theme.accentColor, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52.0).isActive = true
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  @objc private func handleSkipPressed() {
    guard case let .request(request) = mode else { return }
    onSubmitRequest?(request.id, [:], "Skipped setup question")
    dismissPanel()
  }

  @objc private func handleSubmitPressed() {
    guard case let .request(request) = mode else { return }

    var answers: [String: Any] = [:]
    for fieldView in fieldViews {
      if let missingFieldLabel = fieldView.validate() {
        presentValidationAlert(message: "Please complete \(missingFieldLabel.lowercased()) before continuing.")
        return
      }
      if let answer = fieldView.currentAnswer() {
        answers[fieldView.field.key] = answer
      }
    }

    let snippets =
      fieldViews
      .compactMap { view -> String? in
        guard let snippet = view.summarySnippet(), !snippet.isEmpty else { return nil }
        return snippet
      }
      .prefix(2)
    let summary =
      snippets.isEmpty
      ? request.title
      : snippets.joined(separator: " • ")

    onSubmitRequest?(request.id, answers, summary)
    dismissPanel()
  }

  @objc private func handleCreateDraftPressed() {
    onCreateDraft?()
    dismissPanel()
  }

  @objc private func handleClosePressed() {
    dismissPanel()
  }

  @objc private func handleReviewSectionTapped(_ sender: UIControl) {
    guard
      case let .review(sections) = mode,
      let requestId = sender.accessibilityIdentifier,
      let section = sections.first(where: { $0.requestId == requestId })
    else { return }

    let request = ChatBuilderUiRequest(
      id: section.requestId,
      title: section.title,
      description: section.summary,
      submitLabel: "Save changes",
      allowSkip: false,
      fields: section.fields
    )

    let controller = ChatBuilderPanelController(
      mode: .request(request),
      theme: theme,
      setupState: setupState,
      activity: activity
    )
    controller.onSubmitRequest = { [weak self] requestId, answers, summary in
      self?.onSubmitRequest?(requestId, answers, summary)
      self?.dismissPanel()
    }
    controller.onCreateDraft = onCreateDraft
    controller.onControllerDismissed = onControllerDismissed
    navigationController?.pushViewController(controller, animated: true)
  }

  private func dismissPanel() {
    if let navigationController, navigationController.presentingViewController != nil {
      navigationController.dismiss(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  private func presentValidationAlert(message: String) {
    let alert = UIAlertController(title: "Missing Information", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
