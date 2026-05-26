import SwiftUI
import UIKit
import OSLog

enum AppUITrace {
  static let subsystem = "com.mohammadshayani.vibe.native"
  private static let logger = Logger(subsystem: subsystem, category: "UITrace")

  static func notice(_ message: String) {
    logger.notice("\(message, privacy: .public)")
  }

  static func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
    NSLog("[VibeUITrace][error] %@", message)
  }

  static func fault(_ message: String) {
    logger.fault("\(message, privacy: .public)")
    NSLog("[VibeUITrace][fault] %@", message)
  }
}

final class AppUIStallWatchdog {
  static let shared = AppUIStallWatchdog()

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.mohammadshayani.vibe.ui-stall-watchdog", qos: .utility)
  private let stallThresholdSeconds: TimeInterval = 2.0
  private var timer: DispatchSourceTimer?
  private var started = false
  private var active = false
  private var lastMainBeatAt = ProcessInfo.processInfo.systemUptime
  private var latestContext = "launch"
  private var lastReportedStallBucket = -1
  private var wasStalled = false

  private init() {}

  func start(context: String) {
    var shouldStart = false
    locked {
      latestContext = context
      active = true
      lastMainBeatAt = ProcessInfo.processInfo.systemUptime
      if !started {
        started = true
        shouldStart = true
      }
    }
    guard shouldStart else { return }
    AppUITrace.notice("watchdog start thresholdMs=\(Int(stallThresholdSeconds * 1000)) context=\(context)")
    scheduleMainBeat()

    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now() + 1.0, repeating: 0.75)
    source.setEventHandler { [weak self] in
      self?.checkForStall()
    }
    locked {
      timer = source
    }
    source.resume()
  }

  func setActive(_ isActive: Bool, context: String) {
    locked {
      active = isActive
      latestContext = context
      lastMainBeatAt = ProcessInfo.processInfo.systemUptime
      lastReportedStallBucket = -1
      wasStalled = false
    }
    AppUITrace.notice("watchdog active=\(isActive ? "Y" : "N") context=\(context)")
  }

  func updateContext(_ context: String) {
    locked {
      latestContext = context
    }
  }

  private func scheduleMainBeat() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self else { return }
      self.recordMainBeat()
      self.scheduleMainBeat()
    }
  }

  private func recordMainBeat() {
    let now = ProcessInfo.processInfo.systemUptime
    let recovered: (blockedMs: Int, context: String)? = locked {
      let elapsed = now - lastMainBeatAt
      lastMainBeatAt = now
      lastReportedStallBucket = -1
      guard active, wasStalled else { return nil }
      wasStalled = false
      return (Int(elapsed * 1000), latestContext)
    }
    if let recovered {
      AppUITrace.error(
        "main-thread-recovered blockedMs=\(recovered.blockedMs) context=\(recovered.context)"
      )
    }
  }

  private func checkForStall() {
    let now = ProcessInfo.processInfo.systemUptime
    let stalled: (blockedMs: Int, context: String)? = locked {
      guard active else { return nil }
      let elapsed = now - lastMainBeatAt
      guard elapsed >= stallThresholdSeconds else { return nil }
      let bucket = Int(elapsed)
      guard bucket != lastReportedStallBucket else { return nil }
      lastReportedStallBucket = bucket
      wasStalled = true
      return (Int(elapsed * 1000), latestContext)
    }
    if let stalled {
      AppUITrace.fault(
        "main-thread-stall blockedMs=\(stalled.blockedMs) context=\(stalled.context)"
      )
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private func appShellRouteLog(_ message: String) {
  let tagged = "[AppShellRoute] \(message)"
  if Thread.isMainThread {
    AppUIStallWatchdog.shared.updateContext(tagged)
  }
  AppUITrace.notice(tagged)
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
  let unreadCount: Int
  let initialRows: [[String: Any]]

  var id: String { chatId }

  init(
    chatId: String,
    title: String,
    peerUserId: String?,
    avatarURI: String?,
    isGroup: Bool,
    unreadCount: Int = 0,
    initialRows: [[String: Any]]
  ) {
    self.chatId = chatId
    self.title = title
    self.peerUserId = peerUserId
    self.avatarURI = avatarURI
    self.isGroup = isGroup
    self.unreadCount = max(0, unreadCount)
    self.initialRows = initialRows
  }

  init(row: ChatHomeListRow) {
    let cachedRows = row.initialMessages.isEmpty ? row.previewRows : row.initialMessages
    self.init(
      chatId: row.chatId,
      title: row.title,
      peerUserId: row.peerUserId,
      avatarURI: row.avatarUri,
      isGroup: row.isGroup,
      unreadCount: row.unreadCount,
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
      unreadCount: 0,
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

struct PresentedChatProfileRoute: Identifiable, Hashable {
  let requestID: Int
  let route: ChatRoute

  var id: Int { requestID }
}

private enum AppChatNavigationAction {
  case avatar
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
    VibeNativeCallOverlayPresenter.shared.showOutgoing(payload: payload, status: status)
    let accepted = (status["signalingAccepted"] as? Bool) ?? true
    if !accepted {
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
private final class VibeNativeCallOverlayPresenter {
  static let shared = VibeNativeCallOverlayPresenter()

  private var observer: NSObjectProtocol?
  private var window: UIWindow?
  private var controller: VibeNativeCallOverlayController?

  private init() {}

  func startObserving() {
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: VibeNativeCallEngine.stateDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
        let state = notification.userInfo?["state"] as? [String: Any]
      else { return }
      Task { @MainActor in
        self.applyEngineState(state)
      }
    }
  }

  func showOutgoing(payload: [String: Any], status: [String: Any]) {
    startObserving()
    var state = status
    for key in [
      "event", "callId", "callType", "toUserId", "toUserName", "toUserImage", "chatId",
      "signalingAccepted", "signalingQueued", "failureReason",
    ] where state[key] == nil {
      state[key] = payload[key]
    }
    if state["direction"] == nil {
      state["direction"] = "outgoing"
    }
    present(state: state, retryPayload: payload)
  }

  func refreshFromEngine() {
    startObserving()
    applyEngineState(VibeNativeCallEngine.shared.getStatus())
  }

  private func applyEngineState(_ state: [String: Any]) {
    let stateValue = normalizedString(state["state"]) ?? ""
    let direction = normalizedString(state["direction"]) ?? ""
    guard ["ringing", "starting", "connecting", "active", "failed", "ended"].contains(stateValue)
      || (stateValue == "configured" && controller != nil)
    else { return }

    if stateValue == "ended" {
      present(state: state, retryPayload: nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
        guard let self, self.controller?.callId == self.normalizedString(state["callId"] ?? state["call_id"])
        else { return }
        self.hide()
      }
      return
    }

    if direction == "incoming", stateValue == "ringing", UIApplication.shared.applicationState == .active {
      VibeNativeCallManager.shared.presentForegroundIncomingBanner(state)
      return
    }

    if controller == nil, direction == "incoming" || direction == "outgoing" || stateValue == "failed" {
      present(state: state, retryPayload: nil)
    } else {
      controller?.applyState(state, retryPayload: nil)
    }
  }

  private func present(state: [String: Any], retryPayload: [String: Any]?) {
    guard let scene = activeWindowScene() else {
      NSLog("[VibeNativeCall][Overlay] present skipped missing window scene")
      return
    }

    let controller = self.controller ?? VibeNativeCallOverlayController()
    controller.onDismiss = { [weak self] in self?.hide() }
    controller.applyState(state, retryPayload: retryPayload)

    if window == nil {
      let nextWindow = UIWindow(windowScene: scene)
      nextWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
      nextWindow.backgroundColor = .clear
      nextWindow.rootViewController = controller
      nextWindow.makeKeyAndVisible()
      window = nextWindow
      self.controller = controller
    } else if self.controller == nil {
      window?.rootViewController = controller
      self.controller = controller
      window?.isHidden = false
    } else {
      window?.isHidden = false
    }

    NSLog(
      "[VibeNativeCall][Overlay] present state=%@ direction=%@ callId=%@",
      normalizedString(state["state"]) ?? "-",
      normalizedString(state["direction"]) ?? "-",
      normalizedString(state["callId"] ?? state["call_id"]) ?? "-"
    )
  }

  private func hide() {
    controller?.cancelTimers()
    controller = nil
    window?.isHidden = true
    window = nil
  }

  private func activeWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first(where: { $0.activationState == .foregroundActive })
      ?? scenes.first(where: { $0.activationState == .foregroundInactive })
      ?? scenes.first
  }

  private func normalizedString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

@MainActor
private final class VibeNativeCallOverlayModel: ObservableObject {
  @Published var currentState: [String: Any] = [:]
  @Published var retryPayload: [String: Any]?
  @Published var inlineError: String?

  var onDismiss: (() -> Void)?
  private var timeoutWork: DispatchWorkItem?

  var callId: String? {
    normalizedString(currentState["callId"] ?? currentState["call_id"])
  }

  var displayName: String {
    normalizedString(currentState["toUserName"] ?? currentState["to_user_name"])
      ?? normalizedString(currentState["fromUserName"] ?? currentState["from_user_name"])
      ?? normalizedString(currentState["name"])
      ?? "Vibe Call"
  }

  var initial: String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "V"
  }

  var directionTitle: String {
    let type = normalizedString(currentState["callType"] ?? currentState["call_type"]) == "video" ? "Video" : "Voice"
    switch normalizedString(currentState["direction"]) {
    case "incoming": return "Incoming \(type) Call"
    case "outgoing": return "Outgoing \(type) Call"
    default: return "\(type) Call"
    }
  }

  var statusText: String {
    if let inlineError { return inlineError }
    switch normalizedString(currentState["state"]) ?? "ringing" {
    case "ringing", "starting": return "Ringing..."
    case "connecting": return "Connecting..."
    case "active": return "Connected"
    case "failed": return friendlyFailureText
    case "ended": return "Call ended"
    default: return "Connecting..."
    }
  }

  var actionSet: VibeNativeCallOverlayActionSet {
    let stateValue = normalizedString(currentState["state"]) ?? "ringing"
    let direction = normalizedString(currentState["direction"]) ?? ""
    if stateValue == "failed" { return .failed }
    if direction == "incoming", stateValue == "ringing" { return .incoming }
    if stateValue == "ended" { return .ended }
    return .active
  }

  func applyState(_ state: [String: Any], retryPayload: [String: Any]?) {
    currentState = mergedState(existing: currentState, incoming: state)
    inlineError = nil
    if let retryPayload {
      self.retryPayload = retryPayload
    }
    if self.retryPayload == nil, normalizedString(currentState["direction"]) == "outgoing" {
      self.retryPayload = outgoingPayload(from: currentState)
    }
    scheduleTimeoutIfNeeded()
  }

  func cancelTimers() {
    timeoutWork?.cancel()
    timeoutWork = nil
  }

  func accept() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    applyState(VibeNativeCallEngine.shared.acceptIncoming(currentPayload()), retryPayload: nil)
  }

  func end() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    applyState(VibeNativeCallEngine.shared.endCall(currentPayload()), retryPayload: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
      self?.onDismiss?()
    }
  }

  func retry() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    guard var payload = retryPayload ?? outgoingPayload(from: currentState) else {
      inlineError = "Call could not start. Open the chat and try again."
      return
    }
    guard let config = AppSessionConfig.current else {
      inlineError = "Call could not start. Sign in again and retry."
      return
    }
    _ = VibeNativeCallEngine.shared.configure(config.payload)
    let now = Int(Date().timeIntervalSince1970 * 1000)
    payload["event"] = "call-start"
    payload["callId"] = "call_\(now)_\(UUID().uuidString.prefix(8))"
    payload["direction"] = "outbound"
    retryPayload = payload
    applyState(VibeNativeCallEngine.shared.startOutgoing(payload), retryPayload: payload)
  }

  func close() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onDismiss?()
  }

  private var friendlyFailureText: String {
    if let reason = normalizedString(currentState["failureReason"]) {
      return reason
    }
    if boolValue(currentState["signalingQueued"]) {
      return "Still waiting for the connection. You can retry the call."
    }
    return "Call could not start. Check the connection and try again."
  }

  private func scheduleTimeoutIfNeeded() {
    timeoutWork?.cancel()
    timeoutWork = nil
    let stateValue = normalizedString(currentState["state"]) ?? ""
    let direction = normalizedString(currentState["direction"]) ?? ""
    guard direction == "outgoing", ["ringing", "starting"].contains(stateValue), let callId else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self,
        self.callId == callId,
        ["ringing", "starting"].contains(self.normalizedString(self.currentState["state"]) ?? "")
      else { return }
      self.applyState(
        VibeNativeCallEngine.shared.failCall(self.currentPayload(), reason: "No answer. You can retry the call."),
        retryPayload: self.retryPayload ?? self.outgoingPayload(from: self.currentState)
      )
    }
    timeoutWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: work)
  }

  private func currentPayload() -> [String: Any] {
    var payload = currentState
    if let callId {
      payload["callId"] = callId
    }
    if normalizedString(payload["toUserId"] ?? payload["to_user_id"]) == nil,
      let fromUserId = normalizedString(payload["fromUserId"] ?? payload["from_user_id"])
    {
      payload["toUserId"] = fromUserId
    }
    return payload
  }

  private func outgoingPayload(from state: [String: Any]) -> [String: Any]? {
    guard let toUserId = normalizedString(state["toUserId"] ?? state["to_user_id"]) else {
      return nil
    }
    return [
      "event": "call-start",
      "callType": normalizedString(state["callType"] ?? state["call_type"]) ?? "voice",
      "toUserId": toUserId,
      "toUserName": displayName,
      "toUserImage": normalizedString(state["toUserImage"] ?? state["to_user_image"]) ?? "",
      "chatId": normalizedString(state["chatId"] ?? state["chat_id"]) ?? "",
    ]
  }

  private func mergedState(existing: [String: Any], incoming: [String: Any]) -> [String: Any] {
    var next = existing
    for (key, value) in incoming where !(value is NSNull) {
      next[key] = value
    }
    return next
  }

  private func normalizedString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func boolValue(_ value: Any?) -> Bool {
    switch value {
    case let bool as Bool: return bool
    case let number as NSNumber: return number.boolValue
    case let string as String:
      let raw = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return raw == "true" || raw == "1" || raw == "yes"
    default: return false
    }
  }
}

