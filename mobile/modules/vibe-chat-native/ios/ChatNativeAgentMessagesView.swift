import UIKit

private enum ChatNativeAgentRowPresentationKind: String {
  case legacy
  case assistant
  case assistantProgressTree
  case assistantActions
  case assistantAgentCard
}

private enum ChatNativeAgentMessageAction: String {
  case copy
  case thumbUp
  case thumbDown
  case regenerate
}

private final class ChatNativeAgentPlainTextView: UIView {
  private let baseLabel = ChatNativeStreamingTextLabel()
  private let shimmerLabel = ChatNativeStreamingTextLabel()
  private let shimmerGradient = CAGradientLayer()
  private var cachedFrame: CGRect = .zero
  private var isShimmering = false
  private var lastText: String?
  private var lastRowKey: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    [baseLabel, shimmerLabel].forEach {
      $0.numberOfLines = 0
      $0.backgroundColor = .clear
      addSubview($0)
    }

    shimmerGradient.startPoint = CGPoint(x: 0, y: 0.5)
    shimmerGradient.endPoint = CGPoint(x: 1, y: 0.5)
    shimmerGradient.locations = [0.2, 0.5, 0.8]
    shimmerLabel.layer.mask = shimmerGradient
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    let isProgress = row.messageType == "agent_progress"
    let text = (row.plainContent ?? row.text).trimmingCharacters(in: .whitespacesAndNewlines)
    let font =
      isProgress
      ? UIFont.systemFont(ofSize: 11.5, weight: .medium)
      : UIFont.systemFont(ofSize: 18, weight: .regular)
    let lineHeight: CGFloat = isProgress ? 16.0 : 26.0
    let baseColor =
      isProgress
      ? appearance.timeColorThem.withAlphaComponent(0.35)
      : appearance.textColorThem
    let highlightColor =
      isProgress
      ? appearance.timeColorThem.withAlphaComponent(0.85)
      : appearance.textColorThem

    let topPadding: CGFloat = isProgress ? 8.0 : 4.0
    let bottomPadding: CGFloat = isProgress ? 6.0 : 16.0
    let leftPadding: CGFloat = 8.0
    let rightPadding: CGFloat = 32.0
    let labelWidth = max(1.0, availableWidth - leftPadding - rightPadding)

    let baseAttributed = ChatNativeAgentTextRenderer.makeAttributedText(
      text: text,
      font: font,
      textColor: baseColor,
      lineHeight: lineHeight
    )
    let highlightAttributed = ChatNativeAgentTextRenderer.makeAttributedText(
      text: text,
      font: font,
      textColor: highlightColor,
      lineHeight: lineHeight
    )

    let measuredSize = ChatNativeAgentTextRenderer.measuredSize(for: baseAttributed, width: labelWidth)
    let textHeight = max(ceil(font.lineHeight), measuredSize.height)
    let textWidth = min(labelWidth, measuredSize.width)

    baseLabel.textColor = baseColor
    shimmerLabel.textColor = highlightColor

    let isStreaming = row.isStreamingText && !isProgress
    let shouldTransition = isProgress && (lastText != text || lastRowKey != row.key)

    if shouldTransition {
      UIView.transition(
        with: self,
        duration: 0.22,
        options: [.transitionCrossDissolve, .allowUserInteraction]
      ) {
        self.performLabelUpdate(
          baseAttributed: baseAttributed,
          highlightAttributed: highlightAttributed,
          text: text,
          isStreaming: isStreaming
        )
      }
    } else {
      performLabelUpdate(
        baseAttributed: baseAttributed,
        highlightAttributed: highlightAttributed,
        text: text,
        isStreaming: isStreaming
      )
    }

    lastText = text
    lastRowKey = row.key

    cachedFrame = CGRect(
      x: leftPadding,
      y: topPadding,
      width: textWidth,
      height: textHeight
    )

    if isProgress {
      shimmerGradient.colors = [
        UIColor.black.withAlphaComponent(0.0).cgColor,
        UIColor.black.cgColor,
        UIColor.black.withAlphaComponent(0.0).cgColor,
      ]
      startShimmerAnimation()
    } else {
      stopShimmerAnimation()
    }

    setNeedsLayout()
    return topPadding + textHeight + bottomPadding
  }

  private func performLabelUpdate(
    baseAttributed: NSAttributedString,
    highlightAttributed: NSAttributedString,
    text: String,
    isStreaming: Bool
  ) {
    baseLabel.applyStreamingText(baseAttributed, rawText: text, isStreaming: isStreaming)
    shimmerLabel.applyStreamingText(highlightAttributed, rawText: text, isStreaming: isStreaming)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    baseLabel.frame = cachedFrame
    shimmerLabel.frame = cachedFrame
    shimmerGradient.frame = shimmerLabel.bounds
  }

  private func startShimmerAnimation() {
    guard !isShimmering else { return }
    isShimmering = true
    shimmerLabel.isHidden = false
    shimmerLabel.alpha = 1.0

    let animation = CABasicAnimation(keyPath: "locations")
    animation.fromValue = [-1.5, -0.75, 0.0]
    animation.toValue = [1.0, 1.75, 2.5]
    animation.duration = 1.35
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    shimmerGradient.add(animation, forKey: "shimmerLocations")
  }

  private func stopShimmerAnimation() {
    guard isShimmering else { return }
    isShimmering = false
    shimmerGradient.removeAnimation(forKey: "shimmerLocations")
    shimmerLabel.isHidden = true
  }
}

