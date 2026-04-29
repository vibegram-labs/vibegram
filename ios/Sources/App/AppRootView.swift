import SwiftUI
import UIKit

private func appShellRouteLog(_ message: String) {
  NSLog("[AppShellRoute] %@", message)
}

enum AppShellTab: Hashable {
  case contacts
  case calls
  case chats
  case settings
  case search
}

struct ChatRoute: Identifiable, Hashable {
  let chatId: String
  let title: String
  let peerUserId: String?
  let avatarURI: String?
  let isGroup: Bool
  let initialRows: [[String: Any]]

  var id: String { chatId }

  init(
    chatId: String,
    title: String,
    peerUserId: String?,
    avatarURI: String?,
    isGroup: Bool,
    initialRows: [[String: Any]]
  ) {
    self.chatId = chatId
    self.title = title
    self.peerUserId = peerUserId
    self.avatarURI = avatarURI
    self.isGroup = isGroup
    self.initialRows = initialRows
  }

  init(row: ChatHomeListRow) {
    let cachedRows = ChatEngine.shared.getChatRows(["chatId": row.chatId])
    self.init(
      chatId: row.chatId,
      title: row.title,
      peerUserId: row.peerUserId,
      avatarURI: row.avatarUri,
      isGroup: row.isGroup,
      initialRows: cachedRows
    )
  }

  static func savedMessages(initialRows: [[String: Any]] = []) -> ChatRoute {
    ChatRoute(
      chatId: "saved_messages",
      title: "Saved Messages",
      peerUserId: nil,
      avatarURI: nil,
      isGroup: false,
      initialRows: initialRows
    )
  }

  static func == (lhs: ChatRoute, rhs: ChatRoute) -> Bool {
    lhs.chatId == rhs.chatId && lhs.peerUserId == rhs.peerUserId
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(chatId)
    hasher.combine(peerUserId)
  }
}

struct PresentedChatRoute: Identifiable, Hashable {
  let requestID: Int
  let route: ChatRoute

  var id: Int { requestID }
}

@MainActor
private enum NativeCallRouteBridge {
  @discardableResult
  static func startOutgoing(route: ChatRoute, callType: String) -> [String: Any]? {
    guard route.chatId != "saved_messages",
      let toUserId = normalizedString(route.peerUserId)
    else {
      AppToastController.shared.show("Calls are available in direct chats.")
      return nil
    }
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return nil
    }

    VibeNativeCallManager.shared.start()
    _ = VibeNativeCallEngine.shared.configure(config.payload)
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let callId = "call_\(now)_\(UUID().uuidString.prefix(8))"
    let payload: [String: Any] = [
      "event": "call-start",
      "callId": callId,
      "callType": callType == "video" ? "video" : "voice",
      "toUserId": toUserId,
      "toUserName": route.title,
      "toUserImage": route.avatarURI ?? "",
      "chatId": route.chatId,
    ]
    let status = VibeNativeCallEngine.shared.startOutgoing(payload)
    let accepted = (status["signalingAccepted"] as? Bool) ?? true
    if accepted {
      AppToastController.shared.show(callType == "video" ? "Starting video call..." : "Calling...")
    } else {
      AppToastController.shared.show("Could not start call.")
    }
    return status
  }

  private static func normalizedString(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

@MainActor
final class AppShellCoordinator: ObservableObject {
  @Published var selectedTab: AppShellTab = .chats
  @Published var presentedChat: PresentedChatRoute?
  @Published var chatOpenRequestID: Int = 0
  @Published var chatSearchPresentationRequestID: Int = 0

  private var activeRequestID: Int?
  private weak var activeChatController: ChatConversationController?
  private var isChatPresentationTransitioning = false
  private var deferredChatPresentation: PresentedChatRoute?
  private let pushTransitionDelegate = ChatPushTransitionDelegate()

  func openChat(_ route: ChatRoute) {
    if let presentedChat, presentedChat.route == route {
      appShellRouteLog(
        "openChat ignored duplicate requestId=\(presentedChat.requestID) chatId=\(route.chatId) title=\(route.title)")
      return
    }

    chatOpenRequestID &+= 1
    let requestID = chatOpenRequestID
    appShellRouteLog(
      "openChat requested requestId=\(requestID) chatId=\(route.chatId) title=\(route.title) fromTab=\(selectedTab)")
    presentedChat = PresentedChatRoute(requestID: requestID, route: route)

    // Schedule UIKit presentation AFTER SwiftUI's current update cycle completes.
    // Calling present() synchronously during SwiftUI's body/update pass is silently
    // ignored by UIKit, which was the root cause of the blank-screen bug.
    DispatchQueue.main.async { [weak self] in
      self?.presentChatController(route: route, requestID: requestID)
    }
  }

  func closePresentedChat(requestID: Int? = nil) {
    guard let presentedChat else { return }
    if let requestID, presentedChat.requestID != requestID {
      return
    }
    appShellRouteLog(
      "closeChat requested requestId=\(presentedChat.requestID) chatId=\(presentedChat.route.chatId) title=\(presentedChat.route.title)")
    self.presentedChat = nil
    deferredChatPresentation = nil
    dismissActiveChatController(animated: true)
  }

  func openChatSearch() {
    selectedTab = .chats
    DispatchQueue.main.async { [weak self] in
      self?.chatSearchPresentationRequestID &+= 1
    }
  }

  // MARK: - UIKit presentation

  private func presentChatController(route: ChatRoute, requestID: Int) {
    guard presentedChat?.requestID == requestID else {
      appShellRouteLog(
        "presentChatController ignored stale requestId=\(requestID) currentRequestId=\(presentedChat?.requestID.description ?? "nil")")
      return
    }

    if isChatPresentationTransitioning {
      deferredChatPresentation = PresentedChatRoute(requestID: requestID, route: route)
      appShellRouteLog(
        "presentChatController deferred requestId=\(requestID) chatId=\(route.chatId) reason=transitionInFlight")
      return
    }

    if let activeChatController {
      if activeChatController.represents(route) {
        activeRequestID = requestID
        appShellRouteLog(
          "presentChatController reused active requestId=\(requestID) chatId=\(route.chatId)")
        updateChatController(activeChatController, route: route, requestID: requestID)
        return
      }

      appShellRouteLog(
        "presentChatController replacing previous requestId=\(activeRequestID.map(String.init) ?? "nil") with requestId=\(requestID)")
      isChatPresentationTransitioning = true
      dismissActiveChatController(animated: false) { [weak self] in
        guard let self else { return }
        self.isChatPresentationTransitioning = false
        self.presentChatController(route: route, requestID: requestID)
      }
      return
    }

    guard let window = Self.activeWindow() else {
      appShellRouteLog("presentChatController FAILED requestId=\(requestID) reason=noWindow")
      return
    }

    if let visibleChat = Self.visibleChatController(in: window) {
      if visibleChat.represents(route) {
        activeRequestID = requestID
        activeChatController = visibleChat
        appShellRouteLog(
          "presentChatController recovered visible requestId=\(requestID) chatId=\(route.chatId)")
        updateChatController(visibleChat, route: route, requestID: requestID)
        return
      }

      appShellRouteLog(
        "presentChatController dismissing visible stale chat before requestId=\(requestID) chatId=\(route.chatId)")
      isChatPresentationTransitioning = true
      visibleChat.dismiss(animated: false) { [weak self] in
        guard let self else { return }
        self.isChatPresentationTransitioning = false
        self.presentChatController(route: route, requestID: requestID)
      }
      return
    }

    var top: UIViewController? = window.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }

    guard let presenter = top else {
      appShellRouteLog("presentChatController FAILED requestId=\(requestID) reason=noPresenter")
      return
    }
    guard !presenter.isBeingPresented, !presenter.isBeingDismissed else {
      deferredChatPresentation = PresentedChatRoute(requestID: requestID, route: route)
      appShellRouteLog(
        "presentChatController deferred requestId=\(requestID) chatId=\(route.chatId) reason=presenterTransitioning")
      return
    }

    let isDark = window.traitCollection.userInterfaceStyle == .dark
    let controller = ChatConversationController(
      route: route,
      isDark: isDark,
      onClose: { [weak self] in
        self?.closePresentedChat(requestID: requestID)
      }
    )
    controller.modalPresentationStyle = .overFullScreen
    controller.modalPresentationCapturesStatusBarAppearance = true
    controller.transitioningDelegate = pushTransitionDelegate
    activeRequestID = requestID
    activeChatController = controller

    appShellRouteLog(
      "presentChatController presenting requestId=\(requestID) chatId=\(route.chatId) presenter=\(String(describing: type(of: presenter)))")
    isChatPresentationTransitioning = true
    presenter.present(controller, animated: true) { [weak self] in
      self?.completeChatPresentationTransition()
    }
  }

  private func updateChatController(
    _ controller: ChatConversationController,
    route: ChatRoute,
    requestID: Int
  ) {
    let isDark = Self.activeWindow()?.traitCollection.userInterfaceStyle == .dark
      || UITraitCollection.current.userInterfaceStyle == .dark
    controller.update(
      route: route,
      isDark: isDark,
      onClose: { [weak self] in
        self?.closePresentedChat(requestID: requestID)
      }
    )
  }

  private func dismissActiveChatController(animated: Bool, completion: (() -> Void)? = nil) {
    guard let controller = activeChatController else {
      activeRequestID = nil
      if let window = Self.activeWindow(), let visibleChat = Self.visibleChatController(in: window),
        visibleChat.presentingViewController != nil, !visibleChat.isBeingDismissed
      {
        visibleChat.dismiss(animated: animated, completion: completion)
      } else {
        completion?()
      }
      return
    }

    activeRequestID = nil
    activeChatController = nil

    if controller.presentingViewController != nil, !controller.isBeingDismissed {
      controller.dismiss(animated: animated, completion: completion)
    } else {
      completion?()
    }
  }

  private func completeChatPresentationTransition() {
    isChatPresentationTransitioning = false
    guard let deferred = deferredChatPresentation else { return }
    deferredChatPresentation = nil
    guard presentedChat?.requestID == deferred.requestID else {
      appShellRouteLog(
        "presentChatController dropped deferred requestId=\(deferred.requestID) currentRequestId=\(presentedChat?.requestID.description ?? "nil")")
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.presentChatController(route: deferred.route, requestID: deferred.requestID)
    }
  }

  private static func activeWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
        return keyWindow
      }
    }
    return nil
  }

  private static func visibleChatController(in window: UIWindow) -> ChatConversationController? {
    var current = window.rootViewController
    while let presented = current?.presentedViewController {
      if let chat = presented as? ChatConversationController {
        return chat
      }
      current = presented
    }
    return nil
  }
}

