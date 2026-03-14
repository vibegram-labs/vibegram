import ExpoModulesCore
import UIKit

private struct ChatNativeHomeUndoBannerPayload {
  let visible: Bool
  let title: String
  let body: String
  let actionLabel: String
  let timerLabel: String
  let destructive: Bool

  static func parse(_ raw: [String: Any]?) -> ChatNativeHomeUndoBannerPayload? {
    guard let raw else { return nil }
    let visible = (raw["visible"] as? Bool) ?? true
    guard visible else { return nil }
    let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let body = (raw["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !title.isEmpty || !body.isEmpty else { return nil }
    return ChatNativeHomeUndoBannerPayload(
      visible: visible,
      title: title.isEmpty ? "Pending action" : title,
      body: body.isEmpty ? "Tap undo to restore" : body,
      actionLabel:
        (raw["actionLabel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Undo",
      timerLabel:
        (raw["timerLabel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      destructive: (raw["destructive"] as? Bool) ?? true
    )
  }
}

public final class ChatNativeHomeListView: ExpoView, UITableViewDataSource, UITableViewDelegate,
  ChatNativeHomeCardCellSwipeDelegate
{
  public var onNativeEvent = EventDispatcher()

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let refreshControl = UIRefreshControl()
  private let contextMenuBackdropView = UIVisualEffectView(effect: nil)
  private let contextMenuBackdropTintView = UIView()
  private let undoBannerView = ChatNativeHomeUndoBannerView()
  private var rows: [ChatNativeHomeListRow] = []
  private var isDark = false
  private var previewAppearance: [String: Any]?
  private var contentTopInset: CGFloat = 0
  private var contentBottomInset: CGFloat = 0
  private var isEditingMode = false
  private var selectedChatIds = Set<String>()
  private var mediaPrefetchedChatIds = Set<String>()
  private var lastPrefetchedScrollIndex: Int = 0
  private weak var openSwipeCell: ChatNativeHomeCardCell?
  private var currentUndoBanner: ChatNativeHomeUndoBannerPayload?

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
    let previousChatIds = Set(rows.map(\.chatId))
    openSwipeCell?.closeSwipe(animated: false)
    openSwipeCell = nil
    rows = rawRows.compactMap(ChatNativeHomeListRow.parse)
    tableView.reloadData()
    // Pre-fetch chat histories for visible chats so messages are ready
    // before the user taps into a chat. Only trigger on first load or
    // when the chat list changes to avoid redundant requests.
    let currentChatIds = Set(rows.map(\.chatId))
    if previousChatIds != currentChatIds {
      mediaPrefetchedChatIds.removeAll()
      lastPrefetchedScrollIndex = 0
      prefetchTopChatHistories()
    }
  }

  private func prefetchTopChatHistories() {
    // Only preload the top few chats initially — the rest are loaded
    // progressively as the user scrolls via scrollViewDidScroll.
    let initialCount = 5
    let chatIds = rows.prefix(initialCount).map(\.chatId)
    guard !chatIds.isEmpty else { return }
    ChatEngine.shared.prefetchChatHistories(chatIds: chatIds)
    // Warm avatar image cache for visible rows so cells display instantly.
    prefetchAvatars()
    // Warm media cache only for the initially visible chats.
    prefetchMediaForRows(start: 0, end: initialCount)
  }

  /// Prefetch media URLs from preview rows in the given [start, end) range.
  /// Skips chats already prefetched. Runs on current thread but downloads
  /// happen asynchronously inside chatMediaPrefetch.
  private func prefetchMediaForRows(start: Int, end: Int) {
    let transportStatus = ChatEngine.shared.getTransportStatus()
    let transportMode = (transportStatus["transportMode"] as? String) ?? "direct"
    let disableMedia = (transportStatus["disableMedia"] as? Bool) ?? false
    if transportMode == "bridge_text" || disableMedia {
      return
    }
    let clampedEnd = min(end, rows.count)
    guard start < clampedEnd else { return }
    for i in start..<clampedEnd {
      let row = rows[i]
      guard !mediaPrefetchedChatIds.contains(row.chatId) else { continue }
      mediaPrefetchedChatIds.insert(row.chatId)
      for jsRow in row.previewRows {
        guard let message = jsRow["message"] as? [String: Any] else { continue }
        if let mediaUrl = (message["mediaUrl"] as? String ?? message["media_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !mediaUrl.isEmpty {
          let type = message["type"] as? String ?? "text"
          let isAnimated = ["gif", "sticker"].contains(type.lowercased())
          chatMediaPrefetch(urlString: mediaUrl, animated: isAnimated)
        }
      }
    }
  }

  private func prefetchAvatars() {
    let transportStatus = ChatEngine.shared.getTransportStatus()
    let transportMode = (transportStatus["transportMode"] as? String) ?? "direct"
    let disableRemoteAvatars = (transportStatus["disableRemoteAvatars"] as? Bool) ?? false
    if transportMode == "bridge_text" || disableRemoteAvatars {
      return
    }
    let urls = rows.prefix(15).compactMap { $0.avatarUri }
    let session: URLSession = {
      if #available(iOS 13.0, *) {
        return ChatPhoenixClient.makePinnedURLSession()
      }
      return URLSession.shared
    }()
    for urlString in urls {
      let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty,
        ChatNativeHomeCardCell.avatarCached(forKey: trimmed) == nil,
        let url = URL(string: trimmed),
        let scheme = url.scheme?.lowercased(),
        scheme == "https" || scheme == "http"
      else { continue }
      var request = URLRequest(url: url)
      request.cachePolicy = .returnCacheDataElseLoad
      request.timeoutInterval = 10
      request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      session.dataTask(with: request) { data, response, _ in
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(code),
          let data, let image = UIImage(data: data)
        else { return }
        ChatNativeHomeCardCell.cacheAvatar(image, forKey: trimmed)
      }.resume()
    }
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
    updateUndoBanner(animated: false)
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

  func setIsEditing(_ value: Bool) {
    guard isEditingMode != value else { return }
    isEditingMode = value
    openSwipeCell?.closeSwipe(animated: false)
    openSwipeCell = nil
    tableView.setEditing(false, animated: false)
    tableView.reloadData()
  }

  func setSelectedChatIds(_ value: [String]) {
    let nextSelectedChatIds = Set(
      value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    guard nextSelectedChatIds != selectedChatIds else { return }
    selectedChatIds = nextSelectedChatIds
    tableView.reloadData()
  }

  func setUndoBanner(_ raw: [String: Any]?) {
    currentUndoBanner = ChatNativeHomeUndoBannerPayload.parse(raw)
    updateUndoBanner(animated: true)
  }

  private func applyContentInsets() {
    let previousTopInset = tableView.contentInset.top
    let normalizedOffsetY = max(0, tableView.contentOffset.y + previousTopInset)
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
    let targetOffsetY = normalizedOffsetY - contentTopInset
    if abs(tableView.contentOffset.y - targetOffsetY) > 0.5 {
      tableView.setContentOffset(
        CGPoint(x: tableView.contentOffset.x, y: targetOffsetY),
        animated: false
      )
    }
  }

  private func updateUndoBanner(animated: Bool) {
    let textColor = isDark ? UIColor.white : UIColor(red: 22 / 255, green: 28 / 255, blue: 36 / 255, alpha: 1)
    let surfaceColor = isDark ? UIColor.white : UIColor.black

    if let currentUndoBanner {
      undoBannerView.configure(
        title: currentUndoBanner.title,
        body: currentUndoBanner.body,
        actionTitle: currentUndoBanner.actionLabel,
        timerText: currentUndoBanner.timerLabel,
        destructive: currentUndoBanner.destructive
      )
      undoBannerView.applyTheme(textColor: textColor, surfaceColor: surfaceColor, isDark: isDark)
    }

    let shouldShow = currentUndoBanner != nil
    let updates = {
      self.undoBannerView.alpha = shouldShow ? 1 : 0
      self.undoBannerView.transform = shouldShow
        ? .identity
        : CGAffineTransform(translationX: 0, y: 18)
    }

    if shouldShow {
      bringSubviewToFront(undoBannerView)
      undoBannerView.isHidden = false
    }

    if animated {
      UIView.animate(
        withDuration: 0.22,
        delay: 0,
        options: [.curveEaseOut, .beginFromCurrentState]
      ) {
        updates()
      } completion: { _ in
        if !shouldShow {
          self.undoBannerView.isHidden = true
        }
      }
    } else {
      updates()
      undoBannerView.isHidden = !shouldShow
    }
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
    undoBannerView.translatesAutoresizingMaskIntoConstraints = false
    undoBannerView.alpha = 0
    undoBannerView.isHidden = true
    undoBannerView.transform = CGAffineTransform(translationX: 0, y: 18)
    undoBannerView.addTarget(self, action: #selector(handleUndoBannerPressed), for: .touchUpInside)
    addSubview(undoBannerView)

    NSLayoutConstraint.activate([
      tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
      tableView.topAnchor.constraint(equalTo: topAnchor),
      tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
      undoBannerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      undoBannerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      undoBannerView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -14),
      undoBannerView.heightAnchor.constraint(equalToConstant: ChatNativeHomeUndoBannerView.preferredHeight),
    ])

    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    tableView.refreshControl = refreshControl
    updateUndoBanner(animated: false)
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

  @objc private func handleUndoBannerPressed() {
    onNativeEvent(["type": "undoPendingHomeAction"])
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
    guard !isEditingMode else { return nil }
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
      let hasUnread = row.unreadCount > 0 || row.markedUnread
      let readAction = UIAction(
        title: hasUnread ? "Mark as Read" : "Mark as Unread",
        image: UIImage(systemName: hasUnread ? "message.fill" : "circle.fill")
      ) { _ in
        self?.onNativeEvent(["type": "swipeMarkRead", "chatId": row.chatId])
      }
      let pinAction = UIAction(
        title: row.pinned ? "Unpin" : "Pin",
        image: UIImage(systemName: row.pinned ? "pin.slash" : "pin")
      ) { _ in
        self?.onNativeEvent(["type": "swipePin", "chatId": row.chatId])
      }
      let muteAction = UIAction(
        title: row.muted ? "Unmute" : "Mute",
        image: UIImage(systemName: row.muted ? "speaker.wave.2" : "speaker.slash")
      ) { _ in
        self?.onNativeEvent(["type": "swipeMute", "chatId": row.chatId])
      }
      let archiveAction = UIAction(
        title: "Archive",
        image: UIImage(systemName: "archivebox")
      ) { _ in
        self?.onNativeEvent(["type": "swipeArchive", "chatId": row.chatId])
      }
      let clearAction = UIAction(
        title: "Clear Chat",
        image: UIImage(systemName: "eraser")
      ) { _ in
        self?.onNativeEvent(["type": "clearChat", "chatId": row.chatId])
      }
      let deleteAction = UIAction(
        title: "Delete",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { _ in
        self?.onNativeEvent(["type": "swipeDelete", "chatId": row.chatId])
      }
      return UIMenu(
        title: "",
        children: [openAction, readAction, pinAction, muteAction, archiveAction, clearAction, deleteAction]
      )
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
    cell.swipeDelegate = self
    cell.configure(
      row: displayRow,
      isDark: isDark,
      avatarBackgroundColor: resolvedAvatarBackgroundColor(),
      isEditing: isEditingMode,
      isEditSelected: selectedChatIds.contains(displayRow.chatId)
    )
    return cell
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard indexPath.row < rows.count else { return }
    openSwipeCell?.closeSwipe(animated: true)
    openSwipeCell = nil
    let row = rows[indexPath.row]
    if isEditingMode {
      onNativeEvent(["type": "editToggleSelect", "chatId": row.chatId])
      tableView.deselectRow(at: indexPath, animated: false)
      return
    }
    onNativeEvent(["type": "press", "chatId": row.chatId])
    tableView.deselectRow(at: indexPath, animated: true)
  }

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    openSwipeCell?.closeSwipe(animated: true)
    openSwipeCell = nil
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let normalizedOffsetY = scrollView.contentOffset.y + scrollView.contentInset.top
    onNativeEvent([
      "type": "scroll",
      "offsetY": max(0, normalizedOffsetY),
    ])
    // Progressive prefetch: as the user scrolls, warm media for the next
    // batch of rows that are about to become visible.
    let visibleRows = tableView.indexPathsForVisibleRows ?? []
    guard let maxVisible = visibleRows.map(\.row).max() else { return }
    let prefetchHorizon = maxVisible + 3  // look-ahead of 3 rows
    if prefetchHorizon > lastPrefetchedScrollIndex {
      let batchSize = 4
      let batchEnd = min(prefetchHorizon + batchSize, rows.count)
      prefetchMediaForRows(start: lastPrefetchedScrollIndex, end: batchEnd)
      lastPrefetchedScrollIndex = batchEnd
    }
  }

  func homeCardCellDidBeginSwipe(_ cell: ChatNativeHomeCardCell) {
    if openSwipeCell !== cell {
      openSwipeCell?.closeSwipe(animated: true)
    }
    openSwipeCell = cell
  }

  func homeCardCellDidCloseSwipe(_ cell: ChatNativeHomeCardCell) {
    if openSwipeCell === cell {
      openSwipeCell = nil
    }
  }

  func homeCardCell(
    _ cell: ChatNativeHomeCardCell,
    didTriggerSwipeEvent eventType: String,
    chatId: String
  ) {
    if openSwipeCell === cell {
      openSwipeCell = nil
    }
    onNativeEvent([
      "type": eventType,
      "chatId": chatId,
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