private final class ChatNativeAgentProgressStepView: UIView {
  private let connectorView = UIView()
  private let dotView = UIView()
  private let baseLabel = ChatNativeStreamingTextLabel()
  private let shimmerLabel = ChatNativeStreamingTextLabel()
  private let shimmerGradient = CAGradientLayer()
  private var cachedConnectorFrame: CGRect = .zero
  private var cachedDotFrame: CGRect = .zero
  private var cachedLabelFrame: CGRect = .zero
  private var isPulsing = false
  private var isShimmering = false
  private var lastNodeId: String?
  private var lastLabelText: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    connectorView.isHidden = true
    addSubview(connectorView)

    dotView.isHidden = true
    addSubview(dotView)

    [baseLabel, shimmerLabel].forEach {
      $0.numberOfLines = 0
      $0.backgroundColor = .clear
      addSubview($0)
    }

    shimmerGradient.startPoint = CGPoint(x: 0, y: 0.5)
    shimmerGradient.endPoint = CGPoint(x: 1, y: 0.5)
    shimmerGradient.locations = [0.2, 0.5, 0.8]
    shimmerLabel.layer.mask = shimmerGradient
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    node: ChatListRow.AgentProgressNode,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    let indent = CGFloat(node.depth) * 18.0
    let topPadding: CGFloat = 6.0
    let bottomPadding: CGFloat = 8.0
    let dotSize: CGFloat = node.depth == 0 ? 8.0 : 6.0
    let dotX = 8.0 + indent
    let labelX = dotX + dotSize + 10.0
    let labelWidth = max(1.0, availableWidth - labelX - 8.0)
    let font = UIFont.systemFont(ofSize: node.depth == 0 ? 12.0 : 11.0, weight: node.depth == 0 ? .semibold : .medium)
    let lineHeight: CGFloat = node.depth == 0 ? 16.0 : 14.0
    let textColor: UIColor

    switch node.status {
    case "complete":
      textColor = appearance.textColorThem.withAlphaComponent(0.78)
      dotView.backgroundColor = appearance.timeColorThem.withAlphaComponent(0.72)
      stopPulse()
    case "error":
      textColor = UIColor.systemRed.withAlphaComponent(0.94)
      dotView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.88)
      stopPulse()
    default:
      textColor = appearance.textColorThem.withAlphaComponent(node.depth == 0 ? 0.96 : 0.90)
      dotView.backgroundColor = appearance.textColorThem.withAlphaComponent(node.depth == 0 ? 0.94 : 0.78)
      startPulse()
    }

    connectorView.isHidden = node.depth == 0
    connectorView.backgroundColor =
      appearance.timeColorThem.withAlphaComponent(node.depth == 0 ? 0.0 : 0.28)
    dotView.isHidden = false

    let isRunning = node.status != "complete" && node.status != "error"
    let baseColor = isRunning ? textColor.withAlphaComponent(0.35) : textColor
    let highlightColor = isRunning ? textColor.withAlphaComponent(0.85) : textColor

    let attributed = ChatNativeAgentTextRenderer.makeAttributedText(
      text: node.label,
      font: font,
      textColor: baseColor,
      lineHeight: lineHeight
    )
    let highlightAttributed = ChatNativeAgentTextRenderer.makeAttributedText(
      text: node.label,
      font: font,
      textColor: highlightColor,
      lineHeight: lineHeight
    )

    let measuredSize = ChatNativeAgentTextRenderer.measuredSize(for: attributed, width: labelWidth)
    let textHeight = max(ceil(font.lineHeight), measuredSize.height)
    let textWidth = min(labelWidth, measuredSize.width)

    let shouldTransition = lastNodeId != node.id || lastLabelText != node.label
    if shouldTransition {
      UIView.transition(
        with: self,
        duration: 0.22,
        options: [.transitionCrossDissolve, .allowUserInteraction]
      ) {
        self.performLabelUpdate(
          baseAttributed: attributed,
          highlightAttributed: highlightAttributed,
          text: node.label
        )
      }
    } else {
      performLabelUpdate(
        baseAttributed: attributed,
        highlightAttributed: highlightAttributed,
        text: node.label
      )
    }
    lastNodeId = node.id
    lastLabelText = node.label

    if isRunning {
      shimmerGradient.colors = [
        UIColor.black.withAlphaComponent(0.0).cgColor,
        UIColor.black.cgColor,
        UIColor.black.withAlphaComponent(0.0).cgColor,
      ]
      startShimmerAnimation()
    } else {
      stopShimmerAnimation()
    }

    cachedConnectorFrame = CGRect(
      x: dotX + floor((dotSize - 1.0) * 0.5),
      y: 0.0,
      width: 1.0 / UIScreen.main.scale,
      height: topPadding + textHeight + bottomPadding
    )
    cachedDotFrame = CGRect(
      x: dotX,
      y: topPadding + 4.0,
      width: dotSize,
      height: dotSize
    )
    cachedLabelFrame = CGRect(
      x: labelX,
      y: topPadding,
      width: textWidth,
      height: textHeight
    )

    setNeedsLayout()
    return topPadding + textHeight + bottomPadding
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    connectorView.frame = cachedConnectorFrame
    dotView.frame = cachedDotFrame
    dotView.layer.cornerRadius = cachedDotFrame.width * 0.5
    baseLabel.frame = cachedLabelFrame
    shimmerLabel.frame = cachedLabelFrame
    shimmerGradient.frame = shimmerLabel.bounds
  }

  private func performLabelUpdate(
    baseAttributed: NSAttributedString,
    highlightAttributed: NSAttributedString,
    text: String
  ) {
    baseLabel.applyStreamingText(baseAttributed, rawText: text, isStreaming: false)
    shimmerLabel.applyStreamingText(highlightAttributed, rawText: text, isStreaming: false)
  }

  private func startPulse() {
    guard !isPulsing else { return }
    isPulsing = true

    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.92
    scale.toValue = 1.16
    scale.duration = 0.85
    scale.autoreverses = true
    scale.repeatCount = .infinity
    scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    dotView.layer.add(scale, forKey: "agentProgressPulseScale")

    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0.55
    opacity.toValue = 1.0
    opacity.duration = 0.85
    opacity.autoreverses = true
    opacity.repeatCount = .infinity
    opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    dotView.layer.add(opacity, forKey: "agentProgressPulseOpacity")
  }

  private func stopPulse() {
    guard isPulsing else { return }
    isPulsing = false
    dotView.layer.removeAnimation(forKey: "agentProgressPulseScale")
    dotView.layer.removeAnimation(forKey: "agentProgressPulseOpacity")
  }

  private func startShimmerAnimation() {
    guard !isShimmering else { return }
    isShimmering = true
    shimmerLabel.isHidden = false
    shimmerLabel.alpha = 1.0

    let animation = CABasicAnimation(keyPath: "locations")
    animation.fromValue = [-1.5, -0.75, 0.0]
    animation.toValue = [1.0, 1.75, 2.5]
    animation.duration = 1.35
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    shimmerGradient.add(animation, forKey: "stepShimmerLocations")
  }

  private func stopShimmerAnimation() {
    guard isShimmering else { return }
    isShimmering = false
    shimmerGradient.removeAnimation(forKey: "stepShimmerLocations")
    shimmerLabel.isHidden = true
  }
}

