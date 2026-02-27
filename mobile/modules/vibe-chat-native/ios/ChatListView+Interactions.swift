import UIKit

private let swipeReplyTrigger: CGFloat = 28.0
private let swipeReplyMaxOffset: CGFloat = 88.0
private let contextMenuOverlayWindowLevel: CGFloat = 1_000_000_000.0 - 0.001

extension ChatListView: UIGestureRecognizerDelegate, ChatContextMenuOverlayDelegate {
  private func findKeyboardHostView(in view: UIView) -> UIView? {
    let className = NSStringFromClass(type(of: view))
    if className.contains("UIInputSetHostView") || className.contains("UIInputSetContainerView") {
      return view
    }
    for subview in view.subviews.reversed() {
      if let found = findKeyboardHostView(in: subview) {
        return found
      }
    }
    return nil
  }

  private func keyboardWindowPriority(_ window: UIWindow) -> Int {
    let className = NSStringFromClass(type(of: window))
    if className.contains("UIRemoteKeyboardWindow") {
      return 3
    }
    if className.contains("UITextEffectsWindow") {
      return findKeyboardHostView(in: window) == nil ? 1 : 2
    }
    return 0
  }

  private func activeKeyboardOverlayWindow(in scene: UIWindowScene?) -> UIWindow? {
    var allCandidates: [UIWindow] = []
    if let scene {
      allCandidates.append(contentsOf: scene.windows)
    }
    allCandidates.append(contentsOf: UIApplication.shared.windows)
    if #available(iOS 13.0, *) {
      let sceneWindows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
      allCandidates.append(contentsOf: sceneWindows)
    }

    var seen = Set<ObjectIdentifier>()
    var uniqueCandidates: [UIWindow] = []
    for candidate in allCandidates.reversed() {
      let identifier = ObjectIdentifier(candidate)
      if seen.insert(identifier).inserted {
        uniqueCandidates.append(candidate)
      }
    }

    let keyboardCandidates = uniqueCandidates.filter { candidate in
      guard
        !candidate.isHidden,
        candidate.alpha > 0.01,
        candidate.bounds.width > 1.0,
        candidate.bounds.height > 1.0
      else {
        return false
      }
      let className = NSStringFromClass(type(of: candidate))
      return
        className.contains("UITextEffectsWindow")
        || className.contains("UIRemoteKeyboardWindow")
    }

