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

private func chatBuilderOptionLabel(for value: String, field: ChatBuilderField) -> String {
  field.options.first(where: { $0.id == value })?.label ?? value
}

private func chatBuilderFieldDisplayValue(_ field: ChatBuilderField?) -> String? {
  guard let field else { return nil }

  if let text = chatBuilderTrimmedString(field.value) {
    return chatBuilderOptionLabel(for: text, field: field)
  }

  let values = chatBuilderStringArray(field.value)
  guard !values.isEmpty else { return nil }
  return values.map { chatBuilderOptionLabel(for: $0, field: field) }.joined(separator: ", ")
}

private func chatBuilderCondensedText(_ value: String?, maxLength: Int = 96) -> String? {
  guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    return nil
  }

  let singleLine = value.replacingOccurrences(of: "\n", with: " ")
  guard singleLine.count > maxLength else { return singleLine }
  let endIndex = singleLine.index(singleLine.startIndex, offsetBy: maxLength)
  return "\(singleLine[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)…"
}

private func chatBuilderResolvedHeaderInset(in controller: UIViewController) -> CGFloat {
  guard let navigationController = controller.navigationController else {
    return controller.view.safeAreaInsets.top
  }
  let navBarFrame = navigationController.view.convert(navigationController.navigationBar.frame, to: controller.view)
  return max(0.0, max(controller.view.safeAreaInsets.top, navBarFrame.maxY))
}

private func chatBuilderDerivedAgentName(fromPrompt value: String?) -> String? {
  guard let prompt = value?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
    return nil
  }

  let patterns = [
    #"(?i)\byou are\s+([A-Z][A-Za-z0-9'_\-]*(?:\s+[A-Z][A-Za-z0-9'_\-]*){0,2})"#,
    #"(?i)\byour name is\s+([A-Z][A-Za-z0-9'_\-]*(?:\s+[A-Z][A-Za-z0-9'_\-]*){0,2})"#,
    #"(?i)\bname\s*:\s*([A-Z][A-Za-z0-9'_\-]*(?:\s+[A-Z][A-Za-z0-9'_\-]*){0,2})"#
  ]

  for pattern in patterns {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
    let nsRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
    guard let match = regex.firstMatch(in: prompt, options: [], range: nsRange), match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: prompt)
    else { continue }

    let candidate = String(prompt[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    if let condensed = chatBuilderCondensedText(candidate, maxLength: 24) {
      return condensed
    }
  }

  return nil
}

private func chatBuilderPreservedAnswers(for section: ChatBuilderReviewSection) -> [String: Any] {
  var answers: [String: Any] = [:]
  for field in section.fields {
    if let value = field.value {
      answers[field.key] = value
    }
  }
  return answers
}

struct ChatBuilderPanelPayload {
  let setupState: ChatBuilderSetupState?
  let pendingUiRequest: ChatBuilderUiRequest?
  let reviewSections: [ChatBuilderReviewSection]
  let activity: [ChatBuilderActivityItem]
  let agentEnabled: Bool?

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
    self.agentEnabled = raw["agentEnabled"] as? Bool

    if setupState == nil && pendingUiRequest == nil && reviewSections.isEmpty && activity.isEmpty {
      return nil
    }
  }

}

struct ChatBuilderPanelTheme {
  let isDark: Bool
  let backgroundColor: UIColor
  let cardColor: UIColor
  let inputColor: UIColor
  let textColor: UIColor
  let secondaryTextColor: UIColor
  let accentColor: UIColor
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
      textView.backgroundColor = theme.inputColor
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
    textField.backgroundColor = theme.inputColor
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
        : theme.inputColor
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

private final class ChatBuilderPanelCardView: UIView {
  let contentStack = UIStackView()

  init(theme: ChatBuilderPanelTheme, padding: CGFloat = 18.0, spacing: CGFloat = 12.0) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = theme.cardColor
    layer.cornerRadius = 24.0
    layer.cornerCurve = .continuous

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = spacing
    addSubview(contentStack)