private final class ChatNativeAgentProgressTreeView: UIView {
  private let cardView = UIView()
  private var stepViews: [ChatNativeAgentProgressStepView] = []
  private var cachedCardFrame: CGRect = .zero
  private var cachedStepFrames: [CGRect] = []
  private var lastNodeIds: [String] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    cardView.layer.cornerCurve = .continuous
    cardView.layer.cornerRadius = 16.0
    addSubview(cardView)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    let nodes = row.agentProgressNodes

    // Inline design: show only the deepest (last) running node as a single flat row.
    // Force depth=0 so there is no indentation or connector line.
    let displayNodes: [ChatListRow.AgentProgressNode]
    if let lastNode = nodes.last {
      displayNodes = [
        ChatListRow.AgentProgressNode(
          id: lastNode.id, label: lastNode.label, status: lastNode.status, depth: 0)
      ]
    } else {
      displayNodes = []
    }

    while stepViews.count < displayNodes.count {
      let view = ChatNativeAgentProgressStepView()
      view.alpha = 0.0
      stepViews.append(view)
      cardView.addSubview(view)
    }
    while stepViews.count > displayNodes.count {
      stepViews.removeLast().removeFromSuperview()
    }

    cardView.backgroundColor = .clear
    cardView.layer.borderWidth = 0.0
    cardView.layer.borderColor = UIColor.clear.cgColor

    guard !displayNodes.isEmpty else {
      cachedCardFrame = .zero
      cachedStepFrames = []
      setNeedsLayout()
      return 0
    }

    let innerPaddingY: CGFloat = 2.0
    let innerWidth = max(1.0, availableWidth)
    var currentY = innerPaddingY
    var nextStepFrames: [CGRect] = []
    let nextNodeIds = displayNodes.map(\.id)

    for (index, node) in displayNodes.enumerated() {
      let stepHeight = stepViews[index].configure(
        node: node,
        appearance: appearance,
        availableWidth: innerWidth
      )
      nextStepFrames.append(CGRect(x: 0.0, y: currentY, width: innerWidth, height: stepHeight))
      currentY += stepHeight
    }

    cachedCardFrame = CGRect(x: 0.0, y: 0.0, width: innerWidth, height: currentY + innerPaddingY)
    cachedStepFrames = nextStepFrames
    setNeedsLayout()

    if nextNodeIds != lastNodeIds {
      for (index, stepView) in stepViews.enumerated() where index < nextNodeIds.count {
        if !lastNodeIds.contains(nextNodeIds[index]) {
          stepView.alpha = 0.0
          UIView.animate(withDuration: 0.24, delay: 0.03 * Double(index), options: [.curveEaseOut, .allowUserInteraction]) {
            stepView.alpha = 1.0
          }
        } else {
          stepView.alpha = 1.0
        }
      }
      lastNodeIds = nextNodeIds
    }

    return cachedCardFrame.maxY + 4.0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    cardView.frame = cachedCardFrame
    for (index, stepView) in stepViews.enumerated() where index < cachedStepFrames.count {
      stepView.frame = cachedStepFrames[index]
    }
  }
}

private final class ChatNativeAgentActionBarView: UIView {
  private let buttonSize: CGFloat = 28.0
  private let stackView = UIStackView()
  private let copyButton = UIButton(type: .system)
  private let thumbUpButton = UIButton(type: .system)
  private let thumbDownButton = UIButton(type: .system)
  private let regenerateButton = UIButton(type: .system)
  private var cachedStackFrame: CGRect = .zero
  private var sourceMessageId: String = ""
  private var sourceText: String = ""
  private var regeneratePrompt: String = ""