private enum VibeNativeCallOverlayActionSet {
  case incoming
  case active
  case failed
  case ended
}

private struct VibeNativeCallOverlayView: View {
  @ObservedObject var model: VibeNativeCallOverlayModel

  var body: some View {
    ZStack {
      Color.black.opacity(0.62).ignoresSafeArea()
      Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

      VStack(spacing: 0) {
        HStack {
          Spacer()
          if model.actionSet == .failed || model.actionSet == .ended {
            Button(action: model.close) {
              Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .tint(.white.opacity(0.78))
            .accessibilityLabel("Close")
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)

        Spacer()

        VStack(spacing: 12) {
          Text(model.initial)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 104, height: 104)
            .background(.white.opacity(0.14), in: Circle())
            .padding(.bottom, 18)

          Text(model.directionTitle)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.68))

          Text(model.displayName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)

          Text(model.statusText)
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.78))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 28)
        }

        Spacer()

        VibeNativeCallOverlayActions(model: model)
          .padding(.bottom, 52)
      }
    }
  }
}

private struct VibeNativeCallOverlayActions: View {
  @ObservedObject var model: VibeNativeCallOverlayModel

  var body: some View {
    HStack(spacing: 28) {
      switch model.actionSet {
      case .incoming:
        action(title: "Decline", symbol: "phone.down.fill", tint: .red, action: model.end)
        action(title: "Accept", symbol: "phone.fill", tint: .green, action: model.accept)
      case .active:
        action(title: "End", symbol: "phone.down.fill", tint: .red, action: model.end)
      case .failed:
        action(title: "Close", symbol: "xmark", tint: .white.opacity(0.16), action: model.close)
        action(title: "Retry", symbol: "arrow.clockwise", tint: .green, action: model.retry)
      case .ended:
        EmptyView()
      }
    }
  }

  private func action(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
    VStack(spacing: 8) {
      Button(action: action) {
        Image(systemName: symbol)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 60, height: 60)
      }
      .buttonStyle(.borderedProminent)
      .tint(tint)
      .clipShape(Circle())
      .accessibilityLabel(title)

      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
    }
  }
}

private final class VibeNativeCallOverlayController: UIHostingController<VibeNativeCallOverlayView> {
  private let model = VibeNativeCallOverlayModel()

  var onDismiss: (() -> Void)? {
    get { model.onDismiss }
    set { model.onDismiss = newValue }
  }

  var callId: String? { model.callId }

  init() {
    super.init(rootView: VibeNativeCallOverlayView(model: model))
    view.backgroundColor = .clear
  }

  @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func applyState(_ state: [String: Any], retryPayload: [String: Any]?) {
    model.applyState(state, retryPayload: retryPayload)
  }

  func cancelTimers() {
    model.cancelTimers()
  }
}

@MainActor
final class AppShellCoordinator: ObservableObject {
  @Published var selectedTab: AppShellTab = .chats
  @Published var presentedChat: PresentedChatRoute?
  @Published var presentedChatProfile: PresentedChatProfileRoute?
  @Published var chatOpenRequestID: Int = 0
  @Published var chatProfileOpenRequestID: Int = 0
  @Published var chatSearchPresentationRequestID: Int = 0
  private weak var activeChatController: ChatConversationController?
  private var activeChatControllerRequestID: Int?

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
    let presented = PresentedChatRoute(requestID: requestID, route: route)
    presentedChat = presented
  }

  func closePresentedChat(requestID: Int? = nil) {
    guard let presentedChat else { return }
    if let requestID, presentedChat.requestID != requestID {
      return
    }
    appShellRouteLog(
      "closeChat requested requestId=\(presentedChat.requestID) chatId=\(presentedChat.route.chatId) title=\(presentedChat.route.title)")
    if presentedChatProfile?.route == presentedChat.route {
      presentedChatProfile = nil
    }
    if activeChatControllerRequestID == presentedChat.requestID {
      activeChatController = nil
      activeChatControllerRequestID = nil
    }
    self.presentedChat = nil
  }

  func openPresentedChatProfile(_ presented: PresentedChatRoute) {
    guard presented.route.chatId != "saved_messages" else { return }
    chatProfileOpenRequestID &+= 1
    let requestID = chatProfileOpenRequestID
    appShellRouteLog(
      "openChatProfile requested requestId=\(requestID) chatRequestId=\(presented.requestID) chatId=\(presented.route.chatId) title=\(presented.route.title)"
    )
    presentedChatProfile = PresentedChatProfileRoute(requestID: requestID, route: presented.route)
  }

  func closePresentedChatProfile(requestID: Int? = nil) {
    guard let presentedChatProfile else { return }
    if let requestID, presentedChatProfile.requestID != requestID {
      return
    }
    appShellRouteLog(
      "closeChatProfile requested requestId=\(presentedChatProfile.requestID) chatId=\(presentedChatProfile.route.chatId)"
    )
    self.presentedChatProfile = nil
  }

  fileprivate func bindPresentedChatController(
    _ controller: ChatConversationController,
    requestID: Int
  ) {
    guard presentedChat?.requestID == requestID else { return }
    activeChatController = controller
    activeChatControllerRequestID = requestID
  }

  fileprivate func performPresentedChatNavigationAction(
    _ action: AppChatNavigationAction,
    requestID: Int
  ) {
    guard presentedChat?.requestID == requestID,
      activeChatControllerRequestID == requestID,
      let activeChatController
    else { return }
    activeChatController.handleNavigationAction(action)
  }

  func openChatSearch() {
    DispatchQueue.main.async { [weak self] in
      self?.selectedTab = .chats
      self?.chatSearchPresentationRequestID &+= 1
    }
  }
}

