import UIKit

private struct ChatNativeAgentConfigTheme {
  let backgroundColor: UIColor
  let cardColor: UIColor
  let textColor: UIColor
  let secondaryTextColor: UIColor
  let accentColor: UIColor
  let borderColor: UIColor
  let destructiveColor: UIColor

  init(appearance: ChatListAppearance) {
    backgroundColor = appearance.wallpaperGradient.first ?? .black
    cardColor = appearance.bubbleThemColor.withAlphaComponent(0.28)
    textColor = appearance.textColorThem
    secondaryTextColor = appearance.timeColorThem.withAlphaComponent(0.92)
    accentColor = appearance.textColorThem
    borderColor = appearance.dayBorderColor.withAlphaComponent(0.24)
    destructiveColor = UIColor.systemRed
  }
}

private final class ChatNativeAgentConfigSectionView: UIView {
  let contentStack = UIStackView()

  init(title: String?, theme: ChatNativeAgentConfigTheme) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = theme.cardColor
    container.layer.cornerRadius = 22.0
    container.layer.cornerCurve = .continuous
    container.layer.borderWidth = 1.0
    container.layer.borderColor = theme.borderColor.cgColor
    addSubview(container)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 0.0
    container.addSubview(contentStack)

    NSLayoutConstraint.activate([
      container.topAnchor.constraint(equalTo: topAnchor),
      container.leadingAnchor.constraint(equalTo: leadingAnchor),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
      contentStack.topAnchor.constraint(equalTo: container.topAnchor),
      contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    if let title, !title.isEmpty {
      let titleLabel = UILabel()
      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = .systemFont(ofSize: 12.0, weight: .semibold)
      titleLabel.textColor = theme.secondaryTextColor
      titleLabel.text = title.uppercased()
      addSubview(titleLabel)

      NSLayoutConstraint.activate([
        titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4.0),
        titleLabel.bottomAnchor.constraint(equalTo: container.topAnchor, constant: -8.0),
      ])
    }
  }

  required init?(coder: NSCoder) {
    return nil
  }
}

private final class ChatNativeAgentConfigRow: UIControl {
  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let accessoryView = UIImageView()
  private let dividerView = UIView()