  var onNativeEvent: (([String: Any]) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    stackView.axis = .horizontal
    stackView.alignment = .center
    stackView.distribution = .fill
    stackView.spacing = 8.0
    addSubview(stackView)

    configureButton(copyButton, symbolName: "doc.on.doc", action: .copy)
    configureButton(thumbUpButton, symbolName: "hand.thumbsup", action: .thumbUp)
    configureButton(thumbDownButton, symbolName: "hand.thumbsdown", action: .thumbDown)
    configureButton(regenerateButton, symbolName: "arrow.clockwise", action: .regenerate)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    sourceMessageId = row.agentActionSourceId ?? ""
    sourceText = row.agentActionSourceText ?? row.plainContent ?? row.text
    regeneratePrompt = row.agentRegeneratePrompt ?? ""

    let iconColor = appearance.timeColorThem.withAlphaComponent(0.78)

    [copyButton, thumbUpButton, thumbDownButton, regenerateButton].forEach { button in
      button.tintColor = iconColor
      button.backgroundColor = .clear
    }

    let hasSourceText = !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    copyButton.isHidden = !hasSourceText
    thumbUpButton.isHidden = !hasSourceText
    thumbDownButton.isHidden = !hasSourceText
    regenerateButton.isHidden =
      regeneratePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    let visibleButtons = [copyButton, thumbUpButton, thumbDownButton, regenerateButton]
      .filter { !$0.isHidden }
    let contentWidth =
      CGFloat(visibleButtons.count) * buttonSize
      + CGFloat(max(0, visibleButtons.count - 1)) * stackView.spacing
    cachedStackFrame = CGRect(
      x: 8.0,
      y: 6.0,
      width: min(max(1.0, contentWidth), max(1.0, availableWidth - 40.0)),
      height: buttonSize
    )
    setNeedsLayout()
    return 40.0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    stackView.frame = cachedStackFrame
    [copyButton, thumbUpButton, thumbDownButton, regenerateButton].forEach { button in
      button.layer.cornerRadius = 0.0
    }
  }

  private func configureButton(
    _ button: UIButton,
    symbolName: String,
    action: ChatNativeAgentMessageAction
  ) {
    let config = UIImage.SymbolConfiguration(pointSize: 16.0, weight: .medium)
    button.translatesAutoresizingMaskIntoConstraints = false
    var buttonConfiguration = UIButton.Configuration.plain()
    buttonConfiguration.contentInsets = NSDirectionalEdgeInsets(
      top: 6.0,
      leading: 6.0,
      bottom: 6.0,
      trailing: 6.0
    )
    buttonConfiguration.image = UIImage(systemName: symbolName, withConfiguration: config)
    button.configuration = buttonConfiguration
    button.frame.size = CGSize(width: buttonSize, height: buttonSize)
    button.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
    button.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
    button.accessibilityIdentifier = action.rawValue
    button.addTarget(self, action: #selector(handleButtonTap(_:)), for: .touchUpInside)
    stackView.addArrangedSubview(button)
  }

  @objc private func handleButtonTap(_ sender: UIButton) {
    guard let actionRaw = sender.accessibilityIdentifier,
      let action = ChatNativeAgentMessageAction(rawValue: actionRaw)
    else {
      return
    }

    onNativeEvent?([
      "type": "agentMessageAction",
      "action": action.rawValue,
      "sourceMessageId": sourceMessageId,
      "sourceText": sourceText,
      "regeneratePrompt": regeneratePrompt,
    ])
  }
}

private final class ChatNativeAgentCardView: UIControl {
  private let cardView = UIView()
  private let statusView = UIView()
  private let statusLabel = UILabel()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let detailLabel = UILabel()
  private let chevronView = UIImageView()
  private var cachedCardFrame: CGRect = .zero
  private var cachedStatusFrame: CGRect = .zero
  private var cachedStatusLabelFrame: CGRect = .zero
  private var cachedTitleFrame: CGRect = .zero
  private var cachedSubtitleFrame: CGRect = .zero
  private var cachedDetailFrame: CGRect = .zero
  private var cachedChevronFrame: CGRect = .zero
  private var currentCard: ChatListRow.AgentCard?
  var onNativeEvent: (([String: Any]) -> Void)?

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.14) {
        self.cardView.alpha = self.isHighlighted ? 0.82 : 1.0
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
      }
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    cardView.layer.cornerCurve = .continuous
    cardView.layer.cornerRadius = 18.0
    addSubview(cardView)

    statusView.layer.cornerCurve = .continuous
    statusView.layer.cornerRadius = 10.0
    cardView.addSubview(statusView)

    statusLabel.font = .systemFont(ofSize: 11.0, weight: .semibold)
    statusLabel.textAlignment = .center
    statusView.addSubview(statusLabel)

    titleLabel.font = .systemFont(ofSize: 16.0, weight: .semibold)
    titleLabel.numberOfLines = 2
    cardView.addSubview(titleLabel)

    subtitleLabel.font = .systemFont(ofSize: 13.0, weight: .medium)
    subtitleLabel.numberOfLines = 1
    cardView.addSubview(subtitleLabel)

    detailLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
    detailLabel.numberOfLines = 2
    cardView.addSubview(detailLabel)