    let sortedCandidates = keyboardCandidates.sorted { lhs, rhs in
      let lhsPriority = keyboardWindowPriority(lhs)
      let rhsPriority = keyboardWindowPriority(rhs)
      if lhsPriority != rhsPriority {
        return lhsPriority > rhsPriority
      }
      if lhs.windowLevel.rawValue != rhs.windowLevel.rawValue {
        return lhs.windowLevel.rawValue > rhs.windowLevel.rawValue
      }
      let lhsFrame = lhs.convert(lhs.bounds, to: nil)
      let rhsFrame = rhs.convert(rhs.bounds, to: nil)
      if lhsFrame.maxY != rhsFrame.maxY {
        return lhsFrame.maxY > rhsFrame.maxY
      }
      return lhsFrame.height > rhsFrame.height
    }
    if let selected = sortedCandidates.first {
      return selected
    }
    if !uniqueCandidates.isEmpty {
      let debugWindows =
        uniqueCandidates
        .map { candidate in
          "\(NSStringFromClass(type(of: candidate)))@\(String(format: "%.1f", candidate.windowLevel.rawValue)) hidden=\(candidate.isHidden)"
        }
        .joined(separator: " | ")
      NSLog("[ChatListView] contextMenu no keyboard host window candidates=%@", debugWindows)
    }
    return nil
  }

  func installInteractionGestures() {
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
    longPress.minimumPressDuration = 0.16
    longPress.allowableMovement = 10.0
    collectionView.addGestureRecognizer(longPress)
  }

  @objc private func handleDismissInputTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
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

    guard let window = window else { return }

    // Snapshot only the bubble+tail (not the full cell row).
    // bubbleSnapshotView already sets the snapshot's frame in window coordinates.
    // It captures at full scale to ensure tail bounding boxes remain mathematically identical.
    guard let bubbleSnapshot = cell.bubbleSnapshotView(in: window) else { return }
    let keyboardWindow = activeKeyboardOverlayWindow(in: window.windowScene)
    let bubbleFrame: CGRect = {
      if let keyboardWindow {
        let converted = keyboardWindow.convert(bubbleSnapshot.frame, from: window)
        bubbleSnapshot.frame = converted
        return converted
      }
      return bubbleSnapshot.frame
    }()

    let overlay = ChatContextMenuOverlay(
      messageId: messageId,
      bubbleSnapshot: bubbleSnapshot,
      bubbleFrame: bubbleFrame,
      bubbleIsMe: isMe,
      appearance: self.resolvedAppearance(),
      showResendAction: showResendAction
    )
    overlay.delegate = self

    if let keyboardWindow, let keyboardScene = keyboardWindow.windowScene {
      // Present in a dedicated window on the keyboard scene above keyboard level.
      let contextWindow = UIWindow(windowScene: keyboardScene)
      let targetLevel = max(
        keyboardWindow.windowLevel.rawValue + 1.0,
        contextMenuOverlayWindowLevel
      )
      contextWindow.windowLevel = UIWindow.Level(rawValue: targetLevel)
      contextWindow.backgroundColor = .clear
      contextWindow.frame = keyboardScene.coordinateSpace.bounds

      let rootVC = UIViewController()
      rootVC.view.backgroundColor = .clear
      rootVC.view.frame = contextWindow.bounds
      rootVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

      overlay.frame = rootVC.view.bounds
      overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      rootVC.view.addSubview(overlay)
      contextWindow.rootViewController = rootVC
      contextWindow.isHidden = false

      NSLog(
        "[ChatListView] contextMenu host=keyboardSceneWindow baseClass=%@ baseLevel=%.1f targetLevel=%.1f",
        NSStringFromClass(type(of: keyboardWindow)),
        keyboardWindow.windowLevel.rawValue,
        contextWindow.windowLevel.rawValue
      )
      self.customContextMenuWindow = contextWindow
    } else if let windowScene = window.windowScene {
      let contextWindow = UIWindow(windowScene: windowScene)
      // Telegram-style very high overlay window level.
      let targetLevel = contextMenuOverlayWindowLevel
      contextWindow.windowLevel = UIWindow.Level(rawValue: targetLevel)
      contextWindow.backgroundColor = .clear
      contextWindow.frame = windowScene.coordinateSpace.bounds

      let rootVC = UIViewController()
      rootVC.view.backgroundColor = .clear
      rootVC.view.frame = contextWindow.bounds
      rootVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

      overlay.frame = rootVC.view.bounds
      overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      rootVC.view.addSubview(overlay)
      contextWindow.rootViewController = rootVC

      contextWindow.isHidden = false
      let windowDebug = windowScene.windows
        .map { win in
          "\(NSStringFromClass(type(of: win)))@\(String(format: "%.1f", win.windowLevel.rawValue)) hidden=\(win.isHidden)"
        }
        .joined(separator: " | ")
      NSLog(
        "[ChatListView] contextMenu windowLevel target=%.1f windows=%@",
        targetLevel,
        windowDebug
      )
      self.customContextMenuWindow = contextWindow
    } else {
      window.addSubview(overlay)
    }

    // Clear any conflicting swipe reply state when context menu opens
    if customContextMenuOverlay == nil {
      resetSwipeReplyTransform(animated: false)
      clearSwipeReplyState()
    }

    self.customContextMenuOverlay = overlay
    // Hide original bubble before overlay animate-in to avoid duplicate-frame flicker.
    cell.setContextMenuExtracted(true)
    self.contextMenuHostCell = cell
    self.contextMenuHostCellOriginalTransform = cell.transform

    // Animate In
    overlay.animateIn()

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

      // Make sure the cell's contentView has no stale swipe-reply translation.
      cell.contentView.transform = .identity

      // Fire haptic immediately and start the scale-down animation
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      cell.setContextMenuHeld(true, animated: true)

      // Delay opening the menu just enough (50ms) to let the bubble visually compress,
      // giving the user physical-feeling feedback.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self = self, gesture.state == .began || gesture.state == .changed else { return }
        self.openContextMenu(at: point)

        // If the menu failed to open (e.g. not a message row), release the hold.
        if self.customContextMenuOverlay == nil {
          cell.setContextMenuHeld(false, animated: true)
        }
      }

    case .ended, .cancelled, .failed:
      // Belt-and-suspenders: if the overlay never opened, release the hold.
      if customContextMenuOverlay == nil {
        let point = gesture.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: point),
          let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
        {
          cell.setContextMenuHeld(false, animated: true)
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
    if let cell = contextMenuHostCell as? ChatListCell {
      cell.setContextMenuExtracted(false)
      cell.setContextMenuHeld(false, animated: false)
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
    // The overlay dismisses itself in animateOut, but we trigger it here if not already dismissing?
    // Wait, the delegate method is called on tap. The overlay is still present.
    // The overlay code calls delegate then... nothing.
    // So logic must call animateOut.
    customContextMenuOverlay?.animateOut(completion: nil)

    // Use the overlay's messageId directly as it's the source of truth
    guard let overlay = customContextMenuOverlay else { return }

    var payload: [String: Any] = [
      "type": "contextMenuReaction",
      "emoji": reaction,
      "messageId": overlay.messageId,
    ]
    if let sourcePoint {
      payload["sourceX"] = sourcePoint.x
      payload["sourceY"] = sourcePoint.y
    }
    onNativeEvent(payload)
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId _: String) {
    customContextMenuOverlay?.animateOut(completion: nil)

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
        hostCell.setContextMenuExtracted(false)
        hostCell.setContextMenuHeld(false, animated: false)
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
