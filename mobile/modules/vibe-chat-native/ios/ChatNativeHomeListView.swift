import ExpoModulesCore
import UIKit

public final class ChatNativeHomeListView: ExpoView, UITableViewDataSource, UITableViewDelegate {
  public var onNativeEvent = EventDispatcher()

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let refreshControl = UIRefreshControl()
  private let contextMenuBackdropView = UIVisualEffectView(effect: nil)
  private let contextMenuBackdropTintView = UIView()
  private var rows: [ChatNativeHomeListRow] = []
  private var isDark = false
  private var previewAppearance: [String: Any]?
  private var contentTopInset: CGFloat = 0
  private var contentBottomInset: CGFloat = 0

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    configureView()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineDidChange(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(
      self,
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    removeContextMenuBackdrop()
    tableView.delegate = nil
    tableView.dataSource = nil
  }

  func setRows(_ rawRows: [[String: Any]]) {
    rows = rawRows.compactMap(ChatNativeHomeListRow.parse)
    tableView.reloadData()
  }

  func setRefreshing(_ refreshing: Bool) {
    if refreshing {
      if !refreshControl.isRefreshing {
        refreshControl.beginRefreshing()
      }
    } else {
      refreshControl.endRefreshing()
    }
  }

  func setIsDark(_ value: Bool) {
    guard isDark != value else { return }
    isDark = value
    tableView.reloadData()
  }

  func setPreviewAppearance(_ value: [String: Any]) {
    previewAppearance = value
  }

  func setContentTopInset(_ value: Double) {
    contentTopInset = max(0, CGFloat(value))
    applyContentInsets()
  }

  func setContentBottomInset(_ value: Double) {
    contentBottomInset = max(0, CGFloat(value))
    applyContentInsets()
  }

  private func applyContentInsets() {
    tableView.contentInset = UIEdgeInsets(
      top: contentTopInset,
      left: 0,
      bottom: contentBottomInset,
      right: 0
    )
    tableView.verticalScrollIndicatorInsets = UIEdgeInsets(
      top: contentTopInset,
      left: 0,
      bottom: contentBottomInset,
      right: 0
    )
  }

  private func configureView() {
    backgroundColor = .clear
    clipsToBounds = true

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.showsVerticalScrollIndicator = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowHeight = 84
    tableView.estimatedRowHeight = 84
    tableView.contentInsetAdjustmentBehavior = .never
    tableView.register(
      ChatNativeHomeCardCell.self, forCellReuseIdentifier: ChatNativeHomeCardCell.reuseIdentifier)
    addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
      tableView.topAnchor.constraint(equalTo: topAnchor),
      tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    tableView.refreshControl = refreshControl
  }

  @objc private func handleChatEngineDidChange(_ notification: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineDidChange(notification)
      }
      return
    }