    chevronView.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)
    )
    cardView.addSubview(chevronView)

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    guard let card = row.agentCard else {
      currentCard = nil
      cachedCardFrame = .zero
      return 0.0
    }
    currentCard = card

    let outerLeft: CGFloat = 6.0
    let outerRight: CGFloat = 26.0
    let cardWidth = max(1.0, availableWidth - outerLeft - outerRight)
    let contentLeft: CGFloat = 16.0
    let contentRight: CGFloat = 16.0
    let topPadding: CGFloat = 14.0
    let bottomPadding: CGFloat = 14.0
    let chevronSize = CGSize(width: 16.0, height: 16.0)
    let chevronRight: CGFloat = 14.0
    let contentWidth = max(1.0, cardWidth - contentLeft - contentRight - chevronSize.width - chevronRight)

    cardView.backgroundColor = appearance.bubbleThemColor.withAlphaComponent(0.22)
    cardView.layer.borderWidth = 1.0
    cardView.layer.borderColor = appearance.dayBorderColor.withAlphaComponent(0.22).cgColor

    let statusText = card.status.uppercased()
    statusLabel.text = statusText
    statusLabel.textColor = statusText == "PUBLISHED" ? appearance.textColorThem : appearance.timeColorThem
    let publishedBase = appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor
    statusView.backgroundColor =
      (statusText == "PUBLISHED" ? publishedBase : appearance.dayBackgroundColor)
      .withAlphaComponent(0.9)

    titleLabel.text = card.displayName
    titleLabel.textColor = appearance.textColorThem

    subtitleLabel.text = card.subtitleText
    subtitleLabel.textColor = appearance.timeColorThem.withAlphaComponent(0.92)

    let detailText = buildDetailText(for: card)
    detailLabel.text = detailText
    detailLabel.textColor = appearance.timeColorThem.withAlphaComponent(0.76)
    detailLabel.isHidden = detailText == nil

    chevronView.tintColor = appearance.timeColorThem.withAlphaComponent(0.5)

    let statusPaddingX: CGFloat = 10.0
    let statusPaddingY: CGFloat = 5.0
    let statusSize = (statusText as NSString).size(withAttributes: [.font: statusLabel.font as Any])
    let statusWidth = ceil(statusSize.width) + statusPaddingX * 2.0
    let statusHeight = ceil(statusSize.height) + statusPaddingY * 2.0
    cachedStatusFrame = CGRect(x: contentLeft, y: topPadding, width: statusWidth, height: statusHeight)
    cachedStatusLabelFrame = CGRect(x: statusPaddingX, y: statusPaddingY, width: ceil(statusSize.width), height: ceil(statusSize.height))

    let chevronX = cardWidth - chevronRight - chevronSize.width
    cachedChevronFrame = CGRect(
      x: chevronX,
      y: topPadding + 2.0,
      width: chevronSize.width,
      height: chevronSize.height
    )

    let titleY = cachedStatusFrame.maxY + 10.0
    let titleSize = titleLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
    cachedTitleFrame = CGRect(
      x: contentLeft,
      y: titleY,
      width: contentWidth,
      height: ceil(titleSize.height)
    )

    let subtitleY = cachedTitleFrame.maxY + 4.0
    let subtitleSize = subtitleLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
    cachedSubtitleFrame = CGRect(
      x: contentLeft,
      y: subtitleY,
      width: contentWidth,
      height: ceil(subtitleSize.height)
    )

    var bottomY = cachedSubtitleFrame.maxY
    if let detailText, !detailText.isEmpty {
      let detailY = bottomY + 8.0
      let detailSize = detailLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
      cachedDetailFrame = CGRect(
        x: contentLeft,
        y: detailY,
        width: contentWidth,
        height: ceil(detailSize.height)
      )
      bottomY = cachedDetailFrame.maxY
    } else {
      cachedDetailFrame = .zero
    }

    cachedCardFrame = CGRect(
      x: outerLeft,
      y: 4.0,
      width: cardWidth,
      height: bottomY + bottomPadding
    )

    setNeedsLayout()
    return cachedCardFrame.maxY + 8.0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    cardView.frame = cachedCardFrame
    statusView.frame = cachedStatusFrame
    statusLabel.frame = cachedStatusLabelFrame
    titleLabel.frame = cachedTitleFrame
    subtitleLabel.frame = cachedSubtitleFrame
    detailLabel.frame = cachedDetailFrame
    chevronView.frame = cachedChevronFrame
  }

  private func buildDetailText(for card: ChatListRow.AgentCard) -> String? {
    if let promptStatus = card.promptStatus, !promptStatus.isEmpty {
      return promptStatus
    }
    if let defaultChat = card.defaultDestinationChat {
      return defaultChat.name ?? defaultChat.chatId
    }
    if let promptPreview = card.promptPreview, !promptPreview.isEmpty {
      return promptPreview
    }
    return nil
  }

  @objc private func handleTap() {
    guard let currentCard else { return }
    onNativeEvent?([
      "type": "agentCardPressed",
      "card": currentCard.rawValue,
    ])
  }
}

private final class ChatNativeAgentRowHostView: UIView {
  private let legacyCell = ChatListCell(frame: .zero)
  private let assistantView = ChatNativeAgentPlainTextView()
  private let assistantProgressTreeView = ChatNativeAgentProgressTreeView()
  private let assistantActionsView = ChatNativeAgentActionBarView()
  private let assistantAgentCardView = ChatNativeAgentCardView()
  private var currentPresentationKind: ChatNativeAgentRowPresentationKind?
  private var cachedSubviewFrame: CGRect = .zero