    NSLayoutConstraint.activate([
      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

private final class ChatBuilderPanelActionRow: UIControl {
  private let highlightView = UIView()
  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let chevronView = UIImageView()
  private let dividerView = UIView()

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
    theme: ChatBuilderPanelTheme,
    showsChevron: Bool = true,
    showsDivider: Bool = false
  ) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    highlightView.translatesAutoresizingMaskIntoConstraints = false
    highlightView.backgroundColor = theme.textColor.withAlphaComponent(0.05)
    highlightView.alpha = 0.0
    addSubview(highlightView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
    titleLabel.textColor = theme.textColor
    titleLabel.numberOfLines = 1
    titleLabel.text = title
    addSubview(titleLabel)

    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    valueLabel.font = .systemFont(ofSize: 15, weight: .regular)
    valueLabel.textColor = theme.secondaryTextColor
    valueLabel.textAlignment = .right
    valueLabel.numberOfLines = 1
    valueLabel.text = value
    valueLabel.isHidden = value == nil
    addSubview(valueLabel)

    chevronView.translatesAutoresizingMaskIntoConstraints = false
    chevronView.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    )
    chevronView.tintColor = theme.secondaryTextColor.withAlphaComponent(0.55)
    chevronView.isHidden = !showsChevron
    addSubview(chevronView)

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    dividerView.backgroundColor = theme.secondaryTextColor.withAlphaComponent(0.12)
    dividerView.isHidden = !showsDivider
    addSubview(dividerView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 56.0),
      highlightView.topAnchor.constraint(equalTo: topAnchor),
      highlightView.leadingAnchor.constraint(equalTo: leadingAnchor),
      highlightView.trailingAnchor.constraint(equalTo: trailingAnchor),
      highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),
      chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12.0),
      dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 0.5),
    ])

    if showsChevron {
      valueLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8.0)
        .isActive = true
    } else {
      valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0).isActive = true
    }
  }

  required init?(coder: NSCoder) { nil }
}

private final class ChatBuilderToggleRow: UIView {
  private let titleLabel = UILabel()
  private let switchControl = UISwitch()
  private let dividerView = UIView()

  var onToggle: ((Bool) -> Void)?
  var isOn: Bool { switchControl.isOn }

  init(title: String, isOn: Bool, theme: ChatBuilderPanelTheme, showsDivider: Bool = false) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
    titleLabel.textColor = theme.textColor
    titleLabel.text = title
    addSubview(titleLabel)

    switchControl.translatesAutoresizingMaskIntoConstraints = false
    switchControl.onTintColor = .systemGreen
    switchControl.setOn(isOn, animated: false)
    switchControl.addTarget(self, action: #selector(handleToggle(_:)), for: .valueChanged)
    addSubview(switchControl)

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    dividerView.backgroundColor = theme.secondaryTextColor.withAlphaComponent(0.12)
    dividerView.isHidden = !showsDivider
    addSubview(dividerView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 56.0),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: switchControl.leadingAnchor, constant: -12.0),
      switchControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      switchControl.centerYAnchor.constraint(equalTo: centerYAnchor),
      dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 0.5),
    ])
  }

  required init?(coder: NSCoder) { nil }

  @objc private func handleToggle(_ sender: UISwitch) {
    onToggle?(sender.isOn)
  }

  func setOn(_ value: Bool) {
    switchControl.setOn(value, animated: true)
  }
}

private final class ChatBuilderPromptEditorController: UIViewController {
  private let section: ChatBuilderReviewSection
  private let field: ChatBuilderField
  private let theme: ChatBuilderPanelTheme
  private let textView = UITextView()
  private let topMaskView = UIView()
  private let topMaskGradient = CAGradientLayer()
  private var textViewTopConstraint: NSLayoutConstraint?

  var onSubmit: ((String, [String: Any], String?) -> Void)?

  init(section: ChatBuilderReviewSection, field: ChatBuilderField, theme: ChatBuilderPanelTheme) {
    self.section = section
    self.field = field
    self.theme = theme
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    title = "Prompt"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Save",
      style: .done,
      target: self,
      action: #selector(handleSave)
    )

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.font = .systemFont(ofSize: 15, weight: .regular)
    textView.textColor = theme.textColor
    textView.tintColor = theme.accentColor
    textView.backgroundColor = theme.inputColor
    textView.contentInsetAdjustmentBehavior = .never
    textView.layer.cornerRadius = 18.0
    textView.layer.cornerCurve = .continuous
    textView.textContainerInset = UIEdgeInsets(top: 16.0, left: 16.0, bottom: 16.0, right: 16.0)
    textView.text = chatBuilderTrimmedString(field.value) ?? ""
    view.addSubview(textView)