    let reason =
      ((notification.userInfo?["reason"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if reason == "peerTyping" {
      let changedChatId =
        (notification.userInfo?["chatId"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !changedChatId.isEmpty else {
        tableView.reloadData()
        return
      }
      if let rowIndex = rows.firstIndex(where: { $0.chatId == changedChatId }) {
        tableView.reloadRows(
          at: [IndexPath(row: rowIndex, section: 0)],
          with: .none
        )
      }
      return
    }

    if reason == "presenceChanged" {
      tableView.reloadData()
    }
  }

  private func resolvedPresenceRow(for row: ChatNativeHomeListRow) -> ChatNativeHomeListRow {
    if row.isSavedMessages {
      return row.withPresence(isTyping: false, isOnline: false)
    }
    guard let peerUserId = row.peerUserId, !peerUserId.isEmpty else {
      // Group/channel rows do not show single-peer typing/online state.
      return row.withPresence(isTyping: false, isOnline: false)
    }
    let isTyping = ChatEngine.shared.isTyping(["chatId": row.chatId])
    let isOnline = ChatEngine.shared.isUserOnline(userId: peerUserId)
    return row.withPresence(isTyping: isTyping, isOnline: isOnline)
  }

  @objc private func handleRefresh() {
    onNativeEvent(["type": "refresh"])
  }

  private func ensureContextMenuBackdropInWindow() -> UIVisualEffectView? {
    guard let hostWindow = window ?? tableView.window else { return nil }
    let effectStyle: UIBlurEffect.Style = isDark ? .systemMaterialDark : .systemMaterialLight
    contextMenuBackdropView.effect = UIBlurEffect(style: effectStyle)
    contextMenuBackdropView.frame = hostWindow.bounds
    contextMenuBackdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contextMenuBackdropView.isUserInteractionEnabled = false
    contextMenuBackdropView.alpha = 0
    contextMenuBackdropView.clipsToBounds = true
    contextMenuBackdropTintView.frame = contextMenuBackdropView.contentView.bounds
    contextMenuBackdropTintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contextMenuBackdropTintView.backgroundColor =
      (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.42 : 0.32)

    if contextMenuBackdropTintView.superview !== contextMenuBackdropView.contentView {
      contextMenuBackdropView.contentView.addSubview(contextMenuBackdropTintView)
    }
    if contextMenuBackdropView.superview !== hostWindow {
      contextMenuBackdropView.removeFromSuperview()
      hostWindow.addSubview(contextMenuBackdropView)
    }
    return contextMenuBackdropView
  }

  private func removeContextMenuBackdrop() {
    contextMenuBackdropView.layer.removeAllAnimations()
    contextMenuBackdropView.alpha = 0
    contextMenuBackdropView.removeFromSuperview()
  }

  public func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard indexPath.row < rows.count else { return nil }
    let row = rows[indexPath.row]

    return UIContextMenuConfiguration(identifier: row.chatId as NSString) {
      ChatPreviewViewController(
        row: row,
        isDark: self.isDark,
        previewAppearance: self.previewAppearance
      )
    } actionProvider: { [weak self] _ in
      let openAction = UIAction(title: "Open Chat", image: UIImage(systemName: "bubble.left")) {
        _ in
        self?.onNativeEvent(["type": "press", "chatId": row.chatId])
      }
      let pinAction = UIAction(
        title: row.pinned ? "Unpin" : "Pin",
        image: UIImage(systemName: row.pinned ? "pin.slash" : "pin")
      ) { _ in
        self?.onNativeEvent(["type": "swipePin", "chatId": row.chatId])
      }
      let muteAction = UIAction(
        title: row.muted ? "Unmute" : "Mute",
        image: UIImage(systemName: row.muted ? "bell.slash" : "bell")
      ) { _ in
        self?.onNativeEvent(["type": "swipeMute", "chatId": row.chatId])
      }
      return UIMenu(title: "", children: [openAction, pinAction, muteAction])
    }
  }

  public func tableView(
    _ tableView: UITableView,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionCommitAnimating
  ) {
    guard let chatId = configuration.identifier as? String else { return }
    animator.addCompletion { [weak self] in
      self?.onNativeEvent(["type": "press", "chatId": chatId])
    }
  }

  public func tableView(
    _ tableView: UITableView,
    willDisplayContextMenu configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    guard let backdrop = ensureContextMenuBackdropInWindow() else { return }
    if let animator {
      animator.addAnimations {
        backdrop.alpha = 1
      }
    } else {
      backdrop.alpha = 0
      UIView.animate(withDuration: 0.2) {
        backdrop.alpha = 1
      }
    }
  }

  public func tableView(
    _ tableView: UITableView,
    willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    guard contextMenuBackdropView.superview != nil else { return }
    if let animator {
      animator.addAnimations { [weak self] in
        self?.contextMenuBackdropView.alpha = 0
      }
      animator.addCompletion { [weak self] in
        self?.removeContextMenuBackdrop()
      }
    } else {
      UIView.animate(
        withDuration: 0.18,
        animations: { [weak self] in
          self?.contextMenuBackdropView.alpha = 0
        }
      ) { [weak self] _ in
        self?.removeContextMenuBackdrop()
      }
    }
  }

  public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count
  }

  public func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    guard
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ChatNativeHomeCardCell.reuseIdentifier,
        for: indexPath
      ) as? ChatNativeHomeCardCell
    else {
      return UITableViewCell()
    }
    let displayRow = resolvedPresenceRow(for: rows[indexPath.row])
    cell.configure(
      row: displayRow,
      isDark: isDark,
      avatarBackgroundColor: resolvedAvatarBackgroundColor()
    )
    return cell
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard indexPath.row < rows.count else { return }
    onNativeEvent(["type": "press", "chatId": rows[indexPath.row].chatId])
    tableView.deselectRow(at: indexPath, animated: true)
  }

