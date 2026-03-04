import UIKit

private let swipeReplyTrigger: CGFloat = 28.0
private let swipeReplyMaxOffset: CGFloat = 88.0
private let chatHoldDebugLogs = true

private func isKeyboardHostWindow(_ window: UIWindow) -> Bool {
  let typeName = String(describing: type(of: window))
  return typeName.contains("UIRemoteKeyboardWindow") || typeName.contains("UITextEffectsWindow")
}

private final class ChatKeyboardWindowObserver: NSObject {
  static let shared = ChatKeyboardWindowObserver()

  private weak var keyboardWindow: UIWindow?

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeVisible(_:)),
      name: UIWindow.didBecomeVisibleNotification,
      object: nil
    )
  }

  @objc private func windowDidBecomeVisible(_ notification: Notification) {
    guard let window = notification.object as? UIWindow else { return }
    guard isKeyboardHostWindow(window) else { return }
    keyboardWindow = window
  }

  private func discoverKeyboardWindow() -> UIWindow? {
    // iOS can keep the keyboard in a separate window that may not always be exposed
    // through the current scene's window list. Scan UIApplication windows first.
    for window in UIApplication.shared.windows.reversed() {
      guard isKeyboardHostWindow(window) else { continue }
      return window
    }

    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows.reversed() {
        guard isKeyboardHostWindow(window) else { continue }
        return window
      }
    }
    return nil
  }

  func currentKeyboardWindow() -> UIWindow? {
    if keyboardWindow == nil {
      keyboardWindow = discoverKeyboardWindow()
    }
    guard let keyboardWindow else { return nil }
    guard !keyboardWindow.isHidden, keyboardWindow.alpha > 0.01 else { return nil }
    return keyboardWindow
  }
}

extension ChatListView: UIGestureRecognizerDelegate, ChatContextMenuOverlayDelegate {
  private func holdDebugLog(_ message: String) {
    guard chatHoldDebugLogs else { return }
    NSLog("[ChatHold] %@", message)
  }

  private func resolveContextMenuHostWindow(appWindow: UIWindow) -> UIWindow {
    _ = ChatKeyboardWindowObserver.shared

    if let keyboardWindow = ChatKeyboardWindowObserver.shared.currentKeyboardWindow() {
      return keyboardWindow
    }
    return appWindow
  }

  func installInteractionGestures() {
    // Start observing keyboard windows as early as possible so first open is stable.
    _ = ChatKeyboardWindowObserver.shared

    let tap = UITapGestureRecognizer(
      target: self, action: #selector(handleDismissInputTap(_:)))
    tap.delegate = self
    tap.cancelsTouchesInView = false
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    collectionView.addGestureRecognizer(tap)
    dismissInputTapGesture = tap

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipeReplyPan(_:)))
    pan.delegate = self
    pan.maximumNumberOfTouches = 1
    pan.delaysTouchesBegan = false
    pan.delaysTouchesEnded = false
    pan.cancelsTouchesInView = false
    collectionView.addGestureRecognizer(pan)
    swipeReplyPanGesture = pan

    let longPress = UILongPressGestureRecognizer(
      target: self, action: #selector(handleLongPress(_:)))
    // Telegram-like cadence: fast enough for real-time feel without accidental triggers.
    longPress.minimumPressDuration = 0.24
    longPress.allowableMovement = 10.0
    // Prevent a long-press from also being treated as a tap that dismisses keyboard.
    tap.require(toFail: longPress)
    collectionView.addGestureRecognizer(longPress)
    contextMenuLongPressGesture = longPress
  }

