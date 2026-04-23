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
    self.init(
      chatId: row.chatId,
      title: row.title,
      peerUserId: row.peerUserId,
      avatarURI: row.avatarUri,
      isGroup: row.isGroup,
      initialRows: row.previewRows
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
final class AppShellCoordinator: ObservableObject {
  @Published var selectedTab: AppShellTab = .chats
  @Published var presentedChat: PresentedChatRoute?
  @Published var chatOpenRequestID: Int = 0

  private var activeRequestID: Int?
  private weak var activeChatController: ChatConversationController?
  private let pushTransitionDelegate = ChatPushTransitionDelegate()

  func openChat(_ route: ChatRoute) {
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
    dismissActiveChatController(animated: true)
  }

  // MARK: - UIKit presentation

  private func presentChatController(route: ChatRoute, requestID: Int) {
    // If another chat was already presented, dismiss it first
    if activeRequestID != nil, activeRequestID != requestID {
      appShellRouteLog(
        "presentChatController replacing previous requestId=\(activeRequestID.map(String.init) ?? "nil") with requestId=\(requestID)")
      dismissActiveChatController(animated: false)
    }

    guard activeRequestID != requestID else { return }

    guard let window = Self.activeWindow() else {
      appShellRouteLog("presentChatController FAILED requestId=\(requestID) reason=noWindow")
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

    let isDark = window.traitCollection.userInterfaceStyle == .dark
    let controller = ChatConversationController(
      route: route,
      isDark: isDark,
      onClose: { [weak self] in
        self?.closePresentedChat(requestID: requestID)
      }
    )
    controller.modalPresentationStyle = .fullScreen
    controller.transitioningDelegate = pushTransitionDelegate
    activeRequestID = requestID
    activeChatController = controller

    appShellRouteLog(
      "presentChatController presenting requestId=\(requestID) chatId=\(route.chatId) presenter=\(String(describing: type(of: presenter)))")
    presenter.present(controller, animated: true)
  }

  private func dismissActiveChatController(animated: Bool) {
    guard let controller = activeChatController else {
      activeRequestID = nil
      return
    }

    activeRequestID = nil
    activeChatController = nil

    if controller.presentingViewController != nil {
      controller.dismiss(animated: animated)
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
    0.22
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

      let fromView = transitionContext.view(forKey: .from)

      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveEaseInOut],
        animations: {
          toView.frame = finalFrame
          fromView?.frame = fromView?.frame.offsetBy(dx: -(finalFrame.width * 0.3), dy: 0) ?? .zero
        },
        completion: { finished in
          fromView?.frame = finalFrame
          transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
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
        toView.frame = initialFrame.offsetBy(dx: -(initialFrame.width * 0.3), dy: 0)
        containerView.insertSubview(toView, belowSubview: fromView)
      }

      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveEaseInOut],
        animations: {
          fromView.frame = initialFrame.offsetBy(dx: initialFrame.width, dy: 0)
          toView?.frame = initialFrame
        },
        completion: { finished in
          transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        }
      )
    }
  }
}