  var onNativeEvent: (([String: Any]) -> Void)? {
    didSet {
      assistantActionsView.onNativeEvent = onNativeEvent
      assistantAgentCardView.onNativeEvent = onNativeEvent
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    legacyCell.isUserInteractionEnabled = false
    assistantView.isUserInteractionEnabled = false
    assistantProgressTreeView.isUserInteractionEnabled = false
    assistantActionsView.isUserInteractionEnabled = true
    assistantAgentCardView.isUserInteractionEnabled = true
    addSubview(legacyCell)
    addSubview(assistantView)
    addSubview(assistantProgressTreeView)
    addSubview(assistantActionsView)
    addSubview(assistantAgentCardView)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    let nextKind: ChatNativeAgentRowPresentationKind = {
      if row.kind == .message && row.isAgentMessage {
        switch row.messageType {
        case "agent_progress_tree":
          return .assistantProgressTree
        case "agent_actions":
          return .assistantActions
        case "agent_card":
          return .assistantAgentCard
        default:
          return .assistant
        }
      }
      return .legacy
    }()
    currentPresentationKind = nextKind
    legacyCell.isHidden = nextKind != .legacy
    assistantView.isHidden = nextKind != .assistant
    assistantProgressTreeView.isHidden = nextKind != .assistantProgressTree
    assistantActionsView.isHidden = nextKind != .assistantActions
    assistantAgentCardView.isHidden = nextKind != .assistantAgentCard

    switch nextKind {
    case .legacy:
      let cellWidth = max(1.0, availableWidth - (messageHorizontalInset * 2.0))
      let height: CGFloat
      if row.kind == .day {
        height = 30.0
      } else {
        height = measureMessageBubbleLayout(row: row, rowWidth: cellWidth).bubbleHeight
      }
      legacyCell.applyAppearance(appearance)
      legacyCell.configure(row: row, hiddenMessageId: nil)
      cachedSubviewFrame = CGRect(
        x: messageHorizontalInset,
        y: 0.0,
        width: cellWidth,
        height: height
      )
      setNeedsLayout()
      return height

    case .assistant:
      let height = assistantView.configure(
        row: row,
        appearance: appearance,
        availableWidth: availableWidth
      )
      cachedSubviewFrame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)
      setNeedsLayout()
      return height

    case .assistantActions:
      let height = assistantActionsView.configure(
        row: row,
        appearance: appearance,
        availableWidth: availableWidth
      )
      cachedSubviewFrame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)
      setNeedsLayout()
      return height

    case .assistantProgressTree:
      let height = assistantProgressTreeView.configure(
        row: row,
        appearance: appearance,
        availableWidth: availableWidth
      )
      cachedSubviewFrame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)
      setNeedsLayout()
      return height

    case .assistantAgentCard:
      let height = assistantAgentCardView.configure(
        row: row,
        appearance: appearance,
        availableWidth: availableWidth
      )
      cachedSubviewFrame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)
      setNeedsLayout()
      return height
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    switch currentPresentationKind {
    case .legacy:
      legacyCell.frame = cachedSubviewFrame
    case .assistant:
      assistantView.frame = cachedSubviewFrame
    case .assistantActions:
      assistantActionsView.frame = cachedSubviewFrame
    case .assistantAgentCard:
      assistantAgentCardView.frame = cachedSubviewFrame
    case .assistantProgressTree:
      assistantProgressTreeView.frame = cachedSubviewFrame
    case .none:
      break
    }
  }
}

final class ChatNativeAgentMessagesView: UIView {
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let stackView = UIStackView()
  private let topPaddingView = UIView()
  private let spacerView = UIView()
  private let mainRowsStack = UIStackView()
  private let progressRowsStack = UIStackView()
  private let footerRowsStack = UIStackView()
  private let bottomPaddingView = UIView()
  private var topPaddingConstraint: NSLayoutConstraint!
  private var spacerConstraint: NSLayoutConstraint!
  private var bottomPaddingConstraint: NSLayoutConstraint!

  private var currentMainRows: [ChatListRow] = []
  private var currentProgressRows: [ChatListRow] = []
  private var currentFooterRows: [ChatListRow] = []
  private var mainRowHosts: [ChatNativeAgentRowHostView] = []
  private var progressRowHosts: [ChatNativeAgentRowHostView] = []
  private var footerRowHosts: [ChatNativeAgentRowHostView] = []
  private var mainRowKeys: [String] = []
  private var mainRowKinds: [String] = []
  private var progressRowKeys: [String] = []
  private var progressRowKinds: [String] = []
  private var footerRowKeys: [String] = []
  private var footerRowKinds: [String] = []
  private var appearance = ChatListAppearance.fallback
  private var lastKnownWidth: CGFloat = 0.0
  private var keyboardHeight: CGFloat = 0.0

  private let contentHorizontalInset: CGFloat = 10.0
  private let bottomStickThreshold: CGFloat = 56.0