  public func tableView(
    _ tableView: UITableView,
    leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard indexPath.row < rows.count else { return nil }
    let row = rows[indexPath.row]
    let pinAction = UIContextualAction(style: .normal, title: "Pin") {
      [weak self] _, _, completion in
      self?.onNativeEvent(["type": "swipePin", "chatId": row.chatId])
      completion(true)
    }
    pinAction.backgroundColor = UIColor(red: 61 / 255, green: 130 / 255, blue: 247 / 255, alpha: 1)
    let config = UISwipeActionsConfiguration(actions: [pinAction])
    config.performsFirstActionWithFullSwipe = false
    return config
  }

  public func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard indexPath.row < rows.count else { return nil }
    let row = rows[indexPath.row]
    let muteAction = UIContextualAction(style: .normal, title: "Mute") {
      [weak self] _, _, completion in
      self?.onNativeEvent(["type": "swipeMute", "chatId": row.chatId])
      completion(true)
    }
    muteAction.backgroundColor = UIColor(red: 247 / 255, green: 135 / 255, blue: 51 / 255, alpha: 1)
    let config = UISwipeActionsConfiguration(actions: [muteAction])
    config.performsFirstActionWithFullSwipe = false
    return config
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let normalizedOffsetY = scrollView.contentOffset.y + scrollView.contentInset.top
    onNativeEvent([
      "type": "scroll",
      "offsetY": max(0, normalizedOffsetY),
    ])
  }

  private func resolvedAvatarBackgroundColor() -> UIColor? {
    guard let appearance = previewAppearance else { return nil }
    let key = isDark ? "avatarBackgroundColorDark" : "avatarBackgroundColorLight"
    guard let raw = appearance[key] as? String else { return nil }
    return Self.parseHexColor(raw)
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

private final class ChatPreviewViewController: UIViewController {
  private let mainView = ChatMainView()
  private let isDark: Bool
  private let row: ChatNativeHomeListRow
  private var didInitialScrollToBottom = false

  init(row: ChatNativeHomeListRow, isDark: Bool, previewAppearance: [String: Any]?) {
    self.row = row
    self.isDark = isDark
    super.init(nibName: nil, bundle: nil)
    view.backgroundColor = .clear
    view.clipsToBounds = true

    view.addSubview(mainView)
    mainView.translatesAutoresizingMaskIntoConstraints = false
    let previewInsetX: CGFloat = 2
    NSLayoutConstraint.activate([
      mainView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: previewInsetX),
      mainView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -previewInsetX),
      mainView.topAnchor.constraint(equalTo: view.topAnchor),
      mainView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    mainView.layer.cornerRadius = 20
    if #available(iOS 13.0, *) {
      mainView.layer.cornerCurve = .continuous
    }
    mainView.clipsToBounds = true

    let appearance = Self.resolvedPreviewAppearance(
      rawAppearance: previewAppearance, isDark: isDark)
    mainView.setAppearance(appearance)
    mainView.surfaceId = "preview_\(row.chatId)"
    mainView.setEngineSurfaceId(mainView.surfaceId)
    mainView.setEngineChatId(row.chatId)
    mainView.setEnginePeerUserId(row.peerUserId ?? "")
    if let myUserId = Self.normalizedString(
      ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
    ) {
      mainView.setEngineMyUserId(myUserId)
    }
    mainView.setHeaderTitle(row.title)
    mainView.setHeaderSubtitle(Self.resolvedHeaderSubtitle(for: row))
    mainView.setProfileName(row.title)
    mainView.setProfileHandle(Self.resolvedProfileHandle(for: row))
    mainView.setAvatarUri(row.avatarUri)
    mainView.setIsOnline(Self.resolvedIsOnline(for: row))
    mainView.setIsChatMuted(row.muted)
    mainView.setIsGroupOrChannel(Self.resolvedIsGroupOrChannel(for: row))
    mainView.setStatusAuthorityEnabled(true)
    mainView.setInputBarEnabled(false)
    mainView.isUserInteractionEnabled = true
    refreshPreviewRows()
    mainView.setPage("chat", animated: false)

    preferredContentSize = Self.preferredPreviewContentSize()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineChanged(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    _ = ChatEngine.shared.openChatChannel([
      "chatId": row.chatId,
      "peerUserId": row.peerUserId ?? "",
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(
      self,
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    _ = ChatEngine.shared.closeChatChannel(["chatId": row.chatId])
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    view.layoutIfNeeded()
    mainView.layoutIfNeeded()
    configurePreviewScrollBehavior()
  }

  private func refreshPreviewRows() {
    mainView.setRows(Self.resolvedPreviewRows(for: row))
    guard !didInitialScrollToBottom else { return }
    didInitialScrollToBottom = true
    DispatchQueue.main.async { [weak self] in
      self?.mainView.scrollToBottom(animated: false)
    }
  }

  private func configurePreviewScrollBehavior() {
    let scrollViews = Self.collectScrollViews(in: mainView)
    for scrollView in scrollViews {
      // In UIContextMenu preview, top/bottom bounce tends to propagate the pan
      // to the system dismiss interaction and closes the panel.
      scrollView.bounces = false
      scrollView.alwaysBounceVertical = false
      scrollView.alwaysBounceHorizontal = false
      scrollView.panGestureRecognizer.cancelsTouchesInView = false
      scrollView.delaysContentTouches = false
      scrollView.canCancelContentTouches = true
    }
  }

  @objc private func handleChatEngineChanged(_ note: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineChanged(note)
      }
      return
    }
    guard
      let changedChatId = Self.normalizedString(note.userInfo?["chatId"]),
      changedChatId == row.chatId
    else {
      return
    }
    let reason = Self.normalizedString(note.userInfo?["reason"]) ?? ""
    switch reason {
    case "peerTyping", "presenceChanged":
      mainView.setHeaderSubtitle(Self.resolvedHeaderSubtitle(for: row))
      mainView.setIsOnline(Self.resolvedIsOnline(for: row))
      mainView.setProfileHandle(Self.resolvedProfileHandle(for: row))
    case "chatRowsReloaded", "chatMessageInserted", "chatMessageEdited", "chatMessageDeleted",
      "chatMessageChanged", "messageStatusChanged":
      refreshPreviewRows()
    default:
      break
    }
  }

  private static func resolvedPreviewAppearance(rawAppearance: [String: Any]?, isDark: Bool)
    -> [String: Any]
  {
    var resolved = rawAppearance ?? previewAppearanceFallback(isDark: isDark)
    let mode = normalizedString(resolved["backgroundMode"])?.lowercased()
    if mode == nil || mode == "transparent" {
      resolved["backgroundMode"] = "gradient"
    }
    if (resolved["wallpaperGradient"] as? [String])?.count ?? 0 < 2 {
      resolved["wallpaperGradient"] = previewAppearanceFallback(isDark: isDark)["wallpaperGradient"]
    }
    return resolved
  }

  private static func previewAppearanceFallback(isDark: Bool) -> [String: Any] {
    if isDark {
      return [
        "theme": "dark",
        "backgroundMode": "gradient",
        "wallpaperGradient": ["#131325", "#0D0D1F"],
        "wallpaperOpacity": 1.0,
        "wallpaperPatternGradient": ["#115E59", "#0891B2", "#0284C7"],
        "wallpaperPatternLocations": [0.0, 0.5, 1.0],
        "wallpaperPatternOpacity": 0.12,
        "wallpaperMaskKey": "doodles",
      ]
    }
    return [
      "theme": "light",
      "backgroundMode": "gradient",
      "wallpaperGradient": ["#F9F3EA", "#EFE6D9"],
      "wallpaperOpacity": 1.0,
      "wallpaperPatternGradient": ["#5A8A66", "#5A6675", "#8A75A3"],
      "wallpaperPatternLocations": [0.0, 0.5, 1.0],
      "wallpaperPatternOpacity": 0.06,
      "wallpaperMaskKey": "doodles",
    ]
  }

  private static func preferredPreviewContentSize() -> CGSize {
    let screen = UIScreen.main.bounds.size
    let width = max(320, screen.width - 14)
    let maxHeight = max(380, screen.height - 190)
    let targetHeight = min(maxHeight, screen.height * 0.72)
    return CGSize(width: width, height: targetHeight)
  }

  private static func resolvedPreviewRows(for row: ChatNativeHomeListRow) -> [[String: Any]] {
    let jsRows = row.previewRows
    let nativeRows = ChatEngine.shared.getChatRows(["chatId": row.chatId])
    if !jsRows.isEmpty && jsRows.count >= nativeRows.count {
      return jsRows
    }
    if !nativeRows.isEmpty {
      return nativeRows
    }
    if !jsRows.isEmpty {
      return jsRows
    }
    return previewRows(for: row)
  }

  private static func resolvedHeaderSubtitle(for row: ChatNativeHomeListRow) -> String {
    if row.isSavedMessages {
      return "Saved Messages"
    }
    if ChatEngine.shared.isTyping(["chatId": row.chatId]) {
      return "typing..."
    }
    if resolvedIsOnline(for: row) {
      return "online"
    }
    return "last seen recently"
  }

  private static func resolvedIsOnline(for row: ChatNativeHomeListRow) -> Bool {
    guard let peerUserId = normalizedString(row.peerUserId) else { return false }
    return ChatEngine.shared.isUserOnline(userId: peerUserId)
  }

  private static func resolvedProfileHandle(for row: ChatNativeHomeListRow) -> String {
    if row.isSavedMessages {
      return "saved chat"
    }
    if resolvedIsGroupOrChannel(for: row) {
      return "group chat"
    }
    if let peer = normalizedString(row.peerUserId) {
      return "id: \(peer)"
    }
    return resolvedHeaderSubtitle(for: row)
  }

  private static func resolvedIsGroupOrChannel(for row: ChatNativeHomeListRow) -> Bool {
    if row.isSavedMessages { return false }
    return row.isGroup || normalizedString(row.peerUserId) == nil
  }

  private static func previewRows(for row: ChatNativeHomeListRow) -> [[String: Any]] {
    let previewText =
      row.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Start a conversation"
      : row.preview
    let messageId = "preview_message_\(row.chatId)"
    let timestamp = row.timeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    let message: [String: Any] = [
      "id": messageId,
      "text": previewText,
      "timestamp": timestamp,
      "isMe": false,
      "status": "sent",
      "type": "text",
      "isPinned": row.pinned,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18.0,
        "borderTopRightRadius": 18.0,
        "borderBottomLeftRadius": 4.0,
        "borderBottomRightRadius": 18.0,
      ],
    ]
    return [
      [
        "kind": "message",
        "key": messageId,
        "message": message,
      ]
    ]
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

  private static func collectScrollViews(in root: UIView) -> [UIScrollView] {
    var result: [UIScrollView] = []
    if let scroll = root as? UIScrollView {
      result.append(scroll)
    }
    for child in root.subviews {
      result.append(contentsOf: collectScrollViews(in: child))
    }
    return result
  }
}
