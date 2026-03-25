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

private struct ChatNativeAgentMessage: Codable, Equatable {
  let id: String
  let role: ChatNativeAgentRole
  var content: String
  var timestampMs: Int64
  var isStreaming: Bool
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

private struct ChatNativeAgentPendingSend {
  let conversationId: String
  let text: String
  let truncateAtId: String?
}

private struct ChatNativeAgentRenderEntry {
  let id: String
  let role: ChatNativeAgentRole
  let text: String
  let timestampMs: Int64
  let messageType: String
  let isStreaming: Bool
  let isAgentMessage: Bool
  let showTail: Bool
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
  private var currentToolLabel: String?
  private var currentSpacerHeight: CGFloat = 0

  private var topic: String = ""
  private var joinedTopic = false
  private var transportEnabled = false
  private var phoenixClient: ChatPhoenixClient?
  private var pendingReplies: [String: (String, [String: Any]) -> Void] = [:]
  private var reconnectWorkItem: DispatchWorkItem?
  private var streamingTimeoutWorkItem: DispatchWorkItem?
  private var pendingSends: [ChatNativeAgentPendingSend] = []
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
    let headerHeight = safeTop + 60.0

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

  func submitText(_ rawText: String) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    connectIfNeeded()

    var conversationId = activeConversationId
    if conversationId == nil {
      conversationId = createConversation(title: String(text.prefix(20)))
    }
    guard let conversationId else { return }

    let userMessage = ChatNativeAgentMessage(
      id: UUID().uuidString,
      role: .user,
      content: text,
      timestampMs: Self.nowMs(),
      isStreaming: false
    )
    let assistantMessage = ChatNativeAgentMessage(
      id: UUID().uuidString,
      role: .assistant,
      content: "",
      timestampMs: Self.nowMs(),
      isStreaming: true
    )

    updateConversation(conversationId) { conversation in
      conversation.messages.append(userMessage)
      conversation.messages.append(assistantMessage)
      conversation.updatedAt = Self.nowMs()
      if conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        conversation.title = String(text.prefix(20))
      }
    }

    streamingConversationId = conversationId
    currentToolLabel = nil
    currentSpacerHeight = 0.0
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: true, animated: true)
    scheduleStreamingTimeout()

    if joinedTopic {
      pushMessage(text: text, conversationId: conversationId, truncateAtId: nil)
    } else {
      pendingSends.append(
        ChatNativeAgentPendingSend(
          conversationId: conversationId,
          text: text,
          truncateAtId: nil
        ))
    }
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
      UIColor.black.withAlphaComponent(0.95).cgColor,
      UIColor.black.withAlphaComponent(0.72).cgColor,
      UIColor.clear.cgColor,
    ]
    headerMaskGradientLayer.locations = [0.0, 0.58, 1.0]
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
    headerMaskOverlayView.backgroundColor = baseBackground.withAlphaComponent(0.88)
    backGlassView.contentView.backgroundColor = baseBackground.withAlphaComponent(0.10)
    titleGlassView.contentView.backgroundColor = baseBackground.withAlphaComponent(0.10)
    actionGlassView.contentView.backgroundColor = baseBackground.withAlphaComponent(0.10)
    refreshHeaderGlass(isDarkTheme: isDarkTheme)

    refreshHeader(animated: false)
    refreshHistoryList()
    setNeedsLayout()
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
          self?.handleSocketClose()
        }
      },
      onError: { [weak self] error in
        DispatchQueue.main.async {
          NSLog("[ChatNativeAgent] socket error %@", error)
          self?.handleSocketClose()
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

  private func handleSocketClose() {
    joinedTopic = false
    pendingReplies.removeAll()
    phoenixClient = nil
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
      appendChunk(text)
    case "progress":
      let label =
        (frame.payload["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      currentToolLabel = label.isEmpty ? "Thinking..." : label
      rebuildChatRows(scrollToBottom: false, animated: false)
    case "subagent":
      handleSubagentEvent(frame.payload)
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
        fallbackText: (message?.isEmpty == false ? message : "Something went wrong."),
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

    let nextLabel: String?
    switch event {
    case "started":
      nextLabel = "Starting \(label)..."
    case "progress":
      nextLabel = detail ?? "\(label) is working..."
    case "finished":
      nextLabel = status == "error" ? "\(label) failed." : "\(label) completed."
    default:
      nextLabel = detail ?? currentToolLabel
    }

    currentToolLabel = nextLabel
    rebuildChatRows(scrollToBottom: false, animated: false)
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
      pushMessage(
        text: pending.text,
        conversationId: pending.conversationId,
        truncateAtId: pending.truncateAtId
      )
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
    guard let conversationId = streamingConversationId ?? activeConversationId else { return }
    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else { return }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else { return }
      conversation.messages[lastIndex].content += chunk
      conversation.messages[lastIndex].isStreaming = true
      conversation.updatedAt = Self.nowMs()
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
      ChatNativeAgentPendingSend(
        conversationId: $0.conversationId == currentId ? serverConversationId : $0.conversationId,
        text: $0.text,
        truncateAtId: $0.truncateAtId
      )
    }
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func finishStreaming(fallbackText: String?, forceErrorText: Bool) {
    streamingTimeoutWorkItem?.cancel()

    guard let conversationId = streamingConversationId ?? activeConversationId else {
      currentToolLabel = nil
      return
    }

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
      conversation.updatedAt = Self.nowMs()
    }

    currentToolLabel = nil
    streamingConversationId = nil
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func scheduleStreamingTimeout() {
    streamingTimeoutWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.finishStreaming(fallbackText: "Response stopped.", forceErrorText: false)
    }
    streamingTimeoutWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: workItem)
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
    currentToolLabel = nil
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
      ChatNativeAgentPendingSend(
        conversationId: $0.conversationId == localId ? serverId : $0.conversationId,
        text: $0.text,
        truncateAtId: $0.truncateAtId
      )
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
      currentToolLabel = nil
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
    currentToolLabel = nil
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
        if entry.isStreaming {
          message["isStreaming"] = true
        }
      }

      rows.append([
        "kind": "message",
        "key": "m-\(entry.id)",
        "message": message,
      ])
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

      if isActiveStreaming {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let progressLabel = currentToolLabel ?? (trimmed.isEmpty ? "Thinking..." : "")
        if !progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          entries.append(
            ChatNativeAgentRenderEntry(
              id: "\(message.id)-progress",
              role: .assistant,
              text: progressLabel,
              timestampMs: max(message.timestampMs, Self.nowMs()),
              messageType: "agent_progress",
              isStreaming: false,
              isAgentMessage: true,
              showTail: false
            ))
        }
        if trimmed.isEmpty {
          continue
        }
      }

      entries.append(
        ChatNativeAgentRenderEntry(
          id: message.id,
          role: message.role,
          text: message.content,
          timestampMs: message.timestampMs,
          messageType: "text",
          isStreaming: message.isStreaming,
          isAgentMessage: message.role == .assistant,
          showTail: true
        ))
    }

    return entries
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
    conversations = state.conversations
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
      isStreaming: false
    )
  }

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
