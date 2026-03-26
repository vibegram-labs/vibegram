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

private struct ChatNativeAgentConfigTheme {
  let panelTheme: ChatBuilderPanelTheme
  let destructiveColor: UIColor

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

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
    titleLabel.textColor = destructive ? theme.destructiveColor : theme.textColor
    titleLabel.numberOfLines = 1
    titleLabel.text = title
    addSubview(titleLabel)

    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    valueLabel.font = .systemFont(ofSize: 15.0, weight: .regular)
    valueLabel.textColor =
      destructive ? theme.destructiveColor.withAlphaComponent(0.8) : theme.secondaryTextColor
    valueLabel.numberOfLines = 1
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
      heightAnchor.constraint(greaterThanOrEqualToConstant: 56.0),
      highlightView.topAnchor.constraint(equalTo: topAnchor),
      highlightView.leadingAnchor.constraint(equalTo: leadingAnchor),
      highlightView.trailingAnchor.constraint(equalTo: trailingAnchor),
      highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -12.0),
      accessoryView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      accessoryView.centerYAnchor.constraint(equalTo: centerYAnchor),
      accessoryView.widthAnchor.constraint(equalToConstant: 18.0),
      accessoryView.heightAnchor.constraint(equalToConstant: 18.0),
      valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12.0),
      valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 0.5),
    ])

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
    if let secretValue = secretDisplayValue() {
      endpointsSection.contentStack.addArrangedSubview(
        makeCopyRow(title: "Secret", value: secretValue, copyValue: card.latestSecret)
      )
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

  private func secretDisplayValue() -> String? {
    if let latestSecret = card.latestSecret {
      return latestSecret
    }
    if let secretHint = card.secretHint {
      return secretHint
    }
    return "Rotate to reveal"
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