// MARK: - Horizontal push/pop transition (mimics UINavigationController)

private final class ChatPushTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {
  func animationController(
    forPresented presented: UIViewController,
    presenting: UIViewController,
    source: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    ChatPushAnimator(isPresenting: true)
  }

  func animationController(forDismissed dismissed: UIViewController)
    -> UIViewControllerAnimatedTransitioning?
  {
    ChatPushAnimator(isPresenting: false)
  }
}

private final class ChatPushAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  private let isPresenting: Bool

  init(isPresenting: Bool) {
    self.isPresenting = isPresenting
    super.init()
  }

  func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?)
    -> TimeInterval
  {
    0.20
  }

  func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
    let containerView = transitionContext.containerView
    let duration = transitionDuration(using: transitionContext)

    if isPresenting {
      guard let toView = transitionContext.view(forKey: .to) else {
        transitionContext.completeTransition(false)
        return
      }
      let finalFrame = transitionContext.finalFrame(for: transitionContext.viewController(forKey: .to)!)
      toView.frame = finalFrame.offsetBy(dx: finalFrame.width, dy: 0)
      containerView.addSubview(toView)
      toView.layer.shadowColor = UIColor.black.cgColor
      toView.layer.shadowOpacity = 0.18
      toView.layer.shadowRadius = 18
      toView.layer.shadowOffset = CGSize(width: -8, height: 0)

      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveEaseOut, .allowUserInteraction],
        animations: {
          toView.frame = finalFrame
        },
        completion: { finished in
          let completed = !transitionContext.transitionWasCancelled
          if !completed {
            toView.removeFromSuperview()
          }
          toView.layer.shadowOpacity = 0
          transitionContext.completeTransition(completed)
        }
      )
    } else {
      guard let fromView = transitionContext.view(forKey: .from) else {
        transitionContext.completeTransition(false)
        return
      }
      let toView = transitionContext.view(forKey: .to)
      let initialFrame = fromView.frame

      if let toView {
        toView.frame = initialFrame
        containerView.insertSubview(toView, belowSubview: fromView)
      }
      fromView.layer.shadowColor = UIColor.black.cgColor
      fromView.layer.shadowOpacity = 0.16
      fromView.layer.shadowRadius = 18
      fromView.layer.shadowOffset = CGSize(width: -8, height: 0)

      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveEaseIn, .allowUserInteraction],
        animations: {
          fromView.frame = initialFrame.offsetBy(dx: initialFrame.width, dy: 0)
        },
        completion: { finished in
          let completed = !transitionContext.transitionWasCancelled
          if !completed {
            fromView.frame = initialFrame
          }
          fromView.layer.shadowOpacity = 0
          transitionContext.completeTransition(completed)
        }
      )
    }
  }
}

@MainActor
private final class ChatsViewModel: ObservableObject {
  @Published var rows: [ChatHomeListRow] = []
  @Published var isLoading = false
  @Published var isWaitingForNetwork = false
  @Published var errorMessage: String?

  private var hasLoaded = false
  private var backgroundRefreshTask: Task<Void, Never>?

  deinit {
    backgroundRefreshTask?.cancel()
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    guard let config = AppSessionConfig.current else {
      if rows.isEmpty {
        errorMessage = "The current session is unavailable."
      }
      return
    }

    let cachedRows = ChatHomeService.cachedRows(config: config)
    if !cachedRows.isEmpty {
      rows = cachedRows
      hasLoaded = true
      isLoading = false
      isWaitingForNetwork = false
      errorMessage = nil
      warmCachedRows(cachedRows, shouldFetchHistory: false)
      NSLog("[ChatsViewModel] restored cached rows count=%d; scheduling background refresh", cachedRows.count)
      scheduleBackgroundRefreshAfterCachedStart()
      return
    }

    await refresh(preserveRows: false)
  }

  func refresh() async {
    backgroundRefreshTask?.cancel()
    backgroundRefreshTask = nil
    await refresh(preserveRows: false)
  }

  private func refresh(preserveRows: Bool) async {
    guard let config = AppSessionConfig.current else {
      if rows.isEmpty {
        errorMessage = "The current session is unavailable."
      }
      return
    }

    isLoading = rows.isEmpty && !preserveRows
    isWaitingForNetwork = false
    errorMessage = nil
    defer { isLoading = false }

    do {
      let nextRows = try await ChatHomeService.fetchChats(config: config)
      if Self.rowsSnapshotSignature(nextRows) != Self.rowsSnapshotSignature(rows) {
        rows = nextRows
        NSLog("[ChatsViewModel] applied remote rows count=%d preserveRows=%@", nextRows.count, preserveRows ? "Y" : "N")
      } else {
        NSLog("[ChatsViewModel] skipped identical remote rows count=%d preserveRows=%@", nextRows.count, preserveRows ? "Y" : "N")
      }
      hasLoaded = true
      isWaitingForNetwork = false
      warmCachedRows(nextRows, shouldFetchHistory: true)
    } catch {
      let offline = ChatHomeService.isOfflineError(error)
      isWaitingForNetwork = offline
      if rows.isEmpty {
        errorMessage = error.localizedDescription
      } else {
        errorMessage = nil
      }
      hasLoaded = true
    }
  }

  private func scheduleBackgroundRefreshAfterCachedStart() {
    backgroundRefreshTask?.cancel()
    backgroundRefreshTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 450_000_000)
      } catch {
        return
      }
      await self?.refresh(preserveRows: true)
    }
  }

  private func warmCachedRows(_ rows: [ChatHomeListRow], shouldFetchHistory: Bool) {
    let visibleRows = Array(rows.prefix(4))
    for row in visibleRows where !row.initialMessages.isEmpty {
      ChatEngine.shared.seedRecentChatHistory(
        chatId: row.chatId,
        messages: row.initialMessages,
        limit: 3
      )
    }

    guard shouldFetchHistory else { return }
    let preloadChatIds = visibleRows.prefix(2).map(\.chatId)
    ChatEngine.shared.prefetchChatHistories(chatIds: preloadChatIds)
  }

  private static func rowsSnapshotSignature(_ rows: [ChatHomeListRow]) -> String {
    rows.map { row in
      [
        row.chatId,
        row.title,
        row.preview,
        row.timeLabel,
        "\(row.unreadCount)",
        "\(row.markedUnread)",
        "\(row.muted)",
        "\(row.pinned)",
        "\(row.isTyping)",
        "\(row.isOnline)",
        row.avatarUri ?? "",
      ].joined(separator: "\u{1F}")
    }.joined(separator: "\u{1E}")
  }
}

