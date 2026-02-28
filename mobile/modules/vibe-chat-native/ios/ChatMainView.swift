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
  case agent
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

private struct ChatMainPinnedBannerContent: Equatable {
  let title: String
  let body: String
  let messageId: String?
  let isFile: Bool
  let mediaUrl: String?
  let fileName: String?
}

public final class ChatMainView: ExpoView,
  UIGestureRecognizerDelegate,
  ChatMainProfileAgentPromptNodeDelegate
{
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

  private let profileHeaderContainer = UIView()
  private let profileHeaderMaskView = UIView()
  private let profileHeaderBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let profileHeaderOverlayView = UIView()
  private let profileHeaderMaskGradientLayer = CAGradientLayer()
  private let profileHeaderContentView = UIView()
  private let profileBackGlassView = UIVisualEffectView(effect: nil)
  private let profileBackPressedOverlayView = UIView()
  private let profileBackButton = UIButton(type: .system)
  private let profileMenuGlassView = UIVisualEffectView(effect: nil)
  private let profileMenuPressedOverlayView = UIView()
  private let profileMenuButton = UIButton(type: .system)

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
  private let pinnedBannerView = ChatPinnedBannerView()
  private let profilePage = UIView()
  private let agentPage = UIView()
  private let agentScrollView = UIScrollView()
  private let agentContentView = UIView()
  private let agentPromptNode = ChatMainProfileAgentPromptNode()
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

  private let profileAgentRow = ChatMainProfileListRowNode()
  private var agentConfig: [String: Any]?
  private var isGroupOrChannel = false

  private var appearance = ChatListAppearance.fallback
  private var isOnline = false
  private var surfacePresenceOnline: Bool?
  private var chatTitleText: String = "Chat"
  private var chatSubtitleText: String = ""
  private var profileNameText: String = "User"
  private var profileHandleText: String = ""
  private var profileBioText: String = ""
  private var groupMemberDisplayNameByUserId: [String: String] = [:]
  private var groupMemberOrder: [String] = []
  private var groupMemberCount: Int?
  private var groupTypingUserIds: [String] = []
  private var directPeerTypingActive = false
  private var agentProgressSubtitle: String?
  private var pinnedBannerMessageId: String?
  private var pinnedBannerTitle: String?
  private var pinnedBannerBody: String?
  private var pinnedBannerMediaUrl: String?
  private var pinnedBannerFileName: String?
  private var pinnedBannerIsFile = false
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
  private var profileSwipeStartProgress: CGFloat = 0.0
  private var chatHeaderCenterMinWidth: CGFloat = 0.0
  private var standaloneProfileMode = false

  private lazy var profileSwipeBackGesture: UIScreenEdgePanGestureRecognizer = {
    let gesture = UIScreenEdgePanGestureRecognizer(
      target: self, action: #selector(handleProfileSwipeBack(_:)))
    gesture.edges = .left
    gesture.delegate = self
    return gesture
  }()

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
  private static let lastSeenWeekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE"
    return formatter
  }()
  private static let profileListDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private static let themeDarkBg = UIColor(
    red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 18.0 / 255.0, alpha: 1.0)
  private static let themeLightBg = UIColor(
    red: 245.0 / 255.0, green: 244.0 / 255.0, blue: 241.0 / 255.0, alpha: 1.0)
  private static let themeDarkCard = UIColor(
    red: 36.0 / 255.0, green: 36.0 / 255.0, blue: 36.0 / 255.0, alpha: 1.0)
  private static let themeLightCard = UIColor.white

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
    layoutAgentContent()
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
    NSLog("[ChatMainView][Pin] setEngineChatId=%@", engineChatId)
    chatListView.setEngineChatId(value)
    refreshTypingStateFromEngine(force: true)
    refreshAgentProgressFromEngine(force: true)
    refreshPinnedBannerFromEngine(force: true)
    refreshProfileSummaryFromEngine(force: true)
    fetchAgentConfigForCurrentChat()
  }

  func setEngineMyUserId(_ value: String) {
    chatListView.setEngineMyUserId(value)
  }

  func setEnginePeerUserId(_ value: String) {
    enginePeerUserId = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    surfacePresenceOnline = nil
    chatListView.setEnginePeerUserId(value)
    if enginePeerUserId.isEmpty {
      engineLastSeenTimestampMs = nil
      updateHeaderTexts()
      updateProfileTexts()
      return
    }
    refreshPresenceStateFromEngine(force: true)
    refreshTypingStateFromEngine(force: true)
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

  func setGroupMembers(_ rawMembers: [[String: Any]]) {
    var nextNamesByUserId: [String: String] = [:]
    var nextOrder: [String] = []
    for raw in rawMembers {
      let rawId =
        (raw["userId"] as? String)
        ?? (raw["id"] as? String)
        ?? (raw["memberId"] as? String)
      let trimmedId = rawId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmedId.isEmpty else { continue }
      let normalizedId = trimmedId.uppercased()
      let rawName =
        (raw["name"] as? String)
        ?? (raw["username"] as? String)
        ?? (raw["label"] as? String)
        ?? trimmedId
      let displayName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      if nextNamesByUserId[normalizedId] == nil {
        nextOrder.append(normalizedId)
      }
      nextNamesByUserId[normalizedId] = displayName.isEmpty ? trimmedId : displayName
    }
    groupMemberDisplayNameByUserId = nextNamesByUserId
    groupMemberOrder = nextOrder
    refreshTypingStateFromEngine(force: true)
    updateHeaderTexts()
    updateProfileTexts()
  }

  func setGroupMemberCount(_ value: Int?) {
    if let value {
      groupMemberCount = max(0, value)
    } else {
      groupMemberCount = nil
    }
    updateHeaderTexts()
    updateProfileTexts()
  }

  func setAvatarUri(_ value: String?) {
    avatarUri = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    updateAvatarViews()
  }

  func setIsOnline(_ value: Bool) {
    surfacePresenceOnline = value
    if enginePeerUserId.isEmpty {
      isOnline = value
      if value {
        engineLastSeenTimestampMs = nil
      }
      applyTheme()
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

  func setStandaloneProfileMode(_ value: Bool) {
    if standaloneProfileMode == value { return }
    standaloneProfileMode = value
    refreshAgentCardVisibility()
    if value {
      chatListView.setInputBarEnabled(false)
      chatListView.setNativeSendEnabled(false)
      currentPage = .profile
      pendingNativePageTarget = nil
      pendingNativePageLockUntil = 0.0
      applyPageState(animated: false, emitEvent: false)
    }
  }

  func setPage(_ value: String, animated: Bool) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "profile" {
      if standaloneProfileMode {
        if currentPage != .profile {
          currentPage = .profile
          applyPageState(animated: animated, emitEvent: false)
        }
      } else {
        onNativeEvent(["type": "headerAvatarPressed"])
      }
      return
    }
    if normalized == "agent" {
      if standaloneProfileMode {
        if currentPage != .profile {
          currentPage = .profile
          applyPageState(animated: animated, emitEvent: false)
        }
        presentAgentConfigEditor()
      } else {
        onNativeEvent(["type": "headerAgentPressed"])
      }
      return
    }
    if standaloneProfileMode {
      onNativeEvent(["type": "headerBack"])
      return
    }
    var nextPage: ChatMainPage = {
      switch normalized {
      default:
        return .chat
      }
    }()
    if nextPage == .agent && !isGroupOrChannel {
      nextPage = .profile
    }

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
    chatPage.addSubview(pinnedBannerView)
    pinnedBannerView.isHidden = true
    pinnedBannerView.alpha = 0.0
    pinnedBannerView.addTarget(
      self, action: #selector(handlePinnedBannerPressed), for: .touchUpInside)

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

    pagesHost.addSubview(agentPage)
    agentPage.addSubview(agentScrollView)
    agentScrollView.addSubview(agentContentView)
    agentContentView.addSubview(agentPromptNode)
    agentPage.isHidden = true
    agentPage.alpha = 0.0
    agentScrollView.showsVerticalScrollIndicator = false
    agentScrollView.alwaysBounceVertical = true
    agentPromptNode.delegate = self

    profilePage.addSubview(profileHeaderContainer)
    profileHeaderContainer.clipsToBounds = false
    profileHeaderMaskView.isUserInteractionEnabled = false
    profileHeaderContainer.addSubview(profileHeaderMaskView)
    profileHeaderMaskView.addSubview(profileHeaderBlurView)
    profileHeaderBlurView.contentView.addSubview(profileHeaderOverlayView)
    profileHeaderMaskGradientLayer.colors = [
      UIColor.black.withAlphaComponent(0.95).cgColor,
      UIColor.black.withAlphaComponent(0.72).cgColor,
      UIColor.clear.cgColor,
    ]
    profileHeaderMaskGradientLayer.locations = [0.0, 0.58, 1.0]
    profileHeaderMaskView.layer.mask = profileHeaderMaskGradientLayer
    profileHeaderContainer.addSubview(profileHeaderContentView)
    profileHeaderContainer.alpha = 0.0
    profileHeaderContainer.isHidden = true

    profileHeaderContentView.addSubview(profileBackButton)
    profileHeaderContentView.addSubview(profileMenuButton)
    profileHeaderContentView.addSubview(profileHeaderStack)

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

    [profileBackButton, profileMenuButton].forEach { button in
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

    profileBackGlassView.isUserInteractionEnabled = false
    profileBackGlassView.clipsToBounds = true
    profileBackButton.addSubview(profileBackGlassView)
    profileBackButton.sendSubviewToBack(profileBackGlassView)

    profileBackPressedOverlayView.isUserInteractionEnabled = false
    profileBackPressedOverlayView.backgroundColor = headerPressedOverlayColor
    profileBackPressedOverlayView.alpha = 0
    profileBackButton.addSubview(profileBackPressedOverlayView)

    profileMenuGlassView.isUserInteractionEnabled = false
    profileMenuGlassView.clipsToBounds = true
    profileMenuButton.addSubview(profileMenuGlassView)
    profileMenuButton.sendSubviewToBack(profileMenuGlassView)

    profileMenuPressedOverlayView.isUserInteractionEnabled = false
    profileMenuPressedOverlayView.backgroundColor = headerPressedOverlayColor
    profileMenuPressedOverlayView.alpha = 0
    profileMenuButton.addSubview(profileMenuPressedOverlayView)

    backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    backButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)
    titleButton.addTarget(self, action: #selector(handleAvatarPressed), for: .touchUpInside)
    menuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
    menuButton.addTarget(self, action: #selector(handleMenuPressed), for: .touchUpInside)
    menuButton.isHidden = true

    profileBackButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    profileBackButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)
    profileMenuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
    profileMenuButton.addTarget(self, action: #selector(handleMenuPressed), for: .touchUpInside)

    avatarButton.addTarget(self, action: #selector(handleAvatarPressed), for: .touchUpInside)
    avatarButton.addSubview(avatarImageView)
    avatarButton.addSubview(avatarFallbackIconView)
    avatarButton.bringSubviewToFront(avatarPressedOverlayView)
    menuButton.bringSubviewToFront(menuPressedOverlayView)
    backButton.bringSubviewToFront(backPressedOverlayView)
    titleButton.bringSubviewToFront(titlePressedOverlayView)
    profileBackButton.bringSubviewToFront(profileBackPressedOverlayView)
    profileMenuButton.bringSubviewToFront(profileMenuPressedOverlayView)

    let backSymbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    backButton.setPreferredSymbolConfiguration(backSymbolConfig, forImageIn: .normal)
    let menuSymbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    menuButton.setPreferredSymbolConfiguration(menuSymbolConfig, forImageIn: .normal)
    profileBackButton.setPreferredSymbolConfiguration(backSymbolConfig, forImageIn: .normal)
    profileMenuButton.setPreferredSymbolConfiguration(menuSymbolConfig, forImageIn: .normal)
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
    profileHeaderStack.isUserInteractionEnabled = false

    profileScrollView.showsVerticalScrollIndicator = false
    profileScrollView.alwaysBounceVertical = true
    profilePage.addGestureRecognizer(profileSwipeBackGesture)

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

    profileIdentityCard.addSubview(profileAgentRow)
    profileAgentRow.addTarget(self, action: #selector(handleAgentRowTapped), for: .touchUpInside)

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

    profileAgentRow.isHidden = true

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
    let changeReason = (notification.userInfo?["reason"] as? String) ?? "(unknown)"
    let changedChatId = (notification.userInfo?["chatId"] as? String) ?? ""
    if changeReason == "chatPinnedUpdated" || changeReason == "chatRowsReloaded"
      || changeReason == "chatMessageInserted" || changeReason == "chatMessageChanged"
    {
      NSLog(
        "[ChatMainView][Pin] engineDidChange reason=%@ changedChatId=%@ engineChatId=%@",
        changeReason,
        changedChatId,
        engineChatId
      )
    }
    refreshPresenceStateFromEngine()
    refreshTypingStateFromEngine()
    refreshAgentProgressFromEngine()
    guard !engineChatId.isEmpty else { return }
    if let changedChatIdRaw = notification.userInfo?["chatId"] as? String,
      !changedChatIdRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      changedChatIdRaw.trimmingCharacters(in: .whitespacesAndNewlines) != engineChatId
    {
      return
    }
    refreshPinnedBannerFromEngine()
    refreshProfileSummaryFromEngine()
  }

  private func refreshPresenceStateFromEngine(force: Bool = false) {
    guard !enginePeerUserId.isEmpty else { return }
    let engineOnline = ChatEngine.shared.isUserOnline(userId: enginePeerUserId)
    let nextOnline = engineOnline || (surfacePresenceOnline == true)
    let nextLastSeen =
      nextOnline
      ? nil
      : ChatEngine.shared.lastSeenTimestampMs(userId: enginePeerUserId)
    guard
      force || nextOnline != isOnline || nextLastSeen != engineLastSeenTimestampMs
    else { return }
    isOnline = nextOnline
    engineLastSeenTimestampMs = nextLastSeen
    applyTheme()
    updateHeaderTexts()
    updateProfileTexts()
  }

  private func refreshTypingStateFromEngine(force: Bool = false) {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)

    guard isGroupOrChannel else {
      let nextDirectTyping =
        !chatId.isEmpty
        ? ChatEngine.shared.isTyping(["chatId": chatId])
        : false
      guard
        force
          || !groupTypingUserIds.isEmpty
          || nextDirectTyping != directPeerTypingActive
      else { return }
      groupTypingUserIds = []
      directPeerTypingActive = nextDirectTyping
      updateHeaderTexts()
      updateProfileTexts()
      return
    }
    guard !chatId.isEmpty else {
      guard force || !groupTypingUserIds.isEmpty || directPeerTypingActive else { return }
      groupTypingUserIds = []
      directPeerTypingActive = false
      updateHeaderTexts()
      updateProfileTexts()
      return
    }
    let next = ChatEngine.shared.typingUserIds(chatId: chatId)
    guard force || next != groupTypingUserIds || directPeerTypingActive else { return }
    groupTypingUserIds = next
    directPeerTypingActive = false
    updateHeaderTexts()
    updateProfileTexts()
  }

  private func refreshAgentProgressFromEngine(force: Bool = false) {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else {
      guard force || agentProgressSubtitle != nil else { return }
      agentProgressSubtitle = nil
      updateHeaderTexts()
      return
    }

    let payload = ChatEngine.shared.agentProgress(chatId: chatId)
    let isActive = (payload?["isActive"] as? Bool) ?? false
    let rawLabel = (payload?["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let nextLabel = (isActive ? rawLabel : nil)?.isEmpty == false ? rawLabel : nil

    guard force || nextLabel != agentProgressSubtitle else { return }
    agentProgressSubtitle = nextLabel
    updateHeaderTexts()
  }

  private func refreshPinnedBannerFromEngine(force: Bool = false) {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else {
      guard force || pinnedBannerMessageId != nil || pinnedBannerBody != nil || !pinnedBannerView.isHidden else { return }
      NSLog("[ChatMainView][Pin] clear banner: empty engineChatId force=%@", force ? "true" : "false")
      pinnedBannerMessageId = nil
      pinnedBannerTitle = nil
      pinnedBannerBody = nil
      pinnedBannerMediaUrl = nil
      pinnedBannerFileName = nil
      pinnedBannerIsFile = false
      pinnedBannerView.isHidden = true
      pinnedBannerView.alpha = 0.0
      return
    }

    let payload = ChatEngine.shared.getPinnedMessages(["chatId": chatId])
    let pins = (payload["data"] as? [[String: Any]]) ?? []
    let topPin = pins.first
    let nextContent = resolvePinnedBannerContent(chatId: chatId, pin: topPin)
    let nextMessageId = nextContent?.messageId ?? pinnedMessageId(from: topPin)
    let nextTitle = nextContent?.title
    let nextBody = nextContent?.body
    let nextMediaUrl = nextContent?.mediaUrl
    let nextFileName = nextContent?.fileName
    let nextIsFile = nextContent?.isFile == true

    let shouldHide = nextBody == nil
    let bannerChanged =
      nextMessageId != pinnedBannerMessageId
      || nextTitle != pinnedBannerTitle
      || nextBody != pinnedBannerBody
      || nextMediaUrl != pinnedBannerMediaUrl
      || nextFileName != pinnedBannerFileName
      || nextIsFile != pinnedBannerIsFile
      || pinnedBannerView.isHidden != shouldHide
    NSLog(
      "[ChatMainView][Pin] refresh chatId=%@ force=%@ pins=%@ topMessageId=%@ title=%@ nextBody=%@ file=%@ url=%@ currentHidden=%@ shouldHide=%@ changed=%@ loading=%@",
      chatId,
      force ? "true" : "false",
      String(pins.count),
      nextMessageId ?? "(nil)",
      nextTitle ?? "(nil)",
      nextBody ?? "(nil)",
      nextIsFile ? "true" : "false",
      nextMediaUrl ?? "(nil)",
      pinnedBannerView.isHidden ? "true" : "false",
      shouldHide ? "true" : "false",
      bannerChanged ? "true" : "false",
      ((payload["loading"] as? Bool) == true) ? "true" : "false"
    )
    guard force || bannerChanged else { return }

    pinnedBannerMessageId = nextMessageId
    pinnedBannerTitle = nextTitle
    pinnedBannerBody = nextBody
    pinnedBannerMediaUrl = nextMediaUrl
    pinnedBannerFileName = nextFileName
    pinnedBannerIsFile = nextIsFile

    if let nextBody {
      pinnedBannerView.configure(
        title: nextTitle ?? "Pinned Message",
        body: nextBody,
        isFile: nextIsFile,
        animateIcon: bannerChanged
      )
      if pinnedBannerView.isHidden {
        NSLog(
          "[ChatMainView][Pin] show banner messageId=%@ alphaTarget=%@",
          nextMessageId ?? "(nil)",
          currentPage == .chat ? "1.0" : "0.0"
        )
        pinnedBannerView.alpha = 0.0
        pinnedBannerView.isHidden = false
        UIView.animate(withDuration: 0.2) {
          self.pinnedBannerView.alpha = self.currentPage == .chat ? 1.0 : 0.0
        }
      } else {
        NSLog(
          "[ChatMainView][Pin] update banner messageId=%@ alpha=%@",
          nextMessageId ?? "(nil)",
          currentPage == .chat ? "1.0" : "0.0"
        )
        pinnedBannerView.alpha = currentPage == .chat ? 1.0 : 0.0
      }
      setNeedsLayout()
    } else {
      if pinnedBannerView.isHidden {
        pinnedBannerView.alpha = 0.0
      } else {
        NSLog("[ChatMainView][Pin] hide banner (no body)")
        UIView.animate(
          withDuration: 0.18,
          animations: {
            self.pinnedBannerView.alpha = 0.0
          },
          completion: { _ in
            self.pinnedBannerView.isHidden = true
          }
        )
      }
    }
  }

  private func pinnedMessageId(from pin: [String: Any]?) -> String? {
    guard let pin else { return nil }
    let raw = pin["messageId"] ?? pin["message_id"] ?? pin["id"]
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = raw as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private func resolvePinnedBannerContent(chatId: String, pin: [String: Any]?) -> ChatMainPinnedBannerContent? {
    guard let pin else { return nil }

    let messageId = pinnedMessageId(from: pin)
    var type = normalizedPinnedString(pin["type"] ?? pin["messageType"] ?? pin["message_type"])?.lowercased()
    var text = normalizedPinnedString(pin["text"] ?? pin["plainContent"] ?? pin["plain_content"])
    var caption = normalizedPinnedString(pin["caption"])
    var fileName = normalizedPinnedString(pin["fileName"] ?? pin["file_name"])
    var mediaUrl = normalizedPinnedString(pin["mediaUrl"] ?? pin["media_url"])

    if let messageId {
      let rows = ChatEngine.shared.getChatRows(["chatId": chatId])
      for row in rows.reversed() {
        guard (row["kind"] as? String) == "message" else { continue }
        guard let message = row["message"] as? [String: Any] else { continue }
        guard normalizedPinnedString(message["id"]) == messageId else { continue }

        type =
          normalizedPinnedString(message["type"] ?? message["messageType"] ?? message["message_type"])?
          .lowercased() ?? type
        text = text ?? normalizedPinnedString(message["text"] ?? message["plainContent"] ?? message["plain_content"])
        caption = caption ?? normalizedPinnedString(message["caption"])
        fileName = fileName ?? normalizedPinnedString(message["fileName"] ?? message["file_name"])
        mediaUrl = mediaUrl ?? normalizedPinnedString(message["mediaUrl"] ?? message["media_url"])
        break
      }
    }

    let inferredName = inferredPinnedFileName(from: mediaUrl)
    let resolvedFileName = fileName ?? inferredName
    let isFile = isPinnedFileType(type) || resolvedFileName != nil || looksLikePinnedFileURL(mediaUrl)
    let title = isFile ? "Pinned File" : "Pinned Message"
    let resolvedBody: String
    if isFile {
      if let resolvedFileName {
        resolvedBody = "File: \(resolvedFileName)"
      } else if let caption {
        resolvedBody = caption
      } else if let text {
        resolvedBody = text
      } else {
        resolvedBody = "Pinned file"
      }
    } else if let text {
      resolvedBody = text
    } else if let caption {
      resolvedBody = caption
    } else if let mediaUrl {
      resolvedBody = mediaUrl
    } else {
      resolvedBody = "Pinned message"
    }

    return ChatMainPinnedBannerContent(
      title: title,
      body: resolvedBody,
      messageId: messageId,
      isFile: isFile,
      mediaUrl: mediaUrl,
      fileName: resolvedFileName
    )
  }

  private func normalizedPinnedString(_ value: Any?) -> String? {
    if let str = value as? String {
      let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let num = value as? NSNumber {
      return num.stringValue
    }
    return nil
  }

  private func isPinnedFileType(_ value: String?) -> Bool {
    guard let normalized = value?.lowercased() else { return false }
    return normalized == "file" || normalized == "music"
  }

  private func looksLikePinnedFileURL(_ value: String?) -> Bool {
    guard let value else { return false }
    let normalized = value.lowercased()
    if normalized.contains("/api/agent/document/") || normalized.contains("/uploads/agent-docs/") {
      return true
    }
    let documentExtensions = [
      ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".csv", ".txt", ".rtf", ".ppt", ".pptx",
      ".zip", ".json", ".md",
    ]
    return documentExtensions.contains { normalized.contains($0) }
  }

  private func inferredPinnedFileName(from value: String?) -> String? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    let parsedURL = URL(string: raw)
    let componentRaw: String
    if let parsedURL {
      componentRaw = parsedURL.lastPathComponent
    } else {
      componentRaw =
        raw
        .components(separatedBy: "?")
        .first?
        .components(separatedBy: "#")
        .first?
        .components(separatedBy: "/")
        .last ?? ""
    }
    let component = componentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !component.isEmpty else { return nil }
    if component == "document" || component == "agent-docs" {
      return nil
    }
    return component.removingPercentEncoding ?? component
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
        let isAgentDoc =
          url.contains("/api/agent/document/") || url.contains("/uploads/agent-docs/")
        if !isAgentDoc && !seenLinks.contains(url) {
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

    let cardBg = appearance.isDark ? Self.themeDarkCard : Self.themeLightCard
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

  @objc private func handlePinnedBannerPressed() {
    guard currentPage == .chat else { return }
    guard let messageId = pinnedBannerMessageId, !messageId.isEmpty else { return }
    chatListView.scrollToMessage(messageId: messageId, animated: true, viewPosition: 0.2)

    let targetTab: ChatMainProfileTab = {
      if pinnedBannerIsFile, profileVisibleTabs.contains(.files) {
        return .files
      }
      if profileVisibleTabs.contains(.pinned) {
        return .pinned
      }
      return profileActiveTab
    }()
    if targetTab != profileActiveTab {
      profileActiveTab = targetTab
      profileTabContentNeedsReload = true
    }
    setPage("profile", animated: true)

    if pinnedBannerIsFile,
      let mediaUrl = pinnedBannerMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      !mediaUrl.isEmpty
    {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
        self?.chatListView.openPinnedDocument(urlString: mediaUrl)
      }
    }

    var payload: [String: Any] = [
      "type": "pinnedBannerPressed",
      "messageId": messageId,
      "isFile": pinnedBannerIsFile,
      "tab": targetTab.rawValue,
    ]
    if let title = pinnedBannerTitle {
      payload["title"] = title
    }
    if let body = pinnedBannerBody {
      payload["body"] = body
    }
    if let mediaUrl = pinnedBannerMediaUrl {
      payload["url"] = mediaUrl
    }
    if let fileName = pinnedBannerFileName {
      payload["fileName"] = fileName
    }
    onNativeEvent(payload)
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
      let profileBackEffect = UIGlassEffect()
      profileBackEffect.isInteractive = true
      profileBackGlassView.effect = profileBackEffect
      let profileMenuEffect = UIGlassEffect()
      profileMenuEffect.isInteractive = true
      profileMenuGlassView.effect = profileMenuEffect
    } else {
      backGlassView.effect = UIBlurEffect(style: .systemMaterial)
      titleGlassView.effect = UIBlurEffect(style: .systemMaterial)
      avatarGlassView.effect = UIBlurEffect(style: .systemMaterial)
      menuGlassView.effect = UIBlurEffect(style: .systemMaterial)
      profileBackGlassView.effect = UIBlurEffect(style: .systemMaterial)
      profileMenuGlassView.effect = UIBlurEffect(style: .systemMaterial)
    }
  }

  private func configureHeaderPressFeedback() {
    let controls: [UIControl] = [
      backButton, titleButton, avatarButton, menuButton, profileBackButton, profileMenuButton,
    ]
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
      } else if control === self.profileBackButton {
        let scale: CGFloat = isPressed ? 0.9 : 1.0
        self.profileBackButton.imageView?.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.profileBackGlassView.alpha = isPressed ? 0.92 : 1.0
        self.profileBackPressedOverlayView.alpha = isPressed ? 1.0 : 0.0
      } else if control === self.profileMenuButton {
        let scale: CGFloat = isPressed ? 0.96 : 1.0
        self.profileMenuButton.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.profileMenuGlassView.alpha = isPressed ? 0.92 : 1.0
        self.profileMenuPressedOverlayView.alpha = isPressed ? 1.0 : 0.0
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
    menuButton.frame = .zero

    let maxCenterWidth = max(0.0, headerContentView.bounds.width * 0.65)
    let chatReq = max(
      chatTitleLabel.intrinsicContentSize.width, chatSubtitleLabel.intrinsicContentSize.width)
    let computedCenterWidth = min(maxCenterWidth, max(160.0, chatReq + 36.0))
    chatHeaderCenterMinWidth = max(chatHeaderCenterMinWidth, computedCenterWidth)
    let centerWidth = min(maxCenterWidth, max(chatHeaderCenterMinWidth, computedCenterWidth))
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

    profileHeaderContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerHeight)
    profileHeaderMaskView.frame = profileHeaderContainer.bounds
    profileHeaderBlurView.frame = profileHeaderMaskView.bounds
    profileHeaderOverlayView.frame = profileHeaderBlurView.bounds
    profileHeaderMaskGradientLayer.frame = profileHeaderMaskView.bounds
    profileHeaderContentView.frame = CGRect(
      x: 12.0, y: contentY, width: max(0.0, bounds.width - 24.0), height: 44.0)

    profileBackButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    profileMenuButton.frame = CGRect(
      x: max(0.0, profileHeaderContentView.bounds.width - 44.0), y: 0.0, width: 44.0, height: 44.0)

    let profileReq = max(
      profileTitleLabel.intrinsicContentSize.width, profileSubtitleLabel.intrinsicContentSize.width)
    let profileCenterWidth = min(maxCenterWidth, max(160.0, profileReq + 36.0))
    let profileCenterFrame = CGRect(
      x: (profileHeaderContentView.bounds.width - profileCenterWidth) * 0.5,
      y: 0.0,
      width: profileCenterWidth,
      height: 44.0
    )
    profileHeaderStack.frame = profileCenterFrame.insetBy(dx: 12.0, dy: 4.0)

    [profileBackButton, profileMenuButton].forEach { control in
      control.layer.cornerRadius = control.bounds.height / 2.0
    }
    [
      profileBackGlassView, profileMenuGlassView, profileBackPressedOverlayView,
      profileMenuPressedOverlayView,
    ].forEach { view in
      view.frame = view.superview?.bounds ?? .zero
      view.layer.cornerRadius = (view.superview?.bounds.height ?? 0) / 2.0
    }
    if let imageView = profileBackButton.imageView {
      profileBackButton.bringSubviewToFront(imageView)
    }
    profileBackButton.bringSubviewToFront(profileBackPressedOverlayView)
    if let imageView = profileMenuButton.imageView {
      profileMenuButton.bringSubviewToFront(imageView)
    }
    profileMenuButton.bringSubviewToFront(profileMenuPressedOverlayView)
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
    let bannerWidth = max(0.0, pageWidth - 32.0)
    pinnedBannerView.frame = CGRect(
      x: 16.0,
      y: headerHeight + 8.0,
      width: bannerWidth,
      height: ChatPinnedBannerView.preferredHeight
    )
    chatPage.bringSubviewToFront(pinnedBannerView)

    profilePage.frame = CGRect(
      x: 0.0, y: -headerHeight,
      width: pageWidth, height: pageHeight + headerHeight)
    profileWallpaperLayer.frame = profilePage.bounds
    profileWallpaperPatternLayer.frame = profilePage.bounds
    profileWallpaperPatternMaskLayer.frame = profileWallpaperPatternLayer.bounds
    profileScrollView.frame = CGRect(
      x: 0.0, y: headerHeight,
      width: pageWidth, height: pageHeight)

    agentPage.frame = CGRect(
      x: 0.0, y: -headerHeight,
      width: pageWidth, height: pageHeight + headerHeight)
    agentScrollView.frame = CGRect(
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

    var identityCardHeight: CGFloat = profileUsernameRow.frame.maxY
    let showsSecondaryIdentityRow =
      isGroupOrChannel || !profileBioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if showsSecondaryIdentityRow {
      profileBioRow.isHidden = false
      profileBioRow.frame = CGRect(
        x: 0.0, y: identityCardHeight, width: profileIdentityCard.bounds.width,
        height: 62.0)
      identityCardHeight = profileBioRow.frame.maxY
    } else {
      profileBioRow.isHidden = true
      profileBioRow.frame = .zero
    }

    if !profileAgentRow.isHidden {
      profileAgentRow.frame = CGRect(
        x: 0.0, y: identityCardHeight, width: profileIdentityCard.bounds.width, height: 62.0)
      identityCardHeight = profileAgentRow.frame.maxY
    } else {
      profileAgentRow.frame = .zero
    }

    profileIdentityCard.frame.size.height = identityCardHeight

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

    let totalHeight = bottomAnchor + 36.0
    profileContentView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: totalHeight)
    profileScrollView.contentSize = CGSize(width: width, height: totalHeight)
  }

  private func layoutAgentContent() {
    let width = max(1.0, agentScrollView.bounds.width)
    let sideInset: CGFloat = 16.0
    let cardWidth = width - (sideInset * 2.0)
    let cardHeight = agentPromptNode.preferredHeight(for: cardWidth)

    agentContentView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: cardHeight + 36.0)
    agentPromptNode.frame = CGRect(
      x: sideInset,
      y: 18.0,
      width: cardWidth,
      height: cardHeight
    )
    agentScrollView.contentSize = CGSize(width: width, height: agentContentView.bounds.height)
  }

  private func applyTheme() {
    let text = appearance.textColorThem
    let secondary = appearance.timeColorThem.withAlphaComponent(0.85)
    let chatBackground = appearance.wallpaperGradient.first ?? UIColor.black
    let isDarkTheme = appearance.isDark
    let profileBackground = isDarkTheme ? Self.themeDarkBg : Self.themeLightBg
    let profileCardBg = isDarkTheme ? Self.themeDarkCard : Self.themeLightCard
    let actionBg = profileCardBg
    let rowSeparatorColor =
      isDarkTheme
      ? UIColor(white: 1.0, alpha: 0.16) : UIColor(white: 0.0, alpha: 0.08)
    let rowHighlightColor =
      isDarkTheme
      ? UIColor(white: 1.0, alpha: 0.06) : UIColor(white: 0.0, alpha: 0.04)

    backgroundColor = .clear
    var white: CGFloat = 0
    if text.getWhite(&white, alpha: nil) {
      headerMaskBlurView.effect = UIBlurEffect(style: white > 0.5 ? .dark : .light)
    } else {
      headerMaskBlurView.effect = UIBlurEffect(style: .regular)
    }
    headerMaskOverlayView.backgroundColor = chatBackground.withAlphaComponent(0.88)
    rootWallpaperLayer.isHidden = true
    backGlassView.backgroundColor = chatBackground.withAlphaComponent(0.10)
    titleGlassView.backgroundColor = chatBackground.withAlphaComponent(0.10)
    avatarGlassView.backgroundColor = appearance.bubbleThemColor.withAlphaComponent(0.22)
    menuGlassView.backgroundColor = chatBackground.withAlphaComponent(0.10)
    refreshHeaderGlass()

    profileHeaderContainer.backgroundColor = .clear
    profileHeaderBlurView.effect =
      UIBlurEffect(style: isDarkTheme ? .systemThinMaterialDark : .systemThinMaterialLight)
    profileHeaderOverlayView.backgroundColor =
      profileBackground.withAlphaComponent(isDarkTheme ? 0.42 : 0.72)
    profileBackGlassView.backgroundColor = profileCardBg.withAlphaComponent(0.68)
    profileMenuGlassView.backgroundColor = profileCardBg.withAlphaComponent(0.68)

    backButton.tintColor = text
    menuButton.tintColor = text
    profileBackButton.tintColor = text
    profileMenuButton.tintColor = text
    chatTitleLabel.textColor = text
    profileTitleLabel.textColor = text
    chatSubtitleLabel.textColor = secondary
    profileSubtitleLabel.textColor = secondary
    avatarFallbackIconView.tintColor = text
    pinnedBannerView.applyTheme(
      textColor: text,
      surfaceColor: chatBackground,
      isDark: isDarkTheme
    )

    profilePage.backgroundColor = profileBackground
    profileScrollView.backgroundColor = profileBackground
    profileContentView.backgroundColor = profileBackground
    agentPage.backgroundColor = profileBackground
    agentScrollView.backgroundColor = profileBackground
    agentContentView.backgroundColor = profileBackground
    applyProfileWallpaperAppearance()
    profileAvatarView.backgroundColor = profileCardBg
    profileAvatarFallbackIconView.tintColor = text
    profileOnlineDotView.backgroundColor =
      isOnline
      ? UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
      : appearance.timeColorThem.withAlphaComponent(0.32)
    profileOnlineDotView.layer.borderColor = profileBackground.cgColor
    profileNameLabel.textColor = text
    profileHandleLabel.textColor =
      isOnline
      ? UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
      : secondary
    profileBioLabel.textColor = secondary

    profileMuteButton.applyTheme(foreground: text, background: actionBg)
    profileSearchButton.applyTheme(foreground: text, background: actionBg)
    profileAudioCallButton.applyTheme(foreground: text, background: actionBg)
    profileVideoCallButton.applyTheme(foreground: text, background: actionBg)

    profileIdentityCard.backgroundColor = profileCardBg
    profileUsernameRow.applyTheme(
      titleColor: text,
      subtitleColor: secondary,
      separatorColor: rowSeparatorColor,
      highlightedColor: rowHighlightColor
    )
    profileBioRow.applyTheme(
      titleColor: text,
      subtitleColor: secondary,
      separatorColor: rowSeparatorColor,
      highlightedColor: UIColor.clear
    )

    profileTabsCard.backgroundColor = profileCardBg
    profileTabPlaceholderLabel.textColor = secondary
    applyProfileTabTheme()
    profileTabContentNeedsReload = true

    profileAgentRow.applyTheme(
      titleColor: text,
      subtitleColor: secondary,
      separatorColor: rowSeparatorColor,
      highlightedColor: rowHighlightColor
    )

    let accentColor =
      appearance.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    agentPromptNode.applyTheme(
      textColor: text,
      secondaryTextColor: secondary,
      surfaceColor: profileCardBg,
      accentColor: accentColor
    )
  }

  private func applyProfileWallpaperAppearance() {
    profileWallpaperLayer.colors = nil
    profileWallpaperLayer.locations = nil
    profileWallpaperLayer.opacity = 0.0
    profileWallpaperLayer.isHidden = true

    profileWallpaperPatternLayer.isHidden = true
    profileWallpaperPatternLayer.colors = nil
    profileWallpaperPatternLayer.locations = nil
    profileWallpaperPatternLayer.opacity = 0.0
    profileWallpaperPatternMaskLayer.contents = nil
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
    let resolvedAgentProgress = resolvedAgentProgressSubtitle()
    let resolvedDirectTyping = resolvedDirectTypingSubtitle()
    let groupTypingSubtitle = resolvedGroupTypingSubtitle()
    let connectionSubtitle = resolvedEngineConnectionSubtitle()
    let engineSubtitle = resolvedEnginePresenceSubtitle()
    let trimmedSubtitle = chatSubtitleText.trimmingCharacters(in: .whitespacesAndNewlines)
    let subtitleLower = trimmedSubtitle.lowercased()
    let resolvedSubtitle: String
    if let resolvedAgentProgress {
      resolvedSubtitle = resolvedAgentProgress
    } else if let resolvedDirectTyping {
      resolvedSubtitle = resolvedDirectTyping
    } else if let groupTypingSubtitle {
      resolvedSubtitle = groupTypingSubtitle
    } else if let connectionSubtitle {
      resolvedSubtitle = connectionSubtitle
    } else if let engineSubtitle {
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
    profileSubtitleLabel.text = isGroupOrChannel ? "Group Profile" : "Profile"
    chatSubtitleLabel.textColor =
      {
        if resolvedAgentProgress != nil
          || resolvedDirectTyping != nil
          || groupTypingSubtitle != nil
          || (connectionSubtitle == nil && isOnline)
        {
          return UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
        }
        if connectionSubtitle != nil {
          return appearance.textColorThem.withAlphaComponent(0.9)
        }
        return appearance.timeColorThem.withAlphaComponent(0.85)
      }()
  }

  private func updateProfileTexts() {
    let resolvedTitle = chatTitleText.isEmpty ? "Chat" : chatTitleText
    profileNameLabel.text = profileNameText.isEmpty ? resolvedTitle : profileNameText
    if isGroupOrChannel {
      let fallbackGroupHandle: String = {
        let count = resolvedGroupMemberCount()
        if count > 0 { return "\(count) members" }
        return "group chat"
      }()
      profileHandleLabel.text = profileHandleText.isEmpty ? fallbackGroupHandle : profileHandleText
    } else {
      let fallbackHandle = resolvedEnginePresenceSubtitle() ?? (isOnline ? "online" : "offline")
      profileHandleLabel.text =
        profileHandleText.isEmpty ? fallbackHandle : profileHandleText
    }
    profileBioLabel.text = profileBioText
    profileBioLabel.isHidden =
      profileBioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    profileMuteButton.setTitle(isChatMuted ? "Unmute" : "Mute")

    if isGroupOrChannel {
      let showsAgentRow = standaloneProfileMode && isGroupOrChannel
      profileUsernameRow.configure(
        title: "Members",
        subtitle: resolvedGroupMembersRowSubtitle(),
        titleColor: appearance.bubbleMeGradient.last ?? appearance.textColorMe,
        showsSeparator: true
      )
      profileBioRow.configure(
        title: "Typing",
        subtitle: resolvedGroupTypingSubtitle() ?? "No one typing right now",
        titleColor: nil,
        showsSeparator: showsAgentRow
      )

      let agentName = normalizedAgentString(agentConfig?["name"]) ?? "Vibe AI"
      let enabled = normalizedAgentEnabledValue(agentConfig?["enabled"], defaultValue: false)
      let docsCount = getAgentDocuments().count
      let docsLabel = docsCount == 1 ? "1 file" : "\(docsCount) files"
      let stateLabel = enabled ? "Enabled" : "Disabled"
      profileAgentRow.configure(
        title: "AI Agent",
        subtitle: "\(stateLabel) • \(agentName) • \(docsLabel)",
        titleColor: nil,
        showsSeparator: false
      )
    } else {
      let usernameRowSubtitle: String
      if profileHandleText.isEmpty {
        usernameRowSubtitle =
          "@\(resolvedTitle.replacingOccurrences(of: " ", with: "").lowercased())"
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

      profileAgentRow.configure(
        title: "AI Agent",
        subtitle: "Available in group profile",
        titleColor: nil,
        showsSeparator: false
      )
    }

    let agentDocs = getAgentDocuments().map { (id: $0.id, name: $0.name) }
    agentPromptNode.configure(chatId: engineChatId, config: agentConfig, documents: agentDocs)

    rebuildProfileTabs()
    profileTabContentNeedsReload = true
    setNeedsLayout()
  }

  private func resolvedGroupMemberCount() -> Int {
    if let groupMemberCount, groupMemberCount > 0 { return groupMemberCount }
    return Set(groupMemberOrder + groupTypingUserIds.map { $0.uppercased() }).count
  }

  private func resolvedGroupMemberDisplayName(_ normalizedUserId: String) -> String {
    if normalizedUserId.starts(with: "00000000-0000-0000-0000-000000000001")
      || normalizedUserId == "SYSTEM"
    {
      return (agentConfig?["name"] as? String) ?? "Vibe "
    }
    if let explicit = groupMemberDisplayNameByUserId[normalizedUserId],
      !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return explicit
    }
    if !enginePeerUserId.isEmpty, normalizedUserId == enginePeerUserId, !profileNameText.isEmpty {
      return profileNameText
    }
    if normalizedUserId.count > 8 {
      return String(normalizedUserId.prefix(8))
    }
    return normalizedUserId
  }

  private func resolvedGroupTypingSubtitle() -> String? {
    let normalizedTypingUsers = Array(Set(groupTypingUserIds.map { $0.uppercased() })).sorted()
    guard !normalizedTypingUsers.isEmpty else { return nil }
    return "typing..."
  }

  private func resolvedDirectTypingSubtitle() -> String? {
    guard !isGroupOrChannel, directPeerTypingActive else { return nil }
    return "typing..."
  }

  private func resolvedAgentProgressSubtitle() -> String? {
    let trimmed = agentProgressSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func resolvedGroupMembersRowSubtitle() -> String {
    var seen = Set<String>()
    var orderedUserIds: [String] = []
    for rawId in groupMemberOrder {
      let normalized = rawId.uppercased()
      if seen.insert(normalized).inserted {
        orderedUserIds.append(normalized)
      }
    }
    let labels = orderedUserIds.map { resolvedGroupMemberDisplayName($0) }
    let totalCount = max(resolvedGroupMemberCount(), labels.count)
    guard !labels.isEmpty else {
      return totalCount > 0 ? "\(totalCount) members" : "No members"
    }
    let shown = labels.prefix(5)
    let suffix = labels.count > shown.count ? " +\(labels.count - shown.count)" : ""
    return "\(totalCount) members: \(shown.joined(separator: ", "))\(suffix)"
  }

  private func resolvedEnginePresenceSubtitle() -> String? {
    guard !enginePeerUserId.isEmpty else { return nil }
    if isOnline { return "online" }
    guard let lastSeen = engineLastSeenTimestampMs else { return "last seen recently" }
    return formatLastSeenSubtitle(lastSeen)
  }

  private func resolvedEngineConnectionSubtitle() -> String? {
    guard !enginePeerUserId.isEmpty else { return nil }
    if isOnline { return nil }

    let status = ChatEngine.shared.getStatus()
    let connected = (status["connected"] as? Bool) == true
    if connected { return nil }

    let stateValue =
      (status["state"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""

    if stateValue == "native-socket-open" || stateValue == "connected-shadow" {
      return nil
    }

    switch stateValue {
    case "connecting-native-presence":
      return "connecting..."
    case "configured", "configured-native-bootstrap", "native-config-missing":
      return "updating..."
    case "native-socket-closed", "disconnected":
      return "connection issue"
    default:
      if stateValue.contains("connect") { return "connecting..." }
      if stateValue.contains("config") || stateValue.contains("bootstrap")
        || stateValue.contains("update")
      {
        return "updating..."
      }
      return "connection issue"
    }
  }

  private func formatLastSeenSubtitle(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    let calendar = Calendar.current
    let now = Date()
    let timePart = Self.lastSeenTimeFormatter.string(from: date)
    if calendar.isDateInToday(date) {
      return "last seen at \(timePart)"
    }
    if calendar.isDateInYesterday(date) {
      return "last seen yesterday at \(timePart)"
    }

    let startOfLastSeenDay = calendar.startOfDay(for: date)
    let startOfToday = calendar.startOfDay(for: now)
    let daysAgo =
      calendar.dateComponents([.day], from: startOfLastSeenDay, to: startOfToday).day
      ?? Int.max

    if daysAgo < 7 {
      let weekday = Self.lastSeenWeekdayFormatter.string(from: date).lowercased()
      return "last seen \(weekday) at \(timePart)"
    }
    if daysAgo < 14 {
      return "last seen last week"
    }

    let dayPart = Self.lastSeenDateFormatter.string(from: date)
    return "last seen \(dayPart) at \(timePart)"
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
    updateHeaderTexts()

    let width = pagesHost.bounds.width
    let profileOffscreenRight = CGAffineTransform(translationX: width, y: 0.0)
    let profileOffscreenLeft = CGAffineTransform(translationX: -width, y: 0.0)
    let agentOffscreenRight = CGAffineTransform(translationX: width, y: 0.0)

    let isChat = currentPage == .chat
    let isProfile = currentPage == .profile
    let isAgent = currentPage == .agent

    let chatHeaderAlpha: CGFloat = isChat ? 1.0 : 0.0
    let profileHeaderAlpha: CGFloat = isChat ? 0.0 : 1.0
    let avatarAlpha: CGFloat = isChat ? 1.0 : 0.0
    let chatHeaderTransform =
      isChat
      ? CGAffineTransform.identity : CGAffineTransform(translationX: -14.0, y: 0.0)
    let profileHeaderTransform =
      isChat
      ? CGAffineTransform(translationX: 14.0, y: 0.0) : CGAffineTransform.identity

    if !isChat && profilePage.isHidden {
      profilePage.transform = isAgent ? profileOffscreenLeft : profileOffscreenRight
      profilePage.alpha = 1.0
      profilePage.isHidden = false
      profileHeaderContainer.isHidden = false
    }
    if isAgent && agentPage.isHidden {
      agentPage.transform = agentOffscreenRight
      agentPage.alpha = 1.0
      agentPage.isHidden = false
      profileHeaderContainer.isHidden = false
    }

    headerContainer.isUserInteractionEnabled = isChat
    profileHeaderContainer.isUserInteractionEnabled = !isChat

    let profileTargetTransform =
      isChat
      ? profileOffscreenRight
      : (isProfile ? CGAffineTransform.identity : profileOffscreenLeft)
    let agentTargetTransform = isAgent ? CGAffineTransform.identity : agentOffscreenRight

    let apply = {
      self.profilePage.transform = profileTargetTransform
      self.agentPage.transform = agentTargetTransform
      self.headerContainer.alpha = chatHeaderAlpha
      self.profileHeaderContainer.alpha = profileHeaderAlpha
      self.chatHeaderStack.alpha = 1.0
      self.profileHeaderStack.alpha = 1.0
      self.chatHeaderStack.transform = chatHeaderTransform
      self.profileHeaderStack.transform = profileHeaderTransform
      self.avatarButton.alpha = avatarAlpha
      self.pinnedBannerView.alpha = (isChat && !self.pinnedBannerView.isHidden) ? 1.0 : 0.0
      self.menuButton.alpha = 0.0
      self.profileMenuButton.alpha = isProfile ? 1.0 : 0.0
    }

    if animated {
      UIView.animate(
        withDuration: 0.34,
        delay: 0.0,
        usingSpringWithDamping: 0.9,
        initialSpringVelocity: 0.32,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
        animations: apply
      ) { _ in
        if isChat {
          self.profilePage.isHidden = true
          self.profilePage.alpha = 0
          self.agentPage.isHidden = true
          self.agentPage.alpha = 0
          self.profileHeaderContainer.isHidden = true
        } else if isProfile {
          self.profilePage.isHidden = false
          self.profilePage.alpha = 1.0
          self.agentPage.isHidden = true
          self.agentPage.alpha = 0.0
          self.profileHeaderContainer.isHidden = false
        } else {
          self.profilePage.isHidden = true
          self.profilePage.alpha = 0.0
          self.agentPage.isHidden = false
          self.agentPage.alpha = 1.0
          self.profileHeaderContainer.isHidden = false
        }
      }
    } else {
      apply()
      if isChat {
        profilePage.isHidden = true
        profilePage.alpha = 0.0
        agentPage.isHidden = true
        agentPage.alpha = 0.0
        profileHeaderContainer.isHidden = true
      } else if isProfile {
        profilePage.isHidden = false
        profilePage.alpha = 1.0
        agentPage.isHidden = true
        agentPage.alpha = 0.0
        profileHeaderContainer.isHidden = false
      } else {
        profilePage.isHidden = true
        profilePage.alpha = 0.0
        agentPage.isHidden = false
        agentPage.alpha = 1.0
        profileHeaderContainer.isHidden = false
      }
    }

    if emitEvent {
      onNativeEvent(["type": "mainPageChanged", "page": currentPage.rawValue])
    }
  }

  @objc private func handleProfileSwipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
    guard currentPage == .profile || gesture.state == .changed else { return }
    let width = max(1.0, pagesHost.bounds.width)
    let translationX = gesture.translation(in: self).x

    switch gesture.state {
    case .began:
      profileSwipeStartProgress = max(0.0, min(1.0, profilePage.transform.tx / width))
      applyInteractiveProfileSwipe(progress: profileSwipeStartProgress)
    case .changed:
      let progress = max(0.0, min(1.0, profileSwipeStartProgress + (translationX / width)))
      applyInteractiveProfileSwipe(progress: progress)
    case .ended, .cancelled, .failed:
      let progress = max(0.0, min(1.0, profilePage.transform.tx / width))
      let velocityX = gesture.velocity(in: self).x
      let shouldClose = progress > 0.33 || velocityX > 640.0
      profileSwipeStartProgress = 0.0
      if shouldClose {
        markPendingNativePageChange(.chat)
        currentPage = .chat
        applyPageState(animated: true, emitEvent: true)
      } else {
        currentPage = .profile
        applyPageState(animated: true, emitEvent: false)
      }
    default:
      break
    }
  }

  private func applyInteractiveProfileSwipe(progress: CGFloat) {
    let clamped = max(0.0, min(1.0, progress))
    let width = max(1.0, pagesHost.bounds.width)
    profilePage.isHidden = false
    profileHeaderContainer.isHidden = false
    profilePage.transform = CGAffineTransform(translationX: width * clamped, y: 0.0)
    headerContainer.alpha = clamped
    profileHeaderContainer.alpha = 1.0 - clamped
    chatHeaderStack.transform = CGAffineTransform(translationX: -14.0 * (1.0 - clamped), y: 0.0)
    profileHeaderStack.transform = CGAffineTransform(translationX: 14.0 * clamped, y: 0.0)
    avatarButton.alpha = clamped
    menuButton.alpha = 0.0
    headerContainer.isUserInteractionEnabled = false
    profileHeaderContainer.isUserInteractionEnabled = false
  }

  override public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer)
    -> Bool
  {
    if gestureRecognizer === profileSwipeBackGesture {
      if standaloneProfileMode { return false }
      return currentPage == .profile
    }
    return true
  }

  @objc private func handleBackPressed() {
    if standaloneProfileMode {
      if currentPage == .agent {
        currentPage = .profile
        applyPageState(animated: true, emitEvent: false)
        return
      }
      onNativeEvent(["type": "headerBack"])
      return
    }
    if currentPage == .agent {
      markPendingNativePageChange(.profile)
      currentPage = .profile
      applyPageState(animated: true, emitEvent: true)
      return
    }
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
      let sourceButton = profileHeaderContainer.isHidden ? menuButton : profileMenuButton
      popover.sourceView = sourceButton
      popover.sourceRect = sourceButton.bounds
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

  @objc private func handleAgentRowTapped() {
    presentAgentConfigEditor()
  }

  // MARK: - Agent Config

  func agentPromptNode(
    _ node: ChatMainProfileAgentPromptNode, didUpdateConfig config: [String: Any]
  ) {
    applyAgentConfigUpdate(config)
  }

  func agentPromptNodeDidRequestDelete(_ node: ChatMainProfileAgentPromptNode) {
    applyAgentConfigDeletion()
  }

  func agentPromptNodeDidRequestFullEditor(_ node: ChatMainProfileAgentPromptNode) {
    presentAgentConfigEditor()
  }

  func setIsGroupOrChannel(_ value: Bool) {
    isGroupOrChannel = value
    chatListView.setIsGroupOrChannel(value)
    refreshAgentCardVisibility()
    refreshTypingStateFromEngine(force: true)
    updateHeaderTexts()
    updateProfileTexts()
  }

  private func getAgentDocuments() -> [(id: String, name: String, url: String)] {
    return profileFileItems.compactMap { item in
      let url = item.mediaUrl ?? ""
      if url.contains("/agent/document/") || url.contains("/agent-docs/") {
        return (id: item.messageId, name: item.fileName, url: url)
      }
      return nil
    }
  }

  func setAgentConfig(_ config: [String: Any]?) {
    let normalized = normalizedAgentConfig(config, fallbackChatId: engineChatId)
    agentConfig = normalized
    refreshAgentCardVisibility()
  }

  private func refreshAgentCardVisibility() {
    let shouldShow = standaloneProfileMode && isGroupOrChannel
    if !shouldShow && currentPage == .agent {
      currentPage = .profile
      applyPageState(animated: false, emitEvent: false)
    }
    if profileAgentRow.isHidden == !shouldShow { return }
    profileAgentRow.isHidden = !shouldShow
    setNeedsLayout()
  }

  private func fetchAgentConfigForCurrentChat() {
    let currentId = engineChatId
    guard !currentId.isEmpty else { return }
    ChatEngine.shared.fetchAgentConfig(chatId: currentId) { [weak self] config in
      guard let self = self, self.engineChatId == currentId else { return }
      let normalized = self.normalizedAgentConfig(config, fallbackChatId: currentId)
      self.agentConfig = normalized
      self.updateProfileTexts()
      self.setNeedsLayout()
    }
  }

  private func applyAgentConfigUpdate(_ config: [String: Any]) {
    guard let normalized = normalizedAgentConfig(config, fallbackChatId: engineChatId) else {
      return
    }
    let currentId = engineChatId
    ChatEngine.shared.saveAgentConfig(chatId: currentId, config: normalized) {
      [weak self] success in
      guard let self = self, self.engineChatId == currentId else { return }
      if success {
        self.agentConfig = normalized
        self.updateProfileTexts()
        self.setNeedsLayout()
        self.fetchAgentConfigForCurrentChat()
      } else {
        print("[ChatMainView] Failed to save agent config natively")
      }
    }
  }

  private func applyAgentConfigDeletion() {
    let currentId = engineChatId
    ChatEngine.shared.deleteAgentConfig(chatId: currentId) { [weak self] success in
      guard let self = self, self.engineChatId == currentId else { return }
      if success {
        self.agentConfig = nil
        self.updateProfileTexts()
        self.setNeedsLayout()
      } else {
        print("[ChatMainView] Failed to delete agent config natively")
      }
    }
  }

  private func presentAgentConfigEditor() {
    guard standaloneProfileMode, isGroupOrChannel else { return }
    let currentId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !currentId.isEmpty else { return }
    guard let presenter = topMostViewController() else { return }

    if presenter is ChatAgentConfigViewController {
      return
    }

    let controller = ChatAgentConfigViewController()
    controller.chatId = currentId
    controller.agentConfig = agentConfig
    controller.documents = getAgentDocuments()
    controller.onSave = { [weak self] config in
      self?.applyAgentConfigUpdate(config)
    }
    controller.onDelete = { [weak self] in
      self?.applyAgentConfigDeletion()
    }

    if let nav = (presenter as? UINavigationController) ?? presenter.navigationController {
      if nav.topViewController is ChatAgentConfigViewController {
        return
      }
      nav.pushViewController(controller, animated: true)
      return
    }

    let nav = UINavigationController(rootViewController: controller)
    nav.modalPresentationStyle = .fullScreen
    presenter.present(nav, animated: true)
  }

  private func normalizedAgentConfig(_ config: [String: Any]?, fallbackChatId: String)
    -> [String: Any]?
  {
    guard let config else { return nil }
    var normalized: [String: Any] = [:]

    let resolvedChatId =
      normalizedAgentString(config["chat_id"]) ?? normalizedAgentString(config["chatId"])
      ?? fallbackChatId
    normalized["chat_id"] = resolvedChatId

    if let resolvedName = normalizedAgentString(config["name"]) {
      normalized["name"] = resolvedName
    } else {
      normalized["name"] = "Vibe AI"
    }

    let resolvedPrompt =
      normalizedAgentString(config["system_prompt"]) ?? normalizedAgentString(
        config["systemPrompt"])
      ?? ""
    normalized["system_prompt"] = resolvedPrompt

    normalized["enabled"] = normalizedAgentEnabledValue(config["enabled"], defaultValue: true)
    let enabledTools =
      normalizedAgentToolList(config["enabled_tools"])
      ?? normalizedAgentToolList(config["enabledTools"])
    if let enabledTools, !enabledTools.isEmpty {
      normalized["enabled_tools"] = enabledTools
    }

    if let existingId = normalizedAgentString(config["id"]), !existingId.isEmpty {
      normalized["id"] = existingId
    } else if let existingId = config["id"] {
      normalized["id"] = existingId
    }

    if let avatar = normalizedAgentString(config["avatar_url"])
      ?? normalizedAgentString(config["avatarUrl"])
    {
      normalized["avatar_url"] = avatar
    }
    if let createdBy = normalizedAgentString(config["created_by"])
      ?? normalizedAgentString(config["createdBy"])
    {
      normalized["created_by"] = createdBy
    }

    return normalized
  }

  private func normalizedAgentString(_ rawValue: Any?) -> String? {
    if let string = rawValue as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = rawValue as? NSNumber {
      return number.stringValue
    }
    return nil
  }

  private func normalizedAgentEnabledValue(_ rawValue: Any?, defaultValue: Bool) -> Bool {
    guard let rawValue else { return defaultValue }
    if let boolValue = rawValue as? Bool { return boolValue }
    if let numberValue = rawValue as? NSNumber { return numberValue.boolValue }
    if let stringValue = rawValue as? String {
      switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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

  private func normalizedAgentToolList(_ rawValue: Any?) -> [String]? {
    guard let rawArray = rawValue as? [Any] else { return nil }
    let normalized =
      rawArray
      .compactMap { value -> String? in
        if let text = value as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
          return number.stringValue
        }
        return nil
      }
    return normalized
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
