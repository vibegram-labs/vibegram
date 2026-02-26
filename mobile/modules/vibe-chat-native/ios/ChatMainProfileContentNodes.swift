import UIKit

final class ChatMainProfileTabNode: UIControl {
  private let titleLabel = UILabel()
  private let pressedOverlay = UIView()

  private var normalTextColor: UIColor = .secondaryLabel
  private var activeTextColor: UIColor = .label
  private var activeBackgroundColor: UIColor = UIColor(white: 1.0, alpha: 0.12)

  var isActive: Bool = false {
    didSet { applyState() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 18.0

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    titleLabel.textAlignment = .center
    addSubview(titleLabel)

    pressedOverlay.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    pressedOverlay.alpha = 0.0
    pressedOverlay.isUserInteractionEnabled = false
    addSubview(pressedOverlay)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    titleLabel.frame = bounds.insetBy(dx: 14.0, dy: 6.0)
    pressedOverlay.frame = bounds
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(
        withDuration: isHighlighted ? 0.08 : 0.18, delay: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) {
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
        self.pressedOverlay.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  func setTitle(_ title: String) {
    titleLabel.text = title
  }

  func applyTheme(
    activeTextColor: UIColor,
    normalTextColor: UIColor,
    activeBackgroundColor: UIColor
  ) {
    self.activeTextColor = activeTextColor
    self.normalTextColor = normalTextColor
    self.activeBackgroundColor = activeBackgroundColor
    applyState()
  }

  private func applyState() {
    backgroundColor = isActive ? activeBackgroundColor : .clear
    titleLabel.textColor = isActive ? activeTextColor : normalTextColor
  }
}

final class ChatMainProfileListRowNode: UIControl {
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let separatorView = UIView()
  private let pressedOverlay = UIView()

  private var defaultTitleColor: UIColor = .label
  private var subtitleColor: UIColor = .secondaryLabel
  private var separatorColor: UIColor = UIColor(white: 1.0, alpha: 0.08)
  private var highlightedColor: UIColor = UIColor(white: 1.0, alpha: 0.04)
  private var titleColorOverride: UIColor?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    clipsToBounds = true

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    titleLabel.numberOfLines = 1
    addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    subtitleLabel.numberOfLines = 2
    addSubview(subtitleLabel)

    separatorView.backgroundColor = separatorColor
    addSubview(separatorView)

    pressedOverlay.backgroundColor = highlightedColor
    pressedOverlay.alpha = 0.0
    pressedOverlay.isUserInteractionEnabled = false
    addSubview(pressedOverlay)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let insetX: CGFloat = 18.0
    titleLabel.frame = CGRect(
      x: insetX, y: 11.0, width: bounds.width - (insetX * 2.0), height: 22.0)
    let subtitleHeight = max(0.0, bounds.height - titleLabel.frame.maxY - 11.0)
    subtitleLabel.frame = CGRect(
      x: insetX,
      y: titleLabel.frame.maxY + 1.0,
      width: bounds.width - (insetX * 2.0),
      height: subtitleHeight
    )
    separatorView.frame = CGRect(
      x: insetX,
      y: bounds.height - (1.0 / UIScreen.main.scale),
      width: max(0.0, bounds.width - (insetX * 2.0)),
      height: 1.0 / UIScreen.main.scale
    )
    pressedOverlay.frame = bounds
  }

  override var isHighlighted: Bool {
    didSet {
      guard isEnabled else { return }
      UIView.animate(
        withDuration: isHighlighted ? 0.08 : 0.16, delay: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) {
        self.pressedOverlay.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  func configure(
    title: String,
    subtitle: String,
    titleColor: UIColor? = nil,
    showsSeparator: Bool
  ) {
    titleLabel.text = title
    subtitleLabel.text = subtitle
    titleColorOverride = titleColor
    separatorView.isHidden = !showsSeparator
    titleLabel.textColor = titleColor ?? defaultTitleColor
    subtitleLabel.textColor = subtitleColor
  }

  func applyTheme(
    titleColor: UIColor,
    subtitleColor: UIColor,
    separatorColor: UIColor,
    highlightedColor: UIColor
  ) {
    defaultTitleColor = titleColor
    self.subtitleColor = subtitleColor
    self.separatorColor = separatorColor
    self.highlightedColor = highlightedColor
    titleLabel.textColor = titleColorOverride ?? titleColor
    subtitleLabel.textColor = subtitleColor
    separatorView.backgroundColor = separatorColor
    pressedOverlay.backgroundColor = highlightedColor
  }
}

final class ChatMainProfileMediaCellNode: UIControl {
  private static let imageCache = NSCache<NSString, UIImage>()

  private let imageView = UIImageView()
  private let placeholderIcon = UIImageView()
  private let videoBadge = UIView()
  private let videoBadgeLabel = UILabel()

  private var imageLoadTask: URLSessionDataTask?
  private var imageURLString: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  deinit {
    imageLoadTask?.cancel()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 3.0

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.isHidden = true
    addSubview(imageView)

    placeholderIcon.contentMode = .scaleAspectFit
    placeholderIcon.image = UIImage(systemName: "photo")
    addSubview(placeholderIcon)

    videoBadge.backgroundColor = UIColor(white: 0.0, alpha: 0.58)
    videoBadge.layer.cornerRadius = 7.0
    videoBadge.layer.cornerCurve = .continuous
    videoBadge.isHidden = true
    addSubview(videoBadge)

    videoBadgeLabel.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
    videoBadgeLabel.text = "VIDEO"
    videoBadgeLabel.textColor = .white
    videoBadgeLabel.textAlignment = .center
    videoBadge.addSubview(videoBadgeLabel)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
    placeholderIcon.frame = bounds.insetBy(dx: bounds.width * 0.3, dy: bounds.height * 0.3)

    let badgeHeight: CGFloat = 16.0
    let badgeWidth: CGFloat = 48.0
    videoBadge.frame = CGRect(
      x: max(0.0, bounds.width - badgeWidth - 6.0),
      y: max(0.0, bounds.height - badgeHeight - 6.0),
      width: badgeWidth,
      height: badgeHeight
    )
    videoBadgeLabel.frame = videoBadge.bounds.insetBy(dx: 4.0, dy: 1.0)
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(
        withDuration: isHighlighted ? 0.08 : 0.16, delay: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) {
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
        self.alpha = self.isHighlighted ? 0.86 : 1.0
      }
    }
  }

  func configure(urlString: String?, isVideo: Bool) {
    videoBadge.isHidden = !isVideo
    imageLoadTask?.cancel()
    imageLoadTask = nil
    imageView.image = nil
    imageView.isHidden = true
    placeholderIcon.isHidden = false
    imageURLString = nil

    guard let urlString, !urlString.isEmpty else { return }
    imageURLString = urlString

    if let cached = Self.imageCache.object(forKey: urlString as NSString) {
      imageView.image = cached
      imageView.isHidden = false
      placeholderIcon.isHidden = true
      return
    }

    guard let url = URL(string: urlString) else { return }
    if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
      Self.imageCache.setObject(image, forKey: urlString as NSString)
      imageView.image = image
      imageView.isHidden = false
      placeholderIcon.isHidden = true
      return
    }

    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      Self.imageCache.setObject(image, forKey: urlString as NSString)
      DispatchQueue.main.async {
        guard self.imageURLString == urlString else { return }
        self.imageView.image = image
        self.imageView.isHidden = false
        self.placeholderIcon.isHidden = true
      }
    }
    imageLoadTask = task
    task.resume()
  }

  func applyTheme(placeholderTintColor: UIColor, placeholderBackgroundColor: UIColor) {
    backgroundColor = placeholderBackgroundColor
    placeholderIcon.tintColor = placeholderTintColor
  }
}

// MARK: - Agent Prompt Control Node

protocol ChatMainProfileAgentPromptNodeDelegate: AnyObject {
  func agentPromptNode(
    _ node: ChatMainProfileAgentPromptNode, didUpdateConfig config: [String: Any])
  func agentPromptNodeDidRequestDelete(_ node: ChatMainProfileAgentPromptNode)
  func agentPromptNodeDidRequestFullEditor(_ node: ChatMainProfileAgentPromptNode)
}

final class ChatMainProfileAgentPromptNode: UIView {

  weak var delegate: ChatMainProfileAgentPromptNodeDelegate?

  private let headerBar = UIView()
  private let headerIcon = UIImageView()
  private let headerTitleLabel = UILabel()
  private let headerSubtitleLabel = UILabel()
  private let headerToggle = UISwitch()

  private let promptPreviewCard = UIView()
  private let promptPreviewTitleLabel = UILabel()
  private let promptPreviewLabel = UILabel()

  private let buttonStack = UIStackView()
  private let editButton = UIButton(type: .system)
  private let deleteButton = UIButton(type: .system)

  private var chatId: String = ""
  private var currentConfig: [String: Any] = [:]
  private var hasPersistedConfig = false

  private let defaultAccent = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
  private var textColor: UIColor = .white
  private var secondaryTextColor: UIColor = UIColor(white: 1.0, alpha: 0.58)
  private var surfaceColor: UIColor = UIColor(white: 1.0, alpha: 0.06)
  private var fieldBgColor: UIColor = UIColor(white: 1.0, alpha: 0.04)
  private var accentColor: UIColor = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 22.0

    headerBar.clipsToBounds = true
    addSubview(headerBar)

    let iconConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    headerIcon.image = UIImage(systemName: "sparkles", withConfiguration: iconConfig)
    headerIcon.contentMode = .scaleAspectFit
    headerIcon.tintColor = defaultAccent
    headerBar.addSubview(headerIcon)

    headerTitleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    headerTitleLabel.text = "✦ AI Agent"
    headerBar.addSubview(headerTitleLabel)

    headerSubtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    headerSubtitleLabel.text = "Single native model backend"
    headerBar.addSubview(headerSubtitleLabel)

    headerToggle.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
    headerToggle.onTintColor = defaultAccent
    headerToggle.addTarget(self, action: #selector(handleToggleChanged), for: .valueChanged)
    headerBar.addSubview(headerToggle)

    promptPreviewCard.layer.cornerRadius = 14.0
    promptPreviewCard.layer.cornerCurve = .continuous
    promptPreviewCard.clipsToBounds = true
    addSubview(promptPreviewCard)

    promptPreviewTitleLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    promptPreviewTitleLabel.text = "PROMPT PREVIEW"
    promptPreviewCard.addSubview(promptPreviewTitleLabel)

    promptPreviewLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    promptPreviewLabel.numberOfLines = 4
    promptPreviewCard.addSubview(promptPreviewLabel)

    buttonStack.axis = .horizontal
    buttonStack.spacing = 10.0
    buttonStack.distribution = .fillEqually
    addSubview(buttonStack)

    editButton.setTitle("Edit Agent", for: .normal)
    editButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    editButton.layer.cornerRadius = 14.0
    editButton.layer.cornerCurve = .continuous
    editButton.clipsToBounds = true
    editButton.addTarget(self, action: #selector(handleEditTapped), for: .touchUpInside)
    buttonStack.addArrangedSubview(editButton)

    deleteButton.setTitle("Remove Agent", for: .normal)
    deleteButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    deleteButton.layer.cornerRadius = 14.0
    deleteButton.layer.cornerCurve = .continuous
    deleteButton.layer.borderWidth = 1.0 / UIScreen.main.scale
    deleteButton.clipsToBounds = true
    deleteButton.addTarget(self, action: #selector(handleDeleteTapped), for: .touchUpInside)
    buttonStack.addArrangedSubview(deleteButton)

    applyTheme(
      textColor: textColor,
      secondaryTextColor: secondaryTextColor,
      surfaceColor: surfaceColor,
      accentColor: accentColor
    )
    refreshViewState()
  }

  func configure(chatId: String, config: [String: Any]?) {
    self.chatId = chatId
    hasPersistedConfig = config != nil

    if let config {
      var nextConfig: [String: Any] = [:]
      nextConfig["chat_id"] = chatId
      nextConfig["name"] = normalizedName(from: config)
      nextConfig["system_prompt"] = normalizedPrompt(from: config)
      nextConfig["enabled"] = normalizedEnabled(from: config, defaultValue: true)
      if let existingId = config["id"] {
        nextConfig["id"] = existingId
      }
      currentConfig = nextConfig
    } else {
      currentConfig = [
        "chat_id": chatId,
        "name": "Vibe AI",
        "system_prompt": "",
        "enabled": false,
      ]
    }

    refreshViewState()
    setNeedsLayout()
  }

  func applyTheme(
    textColor: UIColor,
    secondaryTextColor: UIColor,
    surfaceColor: UIColor,
    accentColor: UIColor
  ) {
    self.textColor = textColor
    self.secondaryTextColor = secondaryTextColor
    self.surfaceColor = surfaceColor
    self.accentColor = accentColor
    self.fieldBgColor = surfaceColor.withAlphaComponent(0.58)

    backgroundColor = surfaceColor
    headerTitleLabel.textColor = textColor
    headerSubtitleLabel.textColor = secondaryTextColor
    headerIcon.tintColor = accentColor
    headerToggle.onTintColor = accentColor

    promptPreviewCard.backgroundColor = fieldBgColor
    promptPreviewTitleLabel.textColor = secondaryTextColor
    promptPreviewLabel.textColor = textColor

    editButton.backgroundColor = accentColor
    editButton.setTitleColor(.white, for: .normal)

    deleteButton.backgroundColor = fieldBgColor
    deleteButton.setTitleColor(.systemRed, for: .normal)
    deleteButton.layer.borderColor = secondaryTextColor.withAlphaComponent(0.35).cgColor
  }

  func preferredHeight(for width: CGFloat) -> CGFloat {
    let headerHeight: CGFloat = 58.0
    let pad: CGFloat = 16.0
    let buttonHeight: CGFloat = 44.0
    var total = headerHeight + 10.0

    if shouldShowPromptPreview {
      total += promptCardHeight(for: width) + 10.0
    }

    total += buttonHeight + pad
    return total
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    let pad: CGFloat = 16.0
    let headerHeight: CGFloat = 58.0

    headerBar.frame = CGRect(x: 0.0, y: 0.0, width: width, height: headerHeight)
    headerIcon.frame = CGRect(x: pad, y: 12.0, width: 20.0, height: 20.0)
    headerTitleLabel.frame = CGRect(x: pad + 28.0, y: 8.0, width: width - 140.0, height: 22.0)
    headerSubtitleLabel.frame = CGRect(
      x: pad + 28.0, y: headerTitleLabel.frame.maxY - 1.0, width: width - 140.0, height: 18.0)

    let toggleSize = headerToggle.intrinsicContentSize
    let scaledToggleWidth = toggleSize.width * 0.82
    let scaledToggleHeight = toggleSize.height * 0.82
    headerToggle.frame = CGRect(
      x: width - pad - scaledToggleWidth,
      y: (headerHeight - scaledToggleHeight) * 0.5,
      width: toggleSize.width,
      height: toggleSize.height
    )

    var y = headerBar.frame.maxY + 6.0
    if shouldShowPromptPreview {
      let promptCardHeight = promptCardHeight(for: width)
      promptPreviewCard.frame = CGRect(
        x: pad,
        y: y,
        width: width - (pad * 2.0),
        height: promptCardHeight
      )
      promptPreviewTitleLabel.frame = CGRect(
        x: 12.0, y: 10.0, width: promptPreviewCard.bounds.width - 24.0, height: 14.0)
      promptPreviewLabel.frame = CGRect(
        x: 12.0, y: 28.0, width: promptPreviewCard.bounds.width - 24.0, height: promptCardHeight - 40.0)
      y = promptPreviewCard.frame.maxY + 10.0
    } else {
      promptPreviewCard.frame = .zero
      promptPreviewTitleLabel.frame = .zero
      promptPreviewLabel.frame = .zero
    }

    buttonStack.frame = CGRect(
      x: pad, y: y, width: width - (pad * 2.0), height: 44.0)
  }

  @objc private func handleToggleChanged() {
    let prompt = normalizedPrompt(from: currentConfig)
    if headerToggle.isOn && prompt.isEmpty {
      headerToggle.setOn(false, animated: true)
      delegate?.agentPromptNodeDidRequestFullEditor(self)
      return
    }
    emitConfigUpdate(enabled: headerToggle.isOn)
  }

  @objc private func handleEditTapped() {
    delegate?.agentPromptNodeDidRequestFullEditor(self)
  }

  @objc private func handleDeleteTapped() {
    delegate?.agentPromptNodeDidRequestDelete(self)
  }

  private var shouldShowPromptPreview: Bool {
    guard normalizedEnabled(from: currentConfig, defaultValue: false) else { return false }
    return !normalizedPrompt(from: currentConfig).isEmpty
  }

  private func refreshViewState() {
    let name = normalizedName(from: currentConfig)
    let prompt = normalizedPrompt(from: currentConfig)
    let isEnabled = normalizedEnabled(from: currentConfig, defaultValue: false)

    headerToggle.isOn = isEnabled
    headerTitleLabel.text = "✦ \(name)"
    headerSubtitleLabel.text = isEnabled ? "Single native model backend" : "Agent is paused"

    promptPreviewLabel.text = prompt
    promptPreviewCard.isHidden = !shouldShowPromptPreview
    deleteButton.isHidden = !hasPersistedConfig
    setNeedsLayout()
  }

  private func normalizedName(from config: [String: Any]) -> String {
    let raw = (config["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return raw.isEmpty ? "Vibe AI" : raw
  }

  private func normalizedPrompt(from config: [String: Any]) -> String {
    let snake =
      (config["system_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !snake.isEmpty { return snake }
    return
      (config["systemPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func normalizedEnabled(from config: [String: Any], defaultValue: Bool) -> Bool {
    guard let raw = config["enabled"] else { return defaultValue }
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

  private func promptCardHeight(for width: CGFloat) -> CGFloat {
    let availableWidth = max(10.0, width - 56.0)
    let promptText = normalizedPrompt(from: currentConfig)
    let bounding = (promptText as NSString).boundingRect(
      with: CGSize(width: availableWidth, height: 140.0),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: UIFont.systemFont(ofSize: 14.0, weight: .regular)],
      context: nil
    )
    let textHeight = min(96.0, ceil(bounding.height))
    return max(68.0, 28.0 + textHeight + 12.0)
  }

  private func emitConfigUpdate(enabled: Bool) {
    var config = currentConfig
    config["chat_id"] = chatId
    config["name"] = normalizedName(from: config)
    config["system_prompt"] = normalizedPrompt(from: config)
    config["enabled"] = enabled
    currentConfig = config
    refreshViewState()
    delegate?.agentPromptNode(self, didUpdateConfig: config)
  }
}
