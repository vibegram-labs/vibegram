import ExpoModulesCore
import Foundation
import Security
import UIKit

final class ChatNativeAgentRegistry {
  static let shared = ChatNativeAgentRegistry()

  private final class WeakRef {
    weak var value: ChatNativeAgentView?

    init(_ value: ChatNativeAgentView) {
      self.value = value
    }
  }

  private var map: [String: WeakRef] = [:]

  func register(surfaceId: String, view: ChatNativeAgentView) {
    map[surfaceId] = WeakRef(view)
  }

  func view(for surfaceId: String) -> ChatNativeAgentView? {
    if let value = map[surfaceId]?.value {
      return value
    }
    map.removeValue(forKey: surfaceId)
    return nil
  }

  func unregister(surfaceId: String) {
    map.removeValue(forKey: surfaceId)
  }
}

private enum ChatNativeAgentPage: Int {
  case chat = 0
  case history = 1
}

private enum ChatNativeAgentRole: String, Codable {
  case user
  case assistant
}

private enum ChatNativeAgentStreamSegment: Codable, Equatable {
  case text(String)
  case progress(id: String, label: String, tool: String?, status: String)
  case cards(groupId: String, cards: [ChatListRow.AgentCard])

  var isRunningProgress: Bool {
    if case .progress(_, _, _, let status) = self { return status == "running" }
    return false
  }

  var progressTool: String? {
    if case .progress(_, _, let tool, _) = self { return tool }
    return nil
  }

  var progressId: String? {
    if case .progress(let id, _, _, _) = self { return id }
    return nil
  }

  var cardGroupId: String? {
    if case .cards(let groupId, _) = self { return groupId }
    return nil
  }
}

private struct ChatNativeAgentMessage: Codable, Equatable {
  let id: String
  let role: ChatNativeAgentRole
  var content: String
  var timestampMs: Int64
  var isStreaming: Bool
  var streamSegments: [ChatNativeAgentStreamSegment]

  init(
    id: String,
    role: ChatNativeAgentRole,
    content: String,
    timestampMs: Int64,
    isStreaming: Bool,
    streamSegments: [ChatNativeAgentStreamSegment] = []
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestampMs = timestampMs
    self.isStreaming = isStreaming
    self.streamSegments = streamSegments
  }
}

private struct ChatNativeAgentConversation: Codable, Equatable {
  var id: String
  var title: String
  var createdAt: Int64
  var updatedAt: Int64
  var messages: [ChatNativeAgentMessage]
}

private struct ChatNativeAgentPersistedState: Codable {
  let activeConversationId: String?
  let conversations: [ChatNativeAgentConversation]
}

private enum ChatNativeAgentPendingSend {
  case message(conversationId: String, text: String, truncateAtId: String?)
  case builderUiResponse(conversationId: String, uiResponse: [String: Any], summary: String?)

  var conversationId: String {
    switch self {
    case .message(let conversationId, _, _):
      return conversationId
    case .builderUiResponse(let conversationId, _, _):
      return conversationId
    }
  }

  func withConversationId(_ updatedConversationId: String) -> ChatNativeAgentPendingSend {
    switch self {
    case .message(_, let text, let truncateAtId):
      return .message(
        conversationId: updatedConversationId,
        text: text,
        truncateAtId: truncateAtId
      )
    case .builderUiResponse(_, let uiResponse, let summary):
      return .builderUiResponse(
        conversationId: updatedConversationId,
        uiResponse: uiResponse,
        summary: summary
      )
    }
  }
}

private struct ChatNativeAgentRenderEntry {
  let id: String
  let messageId: String
  let role: ChatNativeAgentRole
  let text: String
  let timestampMs: Int64
  let messageType: String
  let isStreaming: Bool
  let isAgentMessage: Bool
  let showTail: Bool
  let progressNodes: [[String: Any]]?
  let agentCard: ChatListRow.AgentCard?
  let actionSourceMessageId: String?
  let actionSourceText: String?
}

private final class ChatNativeAgentHistoryCell: UITableViewCell {
  static let reuseIdentifier = "ChatNativeAgentHistoryCell"

  private let titleLabel = UILabel()
  private let previewLabel = UILabel()
  private let dateLabel = UILabel()
  private let separatorView = UIView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)

    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.numberOfLines = 1

    previewLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    previewLabel.numberOfLines = 1

    dateLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    dateLabel.textAlignment = .right

    separatorView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

    [titleLabel, previewLabel, dateLabel, separatorView].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview($0)
    }

    NSLayoutConstraint.activate([
      dateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      dateLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
      dateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),

      titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -12),
      titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),

      previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      previewLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      previewLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
      previewLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

      separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      separatorView.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
    ])
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    conversation: ChatNativeAgentConversation,
    activeConversationId: String?,
    appearance: ChatListAppearance
  ) {
    let isActive = conversation.id == activeConversationId
    let previewText = conversation.messages.last?.content.trimmingCharacters(
      in: .whitespacesAndNewlines)
    titleLabel.text = conversation.title.isEmpty ? "New Chat" : conversation.title
    previewLabel.text =
      (previewText?.isEmpty == false ? previewText : "No messages") ?? "No messages"
    dateLabel.text = Self.formatDateLabel(conversation.createdAt)

    titleLabel.textColor = appearance.textColorThem.withAlphaComponent(isActive ? 1.0 : 0.72)
    previewLabel.textColor = appearance.timeColorThem.withAlphaComponent(isActive ? 0.9 : 0.72)
    dateLabel.textColor = appearance.timeColorThem.withAlphaComponent(isActive ? 0.9 : 0.64)
    contentView.alpha = isActive ? 1.0 : 0.86
    separatorView.backgroundColor = appearance.dayBorderColor.withAlphaComponent(0.36)
  }

  private static func formatDateLabel(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return "Today"
    }
    if calendar.isDateInYesterday(date) {
      return "Yesterday"
    }
    let now = Date()
    let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
    if days > 1 && days < 7 {
      return "\(days)d ago"
    }
    return Self.dateFormatter.string(from: date)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
  }()
}