struct AppRootView: View {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(AppThemePlateController.storageKey) private var themePlateRaw =
    AppThemePlateOption.glacier.rawValue
  @StateObject private var coordinator = AppShellCoordinator()
  @StateObject private var toastController = AppToastController.shared
  @StateObject private var profileController = AppProfileController.shared
  @State private var settingsTabAvatarImage: UIImage?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(
      for: colorScheme,
      plate: AppThemePlateOption(rawValue: themePlateRaw) ?? .glacier
    )
  }

  private var settingsTabUIImage: UIImage {
    Self.renderCircularTabAvatar(
      source: settingsTabAvatarImage,
      size: 26
    )
  }

  @ViewBuilder
  private var settingsTabIcon: some View {
    if settingsTabAvatarImage != nil {
      Image(uiImage: settingsTabUIImage)
        .renderingMode(.original)
    } else {
      Image(systemName: "person.circle.fill")
    }
  }

  var body: some View {
    ZStack {
      TabView(selection: $coordinator.selectedTab) {
        Tab("Contacts", systemImage: "person.circle", value: AppShellTab.contacts) {
          ContactsRootView()
        }

        Tab("Calls", systemImage: "phone", value: AppShellTab.calls) {
          CallsRootView()
        }

        Tab("Chats", systemImage: "message", value: AppShellTab.chats) {
          ChatsRootView()
        }

        Tab(value: AppShellTab.settings) {
          SettingsRootView()
        } label: {
          Label {
            Text("Settings")
          } icon: {
            settingsTabIcon
          }
        }

        Tab(
          "Search",
          systemImage: "magnifyingglass",
          value: AppShellTab.search,
          role: .search
        ) {
          Color.clear
        }
      }
      .tint(palette.accent)
      .background(palette.background.ignoresSafeArea())
    }
    .onChange(of: coordinator.presentedChat?.requestID) { previousRequestID, _ in
      if let presented = coordinator.presentedChat {
        appShellRouteLog(
          "AppRootView presentedChat changed requestId=\(presented.requestID) chatId=\(presented.route.chatId) title=\(presented.route.title)")
      } else {
        appShellRouteLog(
          "AppRootView presentedChat cleared lastRequestId=\(previousRequestID.map(String.init) ?? "nil")")
      }
    }
    .onAppear {
      AppAppearanceController.applyStoredPreference()
    }
    .task {
      await profileController.loadIfNeeded()
      await loadSettingsTabAvatar()
    }
    .onChange(of: profileController.profile?.profileImage) { _, _ in
      Task { await loadSettingsTabAvatar() }
    }
    .onChange(of: coordinator.selectedTab) { _, newTab in
      guard newTab == .search else { return }
      coordinator.openChatSearch()
    }
    .overlay(alignment: .bottom) {
      if let message = toastController.message {
        AppToastBanner(message: message, palette: palette)
          .padding(.horizontal, 20)
          .padding(.bottom, 116)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.22), value: coordinator.presentedChat?.requestID)
    .animation(.spring(response: 0.3, dampingFraction: 0.82), value: toastController.message)
    .environmentObject(coordinator)
  }

  @MainActor
  private func loadSettingsTabAvatar() async {
    guard let uri = profileController.profile?.profileImage else {
      settingsTabAvatarImage = nil
      return
    }
    settingsTabAvatarImage = await SettingsAvatarImageLoader.load(from: uri)
  }

  private static func renderCircularTabAvatar(
    source: UIImage?, size: CGFloat
  ) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    return renderer.image { context in
      let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
      let path = UIBezierPath(ovalIn: rect)
      path.addClip()

      if let source {
        source.draw(in: rect)
      } else {
        UIColor(red: 180 / 255, green: 190 / 255, blue: 210 / 255, alpha: 1.0).setFill()
        path.fill()

        let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.48, weight: .semibold)
        let icon = UIImage(systemName: "person.fill", withConfiguration: configuration)?
          .withTintColor(.white, renderingMode: .alwaysOriginal)
        let iconSize = CGSize(width: size * 0.52, height: size * 0.52)
        let iconRect = CGRect(
          x: (size - iconSize.width) / 2,
          y: (size - iconSize.height) / 2,
          width: iconSize.width,
          height: iconSize.height
        )
        icon?.draw(in: iconRect)
      }
    }
  }
}

@MainActor
private final class ContactDirectoryViewModel: ObservableObject {
  @Published var rows: [ChatHomeListRow] = []
  @Published var isLoading = false
  @Published var errorMessage: String?

  private var hasLoaded = false

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    await refresh()
  }

  func refresh() async {
    guard let config = AppSessionConfig.current else {
      rows = []
      errorMessage = "The current session is unavailable."
      return
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let chats = try await ChatHomeService.fetchChats(config: config)
      rows = chats.filter { row in
        !row.isSavedMessages && !row.isGroup && row.peerUserId != nil
      }
      hasLoaded = true
    } catch {
      rows = []
      errorMessage = error.localizedDescription
    }
  }
}

private struct ContactsRootView: View {
  var body: some View {
    NavigationStack {
      ContactsPageView()
    }
  }
}

private struct CallsRootView: View {
  var body: some View {
    NavigationStack {
      CallsPageView()
    }
  }
}

private struct ChatsRootView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model = ChatsViewModel()
  @State private var isShowingSearch = false
  @State private var isShowingStoryCamera = false
  @State private var isEditingHome = false
  @State private var selectedChatIDs = Set<String>()
  @State private var isStartingChat = false
  @State private var errorMessage: String?
  @State private var lastHandledSearchRequestID = 0

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    ZStack {
      NavigationStack {
        Group {
          if model.rows.isEmpty && model.isLoading {
            ProgressView()
              .controlSize(.regular)
              .tint(palette.secondaryText)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(palette.background)
          } else if model.rows.isEmpty {
            AppShellEmptyStateView(
              icon: "message",
              title: model.isWaitingForNetwork ? "Waiting for Network" : "No Messages Yet",
              message: errorMessage ?? model.errorMessage
                ?? (model.isWaitingForNetwork
                  ? "Your chats will stay here when the connection returns."
                  : "Start a conversation to catch the vibe."),
              buttonTitle: "New Chat",
              palette: palette
            ) {
              isShowingSearch = true
            }
          } else {
            ChatHomeNativeListRepresentable(
              rows: model.rows,
              isDark: colorScheme == .dark,
              isEditing: isEditingHome,
              selectedChatIDs: selectedChatIDs,
              onSelect: { row in
                if !row.initialMessages.isEmpty {
                  ChatEngine.shared.seedRecentChatHistory(
                    chatId: row.chatId,
                    messages: row.initialMessages,
                    limit: 3
                  )
                }
                coordinator.openChat(ChatRoute(row: row))
              },
              onToggleSelection: { chatID in
                toggleHomeSelection(chatID)
              },
              onRefresh: {
                await model.refresh()
              },
              onUnavailableAction: { message in
                AppToastController.shared.show(message)
              }
            )
          }
        }
        .safeAreaInset(edge: .bottom) {
          if isEditingHome {
            ChatHomeEditActionBar(
              selectedCount: selectedChatIDs.count,
              palette: palette,
              onMarkRead: {
                Task {
                  await performHomeEditAction(.markRead)
                }
              },
              onMute: {
                Task {
                  await performHomeEditAction(.mute)
                }
              },
              onDelete: {
                Task {
                  await performHomeEditAction(.delete)
                }
              }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
          }
        }
        .background(palette.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(isShowingStoryCamera || isEditingHome ? .hidden : .visible, for: .tabBar)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(isEditingHome ? "Done" : "Edit") {
              withAnimation(.easeInOut(duration: 0.18)) {
                isEditingHome.toggle()
                if !isEditingHome {
                  selectedChatIDs.removeAll()
                }
              }
            }
            .foregroundStyle(palette.secondaryText)
            .disabled(model.rows.isEmpty)
          }
          ToolbarItem(placement: .principal) {
            AppHomeStatusHeaderView(
              state: model.isWaitingForNetwork ? .waitingForNetwork : .ready,
              palette: palette
            )
          }
          ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
              withAnimation(.easeInOut(duration: 0.24)) {
                isShowingStoryCamera = true
              }
            } label: {
              AppVectorIcon(glyph: .story, tint: palette.secondaryText)
                .frame(width: 23, height: 23)
            }

            Button {
              isShowingSearch = true
            } label: {
              AppVectorIcon(glyph: .compose, tint: palette.secondaryText)
                .frame(width: 22, height: 22)
            }
          }
        }
        .task {
          await model.loadIfNeeded()
        }
        .onAppear {
          presentSearchIfRequested()
        }
        .onChange(of: coordinator.chatSearchPresentationRequestID) { _, _ in
          presentSearchIfRequested()
        }
        .sheet(isPresented: $isShowingSearch) {
          if let config = AppSessionConfig.current {
            NavigationStack {
              ContactSearchView(config: config) { payload in
                handleSearchPayload(payload)
              }
            }
          }
        }
      }

      if isShowingStoryCamera {
        AppNativeStoryCameraPage {
          withAnimation(.easeInOut(duration: 0.24)) {
            isShowingStoryCamera = false
          }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
        .zIndex(20)
      }
    }
    .animation(.easeInOut(duration: 0.18), value: isEditingHome)
  }

  private func presentSearchIfRequested() {
    let requestID = coordinator.chatSearchPresentationRequestID
    guard coordinator.selectedTab == .chats else { return }
    guard requestID > lastHandledSearchRequestID else { return }
    lastHandledSearchRequestID = requestID
    isShowingSearch = true
  }

  private func toggleHomeSelection(_ chatID: String) {
    if selectedChatIDs.contains(chatID) {
      selectedChatIDs.remove(chatID)
    } else {
      selectedChatIDs.insert(chatID)
    }
  }

  @MainActor
  private func performHomeEditAction(_ action: ChatHomeEditBulkAction) async {
    guard !selectedChatIDs.isEmpty else { return }
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return
    }

    let chatIDs = Array(selectedChatIDs)
    do {
      try await ChatHomeEditService.apply(action: action, chatIDs: chatIDs, config: config)
      selectedChatIDs.removeAll()
      isEditingHome = false
      await model.refresh()
    } catch {
      AppToastController.shared.show(error.localizedDescription)
    }
  }

  private func handleSearchPayload(_ payload: [String: Any]) {
    guard let action = payload["action"] as? String else {
      isShowingSearch = false
      return
    }

    if action == "cancel" {
      isShowingSearch = false
      return
    }

    guard
      ["select", "chat", "call", "saveContact"].contains(action),
      let rawUser = payload["user"] as? [String: Any],
      let user = ContactSearchUser(payload: rawUser)
    else {
      isShowingSearch = false
      errorMessage = "The selected user could not be opened."
      return
    }

    if action == "saveContact" {
      Task {
        await saveContact(for: user)
      }
      return
    }

    isShowingSearch = false
    Task {
      let route = await openChat(for: user)
      if action == "call", let route {
        NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
      }
    }
  }

  @MainActor
  private func saveContact(for user: ContactSearchUser) async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }

    do {
      _ = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      await model.refresh()
      AppToastController.shared.show("Contact saved.")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func openChat(for user: ContactSearchUser) async -> ChatRoute? {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return nil
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    do {
      let result = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      if let publicKey = user.publicKey, !publicKey.isEmpty {
        _ = ChatEngine.shared.cachePeerPublicKey([
          "chatId": result.chatID,
          "peerUserId": user.userID,
          "publicKey": publicKey,
        ])
      }
      let route = ChatRoute(
        chatId: result.chatID,
        title: user.username,
        peerUserId: user.userID,
        avatarURI: ChatAvatarURLResolver.resolve(
          rawAvatar: user.profileImage,
          peerUserId: user.userID,
          chatId: result.chatID,
          preferPushAvatar: true
        ),
        isGroup: false,
        initialRows: result.messages
      )
      coordinator.openChat(route)
      await model.refresh()
      return route
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}

private struct SettingsRootView: View {
  var body: some View {
    NavigationStack {
      SettingsView()
    }
  }
}

private enum ChatHomeEditBulkAction {
  case markRead
  case mute
  case delete
}

private enum ChatHomeEditService {
  private enum EditError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String)

    var errorDescription: String? {
      switch self {
      case .invalidEndpoint:
        return "Chat action endpoint is unavailable."
      case .requestFailed(let message):
        return message
      }
    }
  }

  static func apply(
    action: ChatHomeEditBulkAction,
    chatIDs: [String],
    config: AppSessionConfig
  ) async throws {
    for chatID in chatIDs {
      try await apply(action: action, chatID: chatID, config: config)
    }
  }

  private static func apply(
    action: ChatHomeEditBulkAction,
    chatID: String,
    config: AppSessionConfig
  ) async throws {
    let endpoint: String
    let method: String
    let body: [String: Any]?

    switch action {
    case .markRead:
      endpoint = "/chat/\(chatID)/mark-unread"
      method = "POST"
      body = ["userId": config.userID, "unread": false]
    case .mute:
      endpoint = "/chat/\(chatID)/mute"
      method = "POST"
      body = ["userId": config.userID, "muted": true]
    case .delete:
      endpoint = "/chats/\(chatID)"
      method = "DELETE"
      body = nil
    }

    guard let url = apiURL(base: config.apiBaseURLString, path: endpoint) else {
      throw EditError.invalidEndpoint
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw EditError.requestFailed(responseMessage(from: data))
    }
  }

  private static func apiURL(base rawBase: String, path: String) -> URL? {
    var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if base.hasSuffix("/api") {
      base = String(base.dropLast(4))
    }
    return URL(string: base + "/api" + path)
  }

  private static func responseMessage(from data: Data) -> String {
    if
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = (json["error"] ?? json["message"] ?? json["reason"]) as? String,
      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return message
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "Chat action failed."
  }
}