    topMaskView.isUserInteractionEnabled = false
    topMaskGradient.colors = [
      theme.backgroundColor.cgColor,
      theme.backgroundColor.withAlphaComponent(0.0).cgColor,
    ]
    topMaskGradient.startPoint = CGPoint(x: 0.5, y: 0.0)
    topMaskGradient.endPoint = CGPoint(x: 0.5, y: 1.0)
    topMaskView.layer.addSublayer(topMaskGradient)
    view.addSubview(topMaskView)

    let topConstraint = textView.topAnchor.constraint(equalTo: view.topAnchor)
    textViewTopConstraint = topConstraint
    NSLayoutConstraint.activate([
      topConstraint,
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),
      textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16.0),
    ])
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let topInset = chatBuilderResolvedHeaderInset(in: self) + 8.0
    textViewTopConstraint?.constant = topInset
    let maskHeight = topInset + 16.0
    topMaskView.frame = CGRect(x: 0.0, y: 0.0, width: view.bounds.width, height: maskHeight)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    topMaskGradient.frame = topMaskView.bounds
    CATransaction.commit()
  }

  @objc private func handleSave() {
    var answers = chatBuilderPreservedAnswers(for: section)
    let prompt = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    answers[field.key] = prompt
    onSubmit?(section.requestId, answers, chatBuilderCondensedText(prompt, maxLength: 28))
  }
}

private final class ChatBuilderToolsEditorController: UIViewController {
  private let section: ChatBuilderReviewSection
  private let field: ChatBuilderField
  private let theme: ChatBuilderPanelTheme
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let cardView: ChatBuilderPanelCardView
  private let topMaskView = UIView()
  private let topMaskGradient = CAGradientLayer()
  private var toolRows: [String: ChatBuilderToggleRow] = [:]

  var onSubmit: ((String, [String: Any], String?) -> Void)?