  @objc private func handleDismissInputTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
    // Ignore dismiss taps that are part of a context-menu hold/open sequence.
    if let longPress = contextMenuLongPressGesture {
      switch longPress.state {
      case .began, .changed, .ended:
        return
      default:
        break
      }
    }
    guard customContextMenuOverlay == nil else { return }
    guard inputBar != nil else { return }
    _ = endEditing(true)
  }

  public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer)
    -> Bool
  {
    guard gestureRecognizer === swipeReplyPanGesture,
      let pan = gestureRecognizer as? UIPanGestureRecognizer
    else {
      return true
    }

    let translation = pan.translation(in: collectionView)
    let velocity = pan.velocity(in: collectionView)
    let translationHorizontal = abs(translation.x)
    let translationVertical = abs(translation.y)

    // Translation is usually a better early signal for intent than velocity.
    // Keep this permissive so the bubble starts tracking finger immediately.
    if translationHorizontal > 2.0 || translationVertical > 2.0 {
      return translationHorizontal > translationVertical * 0.9
    }

    let velocityHorizontal = abs(velocity.x)
    let velocityVertical = abs(velocity.y)
    return velocityHorizontal > 8.0 && velocityHorizontal > velocityVertical * 0.9
  }

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Tap-to-dismiss must not run with context-menu long-press.
    if (gestureRecognizer === dismissInputTapGesture
      && otherGestureRecognizer === contextMenuLongPressGesture)
      || (gestureRecognizer === contextMenuLongPressGesture
        && otherGestureRecognizer === dismissInputTapGesture)
    {
      return false
    }
    // Don't allow our swipe-reply pan to run simultaneously with the long-press
    // context menu gesture — this prevents unwanted X movement during hold.
    if (gestureRecognizer === swipeReplyPanGesture
      && otherGestureRecognizer is UILongPressGestureRecognizer)
      || (gestureRecognizer is UILongPressGestureRecognizer
        && otherGestureRecognizer === swipeReplyPanGesture)
    {
      return false
    }
    // Allow simultaneous with scrollView's built-in pan so swiping tracks at 120fps.
    return true
  }

  @objc private func handleSwipeReplyPan(_ gesture: UIPanGestureRecognizer) {
    let location = gesture.location(in: collectionView)
    let translation = gesture.translation(in: collectionView)

    switch gesture.state {
    case .began:
      beginSwipeReply(at: location)
    case .changed:
      updateSwipeReply(translation: translation)
    case .ended, .cancelled, .failed:
      finishSwipeReply()
    default:
      break
    }
  }

  private func beginSwipeReply(at location: CGPoint) {
    resetSwipeReplyTransform(animated: false)
    swipeReplyDidTrigger = false

    guard let indexPath = collectionView.indexPathForItem(at: location),
      indexPath.item < rows.count
    else {
      clearSwipeReplyState()
      return
    }
    let row = rows[indexPath.item]
    guard row.kind == .message, let messageId = row.messageId else {
      clearSwipeReplyState()
      return
    }

    swipeReplyIndexPath = indexPath
    swipeReplyMessageId = messageId
    swipeReplyIsMe = row.isMe
  }

  private func updateSwipeReply(translation: CGPoint) {
    guard let indexPath = swipeReplyIndexPath else {
      return
    }

    // All messages swipe to the LEFT to reply (standard convention)
    let directional = -translation.x
    let clamped = max(0.0, min(swipeReplyMaxOffset, directional))
    let signedOffset = clamped * -1.0

    if let cell = collectionView.cellForItem(at: indexPath) {
      cell.contentView.transform = CGAffineTransform(translationX: signedOffset, y: 0.0)
    }

    guard clamped >= swipeReplyTrigger,
      !swipeReplyDidTrigger,
      let messageId = swipeReplyMessageId
    else {
      return
    }
    swipeReplyDidTrigger = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onNativeEvent([
      "type": "swipeReply",
      "messageId": messageId,
    ])

    // Show reply banner in native input bar
    if let idx = swipeReplyIndexPath?.item, idx < rows.count {
      let row = rows[idx]
      inputBar?.showReplyBanner(messageId: messageId, text: row.text, isMe: row.isMe)
    }
  }

  private func finishSwipeReply() {
    resetSwipeReplyTransform(animated: true)
    clearSwipeReplyState()
  }

  private func resetSwipeReplyTransform(animated: Bool) {
    guard let indexPath = swipeReplyIndexPath,
      let cell = collectionView.cellForItem(at: indexPath)
    else {
      return
    }
    let apply = {
      cell.contentView.transform = .identity
    }
    if animated {
      UIView.animate(
        withDuration: 0.22, delay: 0.0, options: [.curveEaseOut, .beginFromCurrentState],
        animations: apply)
    } else {
      apply()
    }
  }

  private func clearSwipeReplyState() {
    swipeReplyIndexPath = nil
    swipeReplyMessageId = nil
    swipeReplyIsMe = false
    swipeReplyDidTrigger = false
  }

  private func openContextMenu(at point: CGPoint) {
    guard customContextMenuOverlay == nil else { return }
    guard let indexPath = collectionView.indexPathForItem(at: point),
      let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
    else { return }

    guard indexPath.item < rows.count else { return }
    let row = rows[indexPath.item]
    guard row.kind == .message, let messageId = row.messageId else { return }
    let isMe = row.isMe
    let showResendAction = row.isMe && (row.status?.lowercased() == "error")

    holdDebugLog(
      "openContextMenu begin mid=\(messageId) cellTransform=\(NSCoder.string(for: cell.transform)) contentTransform=\(NSCoder.string(for: cell.contentView.transform))"
    )

    // Hold is a pre-menu pulse only. Force identity before snapshot/open.
    cell.setContextMenuHeld(false, animated: false, strategy: "scaleCell")

    guard let window = window else { return }

    // Snapshot only the bubble+tail (not the full cell row).
    // bubbleSnapshotView already sets the snapshot's frame in window coordinates.
    // It captures at full scale to ensure tail bounding boxes remain mathematically identical.
    guard let bubbleSnapshot = cell.bubbleSnapshotView(in: window) else { return }
    let bubbleFrame = bubbleSnapshot.frame
    holdDebugLog(
      "openContextMenu snapshot mid=\(messageId) bubbleFrame=\(NSCoder.string(for: bubbleFrame))"
    )

    let hostWindow = resolveContextMenuHostWindow(appWindow: window)
    let bubbleFrameInHost =
      hostWindow === window
      ? bubbleFrame
      : hostWindow.convert(bubbleFrame, from: window)
    bubbleSnapshot.frame = bubbleFrameInHost

    let overlay = ChatContextMenuOverlay(
      messageId: messageId,
      bubbleSnapshot: bubbleSnapshot,
      bubbleFrame: bubbleFrameInHost,
      bubbleIsMe: isMe,
      appearance: self.resolvedAppearance(),
      showResendAction: showResendAction
    )
    overlay.delegate = self

    overlay.frame = hostWindow.bounds
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostWindow.addSubview(overlay)
    self.customContextMenuWindow = nil

    let hostClass = NSStringFromClass(type(of: hostWindow))
    NSLog(
      "[ChatListView] contextMenu hostWindow=%@ level=%.1f keyboardHost=%@",
      hostClass,
      hostWindow.windowLevel.rawValue,
      hostWindow === window ? "N" : "Y"
    )

    // Clear any conflicting swipe reply state when context menu opens
    if customContextMenuOverlay == nil {
      resetSwipeReplyTransform(animated: false)
      clearSwipeReplyState()
    }

    self.customContextMenuOverlay = overlay
    self.contextMenuHostCell = cell
    self.contextMenuHostCellOriginalTransform = .identity

    // Animate In
    overlay.animateIn()

    // Extract right after overlay is in place so we don't get a blank frame/flicker.
    cell.setContextMenuExtracted(true)
    holdDebugLog("openContextMenu extracted mid=\(messageId)")

    self.onNativeEvent(["type": "contextMenuOpened", "messageId": messageId])
  }

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    switch gesture.state {
    case .began:
      guard customContextMenuOverlay == nil else { return }

      // Cancel any in-progress swipe reply immediately to avoid residual X offset.
      resetSwipeReplyTransform(animated: false)
      clearSwipeReplyState()

      let point = gesture.location(in: collectionView)
      guard let indexPath = collectionView.indexPathForItem(at: point),
        let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
      else { return }
      holdDebugLog(
        "longPress began point=\(NSCoder.string(for: point)) index=\(indexPath.item) cellTransform=\(NSCoder.string(for: cell.transform))"
      )

      // Home-list style: subtle quick press pulse before menu open.
      cell.contentView.transform = .identity
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      cell.setContextMenuHeld(true, animated: true, strategy: "scaleCell")

      // The scale down animation takes 0.18s. We wait exactly that long so the cell
      // reaches its scaled state smoothly, then synchronously pop open the menu.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak cell] in
        guard let self = self else { return }
        guard gesture.state == .began || gesture.state == .changed else {
          self.holdDebugLog("longPress delayed cancel state=\(gesture.state.rawValue)")
          cell?.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
          return
        }
        if self.customContextMenuOverlay != nil {
          cell?.setContextMenuHeld(false, animated: false, strategy: "scaleCell")
          return
        }
        self.holdDebugLog("longPress delayed open state=\(gesture.state.rawValue)")
        self.openContextMenu(at: point)

        if self.customContextMenuOverlay == nil {
          self.holdDebugLog("longPress delayed open failed")
          cell?.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
        }
      }

    case .ended, .cancelled, .failed:
      holdDebugLog(
        "longPress end state=\(gesture.state.rawValue) overlay=\(customContextMenuOverlay != nil)")
      if customContextMenuOverlay == nil {
        let point = gesture.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: point),
          let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
        {
          cell.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
        }
      }

    default:
      break
    }
  }

  @available(iOS 13.0, *)
  public func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    return nil
  }

  // MARK: - ChatContextMenuOverlayDelegate

  public func contextMenuDidDismiss(overlay: ChatContextMenuOverlay) {
    holdDebugLog("contextMenuDidDismiss")
    if let cell = contextMenuHostCell as? ChatListCell {
      cell.setContextMenuHeld(false, animated: false, strategy: "scaleCell")
      cell.setContextMenuExtracted(false)
      cell.transform = contextMenuHostCellOriginalTransform
    }
    contextMenuHostCell = nil
    customContextMenuOverlay = nil

    customContextMenuWindow?.isHidden = true
    customContextMenuWindow = nil
  }

  public func contextMenuDidSelectReaction(
    _ reaction: String,
    messageId: String,
    sourcePoint: CGPoint?
  ) {
    holdDebugLog(
      "contextMenuDidSelectReaction id=\(messageId) emoji=\(reaction) source=\(sourcePoint.map { NSCoder.string(for: $0) } ?? "nil")"
    )
    var resolvedSourcePoint = sourcePoint
    if let window, let hostCell = contextMenuHostCell as? ChatListCell,
      let badgePoint = hostCell.reactionBadgeCenter(in: window)
    {
      resolvedSourcePoint = badgePoint
    }
    let resolvedMessageId = messageId
    applyLocalReactionEmoji(reaction, toMessageId: resolvedMessageId)

    let emitReactionEvent = { [weak self] in
      guard let self else { return }
      var payload: [String: Any] = [
        "type": "contextMenuReaction",
        "emoji": reaction,
        "messageId": resolvedMessageId,
      ]
      if let resolvedSourcePoint {
        payload["sourceX"] = resolvedSourcePoint.x
        payload["sourceY"] = resolvedSourcePoint.y
      }
      self.holdDebugLog(
        "emit contextMenuReaction id=\(resolvedMessageId) emoji=\(reaction) source=\(resolvedSourcePoint.map { NSCoder.string(for: $0) } ?? "nil")"
      )
      self.onNativeEvent(payload)
    }

    // Overlay handles icon flight first. Dispatch reaction only after dismiss so
    // the final native FX is visible above chat content, not behind the overlay.
    if customContextMenuOverlay != nil {
      customContextMenuOverlay?.animateOut(reason: "reaction", completion: emitReactionEvent)
    } else {
      emitReactionEvent()
    }
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId _: String) {
    customContextMenuOverlay?.animateOut(reason: "action:\(actionId)", completion: nil)

    guard let overlay = customContextMenuOverlay else { return }
    let mid = overlay.messageId

    onNativeEvent([
      "type": "contextMenuAction",
      "action": actionId,
      "messageId": mid,
    ])

    if let row = rows.first(where: { $0.messageId == mid }) {
      if actionId == "reply" {
        inputBar?.showReplyBanner(messageId: mid, text: row.text, isMe: row.isMe)
      } else if actionId == "copy" {
        UIPasteboard.general.string = row.text
      }
    }
  }

  func dismissCustomContextMenu(animated: Bool) {
    guard let overlay = customContextMenuOverlay else { return }

    let cleanup = { [weak self] in
      overlay.removeFromSuperview()
      self?.customContextMenuOverlay = nil
      if let hostCell = self?.contextMenuHostCell as? ChatListCell {
        hostCell.setContextMenuHeld(
          false, animated: false, strategy: "scaleCell")
        hostCell.setContextMenuExtracted(false)
        hostCell.transform = self?.contextMenuHostCellOriginalTransform ?? .identity
        self?.contextMenuHostCell = nil
        self?.contextMenuHostCellOriginalTransform = .identity
      }
    }

    if animated {
      UIView.animate(
        withDuration: 0.2, delay: 0, options: [.curveEaseOut],
        animations: {
          overlay.alpha = 0.0
        },
        completion: { _ in
          cleanup()
        })
    } else {
      cleanup()
    }
  }
}