private struct ChatConversationRootHost: UIViewControllerRepresentable {
  let presented: PresentedChatRoute
  let isDark: Bool
  let coordinator: AppShellCoordinator

  func makeUIViewController(context: Context) -> ChatConversationController {
    appShellRouteLog(
      "ChatConversationRootHost make requestId=\(presented.requestID) chatId=\(presented.route.chatId)")
    let controller = ChatConversationController(
      route: presented.route,
      isDark: isDark,
      onClose: {
        coordinator.closePresentedChat(requestID: presented.requestID)
      }
    )
    coordinator.bindPresentedChatController(controller, requestID: presented.requestID)
    appShellRouteLog(
      "ChatConversationRootHost made requestId=\(presented.requestID) chatId=\(presented.route.chatId)")
    return controller
  }

  func updateUIViewController(_ controller: ChatConversationController, context: Context) {
    // Skip updates if this route is no longer the active presentedChat.
    // During the removal animation SwiftUI may call update one final time;
    // allowing applyRoute to run at that point causes a main-thread deadlock
    // because refreshHeaderState calls ChatEngine.shared.isTyping() which
    // does queue.sync while the engine queue may be held by the previous
    // closeChatChannel completing its postChangeLocked notification.
    guard coordinator.presentedChat?.requestID == presented.requestID else {
      let activePresentedId = coordinator.presentedChat?.requestID.description ?? "nil"
      appShellRouteLog(
        "ChatConversationRootHost update SKIPPED requestId=\(presented.requestID) chatId=\(presented.route.chatId) presentedRequestId=\(activePresentedId)")
      return
    }
    appShellRouteLog(
      "ChatConversationRootHost update requestId=\(presented.requestID) chatId=\(presented.route.chatId)")
    coordinator.bindPresentedChatController(controller, requestID: presented.requestID)
    controller.update(
      route: presented.route,
      isDark: isDark,
      onClose: {
        coordinator.closePresentedChat(requestID: presented.requestID)
      }
    )
  }

  static func dismantleUIViewController(
    _ controller: ChatConversationController,
    coordinator: ()
  ) {
    appShellRouteLog("ChatConversationRootHost dismantle")
    controller.dismantle()
  }
}

private struct ChatProfileRootHost: UIViewControllerRepresentable {
  let presented: PresentedChatProfileRoute
  let isDark: Bool
  let coordinator: AppShellCoordinator

  func makeUIViewController(context: Context) -> ChatProfileRootController {
    appShellRouteLog(
      "ChatProfileRootHost make requestId=\(presented.requestID) chatId=\(presented.route.chatId)")
    return ChatProfileRootController(
      route: presented.route,
      isDark: isDark,
      onClose: {
        coordinator.closePresentedChatProfile(requestID: presented.requestID)
      }
    )
  }

  func updateUIViewController(_ controller: ChatProfileRootController, context: Context) {
    guard coordinator.presentedChatProfile?.requestID == presented.requestID else { return }
    controller.update(
      route: presented.route,
      isDark: isDark,
      onClose: {
        coordinator.closePresentedChatProfile(requestID: presented.requestID)
      }
    )
  }
}

private struct ChatConversationNavigationDestinationModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @AppStorage(AppThemePlateController.storageKey) private var themePlateRaw =
    AppThemePlateOption.glacier.rawValue

  private var palette: AppThemePalette {
    AppThemePalette.resolve(
      for: colorScheme,
      plate: AppThemePlateOption(rawValue: themePlateRaw) ?? .glacier
    )
  }

  func body(content: Content) -> some View {
    content
      .modifier(
        ChatConversationChromeSuppressionModifier(
          isPresented: coordinator.presentedChat != nil
        )
      )
      .navigationDestination(item: $coordinator.presentedChat) { presented in
        ChatConversationRootHost(
          presented: presented,
          isDark: colorScheme == .dark,
          coordinator: coordinator
        )
        .id(presented.requestID)
        .background(palette.background.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .tint(palette.text)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            AppChatNavigationBackButton(
              unreadCount: presented.route.unreadCount,
              palette: palette
            ) {
              coordinator.closePresentedChat(requestID: presented.requestID)
            }
          }
          ToolbarItem(placement: .principal) {
            AppChatNavigationHeaderView(route: presented.route, palette: palette)
          }
          ToolbarItem(placement: .topBarTrailing) {
            AppChatNavigationAvatarButton(route: presented.route, palette: palette) {
              coordinator.openPresentedChatProfile(presented)
            }
          }
        }
      }
  }
}

private struct ChatConversationChromeSuppressionModifier: ViewModifier {
  let isPresented: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isPresented {
      content
        .toolbar(.hidden, for: .tabBar)
    } else {
      content
    }
  }
}

