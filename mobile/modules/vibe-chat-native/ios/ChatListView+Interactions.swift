import UIKit

private let swipeReplyTrigger: CGFloat = 34.0
private let swipeReplyMaxOffset: CGFloat = 88.0

extension ChatListView: UIGestureRecognizerDelegate, ChatContextMenuOverlayDelegate {
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
    pan.cancelsTouchesInView = false
    collectionView.addGestureRecognizer(pan)
    swipeReplyPanGesture = pan

    let longPress = UILongPressGestureRecognizer(
      target: self, action: #selector(handleLongPress(_:)))
    longPress.minimumPressDuration = 0.25
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

    let velocity = pan.velocity(in: collectionView)
    let horizontal = abs(velocity.x)
    let vertical = abs(velocity.y)
    // Make swipe-to-reply easier to start while preserving regular vertical scroll.
    return horizontal > vertical * 0.85
  }

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    guard gestureRecognizer === swipeReplyPanGesture || otherGestureRecognizer === swipeReplyPanGesture
    else { return false }
    // Let collection scrolling continue while we still read horizontal drag progress.
    return gestureRecognizer === collectionView.panGestureRecognizer
      || otherGestureRecognizer === collectionView.panGestureRecognizer
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
    // If vertical motion dominates, keep the cell steady so swipe feels responsive
    // without fighting normal list scrolling.
    let absX = abs(translation.x)
    let absY = abs(translation.y)
    if absY > absX * 1.15 {
      if let cell = collectionView.cellForItem(at: indexPath) {
        cell.contentView.transform = .identity
      }
      return
    }

    let directional = swipeReplyIsMe ? -translation.x : translation.x
    let clamped = max(0.0, min(swipeReplyMaxOffset, directional))
    // Slight non-linear easing gives stronger immediate feedback at short drags.
    let progress = clamped / swipeReplyMaxOffset
    let eased = swipeReplyMaxOffset * pow(progress, 0.82)
    let signedOffset = eased * (swipeReplyIsMe ? -1.0 : 1.0)

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

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began else { return }
    let point = gesture.location(in: collectionView)
    guard let indexPath = collectionView.indexPathForItem(at: point),
      let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
    else { return }

    // Haptic feedback
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()

    guard indexPath.item < rows.count else { return }
    let row = rows[indexPath.item]
    guard row.kind == .message, let messageId = row.messageId else { return }

    guard let window = window else { return }

    // Snapshot only the bubble+tail (not the full cell row).
    // bubbleSnapshotView already sets the snapshot's frame in window coordinates.
    guard let bubbleSnapshot = cell.bubbleSnapshotView(in: window) else { return }
    let bubbleFrame = bubbleSnapshot.frame

    let overlay = ChatContextMenuOverlay(
      messageId: messageId,
      bubbleSnapshot: bubbleSnapshot,
      bubbleFrame: bubbleFrame,
      appearance: resolvedAppearance(),
      showResendAction: row.isMe && (row.status?.lowercased() == "error")
    )
    overlay.delegate = self
    window.addSubview(overlay)
    customContextMenuOverlay = overlay

    // Animate In
    overlay.animateIn()

    // Hide only the original bubble layer while extracted overlay is visible.
    cell.setContextMenuExtracted(true)
    contextMenuHostCell = cell
    contextMenuHostCellOriginalTransform = cell.transform

    onNativeEvent(["type": "contextMenuOpened", "messageId": messageId])
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
      cell.transform = contextMenuHostCellOriginalTransform
    }
    contextMenuHostCell = nil
    customContextMenuOverlay = nil
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

    onNativeEvent([
      "type": "contextMenuAction",
      "action": actionId,
      "messageId": overlay.messageId,
    ])

    // Show reply banner when "reply" action is selected
    if actionId == "reply" {
      let mid = overlay.messageId
      if let row = rows.first(where: { $0.messageId == mid }) {
        inputBar?.showReplyBanner(messageId: mid, text: row.text, isMe: row.isMe)
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