@MainActor
private final class ChatsViewModel: ObservableObject {
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
      rows = try await ChatHomeService.fetchChats(config: config)
      hasLoaded = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct AppRootView: View {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(AppThemePlateController.storageKey) private var themePlateRaw =
    AppThemePlateOption.glacier.rawValue
  @StateObject private var coordinator = AppShellCoordinator()
  @StateObject private var toastController = AppToastController.shared

  private var palette: AppThemePalette {
    AppThemePalette.resolve(
      for: colorScheme,
      plate: AppThemePlateOption(rawValue: themePlateRaw) ?? .glacier
    )
  }

  var body: some View {
    ZStack {
      TabView(selection: $coordinator.selectedTab) {
        ContactsRootView()
          .tabItem {
            Label("Contacts", systemImage: "person.2")
          }
          .tag(AppShellTab.contacts)

        CallsRootView()
          .tabItem {
            Label("Calls", systemImage: "phone")
          }
          .tag(AppShellTab.calls)

        ChatsRootView()
          .tabItem {
            Label("Chats", systemImage: "message")
          }
          .tag(AppShellTab.chats)

        SettingsRootView()
          .tabItem {
            Label("Settings", systemImage: "gearshape")
          }
          .tag(AppShellTab.settings)
      }
      .tint(palette.accent)
      .background(palette.background.ignoresSafeArea())
      .toolbarBackground(.hidden, for: .tabBar)
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
    .overlay(alignment: .bottom) {
      if let message = toastController.message {
        AppToastBanner(message: message, palette: palette)
          .padding(.horizontal, 20)
          .padding(.bottom, 30)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.22), value: coordinator.presentedChat?.requestID)
    .animation(.spring(response: 0.3, dampingFraction: 0.82), value: toastController.message)
    .environmentObject(coordinator)
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
  @State private var isShowingStorySheet = false
  @State private var isStartingChat = false
  @State private var errorMessage: String?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var headerState: AppHomeHeaderState {
    if isStartingChat {
      return .updating
    }
    if errorMessage != nil || model.errorMessage != nil {
      return .connecting
    }
    if model.isLoading && model.rows.isEmpty {
      return .connecting
    }
    if model.isLoading {
      return .updating
    }
    if model.rows.isEmpty && (errorMessage != nil || model.errorMessage != nil) {
      return .connecting
    }
    return .ready
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.rows.isEmpty && model.isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
        } else if model.rows.isEmpty {
          AppShellEmptyStateView(
            icon: "message",
            title: "No Messages Yet",
            message: errorMessage ?? model.errorMessage ?? "Start a conversation to catch the vibe.",
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
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .background(palette.background)
        }
      }
      .background(palette.background.ignoresSafeArea())
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          EditButton()
            .disabled(model.rows.isEmpty)
        }
        ToolbarItem(placement: .principal) {
          AppHomeStatusHeaderView(state: headerState, palette: palette)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            isShowingStorySheet = true
          } label: {
            AppVectorIcon(glyph: .story, tint: palette.secondaryText)
              .frame(width: 22, height: 22)
          }

          Button {
            isShowingSearch = true
          } label: {
            AppVectorIcon(glyph: .compose, tint: palette.secondaryText)
              .frame(width: 22, height: 22)
          }
        }
      }
      .refreshable {
        await model.refresh()
      }
      .task {
        await model.loadIfNeeded()
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
      .sheet(isPresented: $isShowingStorySheet) {
        StorySheetPlaceholderView(palette: palette)
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
      action == "select",
      let rawUser = payload["user"] as? [String: Any],
      let user = ContactSearchUser(payload: rawUser)
    else {
      isShowingSearch = false
      errorMessage = "The selected user could not be opened."
      return
    }

    isShowingSearch = false
    Task {
      await openChat(for: user)
    }
  }

  @MainActor
  private func openChat(for user: ContactSearchUser) async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    do {
      let result = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      coordinator.openChat(
        ChatRoute(
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
      )
      await model.refresh()
    } catch {
      errorMessage = error.localizedDescription
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
      action == "select",
      let rawUser = payload["user"] as? [String: Any],
      let user = ContactSearchUser(payload: rawUser)
    else {
      isShowingSearch = false
      errorMessage = "The selected contact could not be opened."
      return
    }

    isShowingSearch = false
    Task {
      await openChat(for: user)
    }
  }

  @MainActor
  private func openChat(for user: ContactSearchUser) async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    do {
      let result = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      coordinator.openChat(
        ChatRoute(
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
      )
    } catch {
      errorMessage = error.localizedDescription
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
  private var lastLayoutSignature: String?

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
    logLifecycle("viewDidAppear")
    logVisualState("viewDidAppear", force: true)
    guard !didInitialScroll else { return }
    didInitialScroll = true
    DispatchQueue.main.async { [weak self] in
      self?.logLifecycle("initialScrollToBottom")
      self?.mainView.scrollToBottom(animated: false)
      self?.logVisualState("afterInitialScroll", force: true)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
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

  private func applyRoute(forceChannelRefresh: Bool) {
    view.backgroundColor = Self.backgroundColor(isDark: isDark)
    currentPage = .chat
    appShellRouteLog(
      "ChatConversationController applyRoute chatId=\(route.chatId) title=\(route.title) forceRefresh=\(forceChannelRefresh) initialRows=\(route.initialRows.count)")

    let surfaceId = "native_chat_\(route.chatId)"
    mainView.surfaceId = surfaceId
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
    mainView.setStatusAuthorityEnabled(true)
    mainView.setInputPlaceholder(route.chatId == "saved_messages" ? "Saved Message" : "Message")
    mainView.setInputBarEnabled(true)
    mainView.setNativeSendEnabled(true)
    mainView.setStandaloneProfileMode(false)
    mainView.setPage(ChatConversationPage.chat.rawValue, animated: false)
    appShellRouteLog(
      "ChatConversationController configuredSurface chatId=\(route.chatId) surfaceId=\(surfaceId) peerUserId=\(route.peerUserId ?? "") isGroup=\(route.isGroup) headerMode=\(route.chatId == "saved_messages" ? "savedmessages" : "default") windowAttached=\(view.window != nil)")

    refreshHeaderState()
    refreshRows()
    logVisualState("afterApplyRoute", force: true)

    if forceChannelRefresh {
      closeOpenedChatChannel()
    }
    openChatChannelIfNeeded()
  }

  private func openChatChannelIfNeeded() {
    guard openedChatId != route.chatId else { return }
    appShellRouteLog(
      "ChatConversationController openChatChannel chatId=\(route.chatId) peerUserId=\(route.peerUserId ?? "")")
    let snapshot = ChatEngine.shared.openChatChannel([
      "chatId": route.chatId,
      "peerUserId": route.peerUserId ?? "",
    ])
    appShellRouteLog(
      "ChatConversationController openChatChannelResult chatId=\(route.chatId) snapshotState=\(Self.normalizedString(snapshot["state"]) ?? "nil") connected=\(snapshot["connected"] as? Bool == true) snapshotKeys=\(snapshot.keys.sorted())")
    openedChatId = route.chatId
  }

  private func closeOpenedChatChannel() {
    guard let openedChatId else { return }
    appShellRouteLog("ChatConversationController closeChatChannel chatId=\(openedChatId)")
    _ = ChatEngine.shared.closeChatChannel(["chatId": openedChatId])
    self.openedChatId = nil
  }

  private func refreshRows() {
    let nativeRows = ChatEngine.shared.getChatRows(["chatId": route.chatId])
    let rows = nativeRows.isEmpty ? route.initialRows : nativeRows
    let firstRowID = Self.normalizedString(rows.first?["id"]) ?? Self.normalizedString(rows.first?["messageId"]) ?? "nil"
    appShellRouteLog(
      "ChatConversationController refreshRows chatId=\(route.chatId) rows=\(rows.count) nativeRows=\(nativeRows.count) initialRows=\(route.initialRows.count) source=\(nativeRows.isEmpty ? "initial" : "native") firstRowId=\(firstRowID)")
    mainView.setRows(rows)
    logVisualState("afterRefreshRows")
  }

  private func refreshHeaderState() {
    mainView.setHeaderSubtitle(Self.headerSubtitle(for: route))
    mainView.setIsOnline(Self.isOnline(for: route))
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
      return
    case "headerAgentPressed":
      return
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

    refreshHeaderState()

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
    let plate = AppThemePlateController.currentOption

    let wallpaperGradient: [String]
    let patternGradient: [String]
    let patternOpacity: Double

    switch (plate, isDark) {
    case (.glacier, true):
      wallpaperGradient = ["#131325", "#0D0D1F"]
      patternGradient = ["#115E59", "#0891B2", "#0284C7"]
      patternOpacity = 0.12
    case (.glacier, false):
      wallpaperGradient = ["#F9F3EA", "#EFE6D9"]
      patternGradient = ["#5A8A66", "#5A6675", "#8A75A3"]
      patternOpacity = 0.06
    case (.zen, true):
      wallpaperGradient = ["#1A1528", "#120E20"]
      patternGradient = ["#7C3AED", "#6D28D9", "#5B21B6"]
      patternOpacity = 0.14
    case (.zen, false):
      wallpaperGradient = ["#F5F3FB", "#EDE8F5"]
      patternGradient = ["#7C3AED", "#6366F1", "#3F51B5"]
      patternOpacity = 0.06
    case (.ocean, true):
      wallpaperGradient = ["#0F1A24", "#0A1520"]
      patternGradient = ["#0277BD", "#0288D1", "#039BE5"]
      patternOpacity = 0.13
    case (.ocean, false):
      wallpaperGradient = ["#F0F7FA", "#E3EFF5"]
      patternGradient = ["#0277BD", "#0288D1", "#4FC3F7"]
      patternOpacity = 0.06
    case (.obsidian, true):
      wallpaperGradient = ["#111118", "#0D0D14"]
      patternGradient = ["#1565C0", "#1E88E5", "#42A5F5"]
      patternOpacity = 0.10
    case (.obsidian, false):
      wallpaperGradient = ["#F2F4F8", "#E8EBF0"]
      patternGradient = ["#1565C0", "#1976D2", "#42A5F5"]
      patternOpacity = 0.06
    }

    return [
      "theme": isDark ? "dark" : "light",
      "backgroundMode": "gradient",
      "wallpaperGradient": wallpaperGradient,
      "wallpaperOpacity": 1.0,
      "wallpaperPatternGradient": patternGradient,
      "wallpaperPatternLocations": [0.0, 0.5, 1.0],
      "wallpaperPatternOpacity": patternOpacity,
      "wallpaperMaskKey": "doodles",
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
        Text(row.avatarFallback)
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(palette.buttonText)
      )
  }
}

private enum AppHomeHeaderState {
  case connecting
  case updating
  case ready

  var title: String {
    switch self {
    case .connecting:
      return "Connecting"
    case .updating:
      return "Updating"
    case .ready:
      return "Chats"
    }
  }

  var subtitle: String {
    switch self {
    case .connecting:
      return "Waiting for the secure link"
    case .updating:
      return "Syncing recent messages"
    case .ready:
      return "Secure messages"
    }
  }

  var showsProgress: Bool {
    switch self {
    case .connecting, .updating:
      return true
    case .ready:
      return false
    }
  }
}

private struct AppHomeStatusHeaderView: View {
  let state: AppHomeHeaderState
  let palette: AppThemePalette

  var body: some View {
    VStack(spacing: 2) {
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

      Text(state.subtitle)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.secondaryText)
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

private struct StorySheetPlaceholderView: View {
  @Environment(\.dismiss) private var dismiss
  let palette: AppThemePalette

  var body: some View {
    NavigationStack {
      AppShellEmptyStateView(
        icon: "camera.macro",
        title: "Stories",
        message: "The story composer from the old app still needs to be linked into this standalone target.",
        buttonTitle: nil,
        palette: palette,
        action: nil
      )
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("Stories")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close") {
            dismiss()
          }
        }
      }
    }
  }
}

private struct ContactSearchView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let onResult: ([String: Any]) -> Void
  @State private var query = ""
  @State private var results: [ContactSearchUser] = []
  @State private var isLoading = false
  @State private var statusText = "Find by username, phone, or user ID"

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      Section {
        TextField("Search username, phone, or ID", text: $query)
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

      if isLoading {
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
              onResult(["action": "select", "user": user.payload])
              dismiss()
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
  let phoneNumber: String?
  let profileImage: String?
  let publicKey: String?

  var id: String { userID }

  var subtitle: String {
    phoneNumber ?? userID
  }

  var payload: [String: Any] {
    var value: [String: Any] = [
      "userId": userID,
      "id": userID,
      "username": username,
    ]
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
    self.username = Self.normalizedString(payload["username"] ?? payload["name"]) ?? userID
    self.phoneNumber = Self.normalizedString(payload["phoneNumber"] ?? payload["phone"])
    self.profileImage = Self.normalizedString(payload["profileImage"])
    self.publicKey = Self.normalizedString(payload["publicKey"])
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