private struct ChatHomeEditActionBar: View {
  let selectedCount: Int
  let palette: AppThemePalette
  let onMarkRead: () -> Void
  let onMute: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 20) {
      editActionButton(title: "Read", systemImage: "envelope.open", action: onMarkRead)
      editActionButton(title: "Mute", systemImage: "bell.slash", action: onMute)
      Text("\(selectedCount) selected")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity)
      editActionButton(title: "Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private func editActionButton(
    title: String,
    systemImage: String,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(role: role, action: action) {
      VStack(spacing: 3) {
        Image(systemName: systemImage)
          .font(.system(size: 18, weight: .medium))
        Text(title)
          .font(.system(size: 11, weight: .medium))
      }
      .frame(minWidth: 48)
    }
    .disabled(selectedCount == 0)
  }
}

private struct ChatHomeNativeListRepresentable: UIViewControllerRepresentable {
  let rows: [ChatHomeListRow]
  let isDark: Bool
  let isEditing: Bool
  let selectedChatIDs: Set<String>
  let onSelect: (ChatHomeListRow) -> Void
  let onToggleSelection: (String) -> Void
  let onRefresh: () async -> Void
  let onUnavailableAction: (String) -> Void

  func makeUIViewController(context: Context) -> ChatHomeNativeListController {
    let controller = ChatHomeNativeListController()
    controller.onSelect = onSelect
    controller.onToggleSelection = onToggleSelection
    controller.onRefresh = onRefresh
    controller.onUnavailableAction = onUnavailableAction
    controller.apply(
      rows: rows,
      isDark: isDark,
      isEditing: isEditing,
      selectedChatIDs: selectedChatIDs
    )
    return controller
  }

  func updateUIViewController(_ uiViewController: ChatHomeNativeListController, context: Context) {
    uiViewController.onSelect = onSelect
    uiViewController.onToggleSelection = onToggleSelection
    uiViewController.onRefresh = onRefresh
    uiViewController.onUnavailableAction = onUnavailableAction
    uiViewController.apply(
      rows: rows,
      isDark: isDark,
      isEditing: isEditing,
      selectedChatIDs: selectedChatIDs
    )
  }
}

private final class ChatHomeNativeListController: UIViewController, UITableViewDataSource,
  UITableViewDelegate, ChatHomeCardCellSwipeDelegate
{
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let refreshControl = UIRefreshControl()

  fileprivate var onSelect: (ChatHomeListRow) -> Void = { _ in }
  fileprivate var onToggleSelection: (String) -> Void = { _ in }
  fileprivate var onRefresh: (() async -> Void)?
  fileprivate var onUnavailableAction: (String) -> Void = { _ in }

  private var rows: [ChatHomeListRow] = []
  private var isDark = false
  private var isEditingMode = false
  private var selectedChatIDs = Set<String>()
  private var isRunningRefresh = false
  private var lastAppliedSignature = ""
  private weak var openSwipeCell: ChatHomeCardCell?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.rowHeight = 84
    tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(ChatHomeCardCell.self, forCellReuseIdentifier: ChatHomeCardCell.reuseIdentifier)
    tableView.refreshControl = refreshControl
    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)

    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  func apply(
    rows: [ChatHomeListRow],
    isDark: Bool,
    isEditing: Bool,
    selectedChatIDs: Set<String>
  ) {
    let nextSignature = Self.signature(
      rows: rows,
      isDark: isDark,
      isEditing: isEditing,
      selectedChatIDs: selectedChatIDs
    )
    guard nextSignature != lastAppliedSignature else { return }
    let previousRowCount = self.rows.count
    let previousContentOffset = tableView.contentOffset
    lastAppliedSignature = nextSignature
    self.rows = rows
    self.isDark = isDark
    self.isEditingMode = isEditing
    self.selectedChatIDs = selectedChatIDs
    UIView.performWithoutAnimation {
      tableView.reloadData()
      tableView.layoutIfNeeded()
      if previousRowCount == rows.count, !rows.isEmpty {
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
          minY,
          tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )
        let y = min(max(previousContentOffset.y, minY), maxY)
        tableView.setContentOffset(CGPoint(x: previousContentOffset.x, y: y), animated: false)
      }
    }
  }

  private static func signature(
    rows: [ChatHomeListRow],
    isDark: Bool,
    isEditing: Bool,
    selectedChatIDs: Set<String>
  ) -> String {
    let rowSignature = rows.map { row in
      [
        row.chatId,
        row.title,
        row.preview,
        row.timeLabel,
        "\(row.unreadCount)",
        "\(row.markedUnread)",
        "\(row.muted)",
        "\(row.pinned)",
        "\(row.isTyping)",
        "\(row.isOnline)",
        row.avatarUri ?? "",
      ].joined(separator: "\u{1F}")
    }.joined(separator: "\u{1E}")
    return [
      isDark ? "dark" : "light",
      isEditing ? "editing" : "normal",
      selectedChatIDs.sorted().joined(separator: ","),
      rowSignature,
    ].joined(separator: "\u{1D}")
  }

  @objc private func handleRefresh() {
    guard !isRunningRefresh else { return }
    isRunningRefresh = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      await onRefresh?()
      isRunningRefresh = false
      refreshControl.endRefreshing()
    }
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ChatHomeCardCell.reuseIdentifier,
        for: indexPath
      ) as? ChatHomeCardCell
    else {
      return UITableViewCell()
    }

    let row = rows[indexPath.row]
    cell.swipeDelegate = self
    cell.selectionStyle = .none
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .clear
    cell.configure(
      row: row,
      isDark: isDark,
      avatarBackgroundColor: nil,
      avatarGradientColors: resolvedAvatarGradientColors(for: row),
      isEditing: isEditingMode,
      isEditSelected: selectedChatIDs.contains(row.chatId)
    )
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard rows.indices.contains(indexPath.row) else { return }
    openSwipeCell?.closeSwipe(animated: true)
    openSwipeCell = nil
    let row = rows[indexPath.row]
    if let cell = tableView.cellForRow(at: indexPath) as? ChatHomeCardCell {
      cell.flashPressedFeedback()
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if isEditingMode {
      let chatID = row.chatId
      onToggleSelection(chatID)
      if selectedChatIDs.contains(chatID) {
        selectedChatIDs.remove(chatID)
      } else {
        selectedChatIDs.insert(chatID)
      }
      tableView.reloadRows(at: [indexPath], with: .none)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
      self?.onSelect(row)
    }
    tableView.deselectRow(at: indexPath, animated: true)
  }

  func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard !isEditingMode, rows.indices.contains(indexPath.row) else { return nil }
    let row = rows[indexPath.row]
    return UIContextMenuConfiguration(identifier: row.chatId as NSString, previewProvider: nil) {
      [weak self] _ in
      let openAction = UIAction(
        title: "Open Chat",
        image: UIImage(systemName: "bubble.left")
      ) { [weak self] _ in
        self?.onSelect(row)
      }
      let hasUnread = row.unreadCount > 0 || row.markedUnread
      let readAction = UIAction(
        title: hasUnread ? "Mark as Read" : "Mark as Unread",
        image: UIImage(systemName: hasUnread ? "message.fill" : "circle")
      ) { [weak self] _ in
        self?.onUnavailableAction("Home actions are not wired into this shell yet.")
      }
      let pinAction = UIAction(
        title: row.pinned ? "Unpin" : "Pin",
        image: UIImage(systemName: row.pinned ? "pin.slash" : "pin")
      ) { [weak self] _ in
        self?.onUnavailableAction("Home actions are not wired into this shell yet.")
      }
      let muteAction = UIAction(
        title: row.muted ? "Unmute" : "Mute",
        image: UIImage(systemName: row.muted ? "speaker.wave.2" : "speaker.slash")
      ) { [weak self] _ in
        self?.onUnavailableAction("Home actions are not wired into this shell yet.")
      }
      let archiveAction = UIAction(
        title: "Archive",
        image: UIImage(systemName: "archivebox")
      ) { [weak self] _ in
        self?.onUnavailableAction("Home actions are not wired into this shell yet.")
      }
      let clearAction = UIAction(
        title: "Clear Chat",
        image: UIImage(systemName: "eraser")
      ) { [weak self] _ in
        self?.onUnavailableAction("Home actions are not wired into this shell yet.")
      }
      let deleteAction = UIAction(
        title: "Delete",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onUnavailableAction("Home actions are not wired into this shell yet.")
      }
      return UIMenu(
        title: "",
        children: [openAction, readAction, pinAction, muteAction, archiveAction, clearAction, deleteAction]
      )
    }
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    openSwipeCell?.closeSwipe(animated: true)
    openSwipeCell = nil
  }

  func homeCardCellDidBeginSwipe(_ cell: ChatHomeCardCell) {
    if openSwipeCell !== cell {
      openSwipeCell?.closeSwipe(animated: true)
    }
    openSwipeCell = cell
  }

  func homeCardCellDidCloseSwipe(_ cell: ChatHomeCardCell) {
    if openSwipeCell === cell {
      openSwipeCell = nil
    }
  }

  func homeCardCell(
    _ cell: ChatHomeCardCell,
    didTriggerSwipeEvent eventType: String,
    chatId: String
  ) {
    if openSwipeCell === cell {
      openSwipeCell = nil
    }
    onUnavailableAction("Home actions are not wired into this shell yet.")
  }

  private func resolvedAvatarGradientColors(for row: ChatHomeListRow) -> (UIColor, UIColor)? {
    let startRaw = isDark ? row.avatarGradientStartDark : row.avatarGradientStartLight
    let endRaw = isDark ? row.avatarGradientEndDark : row.avatarGradientEndLight
    guard let startRaw, let endRaw else { return nil }
    guard let startColor = Self.parseHexColor(startRaw), let endColor = Self.parseHexColor(endRaw)
    else { return nil }
    return (startColor, endColor)
  }

  private static func parseHexColor(_ raw: String) -> UIColor? {
    var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") {
      hex.removeFirst()
    }
    guard hex.count == 6 || hex.count == 8 else { return nil }

    var value: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

    if hex.count == 6 {
      let r = CGFloat((value >> 16) & 0xFF) / 255.0
      let g = CGFloat((value >> 8) & 0xFF) / 255.0
      let b = CGFloat(value & 0xFF) / 255.0
      return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    let r = CGFloat((value >> 24) & 0xFF) / 255.0
    let g = CGFloat((value >> 16) & 0xFF) / 255.0
    let b = CGFloat((value >> 8) & 0xFF) / 255.0
    let a = CGFloat(value & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }
}

