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

public final class ChatMainView: ExpoView {
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
  private let profileNameLabel = UILabel()
  private let profileHandleLabel = UILabel()
  private let profileBioLabel = UILabel()
  private let profileInfoCard = UIView()
  private let profileInfoTitleLabel = UILabel()
  private let profileInfoSubtitleLabel = UILabel()

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
    profileContentView.addSubview(profileNameLabel)
    profileContentView.addSubview(profileHandleLabel)
    profileContentView.addSubview(profileBioLabel)
    profileContentView.addSubview(profileInfoCard)
    profileInfoCard.addSubview(profileInfoTitleLabel)
    profileInfoCard.addSubview(profileInfoSubtitleLabel)

    profileAvatarView.clipsToBounds = true
    profileAvatarImageView.clipsToBounds = true
    profileAvatarImageView.contentMode = .scaleAspectFill
    profileAvatarFallbackIconView.contentMode = .scaleAspectFit
    profileAvatarFallbackIconView.image = UIImage(systemName: "person.fill")
    profileAvatarFallbackIconView.isHidden = false

    profileNameLabel.textAlignment = .center
    profileNameLabel.font = UIFont.systemFont(ofSize: 30, weight: .bold)
    profileHandleLabel.textAlignment = .center
    profileHandleLabel.font = UIFont.systemFont(ofSize: 18, weight: .medium)
    profileBioLabel.textAlignment = .center
    profileBioLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    profileBioLabel.numberOfLines = 0

    profileInfoTitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    profileInfoSubtitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
    profileInfoSubtitleLabel.numberOfLines = 0

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
    if
      let changedChatIdRaw = notification.userInfo?["chatId"] as? String,
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
      {
        profileSummaryMessageCount = 0
        profileSummaryMediaCount = 0
        profileSummaryFileCount = 0
        profileSummaryLinkCount = 0
        profileSummaryRecentFiles = []
        profileSummaryHistoryLoaded = false
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

    guard
      force
        || nextMessageCount != profileSummaryMessageCount
        || nextMediaCount != profileSummaryMediaCount
        || nextFileCount != profileSummaryFileCount
        || nextLinkCount != profileSummaryLinkCount
        || nextHistoryLoaded != profileSummaryHistoryLoaded
        || nextRecentFiles != profileSummaryRecentFiles
    else { return }

    profileSummaryMessageCount = nextMessageCount
    profileSummaryMediaCount = nextMediaCount
    profileSummaryFileCount = nextFileCount
    profileSummaryLinkCount = nextLinkCount
    profileSummaryRecentFiles = nextRecentFiles
    profileSummaryHistoryLoaded = nextHistoryLoaded
    updateProfileTexts()
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
      x: pageWidth, y: -headerHeight,
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
    let padding: CGFloat = 20.0

    profileContentView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: 1.0)

    let avatarSize: CGFloat = 116.0
    profileAvatarView.frame = CGRect(
      x: (width - avatarSize) * 0.5, y: 30.0, width: avatarSize, height: avatarSize)
    profileAvatarView.layer.cornerRadius = avatarSize * 0.5
    profileAvatarImageView.frame = profileAvatarView.bounds
    profileAvatarFallbackIconView.frame = profileAvatarView.bounds.insetBy(dx: 30.0, dy: 30.0)

    profileNameLabel.frame = CGRect(
      x: padding, y: profileAvatarView.frame.maxY + 16.0, width: width - (padding * 2), height: 38.0
    )
    profileHandleLabel.frame = CGRect(
      x: padding, y: profileNameLabel.frame.maxY + 2.0, width: width - (padding * 2), height: 24.0)

    let bioSize = profileBioLabel.sizeThatFits(CGSize(width: width - (padding * 2), height: 200.0))
    let bioHeight = max(0.0, min(120.0, bioSize.height))
    profileBioLabel.frame = CGRect(
      x: padding, y: profileHandleLabel.frame.maxY + 12.0, width: width - (padding * 2),
      height: bioHeight)

    profileInfoCard.frame = CGRect(
      x: 16.0,
      y: profileBioLabel.frame.maxY + 24.0,
      width: width - 32.0,
      height: 108.0
    )
    profileInfoCard.layer.cornerRadius = 22.0

    profileInfoTitleLabel.frame = CGRect(
      x: 16.0, y: 16.0, width: profileInfoCard.bounds.width - 32.0, height: 22.0)
    profileInfoSubtitleLabel.frame = CGRect(
      x: 16.0, y: profileInfoTitleLabel.frame.maxY + 6.0,
      width: profileInfoCard.bounds.width - 32.0, height: 56.0)

    let totalHeight = profileInfoCard.frame.maxY + 36.0
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
    profileNameLabel.textColor = text
    profileHandleLabel.textColor =
      isOnline
      ? UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
      : secondary
    profileBioLabel.textColor = secondary

    profileInfoCard.backgroundColor = cardBg
    profileInfoTitleLabel.textColor = text
    profileInfoSubtitleLabel.textColor = secondary
  }

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
    profileBioLabel.text =
      profileBioText.isEmpty
      ? "Shared media, links, and pinned messages will appear here."
      : profileBioText
    profileInfoTitleLabel.text = "Shared Content"
    if profileSummaryHistoryLoaded {
      let base =
        "Media \(profileSummaryMediaCount) • Files \(profileSummaryFileCount) • Links \(profileSummaryLinkCount)\n\(profileSummaryMessageCount) cached messages available natively."
      if !profileSummaryRecentFiles.isEmpty {
        profileInfoSubtitleLabel.text = "\(base)\nRecent files: \(profileSummaryRecentFiles.joined(separator: ", "))"
      } else {
        profileInfoSubtitleLabel.text = base
      }
    } else {
      profileInfoSubtitleLabel.text =
        "Loading shared media and files from native encrypted cache..."
    }
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
    let targetTranslateX = currentPage == .chat ? 0.0 : -width
    let chatAlpha: CGFloat = currentPage == .chat ? 1.0 : 0.0
    let profileAlpha: CGFloat = currentPage == .profile ? 1.0 : 0.0
    let avatarAlpha: CGFloat = currentPage == .chat ? 1.0 : 0.0
    let menuAlpha: CGFloat = currentPage == .chat ? 1.0 : 0.0
    let chatHeaderTransform =
      currentPage == .chat
      ? CGAffineTransform.identity : CGAffineTransform(translationX: -18.0, y: 0.0)
    let profileHeaderTransform =
      currentPage == .profile
      ? CGAffineTransform.identity : CGAffineTransform(translationX: 18.0, y: 0.0)

    let apply = {
      self.pagesHost.transform = CGAffineTransform(translationX: targetTranslateX, y: 0.0)
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
      )
    } else {
      apply()
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
    guard currentPage == .chat else { return }
    guard let presenter = topMostViewController() else { return }

    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
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