private extension View {
  func chatConversationNavigationDestination() -> some View {
    modifier(ChatConversationNavigationDestinationModifier())
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
    AppUITrace.notice("ChatsViewModel loadIfNeeded start rows=\(rows.count)")
    guard let config = AppSessionConfig.current else {
      if rows.isEmpty {
        errorMessage = "The current session is unavailable."
      }
      AppUITrace.error("ChatsViewModel loadIfNeeded missingSession rows=\(rows.count)")
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
      AppUITrace.notice(
        "ChatsViewModel restored-cache rows=\(cachedRows.count) schedulingBackgroundRefresh=Y"
      )
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
    let startedAt = ProcessInfo.processInfo.systemUptime
    AppUITrace.notice(
      "ChatsViewModel refresh start preserveRows=\(preserveRows ? "Y" : "N") currentRows=\(rows.count)"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatsViewModel refresh preserveRows=\(preserveRows ? "Y" : "N") rows=\(rows.count)"
    )
    guard let config = AppSessionConfig.current else {
      if rows.isEmpty {
        errorMessage = "The current session is unavailable."
      }
      AppUITrace.error("ChatsViewModel refresh missingSession rows=\(rows.count)")
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
        AppUITrace.notice(
          "ChatsViewModel refresh applied rows=\(nextRows.count) preserveRows=\(preserveRows ? "Y" : "N") durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
        )
      } else {
        AppUITrace.notice(
          "ChatsViewModel refresh skipped-identical rows=\(nextRows.count) preserveRows=\(preserveRows ? "Y" : "N") durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
        )
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
      AppUITrace.error(
        "ChatsViewModel refresh error offline=\(offline ? "Y" : "N") rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) error=\(error.localizedDescription)"
      )
    }
  }

  private func scheduleBackgroundRefreshAfterCachedStart() {
    backgroundRefreshTask?.cancel()
    AppUITrace.notice("ChatsViewModel scheduleBackgroundRefreshAfterCachedStart")
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
    AppUITrace.notice(
      "ChatsViewModel warmCachedRows rows=\(rows.count) preload=\(preloadChatIds.map { String($0.prefix(12)) }.joined(separator: ","))"
    )
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
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(AppThemePlateController.storageKey) private var themePlateRaw =
    AppThemePlateOption.glacier.rawValue
  @StateObject private var coordinator = AppShellCoordinator()
  @StateObject private var toastController = AppToastController.shared
  @StateObject private var profileController = AppProfileController.shared
  @State private var settingsTabAvatarImage: UIImage?
  @State private var settingsTabUIImage: UIImage?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(
      for: colorScheme,
      plate: AppThemePlateOption(rawValue: themePlateRaw) ?? .glacier
    )
  }

  @ViewBuilder
  private var settingsTabIcon: some View {
    if let uiImage = settingsTabUIImage {
      Image(uiImage: uiImage)
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

      if let presented = coordinator.presentedChatProfile {
        ChatProfileRootHost(
          presented: presented,
          isDark: colorScheme == .dark,
          coordinator: coordinator
        )
        .id(presented.requestID)
        .background(palette.background.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .transition(.move(edge: .trailing))
        .zIndex(50)
      }
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
      let appearance = UINavigationBarAppearance()
      appearance.configureWithTransparentBackground()
      appearance.shadowColor = .clear
      appearance.backgroundColor = .clear
      UINavigationBar.appearance().standardAppearance = appearance
      UINavigationBar.appearance().scrollEdgeAppearance = appearance
      UINavigationBar.appearance().compactAppearance = appearance

      AppAppearanceController.applyStoredPreference()
      AppUITrace.notice("AppRootView onAppear tab=\(coordinator.selectedTab)")
      AppUIStallWatchdog.shared.start(context: "AppRootView appear tab=\(coordinator.selectedTab)")
      VibeNativeCallOverlayPresenter.shared.startObserving()
      VibeNativeCallOverlayPresenter.shared.refreshFromEngine()
    }
    .task {
      await profileController.loadIfNeeded()
      await loadSettingsTabAvatar()
    }
    .onChange(of: profileController.profile?.profileImage) { _, _ in
      Task { await loadSettingsTabAvatar() }
    }
    .onChange(of: settingsTabAvatarImage) { _, image in
      settingsTabUIImage = Self.renderCircularTabAvatar(source: image, size: 26)
    }
    .onChange(of: coordinator.selectedTab) { previousTab, newTab in
      AppUITrace.notice("tab-change from=\(previousTab) to=\(newTab)")
      AppUIStallWatchdog.shared.updateContext("tab-change from=\(previousTab) to=\(newTab)")
      guard newTab == .search else { return }
      coordinator.openChatSearch()
    }
    .onChange(of: scenePhase) { _, newPhase in
      AppUITrace.notice("scene-phase \(newPhase)")
      AppUIStallWatchdog.shared.setActive(
        newPhase == .active,
        context: "scene-phase \(newPhase) tab=\(coordinator.selectedTab)"
      )
      guard newPhase == .active else { return }
      VibeNativeCallOverlayPresenter.shared.refreshFromEngine()
    }
    .overlay(alignment: .bottom) {
      if let message = toastController.message {
        AppToastBanner(message: message, palette: palette)
          .padding(.horizontal, 20)
          .padding(.bottom, 116)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.82), value: toastController.message)
    .animation(.easeInOut(duration: 0.24), value: coordinator.presentedChatProfile?.requestID)
    .environmentObject(coordinator)
  }

  @MainActor
  private func loadSettingsTabAvatar() async {
    guard let uri = profileController.profile?.profileImage else {
      AppUITrace.notice("AppRootView settingsTabAvatar clear")
      settingsTabAvatarImage = nil
      return
    }
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUITrace.notice("AppRootView settingsTabAvatar load start")
    AppUIStallWatchdog.shared.updateContext("AppRootView settingsTabAvatar load")
    settingsTabAvatarImage = await SettingsAvatarImageLoader.load(from: uri)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    AppUITrace.notice(
      "AppRootView settingsTabAvatar load done success=\(settingsTabAvatarImage != nil) durationMs=\(durationMs)"
    )
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
        .chatConversationNavigationDestination()
    }
  }
}

private struct CallsRootView: View {
  var body: some View {
    NavigationStack {
      CallsPageView()
        .chatConversationNavigationDestination()
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
                AppUITrace.notice(
                  "ChatsRootView select chatId=\(String(row.chatId.prefix(12))) title=\(row.title) rows=\(model.rows.count) initialMessages=\(row.initialMessages.count)"
                )
                AppUIStallWatchdog.shared.updateContext(
                  "ChatsRootView select chatId=\(String(row.chatId.prefix(12))) rows=\(model.rows.count)"
                )
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
        .background(palette.background.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .tabBar)

        .toolbar(isShowingStoryCamera || isEditingHome ? .hidden : .visible, for: .tabBar)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              AppUITrace.notice(
                "ChatsRootView editToggle next=\(!isEditingHome ? "editing" : "normal") selected=\(selectedChatIDs.count) rows=\(model.rows.count)"
              )
              withAnimation(.easeInOut(duration: 0.18)) {
                isEditingHome.toggle()
                if !isEditingHome {
                  selectedChatIDs.removeAll()
                }
              }
            } label: {
              Text(isEditingHome ? "Done" : "Edit")
                .font(.system(size: 17))
                .foregroundStyle(palette.text)
                .frame(width: 48, height: 44, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.rows.isEmpty)
            .transaction { transaction in
              transaction.disablesAnimations = true
            }
          }
          ToolbarItem(placement: .principal) {
            AppHomeStatusHeaderView(
              state: model.isWaitingForNetwork ? .waitingForNetwork : .ready,
              palette: palette
            )
            .transaction { transaction in
              transaction.disablesAnimations = true
            }
          }
          ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
              AppUITrace.notice("ChatsRootView story open rows=\(model.rows.count)")
              withAnimation(.easeInOut(duration: 0.24)) {
                isShowingStoryCamera = true
              }
            } label: {
              AppVectorIcon(glyph: .story, tint: palette.secondaryText)
                .frame(width: 23, height: 23)
            }

            Button {
              AppUITrace.notice("ChatsRootView compose/search open rows=\(model.rows.count)")
              isShowingSearch = true
            } label: {
              AppVectorIcon(glyph: .compose, tint: palette.secondaryText)
                .frame(width: 22, height: 22)
            }
          }
        }
        .task {
          AppUITrace.notice("ChatsRootView task loadIfNeeded")
          await model.loadIfNeeded()
        }
        .onAppear {
          AppUITrace.notice(
            "ChatsRootView onAppear rows=\(model.rows.count) searchRequest=\(coordinator.chatSearchPresentationRequestID)"
          )
          AppUIStallWatchdog.shared.updateContext("ChatsRootView appear rows=\(model.rows.count)")
          presentSearchIfRequested()
        }
        .onChange(of: coordinator.chatSearchPresentationRequestID) { _, _ in
          AppUITrace.notice(
            "ChatsRootView searchRequest changed requestId=\(coordinator.chatSearchPresentationRequestID) selectedTab=\(coordinator.selectedTab)"
          )
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
        .chatConversationNavigationDestination()
      }

      if isShowingStoryCamera {
        AppNativeStoryCameraPage {
          AppUITrace.notice("ChatsRootView story close")
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
    AppUITrace.notice("ChatsRootView presentSearch requestId=\(requestID)")
    isShowingSearch = true
  }

  private func toggleHomeSelection(_ chatID: String) {
    AppUITrace.notice(
      "ChatsRootView toggleSelection chatId=\(String(chatID.prefix(12))) selectedBefore=\(selectedChatIDs.count)"
    )
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
    AppUITrace.notice(
      "ChatsRootView bulkAction start action=\(action) selected=\(chatIDs.count)"
    )
    do {
      try await ChatHomeEditService.apply(action: action, chatIDs: chatIDs, config: config)
      selectedChatIDs.removeAll()
      isEditingHome = false
      await model.refresh()
      AppUITrace.notice("ChatsRootView bulkAction done action=\(action)")
    } catch {
      AppUITrace.error("ChatsRootView bulkAction error action=\(action) error=\(error.localizedDescription)")
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
        .chatConversationNavigationDestination()
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
    AppUITrace.notice("ChatHomeNativeListController viewDidLoad")
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

    if !rows.isEmpty {
      tableView.reloadData()
    }
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController viewDidLoad rows=\(rows.count)"
    )
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    AppUITrace.notice(
      "ChatHomeNativeListController viewWillAppear rows=\(rows.count) editing=\(isEditingMode ? "Y" : "N")"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController viewWillAppear rows=\(rows.count)"
    )
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    AppUITrace.notice(
      "ChatHomeNativeListController viewDidAppear rows=\(rows.count) contentSize=\(Int(tableView.contentSize.height)) offsetY=\(Int(tableView.contentOffset.y))"
    )
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    AppUITrace.notice(
      "ChatHomeNativeListController viewDidDisappear rows=\(rows.count) offsetY=\(Int(tableView.contentOffset.y))"
    )
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
    let startedAt = ProcessInfo.processInfo.systemUptime
    let previousRowCount = self.rows.count
    let previousContentOffset = tableView.contentOffset
    AppUITrace.notice(
      "ChatHomeNativeListController apply start previousRows=\(previousRowCount) nextRows=\(rows.count) editing=\(isEditing ? "Y" : "N") selected=\(selectedChatIDs.count) offsetY=\(Int(previousContentOffset.y))"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController apply nextRows=\(rows.count) previousRows=\(previousRowCount)"
    )
    lastAppliedSignature = nextSignature
    self.rows = rows
    self.isDark = isDark
    self.isEditingMode = isEditing
    self.selectedChatIDs = selectedChatIDs

    guard isViewLoaded else {
      AppUITrace.notice(
        "ChatHomeNativeListController apply storedUntilViewLoad rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
      )
      AppUIStallWatchdog.shared.updateContext(
        "ChatHomeNativeListController apply stored rows=\(rows.count)"
      )
      return
    }

    let shouldPreserveOffset = previousRowCount == rows.count && !rows.isEmpty && view.window != nil
    UIView.performWithoutAnimation {
      tableView.reloadData()
      if shouldPreserveOffset {
        tableView.layoutIfNeeded()
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
          minY,
          tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )
        let y = min(max(previousContentOffset.y, minY), maxY)
        tableView.setContentOffset(CGPoint(x: previousContentOffset.x, y: y), animated: false)
      }
    }
    AppUITrace.notice(
      "ChatHomeNativeListController apply done rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) contentSize=\(Int(tableView.contentSize.height)) offsetY=\(Int(tableView.contentOffset.y))"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController apply done rows=\(rows.count)"
    )
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
    AppUITrace.notice("ChatHomeNativeListController refresh start rows=\(rows.count)")
    AppUIStallWatchdog.shared.updateContext("ChatHomeNativeListController refresh rows=\(rows.count)")
    Task { @MainActor [weak self] in
      guard let self else { return }
      let startedAt = ProcessInfo.processInfo.systemUptime
      await onRefresh?()
      isRunningRefresh = false
      refreshControl.endRefreshing()
      AppUITrace.notice(
        "ChatHomeNativeListController refresh done rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
      )
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
    AppUITrace.notice(
      "ChatHomeNativeListController didSelect row=\(indexPath.row) chatId=\(String(row.chatId.prefix(12))) title=\(row.title) editing=\(isEditingMode ? "Y" : "N") rows=\(rows.count)"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController didSelect chatId=\(String(row.chatId.prefix(12))) row=\(indexPath.row)"
    )
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
    AppUITrace.notice(
      "ChatHomeNativeListController contextMenu row=\(indexPath.row) chatId=\(String(row.chatId.prefix(12)))"
    )
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
    AppUITrace.notice(
      "ChatHomeNativeListController scrollBegin rows=\(rows.count) offsetY=\(Int(scrollView.contentOffset.y))"
    )
    openSwipeCell?.closeSwipe(animated: true)
    openSwipeCell = nil
  }

  func homeCardCellDidBeginSwipe(_ cell: ChatHomeCardCell) {
    if let indexPath = tableView.indexPath(for: cell), rows.indices.contains(indexPath.row) {
      AppUITrace.notice(
        "ChatHomeNativeListController swipeBegin row=\(indexPath.row) chatId=\(String(rows[indexPath.row].chatId.prefix(12)))"
      )
    } else {
      AppUITrace.notice("ChatHomeNativeListController swipeBegin row=unknown")
    }
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
    AppUITrace.notice(
      "ChatHomeNativeListController swipeAction event=\(eventType) chatId=\(String(chatId.prefix(12)))"
    )
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
    .ignoresSafeArea(.container, edges: .top)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Text("Contacts")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(palette.text)
      }
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
    .ignoresSafeArea(.container, edges: .top)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Text("Calls")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(palette.text)
      }
    }
  }
}