private struct ContactsPageView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model = ContactDirectoryViewModel()
  @State private var isShowingSearch = false
  @State private var isStartingChat = false
  @State private var errorMessage: String?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    Group {
      if model.rows.isEmpty && model.isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(palette.background)
      } else if model.rows.isEmpty {
        AppShellEmptyStateView(
          icon: "person.2",
          title: "No Contacts Yet",
          message: errorMessage ?? model.errorMessage ?? "Find someone by username, phone number, or user ID.",
          buttonTitle: "New Chat",
          palette: palette
        ) {
          isShowingSearch = true
        }
      } else {
        List {
          ForEach(model.rows, id: \.chatId) { row in
            Button {
              coordinator.openChat(ChatRoute(row: row))
            } label: {
              ChatHomeRowView(row: row, palette: palette)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
          }

          if isStartingChat {
            Section {
              HStack(spacing: 12) {
                ProgressView()
                Text("Opening chat")
                  .foregroundStyle(palette.secondaryText)
              }
            }
            .listRowBackground(palette.card)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Contacts")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          isShowingSearch = true
        } label: {
          AppVectorIcon(glyph: .compose, tint: palette.secondaryText)
            .frame(width: 22, height: 22)
        }
      }
    }
    .task {
      await model.loadIfNeeded()
    }
    .refreshable {
      await model.refresh()
    }
    .sheet(isPresented: $isShowingSearch) {
      if let config = AppSessionConfig.current {
        NavigationStack {
          ContactSearchView(config: config) { payload in
            handleSearchPayload(payload)
          }
        }
      }
    }
  }

  private func handleSearchPayload(_ payload: [String: Any]) {
    guard let action = payload["action"] as? String else {
      isShowingSearch = false
      return
    }

    if action == "cancel" {
      isShowingSearch = false
      return
    }

    guard
      ["select", "chat", "call", "saveContact"].contains(action),
      let rawUser = payload["user"] as? [String: Any],
      let user = ContactSearchUser(payload: rawUser)
    else {
      isShowingSearch = false
      errorMessage = "The selected contact could not be opened."
      return
    }

    if action == "saveContact" {
      Task {
        await saveContact(for: user)
      }
      return
    }

    isShowingSearch = false
    Task {
      let route = await openChat(for: user)
      if action == "call", let route {
        NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
      }
    }
  }

  @MainActor
  private func saveContact(for user: ContactSearchUser) async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }

    do {
      _ = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      await model.refresh()
      AppToastController.shared.show("Contact saved.")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func openChat(for user: ContactSearchUser) async -> ChatRoute? {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return nil
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    do {
      let result = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      if let publicKey = user.publicKey, !publicKey.isEmpty {
        _ = ChatEngine.shared.cachePeerPublicKey([
          "chatId": result.chatID,
          "peerUserId": user.userID,
          "publicKey": publicKey,
        ])
      }
      let route = ChatRoute(
        chatId: result.chatID,
        title: user.username,
        peerUserId: user.userID,
        avatarURI: ChatAvatarURLResolver.resolve(
          rawAvatar: user.profileImage,
          peerUserId: user.userID,
          chatId: result.chatID,
          preferPushAvatar: true
        ),
        isGroup: false,
        initialRows: result.messages
      )
      coordinator.openChat(route)
      return route
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}

private struct CallsPageView: View {
  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    AppShellEmptyStateView(
      icon: "phone",
      title: "No Calls Yet",
      message: "Recent and active calls will appear here when the call runtime is linked into the standalone shell.",
      buttonTitle: nil,
      palette: palette,
      action: nil
    )
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Calls")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}





private enum ChatConversationPage: String {
  case chat
  case profile
  case agent
}

private final class ChatConversationController: UIViewController {
  private let mainView = ChatMainView()
  private var route: ChatRoute
  private var isDark: Bool
  private var onClose: (() -> Void)?
  private var currentPage: ChatConversationPage = .chat
  private var openedChatId: String?
  private var didInitialScroll = false
  private var rowsRefreshGeneration: UInt = 0
  private var lastLayoutSignature: String?
  private var hasAppeared = false
  private var pendingDeferredEngineStateRefresh = false
  private var deferredEngineRowsReadyChatId: String?

  init(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    appShellRouteLog(
      "ChatConversationController init chatId=\(route.chatId) title=\(route.title) dark=\(isDark)")
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    logLifecycle("viewDidLoad")

    mainView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mainView)
    NSLayoutConstraint.activate([
      mainView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mainView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      mainView.topAnchor.constraint(equalTo: view.topAnchor),
      mainView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    mainView.onNativeEvent.handler = { [weak self] payload in
      self?.handleNativeEvent(payload)
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineChanged(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )

    applyRoute(forceChannelRefresh: true)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    logLifecycle("viewWillAppear")
    logVisualState("viewWillAppear", force: true)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    hasAppeared = true
    logLifecycle("viewDidAppear")
    logVisualState("viewDidAppear", force: true)
    settleInitialBottomIfNeeded(reason: "viewDidAppear")
    completeDeferredEngineStateRefreshIfNeeded(chatId: route.chatId)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    settleInitialBottomIfNeeded(reason: "viewDidLayoutSubviews")
    logVisualState("viewDidLayoutSubviews")
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    logLifecycle("viewDidDisappear")
    logVisualState("viewDidDisappear", force: true)
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    logLifecycle("didMoveToParent")
    logVisualState("didMoveToParent", force: true)
  }

  deinit {
    NotificationCenter.default.removeObserver(
      self,
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    closeOpenedChatChannel()
  }

  func update(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    let chatChanged = self.route.chatId != route.chatId
    let themeChanged = self.isDark != isDark
    appShellRouteLog(
      "ChatConversationController update oldChatId=\(self.route.chatId) newChatId=\(route.chatId) chatChanged=\(chatChanged) themeChanged=\(themeChanged)")
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    applyRoute(forceChannelRefresh: chatChanged)
    if themeChanged {
      mainView.setAppearance(Self.resolvedAppearance(isDark: isDark))
    }
  }

  func represents(_ route: ChatRoute) -> Bool {
    self.route == route
  }

  private func applyRoute(forceChannelRefresh: Bool) {
    view.backgroundColor = Self.backgroundColor(isDark: isDark)
    currentPage = .chat
    appShellRouteLog(
      "ChatConversationController applyRoute chatId=\(route.chatId) title=\(route.title) forceRefresh=\(forceChannelRefresh) initialRows=\(route.initialRows.count)")

    let deferEngineStateRefreshes = view.window == nil && !hasAppeared
    if deferEngineStateRefreshes {
      pendingDeferredEngineStateRefresh = true
      deferredEngineRowsReadyChatId = nil
      appShellRouteLog(
        "ChatConversationController deferEngineState chatId=\(route.chatId) reason=prePresentation")
    } else {
      pendingDeferredEngineStateRefresh = false
      deferredEngineRowsReadyChatId = nil
    }

    let surfaceId = "native_chat_\(route.chatId)"
    mainView.surfaceId = surfaceId
    mainView.setDefersEngineStateRefreshes(deferEngineStateRefreshes)
    mainView.setEngineChannelBindingEnabled(false)
    mainView.setStatusAuthorityEnabled(!deferEngineStateRefreshes)
    mainView.setEngineSurfaceId(surfaceId)
    mainView.setEngineChatId(route.chatId)
    mainView.setEnginePeerUserId(route.peerUserId ?? "")
    if let myUserId = Self.normalizedString(
      ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
    ) {
      mainView.setEngineMyUserId(myUserId)
    }
    mainView.setAppearance(Self.resolvedAppearance(isDark: isDark))
    mainView.setHeaderMode(route.chatId == "saved_messages" ? "savedmessages" : "default")
    mainView.setHeaderTitle(route.title)
    mainView.setProfileName(route.title)
    mainView.setProfileHandle(Self.profileHandle(for: route))
    mainView.setProfileBio("")
    mainView.setAvatarUri(route.avatarURI)
    mainView.setIsGroupOrChannel(route.isGroup)
    mainView.setInputPlaceholder(route.chatId == "saved_messages" ? "Saved Message" : "Message")
    mainView.setInputBarEnabled(true)
    mainView.setNativeSendEnabled(true)
    mainView.setStandaloneProfileMode(false)
    mainView.setPage(ChatConversationPage.chat.rawValue, animated: false)
    appShellRouteLog(
      "ChatConversationController configuredSurface chatId=\(route.chatId) surfaceId=\(surfaceId) peerUserId=\(route.peerUserId ?? "") isGroup=\(route.isGroup) headerMode=\(route.chatId == "saved_messages" ? "savedmessages" : "default") windowAttached=\(view.window != nil)")

    if deferEngineStateRefreshes {
      refreshRouteOnlyHeaderState()
    } else {
      refreshHeaderState()
    }
    refreshRows(preferInitialRows: true)
    logVisualState("afterApplyRoute", force: true)

    if forceChannelRefresh {
      closeOpenedChatChannel()
    }
    openChatChannelIfNeeded()
  }

  private func openChatChannelIfNeeded() {
    guard openedChatId != route.chatId else { return }
    let chatId = route.chatId
    let peerUserId = route.peerUserId ?? ""
    openedChatId = chatId
    appShellRouteLog(
      "ChatConversationController openChatChannel chatId=\(chatId) peerUserId=\(peerUserId)")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard self != nil else { return }
      let snapshot = ChatEngine.shared.openChatChannel([
        "chatId": chatId,
        "peerUserId": peerUserId,
      ])
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          DispatchQueue.global(qos: .utility).async {
            _ = ChatEngine.shared.closeChatChannel(["chatId": chatId])
          }
          return
        }
        guard self.openedChatId == chatId else {
          DispatchQueue.global(qos: .utility).async {
            _ = ChatEngine.shared.closeChatChannel(["chatId": chatId])
          }
          return
        }
        self.appRouteLogOpenResult(chatId: chatId, snapshot: snapshot)
        self.refreshRows()
      }
    }
  }

  private func closeOpenedChatChannel() {
    guard let openedChatId else { return }
    appShellRouteLog("ChatConversationController closeChatChannel chatId=\(openedChatId)")
    self.openedChatId = nil
    DispatchQueue.global(qos: .utility).async {
      _ = ChatEngine.shared.closeChatChannel(["chatId": openedChatId])
    }
  }

  private func refreshRows(preferInitialRows: Bool = false) {
    rowsRefreshGeneration &+= 1
    let generation = rowsRefreshGeneration
    let chatId = route.chatId
    let initialRows = route.initialRows
    if preferInitialRows {
      let firstRowID =
        Self.normalizedString(initialRows.first?["id"])
        ?? Self.normalizedString(initialRows.first?["messageId"])
        ?? "nil"
      appShellRouteLog(
        "ChatConversationController refreshRows immediate chatId=\(chatId) rows=\(initialRows.count) source=initial firstRowId=\(firstRowID)")
      mainView.setRows(initialRows)
      settleInitialBottomIfNeeded(reason: "initialRows")
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let nativeRows = ChatEngine.shared.getChatRows(["chatId": chatId])
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route.chatId == chatId, self.rowsRefreshGeneration == generation else {
          return
        }
        let rows = nativeRows.isEmpty ? initialRows : nativeRows
        let firstRowID =
          Self.normalizedString(rows.first?["id"])
          ?? Self.normalizedString(rows.first?["messageId"])
          ?? "nil"
        appShellRouteLog(
          "ChatConversationController refreshRows chatId=\(chatId) rows=\(rows.count) nativeRows=\(nativeRows.count) initialRows=\(initialRows.count) source=\(nativeRows.isEmpty ? "initial" : "native") firstRowId=\(firstRowID)")
        self.mainView.setRows(rows)
        self.deferredEngineRowsReadyChatId = chatId
        self.completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
        self.settleInitialBottomIfNeeded(reason: "refreshRows")
        self.logVisualState("afterRefreshRows")
      }
    }
  }

  private func completeDeferredEngineStateRefreshIfNeeded(chatId: String) {
    guard hasAppeared, pendingDeferredEngineStateRefresh, route.chatId == chatId,
      deferredEngineRowsReadyChatId == chatId
    else { return }
    pendingDeferredEngineStateRefresh = false
    deferredEngineRowsReadyChatId = nil
    appShellRouteLog(
      "ChatConversationController completeDeferredEngineState chatId=\(chatId)")
    mainView.setDefersEngineStateRefreshes(false)
    mainView.setStatusAuthorityEnabled(true)
    mainView.refreshEngineStateAfterDeferredRouteOpen()
    refreshHeaderState()
  }

  private func appRouteLogOpenResult(chatId: String, snapshot: [String: Any]) {
    appShellRouteLog(
      "ChatConversationController openChatChannelResult chatId=\(chatId) snapshotState=\(Self.normalizedString(snapshot["state"]) ?? "nil") connected=\(snapshot["connected"] as? Bool == true) snapshotKeys=\(snapshot.keys.sorted())")
  }

  private func settleInitialBottomIfNeeded(reason: String) {
    guard !didInitialScroll else { return }
    guard view.bounds.width > 0.0, view.bounds.height > 0.0 else { return }
    didInitialScroll = true
    mainView.layoutIfNeeded()
    mainView.scrollToBottom(animated: false)
    logLifecycle("initialScrollToBottom reason=\(reason)")
    logVisualState("afterInitialScroll", force: true)
  }

  private func refreshHeaderState() {
    mainView.setHeaderSubtitle(Self.headerSubtitle(for: route))
    mainView.setIsOnline(Self.isOnline(for: route))
    mainView.setProfileHandle(Self.profileHandle(for: route))
  }

  private func refreshRouteOnlyHeaderState() {
    mainView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    mainView.setIsOnline(false)
    mainView.setProfileHandle(Self.profileHandle(for: route))
  }

  private func handleNativeEvent(_ payload: [String: Any]) {
    let type = Self.normalizedString(payload["type"]) ?? ""
    appShellRouteLog(
      "ChatConversationController nativeEvent chatId=\(route.chatId) type=\(type) payloadKeys=\(payload.keys.sorted())")
    switch type {
    case "headerBack":
      switch currentPage {
      case .chat:
        if let onClose {
          appShellRouteLog("ChatConversationController dismissPresented chatId=\(route.chatId)")
          onClose()
          DispatchQueue.main.async { [weak self] in
            guard let self, self.presentingViewController != nil, !self.isBeingDismissed else {
              return
            }
            appShellRouteLog(
              "ChatConversationController fallbackSelfDismiss chatId=\(self.route.chatId)")
            self.dismiss(animated: true)
          }
        } else if let navigationController {
          navigationController.popViewController(animated: true)
        }
      case .profile:
        currentPage = .chat
        mainView.setPage(ChatConversationPage.chat.rawValue, animated: true)
      case .agent:
        currentPage = .profile
        mainView.setPage(ChatConversationPage.profile.rawValue, animated: true)
      }
    case "headerAvatarPressed":
      currentPage = .profile
      mainView.setPage(ChatConversationPage.profile.rawValue, animated: true)
    case "headerAgentPressed":
      return
    case "headerAudioCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
    case "headerVideoCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "video")
    case "mainPageChanged":
      if let page = Self.normalizedString(payload["page"]),
        let resolved = ChatConversationPage(rawValue: page)
      {
        currentPage = resolved
      }
    default:
      break
    }
  }

  @objc private func handleChatEngineChanged(_ notification: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineChanged(notification)
      }
      return
    }

    let changedChatId = Self.normalizedString(notification.userInfo?["chatId"])
    guard changedChatId == route.chatId || changedChatId == nil else { return }
    appShellRouteLog(
      "ChatConversationController engineChanged routeChatId=\(route.chatId) changedChatId=\(changedChatId ?? "nil") reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")

    if pendingDeferredEngineStateRefresh {
      refreshRouteOnlyHeaderState()
    } else {
      refreshHeaderState()
    }

    switch Self.normalizedString(notification.userInfo?["reason"]) ?? "" {
    case "chatRowsReloaded", "chatMessageInserted", "chatMessageEdited", "chatMessageDeleted",
      "chatMessageChanged", "messageStatusChanged", "presenceChanged", "peerTyping",
      "chatChannelStateChanged":
      refreshRows()
    default:
      break
    }
  }

  private static func isOnline(for route: ChatRoute) -> Bool {
    ChatEngine.shared.isUserOnline(userId: route.peerUserId)
  }

  private static func headerSubtitle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if ChatEngine.shared.isTyping(["chatId": route.chatId]) {
      return "typing..."
    }
    if isOnline(for: route) {
      return "online"
    }
    if route.isGroup {
      return "group"
    }
    if let lastSeen = ChatEngine.shared.lastSeenTimestampMs(userId: route.peerUserId),
      let label = lastSeenLabel(from: lastSeen)
    {
      return label
    }
    return route.peerUserId == nil ? "" : "last seen recently"
  }

  private static func routeOnlyHeaderSubtitle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if route.isGroup {
      return "group"
    }
    return route.peerUserId == nil ? "" : "last seen recently"
  }

  private func logLifecycle(_ event: String) {
    let navCount = navigationController?.viewControllers.count ?? 0
    let navTypes =
      navigationController?.viewControllers.map { String(describing: type(of: $0)) }
      .joined(separator: " > ") ?? "nil"
    let rootType = view.window?.rootViewController.map { String(describing: type(of: $0)) } ?? "nil"
    let parentType = parent.map { String(describing: type(of: $0)) } ?? "nil"
    let presentedType = presentingViewController.map { String(describing: type(of: $0)) } ?? "nil"
    appShellRouteLog(
      "ChatConversationController \(event) chatId=\(route.chatId) navCount=\(navCount) nav=\(navTypes) parent=\(parentType) root=\(rootType) presentedBy=\(presentedType)")
  }

  private func logVisualState(_ event: String, force: Bool = false) {
    let viewFrame = NSCoder.string(for: view.frame)
    let viewBounds = NSCoder.string(for: view.bounds)
    let mainFrame = NSCoder.string(for: mainView.frame)
    let mainBounds = NSCoder.string(for: mainView.bounds)
    let windowBounds = view.window.map { NSCoder.string(for: $0.bounds) } ?? "nil"
    let safeInsets = NSCoder.string(for: view.safeAreaInsets)
    let signature =
      "\(viewFrame)|\(viewBounds)|\(mainFrame)|\(mainBounds)|\(windowBounds)|\(view.window != nil)|\(view.isHidden)|\(view.alpha)|\(mainView.isHidden)|\(mainView.alpha)"
    if !force, signature == lastLayoutSignature {
      return
    }
    lastLayoutSignature = signature
    appShellRouteLog(
      "ChatConversationController \(event) chatId=\(route.chatId) viewFrame=\(viewFrame) viewBounds=\(viewBounds) mainFrame=\(mainFrame) mainBounds=\(mainBounds) windowBounds=\(windowBounds) safeInsets=\(safeInsets) hidden=\(view.isHidden) alpha=\(view.alpha) mainHidden=\(mainView.isHidden) mainAlpha=\(mainView.alpha)")
  }

  private static func profileHandle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Personal notes and media"
    }
    if let peerUserId = normalizedString(route.peerUserId) {
      return peerUserId
    }
    return route.isGroup ? "Group chat" : ""
  }

  private static func lastSeenLabel(from timestampMs: Int64) -> String? {
    guard timestampMs > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let relative = formatter.localizedString(for: date, relativeTo: Date())
    let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return "last seen \(trimmed)"
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func backgroundColor(isDark: Bool) -> UIColor {
    isDark
      ? UIColor(red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 18.0 / 255.0, alpha: 1.0)
      : UIColor(red: 245.0 / 255.0, green: 244.0 / 255.0, blue: 241.0 / 255.0, alpha: 1.0)
  }

  private static func resolvedAppearance(isDark: Bool) -> [String: Any] {
    [
      "theme": isDark ? "dark" : "light",
      "backgroundMode": "gradient",
      "wallpaperOpacity": 1.0,
      "nativeThemeId": AppThemePlateController.currentOption.rawValue,
      "nativeThemeIsDark": isDark,
    ]
  }
}