  init(section: ChatBuilderReviewSection, field: ChatBuilderField, theme: ChatBuilderPanelTheme) {
    self.section = section
    self.field = field
    self.theme = theme
    self.cardView = ChatBuilderPanelCardView(theme: theme, padding: 0.0, spacing: 0.0)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    title = "Tools"

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = theme.backgroundColor
    scrollView.alwaysBounceVertical = true
    scrollView.contentInsetAdjustmentBehavior = .never
    view.addSubview(scrollView)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    contentView.backgroundColor = theme.backgroundColor
    scrollView.addSubview(contentView)

    cardView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(cardView)

    topMaskView.isUserInteractionEnabled = false
    topMaskGradient.colors = [
      theme.backgroundColor.cgColor,
      theme.backgroundColor.withAlphaComponent(0.0).cgColor,
    ]
    topMaskGradient.startPoint = CGPoint(x: 0.5, y: 0.0)
    topMaskGradient.endPoint = CGPoint(x: 0.5, y: 1.0)
    topMaskView.layer.addSublayer(topMaskGradient)
    view.addSubview(topMaskView)

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

      cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
      cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16.0),
      cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16.0),
      cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])

    let selected = Set(chatBuilderStringArray(field.value))
    for (index, option) in field.options.enumerated() {
      let row = ChatBuilderToggleRow(
        title: option.label,
        isOn: selected.contains(option.id),
        theme: theme,
        showsDivider: index < field.options.count - 1
      )
      row.onToggle = { [weak self] _ in
        self?.submitChanges()
      }
      toolRows[option.id] = row
      cardView.contentStack.addArrangedSubview(row)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let topInset = chatBuilderResolvedHeaderInset(in: self) + 8.0
    let bottomInset = view.safeAreaInsets.bottom + 24.0
    let desiredInsets = UIEdgeInsets(top: topInset, left: 0.0, bottom: bottomInset, right: 0.0)
    if scrollView.contentInset != desiredInsets {
      scrollView.contentInset = desiredInsets
      scrollView.scrollIndicatorInsets = desiredInsets
    }

    let maskHeight = topInset + 16.0
    topMaskView.frame = CGRect(x: 0.0, y: 0.0, width: view.bounds.width, height: maskHeight)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    topMaskGradient.frame = topMaskView.bounds
    CATransaction.commit()
  }

  private func submitChanges() {
    var answers = chatBuilderPreservedAnswers(for: section)
    let selected = field.options.compactMap { option in
      toolRows[option.id]?.isOn == true ? option.id : nil
    }
    answers[field.key] = selected
    let summary = selected
      .compactMap { id in field.options.first(where: { $0.id == id })?.label }
      .joined(separator: ", ")
    onSubmit?(section.requestId, answers, summary.isEmpty ? "No tools" : summary)
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
  private let topMaskView = UIView()
  private let topMaskGradient = CAGradientLayer()

  private var fieldViews: [ChatBuilderFormFieldView] = []
  private var activeRequest: ChatBuilderUiRequest?
  private var pendingAgentEnabled: Bool?
  var onSubmitRequest: ((String, [String: Any], String?) -> Void)?
  var onCreateDraft: ((Bool?) -> Void)?
  var onControllerDismissed: (() -> Void)?

  init(
    mode: ChatBuilderPanelMode,
    theme: ChatBuilderPanelTheme,
    setupState: ChatBuilderSetupState?,
    activity: [ChatBuilderActivityItem],
    agentEnabled: Bool? = nil
  ) {
    self.mode = mode
    self.theme = theme
    self.setupState = setupState
    self.activity = activity
    self.pendingAgentEnabled = agentEnabled
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    additionalSafeAreaInsets = .zero
    configureNavigation()
    configureChrome()
    configureLayout()
    configureMasks()
    buildContent()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutMaskAndInsets()
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
      title = "Agent Setup"
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(handleClosePressed)
      )
    case .request(let request):
      activeRequest = request
      title = request.title
      if request.allowSkip {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
          title: "Skip",
          style: .plain,
          target: self,
          action: #selector(handleSkipPressed)
        )
      } else {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
          barButtonSystemItem: .close,
          target: self,
          action: #selector(handleClosePressed)
        )
      }
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: request.submitLabel,
        style: .done,
        target: self,
        action: #selector(handleSubmitPressed)
      )
    case .review:
      title = "Agent Setup"
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(handleClosePressed)
      )
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: makeNavigationIconButton())
    }
    navigationController?.navigationBar.tintColor = theme.accentColor
  }

  private func configureChrome() {
    navigationController?.view.backgroundColor = theme.backgroundColor
    navigationController?.view.clipsToBounds = true
    view.clipsToBounds = true
    scrollView.backgroundColor = theme.backgroundColor
    contentView.backgroundColor = theme.backgroundColor

    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundEffect = nil
    appearance.backgroundColor = theme.backgroundColor
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: theme.textColor]

    navigationController?.navigationBar.standardAppearance = appearance
    navigationController?.navigationBar.scrollEdgeAppearance = appearance
    navigationController?.navigationBar.compactAppearance = appearance
    navigationController?.navigationBar.tintColor = theme.accentColor
    navigationController?.navigationBar.prefersLargeTitles = false
    navigationController?.navigationBar.isTranslucent = false
  }

  private func makeNavigationIconButton() -> UIButton {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = theme.accentColor
    let image = UIImage(
      systemName: "checkmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    )
    button.setImage(image, for: .normal)
    button.contentHorizontalAlignment = .center
    button.contentVerticalAlignment = .center
    button.frame = CGRect(x: 0.0, y: 0.0, width: 36.0, height: 36.0)
    button.widthAnchor.constraint(equalToConstant: 36.0).isActive = true
    button.heightAnchor.constraint(equalToConstant: 36.0).isActive = true
    button.addTarget(self, action: #selector(handleCreateDraftPressed), for: .touchUpInside)
    return button
  }

  private func configureLayout() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.contentInsetAdjustmentBehavior = .never
    view.addSubview(scrollView)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.spacing = 14.0
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

      stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
      stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16.0),
      stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16.0),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  private func configureMasks() {
    topMaskView.isUserInteractionEnabled = false
    topMaskGradient.colors = [
      theme.backgroundColor.cgColor,
      theme.backgroundColor.withAlphaComponent(0.0).cgColor,
    ]
    topMaskGradient.startPoint = CGPoint(x: 0.5, y: 0.0)
    topMaskGradient.endPoint = CGPoint(x: 0.5, y: 1.0)
    topMaskView.layer.addSublayer(topMaskGradient)
    view.addSubview(topMaskView)
  }

  private func layoutMaskAndInsets() {
    let topPadding: CGFloat = 8.0
    let bottomPadding = view.safeAreaInsets.bottom + 24.0
    let headerInset = resolvedHeaderInset()
    let desiredInsets = UIEdgeInsets(
      top: headerInset + topPadding,
      left: 0.0,
      bottom: bottomPadding,
      right: 0.0
    )

    if scrollView.contentInset != desiredInsets {
      scrollView.contentInset = desiredInsets
      scrollView.scrollIndicatorInsets = desiredInsets
    }

    let maskHeight = desiredInsets.top + 18.0
    topMaskView.frame = CGRect(x: 0.0, y: 0.0, width: view.bounds.width, height: maskHeight)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    topMaskGradient.frame = topMaskView.bounds
    CATransaction.commit()
  }

  private func resolvedHeaderInset() -> CGFloat {
    chatBuilderResolvedHeaderInset(in: self)
  }

  private func buildContent() {
    switch mode {
    case .progress:
      buildProgressContent()
    case .request(let request):
      buildRequestContent(request)
    case .review(let sections):
      buildReviewContent(sections)
    }
  }

  private func makeSectionTitle(_ text: String) -> UILabel {
    let label = UILabel()
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = theme.secondaryTextColor
    label.text = text.uppercased()
    return label
  }

  private func makeRowGroup(title: String? = nil) -> ChatBuilderPanelCardView {
    if let title, !title.isEmpty {
      stackView.addArrangedSubview(makeSectionTitle(title))
    }
    return ChatBuilderPanelCardView(theme: theme, padding: 0.0, spacing: 0.0)
  }

  private func makeStatusValue() -> String {
    setupState?.statusTitle ?? reviewStatusDetail()
  }

  private func activeActivityValue() -> String? {
    let active =
      activity.first(where: { $0.status == "in_progress" })
      ?? activity.first(where: { $0.status == "attention" })
      ?? activity.first
    return chatBuilderCondensedText(active?.title, maxLength: 24)
  }

  private func buildRequestContent(_ request: ChatBuilderUiRequest) {
    activeRequest = request
    if !request.fields.isEmpty {
      stackView.addArrangedSubview(makeSectionTitle("Questions"))
    }

    fieldViews.removeAll()
    for field in request.fields {
      let fieldView = ChatBuilderFormFieldView(field: field, theme: theme)
      fieldViews.append(fieldView)
      stackView.addArrangedSubview(fieldView)
    }
  }

  private func buildProgressContent() {
    let card = makeRowGroup(title: "Builder")
    let currentValue =
      activeActivityValue()
      ?? chatBuilderCondensedText(setupState?.summary, maxLength: 24)
    card.contentStack.addArrangedSubview(
      ChatBuilderPanelActionRow(
        title: "Status",
        value: makeStatusValue(),
        theme: theme,
        showsChevron: false,
        showsDivider: true
      )
    )
    card.contentStack.addArrangedSubview(
      ChatBuilderPanelActionRow(
        title: "Phase",
        value: setupState?.phaseTitle ?? "Understand",
        theme: theme,
        showsChevron: false,
        showsDivider: currentValue != nil
      )
    )
    if let currentValue {
      card.contentStack.addArrangedSubview(
        ChatBuilderPanelActionRow(
          title: "Current",
          value: currentValue,
          theme: theme,
          showsChevron: false
        )
      )
    }
    stackView.addArrangedSubview(card)
  }

  private func buildReviewContent(_ sections: [ChatBuilderReviewSection]) {
    let statusCard = makeRowGroup()
    let activeRow = ChatBuilderToggleRow(
      title: "Agent Active",
      isOn: pendingAgentEnabled ?? true,
      theme: theme
    )
    activeRow.onToggle = { [weak self] isOn in
      self?.pendingAgentEnabled = isOn
    }
    statusCard.contentStack.addArrangedSubview(activeRow)
    stackView.addArrangedSubview(statusCard)

    let promptSection = reviewSection(in: sections, fieldKeys: ["system_prompt", "prompt"])
    let promptField = promptSection.flatMap { reviewField(in: $0, keys: ["system_prompt", "prompt"]) }
    let promptValue = chatBuilderFieldDisplayValue(promptField)
    let hasPrompt = promptField != nil
    let identityCard = makeRowGroup(title: "Agent Identity")

    let explicitName =
      reviewSection(in: sections, fieldKeys: ["display_name", "name", "agent_name", "agentName"])
      .flatMap { reviewField(in: $0, keys: ["display_name", "name", "agent_name", "agentName"]) }
      .flatMap { chatBuilderFieldDisplayValue($0) }
    let fallbackActivityName = activity.compactMap(\.agentLabel).first
    let resolvedName =
      chatBuilderDerivedAgentName(fromPrompt: promptValue)
      ?? chatBuilderCondensedText(explicitName, maxLength: 24)
      ?? chatBuilderCondensedText(fallbackActivityName, maxLength: 24)
      ?? "Agent"

    if hasPrompt || explicitName != nil || fallbackActivityName != nil {
      let nameRow = ChatBuilderPanelActionRow(
        title: "Name",
        value: resolvedName,
        theme: theme,
        showsChevron: false,
        showsDivider: hasPrompt
      )
      nameRow.isUserInteractionEnabled = false
      identityCard.contentStack.addArrangedSubview(nameRow)
    }

    if let promptSection, let promptField {
      let promptRow = ChatBuilderPanelActionRow(
        title: "Prompt",
        value: chatBuilderCondensedText(promptValue, maxLength: 28) ?? "No prompt",
        theme: theme
      )
      promptRow.addAction(UIAction { [weak self] _ in
        self?.presentPromptEditor(section: promptSection, field: promptField)
      }, for: .touchUpInside)
      identityCard.contentStack.addArrangedSubview(promptRow)
    }
    stackView.addArrangedSubview(identityCard)

    if let toolsSection = reviewSection(in: sections, fieldKeys: ["enabled_tools"]),
      let toolsField = reviewField(in: toolsSection, keys: ["enabled_tools"])
    {
      let toolsCard = makeRowGroup()
      let toolsRow = ChatBuilderPanelActionRow(
        title: "Tool",
        value: nil,
        theme: theme
      )
      toolsRow.addAction(UIAction { [weak self] _ in
        self?.presentToolsEditor(section: toolsSection, field: toolsField)
      }, for: .touchUpInside)
      toolsCard.contentStack.addArrangedSubview(toolsRow)
      stackView.addArrangedSubview(toolsCard)
    }
  }

  private func presentPromptEditor(section: ChatBuilderReviewSection, field: ChatBuilderField) {
    let controller = ChatBuilderPromptEditorController(section: section, field: field, theme: theme)
    controller.onSubmit = { [weak self] requestId, answers, summary in
      self?.onSubmitRequest?(requestId, answers, summary)
      self?.navigationController?.popViewController(animated: true)
    }
    navigationController?.pushViewController(controller, animated: true)
  }

  private func presentToolsEditor(section: ChatBuilderReviewSection, field: ChatBuilderField) {
    let controller = ChatBuilderToolsEditorController(section: section, field: field, theme: theme)
    controller.onSubmit = { [weak self] requestId, answers, summary in
      self?.onSubmitRequest?(requestId, answers, summary)
    }
    navigationController?.pushViewController(controller, animated: true)
  }

  @objc private func handleSkipPressed() {
    guard case let .request(request) = mode else { return }
    onSubmitRequest?(request.id, [:], "Skipped")
  }

  @objc private func handleClosePressed() {
    dismissPanel()
  }

  @objc private func handleCreateDraftPressed() {
    onCreateDraft?(pendingAgentEnabled)
    dismissPanel()
  }

  @objc private func handleSubmitPressed() {
    guard let request = activeRequest else { return }
    var answers: [String: Any] = [:]
    var firstError: String?

    for view in fieldViews {
      if let error = view.validate(), firstError == nil {
        firstError = error
      }
      if let answer = view.currentAnswer() {
        answers[view.field.key] = answer
      }
    }

    if let error = firstError {
      presentValidationAlert(message: "Please provide a value for \(error)")
      return
    }

    let summary =
      fieldViews
      .compactMap { $0.summarySnippet() }
      .first(where: { !$0.isEmpty })
    onSubmitRequest?(request.id, answers, summary)
    if navigationController?.viewControllers.first === self {
      dismissPanel()
    } else {
      navigationController?.popViewController(animated: true)
    }
  }

  private func reviewStatusDetail() -> String {
    switch setupState?.status {
    case "draft_created":
      return "Draft created"
    case "review_ready":
      return "Active draft"
    case "assembling", "clarifying", "discovering":
      return "Draft in progress"
    default:
      return "Active draft"
    }
  }

  private func reviewSection(in sections: [ChatBuilderReviewSection], fieldKeys: [String]) -> ChatBuilderReviewSection? {
    sections.first { section in
      fieldKeys.contains { key in
        section.fields.contains(where: { $0.key == key })
      }
    }
  }

  private func reviewField(in section: ChatBuilderReviewSection, keys: [String]) -> ChatBuilderField? {
    section.fields.first { field in
      keys.contains(field.key)
    }
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