private enum ChatConversationPage: String {
  case chat
  case profile
  case agent
}

private final class ChatProfileRootController: UIViewController {
  private let profileView = ChatProfileMainView()
  private var route: ChatRoute
  private var isDark: Bool
  private var onClose: (() -> Void)?

  init(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
    appShellRouteLog("ChatProfileRootController init chatId=\(route.chatId) title=\(route.title)")
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Self.backgroundColor(isDark: isDark)
    profileView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(profileView)
    NSLayoutConstraint.activate([
      profileView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      profileView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      profileView.topAnchor.constraint(equalTo: view.topAnchor),
      profileView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    profileView.onNativeEvent.handler = { [weak self] payload in
      self?.handleNativeEvent(payload)
    }
    applyRoute()
  }

  func update(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    let routeChanged = self.route != route
    let themeChanged = self.isDark != isDark
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    if themeChanged {
      view.backgroundColor = Self.backgroundColor(isDark: isDark)
    }
    if routeChanged || themeChanged {
      applyRoute()
    }
  }

  private func applyRoute() {
    let surfaceId = "native_profile_\(route.chatId)"
    view.backgroundColor = Self.backgroundColor(isDark: isDark)
    profileView.surfaceId = surfaceId
    profileView.setProfileOnly(true)
    profileView.setEngineSurfaceId(surfaceId)
    profileView.setEngineChatId(route.chatId)
    profileView.setEnginePeerUserId(route.peerUserId ?? "")
    if let myUserId = Self.normalizedString(
      ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
    ) {
      profileView.setEngineMyUserId(myUserId)
    }
    profileView.setAppearance(Self.resolvedAppearance(isDark: isDark))
    profileView.setHeaderTitle(route.title)
    profileView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    profileView.setProfileName(route.title)
    profileView.setProfileHandle(Self.profileHandle(for: route))
    profileView.setProfileBio("")
    profileView.setAvatarUri(route.avatarURI)
    profileView.setIsGroupOrChannel(route.isGroup)
    profileView.setRows(route.initialRows)
  }

  private func handleNativeEvent(_ payload: [String: Any]) {
    let type = Self.normalizedString(payload["type"]) ?? ""
    appShellRouteLog("ChatProfileRootController nativeEvent chatId=\(route.chatId) type=\(type)")
    switch type {
    case "headerBack":
      onClose?()
    case "headerSearchPressed":
      AppToastController.shared.show("Search stays in the chat page.")
    case "headerAudioCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
    case "headerVideoCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "video")
    default:
      break
    }
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

  private static func routeOnlyHeaderSubtitle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if route.isGroup {
      return "group"
    }
    return route.peerUserId == nil ? "" : "last seen recently"
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

private final class ChatConversationController: UIViewController {
  private static let postPresentationActivationDelay: TimeInterval = 0.28

  private let mainView = ChatMainView()
  private var profileView: ChatProfileMainView?
  private var route: ChatRoute
  private var isDark: Bool
  private var onClose: (() -> Void)?
  private var currentPage: ChatConversationPage = .chat
  private var openedChatId: String?
  private var openedChatIdUsesEngineChannel = false
  private var didInitialScroll = false
  private var rowsRefreshGeneration: UInt = 0
  private var lastLayoutSignature: String?
  private var hasAppeared = false
  private var pendingDeferredEngineStateRefresh = false
  private var deferredEngineRowsReadyChatId: String?
  private var latestProfileRows: [[String: Any]] = []
  private var pendingRowsForAttachment: [[String: Any]]?
  private var isDismantled = false
  private var pendingRowsForAttachmentChatId: String?
  private var pendingRowsForAttachmentSource: String?
  private var lastAppliedRowsToSurfaceCount = 0
  private var postPresentationActivationWorkItem: DispatchWorkItem?
  private var didRunPostPresentationActivation = false
  private var pendingEngineBinding = false
  private var engineBindingKey: String?
  private var engineBindingUserId: String?
  private var pendingAppearanceForAttachment: [String: Any]?
  private var pendingInputActivationForAttachment = false

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
    mainView.setExternalNavigationHeaderEnabled(true)

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
    guard !isDismantled else { return }
    hasAppeared = true
    logLifecycle("viewDidAppear")
    logVisualState("viewDidAppear", force: true)
    applyPendingAppearanceAfterAttachment(reason: "viewDidAppear")
    applyPendingInputActivationAfterAttachment(reason: "viewDidAppear")
    applyPendingRowsAfterAttachment(reason: "viewDidAppear")
    settleInitialBottomIfNeeded(reason: "viewDidAppear")
    schedulePostPresentationActivation(reason: "viewDidAppear")
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyPendingAppearanceAfterAttachment(reason: "viewDidLayoutSubviews")
    applyPendingInputActivationAfterAttachment(reason: "viewDidLayoutSubviews")
    applyPendingRowsAfterAttachment(reason: "viewDidLayoutSubviews")
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
    postPresentationActivationWorkItem?.cancel()
    closeOpenedChatChannel()
  }

  func dismantle() {
    logLifecycle("dismantle")
    isDismantled = true
    postPresentationActivationWorkItem?.cancel()
    postPresentationActivationWorkItem = nil
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
      applySurfaceAppearance(
        Self.resolvedAppearance(isDark: isDark),
        reason: "themeChanged",
        allowDeferUntilAttached: true
      )
    }
  }

  func handleNavigationAction(_ action: AppChatNavigationAction) {
    switch action {
    case .avatar:
      guard route.chatId != "saved_messages" else { return }
      showProfileView(animated: true)
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

    let deferSurfaceUntilAttached = view.window == nil && !hasAppeared
    postPresentationActivationWorkItem?.cancel()
    postPresentationActivationWorkItem = nil
    didRunPostPresentationActivation = false
    pendingEngineBinding = true
    pendingDeferredEngineStateRefresh = true
    deferredEngineRowsReadyChatId = nil
    if deferSurfaceUntilAttached {
      appShellRouteLog(
        "ChatConversationController deferEngineState chatId=\(route.chatId) reason=prePresentation")
    } else {
      appShellRouteLog(
        "ChatConversationController deferEngineState chatId=\(route.chatId) reason=routeActivation")
    }

    let surfaceId = "native_chat_\(route.chatId)"
    latestProfileRows = route.initialRows
    lastAppliedRowsToSurfaceCount = 0
    mainView.surfaceId = surfaceId
    mainView.setDefersEngineStateRefreshes(true)
    mainView.setStatusAuthorityEnabled(false)
    mainView.setEngineChannelBindingEnabled(false)
    if deferSurfaceUntilAttached {
      appShellRouteLog(
        "ChatConversationController deferEngineBinding chatId=\(route.chatId) reason=prePresentation")
    } else {
      configureEngineBindingIfNeeded(reason: "applyRoute", enableStatusAuthority: false)
    }
    applySurfaceAppearance(
      Self.resolvedAppearance(isDark: isDark),
      reason: "applyRoute",
      allowDeferUntilAttached: deferSurfaceUntilAttached
    )
    appShellRouteLog(
      "ChatConversationController configureRouteSurfaceStart chatId=\(route.chatId) reason=applyRoute")
    markRouteSurfaceStep("header")
    mainView.setHeaderMode(route.chatId == "saved_messages" ? "savedmessages" : "default")
    mainView.setHeaderTitle(route.title)
    mainView.setHeaderUnreadCount(route.unreadCount)
    mainView.setProfileName(route.title)
    mainView.setProfileHandle(Self.profileHandle(for: route))
    mainView.setProfileBio("")
    markRouteSurfaceStep("avatar")
    mainView.setAvatarUri(route.avatarURI)
    markRouteSurfaceStep("groupAndInput")
    mainView.setIsGroupOrChannel(route.isGroup)
    mainView.setInputPlaceholder(route.chatId == "saved_messages" ? "Saved Message" : "Message")
    if deferSurfaceUntilAttached {
      pendingInputActivationForAttachment = true
      appShellRouteLog(
        "ChatConversationController deferInputActivation chatId=\(route.chatId) reason=prePresentation")
    } else {
      applyInputActivation(reason: "applyRoute")
    }
    markRouteSurfaceStep("page")
    mainView.setStandaloneProfileMode(false)
    mainView.setPage(ChatConversationPage.chat.rawValue, animated: false)
    removeProfileView(animated: false)
    appShellRouteLog(
      "ChatConversationController configuredSurface chatId=\(route.chatId) surfaceId=\(surfaceId) peerUserId=\(route.peerUserId ?? "") isGroup=\(route.isGroup) headerMode=\(route.chatId == "saved_messages" ? "savedmessages" : "default") windowAttached=\(view.window != nil)")

    refreshRouteOnlyHeaderState()
    refreshRows(preferInitialRows: true)
    logVisualState("afterApplyRoute", force: true)

    if forceChannelRefresh {
      closeOpenedChatChannel()
    }
    if hasAppeared, view.window != nil {
      schedulePostPresentationActivation(reason: "applyRouteAttached")
    } else {
      appShellRouteLog(
        "ChatConversationController deferOpenChatChannel chatId=\(route.chatId) reason=prePresentation hasAppeared=\(hasAppeared) windowAttached=\(view.window != nil)")
    }
  }

  private func markRouteSurfaceStep(_ step: String) {
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController configureRouteSurface.\(step) chatId=\(route.chatId) reason=applyRoute"
    )
  }

  private func applySurfaceAppearance(
    _ appearance: [String: Any],
    reason: String,
    allowDeferUntilAttached: Bool
  ) {
    if allowDeferUntilAttached, view.window == nil {
      pendingAppearanceForAttachment = appearance
      appShellRouteLog(
        "ChatConversationController deferAppearance chatId=\(route.chatId) reason=\(reason) windowAttached=false")
      return
    }
    pendingAppearanceForAttachment = nil
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController setAppearance chatId=\(route.chatId) reason=\(reason)"
    )
    appShellRouteLog(
      "ChatConversationController setAppearanceStart chatId=\(route.chatId) reason=\(reason)")
    mainView.setAppearance(appearance)
    profileView?.setAppearance(appearance)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController setAppearanceDone chatId=\(route.chatId) reason=\(reason) durationMs=\(durationMs)")
  }

  private func applyPendingAppearanceAfterAttachment(reason: String) {
    guard view.window != nil, let appearance = pendingAppearanceForAttachment else { return }
    appShellRouteLog(
      "ChatConversationController applyDeferredAppearance chatId=\(route.chatId) reason=\(reason)")
    applySurfaceAppearance(
      appearance,
      reason: "\(reason)-deferred",
      allowDeferUntilAttached: false
    )
  }

  private func applyInputActivation(reason: String) {
    pendingInputActivationForAttachment = false
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController inputActivation chatId=\(route.chatId) reason=\(reason)"
    )
    appShellRouteLog(
      "ChatConversationController inputActivationStart chatId=\(route.chatId) reason=\(reason)")
    mainView.setInputBarEnabled(true)
    mainView.setNativeSendEnabled(true)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController inputActivationDone chatId=\(route.chatId) reason=\(reason) durationMs=\(durationMs)")
  }