private struct ChatHomeRowView: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette

  var body: some View {
    HStack(spacing: 14) {
      ChatAvatarView(row: row, palette: palette)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(row.title)
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(palette.text)

          if row.isTyping {
            Text("Typing…")
              .font(.caption)
              .foregroundStyle(palette.secondaryText)
              .lineLimit(1)
          }

          Spacer(minLength: 8)

          if !row.timeLabel.isEmpty {
            Text(row.timeLabel)
              .font(.caption)
              .foregroundStyle(palette.secondaryText)
          }
        }

        HStack(spacing: 8) {
          Text(row.preview.isEmpty ? "No messages yet" : row.preview)
            .font(.subheadline)
            .foregroundStyle(palette.secondaryText)
            .lineLimit(2)

          Spacer(minLength: 8)

          if row.unreadCount > 0 {
            Text("\(row.unreadCount)")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(palette.buttonText)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Capsule(style: .continuous).fill(palette.accent))
          }
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(palette.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(palette.border, lineWidth: 1)
    )
  }
}

private struct ChatAvatarView: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      avatarContent
        .frame(width: 54, height: 54)
        .clipShape(Circle())

      if row.isOnline {
        Circle()
          .fill(palette.success)
          .frame(width: 12, height: 12)
          .overlay(
            Circle()
              .stroke(palette.card, lineWidth: 2)
          )
      }
    }
  }

  @ViewBuilder
  private var avatarContent: some View {
    if let avatarURI = row.avatarUri, let url = URL(string: avatarURI) {
      AsyncImage(url: url) { phase in
        switch phase {
        case let .success(image):
          image
            .resizable()
            .scaledToFill()
        default:
          fallbackAvatar
        }
      }
    } else {
      fallbackAvatar
    }
  }

  private var fallbackAvatar: some View {
    Circle()
      .fill(
        LinearGradient(
          colors: [palette.accent.opacity(0.9), palette.button.opacity(0.72)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .overlay(
        Group {
          if row.isSavedMessages {
            Image(systemName: "bookmark.fill")
              .font(.system(size: 20, weight: .semibold))
          } else {
            Text(row.avatarFallback)
              .font(.system(size: 20, weight: .bold))
          }
        }
        .foregroundStyle(palette.buttonText)
      )
  }
}

private enum AppHomeHeaderState {
  case ready
  case waitingForNetwork

  var title: String {
    switch self {
    case .ready:
      return "Chats"
    case .waitingForNetwork:
      return "Waiting for Network"
    }
  }

  var showsProgress: Bool {
    false
  }
}

private struct AppHomeStatusHeaderView: View {
  let state: AppHomeHeaderState
  let palette: AppThemePalette

  var body: some View {
    HStack(spacing: 6) {
      if state.showsProgress {
        ProgressView()
          .controlSize(.small)
          .tint(palette.secondaryText)
      }

      Text(state.title)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(palette.text)
    }
  }
}

private struct AppShellEmptyStateView: View {
  let icon: String
  let title: String
  let message: String
  let buttonTitle: String?
  let palette: AppThemePalette
  let action: (() -> Void)?

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: icon)
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(palette.accent)

      VStack(spacing: 8) {
        Text(title)
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(palette.text)

        Text(message)
          .font(.system(size: 15))
          .foregroundStyle(palette.secondaryText)
          .multilineTextAlignment(.center)
      }

      if let buttonTitle, let action {
        Button(buttonTitle, action: action)
          .buttonStyle(AppPrimaryCapsuleButtonStyle(palette: palette))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 30)
  }
}

