import UIKit

final class ChatAgentConfigViewController: UIViewController {
  var chatId: String = ""
  var agentConfig: [String: Any]?
  var onSave: (([String: Any]) -> Void)?
  var onDelete: (() -> Void)?

  private let scrollView = UIScrollView()
  private let contentView = UIView()

  private let nameField = UITextField()
  private let promptTextView = UITextView()
  private let enabledToggle = UISwitch()
  private let enabledLabel = UILabel()
  private let saveButton = UIButton(type: .system)
  private let deleteButton = UIButton(type: .system)

  private let nameLabel = UILabel()
  private let promptLabel = UILabel()

  private let purpleAccent = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)

  override func viewDidLoad() {
    super.viewDidLoad()
    title = agentConfig != nil ? "Edit AI Agent" : "Add AI Agent"
    view.backgroundColor = UIColor.systemBackground

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel, target: self, action: #selector(handleCancel))

    view.addSubview(scrollView)
    scrollView.addSubview(contentView)
    scrollView.keyboardDismissMode = .interactive

    // Name
    nameLabel.text = "Agent Name"
    nameLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    nameLabel.textColor = .secondaryLabel
    contentView.addSubview(nameLabel)

    nameField.placeholder = "Vibe AI"
    nameField.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    nameField.borderStyle = .roundedRect
    nameField.backgroundColor = UIColor.secondarySystemBackground
    nameField.text = (agentConfig?["name"] as? String) ?? ""
    contentView.addSubview(nameField)

    // System Prompt
    promptLabel.text = "System Prompt"
    promptLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    promptLabel.textColor = .secondaryLabel
    contentView.addSubview(promptLabel)

    promptTextView.font = UIFont.systemFont(ofSize: 15, weight: .regular)
    promptTextView.backgroundColor = UIColor.secondarySystemBackground
    promptTextView.layer.cornerRadius = 10.0
    promptTextView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
    promptTextView.text = (agentConfig?["system_prompt"] as? String) ?? ""
    contentView.addSubview(promptTextView)

    // Enabled
    enabledLabel.text = "Enabled"
    enabledLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    contentView.addSubview(enabledLabel)

    enabledToggle.isOn = (agentConfig?["enabled"] as? Bool) ?? true
    enabledToggle.onTintColor = purpleAccent
    contentView.addSubview(enabledToggle)

    // Save
    saveButton.setTitle(agentConfig != nil ? "Save Changes" : "Create Agent", for: .normal)
    saveButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    saveButton.backgroundColor = purpleAccent
    saveButton.setTitleColor(.white, for: .normal)
    saveButton.layer.cornerRadius = 14.0
    saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)
    contentView.addSubview(saveButton)

    // Delete
    if agentConfig != nil {
      deleteButton.setTitle("Remove Agent", for: .normal)
      deleteButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
      deleteButton.setTitleColor(.systemRed, for: .normal)
      deleteButton.addTarget(self, action: #selector(handleDelete), for: .touchUpInside)
      contentView.addSubview(deleteButton)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safeArea = view.safeAreaInsets
    scrollView.frame = CGRect(
      x: 0, y: safeArea.top,
      width: view.bounds.width,
      height: view.bounds.height - safeArea.top
    )
    let width = scrollView.bounds.width
    let padding: CGFloat = 20.0

    contentView.frame = CGRect(x: 0, y: 0, width: width, height: 1)

    var y: CGFloat = 20.0

    nameLabel.frame = CGRect(x: padding, y: y, width: width - padding * 2, height: 20)
    y += 24.0
    nameField.frame = CGRect(x: padding, y: y, width: width - padding * 2, height: 44)
    y += 56.0

    promptLabel.frame = CGRect(x: padding, y: y, width: width - padding * 2, height: 20)
    y += 24.0
    promptTextView.frame = CGRect(x: padding, y: y, width: width - padding * 2, height: 160)
    y += 172.0

    enabledLabel.frame = CGRect(x: padding, y: y, width: 120, height: 32)
    let toggleSize = enabledToggle.intrinsicContentSize
    enabledToggle.frame = CGRect(
      x: width - padding - toggleSize.width,
      y: y + (32 - toggleSize.height) * 0.5,
      width: toggleSize.width,
      height: toggleSize.height
    )
    y += 50.0

    saveButton.frame = CGRect(x: padding, y: y, width: width - padding * 2, height: 50)
    y += 62.0

    if agentConfig != nil {
      deleteButton.frame = CGRect(x: padding, y: y, width: width - padding * 2, height: 44)
      y += 56.0
    }

    contentView.frame = CGRect(x: 0, y: 0, width: width, height: y + 20)
    scrollView.contentSize = CGSize(width: width, height: y + 20)
  }

  @objc private func handleCancel() {
    dismiss(animated: true)
  }

  @objc private func handleSave() {
    let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let prompt = promptTextView.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !prompt.isEmpty else {
      let alert = UIAlertController(
        title: "System Prompt Required",
        message: "Please enter a system prompt to define the agent's behavior.",
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
      return
    }

    var config: [String: Any] = [
      "name": name.isEmpty ? "Vibe AI" : name,
      "system_prompt": prompt,
      "enabled": enabledToggle.isOn,
    ]
    if let existingId = agentConfig?["id"] {
      config["id"] = existingId
    }
    config["chat_id"] = chatId

    onSave?(config)
    dismiss(animated: true)
  }

  @objc private func handleDelete() {
    let alert = UIAlertController(
      title: "Remove AI Agent",
      message: "This will remove the agent and clear its memory. This action cannot be undone.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
      self?.onDelete?()
      self?.dismiss(animated: true)
    })
    present(alert, animated: true)
  }
}