  var onTap: (() -> Void)?

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.12) {
        self.alpha = self.isHighlighted ? 0.76 : 1.0
      }
    }
  }

  init(
    title: String,
    value: String?,
    theme: ChatNativeAgentConfigTheme,
    showsChevron: Bool,
    showsAccessory: Bool = true,
    showsDivider: Bool = true,
    destructive: Bool = false
  ) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 15.0, weight: .medium)
    titleLabel.textColor = destructive ? theme.destructiveColor : theme.textColor
    titleLabel.text = title
    addSubview(titleLabel)

    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    valueLabel.font = .systemFont(ofSize: 14.0, weight: .regular)
    valueLabel.textColor = destructive ? theme.destructiveColor.withAlphaComponent(0.8) : theme.secondaryTextColor
    valueLabel.numberOfLines = 2
    valueLabel.textAlignment = .right
    valueLabel.text = value
    addSubview(valueLabel)

    accessoryView.translatesAutoresizingMaskIntoConstraints = false
    accessoryView.image = UIImage(
      systemName: showsChevron ? "chevron.right" : "doc.on.doc",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)
    )
    accessoryView.tintColor = destructive ? theme.destructiveColor.withAlphaComponent(0.72) : theme.secondaryTextColor.withAlphaComponent(0.58)
    accessoryView.isHidden = !showsAccessory
    addSubview(accessoryView)

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    dividerView.backgroundColor = theme.borderColor
    dividerView.isHidden = !showsDivider
    addSubview(dividerView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 58.0),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -12.0),
      accessoryView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      accessoryView.centerYAnchor.constraint(equalTo: centerYAnchor),
      accessoryView.widthAnchor.constraint(equalToConstant: 18.0),
      accessoryView.heightAnchor.constraint(equalToConstant: 18.0),
      valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12.0),
      valueLabel.trailingAnchor.constraint(equalTo: accessoryView.leadingAnchor, constant: -8.0),
      valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 0.5),
    ])

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  @objc private func handleTap() {
    onTap?()
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
    textView.backgroundColor = theme.cardColor
    textView.textColor = theme.textColor
    textView.font = .systemFont(ofSize: 15.0, weight: .regular)
    textView.layer.cornerRadius = 18.0
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
  private let card: ChatListRow.AgentCard
  private let theme: ChatNativeAgentConfigTheme
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let stackView = UIStackView()

  var onToast: ((String) -> Void)?
  var onDeleteAgent: ((ChatListRow.AgentCard, @escaping () -> Void) -> Void)?

  init(card: ChatListRow.AgentCard, appearance: ChatListAppearance) {
    self.card = card
    self.theme = ChatNativeAgentConfigTheme(appearance: appearance)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    title = card.displayName
    configureNavigation()
    configureLayout()
    buildContent()
  }

  private func configureNavigation() {
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
    stackView.spacing = 20.0
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
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24.0),
    ])
  }

  private func buildContent() {
    let identitySection = ChatNativeAgentConfigSectionView(title: "Identity", theme: theme)
    identitySection.contentStack.addArrangedSubview(makeCopyRow(title: "Status", value: card.status, copyValue: nil))
    identitySection.contentStack.addArrangedSubview(makeCopyRow(title: "Identifier", value: card.identifier, copyValue: card.identifier))
    if let username = card.username {
      identitySection.contentStack.addArrangedSubview(
        makeCopyRow(title: "Username", value: "@\(username)", copyValue: username)
      )
    }
    stackView.addArrangedSubview(identitySection)

    let endpointsSection = ChatNativeAgentConfigSectionView(title: "Endpoints", theme: theme)
    if let apiBaseURL = card.apiBaseURL {
      endpointsSection.contentStack.addArrangedSubview(makeCopyRow(title: "API Base", value: apiBaseURL, copyValue: apiBaseURL))
    }
    if let eventsURL = card.eventsURL {
      endpointsSection.contentStack.addArrangedSubview(makeCopyRow(title: "Events URL", value: eventsURL, copyValue: eventsURL))
    }
    if let invokeURL = card.invokeURL {
      endpointsSection.contentStack.addArrangedSubview(makeCopyRow(title: "Invoke URL", value: invokeURL, copyValue: invokeURL))
    }
    if let callbackURL = card.callbackURL {
      endpointsSection.contentStack.addArrangedSubview(makeCopyRow(title: "Callback", value: callbackURL, copyValue: callbackURL))
    }
    if let latestSecret = card.latestSecret {
      endpointsSection.contentStack.addArrangedSubview(makeCopyRow(title: "Secret", value: latestSecret, copyValue: latestSecret))
    } else if let secretHint = card.secretHint {
      endpointsSection.contentStack.addArrangedSubview(makeCopyRow(title: "Secret Hint", value: secretHint, copyValue: nil))
    }
    stackView.addArrangedSubview(endpointsSection)

    let deliverySection = ChatNativeAgentConfigSectionView(title: "Delivery", theme: theme)
    if let defaultChat = card.defaultDestinationChat {
      let label = defaultChat.name ?? defaultChat.chatId
      deliverySection.contentStack.addArrangedSubview(
        makeCopyRow(title: "Default Chat", value: label, copyValue: defaultChat.chatId)
      )
    }
    for attachedChat in card.attachedChats {
      let label = attachedChat.name ?? attachedChat.chatId
      deliverySection.contentStack.addArrangedSubview(
        makeCopyRow(title: "Attached Chat", value: label, copyValue: attachedChat.chatId)
      )
    }
    stackView.addArrangedSubview(deliverySection)

    let behaviorSection = ChatNativeAgentConfigSectionView(title: "Behavior", theme: theme)
    if !card.enabledTools.isEmpty {
      behaviorSection.contentStack.addArrangedSubview(
        makeCopyRow(title: "Tools", value: card.enabledTools.joined(separator: ", "), copyValue: nil)
      )
    }
    if !card.outputModes.isEmpty {
      behaviorSection.contentStack.addArrangedSubview(
        makeCopyRow(title: "Outputs", value: card.outputModes.joined(separator: ", "), copyValue: nil)
      )
    }
    if let voiceProfile = card.voiceProfile {
      behaviorSection.contentStack.addArrangedSubview(
        makeCopyRow(title: "Voice", value: voiceProfile, copyValue: nil)
      )
    }
    if let promptStatus = card.promptStatus {
      behaviorSection.contentStack.addArrangedSubview(
        makeCopyRow(title: "Prompt Status", value: promptStatus, copyValue: nil)
      )
    }
    if let systemPrompt = card.systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let row = ChatNativeAgentConfigRow(
        title: "Prompt",
        value: "View full prompt",
        theme: theme,
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

  private func makeCopyRow(title: String, value: String, copyValue: String?) -> ChatNativeAgentConfigRow {
    let row = ChatNativeAgentConfigRow(
      title: title,
      value: value,
      theme: theme,
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

  private func envExportBlock() -> String {
    let destinationChat = card.defaultDestinationChat?.chatId ?? ""
    let secret = card.latestSecret ?? "<rotate_secret_to_reveal>"
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
    UIPasteboard.general.string = envExportBlock()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onToast?("Copied env pack")
  }
}