  private func applyPendingInputActivationAfterAttachment(reason: String) {
    guard view.window != nil, pendingInputActivationForAttachment else { return }
    applyInputActivation(reason: "\(reason)-deferred")
  }

  private func schedulePostPresentationActivation(reason: String) {
    guard view.window != nil, hasAppeared else { return }
    guard !didRunPostPresentationActivation else {
      openChatChannelIfNeeded(reason: "\(reason)-alreadyActivated")
      return
    }
    let chatId = route.chatId
    postPresentationActivationWorkItem?.cancel()
    appShellRouteLog(
      "ChatConversationController schedulePostPresentationActivation chatId=\(chatId) reason=\(reason) delayMs=\(Int(Self.postPresentationActivationDelay * 1000))")
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.route.chatId == chatId, self.view.window != nil, self.hasAppeared else {
        return
      }
      self.didRunPostPresentationActivation = true
      appShellRouteLog(
        "ChatConversationController postPresentationActivation chatId=\(chatId) reason=\(reason)")
      self.configureEngineBindingIfNeeded(
        reason: "\(reason)-postTransition",
        enableStatusAuthority: false
      )
      self.completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
      self.openChatChannelIfNeeded(reason: "\(reason)-postTransition")
      AppUIStallWatchdog.shared.updateContext(
        "ChatConversationController postPresentationActivation DONE chatId=\(chatId)"
      )
    }
    postPresentationActivationWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.postPresentationActivationDelay,
      execute: work
    )
  }

  private func configureEngineBindingIfNeeded(reason: String, enableStatusAuthority: Bool) {
    if route.chatId == "saved_messages" {
      let bindingKey = [
        "local_saved_messages",
        route.chatId,
        "deferred",
      ].joined(separator: "|")
      guard pendingEngineBinding || engineBindingKey != bindingKey else { return }
      pendingEngineBinding = false
      engineBindingKey = bindingKey
      appShellRouteLog(
        "ChatConversationController engineBindingStart chatId=\(route.chatId) reason=\(reason) statusAuthority=N savedMessages=Y")
      mainView.setEngineChannelBindingEnabled(false)
      mainView.setStatusAuthorityEnabled(false)
      appShellRouteLog(
        "ChatConversationController engineBindingSkipSurface chatId=\(route.chatId) reason=\(reason) savedMessages=Y")
      mainView.setEngineSurfaceId("")
      mainView.setEngineChatId(route.chatId)
      mainView.setEnginePeerUserId("")
      loadEngineBindingUserId(chatId: route.chatId, reason: reason)
      appShellRouteLog(
        "ChatConversationController engineBindingDone chatId=\(route.chatId) reason=\(reason) statusAuthority=N savedMessages=Y")
      return
    }

    let surfaceId = "native_chat_\(route.chatId)"
    let bindingKey = [
      surfaceId,
      route.chatId,
      route.peerUserId ?? "",
      enableStatusAuthority ? "status" : "deferred",
    ].joined(separator: "|")
    guard pendingEngineBinding || engineBindingKey != bindingKey else { return }
    pendingEngineBinding = false
    engineBindingKey = bindingKey
    appShellRouteLog(
      "ChatConversationController engineBindingStart chatId=\(route.chatId) reason=\(reason) statusAuthority=\(enableStatusAuthority ? "Y" : "N")")
    mainView.setEngineChannelBindingEnabled(false)
    mainView.setStatusAuthorityEnabled(false)
    appShellRouteLog(
      "ChatConversationController engineBindingSetSurface chatId=\(route.chatId) reason=\(reason)")
    mainView.setEngineSurfaceId(surfaceId)
    appShellRouteLog(
      "ChatConversationController engineBindingSetChatId chatId=\(route.chatId) reason=\(reason)")
    mainView.setEngineChatId(route.chatId)
    appShellRouteLog(
      "ChatConversationController engineBindingSetPeer chatId=\(route.chatId) reason=\(reason)")
    mainView.setEnginePeerUserId(route.peerUserId ?? "")
    if enableStatusAuthority {
      appShellRouteLog(
        "ChatConversationController engineBindingEnableStatus chatId=\(route.chatId) reason=\(reason)")
      mainView.setStatusAuthorityEnabled(true)
    }
    loadEngineBindingUserId(chatId: route.chatId, reason: reason)
    appShellRouteLog(
      "ChatConversationController engineBindingDone chatId=\(route.chatId) reason=\(reason) statusAuthority=\(enableStatusAuthority ? "Y" : "N")")
  }

  private func loadEngineBindingUserId(chatId: String, reason: String) {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let config = ChatEngineStore.shared.getConfig()
      let myUserId =
        Self.normalizedString(config["myUserId"])
        ?? Self.normalizedString(config["userId"])
      guard let myUserId else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route.chatId == chatId else { return }
        guard self.engineBindingUserId != myUserId else { return }
        self.engineBindingUserId = myUserId
        AppUIStallWatchdog.shared.updateContext(
          "[AppShellRoute] ChatConversationController engineBindingApplyUserId chatId=\(chatId) reason=\(reason)"
        )
        self.mainView.setEngineMyUserId(myUserId)
        AppUITrace.notice(
          "[AppShellRoute] ChatConversationController engineBindingUserIdApplied chatId=\(chatId) reason=\(reason)"
        )
        AppUIStallWatchdog.shared.updateContext("")
      }
    }
  }

  private func openChatChannelIfNeeded(reason: String) {
    guard openedChatId != route.chatId else { return }
    let chatId = route.chatId
    let peerUserId = route.peerUserId ?? ""
    openedChatId = chatId
    if chatId == "saved_messages" {
      openedChatIdUsesEngineChannel = false
      appShellRouteLog(
        "ChatConversationController openChatChannel skipped chatId=\(chatId) reason=\(reason) savedMessages=Y")
      return
    }
    openedChatIdUsesEngineChannel = true
    appShellRouteLog(
      "ChatConversationController openChatChannel scheduled chatId=\(chatId) peerUserId=\(peerUserId) reason=\(reason) windowAttached=\(view.window != nil) hasAppeared=\(hasAppeared)")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let startedAt = CFAbsoluteTimeGetCurrent()
      appShellRouteLog(
        "ChatConversationController openChatChannel backgroundStart chatId=\(chatId) reason=\(reason)")
      let snapshot = ChatEngine.shared.openChatChannel([
        "chatId": chatId,
        "peerUserId": peerUserId,
      ])
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      appShellRouteLog(
        "ChatConversationController openChatChannel backgroundDone chatId=\(chatId) reason=\(reason) durationMs=\(durationMs)")
      self.appRouteLogOpenResult(chatId: chatId, snapshot: snapshot)
    }
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController openChatChannelIfNeeded DONE chatId=\(chatId)"
    )
  }

  private func closeOpenedChatChannel() {
    guard let openedChatId else { return }
    let usesEngineChannel = openedChatIdUsesEngineChannel
    self.openedChatId = nil
    openedChatIdUsesEngineChannel = false
    guard usesEngineChannel else { return }
    let windowAttachedAtSchedule: Bool?
    if Thread.isMainThread {
      windowAttachedAtSchedule = view.window != nil
    } else {
      windowAttachedAtSchedule = nil
    }
    let windowAttachedLabel = windowAttachedAtSchedule.map { String($0) } ?? "unknown"
    appShellRouteLog(
      "ChatConversationController closeChatChannel scheduled chatId=\(openedChatId) windowAttached=\(windowAttachedLabel) mainThread=\(Thread.isMainThread)")
    DispatchQueue.global(qos: .utility).async {
      let snapshot = ChatEngine.shared.closeChatChannel(["chatId": openedChatId])
      let state = Self.normalizedString(snapshot["state"]) ?? "nil"
      let openCount = snapshot["openChatChannelCount"] as? Int ?? -1
      appShellRouteLog(
        "ChatConversationController closeChatChannel finished chatId=\(openedChatId) state=\(state) openChatCount=\(openCount)")
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
      let didApply = applyRowsToSurface(
        initialRows,
        chatId: chatId,
        source: "initial",
        firstRowID: firstRowID,
        allowDeferUntilAttached: true
      )
      if didApply {
        deferredEngineRowsReadyChatId = chatId
        completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
        settleInitialBottomIfNeeded(reason: "initialRows")
      }
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
        let didApply = self.applyRowsToSurface(
          rows,
          chatId: chatId,
          source: nativeRows.isEmpty ? "initial" : "native",
          firstRowID: firstRowID,
          allowDeferUntilAttached: true
        )
        if didApply {
          self.deferredEngineRowsReadyChatId = chatId
          self.completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
          self.settleInitialBottomIfNeeded(reason: "refreshRows")
          self.logVisualState("afterRefreshRows")
        }
      }
    }
  }

  @discardableResult
  private func applyRowsToSurface(
    _ rows: [[String: Any]],
    chatId: String,
    source: String,
    firstRowID: String,
    allowDeferUntilAttached: Bool
  ) -> Bool {
    latestProfileRows = rows
    guard route.chatId == chatId else { return false }
    if allowDeferUntilAttached, view.window == nil {
      pendingRowsForAttachment = rows
      pendingRowsForAttachmentChatId = chatId
      pendingRowsForAttachmentSource = source
      appShellRouteLog(
        "ChatConversationController deferRowsUntilAttached chatId=\(chatId) rows=\(rows.count) source=\(source) firstRowId=\(firstRowID) hasAppeared=\(hasAppeared)")
      return false
    }

    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController setRows chatId=\(chatId) rows=\(rows.count) source=\(source)"
    )
    mainView.setRows(rows)
    lastAppliedRowsToSurfaceCount = rows.count
    if currentPage == .profile {
      profileView?.setRows(rows)
    }
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController setRowsApplied chatId=\(chatId) rows=\(rows.count) source=\(source) durationMs=\(durationMs) firstRowId=\(firstRowID)")
    return true
  }

  private func applyPendingRowsAfterAttachment(reason: String) {
    guard view.window != nil else { return }
    guard let rows = pendingRowsForAttachment,
      let chatId = pendingRowsForAttachmentChatId,
      chatId == route.chatId
    else { return }
    let source = pendingRowsForAttachmentSource ?? "pending"
    pendingRowsForAttachment = nil
    pendingRowsForAttachmentChatId = nil
    pendingRowsForAttachmentSource = nil
    let firstRowID =
      Self.normalizedString(rows.first?["id"])
      ?? Self.normalizedString(rows.first?["messageId"])
      ?? "nil"
    appShellRouteLog(
      "ChatConversationController applyDeferredRows reason=\(reason) chatId=\(chatId) rows=\(rows.count) source=\(source)")
    let didApply = applyRowsToSurface(
      rows,
      chatId: chatId,
      source: "\(source)-deferred",
      firstRowID: firstRowID,
      allowDeferUntilAttached: false
    )
    if didApply {
      deferredEngineRowsReadyChatId = chatId
      completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
      logVisualState("afterApplyDeferredRows", force: true)
    }
  }

  private func completeDeferredEngineStateRefreshIfNeeded(chatId: String) {
    guard didRunPostPresentationActivation else { return }
    guard hasAppeared, pendingDeferredEngineStateRefresh, route.chatId == chatId,
      deferredEngineRowsReadyChatId == chatId
    else { return }
    pendingDeferredEngineStateRefresh = false
    deferredEngineRowsReadyChatId = nil
    appShellRouteLog(
      "ChatConversationController completeDeferredEngineState chatId=\(chatId)")
    configureEngineBindingIfNeeded(reason: "completeDeferredEngineState", enableStatusAuthority: false)
    mainView.setDefersEngineStateRefreshes(false)
    mainView.refreshEngineStateAfterDeferredRouteOpen()
    refreshHeaderState()
  }

  private func appRouteLogOpenResult(chatId: String, snapshot: [String: Any]) {
    let state = Self.normalizedString(snapshot["state"]) ?? "nil"
    let openCount = snapshot["openChatChannelCount"] as? Int ?? -1
    let joinedCount = snapshot["nativeJoinedChatCount"] as? Int ?? -1
    let boundSurfaceCount = snapshot["boundSurfaceCount"] as? Int ?? -1
    AppUITrace.notice(
      "[AppShellRoute] ChatConversationController openChatChannelResult chatId=\(chatId) state=\(state) connected=\(snapshot["connected"] as? Bool == true ? "true" : "false") openChatCount=\(openCount) joinedChatCount=\(joinedCount) boundSurfaceCount=\(boundSurfaceCount) keyCount=\(snapshot.count)"
    )
  }

  private func settleInitialBottomIfNeeded(reason: String) {
    guard !didInitialScroll else { return }
    guard view.bounds.width > 0.0, view.bounds.height > 0.0 else { return }
    guard lastAppliedRowsToSurfaceCount > 0 else {
      appShellRouteLog(
        "ChatConversationController deferInitialScroll reason=\(reason) chatId=\(route.chatId) rowsReady=false")
      return
    }
    guard view.window != nil else {
      appShellRouteLog(
        "ChatConversationController deferInitialScroll reason=\(reason) chatId=\(route.chatId) windowAttached=false")
      return
    }
    didInitialScroll = true
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController initialScroll chatId=\(route.chatId) reason=\(reason)"
    )
    mainView.layoutIfNeeded()
    mainView.scrollToBottom(animated: false)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController initialScrollToBottomCompleted reason=\(reason) chatId=\(route.chatId) durationMs=\(durationMs)")
    logLifecycle("initialScrollToBottom reason=\(reason)")
    logVisualState("afterInitialScroll", force: true)
  }

  private func refreshHeaderState() {
    let route = route
    let handle = Self.profileHandle(for: route)
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let subtitle = Self.headerSubtitle(for: route)
      let isOnline = Self.isOnline(for: route)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route == route else { return }
        self.mainView.setHeaderSubtitle(subtitle)
        self.mainView.setIsOnline(isOnline)
        self.mainView.setProfileHandle(handle)
        self.profileView?.setHeaderSubtitle(subtitle)
        self.profileView?.setIsOnline(isOnline)
        self.profileView?.setProfileHandle(handle)
      }
    }
  }

  private func refreshRouteOnlyHeaderState() {
    mainView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    mainView.setIsOnline(false)
    mainView.setProfileHandle(Self.profileHandle(for: route))
    profileView?.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    profileView?.setIsOnline(false)
    profileView?.setProfileHandle(Self.profileHandle(for: route))
  }

  private func makeProfileViewIfNeeded() -> ChatProfileMainView {
    if let profileView {
      return profileView
    }

    let nextProfileView = ChatProfileMainView()
    nextProfileView.translatesAutoresizingMaskIntoConstraints = false
    nextProfileView.isHidden = true
    nextProfileView.alpha = 0.0
    nextProfileView.onNativeEvent.handler = { [weak self] payload in
      self?.handleNativeEvent(payload)
    }
    view.addSubview(nextProfileView)
    NSLayoutConstraint.activate([
      nextProfileView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      nextProfileView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      nextProfileView.topAnchor.constraint(equalTo: view.topAnchor),
      nextProfileView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    profileView = nextProfileView
    return nextProfileView
  }

  private func configureProfileView(_ profileView: ChatProfileMainView, rows: [[String: Any]]) {
    let surfaceId = "native_profile_\(route.chatId)"
    profileView.surfaceId = surfaceId
    profileView.setProfileOnly(true)
    profileView.setEngineSurfaceId(surfaceId)
    profileView.setEngineChatId(route.chatId)
    profileView.setEnginePeerUserId(route.peerUserId ?? "")
    if let myUserId = Self.normalizedString(
      ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
    ) {
      profileView.setEngineMyUserId(myUserId)
    }
    profileView.setAppearance(Self.resolvedAppearance(isDark: isDark))
    profileView.setHeaderTitle(route.title)
    profileView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    profileView.setProfileName(route.title)
    profileView.setProfileHandle(Self.profileHandle(for: route))
    profileView.setProfileBio("")
    profileView.setAvatarUri(route.avatarURI)
    profileView.setIsGroupOrChannel(route.isGroup)
    profileView.setRows(rows)
  }

  private func showProfileView(animated: Bool) {
    guard currentPage != .profile else { return }
    currentPage = .profile
    let profileView = makeProfileViewIfNeeded()
    configureProfileView(profileView, rows: latestProfileRows)
    profileView.layer.removeAllAnimations()
    mainView.layer.removeAllAnimations()
    view.bringSubviewToFront(profileView)
    profileView.isHidden = false
    profileView.alpha = 1.0
    let width = max(view.bounds.width, 1.0)
    guard animated, view.window != nil else {
      profileView.transform = .identity
      mainView.transform = .identity
      return
    }
    profileView.transform = CGAffineTransform(translationX: width, y: 0.0)
    UIView.animate(
      withDuration: 0.26,
      delay: 0.0,
      options: [.curveEaseOut, .beginFromCurrentState]
    ) {
      profileView.transform = .identity
      self.mainView.transform = .identity
    } completion: { _ in
      self.mainView.transform = .identity
    }
  }

  private func hideProfileView(animated: Bool) {
    guard profileView?.isHidden == false else {
      currentPage = .chat
      return
    }
    removeProfileView(animated: animated)
  }

  private func removeProfileView(animated: Bool) {
    guard let profileView else {
      currentPage = .chat
      mainView.transform = .identity
      return
    }
    currentPage = .chat
    profileView.layer.removeAllAnimations()
    mainView.layer.removeAllAnimations()
    let width = max(view.bounds.width, 1.0)
    guard animated, view.window != nil else {
      profileView.transform = .identity
      profileView.alpha = 0.0
      profileView.isHidden = true
      mainView.transform = .identity
      profileView.removeFromSuperview()
      self.profileView = nil
      return
    }
    UIView.animate(
      withDuration: 0.22,
      delay: 0.0,
      options: [.curveEaseOut, .beginFromCurrentState]
    ) {
      profileView.transform = CGAffineTransform(translationX: width, y: 0.0)
      profileView.alpha = 0.92
    } completion: { _ in
      profileView.transform = .identity
      profileView.alpha = 0.0
      profileView.isHidden = true
      self.mainView.transform = .identity
      if self.profileView === profileView {
        profileView.removeFromSuperview()
        self.profileView = nil
      }
    }
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
        hideProfileView(animated: true)
      case .agent:
        showProfileView(animated: true)
      }
    case "headerAvatarPressed":
      showProfileView(animated: true)
    case "headerAgentPressed":
      return
    case "headerSearchPressed":
      if currentPage == .profile {
        hideProfileView(animated: true)
      }
      mainView.openHeaderSearch()
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

    if hasAppeared && view.window == nil {
      appShellRouteLog(
        "ChatConversationController engineChanged ignoredDetached chatId=\(route.chatId) reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")
      return
    }
    if isBeingDismissed {
      appShellRouteLog(
        "ChatConversationController engineChanged ignoredDismissing chatId=\(route.chatId) reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")
      return
    }
    if isDismantled {
      appShellRouteLog(
        "ChatConversationController engineChanged ignoredDismantled chatId=\(route.chatId) reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")
      return
    }

    let changedChatId = Self.normalizedString(notification.userInfo?["chatId"])
    let changeReason = Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown"
    if changeReason == "surfaceBindingChanged", changedChatId == nil {
      return
    }
    if route.chatId == "saved_messages", changedChatId == nil {
      return
    }
    guard changedChatId == route.chatId || changedChatId == nil else { return }
    appShellRouteLog(
      "ChatConversationController engineChanged routeChatId=\(route.chatId) changedChatId=\(changedChatId ?? "nil") reason=\(changeReason)")

    if pendingDeferredEngineStateRefresh {
      refreshRouteOnlyHeaderState()
    }

    switch changeReason {
    case "chatRowsReloaded", "chatMessageInserted", "chatMessageEdited", "chatMessageDeleted",
      "chatMessageChanged", "messageStatusChanged", "presenceChanged", "peerTyping",
      "chatMuteChanged":
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

  @ViewBuilder
  private var fallbackAvatar: some View {
    let gradientColors = rowAvatarGradientColors(row: row, palette: palette)
    Circle()
      .fill(
        LinearGradient(
          colors: gradientColors,
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


  private func rowAvatarGradientColors(row: ChatHomeListRow, palette: AppThemePalette) -> [Color] {
    let startRaw = row.avatarGradientStartLight ?? row.avatarGradientStartDark
    let endRaw = row.avatarGradientEndLight ?? row.avatarGradientEndDark
    if let startRaw, let endRaw,
      let start = Color(hexString: startRaw),
      let end = Color(hexString: endRaw)
    {
      return [start, end]
    }
    return [palette.accent.opacity(0.9), palette.button.opacity(0.72)]
  }
}

private struct AppChatNavigationHeaderView: View {
  let route: ChatRoute
  let palette: AppThemePalette

  private var subtitle: String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if route.isGroup {
      return "group"
    }
    return route.peerUserId == nil ? "" : "last seen recently"
  }

  var body: some View {
    GlassEffectContainer(spacing: 0.0) {
      headerContent
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(width: 172, height: 44)
        .glassEffect(.regular.interactive(true), in: .capsule)
    }
      .frame(width: 172, height: 44)
      .transaction { transaction in
        transaction.disablesAnimations = true
      }
  }

  private var headerContent: some View {
    VStack(alignment: .center, spacing: 0) {
      Text(route.title.isEmpty ? "Chat" : route.title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(palette.text)
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .truncationMode(.tail)

      if !subtitle.isEmpty {
        Text(subtitle)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(palette.secondaryText)
          .multilineTextAlignment(.center)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
  }
}

private struct AppChatNavigationBackButton: View {
  let unreadCount: Int
  let palette: AppThemePalette
  let action: () -> Void

  private var displayedUnreadCount: Int {
    min(max(0, unreadCount), 99)
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.left")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(palette.text)
        .frame(width: 36, height: 44, alignment: .center)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .transaction { transaction in
      transaction.disablesAnimations = true
    }
    .accessibilityLabel(
      displayedUnreadCount > 0 ? "Back, \(unreadCount) unread messages" : "Back"
    )
  }
}

private struct AppChatNavigationAvatarButton: View {
  let route: ChatRoute
  let palette: AppThemePalette
  let action: () -> Void

  private var fallbackText: String {
    let trimmed = route.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "U" : String(trimmed.prefix(1)).uppercased()
  }

  var body: some View {
    Button {
      guard route.chatId != "saved_messages" else { return }
      action()
    } label: {
      ZStack {
        avatarContent
          .frame(width: 30, height: 30)
          .clipShape(Circle())
          .overlay(Circle().stroke(palette.secondaryText.opacity(0.16), lineWidth: 0.5))
      }
        .frame(width: 36, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(route.chatId == "saved_messages")
    .transaction { transaction in
      transaction.disablesAnimations = true
    }
    .accessibilityLabel(route.chatId == "saved_messages" ? "Saved Messages" : "Open profile")
  }

  @ViewBuilder
  private var avatarContent: some View {
    if route.chatId == "saved_messages" {
      ZStack {
        LinearGradient(
          colors: [
            Color(red: 43 / 255, green: 165 / 255, blue: 181 / 255),
            Color(red: 0 / 255, green: 122 / 255, blue: 124 / 255),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        Image(systemName: "bookmark.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
      }
    } else if let rawURI = route.avatarURI,
      let url = URL(string: rawURI)
    {
      AsyncImage(url: url) { phase in
        switch phase {
        case .success(let image):
          image.resizable().scaledToFill()
        default:
          fallbackAvatar
        }
      }
    } else {
      fallbackAvatar
    }
  }
    @ViewBuilder
    private var fallbackAvatar: some View {
      let colors = routeAvatarGradientColors(route: route)
      ZStack {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        Image(systemName: "person.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
      }
    }

  private func routeAvatarGradientColors(route: ChatRoute) -> [Color] {
    let seed =
      [route.peerUserId, route.title, route.chatId]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? "user"
    let palettes: [[Color]] = [
      [Color(red: 91 / 255, green: 141 / 255, blue: 239 / 255), Color(red: 61 / 255, green: 107 / 255, blue: 198 / 255)],
      [Color(red: 31 / 255, green: 169 / 255, blue: 122 / 255), Color(red: 22 / 255, green: 122 / 255, blue: 96 / 255)],
      [Color(red: 214 / 255, green: 106 / 255, blue: 90 / 255), Color(red: 175 / 255, green: 73 / 255, blue: 63 / 255)],
      [Color(red: 160 / 255, green: 106 / 255, blue: 216 / 255), Color(red: 124 / 255, green: 78 / 255, blue: 178 / 255)],
      [Color(red: 213 / 255, green: 154 / 255, blue: 46 / 255), Color(red: 175 / 255, green: 116 / 255, blue: 29 / 255)],
      [Color(red: 47 / 255, green: 154 / 255, blue: 168 / 255), Color(red: 32 / 255, green: 117 / 255, blue: 133 / 255)],
    ]
    let index = abs(seed.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palettes.count
    return palettes[index]
  }
}

private extension Color {
  init?(hexString: String) {
    var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255.0,
      green: Double((value >> 8) & 0xFF) / 255.0,
      blue: Double(value & 0xFF) / 255.0
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
