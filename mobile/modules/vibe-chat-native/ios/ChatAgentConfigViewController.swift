import UIKit

final class ChatAgentConfigViewController: UIViewController {
  var chatId: String = ""
  var agentConfig: [String: Any]?
  var documents: [(id: String, name: String, url: String)] = []
  var onSave: (([String: Any]) -> Void)?
  var onDelete: (() -> Void)?

  private let scrollView = UIScrollView()
  private let contentView = UIView()

  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  
  private let documentsLabel = UILabel()
  private let documentsStack = UIStackView()

  private let modelCard = UIView()
  private let modelLabel = UILabel()

  private let nameLabel = UILabel()
  private let nameField = UITextField()
  private let promptLabel = UILabel()
  private let generatePromptButton = UIButton(type: .system)
  private let generateInputLabel = UILabel()
  private let generateInputField = UITextField()
  private let promptTextView = UITextView()
  private let promptHintLabel = UILabel()
  private let toolsLabel = UILabel()
  private let toolsCard = UIView()
  private let enabledLabel = UILabel()
  private let enabledToggle = UISwitch()

  private let deleteButton = UIButton(type: .system)

  private let accentColor = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
  private let toolOptions: [(id: String, title: String, subtitle: String)] = [
    ("search_google", "Web Search", "Search Google for up-to-date results"),
    ("analyze_image", "Image Analysis", "Understand images and OCR text"),
    ("analyze_document", "Document Analysis", "Read and summarize document files"),
    ("create_document", "Create Document", "Generate formatted document drafts"),
  ]
  private var toolRows: [UIView] = []
  private var toolTitleLabels: [UILabel] = []
  private var toolSubtitleLabels: [UILabel] = []
  private var toolToggles: [UISwitch] = []
  private var toolTogglesById: [String: UISwitch] = [:]