private struct AppPrimaryCapsuleButtonStyle: ButtonStyle {
  let palette: AppThemePalette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(palette.buttonText)
      .padding(.horizontal, 22)
      .frame(height: 48)
      .background(
        Capsule(style: .continuous)
          .fill(configuration.isPressed ? palette.button.opacity(0.82) : palette.button)
      )
      .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct AppToastBanner: View {
  let message: String
  let palette: AppThemePalette

  var body: some View {
    Text(message)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(palette.text)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity)
      .background(
        Capsule(style: .continuous)
          .fill(palette.card)
      )
      .overlay(
        Capsule(style: .continuous)
          .stroke(palette.border, lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
  }
}

private struct ContactSearchView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let onResult: ([String: Any]) -> Void
  @State private var query = ""
  @State private var results: [ContactSearchUser] = []
  @State private var selectedUser: ContactSearchUser?
  @State private var savedUserIDs = Set<String>()
  @State private var isLoading = false
  @State private var statusText = "Find by username, phone, or user ID"
  @FocusState private var isQueryFieldFocused: Bool

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      Section {
        TextField("Search username, phone, or ID", text: $query)
          .focused($isQueryFieldFocused)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.search)
          .onSubmit {
            Task {
              await performSearch()
            }
          }
      }
      .listRowBackground(palette.card)

