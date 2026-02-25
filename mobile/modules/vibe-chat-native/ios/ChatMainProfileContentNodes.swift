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

final class ChatMainProfileAgentPromptNode: UIView, UITextViewDelegate {

  weak var delegate: ChatMainProfileAgentPromptNodeDelegate?

  // MARK: - Header

  private let headerBar = UIView()
  private let headerIcon = UIImageView()
  private let headerTitleLabel = UILabel()
  private let headerToggle = UISwitch()
  private let expandButton = UIButton(type: .system)

  // MARK: - Prompt Section

  private let promptSectionLabel = UILabel()
  private let promptTextView = UITextView()
  private let promptCharCountLabel = UILabel()
  private let promptPlaceholderLabel = UILabel()

  // MARK: - Agent Name

  private let nameSectionLabel = UILabel()
  private let nameField = UITextField()

  // MARK: - Model Section

  private let modelSectionLabel = UILabel()
  private let modelSelector = UISegmentedControl(items: ["GPT-4o", "GPT-4o-mini", "Claude 3.5"])

  // MARK: - Temperature

  private let temperatureSectionLabel = UILabel()
  private let temperatureSlider = UISlider()
  private let temperatureValueLabel = UILabel()

  // MARK: - Response Length

  private let responseLengthLabel = UILabel()
  private let responseLengthSelector = UISegmentedControl(items: ["Concise", "Normal", "Detailed"])

  // MARK: - Memory

  private let memorySectionLabel = UILabel()
  private let memoryToggle = UISwitch()
  private let memoryDescriptionLabel = UILabel()

  // MARK: - Actions

  private let deleteButton = UIButton(type: .system)

  // MARK: - State

  private var chatId: String = ""
  private var currentConfig: [String: Any] = [:]
  private var isExpanded = false

  private let purpleAccent = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
  private var textColor: UIColor = .white
  private var secondaryTextColor: UIColor = UIColor(white: 1.0, alpha: 0.58)
  private var surfaceColor: UIColor = UIColor(white: 1.0, alpha: 0.06)
  private var fieldBgColor: UIColor = UIColor(white: 1.0, alpha: 0.04)

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

    // ─── Header ───
    headerBar.clipsToBounds = true
    headerBar.layer.cornerCurve = .continuous
    addSubview(headerBar)

    let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    headerIcon.image = UIImage(systemName: "sparkles", withConfiguration: cfg)
    headerIcon.tintColor = purpleAccent
    headerIcon.contentMode = .scaleAspectFit
    headerBar.addSubview(headerIcon)

    headerTitleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    headerTitleLabel.text = "✦ AI Agent"
    headerBar.addSubview(headerTitleLabel)