  var onTap: (() -> Void)?
  var onNativeEvent: (([String: Any]) -> Void)? {
    didSet {
      syncHostEventHandlers()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.keyboardDismissMode = .interactive
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceVertical = true
    if #available(iOS 11.0, *) {
      scrollView.contentInsetAdjustmentBehavior = .never
    }
    addSubview(scrollView)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    contentView.backgroundColor = .clear
    scrollView.addSubview(contentView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.alignment = .fill
    stackView.distribution = .fill
    stackView.spacing = 2.0
    contentView.addSubview(stackView)

    topPaddingView.translatesAutoresizingMaskIntoConstraints = false
    spacerView.translatesAutoresizingMaskIntoConstraints = false
    bottomPaddingView.translatesAutoresizingMaskIntoConstraints = false
    topPaddingView.backgroundColor = .clear
    spacerView.backgroundColor = .clear
    bottomPaddingView.backgroundColor = .clear
    mainRowsStack.axis = .vertical
    mainRowsStack.alignment = .fill
    mainRowsStack.distribution = .fill
    mainRowsStack.spacing = 2.0
    mainRowsStack.backgroundColor = .clear
    progressRowsStack.axis = .vertical
    progressRowsStack.alignment = .fill
    progressRowsStack.distribution = .fill
    progressRowsStack.spacing = 2.0
    progressRowsStack.backgroundColor = .clear
    footerRowsStack.axis = .vertical
    footerRowsStack.alignment = .fill
    footerRowsStack.distribution = .fill
    footerRowsStack.spacing = 2.0
    footerRowsStack.backgroundColor = .clear

    stackView.addArrangedSubview(topPaddingView)
    stackView.addArrangedSubview(spacerView)
    stackView.addArrangedSubview(mainRowsStack)
    stackView.addArrangedSubview(progressRowsStack)
    stackView.addArrangedSubview(footerRowsStack)
    stackView.addArrangedSubview(bottomPaddingView)

    topPaddingConstraint = topPaddingView.heightAnchor.constraint(equalToConstant: 0.0)
    spacerConstraint = spacerView.heightAnchor.constraint(equalToConstant: 0.0)
    bottomPaddingConstraint = bottomPaddingView.heightAnchor.constraint(equalToConstant: 0.0)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      stackView.leadingAnchor.constraint(
        equalTo: contentView.leadingAnchor, constant: contentHorizontalInset),
      stackView.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor, constant: -contentHorizontalInset),
      stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      topPaddingConstraint,
      spacerConstraint,
      bottomPaddingConstraint,
    ])

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tapGesture.cancelsTouchesInView = false
    scrollView.addGestureRecognizer(tapGesture)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillHide(_:)),
      name: UIResponder.keyboardWillHideNotification,
      object: nil
    )
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    guard abs(width - lastKnownWidth) > 0.5 else { return }
    lastKnownWidth = width
    reconfigureVisibleRows()
  }

  func applyAppearance(_ appearance: ChatListAppearance) {
    self.appearance = appearance
    reconfigureVisibleRows()
  }

  func setRows(
    _ rawRows: [[String: Any]],
    topPadding: CGFloat,
    spacerHeight: CGFloat,
    bottomPadding: CGFloat,
    scrollToBottom shouldScrollToBottom: Bool,
    animated: Bool
  ) {
    let parsedRows = rawRows.compactMap(ChatListRow.init)
    let partitioned = Self.partitionRows(parsedRows)
    let preservedOffsetY = scrollView.contentOffset.y
    let distanceBeforeUpdate = currentDistanceFromBottom()

    let assignConstraints = {
      self.topPaddingConstraint.constant = topPadding
      self.spacerConstraint.constant = spacerHeight
      self.bottomPaddingConstraint.constant = bottomPadding
    }

    if animated {
      UIView.animate(
        withDuration: 0.35, delay: 0.0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.0,
        options: [.allowUserInteraction, .beginFromCurrentState]
      ) {
        assignConstraints()
        self.layoutIfNeeded()
      }
    } else {
      assignConstraints()
    }

    let nextMainKeys = partitioned.main.map(\.key)
    let nextMainKinds = partitioned.main.map(Self.presentationSignature(for:))
    if nextMainKeys != mainRowKeys || nextMainKinds != mainRowKinds {
      rebuildRows(partitioned.main, in: mainRowsStack, hosts: &mainRowHosts)
      mainRowKeys = nextMainKeys
      mainRowKinds = nextMainKinds
    } else {
      currentMainRows = partitioned.main
      reconfigureRows(currentMainRows, hosts: mainRowHosts)
    }

    let nextProgressKeys = partitioned.progress.map(\.key)
    let nextProgressKinds = partitioned.progress.map(Self.presentationSignature(for:))
    if nextProgressKeys != progressRowKeys || nextProgressKinds != progressRowKinds {
      rebuildRows(partitioned.progress, in: progressRowsStack, hosts: &progressRowHosts)
      progressRowKeys = nextProgressKeys
      progressRowKinds = nextProgressKinds
    } else {
      currentProgressRows = partitioned.progress
      reconfigureRows(currentProgressRows, hosts: progressRowHosts)
    }

    let nextFooterKeys = partitioned.footer.map(\.key)
    let nextFooterKinds = partitioned.footer.map(Self.presentationSignature(for:))
    if nextFooterKeys != footerRowKeys || nextFooterKinds != footerRowKinds {
      rebuildRows(partitioned.footer, in: footerRowsStack, hosts: &footerRowHosts)
      footerRowKeys = nextFooterKeys
      footerRowKinds = nextFooterKinds
    } else {
      currentFooterRows = partitioned.footer
      reconfigureRows(currentFooterRows, hosts: footerRowHosts)
    }

    layoutIfNeeded()

    if shouldScrollToBottom || distanceBeforeUpdate <= bottomStickThreshold {
      self.scrollToBottom(animated: animated)
      return
    }

    let minOffset = -scrollView.adjustedContentInset.top
    let maxOffset = max(
      minOffset,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    let clampedOffset = max(minOffset, min(maxOffset, preservedOffsetY))
    scrollView.setContentOffset(CGPoint(x: 0.0, y: clampedOffset), animated: false)
  }

  func scrollToBottom(animated: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.layoutIfNeeded()
      let minOffset = -self.scrollView.adjustedContentInset.top
      let targetY = max(
        minOffset,
        self.scrollView.contentSize.height - self.scrollView.bounds.height
          + self.scrollView.adjustedContentInset.bottom
      )
      self.scrollView.setContentOffset(CGPoint(x: 0.0, y: targetY), animated: animated)
    }
  }

  private func rebuildRows(
    _ rows: [ChatListRow],
    in hostStack: UIStackView,
    hosts: inout [ChatNativeAgentRowHostView]
  ) {
    for host in hosts {
      hostStack.removeArrangedSubview(host)
      host.removeFromSuperview()
    }
    hosts.removeAll()

    for (offset, _) in rows.enumerated() {
      let host = ChatNativeAgentRowHostView()
      host.onNativeEvent = onNativeEvent
      hosts.append(host)
      hostStack.insertArrangedSubview(host, at: offset)
    }
    if hostStack === mainRowsStack {
      currentMainRows = rows
      reconfigureRows(currentMainRows, hosts: hosts)
    } else if hostStack === progressRowsStack {
      currentProgressRows = rows
      reconfigureRows(currentProgressRows, hosts: hosts)
    } else {
      currentFooterRows = rows
      reconfigureRows(currentFooterRows, hosts: hosts)
    }
  }

  private func reconfigureVisibleRows() {
    syncHostEventHandlers()
    reconfigureRows(currentMainRows, hosts: mainRowHosts)
    reconfigureRows(currentProgressRows, hosts: progressRowHosts)
    reconfigureRows(currentFooterRows, hosts: footerRowHosts)
  }

  private func reconfigureRows(_ rows: [ChatListRow], hosts: [ChatNativeAgentRowHostView]) {
    guard hosts.count == rows.count else { return }
    let width = max(1.0, bounds.width - (contentHorizontalInset * 2.0))
    for (index, row) in rows.enumerated() {
      let host = hosts[index]
      host.onNativeEvent = onNativeEvent
      let height = host.configure(row: row, appearance: appearance, availableWidth: width)
      if let heightConstraint = host.constraints.first(where: {
        $0.firstAttribute == .height && $0.relation == .equal
      }) {
        heightConstraint.constant = height
      } else {
        host.heightAnchor.constraint(equalToConstant: height).isActive = true
      }
    }
  }

  private static func presentationSignature(for row: ChatListRow) -> String {
    if row.kind == .message && row.isAgentMessage {
      switch row.messageType {
      case "agent_progress_tree":
        return ChatNativeAgentRowPresentationKind.assistantProgressTree.rawValue
      case "agent_actions":
        return ChatNativeAgentRowPresentationKind.assistantActions.rawValue
      case "agent_card":
        return ChatNativeAgentRowPresentationKind.assistantAgentCard.rawValue
      default:
        return ChatNativeAgentRowPresentationKind.assistant.rawValue
      }
    }
    return ChatNativeAgentRowPresentationKind.legacy.rawValue
  }

  private static func partitionRows(_ rows: [ChatListRow]) -> (
    main: [ChatListRow], progress: [ChatListRow], footer: [ChatListRow]
  ) {
    // Progress rows are now inline with the response stream — no separate partition
    return (rows, [], [])
  }

  @objc private func handleTap() {
    onTap?()
  }

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    applyKeyboardFrame(notification, hidden: false)
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    applyKeyboardFrame(notification, hidden: true)
  }

  private func applyKeyboardFrame(_ notification: Notification, hidden: Bool) {
    guard let info = notification.userInfo else { return }
    let duration =
      (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let curveRaw =
      (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
    let distanceBeforeInsetChange = currentDistanceFromBottom()
    let nextKeyboardHeight: CGFloat

    if hidden {
      nextKeyboardHeight = 0.0
    } else if let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
      let endFrameInView = convert(endFrame, from: nil)
      let intersection = bounds.intersection(endFrameInView)
      nextKeyboardHeight = max(0.0, intersection.height)
    } else {
      nextKeyboardHeight = 0.0
    }

    keyboardHeight = nextKeyboardHeight

    UIView.animate(withDuration: duration, delay: 0.0, options: options) { [weak self] in
      guard let self else { return }
      self.applyKeyboardInsets()
      self.layoutIfNeeded()
      if distanceBeforeInsetChange <= self.bottomStickThreshold {
        self.scrollToBottom(animated: false)
      } else {
        self.restoreStationaryDistance(distanceBeforeInsetChange)
      }
    }
  }

  private func applyKeyboardInsets() {
    scrollView.contentInset.bottom = keyboardHeight
    scrollView.verticalScrollIndicatorInsets.bottom = keyboardHeight
  }

  private func currentDistanceFromBottom() -> CGFloat {
    let minOffset = -scrollView.adjustedContentInset.top
    let targetY = max(
      minOffset,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    return max(0.0, targetY - scrollView.contentOffset.y)
  }

  private func restoreStationaryDistance(_ distanceFromBottom: CGFloat) {
    let minOffset = -scrollView.adjustedContentInset.top
    let maxOffset = max(
      minOffset,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    let targetY = max(minOffset, min(maxOffset, maxOffset - distanceFromBottom))
    scrollView.setContentOffset(CGPoint(x: 0.0, y: targetY), animated: false)
  }

  private func syncHostEventHandlers() {
    let groups = [mainRowHosts, progressRowHosts, footerRowHosts]
    for hosts in groups {
      for host in hosts {
        host.onNativeEvent = onNativeEvent
      }
    }
  }
}