      if let selectedUser {
        Section {
          VStack(spacing: 16) {
            Circle()
              .fill(palette.card)
              .frame(width: 78, height: 78)
              .overlay {
                Text(String(selectedUser.username.prefix(1)).uppercased())
                  .font(.system(size: 28, weight: .semibold))
                  .foregroundStyle(palette.accent)
              }

            VStack(spacing: 4) {
              Text(selectedUser.username)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.text)
              Text(selectedUser.subtitle)
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
            }

            HStack(spacing: 10) {
              Button {
                onResult(["action": "chat", "user": selectedUser.payload])
                dismiss()
              } label: {
                Label("Chat", systemImage: "message.fill")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)

              Button {
                onResult(["action": "call", "user": selectedUser.payload])
                dismiss()
              } label: {
                Label("Call", systemImage: "phone.fill")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
            }

            Button {
              savedUserIDs.insert(selectedUser.userID)
              onResult(["action": "saveContact", "user": selectedUser.payload])
            } label: {
              Label(
                savedUserIDs.contains(selectedUser.userID) ? "Saved" : "Add Contact",
                systemImage: savedUserIDs.contains(selectedUser.userID) ? "checkmark.circle.fill" : "person.badge.plus"
              )
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(savedUserIDs.contains(selectedUser.userID))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 16)
        }
        .listRowBackground(palette.card)
      } else if isLoading {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Searching")
              .foregroundStyle(.secondary)
          }
        }
        .listRowBackground(palette.card)
      } else if !results.isEmpty {
        Section("Results") {
          ForEach(results) { user in
            Button {
              selectedUser = user
              isQueryFieldFocused = false
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(user.username)
                  .foregroundStyle(.primary)
                Text(user.subtitle)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        .listRowBackground(palette.card)
      } else {
        Section {
          Text(statusText)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .listRowBackground(palette.card)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("New Chat")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      DispatchQueue.main.async {
        isQueryFieldFocused = true
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Close") {
          onResult(["action": "cancel"])
          dismiss()
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Search") {
          Task {
            await performSearch()
          }
        }
        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
      }
    }
  }

  @MainActor
  private func performSearch() async {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      results = []
      statusText = "Find by username, phone, or user ID"
      return
    }

    isLoading = true
    selectedUser = nil
    defer { isLoading = false }

    do {
      results = try await ContactSearchService.search(config: config, query: trimmedQuery)
      statusText = results.isEmpty ? "No user found" : ""
    } catch {
      results = []
      statusText = error.localizedDescription
    }
  }
}

private struct ContactSearchUser: Identifiable {
  let userID: String
  let username: String
  let handle: String?
  let phoneNumber: String?
  let profileImage: String?
  let publicKey: String?

  var id: String { userID }

  var subtitle: String {
    if let phoneNumber { return phoneNumber }
    if let handle, !handle.isEmpty, !Self.looksLikeUUID(handle), handle.localizedCaseInsensitiveCompare(username) != .orderedSame {
      return "@\(handle.trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
    }
    return "User is in Vibegram"
  }

  var payload: [String: Any] {
    var value: [String: Any] = [
      "userId": userID,
      "id": userID,
      "username": username,
      "displayName": username,
    ]
    if let handle { value["handle"] = handle }
    if let phoneNumber { value["phoneNumber"] = phoneNumber }
    if let profileImage { value["profileImage"] = profileImage }
    if let publicKey { value["publicKey"] = publicKey }
    return value
  }

  init?(payload: [String: Any]) {
    guard let userID = Self.normalizedString(payload["userId"] ?? payload["id"]) else {
      return nil
    }

    self.userID = userID
    let rawHandle = Self.normalizedString(payload["username"] ?? payload["handle"])
    let rawDisplayName =
      Self.normalizedString(
        payload["displayName"] ?? payload["display_name"] ?? payload["fullName"] ?? payload["full_name"]
          ?? payload["name"])
      ?? rawHandle
    self.username =
      rawDisplayName.flatMap { Self.looksLikeUUID($0) ? nil : $0 }
      ?? rawHandle.flatMap { Self.looksLikeUUID($0) ? nil : $0 }
      ?? "Vibegram User"
    self.handle = rawHandle
    self.phoneNumber = Self.normalizedString(payload["phoneNumber"] ?? payload["phone_number"] ?? payload["phone"])
    self.profileImage = Self.normalizedString(
      payload["profileImage"] ?? payload["profile_image"] ?? payload["avatarUrl"] ?? payload["avatar_url"])
    self.publicKey = Self.normalizedString(
      payload["publicKey"] ?? payload["public_key"] ?? payload["friendKey"] ?? payload["friendPublicKey"])
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
  }
}

private enum ContactSearchService {
  static func search(config: AppSessionConfig, query: String) async throws -> [ContactSearchUser] {
    guard let url = buildSearchURL(apiBaseURLString: config.apiBaseURLString, query: query) else {
      throw ContactSearchServiceError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 14
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ContactSearchServiceError.invalidResponse
    }

    if httpResponse.statusCode == 404 {
      return []
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ContactSearchServiceError.http(httpResponse.statusCode, body)
    }

    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return parseUsers(from: object, excluding: config.userID)
  }

  private static func buildSearchURL(apiBaseURLString: String, query: String) -> URL? {
    var base = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    guard !base.isEmpty else { return nil }

    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    let endpoint: String
    switch queryKind(for: query) {
    case .userID:
      let encodedID = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
      endpoint = "/user/\(encodedID)"
    case .phone:
      let encodedPhone =
        query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
      endpoint = "/user/phone/\(encodedPhone)"
    case .username:
      let normalized =
        query.hasPrefix("@") ? String(query.dropFirst()) : query
      let encodedName =
        normalized.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        ?? normalized.lowercased()
      endpoint = "/user/name/\(encodedName)"
    }

    return URL(string: pathBase + endpoint)
  }

  private static func parseUsers(from value: Any, excluding currentUserID: String) -> [ContactSearchUser] {
    let rawEntries: [[String: Any]]
    if let array = value as? [[String: Any]] {
      rawEntries = array
    } else if let dictionary = value as? [String: Any] {
      if let nestedArray = dictionary["data"] as? [[String: Any]] {
        rawEntries = nestedArray
      } else if let nestedDictionary = dictionary["data"] as? [String: Any] {
        rawEntries = [nestedDictionary]
      } else {
        rawEntries = [dictionary]
      }
    } else {
      rawEntries = []
    }

    let currentUpper = currentUserID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    var usersByID: [String: ContactSearchUser] = [:]
    for rawEntry in rawEntries {
      guard let user = ContactSearchUser(payload: rawEntry) else { continue }
      let normalizedID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      if normalizedID.isEmpty || normalizedID == currentUpper { continue }
      usersByID[normalizedID] = user
    }
    return Array(usersByID.values).sorted {
      $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
    }
  }

  private enum QueryKind {
    case userID
    case phone
    case username
  }

  private static func queryKind(for query: String) -> QueryKind {
    let digitsCount = query.filter(\.isNumber).count
    let phoneCharacters = Set(query).isSubset(of: Set("0123456789+-() ".map { $0 }))
    if phoneCharacters && digitsCount >= 7 {
      return .phone
    }
    if looksLikeUUID(query) {
      return .userID
    }
    return .username
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return UUID(uuidString: trimmed.uppercased()) != nil
  }
}

private enum ContactSearchServiceError: LocalizedError {
  case invalidURL
  case invalidResponse
  case http(Int, String)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case let .http(statusCode, body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Search unavailable (\(statusCode))\(trimmed.isEmpty ? "" : ": \(trimmed)")"
    }
  }
}

private struct ChatCreateResult {
  let chatID: String
  let messages: [[String: Any]]
}

private enum ChatDirectMessageService {
  static func startChat(config: AppSessionConfig, friendID: String) async throws -> ChatCreateResult {
    let request = try buildRequest(config: config, friendID: friendID)

    switch config.transportMode {
    case .offline:
      throw ChatDirectMessageServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatDirectMessageServiceError.transportUnavailable("bridge_text")
    case .packetMesh:
      let packetSnapshot = try await PacketRuntime.shared.ensureStarted(config: config)
      let session = PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot)
      return try await perform(request, session: session)
    case .direct:
      do {
        let result = try await perform(request, session: .shared)
        PacketRuntime.shared.stop(resetToDirect: true)
        Task.detached {
          await PacketBootstrapService.prefetchIfNeeded(config: config)
        }
        return result
      } catch {
        guard shouldAttemptPacketFallback(for: error) else {
          throw error
        }
        let packetSnapshot = try await PacketRuntime.shared.ensureStarted(config: config)
        let session = PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot)
        return try await perform(request, session: session)
      }
    }
  }

  private static func buildRequest(config: AppSessionConfig, friendID: String) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }

    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard let url = URL(string: "\(pathBase)/chat") else {
      throw ChatDirectMessageServiceError.invalidURL
    }

    let body: [String: Any] = [
      "myId": config.userID,
      "friendId": friendID,
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private static func perform(_ request: URLRequest, session: URLSession) async throws -> ChatCreateResult {
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ChatDirectMessageServiceError.http(httpResponse.statusCode, body)
    }

    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    guard let payload = object as? [String: Any] else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    guard let chatID = normalizedString(payload["chatId"] ?? payload["chat_id"]) else {
      throw ChatDirectMessageServiceError.invalidPayload
    }

    let messages = (payload["messages"] as? [[String: Any]]) ?? []
    return ChatCreateResult(chatID: chatID, messages: messages)
  }

  private static func shouldAttemptPacketFallback(for error: Error) -> Bool {
    if let serviceError = error as? ChatDirectMessageServiceError {
      switch serviceError {
      case let .http(statusCode, _):
        return statusCode >= 500
      case .transportUnavailable:
        return false
      default:
        return true
      }
    }
    return true
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

private enum ChatDirectMessageServiceError: LocalizedError {
  case invalidURL
  case invalidResponse
  case invalidPayload
  case http(Int, String)
  case transportUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case .invalidPayload:
      return "The chat response could not be parsed."
    case let .http(statusCode, body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Request failed with status \(statusCode)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
    case let .transportUnavailable(mode):
      return "Transport mode \(mode) is not available in the standalone native app."
    }
  }
}
