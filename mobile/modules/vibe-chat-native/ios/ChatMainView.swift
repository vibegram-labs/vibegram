import ExpoModulesCore
import UIKit

final class ChatNativeMainRegistry {
  static let shared = ChatNativeMainRegistry()

  private final class WeakRef {
    weak var value: ChatMainView?

    init(_ value: ChatMainView) {
      self.value = value
    }
  }

  private var map: [String: WeakRef] = [:]

  func register(surfaceId: String, view: ChatMainView) {
    map[surfaceId] = WeakRef(view)
  }

  func view(for surfaceId: String) -> ChatMainView? {
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

private enum ChatMainPage: String {
  case chat
  case profile
}

private enum ChatMainProfileTab: String, CaseIterable {
  case media
  case music
  case files
  case links
  case pinned
}

private struct ChatMainProfileMediaItem: Equatable {
  let messageId: String
  let type: String
  let mediaUrl: String
}

private struct ChatMainProfileFileItem: Equatable {
  let messageId: String
  let type: String
  let fileName: String
  let mediaUrl: String?
  let fileSize: Int64?
  let timestampMs: Int64
}

private struct ChatMainProfileLinkItem: Equatable {
  let messageId: String
  let url: String
  let subtitle: String
}

private struct ChatMainProfilePinnedItem: Equatable {
  let messageId: String
  let text: String
  let subtitle: String
}

public final class ChatMainView: ExpoView, ChatMainProfileAgentPromptNodeDelegate {
  public var onViewportChanged = EventDispatcher() {
    didSet { syncListDispatchers() }
  }
  public var onNativeEvent = EventDispatcher() {
    didSet { syncListDispatchers() }
  }

  @objc public var surfaceId: String = "" {
    didSet {
      let trimmed = surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !registeredSurfaceId.isEmpty, registeredSurfaceId != trimmed {
        ChatNativeMainRegistry.shared.unregister(surfaceId: registeredSurfaceId)
      }
      registeredSurfaceId = trimmed
      guard !trimmed.isEmpty else { return }
      ChatNativeMainRegistry.shared.register(surfaceId: trimmed, view: self)
      chatListView.surfaceId = "\(trimmed)#list"
    }
  }

  private let chatListView: ChatListView

  private let headerContainer = UIView()
  private let headerMaskView = UIView()
  private let headerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerMaskOverlayView = UIView()
  private let headerMaskGradientLayer = CAGradientLayer()
  private let headerContentView = UIView()

  private let backGlassView = UIVisualEffectView(effect: nil)
  private let backPressedOverlayView = UIView()
  private let backButton = UIButton(type: .system)

  private let titleGlassView = UIVisualEffectView(effect: nil)
  private let titlePressedOverlayView = UIView()
  private let titleButton = UIButton(type: .custom)

  private let avatarGlassView = UIVisualEffectView(effect: nil)
  private let avatarPressedOverlayView = UIView()
  private let avatarButton = UIButton(type: .system)
  private let avatarImageView = UIImageView()
  private let avatarFallbackIconView = UIImageView()
  private let menuGlassView = UIVisualEffectView(effect: nil)
  private let menuPressedOverlayView = UIView()
  private let menuButton = UIButton(type: .system)

  private let chatHeaderStack = UIStackView()
  private let chatTitleLabel = UILabel()
  private let chatSubtitleLabel = UILabel()
  private let profileHeaderStack = UIStackView()
  private let profileTitleLabel = UILabel()
  private let profileSubtitleLabel = UILabel()

  private let headerPressedOverlayColor = UIColor(white: 1.0, alpha: 0.08)

  private let rootWallpaperLayer = CAGradientLayer()
  private let pagesHost = UIView()
  private let chatPage = UIView()
  private let profilePage = UIView()
  private let profileWallpaperLayer = CAGradientLayer()
  private let profileWallpaperPatternLayer = CAGradientLayer()
  private let profileWallpaperPatternMaskLayer = CALayer()
  private let profileScrollView = UIScrollView()
  private let profileContentView = UIView()

  private let profileAvatarView = UIView()
  private let profileAvatarImageView = UIImageView()
  private let profileAvatarFallbackIconView = UIImageView()
  private let profileOnlineDotView = UIView()
  private let profileNameLabel = UILabel()
  private let profileHandleLabel = UILabel()
  private let profileBioLabel = UILabel()
  private let profileActionsStack = UIStackView()
  private let profileMuteButton = ChatMainProfileActionNode()
  private let profileSearchButton = ChatMainProfileActionNode()
  private let profileAudioCallButton = ChatMainProfileActionNode()
  private let profileVideoCallButton = ChatMainProfileActionNode()
  private let profileIdentityCard = UIView()
  private let profileUsernameRow = ChatMainProfileListRowNode()
  private let profileBioRow = ChatMainProfileListRowNode()
  private let profileTabsCard = UIView()
  private let profileTabsScrollView = UIScrollView()
  private let profileTabsStack = UIView()
  private let profileTabContentContainer = UIView()
  private let profileTabPlaceholderLabel = UILabel()

  private let profileAgentPromptNode = ChatMainProfileAgentPromptNode()
  private var agentConfig: [String: Any]?
  private var isGroupOrChannel = false

  private var appearance = ChatListAppearance.fallback
  private var isOnline = false
  private var chatTitleText: String = "Chat"
  private var chatSubtitleText: String = ""
  private var profileNameText: String = "User"
  private var profileHandleText: String = ""
  private var profileBioText: String = ""
  private var avatarUri: String = ""
  private var isChatMuted = false
  private var engineChatId: String = ""
  private var enginePeerUserId: String = ""
  private var engineLastSeenTimestampMs: Int64?
  private var profileSummaryMessageCount = 0
  private var profileSummaryMediaCount = 0
  private var profileSummaryFileCount = 0
  private var profileSummaryLinkCount = 0
  private var profileSummaryRecentFiles: [String] = []
  private var profileSummaryHistoryLoaded = false
  private var profileMediaItems: [ChatMainProfileMediaItem] = []
  private var profileMusicItems: [ChatMainProfileFileItem] = []
  private var profileFileItems: [ChatMainProfileFileItem] = []
  private var profileLinkItems: [ChatMainProfileLinkItem] = []
  private var profilePinnedItems: [ChatMainProfilePinnedItem] = []
  private var profileVisibleTabs: [ChatMainProfileTab] = []
  private var profileTabButtons: [ChatMainProfileTab: ChatMainProfileTabNode] = [:]
  private var profileActiveTab: ChatMainProfileTab = .media
  private var profileTabContentNeedsReload = true
  private var profileLastTabContentWidth: CGFloat = 0.0
  private var currentPage: ChatMainPage = .chat
  private var avatarLoadTask: URLSessionDataTask?
  private var registeredSurfaceId: String = ""
  private var pendingNativePageTarget: ChatMainPage?
  private var pendingNativePageLockUntil: CFTimeInterval = 0.0

  private static var wallpaperMaskImageCache: [String: CGImage] = [:]
  private static let lastSeenDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
  }()
  private static let lastSeenTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()
  private static let profileListDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  required init(appContext: AppContext? = nil) {
    chatListView = ChatListView(appContext: appContext)
    super.init(appContext: appContext)
    clipsToBounds = true
    configureView()
    startObservingChatEngine()
    syncListDispatchers()
    applyTheme()
    updateHeaderTexts()
    updateProfileTexts()
  }

  deinit {
    avatarLoadTask?.cancel()
    NotificationCenter.default.removeObserver(
      self, name: ChatEngine.didChangeNotification, object: nil)
    if !registeredSurfaceId.isEmpty {
      ChatNativeMainRegistry.shared.unregister(surfaceId: registeredSurfaceId)
    }
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    rootWallpaperLayer.frame = bounds
    layoutChrome()
    layoutPages()
    layoutProfileContent()
    applyPageState(animated: false, emitEvent: false)
  }

  // MARK: - Forwarded chat-list APIs

  func setRows(_ rows: [[String: Any]]) {
    chatListView.setRows(rows)
  }

  func setEngineSurfaceId(_ value: String) {
    chatListView.setEngineSurfaceId(value)
  }

  func setEngineChatId(_ value: String) {
    engineChatId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    chatListView.setEngineChatId(value)
    refreshProfileSummaryFromEngine(force: true)
  }

  func setEngineMyUserId(_ value: String) {
    chatListView.setEngineMyUserId(value)
  }

  func setEnginePeerUserId(_ value: String) {
    enginePeerUserId = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    chatListView.setEnginePeerUserId(value)
    if enginePeerUserId.isEmpty {
      engineLastSeenTimestampMs = nil
      updateHeaderTexts()
      updateProfileTexts()
      return
    }
    refreshPresenceStateFromEngine(force: true)
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    chatListView.setStatusAuthorityEnabled(enabled)
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    appearance = ChatListAppearance.from(raw: rawAppearance)
    chatListView.setAppearance(rawAppearance)
    applyTheme()
    updateHeaderTexts()
    updateProfileTexts()
  }

  func setContentPaddingBottom(_ value: Double) {
    chatListView.setContentPaddingBottom(value)
  }

  func setVoicePlayback(_ payload: [String: Any]) {
    chatListView.setVoicePlayback(payload)
  }

  func setInputBarEnabled(_ enabled: Bool) {
    chatListView.setInputBarEnabled(enabled)
  }

  func setInputPlaceholder(_ value: String) {
    chatListView.setInputPlaceholder(value)
  }

  func setNativeSendEnabled(_ enabled: Bool) {
    chatListView.setNativeSendEnabled(enabled)
  }

  func setDebugAnimationPanel(_ enabled: Bool) {
    chatListView.setDebugAnimationPanel(enabled)
  }

  func applyTransactions(_ transactions: [[String: Any]]) {
    chatListView.applyTransactions(transactions)
  }

  func scrollToBottom(animated: Bool) {
    chatListView.scrollToBottom(animated: animated)
  }

  func scrollToMessage(messageId: String, animated: Bool, viewPosition: Double) {
    chatListView.scrollToMessage(
      messageId: messageId, animated: animated, viewPosition: viewPosition)
  }

  func startSendTransition(_ payload: [String: Any]) {
    chatListView.startSendTransition(payload)
  }

  func playReactionFx(_ payload: [String: Any]) {
    chatListView.playReactionFx(payload)
  }

  // MARK: - Main view inputs

  func setHeaderTitle(_ value: String) {
    chatTitleText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if profileNameText.isEmpty {
      profileNameText = chatTitleText
    }
    updateHeaderTexts()
    updateProfileTexts()
  }

  func setHeaderSubtitle(_ value: String) {
    chatSubtitleText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    updateHeaderTexts()
  }

  func setProfileName(_ value: String) {
    profileNameText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    updateHeaderTexts()
    updateProfileTexts()
  }

  func setProfileHandle(_ value: String) {
    profileHandleText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    updateProfileTexts()
  }

  func setProfileBio(_ value: String) {
    profileBioText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    updateProfileTexts()
  }

  func setAvatarUri(_ value: String?) {
    avatarUri = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    updateAvatarViews()
  }

  func setIsOnline(_ value: Bool) {
    if enginePeerUserId.isEmpty {
      isOnline = value
      engineLastSeenTimestampMs = nil
      updateHeaderTexts()
      updateProfileTexts()
      return
    } else {
      refreshPresenceStateFromEngine(force: true)
      return
    }
  }

  func setIsChatMuted(_ value: Bool) {
    if isChatMuted == value { return }
    isChatMuted = value
    updateProfileTexts()
  }

  func setPage(_ value: String, animated: Bool) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let nextPage: ChatMainPage = normalized == "profile" ? .profile : .chat

    let now = CACurrentMediaTime()
    if let pendingTarget = pendingNativePageTarget, now < pendingNativePageLockUntil,
      nextPage != pendingTarget
    {
      return
    }

    if let pendingTarget = pendingNativePageTarget, nextPage == pendingTarget {
      pendingNativePageTarget = nil
      pendingNativePageLockUntil = 0.0
    }

    guard nextPage != currentPage else { return }
    currentPage = nextPage
    applyPageState(animated: animated, emitEvent: true)
  }

