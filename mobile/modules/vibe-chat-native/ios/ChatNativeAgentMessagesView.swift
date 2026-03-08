import UIKit

private enum ChatNativeAgentRowPresentationKind: String {
  case legacy
  case assistant
}

private final class ChatNativeAgentPlainTextView: UIView {
  private let label = ChatNativeStreamingTextLabel()
  private var cachedFrame: CGRect = .zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    label.numberOfLines = 0
    label.backgroundColor = .clear
    addSubview(label)
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
      ? UIFont.systemFont(ofSize: 14, weight: .medium)
      : UIFont.systemFont(ofSize: 18, weight: .regular)
    let lineHeight: CGFloat = isProgress ? 20.0 : 26.0
    let textColor =
      isProgress
      ? appearance.timeColorThem.withAlphaComponent(0.92)
      : appearance.textColorThem
    let topPadding: CGFloat = isProgress ? 8.0 : 4.0
    let bottomPadding: CGFloat = isProgress ? 6.0 : 16.0
    let leftPadding: CGFloat = 8.0
    let rightPadding: CGFloat = 32.0
    let labelWidth = max(1.0, availableWidth - leftPadding - rightPadding)
    let attributed = ChatNativeAgentTextRenderer.makeAttributedText(
      text: text,
      font: font,
      textColor: textColor,
      lineHeight: lineHeight
    )
    let textHeight = max(
      ceil(font.lineHeight),
      ChatNativeAgentTextRenderer.measuredHeight(for: attributed, width: labelWidth)
    )

    label.textColor = textColor
    label.applyStreamingText(attributed, isStreaming: row.isStreamingText && !isProgress)
    cachedFrame = CGRect(
      x: leftPadding,
      y: topPadding,
      width: labelWidth,
      height: textHeight
    )
    setNeedsLayout()
    return topPadding + textHeight + bottomPadding
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = cachedFrame
  }
}

private final class ChatNativeAgentRowHostView: UIView {
  private let legacyCell = ChatListCell(frame: .zero)
  private let assistantView = ChatNativeAgentPlainTextView()
  private var currentPresentationKind: ChatNativeAgentRowPresentationKind?
  private var cachedSubviewFrame: CGRect = .zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    legacyCell.isUserInteractionEnabled = false
    assistantView.isUserInteractionEnabled = false
    addSubview(legacyCell)
    addSubview(assistantView)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    let nextKind: ChatNativeAgentRowPresentationKind =
      (row.kind == .message && row.isAgentMessage) ? .assistant : .legacy
    currentPresentationKind = nextKind
    legacyCell.isHidden = nextKind != .legacy
    assistantView.isHidden = nextKind != .assistant

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
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    switch currentPresentationKind {
    case .legacy:
      legacyCell.frame = cachedSubviewFrame
    case .assistant:
      assistantView.frame = cachedSubviewFrame
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
  private let footerRowsStack = UIStackView()
  private let bottomPaddingView = UIView()
  private var topPaddingConstraint: NSLayoutConstraint!
  private var spacerConstraint: NSLayoutConstraint!
  private var bottomPaddingConstraint: NSLayoutConstraint!

  private var currentMainRows: [ChatListRow] = []
  private var currentFooterRows: [ChatListRow] = []
  private var mainRowHosts: [ChatNativeAgentRowHostView] = []
  private var footerRowHosts: [ChatNativeAgentRowHostView] = []
  private var mainRowKeys: [String] = []
  private var mainRowKinds: [String] = []
  private var footerRowKeys: [String] = []
  private var footerRowKinds: [String] = []
  private var appearance = ChatListAppearance.fallback
  private var lastKnownWidth: CGFloat = 0.0
  private var keyboardHeight: CGFloat = 0.0

  private let contentHorizontalInset: CGFloat = 10.0
  private let bottomStickThreshold: CGFloat = 56.0

  var onTap: (() -> Void)?

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
    footerRowsStack.axis = .vertical
    footerRowsStack.alignment = .fill
    footerRowsStack.distribution = .fill
    footerRowsStack.spacing = 2.0
    footerRowsStack.backgroundColor = .clear

    stackView.addArrangedSubview(topPaddingView)
    stackView.addArrangedSubview(spacerView)
    stackView.addArrangedSubview(mainRowsStack)
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

    if shouldScrollToBottom {
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
    layoutIfNeeded()
    let minOffset = -scrollView.adjustedContentInset.top
    let targetY = max(
      minOffset,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    scrollView.setContentOffset(CGPoint(x: 0.0, y: targetY), animated: animated)
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
      hosts.append(host)
      hostStack.insertArrangedSubview(host, at: offset)
    }
    if hostStack === mainRowsStack {
      currentMainRows = rows
      reconfigureRows(currentMainRows, hosts: hosts)
    } else {
      currentFooterRows = rows
      reconfigureRows(currentFooterRows, hosts: hosts)
    }
  }

  private func reconfigureVisibleRows() {
    reconfigureRows(currentMainRows, hosts: mainRowHosts)
    reconfigureRows(currentFooterRows, hosts: footerRowHosts)
  }

  private func reconfigureRows(_ rows: [ChatListRow], hosts: [ChatNativeAgentRowHostView]) {
    guard hosts.count == rows.count else { return }
    let width = max(1.0, bounds.width - (contentHorizontalInset * 2.0))
    for (index, row) in rows.enumerated() {
      let host = hosts[index]
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
      return ChatNativeAgentRowPresentationKind.assistant.rawValue
    }
    return ChatNativeAgentRowPresentationKind.legacy.rawValue
  }

  private static func partitionRows(_ rows: [ChatListRow]) -> (
    main: [ChatListRow], footer: [ChatListRow]
  ) {
    guard let lastUserIndex = rows.lastIndex(where: { $0.kind == .message && $0.isMe }) else {
      return (rows, [])
    }
    let mainRows = Array(rows.prefix(through: lastUserIndex))
    let footerRows =
      lastUserIndex + 1 < rows.count
      ? Array(rows.suffix(from: lastUserIndex + 1))
      : []
    return (mainRows, footerRows)
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
}