  override func viewDidLoad() {
    super.viewDidLoad()
    configureNavigation()
    configureViews()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    let safe = view.safeAreaInsets
    scrollView.frame = CGRect(
      x: 0.0,
      y: safe.top,
      width: view.bounds.width,
      height: view.bounds.height - safe.top
    )

    let width = scrollView.bounds.width
    let sideInset: CGFloat = 20.0
    var y: CGFloat = 14.0
    let contentWidth = width - (sideInset * 2.0)

    titleLabel.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 30.0)
    y = titleLabel.frame.maxY + 2.0
    subtitleLabel.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 22.0)
    y = subtitleLabel.frame.maxY + 16.0

    modelCard.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 48.0)
    modelLabel.frame = modelCard.bounds.insetBy(dx: 14.0, dy: 0.0)
    y = modelCard.frame.maxY + 20.0

    nameLabel.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 20.0)
    y = nameLabel.frame.maxY + 8.0
    nameField.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 48.0)
    y = nameField.frame.maxY + 18.0

    promptLabel.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 20.0)
    let generateWidth: CGFloat = 94.0
    generatePromptButton.frame = CGRect(
      x: width - sideInset - generateWidth,
      y: y - 4.0,
      width: generateWidth,
      height: 28.0
    )
    promptLabel.frame.size.width = max(80.0, contentWidth - generateWidth - 8.0)
    y = promptLabel.frame.maxY + 8.0
    generateInputLabel.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 18.0)
    y = generateInputLabel.frame.maxY + 6.0
    generateInputField.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 42.0)
    y = generateInputField.frame.maxY + 12.0
    promptTextView.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 180.0)
    promptHintLabel.frame = CGRect(
      x: sideInset + 12.0,
      y: y + 12.0,
      width: contentWidth - 24.0,
      height: 42.0
    )
    y = promptTextView.frame.maxY + 16.0

    toolsLabel.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 20.0)
    y = toolsLabel.frame.maxY + 8.0
    let rowHeight: CGFloat = 54.0
    let toolsCardHeight = CGFloat(toolRows.count) * rowHeight
    toolsCard.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: toolsCardHeight)
    for index in toolRows.indices {
      let rowY = CGFloat(index) * rowHeight
      let row = toolRows[index]
      row.frame = CGRect(x: 0.0, y: rowY, width: contentWidth, height: rowHeight)
      let toggle = toolToggles[index]
      let toggleSize = toggle.intrinsicContentSize
      toggle.frame = CGRect(
        x: contentWidth - 16.0 - toggleSize.width,
        y: (rowHeight - toggleSize.height) * 0.5,
        width: toggleSize.width,
        height: toggleSize.height
      )
      let textWidth = max(120.0, toggle.frame.minX - 24.0)
      toolTitleLabels[index].frame = CGRect(x: 12.0, y: 8.0, width: textWidth, height: 20.0)
      toolSubtitleLabels[index].frame = CGRect(x: 12.0, y: 28.0, width: textWidth, height: 18.0)
    }
    y = toolsCard.frame.maxY + 14.0

    if !documents.isEmpty {
      documentsLabel.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 20.0)
      documentsLabel.isHidden = false
      y = documentsLabel.frame.maxY + 8.0
      
      let docHeight: CGFloat = 48.0
      let docsTotalHeight = CGFloat(documents.count) * docHeight + CGFloat(max(0, documents.count - 1)) * 10.0
      documentsStack.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: docsTotalHeight)
      documentsStack.isHidden = false
      y = documentsStack.frame.maxY + 24.0
    } else {
      documentsLabel.isHidden = true
      documentsStack.isHidden = true
    }

    enabledLabel.frame = CGRect(x: sideInset, y: y, width: contentWidth - 80.0, height: 30.0)
    let toggleSize = enabledToggle.intrinsicContentSize
    enabledToggle.frame = CGRect(
      x: width - sideInset - toggleSize.width,
      y: y + (30.0 - toggleSize.height) * 0.5,
      width: toggleSize.width,
      height: toggleSize.height
    )
    y += 42.0

    if agentConfig != nil {
      deleteButton.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: 46.0)
      deleteButton.isHidden = false
      y = deleteButton.frame.maxY + 18.0
    } else {
      deleteButton.isHidden = true
      deleteButton.frame = .zero
      y += 10.0
    }

    contentView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: y)
    scrollView.contentSize = CGSize(width: width, height: y + max(20.0, safe.bottom))
  }

  private func configureNavigation() {
    navigationItem.title = agentConfig == nil ? "Add AI Agent" : "Edit AI Agent"
    navigationItem.largeTitleDisplayMode = .never

    let saveTitle = agentConfig == nil ? "Create" : "Save"
    let saveItem = UIBarButtonItem(
      title: saveTitle, style: .done, target: self, action: #selector(handleSave))
    navigationItem.rightBarButtonItem = saveItem

    if navigationController?.viewControllers.first === self || presentingViewController != nil {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(handleCancel)
      )
    }
  }

  private func configureViews() {
    view.backgroundColor = .systemBackground

    scrollView.keyboardDismissMode = .interactive
    view.addSubview(scrollView)
    scrollView.addSubview(contentView)

    titleLabel.font = UIFont.systemFont(ofSize: 30.0, weight: .bold)
    titleLabel.textColor = .label
    titleLabel.text = "Agent Settings"
    contentView.addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .medium)
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.text = "Single native model backend"
    contentView.addSubview(subtitleLabel)

    modelCard.backgroundColor = .secondarySystemGroupedBackground
    modelCard.layer.cornerRadius = 14.0
    modelCard.layer.cornerCurve = .continuous
    contentView.addSubview(modelCard)

    modelLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
    modelLabel.textColor = .label
    modelLabel.text = "Model: Native default"
    modelCard.addSubview(modelLabel)

    let initialEnabledTools = Set(currentEnabledTools())

    nameLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
    nameLabel.textColor = .secondaryLabel
    nameLabel.text = "AGENT NAME"
    contentView.addSubview(nameLabel)

    nameField.font = UIFont.systemFont(ofSize: 16.0, weight: .medium)
    nameField.layer.cornerRadius = 12.0
    nameField.layer.cornerCurve = .continuous
    nameField.backgroundColor = .secondarySystemGroupedBackground
    nameField.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 12.0, height: 1.0))
    nameField.leftViewMode = .always
    nameField.placeholder = "Vibe AI"
    nameField.text = (agentConfig?["name"] as? String) ?? ""
    contentView.addSubview(nameField)

    promptLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
    promptLabel.textColor = .secondaryLabel
    promptLabel.text = "SYSTEM PROMPT"
    contentView.addSubview(promptLabel)

    generatePromptButton.setTitle("Generate", for: .normal)
    generatePromptButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
    generatePromptButton.tintColor = accentColor
    generatePromptButton.addTarget(
      self, action: #selector(handleGeneratePromptTapped), for: .touchUpInside)
    contentView.addSubview(generatePromptButton)

    generateInputLabel.font = UIFont.systemFont(ofSize: 12.0, weight: .semibold)
    generateInputLabel.textColor = .secondaryLabel
    generateInputLabel.text = "GENERATE FROM INPUT"
    contentView.addSubview(generateInputLabel)

    generateInputField.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
    generateInputField.layer.cornerRadius = 12.0
    generateInputField.layer.cornerCurve = .continuous
    generateInputField.backgroundColor = .secondarySystemGroupedBackground
    generateInputField.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 12.0, height: 1.0))
    generateInputField.leftViewMode = .always
    generateInputField.placeholder = "e.g. Helpful PM assistant for sprint planning"
    generateInputField.autocapitalizationType = .sentences
    contentView.addSubview(generateInputField)

    promptTextView.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)
    promptTextView.layer.cornerRadius = 12.0
    promptTextView.layer.cornerCurve = .continuous
    promptTextView.backgroundColor = .secondarySystemGroupedBackground
    promptTextView.textContainerInset = UIEdgeInsets(top: 12.0, left: 8.0, bottom: 12.0, right: 8.0)
    promptTextView.text = normalizedPrompt(from: agentConfig)
    promptTextView.delegate = self
    contentView.addSubview(promptTextView)

    promptHintLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
    promptHintLabel.textColor = UIColor.secondaryLabel.withAlphaComponent(0.75)
    promptHintLabel.numberOfLines = 0
    promptHintLabel.text = "Describe how this agent should behave in the group."
    promptTextView.addSubview(promptHintLabel)
    refreshPromptHintVisibility()

    toolsLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
    toolsLabel.textColor = .secondaryLabel
    toolsLabel.text = "ENABLED TOOLS"
    contentView.addSubview(toolsLabel)

    toolsCard.backgroundColor = .secondarySystemGroupedBackground
    toolsCard.layer.cornerRadius = 12.0
    toolsCard.layer.cornerCurve = .continuous
    contentView.addSubview(toolsCard)
    for option in toolOptions {
      let row = UIView()
      row.backgroundColor = .clear

      let title = UILabel()
      title.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
      title.textColor = .label
      title.text = option.title
      row.addSubview(title)

      let subtitle = UILabel()
      subtitle.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
      subtitle.textColor = .secondaryLabel
      subtitle.text = option.subtitle
      row.addSubview(subtitle)

      let toggle = UISwitch()
      toggle.onTintColor = accentColor
      toggle.isOn = initialEnabledTools.contains(option.id)
      row.addSubview(toggle)

      toolsCard.addSubview(row)
      toolRows.append(row)
      toolTitleLabels.append(title)
      toolSubtitleLabels.append(subtitle)
      toolToggles.append(toggle)
      toolTogglesById[option.id] = toggle
    }

    documentsLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
    documentsLabel.textColor = .secondaryLabel
    documentsLabel.text = "AGENT DOCUMENTS"
    contentView.addSubview(documentsLabel)
    
    documentsStack.axis = .vertical
    documentsStack.spacing = 10.0
    documentsStack.distribution = .equalSpacing
    contentView.addSubview(documentsStack)
    
    for (index, doc) in documents.enumerated() {
      let row = UIControl()
      row.backgroundColor = .clear // will set explicitly below
      row.layer.cornerRadius = 12.0
      row.layer.cornerCurve = .continuous
      row.layer.borderWidth = 1.0 / UIScreen.main.scale
      row.layer.borderColor = UIColor.secondaryLabel.withAlphaComponent(0.2).cgColor
      row.translatesAutoresizingMaskIntoConstraints = false
      row.heightAnchor.constraint(equalToConstant: 48).isActive = true
      row.tag = index
      row.addTarget(self, action: #selector(handleDocumentTapped(_:)), for: .touchUpInside)
      
      let icon = UIImageView(image: UIImage(systemName: "doc.text.fill"))
      icon.tintColor = accentColor
      icon.contentMode = .scaleAspectFit
      icon.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(icon)
      
      let label = UILabel()
      label.text = doc.name
      label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
      label.textColor = .label
      label.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(label)
      
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
        icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 20),
        icon.heightAnchor.constraint(equalToConstant: 20),
        
        label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
        label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
        label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
      ])
      
      documentsStack.addArrangedSubview(row)
    }

    enabledLabel.font =  UIFont.systemFont(ofSize: 16.0, weight: .medium)
    enabledLabel.textColor = .label
    enabledLabel.text = "Enabled"
    contentView.addSubview(enabledLabel)

    enabledToggle.onTintColor = accentColor
    enabledToggle.isOn = normalizedEnabled(from: agentConfig, defaultValue: true)
    contentView.addSubview(enabledToggle)

    deleteButton.setTitle("Remove Agent", for: .normal)
    deleteButton.titleLabel?.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
    deleteButton.setTitleColor(.systemRed, for: .normal)
    deleteButton.layer.cornerRadius = 14.0
    deleteButton.layer.cornerCurve = .continuous
    deleteButton.backgroundColor = .secondarySystemGroupedBackground
    deleteButton.addTarget(self, action: #selector(handleDelete), for: .touchUpInside)
    contentView.addSubview(deleteButton)
  }

  @objc private func handleCancel() {
    closeEditor()
  }

  @objc private func handleSave() {
    let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let prompt = promptTextView.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !prompt.isEmpty else {
      let alert = UIAlertController(
        title: "System Prompt Required",
        message: "Please enter a system prompt before saving this agent.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
      return
    }
    let selectedTools = selectedEnabledTools()
    guard !selectedTools.isEmpty else {
      presentSimpleAlert(
        title: "Enable At Least One Tool",
        message: "Select at least one tool for this agent.")
      return
    }

    var config: [String: Any] = [
      "chat_id": chatId,
      "name": name.isEmpty ? "Vibe AI" : name,
      "system_prompt": prompt,
      "enabled": enabledToggle.isOn,
      "enabled_tools": selectedTools,
    ]
    if let existingId = agentConfig?["id"] {
      config["id"] = existingId
    }

    onSave?(config)
    closeEditor()
  }

  @objc private func handleDelete() {
    let alert = UIAlertController(
      title: "Remove AI Agent",
      message: "This will remove the agent and clear its memory. This action cannot be undone.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
        self?.onDelete?()
        self?.closeEditor()
      })
    present(alert, animated: true)
  }

  private func closeEditor() {
    if let nav = navigationController, nav.viewControllers.count > 1 {
      nav.popViewController(animated: true)
      return
    }
    dismiss(animated: true)
  }

  private func refreshPromptHintVisibility() {
    promptHintLabel.isHidden = !(promptTextView.text ?? "").isEmpty
  }

  private func normalizedPrompt(from config: [String: Any]?) -> String {
    guard let config else { return "" }
    let snake =
      (config["system_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !snake.isEmpty { return snake }
    return
      (config["systemPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func normalizedEnabled(from config: [String: Any]?, defaultValue: Bool) -> Bool {
    guard let raw = config?["enabled"] else { return defaultValue }
    if let bool = raw as? Bool { return bool }
    if let number = raw as? NSNumber { return number.boolValue }
    if let string = raw as? String {
      switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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

  private func currentEnabledTools() -> [String] {
    if let explicit = normalizedToolList(agentConfig?["enabled_tools"]), !explicit.isEmpty {
      return explicit
    }
    if let explicit = normalizedToolList(agentConfig?["enabledTools"]), !explicit.isEmpty {
      return explicit
    }
    return ["search_google", "analyze_image", "analyze_document", "create_document"]
  }

  @objc private func handleGeneratePromptTapped() {
    let input = generateInputField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !input.isEmpty else {
      generateInputField.becomeFirstResponder()
      return
    }
    let selectedTools = selectedEnabledTools()
    guard !selectedTools.isEmpty else {
      presentSimpleAlert(
        title: "Enable At Least One Tool",
        message: "Select at least one tool before generating.")
      return
    }
    generatePromptButton.isEnabled = false
    generatePromptButton.setTitle("Generating...", for: .normal)
    ChatEngine.shared.generateAgentPrompt(
      chatId: chatId,
      input: input,
      enabledTools: selectedTools
    ) { [weak self] payload in
      guard let self else { return }
      self.generatePromptButton.isEnabled = true
      self.generatePromptButton.setTitle("Generate", for: .normal)
      let generated =
        (payload?["systemPrompt"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !generated.isEmpty else {
        self.presentSimpleAlert(
          title: "Generation Failed",
          message: "Could not generate a prompt. Try adjusting your input.")
        return
      }
      self.promptTextView.text = generated
      self.refreshPromptHintVisibility()
    }
  }

  private func selectedEnabledTools() -> [String] {
    var out: [String] = []
    for option in toolOptions {
      if toolTogglesById[option.id]?.isOn == true {
        out.append(option.id)
      }
    }
    return out
  }

  private func normalizedToolList(_ raw: Any?) -> [String]? {
    guard let rawList = raw as? [Any] else { return nil }
    let normalized =
      rawList
      .compactMap { item -> String? in
        if let text = item as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
        if let number = item as? NSNumber {
          return number.stringValue
        }
        return nil
      }
    return normalized.isEmpty ? nil : normalized
  }

  @objc private func handleDocumentTapped(_ sender: UIControl) {
    let index = sender.tag
    guard index >= 0, index < documents.count else { return }
    let doc = documents[index]
    
    let isText = doc.name.lowercased().hasSuffix(".csv") || doc.name.lowercased().hasSuffix(".md") || doc.name.lowercased().hasSuffix(".txt") || doc.name.lowercased().hasSuffix(".json")
    guard isText else {
       if let url = URL(string: doc.url) {
           UIApplication.shared.open(url)
       }
       return
    }
    
    let overlay = UIView(frame: view.bounds)
    overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
    overlay.alpha = 0.0
    view.addSubview(overlay)
    
    let indicator = UIActivityIndicatorView(style: .large)
    indicator.center = view.center
    indicator.startAnimating()
    overlay.addSubview(indicator)
    
    UIView.animate(withDuration: 0.2) { overlay.alpha = 1.0 }
    
    let cleanUrlString = doc.url.replacingOccurrences(of: "vibe://", with: "https://") 
    guard let url = URL(string: cleanUrlString) else {
      UIView.animate(withDuration: 0.2, animations: { overlay.alpha = 0.0 }) { _ in overlay.removeFromSuperview() }
      return
    }
    
    var request = URLRequest(url: url)
    if let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
       request.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
       DispatchQueue.main.async {
          UIView.animate(withDuration: 0.2, animations: { overlay.alpha = 0.0 }) { _ in overlay.removeFromSuperview() }
          guard let self = self, let data = data, let text = String(data: data, encoding: .utf8) else {
             self?.presentSimpleAlert(title: "Error", message: "Failed to load document content.")
             return
          }
          let preview = AgentDocumentPreviewController(title: doc.name, text: text)
          let nav = UINavigationController(rootViewController: preview)
          self.present(nav, animated: true)
       }
    }
    task.resume()
  }

  private func presentSimpleAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}

extension ChatAgentConfigViewController: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    refreshPromptHintVisibility()
  }
}


private final class AgentDocumentPreviewController: UIViewController {
  private let previewTitle: String
  private let textContent: String
  private let textView = UITextView()

  init(title: String, text: String) {
    self.previewTitle = title
    self.textContent = text
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = previewTitle
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(handleDone))

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.alwaysBounceVertical = true
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    textView.text = textContent

    view.addSubview(textView)
    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
  @objc private func handleDone() { dismiss(animated: true) }
}