  // MARK: - View wiring

  private func configureView() {
    backgroundColor = .clear

    layer.insertSublayer(rootWallpaperLayer, at: 0)

    addSubview(pagesHost)
    pagesHost.clipsToBounds = false

    pagesHost.addSubview(chatPage)
    chatPage.addSubview(chatListView)

    pagesHost.addSubview(profilePage)
    profilePage.addSubview(profileScrollView)
    profileScrollView.addSubview(profileContentView)
    profilePage.isHidden = true
    profilePage.alpha = 0
    profileWallpaperPatternLayer.mask = profileWallpaperPatternMaskLayer
    profileWallpaperPatternMaskLayer.contentsGravity = .resizeAspectFill
    profileWallpaperPatternMaskLayer.contentsScale = UIScreen.main.scale
    profilePage.layer.insertSublayer(profileWallpaperLayer, at: 0)
    profilePage.layer.insertSublayer(profileWallpaperPatternLayer, above: profileWallpaperLayer)

    addSubview(headerContainer)
    headerContainer.clipsToBounds = false
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

    headerContentView.addSubview(backButton)
    headerContentView.addSubview(menuButton)
    headerContentView.addSubview(titleButton)
    headerContentView.addSubview(avatarButton)

    [backButton, titleButton, avatarButton, menuButton].forEach { button in
      button.backgroundColor = .clear
      button.contentHorizontalAlignment = .center
      button.contentVerticalAlignment = .center
      button.clipsToBounds = true
    }

    backGlassView.isUserInteractionEnabled = false
    backGlassView.clipsToBounds = true
    backButton.addSubview(backGlassView)
    backButton.sendSubviewToBack(backGlassView)

    backPressedOverlayView.isUserInteractionEnabled = false
    backPressedOverlayView.backgroundColor = headerPressedOverlayColor
    backPressedOverlayView.alpha = 0
    backButton.addSubview(backPressedOverlayView)

    titleGlassView.isUserInteractionEnabled = false
    titleGlassView.clipsToBounds = true
    titleButton.addSubview(titleGlassView)
    titleButton.sendSubviewToBack(titleGlassView)

    titlePressedOverlayView.isUserInteractionEnabled = false
    titlePressedOverlayView.backgroundColor = headerPressedOverlayColor
    titlePressedOverlayView.alpha = 0
    titleButton.addSubview(titlePressedOverlayView)

    avatarGlassView.isUserInteractionEnabled = false
    avatarGlassView.clipsToBounds = true
    avatarButton.addSubview(avatarGlassView)
    avatarButton.sendSubviewToBack(avatarGlassView)

    avatarPressedOverlayView.isUserInteractionEnabled = false
    avatarPressedOverlayView.backgroundColor = headerPressedOverlayColor
    avatarPressedOverlayView.alpha = 0
    avatarButton.addSubview(avatarPressedOverlayView)

    menuGlassView.isUserInteractionEnabled = false
    menuGlassView.clipsToBounds = true
    menuButton.addSubview(menuGlassView)
    menuButton.sendSubviewToBack(menuGlassView)

    menuPressedOverlayView.isUserInteractionEnabled = false
    menuPressedOverlayView.backgroundColor = headerPressedOverlayColor
    menuPressedOverlayView.alpha = 0
    menuButton.addSubview(menuPressedOverlayView)

    titleButton.addSubview(chatHeaderStack)
    titleButton.addSubview(profileHeaderStack)

    backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    backButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)
    titleButton.addTarget(self, action: #selector(handleAvatarPressed), for: .touchUpInside)
    menuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
    menuButton.addTarget(self, action: #selector(handleMenuPressed), for: .touchUpInside)

    avatarButton.addTarget(self, action: #selector(handleAvatarPressed), for: .touchUpInside)
    avatarButton.addSubview(avatarImageView)
    avatarButton.addSubview(avatarFallbackIconView)
    avatarButton.bringSubviewToFront(avatarPressedOverlayView)
    menuButton.bringSubviewToFront(menuPressedOverlayView)
    backButton.bringSubviewToFront(backPressedOverlayView)
    titleButton.bringSubviewToFront(titlePressedOverlayView)

    let backSymbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    backButton.setPreferredSymbolConfiguration(backSymbolConfig, forImageIn: .normal)
    let menuSymbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    menuButton.setPreferredSymbolConfiguration(menuSymbolConfig, forImageIn: .normal)
    avatarImageView.contentMode = .scaleAspectFill
    avatarImageView.isHidden = true

    avatarFallbackIconView.contentMode = .scaleAspectFit
    avatarFallbackIconView.image = UIImage(systemName: "person.fill")
    avatarFallbackIconView.isHidden = false

    [chatHeaderStack, profileHeaderStack].forEach { stack in
      stack.axis = .vertical
      stack.alignment = .center
      stack.distribution = .fill
      stack.spacing = -1
    }

    [chatTitleLabel, profileTitleLabel].forEach { label in
      label.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
      label.textAlignment = .center
      label.lineBreakMode = .byTruncatingTail
    }
    [chatSubtitleLabel, profileSubtitleLabel].forEach { label in
      label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
      label.textAlignment = .center
      label.lineBreakMode = .byTruncatingTail
    }

    chatHeaderStack.addArrangedSubview(chatTitleLabel)
    chatHeaderStack.addArrangedSubview(chatSubtitleLabel)
    profileHeaderStack.addArrangedSubview(profileTitleLabel)
    profileHeaderStack.addArrangedSubview(profileSubtitleLabel)

    profileScrollView.showsVerticalScrollIndicator = false
    profileScrollView.alwaysBounceVertical = true

    profileContentView.addSubview(profileAvatarView)
    profileAvatarView.addSubview(profileAvatarImageView)
    profileAvatarView.addSubview(profileAvatarFallbackIconView)
    profileAvatarView.addSubview(profileOnlineDotView)
    profileContentView.addSubview(profileNameLabel)
    profileContentView.addSubview(profileHandleLabel)
    profileContentView.addSubview(profileBioLabel)
    profileContentView.addSubview(profileActionsStack)
    [profileMuteButton, profileSearchButton, profileAudioCallButton, profileVideoCallButton].forEach
    {
      profileActionsStack.addArrangedSubview($0)
    }
    profileContentView.addSubview(profileIdentityCard)
    profileIdentityCard.addSubview(profileUsernameRow)
    profileIdentityCard.addSubview(profileBioRow)
    profileContentView.addSubview(profileTabsCard)
    profileTabsCard.addSubview(profileTabsScrollView)
    profileTabsScrollView.addSubview(profileTabsStack)
    profileContentView.addSubview(profileTabContentContainer)
    profileTabContentContainer.addSubview(profileTabPlaceholderLabel)

    profileContentView.addSubview(profileAgentPromptNode)
    profileAgentPromptNode.delegate = self

    profileAvatarView.clipsToBounds = true
    profileAvatarImageView.clipsToBounds = true
    profileAvatarImageView.contentMode = .scaleAspectFill
    profileAvatarFallbackIconView.contentMode = .scaleAspectFit
    profileAvatarFallbackIconView.image = UIImage(systemName: "person.fill")
    profileAvatarFallbackIconView.isHidden = false
    profileOnlineDotView.layer.cornerCurve = .continuous

    profileNameLabel.textAlignment = .center
    profileNameLabel.font = UIFont.systemFont(ofSize: 30, weight: .bold)
    profileHandleLabel.textAlignment = .center
    profileHandleLabel.font = UIFont.systemFont(ofSize: 18, weight: .medium)
    profileBioLabel.textAlignment = .center
    profileBioLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    profileBioLabel.numberOfLines = 0

    profileActionsStack.axis = .horizontal
    profileActionsStack.alignment = .fill
    profileActionsStack.distribution = .fillEqually
    profileActionsStack.spacing = 8

    profileMuteButton.configure(title: "Mute", symbol: "bell.slash")
    profileSearchButton.configure(title: "Search", symbol: "magnifyingglass")
    profileAudioCallButton.configure(title: "Call", symbol: "phone")
    profileVideoCallButton.configure(title: "Video", symbol: "video")
    profileMuteButton.addTarget(
      self, action: #selector(handleProfileMutePressed), for: .touchUpInside)
    profileSearchButton.addTarget(
      self, action: #selector(handleProfileSearchPressed), for: .touchUpInside)
    profileAudioCallButton.addTarget(
      self, action: #selector(handleProfileAudioCallPressed), for: .touchUpInside)
    profileVideoCallButton.addTarget(
      self, action: #selector(handleProfileVideoCallPressed), for: .touchUpInside)

    profileIdentityCard.clipsToBounds = true
    profileIdentityCard.layer.cornerCurve = .continuous

    profileUsernameRow.addTarget(
      self, action: #selector(handleProfileUsernamePressed), for: .touchUpInside)
    profileBioRow.isEnabled = false

    profileTabsCard.clipsToBounds = true
    profileTabsCard.layer.cornerCurve = .continuous
    profileTabsScrollView.showsHorizontalScrollIndicator = false
    profileTabsScrollView.alwaysBounceHorizontal = true

    profileTabPlaceholderLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    profileTabPlaceholderLabel.numberOfLines = 0
    profileTabPlaceholderLabel.textAlignment = .left
    profileTabPlaceholderLabel.text =
      "Loading shared media and files from native encrypted cache..."

    profileAgentPromptNode.isHidden = true

    rebuildProfileTabs()
    configureHeaderPressFeedback()
    refreshHeaderGlass()
    updateAvatarViews()
  }

  private func syncListDispatchers() {
    chatListView.onNativeEvent = onNativeEvent
    chatListView.onViewportChanged = onViewportChanged
  }

  private func startObservingChatEngine() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineDidChange(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )
  }

  @objc private func handleChatEngineDidChange(_ notification: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineDidChange(notification)
      }
      return
    }
    refreshPresenceStateFromEngine()
    guard !engineChatId.isEmpty else { return }
    if let changedChatIdRaw = notification.userInfo?["chatId"] as? String,
      !changedChatIdRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      changedChatIdRaw.trimmingCharacters(in: .whitespacesAndNewlines) != engineChatId
    {
      return
    }
    refreshProfileSummaryFromEngine()
  }

  private func refreshPresenceStateFromEngine(force: Bool = false) {
    guard !enginePeerUserId.isEmpty else { return }
    let nextOnline = ChatEngine.shared.isUserOnline(userId: enginePeerUserId)
    let nextLastSeen = ChatEngine.shared.lastSeenTimestampMs(userId: enginePeerUserId)
    guard
      force || nextOnline != isOnline || nextLastSeen != engineLastSeenTimestampMs
    else { return }
    isOnline = nextOnline
    engineLastSeenTimestampMs = nextLastSeen
    updateHeaderTexts()
    updateProfileTexts()
  }

  private func refreshProfileSummaryFromEngine(force: Bool = false) {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else {
      if force || profileSummaryMessageCount != 0 || profileSummaryMediaCount != 0
        || profileSummaryFileCount != 0 || profileSummaryLinkCount != 0
        || profileSummaryHistoryLoaded || !profileSummaryRecentFiles.isEmpty
        || !profileMediaItems.isEmpty
        || !profileMusicItems.isEmpty || !profileFileItems.isEmpty || !profileLinkItems.isEmpty
        || !profilePinnedItems.isEmpty
      {
        profileSummaryMessageCount = 0
        profileSummaryMediaCount = 0
        profileSummaryFileCount = 0
        profileSummaryLinkCount = 0
        profileSummaryRecentFiles = []
        profileSummaryHistoryLoaded = false
        profileMediaItems = []
        profileMusicItems = []
        profileFileItems = []
        profileLinkItems = []
        profilePinnedItems = []
        rebuildProfileTabs()
        profileTabContentNeedsReload = true
        updateProfileTexts()
      }
      return
    }

    let summary = ChatEngine.shared.getChatProfileSummary(["chatId": chatId])
    let nextMessageCount = (summary["totalMessages"] as? Int) ?? 0
    let nextMediaCount = (summary["mediaCount"] as? Int) ?? 0
    let nextFileCount = (summary["fileCount"] as? Int) ?? 0
    let nextLinkCount = (summary["linkCount"] as? Int) ?? 0
    let nextRecentFiles = (summary["recentFiles"] as? [String]) ?? []
    let nextHistoryLoaded = (summary["historyLoaded"] as? Bool) ?? false
    let rows = ChatEngine.shared.getChatRows(["chatId": chatId])
    let parsed = buildProfileContent(rows: rows)

    let summaryChanged =
      nextMessageCount != profileSummaryMessageCount
      || nextMediaCount != profileSummaryMediaCount
      || nextFileCount != profileSummaryFileCount
      || nextLinkCount != profileSummaryLinkCount
      || nextHistoryLoaded != profileSummaryHistoryLoaded
      || nextRecentFiles != profileSummaryRecentFiles
    let contentChanged =
      parsed.mediaItems != profileMediaItems
      || parsed.musicItems != profileMusicItems
      || parsed.fileItems != profileFileItems
      || parsed.linkItems != profileLinkItems
      || parsed.pinnedItems != profilePinnedItems

    guard force || summaryChanged || contentChanged else { return }

    profileSummaryMessageCount = nextMessageCount
    profileSummaryMediaCount = nextMediaCount
    profileSummaryFileCount = nextFileCount
    profileSummaryLinkCount = nextLinkCount
    profileSummaryRecentFiles = nextRecentFiles
    profileSummaryHistoryLoaded = nextHistoryLoaded
    profileMediaItems = parsed.mediaItems
    profileMusicItems = parsed.musicItems
    profileFileItems = parsed.fileItems
    profileLinkItems = parsed.linkItems
    profilePinnedItems = parsed.pinnedItems
    rebuildProfileTabs()
    profileTabContentNeedsReload = true
    updateProfileTexts()
  }

  private func buildProfileContent(rows: [[String: Any]]) -> (
    mediaItems: [ChatMainProfileMediaItem],
    musicItems: [ChatMainProfileFileItem],
    fileItems: [ChatMainProfileFileItem],
    linkItems: [ChatMainProfileLinkItem],
    pinnedItems: [ChatMainProfilePinnedItem]
  ) {
    var mediaItems: [ChatMainProfileMediaItem] = []
    var musicItems: [ChatMainProfileFileItem] = []
    var fileItems: [ChatMainProfileFileItem] = []
    var linkItems: [ChatMainProfileLinkItem] = []
    var pinnedItems: [ChatMainProfilePinnedItem] = []
    var seenLinks = Set<String>()

    for row in rows.reversed() {
      guard normalizedProfileString(row["kind"]) == "message" else { continue }
      guard let message = row["message"] as? [String: Any] else { continue }

      let messageId = normalizedProfileString(message["id"]) ?? UUID().uuidString
      let type = normalizedProfileString(message["type"])?.lowercased() ?? "text"
      let text = normalizedProfileString(message["text"]) ?? ""
      let caption = normalizedProfileString(message["caption"]) ?? ""
      let mediaUrl = normalizedProfileString(message["mediaUrl"]) ?? ""
      let fileNameRaw = normalizedProfileString(message["fileName"])
      let timestampMs = profileTimestampMs(from: message)
      let dateSubtitle = formatProfileDate(timestampMs)

      if !mediaUrl.isEmpty && ["image", "video", "gif", "sticker"].contains(type) {
        mediaItems.append(
          ChatMainProfileMediaItem(
            messageId: messageId,
            type: type,
            mediaUrl: mediaUrl
          ))
      }

      if type == "music" || type == "file" {
        let fileName =
          (fileNameRaw?.isEmpty == false
            ? fileNameRaw! : "\(type.uppercased())-\(messageId.prefix(6))")
        let fileItem = ChatMainProfileFileItem(
          messageId: messageId,
          type: type,
          fileName: fileName,
          mediaUrl: mediaUrl.isEmpty ? nil : mediaUrl,
          fileSize: parseInt64(message["fileSize"]),
          timestampMs: timestampMs
        )
        if type == "music" {
          musicItems.append(fileItem)
        } else {
          fileItems.append(fileItem)
        }
      }

      if let url = firstDetectedURL(from: text) ?? firstDetectedURL(from: caption)
        ?? firstDetectedURL(from: mediaUrl)
      {
        if !seenLinks.contains(url) {
          seenLinks.insert(url)
          linkItems.append(
            ChatMainProfileLinkItem(
              messageId: messageId,
              url: url,
              subtitle: dateSubtitle
            ))
        }
      }

      let isPinned = (message["isPinned"] as? Bool) == true || (message["pinned"] as? Bool) == true
      if isPinned {
        let pinnedText =
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? text
          : (caption.isEmpty ? type.capitalized : caption)
        pinnedItems.append(
          ChatMainProfilePinnedItem(
            messageId: messageId,
            text: pinnedText,
            subtitle: dateSubtitle
          ))
      }
    }

    return (mediaItems, musicItems, fileItems, linkItems, pinnedItems)
  }

  private func normalizedProfileString(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber {
      return number.stringValue
    }
    return nil
  }

  private func parseInt64(_ value: Any?) -> Int64? {
    guard let value else { return nil }
    if let intValue = value as? Int64 { return intValue }
    if let intValue = value as? Int { return Int64(intValue) }
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String, let parsed = Int64(string) { return parsed }
    return nil
  }

  private func profileTimestampMs(from message: [String: Any]) -> Int64 {
    if let direct = parseInt64(message["timestampMs"]) { return direct }
    if let direct = parseInt64(message["timestamp_ms"]) { return direct }
    if let direct = parseInt64(message["timestamp"]) {
      return direct < 2_000_000_000 ? direct * 1000 : direct
    }
    if let timestampString = message["timestamp"] as? String {
      if let parsedDouble = Double(timestampString) {
        let ms = parsedDouble < 2_000_000_000 ? parsedDouble * 1000.0 : parsedDouble
        return Int64(ms)
      }
      let iso8601 = ISO8601DateFormatter()
      if let parsedDate = iso8601.date(from: timestampString) {
        return Int64(parsedDate.timeIntervalSince1970 * 1000.0)
      }
    }
    return Int64(Date().timeIntervalSince1970 * 1000.0)
  }

  private func firstDetectedURL(from source: String?) -> String? {
    guard let source, !source.isEmpty else { return nil }
    guard
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return nil }
    let range = NSRange(location: 0, length: (source as NSString).length)
    guard let match = detector.firstMatch(in: source, options: [], range: range) else { return nil }
    return match.url?.absoluteString
  }

  private func formatProfileDate(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    return Self.profileListDateFormatter.string(from: date)
  }

  private func formatFileSize(_ bytes: Int64?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 {
      return String(format: "%.1f KB", Double(bytes) / 1024.0)
    }
    return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
  }

  private func profileTabCount(_ tab: ChatMainProfileTab) -> Int {
    switch tab {
    case .media: return profileMediaItems.count
    case .music: return profileMusicItems.count
    case .files: return profileFileItems.count
    case .links: return profileLinkItems.count
    case .pinned: return profilePinnedItems.count
    }
  }

  private func profileTabLabel(_ tab: ChatMainProfileTab) -> String {
    switch tab {
    case .media: return "Media"
    case .music: return "Music"
    case .files: return "Files"
    case .links: return "Links"
    case .pinned: return "Pinned"
    }
  }

  private func rebuildProfileTabs() {
    let nextVisibleTabs = ChatMainProfileTab.allCases.filter { profileTabCount($0) > 0 }
    let needsStructureUpdate = nextVisibleTabs != profileVisibleTabs
    profileVisibleTabs = nextVisibleTabs

    if !profileVisibleTabs.isEmpty, !profileVisibleTabs.contains(profileActiveTab) {
      profileActiveTab = profileVisibleTabs[0]
      profileTabContentNeedsReload = true
    }

    if needsStructureUpdate {
      profileTabsStack.subviews.forEach { $0.removeFromSuperview() }
      profileTabButtons.removeAll()

      for tab in profileVisibleTabs {
        let button = ChatMainProfileTabNode()
        button.setTitle("\(profileTabLabel(tab)) \(profileTabCount(tab))")
        button.addTarget(self, action: #selector(handleProfileTabPressed(_:)), for: .touchUpInside)
        profileTabsStack.addSubview(button)
        profileTabButtons[tab] = button
      }
    } else {
      for tab in profileVisibleTabs {
        profileTabButtons[tab]?.setTitle("\(profileTabLabel(tab)) \(profileTabCount(tab))")
      }
    }

    applyProfileTabTheme()
    setNeedsLayout()
  }

  private func applyProfileTabTheme() {
    let activeTextColor = appearance.textColorThem
    let normalTextColor = appearance.timeColorThem.withAlphaComponent(0.95)
    let activeBackgroundColor = appearance.textColorThem.withAlphaComponent(0.12)
    for tab in profileVisibleTabs {
      guard let button = profileTabButtons[tab] else { continue }
      button.isActive = tab == profileActiveTab
      button.applyTheme(
        activeTextColor: activeTextColor,
        normalTextColor: normalTextColor,
        activeBackgroundColor: activeBackgroundColor
      )
    }
  }

  @objc private func handleProfileTabPressed(_ sender: ChatMainProfileTabNode) {
    guard
      let pair = profileTabButtons.first(where: { $0.value === sender }),
      pair.key != profileActiveTab
    else { return }
    profileActiveTab = pair.key
    profileTabContentNeedsReload = true
    applyProfileTabTheme()
    setNeedsLayout()
  }

  private func reloadProfileTabContentIfNeeded(contentWidth: CGFloat) -> CGFloat {
    let normalizedWidth = max(1.0, contentWidth)
    if !profileTabContentNeedsReload && abs(normalizedWidth - profileLastTabContentWidth) < 0.5 {
      return profileTabContentContainer.bounds.height
    }

    profileTabContentNeedsReload = false
    profileLastTabContentWidth = normalizedWidth

    let cardBg = appearance.bubbleThemColor.withAlphaComponent(0.58)
    let textColor = appearance.textColorThem
    let subtitleColor = appearance.timeColorThem.withAlphaComponent(0.9)
    let separatorColor = appearance.timeColorThem.withAlphaComponent(0.18)
    let highlightColor = appearance.textColorThem.withAlphaComponent(0.06)

    profileTabContentContainer.subviews.forEach { subview in
      if subview !== profileTabPlaceholderLabel {
        subview.removeFromSuperview()
      }
    }

    profileTabPlaceholderLabel.frame = .zero
    profileTabPlaceholderLabel.isHidden = true
    profileTabPlaceholderLabel.textColor = subtitleColor

    if !profileSummaryHistoryLoaded {
      profileTabPlaceholderLabel.text =
        "Loading shared media and files from native encrypted cache..."
      profileTabPlaceholderLabel.isHidden = false
      profileTabPlaceholderLabel.frame = CGRect(
        x: 0.0, y: 0.0, width: normalizedWidth, height: 48.0)
      profileTabContentContainer.frame = CGRect(
        x: profileTabContentContainer.frame.minX,
        y: profileTabContentContainer.frame.minY,
        width: normalizedWidth,
        height: 48.0
      )
      return 48.0
    }

    guard !profileVisibleTabs.isEmpty else {
      profileTabPlaceholderLabel.text = "No shared content yet."
      profileTabPlaceholderLabel.isHidden = false
      profileTabPlaceholderLabel.frame = CGRect(
        x: 0.0, y: 0.0, width: normalizedWidth, height: 40.0)
      profileTabContentContainer.frame = CGRect(
        x: profileTabContentContainer.frame.minX,
        y: profileTabContentContainer.frame.minY,
        width: normalizedWidth,
        height: 40.0
      )
      return 40.0
    }

    switch profileActiveTab {
    case .media:
      let items = profileMediaItems
      guard !items.isEmpty else {
        profileTabPlaceholderLabel.text = "No media yet."
        profileTabPlaceholderLabel.isHidden = false
        profileTabPlaceholderLabel.frame = CGRect(
          x: 0.0, y: 0.0, width: normalizedWidth, height: 40.0)
        profileTabContentContainer.frame = CGRect(
          x: profileTabContentContainer.frame.minX,
          y: profileTabContentContainer.frame.minY,
          width: normalizedWidth,
          height: 40.0
        )
        return 40.0
      }

      let gridGap: CGFloat = 3.0
      let columns: CGFloat = 3.0
      let cellSize = floor((normalizedWidth - (gridGap * (columns - 1.0))) / columns)
      for (index, item) in items.enumerated() {
        let cell = ChatMainProfileMediaCellNode()
        let column = CGFloat(index % Int(columns))
        let row = CGFloat(index / Int(columns))
        cell.frame = CGRect(
          x: column * (cellSize + gridGap),
          y: row * (cellSize + gridGap),
          width: cellSize,
          height: cellSize
        )
        cell.tag = index
        cell.configure(urlString: item.mediaUrl, isVideo: item.type == "video")
        cell.applyTheme(
          placeholderTintColor: appearance.timeColorThem.withAlphaComponent(0.72),
          placeholderBackgroundColor: appearance.textColorThem.withAlphaComponent(0.06)
        )
        cell.addTarget(
          self, action: #selector(handleProfileMediaCellPressed(_:)), for: .touchUpInside)
        profileTabContentContainer.addSubview(cell)
      }
      let rows = ceil(CGFloat(items.count) / columns)
      let totalHeight = max(0.0, rows * cellSize + max(0.0, rows - 1.0) * gridGap)
      profileTabContentContainer.frame = CGRect(
        x: profileTabContentContainer.frame.minX,
        y: profileTabContentContainer.frame.minY,
        width: normalizedWidth,
        height: totalHeight
      )
      return totalHeight

    case .music, .files, .links, .pinned:
      let card = UIView()
      card.backgroundColor = cardBg
      card.layer.cornerRadius = 24.0
      card.layer.cornerCurve = .continuous
      profileTabContentContainer.addSubview(card)

      var rows: [(title: String, subtitle: String, titleColor: UIColor?, selector: Selector)] = []
      switch profileActiveTab {
      case .music:
        rows = profileMusicItems.map { item in
          let subtitleParts = [formatFileSize(item.fileSize), formatProfileDate(item.timestampMs)]
            .compactMap { $0 }
          return (
            item.fileName,
            subtitleParts.joined(separator: " · "),
            nil,
            #selector(handleProfileMusicRowPressed(_:))
          )
        }
      case .files:
        rows = profileFileItems.map { item in
          let subtitleParts = [formatFileSize(item.fileSize), formatProfileDate(item.timestampMs)]
            .compactMap { $0 }
          return (
            item.fileName,
            subtitleParts.joined(separator: " · "),
            nil,
            #selector(handleProfileFileRowPressed(_:))
          )
        }
      case .links:
        rows = profileLinkItems.map { item in
          (
            item.url,
            item.subtitle,
            appearance.bubbleMeGradient.last ?? appearance.textColorMe,
            #selector(handleProfileLinkRowPressed(_:))
          )
        }
      case .pinned:
        rows = profilePinnedItems.map { item in
          (
            item.text,
            item.subtitle,
            nil,
            #selector(handleProfilePinnedRowPressed(_:))
          )
        }
      case .media:
        rows = []
      }

      guard !rows.isEmpty else {
        profileTabPlaceholderLabel.text = "No content yet."
        profileTabPlaceholderLabel.isHidden = false
        profileTabPlaceholderLabel.frame = CGRect(
          x: 0.0, y: 0.0, width: normalizedWidth, height: 40.0)
        card.removeFromSuperview()
        profileTabContentContainer.frame = CGRect(
          x: profileTabContentContainer.frame.minX,
          y: profileTabContentContainer.frame.minY,
          width: normalizedWidth,
          height: 40.0
        )
        return 40.0
      }

      let rowHeight: CGFloat = 62.0
      for (index, row) in rows.enumerated() {
        let rowNode = ChatMainProfileListRowNode()
        rowNode.frame = CGRect(
          x: 0.0,
          y: CGFloat(index) * rowHeight,
          width: normalizedWidth,
          height: rowHeight
        )
        rowNode.tag = index
        rowNode.configure(
          title: row.title,
          subtitle: row.subtitle,
          titleColor: row.titleColor,
          showsSeparator: index < rows.count - 1
        )
        rowNode.applyTheme(
          titleColor: textColor,
          subtitleColor: subtitleColor,
          separatorColor: separatorColor,
          highlightedColor: highlightColor
        )
        rowNode.addTarget(self, action: row.selector, for: .touchUpInside)
        card.addSubview(rowNode)
      }
      let totalHeight = rowHeight * CGFloat(rows.count)
      card.frame = CGRect(x: 0.0, y: 0.0, width: normalizedWidth, height: totalHeight)
      profileTabContentContainer.frame = CGRect(
        x: profileTabContentContainer.frame.minX,
        y: profileTabContentContainer.frame.minY,
        width: normalizedWidth,
        height: totalHeight
      )
      return totalHeight
    }
  }

  @objc private func handleProfileMediaCellPressed(_ sender: ChatMainProfileMediaCellNode) {
    let index = sender.tag
    guard index >= 0, index < profileMediaItems.count else { return }
    let item = profileMediaItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "media",
      "messageId": item.messageId,
      "url": item.mediaUrl,
    ])
  }

  @objc private func handleProfileMusicRowPressed(_ sender: ChatMainProfileListRowNode) {
    let index = sender.tag
    guard index >= 0, index < profileMusicItems.count else { return }
    let item = profileMusicItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "music",
      "messageId": item.messageId,
      "url": item.mediaUrl ?? "",
      "fileName": item.fileName,
    ])
  }

  @objc private func handleProfileFileRowPressed(_ sender: ChatMainProfileListRowNode) {
    let index = sender.tag
    guard index >= 0, index < profileFileItems.count else { return }
    let item = profileFileItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "files",
      "messageId": item.messageId,
      "url": item.mediaUrl ?? "",
      "fileName": item.fileName,
    ])
  }

  @objc private func handleProfileLinkRowPressed(_ sender: ChatMainProfileListRowNode) {
    let index = sender.tag
    guard index >= 0, index < profileLinkItems.count else { return }
    let item = profileLinkItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "links",
      "messageId": item.messageId,
      "url": item.url,
    ])
  }

  @objc private func handleProfilePinnedRowPressed(_ sender: ChatMainProfileListRowNode) {
    let index = sender.tag
    guard index >= 0, index < profilePinnedItems.count else { return }
    let item = profilePinnedItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "pinned",
      "messageId": item.messageId,
      "text": item.text,
    ])
  }

  private func refreshHeaderGlass() {
    if #available(iOS 26.0, *) {
      let backEffect = UIGlassEffect()
      backEffect.isInteractive = true
      backGlassView.effect = backEffect

      let centerEffect = UIGlassEffect()
      centerEffect.isInteractive = true
      titleGlassView.effect = centerEffect

      let avatarEffect = UIGlassEffect()
      avatarEffect.isInteractive = true
      avatarGlassView.effect = avatarEffect

      let menuEffect = UIGlassEffect()
      menuEffect.isInteractive = true
      menuGlassView.effect = menuEffect
    } else {
      backGlassView.effect = UIBlurEffect(style: .systemMaterial)
      titleGlassView.effect = UIBlurEffect(style: .systemMaterial)
      avatarGlassView.effect = UIBlurEffect(style: .systemMaterial)
      menuGlassView.effect = UIBlurEffect(style: .systemMaterial)
    }
  }

  private func configureHeaderPressFeedback() {
    let controls: [UIControl] = [backButton, titleButton, avatarButton, menuButton]
    controls.forEach { control in
      control.addTarget(
        self, action: #selector(handleHeaderPressDown(_:)), for: [.touchDown, .touchDragEnter])
      control.addTarget(
        self,
        action: #selector(handleHeaderPressUp(_:)),
        for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit, .touchDragOutside]
      )
    }
  }

  private func markPendingNativePageChange(_ page: ChatMainPage) {
    pendingNativePageTarget = page
    pendingNativePageLockUntil = CACurrentMediaTime() + 2.0
  }

  @objc private func handleHeaderPressDown(_ sender: UIControl) {
    setHeaderControlPressed(sender, isPressed: true)
  }

  @objc private func handleHeaderPressUp(_ sender: UIControl) {
    setHeaderControlPressed(sender, isPressed: false)
  }

  private func setHeaderControlPressed(_ control: UIControl, isPressed: Bool) {
    let duration: TimeInterval = isPressed ? 0.1 : 0.22
    let damping: CGFloat = isPressed ? 1.0 : 0.72

    UIView.animate(
      withDuration: duration,
      delay: 0,
      usingSpringWithDamping: damping,
      initialSpringVelocity: 0.25,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      if control === self.backButton {
        let scale: CGFloat = isPressed ? 0.9 : 1.0
        self.backButton.imageView?.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.backGlassView.alpha = isPressed ? 0.92 : 1.0
        self.backPressedOverlayView.alpha = isPressed ? 1.0 : 0.0
      } else if control === self.titleButton {
        let scale: CGFloat = isPressed ? 0.992 : 1.0
        self.titleButton.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.titleGlassView.alpha = isPressed ? 0.92 : 1.0
        self.titlePressedOverlayView.alpha = isPressed ? 1.0 : 0.0
      } else if control === self.avatarButton {
        let scale: CGFloat = isPressed ? 0.96 : 1.0
        self.avatarButton.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.avatarGlassView.alpha = isPressed ? 0.92 : 1.0
        self.avatarPressedOverlayView.alpha = isPressed ? 1.0 : 0.0
      } else if control === self.menuButton {
        let scale: CGFloat = isPressed ? 0.96 : 1.0
        self.menuButton.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.menuGlassView.alpha = isPressed ? 0.92 : 1.0
        self.menuPressedOverlayView.alpha = isPressed ? 1.0 : 0.0
      }
    }
  }

  private func layoutChrome() {
    let safeTop = safeAreaInsets.top
    let headerHeight = safeTop + 60.0
    headerContainer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
    headerMaskView.frame = headerContainer.bounds
    headerMaskBlurView.frame = headerMaskView.bounds
    headerMaskOverlayView.frame = headerMaskBlurView.bounds
    headerMaskGradientLayer.frame = headerMaskView.bounds

    let contentY = safeTop + 8.0
    headerContentView.frame = CGRect(
      x: 12.0, y: contentY, width: max(0.0, bounds.width - 24.0), height: 44.0)

    backButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    avatarButton.frame = CGRect(
      x: max(0.0, headerContentView.bounds.width - 44.0), y: 0.0, width: 44.0, height: 44.0)
    menuButton.frame = CGRect(
      x: max(0.0, avatarButton.frame.minX - 8.0 - 44.0), y: 0.0, width: 44.0, height: 44.0)

    let maxCenterWidth = max(0.0, headerContentView.bounds.width * 0.45)
    let chatReq = max(
      chatTitleLabel.intrinsicContentSize.width, chatSubtitleLabel.intrinsicContentSize.width)
    let profileReq = max(
      profileTitleLabel.intrinsicContentSize.width, profileSubtitleLabel.intrinsicContentSize.width)
    let maxContentReq = max(chatReq, profileReq) + 36.0  // 18 tracking padding on each side
    let centerWidth = min(maxCenterWidth, max(60.0, maxContentReq))
    titleButton.frame = CGRect(
      x: (headerContentView.bounds.width - centerWidth) * 0.5,
      y: 0.0,
      width: centerWidth,
      height: 44.0
    )

    [backButton, avatarButton, titleButton, menuButton].forEach { control in
      control.layer.cornerRadius = control.bounds.height / 2.0
    }
    [
      backGlassView, avatarGlassView, titleGlassView, menuGlassView, backPressedOverlayView,
      avatarPressedOverlayView,
      menuPressedOverlayView,
      titlePressedOverlayView,
    ]
    .forEach { view in
      view.frame = view.superview?.bounds ?? .zero
      view.layer.cornerRadius = (view.superview?.bounds.height ?? 0) / 2.0
    }

    avatarButton.layer.cornerRadius = 22.0
    avatarImageView.frame = avatarButton.bounds
    avatarFallbackIconView.frame = avatarButton.bounds.insetBy(dx: 12.0, dy: 12.0)
    avatarPressedOverlayView.frame = avatarButton.bounds
    if let imageView = backButton.imageView {
      backButton.bringSubviewToFront(imageView)
    }
    backButton.bringSubviewToFront(backPressedOverlayView)

    let titleBounds = titleButton.bounds.insetBy(dx: 12.0, dy: 4.0)
    chatHeaderStack.frame = titleBounds
    profileHeaderStack.frame = titleBounds
  }

  private func layoutPages() {
    let safeTop = safeAreaInsets.top
    let headerHeight = safeTop + 60.0
    pagesHost.frame = CGRect(
      x: 0.0,
      y: headerHeight,
      width: bounds.width,
      height: max(0.0, bounds.height - headerHeight)
    )

    let pageWidth = pagesHost.bounds.width
    let pageHeight = pagesHost.bounds.height

    // Extend chatPage upward behind the header so its wallpaper
    // layer covers the full screen — no gap with a mismatched gradient.
    chatPage.frame = CGRect(
      x: 0.0, y: -headerHeight,
      width: pageWidth, height: pageHeight + headerHeight)
    chatListView.frame = chatPage.bounds

    profilePage.frame = CGRect(
      x: 0.0, y: -headerHeight,
      width: pageWidth, height: pageHeight + headerHeight)
    profileWallpaperLayer.frame = profilePage.bounds
    profileWallpaperPatternLayer.frame = profilePage.bounds
    profileWallpaperPatternMaskLayer.frame = profileWallpaperPatternLayer.bounds
    profileScrollView.frame = CGRect(
      x: 0.0, y: headerHeight,
      width: pageWidth, height: pageHeight)
  }

  private func layoutProfileContent() {
    let width = max(1.0, profileScrollView.bounds.width)
    let sideInset: CGFloat = 16.0
    let textInset: CGFloat = 24.0

    profileContentView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: 1.0)

    let avatarSize: CGFloat = 118.0
    profileAvatarView.frame = CGRect(
      x: (width - avatarSize) * 0.5, y: 30.0, width: avatarSize, height: avatarSize)
    profileAvatarView.layer.cornerRadius = avatarSize * 0.5
    profileAvatarImageView.frame = profileAvatarView.bounds
    profileAvatarFallbackIconView.frame = profileAvatarView.bounds.insetBy(dx: 30.0, dy: 30.0)
    let onlineDotSize: CGFloat = 20.0
    profileOnlineDotView.frame = CGRect(
      x: profileAvatarView.bounds.width - onlineDotSize - 4.0,
      y: profileAvatarView.bounds.height - onlineDotSize - 4.0,
      width: onlineDotSize,
      height: onlineDotSize
    )
    profileOnlineDotView.layer.cornerRadius = onlineDotSize * 0.5
    profileOnlineDotView.layer.borderWidth = 3.0

    profileNameLabel.frame = CGRect(
      x: textInset, y: profileAvatarView.frame.maxY + 16.0, width: width - (textInset * 2),
      height: 38.0
    )
    profileHandleLabel.frame = CGRect(
      x: textInset, y: profileNameLabel.frame.maxY + 2.0, width: width - (textInset * 2),
      height: 24.0)

    let bioSize = profileBioLabel.sizeThatFits(
      CGSize(width: width - (textInset * 2), height: 200.0))
    let bioHeight = profileBioLabel.isHidden ? 0.0 : max(0.0, min(120.0, bioSize.height))
    profileBioLabel.frame = CGRect(
      x: textInset, y: profileHandleLabel.frame.maxY + 10.0, width: width - (textInset * 2),
      height: bioHeight)

    profileActionsStack.frame = CGRect(
      x: sideInset,
      y: profileBioLabel.frame.maxY + 18.0,
      width: width - 32.0,
      height: 64.0
    )

    profileIdentityCard.frame = CGRect(
      x: sideInset,
      y: profileActionsStack.frame.maxY + 18.0,
      width: width - 32.0,
      height: 62.0
    )
    profileIdentityCard.layer.cornerRadius = 24.0
    profileUsernameRow.frame = CGRect(
      x: 0.0, y: 0.0, width: profileIdentityCard.bounds.width, height: 62.0)

    let hasBioRow = !profileBioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if hasBioRow {
      profileBioRow.isHidden = false
      profileBioRow.frame = CGRect(
        x: 0.0, y: profileUsernameRow.frame.maxY, width: profileIdentityCard.bounds.width,
        height: 62.0)
      profileIdentityCard.frame.size.height = 124.0
    } else {
      profileBioRow.isHidden = true
      profileIdentityCard.frame.size.height = 62.0
      profileBioRow.frame = .zero
    }

    var bottomAnchor = profileIdentityCard.frame.maxY

    let showTabsSection = !profileVisibleTabs.isEmpty || !profileSummaryHistoryLoaded
    if showTabsSection {
      profileTabsCard.isHidden = false
      profileTabContentContainer.isHidden = false

      profileTabsCard.frame = CGRect(
        x: sideInset,
        y: bottomAnchor + 18.0,
        width: width - 32.0,
        height: 50.0
      )
      profileTabsCard.layer.cornerRadius = 20.0

      profileTabsScrollView.frame = profileTabsCard.bounds.insetBy(dx: 6.0, dy: 6.0)
      let tabHeight = profileTabsScrollView.bounds.height
      var tabCursorX: CGFloat = 0.0
      for tab in profileVisibleTabs {
        guard let button = profileTabButtons[tab] else { continue }
        let title = "\(profileTabLabel(tab)) \(profileTabCount(tab))"
        let widthGuess = (title as NSString).size(withAttributes: [
          .font: UIFont.systemFont(ofSize: 16, weight: .medium)
        ]).width
        let buttonWidth = max(72.0, widthGuess + 32.0)
        button.frame = CGRect(x: tabCursorX, y: 0.0, width: buttonWidth, height: tabHeight)
        tabCursorX += buttonWidth + 6.0
      }
      profileTabsStack.frame = CGRect(
        x: 0.0, y: 0.0, width: max(profileTabsScrollView.bounds.width, tabCursorX),
        height: tabHeight)
      profileTabsScrollView.contentSize = CGSize(
        width: max(profileTabsScrollView.bounds.width, tabCursorX), height: tabHeight)

      profileTabContentContainer.frame = CGRect(
        x: sideInset,
        y: profileTabsCard.frame.maxY + 14.0,
        width: width - 32.0,
        height: 0.0
      )
      let tabContentHeight = reloadProfileTabContentIfNeeded(
        contentWidth: profileTabContentContainer.bounds.width)
      profileTabContentContainer.frame.size.height = tabContentHeight
      bottomAnchor = profileTabContentContainer.frame.maxY
    } else {
      profileTabsCard.isHidden = true
      profileTabContentContainer.isHidden = true
    }

    let hPad: CGFloat = 16.0
    let sectionPad: CGFloat = 18.0
    let contentWidth = width

    if !profileAgentPromptNode.isHidden {
      let promptNodeWidth = contentWidth - (hPad * 2)
      let promptNodeHeight = profileAgentPromptNode.preferredHeight(for: promptNodeWidth)
      profileAgentPromptNode.frame = CGRect(
        x: hPad,
        y: bottomAnchor + sectionPad,
        width: promptNodeWidth,
        height: promptNodeHeight
      )
      bottomAnchor = profileAgentPromptNode.frame.maxY
    } else {
      profileAgentPromptNode.frame = .zero
    }

    let totalHeight = bottomAnchor + 36.0
    profileContentView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: totalHeight)
    profileScrollView.contentSize = CGSize(width: width, height: totalHeight)
  }

  private func applyTheme() {
    let text = appearance.textColorThem
    let secondary = appearance.timeColorThem.withAlphaComponent(0.85)
    let background = appearance.wallpaperGradient.first ?? UIColor.black
    let cardBg = appearance.bubbleThemColor.withAlphaComponent(0.48)

    backgroundColor = .clear
    var white: CGFloat = 0
    if text.getWhite(&white, alpha: nil) {
      headerMaskBlurView.effect = UIBlurEffect(style: white > 0.5 ? .dark : .light)
    } else {
      headerMaskBlurView.effect = UIBlurEffect(style: .regular)
    }
    headerMaskOverlayView.backgroundColor = background.withAlphaComponent(0.32)
    rootWallpaperLayer.isHidden = true
    backGlassView.backgroundColor = background.withAlphaComponent(0.10)
    titleGlassView.backgroundColor = background.withAlphaComponent(0.10)
    avatarGlassView.backgroundColor = appearance.bubbleThemColor.withAlphaComponent(0.22)
    menuGlassView.backgroundColor = background.withAlphaComponent(0.10)
    refreshHeaderGlass()

    backButton.tintColor = text
    menuButton.tintColor = text
    chatTitleLabel.textColor = text
    profileTitleLabel.textColor = text
    chatSubtitleLabel.textColor = secondary
    profileSubtitleLabel.textColor = secondary
    avatarFallbackIconView.tintColor = text

    profilePage.backgroundColor = .clear
    profileScrollView.backgroundColor = .clear
    profileContentView.backgroundColor = .clear
    applyProfileWallpaperAppearance()
    profileAvatarView.backgroundColor = appearance.bubbleThemColor.withAlphaComponent(0.35)
    profileAvatarFallbackIconView.tintColor = text
    profileOnlineDotView.backgroundColor =
      isOnline
      ? UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
      : appearance.timeColorThem.withAlphaComponent(0.32)
    profileOnlineDotView.layer.borderColor = (appearance.wallpaperGradient.first ?? .black).cgColor
    profileNameLabel.textColor = text
    profileHandleLabel.textColor =
      isOnline
      ? UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
      : secondary
    profileBioLabel.textColor = secondary

    let actionBg =
      appearance.bubbleThemColor.withAlphaComponent(0.44)
    profileMuteButton.applyTheme(foreground: text, background: actionBg)
    profileSearchButton.applyTheme(foreground: text, background: actionBg)
    profileAudioCallButton.applyTheme(foreground: text, background: actionBg)
    profileVideoCallButton.applyTheme(foreground: text, background: actionBg)

    profileIdentityCard.backgroundColor = appearance.bubbleThemColor.withAlphaComponent(0.58)
    profileUsernameRow.applyTheme(
      titleColor: text,
      subtitleColor: secondary,
      separatorColor: appearance.timeColorThem.withAlphaComponent(0.18),
      highlightedColor: appearance.textColorThem.withAlphaComponent(0.06)
    )
    profileBioRow.applyTheme(
      titleColor: text,
      subtitleColor: secondary,
      separatorColor: appearance.timeColorThem.withAlphaComponent(0.18),
      highlightedColor: appearance.textColorThem.withAlphaComponent(0.0)
    )

    profileTabsCard.backgroundColor = appearance.bubbleThemColor.withAlphaComponent(0.58)
    profileTabPlaceholderLabel.textColor = secondary
    applyProfileTabTheme()
    profileTabContentNeedsReload = true

    let accentColor =
      appearance.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    profileAgentPromptNode.applyTheme(
      textColor: primaryText,
      secondaryTextColor: secondaryText,
      surfaceColor: cardBg,
      accentColor: accentColor
    )

  private func applyProfileWallpaperAppearance() {
    profileWallpaperLayer.colors = appearance.wallpaperGradient.map(\.cgColor)
    profileWallpaperLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    profileWallpaperLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    profileWallpaperLayer.opacity = Float(max(0.0, min(1.0, appearance.wallpaperOpacity)))
    profileWallpaperLayer.isHidden = appearance.backgroundMode == "transparent"

    let canShowPattern =
      appearance.backgroundMode != "transparent"
      && appearance.wallpaperPatternGradient.count >= 2
      && appearance.wallpaperPatternOpacity > 0.001
      && (appearance.wallpaperMaskKey?.isEmpty == false)

    guard
      canShowPattern,
      let maskKey = appearance.wallpaperMaskKey,
      let maskImage = resolvedWallpaperMaskImage(for: maskKey)
    else {
      profileWallpaperPatternLayer.isHidden = true
      profileWallpaperPatternLayer.colors = nil
      profileWallpaperPatternLayer.locations = nil
      profileWallpaperPatternLayer.opacity = 0.0
      profileWallpaperPatternMaskLayer.contents = nil
      return
    }

    profileWallpaperPatternLayer.colors = appearance.wallpaperPatternGradient.map(\.cgColor)
    profileWallpaperPatternLayer.locations = appearance.wallpaperPatternLocations
    profileWallpaperPatternLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    profileWallpaperPatternLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    profileWallpaperPatternLayer.opacity = Float(
      max(0.0, min(1.0, appearance.wallpaperPatternOpacity)))
    profileWallpaperPatternMaskLayer.contents = maskImage
    profileWallpaperPatternMaskLayer.frame = profileWallpaperPatternLayer.bounds
    profileWallpaperPatternLayer.isHidden = false
  }

  private func resolvedWallpaperMaskImage(for key: String) -> CGImage? {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedKey.isEmpty else { return nil }
    if let cached = Self.wallpaperMaskImageCache[normalizedKey] {
      return cached
    }
    guard let baseName = Self.wallpaperMaskBaseName(for: normalizedKey) else {
      return nil
    }

    let bundles = [Bundle.main, Bundle(for: ChatMainView.self), Bundle(for: ChatListView.self)]
    for bundle in bundles {
      if let image = UIImage(named: baseName, in: bundle, compatibleWith: nil)?.cgImage {
        Self.wallpaperMaskImageCache[normalizedKey] = image
        return image
      }
      if let image = UIImage(named: "\(baseName).png", in: bundle, compatibleWith: nil)?.cgImage {
        Self.wallpaperMaskImageCache[normalizedKey] = image
        return image
      }
      if let path = bundle.path(forResource: baseName, ofType: "png"),
        let image = UIImage(contentsOfFile: path)?.cgImage
      {
        Self.wallpaperMaskImageCache[normalizedKey] = image
        return image
      }
    }
    return nil
  }

  private static func wallpaperMaskBaseName(for key: String) -> String? {
    switch key {
    case "doodles", "hearts":
      return "doodle_transparent"
    case "music":
      return "music_transparent"
    case "music2":
      return "music2_transparent"
    case "food":
      return "food_transparent"
    case "animals":
      return "animals_transparent"
    default:
      return nil
    }
  }

  private func updateHeaderTexts() {
    let resolvedTitle = chatTitleText.isEmpty ? "Chat" : chatTitleText
    let engineSubtitle = resolvedEnginePresenceSubtitle()
    let trimmedSubtitle = chatSubtitleText.trimmingCharacters(in: .whitespacesAndNewlines)
    let subtitleLower = trimmedSubtitle.lowercased()
    let resolvedSubtitle: String
    if let engineSubtitle {
      resolvedSubtitle = engineSubtitle
    } else if isOnline
      && (trimmedSubtitle.isEmpty || subtitleLower.hasPrefix("last seen")
        || subtitleLower == "offline")
    {
      resolvedSubtitle = "online"
    } else {
      resolvedSubtitle = trimmedSubtitle
    }
    chatTitleLabel.text = resolvedTitle
    chatSubtitleLabel.text = resolvedSubtitle
    profileTitleLabel.text = profileNameText.isEmpty ? resolvedTitle : profileNameText
    profileSubtitleLabel.text = "Profile"
    chatSubtitleLabel.textColor =
      isOnline
      ? UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
      : appearance.timeColorThem.withAlphaComponent(0.85)
  }

  private func updateProfileTexts() {
    let resolvedTitle = chatTitleText.isEmpty ? "Chat" : chatTitleText
    profileNameLabel.text = profileNameText.isEmpty ? resolvedTitle : profileNameText
    let fallbackHandle = resolvedEnginePresenceSubtitle() ?? (isOnline ? "online" : "offline")
    profileHandleLabel.text =
      profileHandleText.isEmpty ? fallbackHandle : profileHandleText
    profileBioLabel.text = profileBioText
    profileBioLabel.isHidden =
      profileBioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    profileMuteButton.setTitle(isChatMuted ? "Unmute" : "Mute")

    let usernameRowSubtitle: String
    if profileHandleText.isEmpty {
      usernameRowSubtitle = "@\(resolvedTitle.replacingOccurrences(of: " ", with: "").lowercased())"
    } else if profileHandleText.lowercased().hasPrefix("id:") {
      usernameRowSubtitle = profileHandleText
    } else if profileHandleText.hasPrefix("@") {
      usernameRowSubtitle = profileHandleText
    } else {
      usernameRowSubtitle = "@\(profileHandleText)"
    }
    let hasBioRow = !profileBioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    profileUsernameRow.configure(
      title: "Username",
      subtitle: usernameRowSubtitle,
      titleColor: appearance.bubbleMeGradient.last ?? appearance.textColorMe,
      showsSeparator: hasBioRow
    )
    profileBioRow.configure(
      title: "Bio",
      subtitle: hasBioRow ? profileBioText : "No bio",
      titleColor: nil,
      showsSeparator: false
    )

    rebuildProfileTabs()
    profileTabContentNeedsReload = true
    setNeedsLayout()
  }

  private func resolvedEnginePresenceSubtitle() -> String? {
    guard !enginePeerUserId.isEmpty else { return nil }
    if isOnline { return "online" }
    guard let lastSeen = engineLastSeenTimestampMs else { return "last seen recently" }
    return formatLastSeenSubtitle(lastSeen)
  }

  private func formatLastSeenSubtitle(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    let timePart = Self.lastSeenTimeFormatter.string(from: date)
    if Calendar.current.isDateInToday(date) {
      return "last seen today at \(timePart)"
    }
    let dayPart = Self.lastSeenDateFormatter.string(from: date)
    return "last seen \(dayPart) \(timePart)"
  }

  private func updateAvatarViews() {
    avatarLoadTask?.cancel()

    guard let url = URL(string: avatarUri), !avatarUri.isEmpty else {
      avatarImageView.isHidden = true
      profileAvatarImageView.isHidden = true
      avatarFallbackIconView.isHidden = false
      profileAvatarFallbackIconView.isHidden = false
      return
    }

    avatarImageView.image = nil
    profileAvatarImageView.image = nil
    avatarImageView.isHidden = true
    profileAvatarImageView.isHidden = true
    avatarFallbackIconView.isHidden = false
    profileAvatarFallbackIconView.isHidden = false

    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        self.avatarImageView.image = image
        self.profileAvatarImageView.image = image
        self.avatarImageView.isHidden = false
        self.profileAvatarImageView.isHidden = false
        self.avatarFallbackIconView.isHidden = true
        self.profileAvatarFallbackIconView.isHidden = true
      }
    }
    avatarLoadTask = task
    task.resume()
  }

  private func applyPageState(animated: Bool, emitEvent: Bool) {
    let width = pagesHost.bounds.width
    let profileOffscreen = CGAffineTransform(translationX: width, y: 0.0)
    let profileOnscreen = CGAffineTransform.identity
    let chatAlpha: CGFloat = currentPage == .chat ? 1.0 : 0.0
    let profileAlpha: CGFloat = currentPage == .profile ? 1.0 : 0.0
    let avatarAlpha: CGFloat = currentPage == .chat ? 1.0 : 0.0
    let menuAlpha: CGFloat = currentPage == .profile ? 1.0 : 0.0
    let chatHeaderTransform =
      currentPage == .chat
      ? CGAffineTransform.identity : CGAffineTransform(translationX: -18.0, y: 0.0)
    let profileHeaderTransform =
      currentPage == .profile
      ? CGAffineTransform.identity : CGAffineTransform(translationX: 18.0, y: 0.0)

    let openingProfile = currentPage == .profile
    if openingProfile && profilePage.isHidden {
      profilePage.transform = profileOffscreen
      profilePage.alpha = 1.0
      profilePage.isHidden = false
    }

    let apply = {
      self.profilePage.transform = openingProfile ? profileOnscreen : profileOffscreen
      self.chatHeaderStack.alpha = chatAlpha
      self.profileHeaderStack.alpha = profileAlpha
      self.chatHeaderStack.transform = chatHeaderTransform
      self.profileHeaderStack.transform = profileHeaderTransform
      self.avatarButton.alpha = avatarAlpha
      self.menuButton.alpha = menuAlpha
    }

    if animated {
      UIView.animate(
        withDuration: 0.28,
        delay: 0.0,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
        animations: apply
      ) { _ in
        if !openingProfile {
          self.profilePage.isHidden = true
          self.profilePage.alpha = 0
        } else {
          self.profilePage.isHidden = false
          self.profilePage.alpha = 1.0
        }
      }
    } else {
      apply()
      profilePage.isHidden = !openingProfile
      profilePage.alpha = openingProfile ? 1.0 : 0.0
    }

    if emitEvent {
      onNativeEvent(["type": "mainPageChanged", "page": currentPage.rawValue])
    }
  }

  @objc private func handleBackPressed() {
    if currentPage == .profile {
      markPendingNativePageChange(.chat)
      currentPage = .chat
      applyPageState(animated: true, emitEvent: true)
      return
    }
    onNativeEvent(["type": "headerBack"])
  }

  @objc private func handleAvatarPressed() {
    guard currentPage == .chat else { return }
    markPendingNativePageChange(.profile)
    currentPage = .profile
    applyPageState(animated: true, emitEvent: true)
    onNativeEvent(["type": "headerAvatarPressed"])
  }

  @objc private func handleMenuPressed() {
    guard currentPage == .profile else { return }
    guard let presenter = topMostViewController() else { return }

    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    sheet.addAction(
      UIAlertAction(title: "Search in Chat", style: .default) { [weak self] _ in
        self?.onNativeEvent(["type": "headerSearchPressed"])
      })
    let muteTitle = isChatMuted ? "Unmute" : "Mute"
    sheet.addAction(
      UIAlertAction(title: muteTitle, style: .default) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "muteToggle"])
      })
    sheet.addAction(
      UIAlertAction(title: "Clear Chat", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
      })
    sheet.addAction(
      UIAlertAction(title: "Block User", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "blockUser"])
      })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    if let popover = sheet.popoverPresentationController {
      popover.sourceView = menuButton
      popover.sourceRect = menuButton.bounds
      popover.permittedArrowDirections = [.up, .down]
    }
    presenter.present(sheet, animated: true)
  }

  @objc private func handleProfileUsernamePressed() {
    onNativeEvent([
      "type": "profileUsernamePressed",
      "handle": profileHandleText,
    ])
  }

  @objc private func handleProfileMutePressed() {
    onNativeEvent(["type": "headerMenuAction", "action": "muteToggle"])
  }

  @objc private func handleProfileSearchPressed() {
    onNativeEvent(["type": "headerSearchPressed"])
  }

  @objc private func handleProfileAudioCallPressed() {
    onNativeEvent(["type": "headerAudioCallPressed"])
  }

  @objc private func handleProfileVideoCallPressed() {
    onNativeEvent(["type": "headerVideoCallPressed"])
  }

  // MARK: - Agent Config

  func setIsGroupOrChannel(_ value: Bool) {
    isGroupOrChannel = value
    refreshAgentCardVisibility()
  }

  func setAgentConfig(_ config: [String: Any]?) {
    agentConfig = config
    refreshAgentCardVisibility()
    profileAgentPromptNode.configure(chatId: engineChatId, config: config)
  }

  private func refreshAgentCardVisibility() {
    let shouldShow = isGroupOrChannel
    if profileAgentPromptNode.isHidden == !shouldShow { return }
    profileAgentPromptNode.isHidden = !shouldShow
    setNeedsLayout()
  }

  func agentPromptNode(_ node: ChatMainProfileAgentPromptNode, didUpdateConfig config: [String: Any]) {
    agentConfig = config
    onNativeEvent([
      "type": "agentConfigSaved",
      "chatId": engineChatId,
      "config": config,
    ])
    setNeedsLayout()
  }

  func agentPromptNodeDidRequestDelete(_ node: ChatMainProfileAgentPromptNode) {
    let alert = UIAlertController(
      title: "Remove AI Agent",
      message: "This will remove the agent and clear its memory. This action cannot be undone.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
      guard let self else { return }
      self.agentConfig = nil
      self.profileAgentPromptNode.configure(chatId: self.engineChatId, config: nil)
      self.setNeedsLayout()
      self.onNativeEvent([
        "type": "agentConfigDeleted",
        "chatId": self.engineChatId,
      ])
    })
    
    if let presenter = topMostViewController() {
      presenter.present(alert, animated: true)
    }
  }

  func agentPromptNodeDidRequestFullEditor(_ node: ChatMainProfileAgentPromptNode) {
    // Intentionally left blank as the inline editor covers all functionality.
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
}