    headerToggle.transform = CGAffineTransform(scaleX: 0.76, y: 0.76)
    headerToggle.onTintColor = purpleAccent
    headerToggle.addTarget(self, action: #selector(handleToggle), for: .valueChanged)
    headerBar.addSubview(headerToggle)

    expandButton.setImage(
      UIImage(
        systemName: "chevron.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)),
      for: .normal
    )
    expandButton.tintColor = secondaryTextColor
    expandButton.addTarget(self, action: #selector(handleExpandTapped), for: .touchUpInside)
    headerBar.addSubview(expandButton)

    let headerTap = UITapGestureRecognizer(target: self, action: #selector(handleExpandTapped))
    headerBar.addGestureRecognizer(headerTap)
    headerBar.isUserInteractionEnabled = true

    // ─── Agent Name ───
    nameSectionLabel.text = "AGENT NAME"
    nameSectionLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    addSubview(nameSectionLabel)

    nameField.font = UIFont.systemFont(ofSize: 15, weight: .medium)
    nameField.placeholder = "Vibe AI"
    nameField.borderStyle = .none
    nameField.layer.cornerRadius = 10
    nameField.layer.cornerCurve = .continuous
    nameField.clipsToBounds = true
    nameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
    nameField.leftViewMode = .always
    nameField.addTarget(self, action: #selector(handleFieldChanged), for: .editingChanged)
    addSubview(nameField)

    // ─── Prompt Section ───
    promptSectionLabel.text = "SYSTEM PROMPT"
    promptSectionLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    addSubview(promptSectionLabel)

    promptTextView.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    promptTextView.layer.cornerRadius = 12
    promptTextView.layer.cornerCurve = .continuous
    promptTextView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    promptTextView.isScrollEnabled = true
    promptTextView.delegate = self
    addSubview(promptTextView)

    promptPlaceholderLabel.text =
      "Describe the agent's personality, knowledge, and how it should respond..."
    promptPlaceholderLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    promptPlaceholderLabel.numberOfLines = 0
    promptPlaceholderLabel.isUserInteractionEnabled = false
    promptTextView.addSubview(promptPlaceholderLabel)

    promptCharCountLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    promptCharCountLabel.textAlignment = .right
    addSubview(promptCharCountLabel)

    // ─── Model ───
    modelSectionLabel.text = "MODEL"
    modelSectionLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    addSubview(modelSectionLabel)

    modelSelector.selectedSegmentIndex = 0
    modelSelector.addTarget(self, action: #selector(handleFieldChanged), for: .valueChanged)
    addSubview(modelSelector)

    // ─── Temperature ───
    temperatureSectionLabel.text = "CREATIVITY (TEMPERATURE)"
    temperatureSectionLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    addSubview(temperatureSectionLabel)

    temperatureSlider.minimumValue = 0.0
    temperatureSlider.maximumValue = 2.0
    temperatureSlider.value = 0.7
    temperatureSlider.minimumTrackTintColor = purpleAccent
    temperatureSlider.addTarget(
      self, action: #selector(handleTemperatureChanged), for: .valueChanged)
    addSubview(temperatureSlider)

    temperatureValueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    temperatureValueLabel.textAlignment = .right
    addSubview(temperatureValueLabel)

    // ─── Response Length ───
    responseLengthLabel.text = "RESPONSE LENGTH"
    responseLengthLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    addSubview(responseLengthLabel)

    responseLengthSelector.selectedSegmentIndex = 1
    responseLengthSelector.addTarget(
      self, action: #selector(handleFieldChanged), for: .valueChanged)
    addSubview(responseLengthSelector)

    // ─── Memory ───
    memorySectionLabel.text = "Conversation Memory"
    memorySectionLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    addSubview(memorySectionLabel)

    memoryToggle.onTintColor = purpleAccent
    memoryToggle.isOn = true
    memoryToggle.addTarget(self, action: #selector(handleFieldChanged), for: .valueChanged)
    addSubview(memoryToggle)

    memoryDescriptionLabel.text =
      "Agent remembers previous messages in this conversation for context."
    memoryDescriptionLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    memoryDescriptionLabel.numberOfLines = 0
    addSubview(memoryDescriptionLabel)

    // ─── Delete ───
    deleteButton.setTitle("Remove Agent", for: .normal)
    deleteButton.setTitleColor(.systemRed, for: .normal)
    deleteButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    deleteButton.addTarget(self, action: #selector(handleDeleteTapped), for: .touchUpInside)
    addSubview(deleteButton)

    updateTemperatureLabel()
    updatePromptPlaceholder()
    applyExpandedState(animated: false)
  }

  // MARK: - Public API

  func configure(chatId: String, config: [String: Any]?) {
    self.chatId = chatId
    if let config {
      currentConfig = config
      let name = (config["name"] as? String) ?? ""
      let prompt = (config["system_prompt"] as? String) ?? ""
      let enabled = (config["enabled"] as? Bool) ?? true
      let model = (config["model"] as? String) ?? "gpt-4o"
      let temperature = (config["temperature"] as? Double) ?? 0.7
      let memory = (config["memory_enabled"] as? Bool) ?? true
      let responseLength = (config["response_length"] as? String) ?? "normal"

      nameField.text = name
      promptTextView.text = prompt
      headerToggle.isOn = enabled

      switch model.lowercased() {
      case "gpt-4o": modelSelector.selectedSegmentIndex = 0
      case "gpt-4o-mini": modelSelector.selectedSegmentIndex = 1
      case "claude-3.5-sonnet", "claude-3-5-sonnet": modelSelector.selectedSegmentIndex = 2
      default: modelSelector.selectedSegmentIndex = 0
      }

      temperatureSlider.value = Float(temperature)
      memoryToggle.isOn = memory

      switch responseLength.lowercased() {
      case "concise": responseLengthSelector.selectedSegmentIndex = 0
      case "normal": responseLengthSelector.selectedSegmentIndex = 1
      case "detailed": responseLengthSelector.selectedSegmentIndex = 2
      default: responseLengthSelector.selectedSegmentIndex = 1
      }

      headerTitleLabel.text = "✦ \(name.isEmpty ? "AI Agent" : name)"
      deleteButton.isHidden = false
    } else {
      currentConfig = [:]
      nameField.text = ""
      promptTextView.text = ""
      headerToggle.isOn = false
      modelSelector.selectedSegmentIndex = 0
      temperatureSlider.value = 0.7
      memoryToggle.isOn = true
      responseLengthSelector.selectedSegmentIndex = 1
      headerTitleLabel.text = "✦ AI Agent"
      deleteButton.isHidden = true
    }
    updateTemperatureLabel()
    updatePromptPlaceholder()
    updatePromptCharCount()
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
    self.fieldBgColor = surfaceColor.withAlphaComponent(0.5)

    backgroundColor = surfaceColor

    headerTitleLabel.textColor = textColor
    headerIcon.tintColor = accentColor

    nameSectionLabel.textColor = secondaryTextColor
    nameField.textColor = textColor
    nameField.backgroundColor = fieldBgColor
    nameField.attributedPlaceholder = NSAttributedString(
      string: "Vibe AI",
      attributes: [.foregroundColor: secondaryTextColor.withAlphaComponent(0.5)]
    )

    promptSectionLabel.textColor = secondaryTextColor
    promptTextView.textColor = textColor
    promptTextView.backgroundColor = fieldBgColor
    promptPlaceholderLabel.textColor = secondaryTextColor.withAlphaComponent(0.5)
    promptCharCountLabel.textColor = secondaryTextColor

    modelSectionLabel.textColor = secondaryTextColor
    temperatureSectionLabel.textColor = secondaryTextColor
    temperatureValueLabel.textColor = textColor
    temperatureSlider.minimumTrackTintColor = accentColor

    responseLengthLabel.textColor = secondaryTextColor
    memorySectionLabel.textColor = textColor
    memoryDescriptionLabel.textColor = secondaryTextColor.withAlphaComponent(0.7)

    expandButton.tintColor = secondaryTextColor

    headerToggle.onTintColor = accentColor
    memoryToggle.onTintColor = accentColor

    setNeedsLayout()
  }

  // MARK: - Preferred Height

  func preferredHeight(for width: CGFloat) -> CGFloat {
    let headerH: CGFloat = 52.0
    if !isExpanded { return headerH }

    let pad: CGFloat = 16.0
    var h = headerH + 12.0  // gap after header

    // Agent name
    h += 18.0 + 4.0 + 38.0 + 16.0

    // Prompt section
    h += 18.0 + 4.0 + 120.0 + 4.0 + 14.0 + 16.0

    // Model
    h += 18.0 + 4.0 + 32.0 + 16.0

    // Temperature
    h += 18.0 + 4.0 + 32.0 + 16.0

    // Response length
    h += 18.0 + 4.0 + 32.0 + 16.0

    // Memory
    h += 20.0 + 4.0 + 36.0 + 16.0

    // Delete button
    if !deleteButton.isHidden {
      h += 36.0 + 12.0
    }

    return h + pad
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    let pad: CGFloat = 16.0

    let headerH: CGFloat = 52.0
    headerBar.frame = CGRect(x: 0, y: 0, width: w, height: headerH)
    headerIcon.frame = CGRect(x: pad, y: (headerH - 20) * 0.5, width: 20, height: 20)
    headerTitleLabel.frame = CGRect(x: pad + 28, y: 0, width: w - pad * 2 - 120, height: headerH)

    let toggleSize = headerToggle.intrinsicContentSize
    headerToggle.frame = CGRect(
      x: w - pad - toggleSize.width * 0.76 - 32,
      y: (headerH - toggleSize.height * 0.76) * 0.5,
      width: toggleSize.width,
      height: toggleSize.height
    )

    expandButton.frame = CGRect(x: w - pad - 24, y: (headerH - 24) * 0.5, width: 24, height: 24)

    guard isExpanded else { return }

    var y: CGFloat = headerH + 12.0
    let fieldW = w - pad * 2

    // Name
    nameSectionLabel.frame = CGRect(x: pad, y: y, width: fieldW, height: 16)
    y += 18.0
    nameField.frame = CGRect(x: pad, y: y, width: fieldW, height: 38)
    y += 42.0 + 12.0

    // Prompt
    promptSectionLabel.frame = CGRect(x: pad, y: y, width: fieldW, height: 16)
    y += 18.0
    promptTextView.frame = CGRect(x: pad, y: y, width: fieldW, height: 120)
    promptPlaceholderLabel.frame = CGRect(x: 12, y: 10, width: fieldW - 24, height: 60)
    y += 122.0
    promptCharCountLabel.frame = CGRect(x: pad, y: y, width: fieldW, height: 14)
    y += 18.0 + 12.0

    // Model
    modelSectionLabel.frame = CGRect(x: pad, y: y, width: fieldW, height: 16)
    y += 20.0
    modelSelector.frame = CGRect(x: pad, y: y, width: fieldW, height: 32)
    y += 36.0 + 12.0

    // Temperature
    temperatureSectionLabel.frame = CGRect(x: pad, y: y, width: fieldW - 48, height: 16)
    temperatureValueLabel.frame = CGRect(x: w - pad - 44, y: y, width: 44, height: 16)
    y += 20.0
    temperatureSlider.frame = CGRect(x: pad, y: y, width: fieldW, height: 28)
    y += 32.0 + 12.0

    // Response length
    responseLengthLabel.frame = CGRect(x: pad, y: y, width: fieldW, height: 16)
    y += 20.0
    responseLengthSelector.frame = CGRect(x: pad, y: y, width: fieldW, height: 32)
    y += 36.0 + 12.0

    // Memory
    memorySectionLabel.frame = CGRect(x: pad, y: y, width: fieldW - 60, height: 20)
    let memToggleSize = memoryToggle.intrinsicContentSize
    memoryToggle.frame = CGRect(
      x: w - pad - memToggleSize.width,
      y: y + (20 - memToggleSize.height) * 0.5,
      width: memToggleSize.width,
      height: memToggleSize.height
    )
    y += 24.0
    memoryDescriptionLabel.frame = CGRect(x: pad, y: y, width: fieldW, height: 36)
    y += 40.0 + 12.0

    // Delete
    if !deleteButton.isHidden {
      deleteButton.frame = CGRect(x: pad, y: y, width: fieldW, height: 36)
    }
  }

  // MARK: - UITextViewDelegate

  func textViewDidChange(_ textView: UITextView) {
    updatePromptPlaceholder()
    updatePromptCharCount()
    emitConfigUpdate()
  }

  // MARK: - Actions

  @objc private func handleToggle() {
    emitConfigUpdate()
  }

  @objc private func handleExpandTapped() {
    isExpanded.toggle()
    applyExpandedState(animated: true)
    // Notify parent for re-layout
    emitConfigUpdate()
  }

  @objc private func handleFieldChanged() {
    emitConfigUpdate()
  }

  @objc private func handleTemperatureChanged() {
    updateTemperatureLabel()
    emitConfigUpdate()
  }

  @objc private func handleDeleteTapped() {
    delegate?.agentPromptNodeDidRequestDelete(self)
  }

  // MARK: - Internal

  private func applyExpandedState(animated: Bool) {
    let hidden = !isExpanded
    let iconName = isExpanded ? "chevron.up" : "chevron.down"
    expandButton.setImage(
      UIImage(
        systemName: iconName,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)),
      for: .normal
    )

    let views: [UIView] = [
      nameSectionLabel, nameField,
      promptSectionLabel, promptTextView, promptCharCountLabel,
      modelSectionLabel, modelSelector,
      temperatureSectionLabel, temperatureSlider, temperatureValueLabel,
      responseLengthLabel, responseLengthSelector,
      memorySectionLabel, memoryToggle, memoryDescriptionLabel,
      deleteButton,
    ]

    if animated {
      UIView.animate(
        withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.3,
        options: [.curveEaseInOut, .allowUserInteraction]
      ) {
        for v in views { v.alpha = hidden ? 0.0 : 1.0 }
      }
    } else {
      for v in views { v.alpha = hidden ? 0.0 : 1.0 }
    }

    for v in views { v.isHidden = hidden }
  }

  private func updateTemperatureLabel() {
    temperatureValueLabel.text = String(format: "%.1f", temperatureSlider.value)
  }

  private func updatePromptPlaceholder() {
    promptPlaceholderLabel.isHidden = !(promptTextView.text ?? "").isEmpty
  }

  private func updatePromptCharCount() {
    let count = (promptTextView.text ?? "").count
    promptCharCountLabel.text = "\(count) / 4000"
  }

  private func emitConfigUpdate() {
    let modelOptions = ["gpt-4o", "gpt-4o-mini", "claude-3.5-sonnet"]
    let responseLengthOptions = ["concise", "normal", "detailed"]

    let config: [String: Any] = [
      "chat_id": chatId,
      "name": (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
      "system_prompt": (promptTextView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
      "enabled": headerToggle.isOn,
      "model": modelOptions[safe: modelSelector.selectedSegmentIndex] ?? "gpt-4o",
      "temperature": Double(temperatureSlider.value),
      "memory_enabled": memoryToggle.isOn,
      "response_length": responseLengthOptions[safe: responseLengthSelector.selectedSegmentIndex]
        ?? "normal",
    ]
    currentConfig = config
    let displayName = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    headerTitleLabel.text = "✦ \(displayName.isEmpty ? "AI Agent" : displayName)"
    delegate?.agentPromptNode(self, didUpdateConfig: config)
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