public final class ChatNativeAgentView: ExpoView, UITableViewDataSource, UITableViewDelegate,
  UIScrollViewDelegate
{
  public var onNativeEvent = EventDispatcher()

  @objc public var surfaceId: String = "" {
    didSet {
      let trimmed = surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !registeredSurfaceId.isEmpty, registeredSurfaceId != trimmed {
        ChatNativeAgentRegistry.shared.unregister(surfaceId: registeredSurfaceId)
      }
      registeredSurfaceId = trimmed
      if !trimmed.isEmpty {
        ChatNativeAgentRegistry.shared.register(surfaceId: trimmed, view: self)
      }
    }
  }

  private let headerContainer = UIView()
  private let headerMaskView = UIView()
  private let headerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerMaskOverlayView = UIView()
  private let headerMaskGradientLayer = CAGradientLayer()
  private let headerContentView = UIView()

  private let footerMaskView = UIView()
  private let footerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let footerMaskOverlayView = UIView()
  private let footerMaskGradientLayer = CAGradientLayer()
  private let backGlassView = UIVisualEffectView(effect: nil)
  private let titleGlassView = UIVisualEffectView(effect: nil)
  private let actionGlassView = UIVisualEffectView(effect: nil)
  private let backButton = UIButton(type: .system)
  private let titleButton = UIButton(type: .custom)
  private let titleLabel = UILabel()
  private let actionButton = UIButton(type: .system)

  private let pageScrollView = UIScrollView()
  private let chatPage = UIView()
  private let historyPage = UIView()
  private let messagesView = ChatNativeAgentMessagesView()
  private let historyTableView = UITableView(frame: .zero, style: .plain)
  private let historyEmptyLabel = UILabel()

  private var appearance = ChatListAppearance.fallback
  private var currentPage: ChatNativeAgentPage = .chat
  private var conversations: [ChatNativeAgentConversation] = []
  private var activeConversationId: String?
  private var streamingConversationId: String?

  private var currentSpacerHeight: CGFloat = 0

  private var topic: String = ""
  private var joinedTopic = false
  private var transportEnabled = false
  private var phoenixClient: ChatPhoenixClient?
  private var pendingReplies: [String: (String, [String: Any]) -> Void] = [:]
  private var reconnectWorkItem: DispatchWorkItem?
  private var streamingTimeoutWorkItem: DispatchWorkItem?
  private var pendingSends: [ChatNativeAgentPendingSend] = []
  private var lastReportedStreamingState = false
  private var isStoppingStreamManually = false
  private var builderQuestionNavigationController: UINavigationController?
  private var queuedBuilderQuestionRequest: ChatBuilderUiRequest?
  private var builderSetupState: ChatBuilderSetupState?
  private var builderActivity: [ChatBuilderActivityItem] = []
  private var builderActiveAgentId: String?
  private var builderLatestSecret: String?
  private var registeredSurfaceId: String = ""

  private static let fallbackApiBaseURL = "https://api.vibegram.io"
  private static let persistenceKey = "vibe.native.agent.screen.v1"

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)

    backgroundColor = .clear
    clipsToBounds = true

    setupHeader()
    setupPages()
    applyPersistedState()
    applyAppearance([:])
    refreshHeader(animated: false)
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  deinit {
    transportEnabled = false
    reconnectWorkItem?.cancel()
    streamingTimeoutWorkItem?.cancel()
    phoenixClient?.disconnect()
    if !registeredSurfaceId.isEmpty {
      ChatNativeAgentRegistry.shared.unregister(surfaceId: registeredSurfaceId)
    }
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      transportEnabled = true
      connectIfNeeded()
      if let activeConversationId, conversation(for: activeConversationId)?.messages.isEmpty == true
      {
        loadConversation(id: activeConversationId)
      }
      return
    }
    transportEnabled = false
    reconnectWorkItem?.cancel()
    phoenixClient?.disconnect()
    phoenixClient = nil
    joinedTopic = false
  }

  public override func layoutSubviews() {
    super.layoutSubviews()

    let safeTop = safeAreaInsets.top
    let bounds = self.bounds
    let headerHeight = safeTop + 72.0

    headerContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerHeight)
    headerMaskView.frame = headerContainer.bounds
    headerMaskBlurView.frame = headerMaskView.bounds
    headerMaskOverlayView.frame = headerMaskBlurView.bounds
    headerMaskGradientLayer.frame = headerMaskView.bounds
    bringSubviewToFront(headerContainer)
    headerContainer.bringSubviewToFront(headerContentView)

    let contentY = safeTop + 8.0
    headerContentView.frame = CGRect(
      x: 12.0,
      y: contentY,
      width: max(0.0, bounds.width - 24.0),
      height: 44.0
    )

    backGlassView.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    actionGlassView.frame = CGRect(
      x: max(0.0, headerContentView.bounds.width - 44.0),
      y: 0.0,
      width: 44.0,
      height: 44.0
    )
    let maxCenterWidth = max(0.0, headerContentView.bounds.width * 0.65)
    let requiredTitleWidth = max(160.0, titleLabel.intrinsicContentSize.width + 36.0)
    let centerWidth = min(maxCenterWidth, requiredTitleWidth)
    titleGlassView.frame = CGRect(
      x: (headerContentView.bounds.width - centerWidth) * 0.5,
      y: 0.0,
      width: centerWidth,
      height: 44.0
    )

    backButton.frame = backGlassView.bounds
    titleButton.frame = titleGlassView.bounds
    actionButton.frame = actionGlassView.bounds
    [backButton, titleButton, actionButton].forEach { control in
      control.layer.cornerRadius = control.bounds.height * 0.5
    }
    [backGlassView, titleGlassView, actionGlassView].forEach { glassView in
      glassView.layer.cornerRadius = glassView.bounds.height * 0.5
    }
    titleLabel.frame = titleButton.bounds.insetBy(dx: 12.0, dy: 4.0)

    pageScrollView.frame = bounds
    pageScrollView.contentSize = CGSize(width: bounds.width * 2.0, height: bounds.height)
    chatPage.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: bounds.height)
    historyPage.frame = CGRect(
      x: bounds.width,
      y: 0,
      width: bounds.width,
      height: bounds.height
    )

    messagesView.frame = chatPage.bounds
    let activeRows: [[String: Any]]
    if let activeConversationId, let conversation = conversation(for: activeConversationId) {
      activeRows = makeRawRows(for: conversation)
    } else {
      activeRows = []
    }
    messagesView.setRows(
      activeRows,
      topPadding: safeTop + 80.0,
      spacerHeight: currentSpacerHeight,
      bottomPadding: 140.0,
      scrollToBottom: false,
      animated: false
    )

    // Footer fade mask at bottom of chat page
    let footerMaskHeight: CGFloat = 100.0
    footerMaskView.frame = CGRect(
      x: 0.0,
      y: bounds.height - footerMaskHeight,
      width: bounds.width,
      height: footerMaskHeight
    )
    footerMaskBlurView.frame = footerMaskView.bounds
    footerMaskOverlayView.frame = footerMaskBlurView.bounds
    footerMaskGradientLayer.frame = footerMaskView.bounds

    historyTableView.frame = historyPage.bounds
    historyTableView.contentInset = UIEdgeInsets(
      top: safeTop + 80.0,
      left: 0.0,
      bottom: 100.0,
      right: 0.0
    )
    historyTableView.scrollIndicatorInsets = historyTableView.contentInset
    historyEmptyLabel.frame = CGRect(
      x: 28.0,
      y: safeTop + 132.0,
      width: max(0.0, historyPage.bounds.width - 56.0),
      height: 120.0
    )

    let targetOffset = CGPoint(x: CGFloat(currentPage.rawValue) * bounds.width, y: 0)
    if abs(pageScrollView.contentOffset.x - targetOffset.x) > 0.5 {
      pageScrollView.setContentOffset(targetOffset, animated: false)
    }
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    applyAppearance(rawAppearance)
  }

  func setBuilderActiveAgentId(_ activeAgentId: String?) {
    builderActiveAgentId = Self.normalizedString(activeAgentId)
  }

  func setBuilderLatestSecret(_ latestSecret: String?) {
    builderLatestSecret = Self.normalizedString(latestSecret)
  }

  func submitText(_ rawText: String) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    connectIfNeeded()
    guard let conversationId = beginStreamingTurn(
      userText: text,
      fallbackTitle: String(text.prefix(20))
    ) else { return }

    if joinedTopic {
      pushMessage(text: text, conversationId: conversationId, truncateAtId: nil)
    } else {
      pendingSends.append(
        .message(
          conversationId: conversationId,
          text: text,
          truncateAtId: nil
        ))
    }
  }

  private func beginStreamingTurn(userText: String, fallbackTitle: String) -> String? {
    let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return nil }

    var conversationId = activeConversationId
    if conversationId == nil {
      conversationId = createConversation(title: fallbackTitle)
    }
    guard let conversationId else { return nil }

    let timestampMs = Self.nowMs()
    let userMessage = ChatNativeAgentMessage(
      id: UUID().uuidString,
      role: .user,
      content: trimmedText,
      timestampMs: timestampMs,
      isStreaming: false,
      streamSegments: []
    )
    let assistantMessage = ChatNativeAgentMessage(
      id: UUID().uuidString,
      role: .assistant,
      content: "",
      timestampMs: timestampMs,
      isStreaming: true,
      streamSegments: []
    )

    updateConversation(conversationId) { conversation in
      conversation.messages.append(userMessage)
      conversation.messages.append(assistantMessage)
      conversation.updatedAt = timestampMs
      if conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        conversation.title = fallbackTitle
      }
    }

    streamingConversationId = conversationId
    notifyStreamingStateChanged()
    currentSpacerHeight = 0.0
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: true, animated: true)
    scheduleStreamingTimeout()

    return conversationId
  }

  private func submitBuilderUiResponse(
    requestId: String,
    answers: [String: Any],
    summary: String?
  ) {
    let trimmedRequestId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRequestId.isEmpty else { return }

    let normalizedSummary: String
    if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      normalizedSummary = "Updated the setup"
    }

    connectIfNeeded()
    guard
      let conversationId = beginStreamingTurn(
        userText: normalizedSummary,
        fallbackTitle: "Agent setup"
      )
    else { return }

    let uiResponse: [String: Any] = [
      "requestId": trimmedRequestId,
      "answers": answers,
    ]

    if joinedTopic {
      pushBuilderUiResponse(
        conversationId: conversationId,
        uiResponse: uiResponse,
        summary: normalizedSummary
      )
    } else {
      pendingSends.append(
        .builderUiResponse(
          conversationId: conversationId,
          uiResponse: uiResponse,
          summary: normalizedSummary
        ))
    }
  }

  private func pushBuilderUiResponse(
    conversationId: String,
    uiResponse: [String: Any],
    summary: String?
  ) {
    var payload: [String: Any] = [
      "conversation_id": conversationId,
      "ui_response": uiResponse,
    ]
    if let summary, !summary.isEmpty {
      payload["summary"] = summary
    }
    sendChannelEvent(event: "builder_ui_response", payload: payload) { _, _ in }
  }

  private func setupHeader() {
    addSubview(headerContainer)
    headerContainer.clipsToBounds = false
    headerContainer.layer.zPosition = 50.0
    headerContainer.isUserInteractionEnabled = true

    headerMaskView.isUserInteractionEnabled = false
    headerContainer.addSubview(headerMaskView)
    headerMaskView.addSubview(headerMaskBlurView)
    headerMaskBlurView.contentView.addSubview(headerMaskOverlayView)
    headerMaskGradientLayer.colors = [
      UIColor.black.cgColor,
      UIColor.black.withAlphaComponent(0.85).cgColor,
      UIColor.black.withAlphaComponent(0.45).cgColor,
      UIColor.clear.cgColor,
    ]
    headerMaskGradientLayer.locations = [0.0, 0.42, 0.72, 1.0]
    headerMaskView.layer.mask = headerMaskGradientLayer

    headerContainer.addSubview(headerContentView)
    headerContentView.layer.zPosition = 1.0
    headerContentView.isUserInteractionEnabled = true
    headerContentView.addSubview(backGlassView)
    headerContentView.addSubview(titleGlassView)
    headerContentView.addSubview(actionGlassView)
    backGlassView.contentView.addSubview(backButton)
    titleGlassView.contentView.addSubview(titleButton)
    actionGlassView.contentView.addSubview(actionButton)
    titleButton.addSubview(titleLabel)

    [backGlassView, titleGlassView, actionGlassView].forEach { glassView in
      glassView.clipsToBounds = true
      glassView.layer.cornerCurve = .continuous
      glassView.contentView.backgroundColor = .clear
      glassView.isUserInteractionEnabled = true
    }

    [backButton, titleButton, actionButton].forEach {
      $0.tintColor = .white
      $0.backgroundColor = .clear
      $0.contentHorizontalAlignment = .center
      $0.contentVerticalAlignment = .center
      $0.clipsToBounds = true
    }
    backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    backButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)
    actionButton.addTarget(self, action: #selector(handleActionPressed), for: .touchUpInside)

    titleButton.isUserInteractionEnabled = false
    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail

    let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    backButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
    actionButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
  }

  private func setupPages() {
    pageScrollView.isPagingEnabled = true
    pageScrollView.showsHorizontalScrollIndicator = false
    pageScrollView.alwaysBounceHorizontal = true
    pageScrollView.bounces = false
    pageScrollView.keyboardDismissMode = .interactive
    pageScrollView.delegate = self
    if #available(iOS 11.0, *) {
      pageScrollView.contentInsetAdjustmentBehavior = .never
    }
    if headerContainer.superview === self {
      insertSubview(pageScrollView, belowSubview: headerContainer)
    } else {
      addSubview(pageScrollView)
    }

    pageScrollView.addSubview(chatPage)
    pageScrollView.addSubview(historyPage)

    chatPage.clipsToBounds = true
    historyPage.clipsToBounds = true

    chatPage.addSubview(messagesView)
    messagesView.onTap = { [weak self] in
      self?.window?.endEditing(true)
    }
    messagesView.onNativeEvent = { [weak self] event in
      self?.handleMessagesEvent(event)
    }

    let historyTap = UITapGestureRecognizer(target: self, action: #selector(handlePageTap))
    historyTap.cancelsTouchesInView = false
    historyPage.addGestureRecognizer(historyTap)

    historyTableView.backgroundColor = .clear
    historyTableView.separatorStyle = .none
    historyTableView.dataSource = self
    historyTableView.delegate = self
    historyTableView.keyboardDismissMode = .interactive
    historyTableView.register(
      ChatNativeAgentHistoryCell.self,
      forCellReuseIdentifier: ChatNativeAgentHistoryCell.reuseIdentifier
    )
    if #available(iOS 11.0, *) {
      historyTableView.contentInsetAdjustmentBehavior = .never
    }
    historyPage.addSubview(historyTableView)

    historyEmptyLabel.text = "No conversations yet.\nStart chatting with Vibe AI."
    historyEmptyLabel.numberOfLines = 0
    historyEmptyLabel.textAlignment = .center
    historyPage.addSubview(historyEmptyLabel)

    // Footer fade mask
    footerMaskView.isUserInteractionEnabled = false
    footerMaskView.clipsToBounds = true
    chatPage.addSubview(footerMaskView)
    footerMaskView.addSubview(footerMaskBlurView)
    footerMaskBlurView.contentView.addSubview(footerMaskOverlayView)
    footerMaskGradientLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.55).cgColor,
      UIColor.black.cgColor,
    ]
    footerMaskGradientLayer.locations = [0.0, 0.38, 1.0]
    footerMaskView.layer.mask = footerMaskGradientLayer

    bringSubviewToFront(headerContainer)
  }

  private func applyAppearance(_ rawAppearance: [String: Any]) {
    appearance = ChatListAppearance.from(raw: rawAppearance)
    messagesView.applyAppearance(appearance)

    let headerTint = appearance.textColorThem
    let baseBackground = appearance.wallpaperGradient.first ?? UIColor.black
    let isDarkTheme = appearance.isDark

    backgroundColor = baseBackground
    titleLabel.textColor = headerTint
    backButton.tintColor = appearance.textColorThem
    actionButton.tintColor = appearance.textColorThem
    historyEmptyLabel.textColor = appearance.timeColorThem
    chatPage.backgroundColor = baseBackground
    historyPage.backgroundColor = baseBackground
    historyTableView.backgroundColor = .clear

    var white: CGFloat = 0.0
    if appearance.textColorThem.getWhite(&white, alpha: nil) {
      headerMaskBlurView.effect = UIBlurEffect(style: white > 0.5 ? .dark : .light)
    } else {
      headerMaskBlurView.effect = UIBlurEffect(style: .regular)
    }
    headerMaskOverlayView.backgroundColor = baseBackground.withAlphaComponent(0.72)
    backGlassView.contentView.backgroundColor = baseBackground.withAlphaComponent(0.10)
    titleGlassView.contentView.backgroundColor = baseBackground.withAlphaComponent(0.10)
    actionGlassView.contentView.backgroundColor = baseBackground.withAlphaComponent(0.10)
    refreshHeaderGlass(isDarkTheme: isDarkTheme)

    // Footer mask theme
    var footerWhite: CGFloat = 0.0
    if appearance.textColorThem.getWhite(&footerWhite, alpha: nil) {
      footerMaskBlurView.effect = UIBlurEffect(style: footerWhite > 0.5 ? .dark : .light)
    } else {
      footerMaskBlurView.effect = UIBlurEffect(style: .regular)
    }
    footerMaskOverlayView.backgroundColor = baseBackground.withAlphaComponent(0.72)

    refreshHeader(animated: false)
    refreshHistoryList()
    setNeedsLayout()
  }

  private func currentBuilderPanelTheme() -> ChatBuilderPanelTheme {
    let isDarkTheme = appearance.isDark
    return ChatBuilderPanelTheme(
      isDark: isDarkTheme,
      backgroundColor: builderThemeColor(isDarkTheme ? "#121212" : "#F5F4F1"),
      cardColor: builderThemeColor(isDarkTheme ? "#242424" : "#FFFFFF"),
      inputColor: builderThemeColor(isDarkTheme ? "#222222" : "#F2F2F2"),
      textColor: builderThemeColor(isDarkTheme ? "#E8E6F0" : "#1A1A1F"),
      secondaryTextColor: builderThemeColor(isDarkTheme ? "#9896A8" : "#5A5A66"),
      accentColor: builderThemeColor(isDarkTheme ? "#7CB8B8" : "#4A8D8E")
    )
  }

  private func builderThemeColor(_ hex: String) -> UIColor {
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

  @objc private func handleBackPressed() {
    if currentPage == .history {
      setPage(.chat, animated: true)
      return
    }
    onNativeEvent(["type": "headerBack"])
  }

  @objc private func handleActionPressed() {
    if currentPage == .history {
      _ = createConversation(title: "New Chat")
      setPage(.chat, animated: true)
      return
    }

    setPage(.history, animated: true)
  }

  @objc private func handlePageTap() {
    window?.endEditing(true)
  }

  private func handleMessagesEvent(_ event: [String: Any]) {
    let type = Self.normalizedString(event["type"]) ?? ""

    if type == "agentCardPressed",
      let rawCard = event["card"] as? [String: Any],
      let card = ChatListRow.AgentCard.parse(rawCard)
    {
      presentAgentCardPanel(card)
      return
    }

    guard type == "agentMessageAction" else {
      onNativeEvent(event)
      return
    }

    let action = Self.normalizedString(event["action"]) ?? ""
    let sourceMessageId = Self.normalizedString(event["sourceMessageId"]) ?? ""
    let sourceText = (event["sourceText"] as? String) ?? ""

    switch action {
    case "copy":
      guard !sourceText.isEmpty else { return }
      UIPasteboard.general.string = sourceText
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      onNativeEvent(["type": "agentToast", "message": "Copied to clipboard"])

    case "thumbUp":
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      onNativeEvent([
        "type": "agentFeedback",
        "messageId": sourceMessageId,
        "value": "up",
      ])
      onNativeEvent(["type": "agentToast", "message": "Thanks for the feedback"])

    case "thumbDown":
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      onNativeEvent([
        "type": "agentFeedback",
        "messageId": sourceMessageId,
        "value": "down",
      ])
      onNativeEvent(["type": "agentToast", "message": "Feedback noted"])

    case "regenerate":
      regenerateAssistantResponse(sourceMessageId: sourceMessageId)

    default:
      onNativeEvent(event)
    }
  }

  private func presentAgentCardPanel(_ card: ChatListRow.AgentCard) {
    guard let presenter = topMostViewController() else { return }
    let controller = ChatNativeAgentConfigPanelController(
      card: resolvedAgentCard(card),
      appearance: appearance
    )
    controller.onToast = { [weak self] message in
      self?.onNativeEvent(["type": "agentToast", "message": message])
    }
    controller.onDeleteAgent = { [weak self] card, dismiss in
      self?.deleteAgent(card, dismiss: dismiss)
    }

    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .pageSheet
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28.0
    }
    presenter.present(navigation, animated: true)
  }

  private func refreshHeaderGlass(isDarkTheme: Bool) {
    if #available(iOS 26.0, *) {
      let backEffect = UIGlassEffect()
      backEffect.isInteractive = true
      backGlassView.effect = backEffect

      let titleEffect = UIGlassEffect()
      titleEffect.isInteractive = true
      titleGlassView.effect = titleEffect

      let actionEffect = UIGlassEffect()
      actionEffect.isInteractive = true
      actionGlassView.effect = actionEffect
      return
    }

    let blurStyle: UIBlurEffect.Style = isDarkTheme ? .systemMaterialDark : .systemMaterialLight
    backGlassView.effect = UIBlurEffect(style: blurStyle)
    titleGlassView.effect = UIBlurEffect(style: blurStyle)
    actionGlassView.effect = UIBlurEffect(style: blurStyle)
  }

  private func refreshHeader(animated: Bool) {
    let title = currentPage == .chat ? "Vibe AI" : "History"
    let backSymbol = "chevron.left"
    let actionSymbol = currentPage == .chat ? "clock" : "plus"
    let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    backButton.setImage(UIImage(systemName: backSymbol, withConfiguration: config), for: .normal)
    actionButton.setImage(
      UIImage(systemName: actionSymbol, withConfiguration: config), for: .normal)

    if animated {
      UIView.transition(
        with: titleLabel,
        duration: 0.2,
        options: [.transitionCrossDissolve, .allowUserInteraction]
      ) {
        self.titleLabel.text = title
      }
      return
    }
    titleLabel.text = title
  }

  private func setPage(_ page: ChatNativeAgentPage, animated: Bool) {
    guard
      currentPage != page
        || abs(pageScrollView.contentOffset.x - CGFloat(page.rawValue) * bounds.width) > 0.5
    else {
      return
    }
    window?.endEditing(true)
    currentPage = page
    refreshHeader(animated: animated)
    bringSubviewToFront(headerContainer)
    let target = CGPoint(x: CGFloat(page.rawValue) * bounds.width, y: 0)
    pageScrollView.setContentOffset(target, animated: animated)
  }

  private func connectIfNeeded() {
    guard transportEnabled else { return }
    guard phoenixClient == nil else { return }
    guard let config = resolveConnectionConfig() else { return }

    topic = "agent:\(config.userId)"

    let callbacks = ChatPhoenixClient.Callbacks(
      onOpen: { [weak self] in
        DispatchQueue.main.async {
          self?.handleSocketOpen()
        }
      },
      onClose: { [weak self] _, _ in
        DispatchQueue.main.async {
          self?.handleSocketClose(
            streamFailureMessage: "Connection lost. Tap regenerate to retry.",
            toastMessage: "Connection lost"
          )
        }
      },
      onError: { [weak self] error in
        DispatchQueue.main.async {
          NSLog("[ChatNativeAgent] socket error %@", error)
          self?.handleSocketClose(
            streamFailureMessage: "Connection lost. Tap regenerate to retry.",
            toastMessage: "Connection lost"
          )
        }
      },
      onEvent: { [weak self] frame in
        DispatchQueue.main.async {
          self?.handlePhoenixFrame(frame)
        }
      }
    )

    let client = ChatPhoenixClient(
      baseURL: config.socketURL,
      params: [:],
      authToken: config.token,
      callbacks: callbacks
    )
    phoenixClient = client
    client.connect()
  }

  private func handleSocketOpen() {
    reconnectWorkItem?.cancel()
    guard let client = phoenixClient, !topic.isEmpty else { return }
    let joinRef = client.join(topic: topic, payload: [:])
    pendingReplies[joinRef] = { [weak self] status, _ in
      guard let self else { return }
      if status == "ok" {
        self.joinedTopic = true
        self.syncConversations()
        self.flushPendingSends()
        return
      }
      self.scheduleReconnect()
    }
  }

  private func handleSocketClose(
    streamFailureMessage: String? = nil,
    toastMessage: String? = nil
  ) {
    let hadActiveStream = streamingConversationId != nil
    let stoppedManually = isStoppingStreamManually
    isStoppingStreamManually = false
    joinedTopic = false
    pendingReplies.removeAll()
    phoenixClient = nil

    if hadActiveStream && !stoppedManually {
      if let toastMessage, !toastMessage.isEmpty {
        onNativeEvent(["type": "agentToast", "message": toastMessage])
      }
      finishStreaming(
        fallbackText: streamFailureMessage ?? "Connection lost. Tap regenerate to retry.",
        forceErrorText: true
      )
    }

    scheduleReconnect()
  }

  private func scheduleReconnect() {
    reconnectWorkItem?.cancel()
    guard transportEnabled else { return }
    let workItem = DispatchWorkItem { [weak self] in
      self?.connectIfNeeded()
    }
    reconnectWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
  }

  private func resolveConnectionConfig() -> (socketURL: URL, token: String, userId: String)? {
    let nativeCallConfig = VibeNativeCallStore.shared.getNativeEngineConfig()
    let session = Self.loadNativeAuthSessionFromKeychain()

    guard
      let userId = Self.normalizedString(
        nativeCallConfig["userId"] ?? session?["userId"])
    else {
      NSLog("[ChatNativeAgent] missing native user id")
      return nil
    }

    let apiBase =
      Self.normalizedString(
        nativeCallConfig["baseUrl"] ?? nativeCallConfig["apiBaseUrl"])
      ?? Self.fallbackApiBaseURL
    let socketString =
      Self.normalizedString(nativeCallConfig["socketUrl"])
      ?? (apiBase.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
        + "/socket")
    let token =
      Self.normalizedString(nativeCallConfig["authToken"] ?? session?["loginToken"])
      ?? userId

    guard let socketURL = URL(string: socketString) else {
      NSLog("[ChatNativeAgent] invalid socket url %@", socketString)
      return nil
    }

    return (socketURL, token, userId)
  }

  private func resolveAPIConfig() -> (apiBaseURL: URL, token: String, userId: String)? {
    let nativeCallConfig = VibeNativeCallStore.shared.getNativeEngineConfig()
    let session = Self.loadNativeAuthSessionFromKeychain()

    guard
      let userId = Self.normalizedString(nativeCallConfig["userId"] ?? session?["userId"])
    else {
      return nil
    }

    let apiBase =
      Self.normalizedString(nativeCallConfig["baseUrl"] ?? nativeCallConfig["apiBaseUrl"])
      ?? Self.fallbackApiBaseURL
    let token =
      Self.normalizedString(nativeCallConfig["authToken"] ?? session?["loginToken"])
      ?? userId

    guard let apiBaseURL = URL(string: apiBase) else { return nil }
    return (apiBaseURL, token, userId)
  }

  private func handlePhoenixFrame(_ frame: ChatPhoenixClient.EventFrame) {
    if frame.event == "phx_reply", let ref = frame.ref {
      let status = (frame.payload["status"] as? String) ?? "error"
      let response = (frame.payload["response"] as? [String: Any]) ?? [:]
      let handler = pendingReplies.removeValue(forKey: ref)
      handler?(status, response)
      return
    }

    guard frame.topic == topic else { return }

    switch frame.event {
    case "chunk":
      let text = (frame.payload["text"] as? String) ?? ""
      NSLog("[ChatNativeAgent] chunk received len=%d total_segments=%d", text.count, conversation(for: streamingConversationId ?? activeConversationId ?? "")?.messages.last?.streamSegments.count ?? 0)
      scheduleStreamingTimeout()
      appendChunk(text)
    case "progress":
      let label =
        (frame.payload["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let tool = frame.payload["tool"] as? String
      let status = (frame.payload["status"] as? String) ?? "running"
      NSLog("[ChatNativeAgent] progress tool=%@ status=%@ label=%@", tool ?? "nil", status, label)
      scheduleStreamingTimeout()

      guard let conversationId = streamingConversationId ?? activeConversationId else { break }
      updateConversation(conversationId) { conversation in
        guard !conversation.messages.isEmpty else { return }
        let lastIndex = conversation.messages.count - 1
        guard conversation.messages[lastIndex].role == .assistant else { return }

        if status == "complete" || status == "error" {
          // Remove the running progress for this tool
          conversation.messages[lastIndex].streamSegments.removeAll {
            $0.isRunningProgress && $0.progressTool == tool
          }
        } else {
          // Remove any existing running progress for same tool, then append new one
          conversation.messages[lastIndex].streamSegments.removeAll {
            $0.isRunningProgress && $0.progressTool == tool
          }
          conversation.messages[lastIndex].streamSegments.append(
            .progress(
              id: UUID().uuidString,
              label: label.isEmpty ? "Working..." : label,
              tool: tool,
              status: status
            )
          )
        }
      }
      rebuildChatRows(scrollToBottom: false, animated: false)
    case "subagent":
      NSLog("[ChatNativeAgent] subagent event=%@", (frame.payload["event"] as? String) ?? "unknown")
      scheduleStreamingTimeout()
      handleSubagentEvent(frame.payload)
    case "agent_cards":
      scheduleStreamingTimeout()
      handleAgentCardsEvent(frame.payload)
    case "builder_state":
      scheduleStreamingTimeout()
      handleBuilderStateEvent(frame.payload)
    case "ui_request":
      scheduleStreamingTimeout()
      handleBuilderUiRequestEvent(frame.payload)
    case "review_ready":
      scheduleStreamingTimeout()
      handleBuilderReviewReadyEvent(frame.payload)
    case "ack":
      if let conversationId = frame.payload["conversation_id"] as? String {
        applyAcknowledgedConversationId(conversationId)
      }
    case "done":
      finishStreaming(
        fallbackText: nil,
        forceErrorText: false
      )
    case "error":
      let message = (frame.payload["message"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      finishStreaming(
        fallbackText:
          (message?.isEmpty == false ? message : "Something went wrong. Tap regenerate to retry."),
        forceErrorText: true
      )
    case "title_updated":
      let conversationId = (frame.payload["conversation_id"] as? String) ?? ""
      let title = (frame.payload["title"] as? String) ?? ""
      guard !conversationId.isEmpty else { return }
      updateConversation(conversationId) { conversation in
        conversation.title = title
      }
      persistState()
      refreshHistoryList()
    default:
      break
    }
  }

  private func handleSubagentEvent(_ payload: [String: Any]) {
    let label = Self.normalizedString(payload["label"]) ?? "Specialist"
    let event = Self.normalizedString(payload["event"]) ?? ""
    let detail = Self.normalizedString(payload["detail"])
    let status = Self.normalizedString(payload["status"]) ?? ""

    let nextLabel: String
    let segmentStatus: String
    switch event {
    case "started":
      nextLabel = "Starting \(label)..."
      segmentStatus = "running"
    case "progress":
      nextLabel = detail ?? "\(label) is working..."
      segmentStatus = "running"
    case "finished":
      nextLabel = status == "error" ? "\(label) failed." : "\(label) completed."
      segmentStatus = status == "error" ? "error" : "complete"
    default:
      nextLabel = detail ?? "Working..."
      segmentStatus = "running"
    }

    guard let conversationId = streamingConversationId ?? activeConversationId else { return }
    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else { return }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else { return }

      let toolKey = "subagent_\(label)"
      if segmentStatus == "complete" || segmentStatus == "error" {
        conversation.messages[lastIndex].streamSegments.removeAll {
          $0.isRunningProgress && $0.progressTool == toolKey
        }
      } else {
        conversation.messages[lastIndex].streamSegments.removeAll {
          $0.isRunningProgress && $0.progressTool == toolKey
        }
        conversation.messages[lastIndex].streamSegments.append(
          .progress(
            id: UUID().uuidString,
            label: nextLabel,
            tool: toolKey,
            status: segmentStatus
          )
        )
      }
    }
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func handleAgentCardsEvent(_ payload: [String: Any]) {
    let groupId =
      Self.normalizedString(payload["group_id"])
      ?? Self.normalizedString(payload["groupId"])
      ?? "builder:cards"
    let rawCards = (payload["cards"] as? [[String: Any]]) ?? []
    let cards = rawCards.compactMap(ChatListRow.AgentCard.parse).map(resolvedAgentCard)
    guard !cards.isEmpty else { return }
    guard let conversationId = streamingConversationId ?? activeConversationId else { return }

    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else { return }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else { return }

      conversation.messages[lastIndex].streamSegments.removeAll {
        if case .cards(let existingGroupId, _) = $0 {
          return existingGroupId == groupId
        }
        return false
      }
      conversation.messages[lastIndex].streamSegments.append(
        .cards(groupId: groupId, cards: cards)
      )
      conversation.updatedAt = Self.nowMs()
    }
    persistState()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func handleBuilderStateEvent(_ payload: [String: Any]) {
    if let setupState = ChatBuilderSetupState(raw: payload["setupState"] as? [String: Any]) {
      builderSetupState = setupState
    }
    builderActivity =
      ((payload["activity"] as? [[String: Any]]) ?? [])
      .compactMap(ChatBuilderActivityItem.init(raw:))
  }

  private func resolvedAgentCard(_ card: ChatListRow.AgentCard) -> ChatListRow.AgentCard {
    guard
      card.latestSecret == nil,
      let activeAgentId = builderActiveAgentId,
      let latestSecret = builderLatestSecret,
      card.agentId == activeAgentId
    else {
      return card
    }

    return ChatListRow.AgentCard(
      id: card.id,
      style: card.style,
      agentId: card.agentId,
      displayName: card.displayName,
      username: card.username,
      identifier: card.identifier,
      status: card.status,
      promptStatus: card.promptStatus,
      promptPreview: card.promptPreview,
      systemPrompt: card.systemPrompt,
      enabledTools: card.enabledTools,
      outputModes: card.outputModes,
      voiceProfile: card.voiceProfile,
      callbackURL: card.callbackURL,
      apiBaseURL: card.apiBaseURL,
      invokeURL: card.invokeURL,
      eventsURL: card.eventsURL,
      builderLink: card.builderLink,
      agentDMURL: card.agentDMURL,
      secretHint: card.secretHint,
      latestSecret: latestSecret,
      defaultDestinationChat: card.defaultDestinationChat,
      attachedChats: card.attachedChats,
      canDelete: card.canDelete
    )
  }

  private func handleBuilderUiRequestEvent(_ payload: [String: Any]) {
    handleBuilderStateEvent(payload)

    guard let request = ChatBuilderUiRequest(raw: payload["pendingUiRequest"] as? [String: Any])
    else { return }

    if let navigationController = builderQuestionNavigationController,
      navigationController.presentingViewController != nil
    {
      queuedBuilderQuestionRequest = request
      return
    }
    presentBuilderQuestionPanel(request)
  }

  private func handleBuilderReviewReadyEvent(_ payload: [String: Any]) {
    handleBuilderStateEvent(payload)
  }

  private func presentBuilderQuestionPanel(_ request: ChatBuilderUiRequest) {
    if let navigationController = builderQuestionNavigationController,
      navigationController.presentingViewController != nil
    {
      return
    }

    guard let presenter = topMostViewController() else { return }

    let controller = ChatBuilderPanelController(
      mode: .request(request),
      theme: currentBuilderPanelTheme(),
      setupState: builderSetupState,
      activity: builderActivity,
      agentEnabled: nil
    )
    controller.onSubmitRequest = { [weak self] requestId, answers, summary in
      self?.submitBuilderUiResponse(requestId: requestId, answers: answers, summary: summary)
    }
    controller.onControllerDismissed = { [weak self] in
      guard let self else { return }
      self.builderQuestionNavigationController = nil
      guard let queuedRequest = self.queuedBuilderQuestionRequest else { return }
      self.queuedBuilderQuestionRequest = nil
      DispatchQueue.main.async { [weak self] in
        self?.presentBuilderQuestionPanel(queuedRequest)
      }
    }

    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .pageSheet
    if let sheet = navigationController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.selectedDetentIdentifier = .medium
      sheet.prefersGrabberVisible = false
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      sheet.prefersEdgeAttachedInCompactHeight = true
      sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      sheet.preferredCornerRadius = 28.0
    }

    builderQuestionNavigationController = navigationController
    presenter.present(navigationController, animated: true)
  }

  private func syncConversations() {
    sendChannelEvent(event: "list_conversations", payload: [:]) { [weak self] status, response in
      guard let self, status == "ok" else { return }
      let remoteItems = (response["conversations"] as? [[String: Any]]) ?? []
      let localConversations = self.conversations

      var merged: [ChatNativeAgentConversation] = remoteItems.compactMap { item in
        guard let id = Self.normalizedString(item["id"]) else { return nil }
        let title = Self.normalizedString(item["title"]) ?? "New Chat"
        let existing = localConversations.first(where: { $0.id == id })
        return ChatNativeAgentConversation(
          id: id,
          title: title,
          createdAt: Self.parseTimestampMs(item["inserted_at"]) ?? Self.nowMs(),
          updatedAt: Self.parseTimestampMs(item["updated_at"]) ?? Self.nowMs(),
          messages: existing?.messages ?? []
        )
      }

      if let activeConversationId,
        !merged.contains(where: { $0.id == activeConversationId }),
        let localActive = localConversations.first(where: { $0.id == activeConversationId })
      {
        merged.insert(localActive, at: 0)
      }

      merged.sort { $0.createdAt > $1.createdAt }
      self.conversations = merged
      if self.activeConversationId == nil {
        self.activeConversationId = merged.first?.id
      }

      self.persistState()
      self.refreshHistoryList()
      self.rebuildChatRows(scrollToBottom: false, animated: false)

      if let activeConversationId,
        self.conversation(for: activeConversationId)?.messages.isEmpty == true
      {
        self.loadConversation(id: activeConversationId)
      }
    }
  }

  private func regenerateAssistantResponse(sourceMessageId: String) {
    let assistantMessageId = sourceMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !assistantMessageId.isEmpty else { return }

    connectIfNeeded()

    guard let conversationId = activeConversationId else { return }
    guard let conversation = conversation(for: conversationId) else { return }
    guard let assistantIndex = conversation.messages.firstIndex(where: { $0.id == assistantMessageId })
    else { return }
    guard conversation.messages[assistantIndex].role == .assistant else { return }
    guard assistantIndex > 0 else { return }

    var userText = ""
    for index in stride(from: assistantIndex - 1, through: 0, by: -1) {
      let candidate = conversation.messages[index]
      guard candidate.role == .user else { continue }
      userText = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !userText.isEmpty {
        break
      }
    }
    guard !userText.isEmpty else { return }

    let timestampMs = Self.nowMs()
    let assistantMessage = ChatNativeAgentMessage(
      id: UUID().uuidString,
      role: .assistant,
      content: "",
      timestampMs: timestampMs,
      isStreaming: true,
      streamSegments: []
    )

    updateConversation(conversationId) { conversation in
      conversation.messages = Array(conversation.messages.prefix(assistantIndex))
      conversation.messages.append(assistantMessage)
      conversation.updatedAt = timestampMs
    }

    streamingConversationId = conversationId
    notifyStreamingStateChanged()
    currentSpacerHeight = 0.0
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: true, animated: true)
    scheduleStreamingTimeout()
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()

    if joinedTopic {
      pushMessage(text: userText, conversationId: conversationId, truncateAtId: assistantMessageId)
    } else {
      pendingSends.append(
        .message(
          conversationId: conversationId,
          text: userText,
          truncateAtId: assistantMessageId
        ))
    }
  }

  private func loadConversation(id: String) {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    sendChannelEvent(event: "get_conversation", payload: ["id": id]) {
      [weak self] status, response in
      guard let self, status == "ok" else { return }

      let conversationPayload: [String: Any]
      if let nested = response["conversation"] as? [String: Any] {
        conversationPayload = nested
      } else {
        conversationPayload = response
      }

      let rawMessages = (conversationPayload["messages"] as? [[String: Any]]) ?? []
      let messages = rawMessages.compactMap(Self.parseServerMessage)

      self.updateConversation(id) { conversation in
        conversation.messages = messages.sorted { $0.timestampMs < $1.timestampMs }
        conversation.updatedAt = Self.nowMs()
      }
      self.persistState()
      self.refreshHistoryList()
      self.rebuildChatRows(scrollToBottom: false, animated: false)
    }
  }

  private func pushMessage(text: String, conversationId: String, truncateAtId: String?) {
    var payload: [String: Any] = [
      "text": text,
      "images": [],
      "conversation_id": conversationId,
    ]
    if let truncateAtId, !truncateAtId.isEmpty {
      payload["truncate_at_id"] = truncateAtId
    }
    sendChannelEvent(event: "message", payload: payload) { _, _ in }
  }

  private func flushPendingSends() {
    guard joinedTopic else { return }
    let queued = pendingSends
    pendingSends.removeAll()
    for pending in queued {
      switch pending {
      case .message(let conversationId, let text, let truncateAtId):
        pushMessage(
          text: text,
          conversationId: conversationId,
          truncateAtId: truncateAtId
        )

      case .builderUiResponse(let conversationId, let uiResponse, let summary):
        pushBuilderUiResponse(
          conversationId: conversationId,
          uiResponse: uiResponse,
          summary: summary
        )
      }
    }
  }

  private func sendChannelEvent(
    event: String,
    payload: [String: Any],
    reply: @escaping (String, [String: Any]) -> Void
  ) {
    guard let client = phoenixClient, !topic.isEmpty else { return }
    let ref = client.push(topic: topic, event: event, payload: payload)
    pendingReplies[ref] = reply
  }

  private func appendChunk(_ chunk: String) {
    guard let conversationId = streamingConversationId ?? activeConversationId else {
      NSLog("[ChatNativeAgent] appendChunk: no active conversation, dropping chunk len=%d", chunk.count)
      return
    }
    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else {
        NSLog("[ChatNativeAgent] appendChunk: no messages in conversation")
        return
      }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else {
        NSLog("[ChatNativeAgent] appendChunk: last message is not assistant")
        return
      }
      conversation.messages[lastIndex].content += chunk
      conversation.messages[lastIndex].isStreaming = true
      conversation.updatedAt = Self.nowMs()

      // Append to the last .text segment (skip over any trailing card segments),
      // or create a new one. This preserves ordering: if the last non-card segment
      // was a progress, a new text block starts AFTER it.
      let lastTextOrProgressIndex = conversation.messages[lastIndex].streamSegments.lastIndex(where: {
        switch $0 {
        case .text: return true
        case .progress: return true
        case .cards: return false
        }
      })
      if let lastIdx = lastTextOrProgressIndex,
         case .text(let existing) = conversation.messages[lastIndex].streamSegments[lastIdx] {
        conversation.messages[lastIndex].streamSegments[lastIdx] = .text(existing + chunk)
      } else {
        // Insert before any trailing card segments
        let insertIndex = lastTextOrProgressIndex.map { $0 + 1 } ?? conversation.messages[lastIndex].streamSegments.count
        conversation.messages[lastIndex].streamSegments.insert(.text(chunk), at: min(insertIndex, conversation.messages[lastIndex].streamSegments.count))
      }

      NSLog("[ChatNativeAgent] appendChunk: content_len=%d segments=%d chunk_len=%d",
            conversation.messages[lastIndex].content.count,
            conversation.messages[lastIndex].streamSegments.count,
            chunk.count)
    }
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func applyAcknowledgedConversationId(_ serverConversationId: String) {
    guard let currentId = activeConversationId, currentId != serverConversationId else {
      if streamingConversationId != nil {
        streamingConversationId = serverConversationId
      }
      return
    }

    guard let index = conversations.firstIndex(where: { $0.id == currentId }) else {
      activeConversationId = serverConversationId
      streamingConversationId = serverConversationId
      return
    }

    conversations[index].id = serverConversationId
    activeConversationId = serverConversationId
    streamingConversationId = serverConversationId
    pendingSends = pendingSends.map {
      $0.conversationId == currentId ? $0.withConversationId(serverConversationId) : $0
    }
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func finishStreaming(fallbackText: String?, forceErrorText: Bool) {
    streamingTimeoutWorkItem?.cancel()

    guard let conversationId = streamingConversationId ?? activeConversationId else {
      NSLog("[ChatNativeAgent] finishStreaming: no active conversation")
      return
    }
    NSLog("[ChatNativeAgent] finishStreaming conversationId=%@ fallback=%@ forceError=%d",
          String(conversationId.prefix(8)), fallbackText ?? "nil", forceErrorText ? 1 : 0)

    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else { return }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else { return }

      if forceErrorText, let fallbackText, conversation.messages[lastIndex].content.isEmpty {
        conversation.messages[lastIndex].content = fallbackText
      } else if conversation.messages[lastIndex].content.isEmpty, let fallbackText {
        conversation.messages[lastIndex].content = fallbackText
      }
      conversation.messages[lastIndex].isStreaming = false
      conversation.messages[lastIndex].streamSegments.removeAll { $0.isRunningProgress }
      conversation.updatedAt = Self.nowMs()
    }

    streamingConversationId = nil
    notifyStreamingStateChanged()
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  func stopStreaming() {
    guard let conversationId = streamingConversationId else { return }

    isStoppingStreamManually = true
    pendingReplies.removeAll()
    pendingSends.removeAll { $0.conversationId == conversationId }

    finishStreaming(fallbackText: "Stopped.", forceErrorText: false)
    onNativeEvent(["type": "agentToast", "message": "Stopped response"])

    joinedTopic = false
    reconnectWorkItem?.cancel()
    phoenixClient?.disconnect()
    phoenixClient = nil
    scheduleReconnect()
  }

  private func deleteAgent(_ card: ChatListRow.AgentCard, dismiss: @escaping () -> Void) {
    guard let config = resolveAPIConfig() else {
      onNativeEvent(["type": "agentToast", "message": "Missing API session"])
      return
    }

    let trimmedId = card.agentId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedId.isEmpty else { return }

    let path = "/api/agents/\(trimmedId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedId)"
    let url = URL(string: path, relativeTo: config.apiBaseURL) ?? config.apiBaseURL.appendingPathComponent(path)
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let cardTitle = card.displayName

    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          NSLog("[ChatNativeAgent] delete agent failed %@", error.localizedDescription)
          self.onNativeEvent(["type": "agentToast", "message": "Could not delete agent"])
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
          let body =
            data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          NSLog(
            "[ChatNativeAgent] delete agent rejected status=%d body=%@",
            statusCode,
            body ?? "-"
          )
          self.onNativeEvent(["type": "agentToast", "message": "Delete failed"])
          return
        }

        self.removeAgentCards(agentId: trimmedId)
        dismiss()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        self.onNativeEvent(["type": "agentToast", "message": "Deleted \(cardTitle)"])
      }
    }.resume()
  }

  private func removeAgentCards(agentId: String) {
    let trimmedId = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedId.isEmpty else { return }

    for index in conversations.indices {
      var conversation = conversations[index]
      for messageIndex in conversation.messages.indices {
        var segments = conversation.messages[messageIndex].streamSegments
        var changed = false

        segments = segments.compactMap { segment in
          switch segment {
          case .cards(let groupId, let cards):
            let filtered = cards.filter { $0.agentId != trimmedId }
            if filtered.count != cards.count {
              changed = true
            }
            return filtered.isEmpty ? nil : .cards(groupId: groupId, cards: filtered)

          default:
            return segment
          }
        }

        if changed {
          conversation.messages[messageIndex].streamSegments = segments
        }
      }
      conversations[index] = conversation
    }

    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func scheduleStreamingTimeout() {
    streamingTimeoutWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      NSLog("[ChatNativeAgent] streaming timeout fired after 120s")
      self?.finishStreaming(
        fallbackText: "Response timed out. Tap regenerate to retry.",
        forceErrorText: true
      )
    }
    streamingTimeoutWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 120.0, execute: workItem)
  }

  private func createConversation(title: String) -> String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let conversation = ChatNativeAgentConversation(
      id: UUID().uuidString,
      title: trimmedTitle.isEmpty ? "New Chat" : trimmedTitle,
      createdAt: Self.nowMs(),
      updatedAt: Self.nowMs(),
      messages: []
    )
    conversations.insert(conversation, at: 0)
    activeConversationId = conversation.id
    currentSpacerHeight = 0
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)

    if joinedTopic {
      sendChannelEvent(event: "create_conversation", payload: ["title": conversation.title]) {
        [weak self] status, response in
        guard let self, status == "ok" else { return }
        guard let newId = Self.normalizedString(response["id"]) else { return }
        self.replaceConversationId(localId: conversation.id, serverId: newId)
      }
    }
    return conversation.id
  }

  private func replaceConversationId(localId: String, serverId: String) {
    guard let index = conversations.firstIndex(where: { $0.id == localId }) else { return }
    conversations[index].id = serverId
    if activeConversationId == localId {
      activeConversationId = serverId
    }
    if streamingConversationId == localId {
      streamingConversationId = serverId
    }
    pendingSends = pendingSends.map {
      $0.conversationId == localId ? $0.withConversationId(serverId) : $0
    }
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func deleteConversation(id: String) {
    conversations.removeAll(where: { $0.id == id })
    if activeConversationId == id {
      activeConversationId = conversations.sorted { $0.createdAt > $1.createdAt }.first?.id
      currentSpacerHeight = 0

      if let activeConversationId,
        conversation(for: activeConversationId)?.messages.isEmpty == true
      {
        loadConversation(id: activeConversationId)
      }
    }
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
    if joinedTopic {
      sendChannelEvent(event: "delete_conversation", payload: ["id": id]) { _, _ in }
    }
  }

  private func selectConversation(id: String) {
    guard activeConversationId != id else {
      setPage(.chat, animated: true)
      return
    }
    activeConversationId = id
    currentSpacerHeight = 0

    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
    if conversation(for: id)?.messages.isEmpty == true {
      loadConversation(id: id)
    }
    setPage(.chat, animated: true)
  }

  private func refreshHistoryList() {
    historyEmptyLabel.isHidden = !conversations.isEmpty
    historyTableView.reloadData()
  }

  private func rebuildChatRows(scrollToBottom: Bool, animated: Bool) {
    let topPadding = safeAreaInsets.top + 80.0
    let bottomPadding: CGFloat = 140.0

    guard let activeConversation = activeConversationId.flatMap({ conversation(for: $0) }) else {
      messagesView.setRows(
        [],
        topPadding: topPadding,
        spacerHeight: currentSpacerHeight,
        bottomPadding: bottomPadding,
        scrollToBottom: false,
        animated: false
      )
      return
    }

    let rows = makeRawRows(for: activeConversation)
    messagesView.setRows(
      rows,
      topPadding: topPadding,
      spacerHeight: currentSpacerHeight,
      bottomPadding: bottomPadding,
      scrollToBottom: false,
      animated: animated
    )

    guard scrollToBottom else { return }
    DispatchQueue.main.async { [weak self] in
      self?.messagesView.scrollToBottom(animated: animated)
    }
  }

  private func makeRawRows(for conversation: ChatNativeAgentConversation) -> [[String: Any]] {
    let renderEntries = makeRenderEntries(for: conversation)
    let regeneratePromptByAssistantId = regeneratePromptMap(for: conversation)
    var rows: [[String: Any]] = []
    var lastDayKey: String?

    for index in renderEntries.indices {
      let entry = renderEntries[index]
      let dayKey = Self.dayKey(entry.timestampMs)
      if lastDayKey != dayKey {
        rows.append([
          "kind": "day",
          "key": "d-\(dayKey)",
          "label": Self.formatDayLabel(entry.timestampMs),
          "timestampMs": entry.timestampMs,
        ])
        lastDayKey = dayKey
      }

      let previous = index > 0 ? renderEntries[index - 1] : nil
      let next = index + 1 < renderEntries.count ? renderEntries[index + 1] : nil
      let isLastEntryForMessage = next?.messageId != entry.messageId
      let isSequenceStart = previous?.role != entry.role
      let isSequenceEnd = next?.role != entry.role
      let shape = Self.makeBubbleShape(
        isMe: entry.role == .user,
        isSequenceStart: isSequenceStart,
        isSequenceEnd: isSequenceEnd,
        showTail: entry.showTail
      )

      var message: [String: Any] = [
        "id": entry.id,
        "text": entry.text,
        "timestamp": Self.formatTimeLabel(entry.timestampMs),
        "isMe": entry.role == .user,
        "type": entry.messageType,
        "bubbleShape": shape,
      ]

      if entry.isAgentMessage {
        message["isAgentMessage"] = true
        message["agentName"] = "Vibe AI"
        message["plainContent"] = entry.text
        var metadata: [String: Any] = [:]
        if let progressNodes = entry.progressNodes, !progressNodes.isEmpty {
          metadata["progressNodes"] = progressNodes
        }
        if let agentCard = entry.agentCard {
          metadata["agentCard"] = agentCard.rawValue
        }
        if entry.messageType == "text", let actionSourceMessageId = entry.actionSourceMessageId {
          metadata["sourceMessageId"] = actionSourceMessageId
        }
        if entry.messageType == "text", let actionSourceText = entry.actionSourceText {
          metadata["sourceText"] = actionSourceText
        }
        if !metadata.isEmpty {
          message["metadata"] = metadata
        }
        if entry.isStreaming {
          message["isStreaming"] = true
        }
      }

      rows.append([
        "kind": "message",
        "key": "m-\(entry.id)",
        "message": message,
      ])

      let actionSourceText = entry.actionSourceText ?? entry.text
      let trimmedActionSourceText =
        actionSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
      if entry.isAgentMessage,
        !entry.isStreaming,
        isLastEntryForMessage,
        !trimmedActionSourceText.isEmpty,
        let actionSourceMessageId = entry.actionSourceMessageId
      {
        var actionMetadata: [String: Any] = [
          "sourceMessageId": actionSourceMessageId,
          "sourceText": actionSourceText,
        ]
        if let regeneratePrompt = regeneratePromptByAssistantId[actionSourceMessageId],
          !regeneratePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          actionMetadata["regeneratePrompt"] = regeneratePrompt
        }

        rows.append([
          "kind": "message",
          "key": "a-\(actionSourceMessageId)",
          "message": [
            "id": "actions-\(actionSourceMessageId)",
            "text": "",
            "timestamp": "",
            "isMe": false,
            "type": "agent_actions",
            "isAgentMessage": true,
            "agentName": "Vibe AI",
            "bubbleShape": [
              "showTail": false,
              "borderTopLeftRadius": 18,
              "borderTopRightRadius": 18,
              "borderBottomLeftRadius": 18,
              "borderBottomRightRadius": 18,
            ],
            "metadata": actionMetadata,
          ],
        ])
      }
    }

    return rows
  }

  private func makeRenderEntries(for conversation: ChatNativeAgentConversation)
    -> [ChatNativeAgentRenderEntry]
  {
    let messages = conversation.messages.sorted { $0.timestampMs < $1.timestampMs }
    var entries: [ChatNativeAgentRenderEntry] = []

    for message in messages {
      let isActiveStreaming =
        message.isStreaming
        && conversation.id == (streamingConversationId ?? activeConversationId)

      let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasRenderableSegments = message.streamSegments.contains { segment in
        switch segment {
        case .text(let text):
          return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .progress(_, _, _, let status):
          return status == "running"
        case .cards(_, let cards):
          return !cards.isEmpty
        }
      }

      if message.role == .assistant && hasRenderableSegments {
        let entryCountBeforeAppend = entries.count
        appendSegmentedEntries(
          from: message,
          isStreaming: isActiveStreaming,
          into: &entries
        )
        if entries.count > entryCountBeforeAppend {
          continue
        }
      }

      if isActiveStreaming && trimmedContent.isEmpty {
        entries.append(
          ChatNativeAgentRenderEntry(
            id: "\(message.id)-thinking",
            messageId: message.id,
            role: .assistant,
            text: "Thinking...",
            timestampMs: max(message.timestampMs, Self.nowMs()),
            messageType: "agent_progress_tree",
            isStreaming: false,
            isAgentMessage: true,
            showTail: false,
            progressNodes: [
              ["id": "\(message.id)-thinking", "label": "Thinking...", "status": "running", "depth": 0]
            ],
            agentCard: nil,
            actionSourceMessageId: nil,
            actionSourceText: nil
          ))
        continue
      }

      guard !trimmedContent.isEmpty || message.role == .user else { continue }

      entries.append(
        ChatNativeAgentRenderEntry(
          id: message.id,
          messageId: message.id,
          role: message.role,
          text: message.content,
          timestampMs: message.timestampMs,
          messageType: "text",
          isStreaming: false,
          isAgentMessage: message.role == .assistant,
          showTail: true,
          progressNodes: nil,
          agentCard: nil,
          actionSourceMessageId: message.role == .assistant ? message.id : nil,
          actionSourceText: message.role == .assistant ? message.content : nil
        ))
    }

    return entries
  }

  private func appendSegmentedEntries(
    from message: ChatNativeAgentMessage,
    isStreaming: Bool,
    into entries: inout [ChatNativeAgentRenderEntry]
  ) {
    var pendingProgressSegments: [ChatNativeAgentStreamSegment] = []
    var deferredCardEntries: [ChatNativeAgentRenderEntry] = []
    let lastRenderableSegmentIndex = message.streamSegments.lastIndex(where: {
      switch $0 {
      case .text(let text):
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .cards(_, let cards):
        return !cards.isEmpty
      case .progress:
        return false
      }
    })
    let lastTextSegmentIndex = message.streamSegments.lastIndex(where: {
      if case .text(let text) = $0 {
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return false
    })

    func flushProgressSegments(position: Int) {
      guard !pendingProgressSegments.isEmpty else { return }
      let progressNodes = buildProgressNodes(from: pendingProgressSegments)
      pendingProgressSegments.removeAll()
      guard !progressNodes.isEmpty else { return }

      entries.append(
        ChatNativeAgentRenderEntry(
          id: "\(message.id)-progress-\(position)",
          messageId: message.id,
          role: .assistant,
          text: (progressNodes.first?["label"] as? String) ?? "Working...",
          timestampMs: max(message.timestampMs, Self.nowMs()),
          messageType: "agent_progress_tree",
          isStreaming: false,
          isAgentMessage: true,
          showTail: false,
          progressNodes: progressNodes,
          agentCard: nil,
          actionSourceMessageId: nil,
          actionSourceText: nil
        ))
    }

    for (index, segment) in message.streamSegments.enumerated() {
      switch segment {
      case .progress(_, _, _, let status):
        guard status == "running" else { continue }
        pendingProgressSegments.append(segment)

      case .text(let text):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        // Drop any accumulated progress segments — the arrival of text means the tool
        // already completed.  Showing a running-progress tree above the response text
        // would be misleading and visually incorrect.
        pendingProgressSegments.removeAll()

        let isLastTextSegment = index == lastTextSegmentIndex
        let isLastRenderableSegment = index == lastRenderableSegmentIndex
        entries.append(
          ChatNativeAgentRenderEntry(
            id: "\(message.id)-text-\(index)",
            messageId: message.id,
            role: .assistant,
            text: text,
            timestampMs: message.timestampMs,
            messageType: "text",
            isStreaming: isStreaming && isLastTextSegment,
            isAgentMessage: true,
            showTail: isLastTextSegment,
            progressNodes: nil,
            agentCard: nil,
            actionSourceMessageId:
              isStreaming ? nil : (isLastRenderableSegment ? message.id : nil),
            actionSourceText:
              isStreaming ? nil : (isLastRenderableSegment ? message.content : nil)
          ))

      case .cards(let groupId, let cards):
        // Defer card entries to render after all text content
        pendingProgressSegments.removeAll()
        let shouldAttachActions = !isStreaming && index == lastRenderableSegmentIndex
        for (cardIndex, card) in cards.enumerated() {
          deferredCardEntries.append(
            ChatNativeAgentRenderEntry(
              id: "\(message.id)-card-\(groupId)-\(cardIndex)",
              messageId: message.id,
              role: .assistant,
              text: card.displayName,
              timestampMs: message.timestampMs,
              messageType: "agent_card",
              isStreaming: false,
              isAgentMessage: true,
              showTail: false,
              progressNodes: nil,
              agentCard: card,
              actionSourceMessageId:
                shouldAttachActions && cardIndex == cards.count - 1 ? message.id : nil,
              actionSourceText:
                shouldAttachActions && cardIndex == cards.count - 1 ? message.content : nil
            ))
        }
      }
    }

    flushProgressSegments(position: message.streamSegments.count)

    if entries.last(where: { $0.id.hasPrefix(message.id) }) == nil,
      let lastTextSegmentIndex,
      case .text(let text) = message.streamSegments[lastTextSegmentIndex]
    {
      entries.append(
        ChatNativeAgentRenderEntry(
          id: message.id,
          messageId: message.id,
          role: .assistant,
          text: text,
          timestampMs: message.timestampMs,
          messageType: "text",
          isStreaming: isStreaming,
          isAgentMessage: true,
          showTail: true,
          progressNodes: nil,
          agentCard: nil,
          actionSourceMessageId: isStreaming ? nil : message.id,
          actionSourceText: isStreaming ? nil : message.content
        ))
    }

    if !deferredCardEntries.isEmpty, !isStreaming || lastTextSegmentIndex != nil {
      entries.append(contentsOf: deferredCardEntries)
    }
  }

  private func buildProgressNodes(from segments: [ChatNativeAgentStreamSegment]) -> [[String: Any]] {
    var nodes: [[String: Any]] = []
    var hasSubagentNode = false

    for segment in segments {
      guard case .progress(let id, let label, let tool, let status) = segment, status == "running" else {
        continue
      }

      let depth: Int
      if tool == "delegate_to_subagent" || tool == nil {
        depth = 0
      } else if let tool, tool.hasPrefix("subagent_") {
        depth = 1
        hasSubagentNode = true
      } else {
        depth = hasSubagentNode ? 2 : 1
      }

      nodes.append([
        "id": id,
        "label": label,
        "status": status,
        "depth": depth,
      ])
    }

    return nodes
  }

  private func regeneratePromptMap(for conversation: ChatNativeAgentConversation) -> [String: String]
  {
    let messages = conversation.messages.sorted { $0.timestampMs < $1.timestampMs }
    var prompts: [String: String] = [:]
    var lastUserText: String?

    for message in messages {
      let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      switch message.role {
      case .user:
        lastUserText = trimmed.isEmpty ? nil : message.content

      case .assistant:
        if let lastUserText, !trimmed.isEmpty {
          prompts[message.id] = lastUserText
        }
      }
    }

    return prompts
  }

  private func conversation(for id: String) -> ChatNativeAgentConversation? {
    conversations.first(where: { $0.id == id })
  }

  private func updateConversation(_ id: String, mutate: (inout ChatNativeAgentConversation) -> Void)
  {
    guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
    var conversation = conversations[index]
    mutate(&conversation)
    conversations[index] = conversation
  }

  private func notifyStreamingStateChanged() {
    let isStreaming = streamingConversationId != nil
    guard isStreaming != lastReportedStreamingState else { return }
    lastReportedStreamingState = isStreaming
    onNativeEvent([
      "type": "agentStreamingState",
      "isStreaming": isStreaming,
    ])
  }

  private func updateSpacerForSend(conversationId: String) {
    currentSpacerHeight = 0.0
  }

  private func applyPersistedState() {
    guard
      let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
      let state = try? JSONDecoder().decode(ChatNativeAgentPersistedState.self, from: data)
    else {
      return
    }
    conversations = state.conversations.map { conversation in
      var normalizedConversation = conversation
      normalizedConversation.messages = conversation.messages.map { message in
        guard message.role == .assistant, message.isStreaming else { return message }
        var normalizedMessage = message
        normalizedMessage.isStreaming = false
        normalizedMessage.streamSegments.removeAll { $0.isRunningProgress }
        if normalizedMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let fallbackText = "Previous response was interrupted. Tap regenerate to retry."
          normalizedMessage.content = fallbackText
          normalizedMessage.streamSegments = [.text(fallbackText)]
        }
        return normalizedMessage
      }
      return normalizedConversation
    }
    activeConversationId = state.activeConversationId
  }

  private func persistState() {
    let state = ChatNativeAgentPersistedState(
      activeConversationId: activeConversationId,
      conversations: conversations
    )
    guard let data = try? JSONEncoder().encode(state) else { return }
    UserDefaults.standard.set(data, forKey: Self.persistenceKey)
  }

  private func topMostViewController() -> UIViewController? {
    guard
      let root =
        window?.rootViewController
        ?? UIApplication.shared.connectedScenes
        .compactMap({ scene -> UIViewController? in
          guard let windowScene = scene as? UIWindowScene else { return nil }
          return windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        })
        .first
    else { return nil }

    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  private static func parseServerMessage(_ raw: [String: Any]) -> ChatNativeAgentMessage? {
    let id = normalizedString(raw["id"]) ?? UUID().uuidString
    let role = ChatNativeAgentRole(rawValue: (raw["role"] as? String) ?? "assistant") ?? .assistant
    let content = normalizedString(raw["content"]) ?? ""
    let timestampMs = parseTimestampMs(raw["timestamp"]) ?? nowMs()
    return ChatNativeAgentMessage(
      id: id,
      role: role,
      content: content,
      timestampMs: timestampMs,
      isStreaming: false,
      streamSegments: []
    )
  }

  // MARK: - Legacy decode helper
  // When loading persisted messages that don't have streamSegments,
  // the Codable default will give an empty array which is correct.

  private static func parseTimestampMs(_ raw: Any?) -> Int64? {
    if let value = raw as? NSNumber {
      let number = value.int64Value
      return number < 2_000_000_000 ? number * 1000 : number
    }
    if let value = raw as? String {
      if let number = Int64(value) {
        return number < 2_000_000_000 ? number * 1000 : number
      }
      if let date = isoDateFormatter.date(from: value) {
        return Int64(date.timeIntervalSince1970 * 1000.0)
      }
      if let date = fallbackDateFormatter.date(from: value) {
        return Int64(date.timeIntervalSince1970 * 1000.0)
      }
    }
    return nil
  }

  private static func normalizedString(_ raw: Any?) -> String? {
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = raw as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func loadNativeAuthSessionFromKeychain() -> [String: Any]? {
    let keyData = Data("user_session_v2".utf8)

    for service in ["app:no-auth", "app:auth", "app"] {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keyData,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecSuccess,
        let data = result as? Data,
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        return json
      }
    }

    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: "user_session_v2",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    return nil
  }

  private static func makeBubbleShape(
    isMe: Bool,
    isSequenceStart: Bool,
    isSequenceEnd: Bool,
    showTail: Bool
  ) -> [String: Any] {
    var shape: [String: Any] = [
      "isMe": isMe,
      "showTail": showTail && isSequenceEnd,
      "borderTopLeftRadius": 18,
      "borderTopRightRadius": 18,
      "borderBottomLeftRadius": 18,
      "borderBottomRightRadius": 18,
    ]

    if isMe {
      shape["borderTopRightRadius"] = isSequenceStart ? 18 : 5
      shape["borderBottomRightRadius"] = isSequenceEnd ? 18 : 5
    } else {
      shape["borderTopLeftRadius"] = isSequenceStart ? 18 : 5
      shape["borderBottomLeftRadius"] = isSequenceEnd ? 18 : 5
    }

    return shape
  }

  private static func formatTimeLabel(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    return timeFormatter.string(from: date)
  }

  private static func formatDayLabel(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    return dayFormatter.string(from: date)
  }

  private static func dayKey(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
  }

  private static func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000.0)
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private static let isoDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let fallbackDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter
  }()

  public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    conversations.sorted { $0.createdAt > $1.createdAt }.count
  }

  public func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let sorted = conversations.sorted { $0.createdAt > $1.createdAt }
    let conversation = sorted[indexPath.row]
    let cell =
      tableView.dequeueReusableCell(
        withIdentifier: ChatNativeAgentHistoryCell.reuseIdentifier,
        for: indexPath
      ) as? ChatNativeAgentHistoryCell
      ?? ChatNativeAgentHistoryCell(
        style: .default, reuseIdentifier: ChatNativeAgentHistoryCell.reuseIdentifier)
    cell.configure(
      conversation: conversation,
      activeConversationId: activeConversationId,
      appearance: appearance
    )
    return cell
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    window?.endEditing(true)
    let sorted = conversations.sorted { $0.createdAt > $1.createdAt }
    guard indexPath.row < sorted.count else { return }
    selectConversation(id: sorted[indexPath.row].id)
  }

  public func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    let sorted = conversations.sorted { $0.createdAt > $1.createdAt }
    guard indexPath.row < sorted.count else { return nil }
    let conversationId = sorted[indexPath.row].id
    let deleteAction = UIContextualAction(style: .destructive, title: "Delete") {
      [weak self] _, _, completion in
      self?.deleteConversation(id: conversationId)
      completion(true)
    }
    return UISwipeActionsConfiguration(actions: [deleteAction])
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    guard scrollView === pageScrollView else { return }
    syncCurrentPageFromOffset()
  }

  public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    guard scrollView === pageScrollView else { return }
    syncCurrentPageFromOffset()
  }

  private func syncCurrentPageFromOffset() {
    let width = max(1.0, pageScrollView.bounds.width)
    let pageIndex = Int(round(pageScrollView.contentOffset.x / width))
    let nextPage: ChatNativeAgentPage = pageIndex <= 0 ? .chat : .history
    guard currentPage != nextPage else { return }
    currentPage = nextPage
    refreshHeader(animated: true)
  }
}
