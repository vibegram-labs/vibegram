import UIKit

private let swipeReplyTrigger: CGFloat = 48.0
private let swipeReplyMaxOffset: CGFloat = 72.0

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
    // Keep default vertical scrolling as the dominant gesture.
    return abs(velocity.x) > abs(velocity.y) * 1.2
  }

  @objc private func handleSwipeReplyPan(_ gesture: UIPanGestureRecognizer) {
    let location = gesture.location(in: collectionView)
    let translationX = gesture.translation(in: collectionView).x

    switch gesture.state {
    case .began:
      beginSwipeReply(at: location)
    case .changed:
      updateSwipeReply(translationX: translationX)
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

  private func updateSwipeReply(translationX: CGFloat) {
    guard let indexPath = swipeReplyIndexPath else {
      return
    }
    let directional = swipeReplyIsMe ? -translationX : translationX
    let clamped = max(0.0, min(swipeReplyMaxOffset, directional))
    let signedOffset = clamped * (swipeReplyIsMe ? -1.0 : 1.0)

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
        withDuration: 0.18, delay: 0.0, options: [.curveEaseOut, .beginFromCurrentState],
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
      appearance: resolvedAppearance()
    )
    overlay.delegate = self
    window.addSubview(overlay)
    customContextMenuOverlay = overlay

    // Animate In
    overlay.animateIn()

    // Hide the original cell's bubble while the overlay is showing
    cell.alpha = 0.0
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
    UIView.animate(withDuration: 0.2) {
      if let cell = self.contextMenuHostCell {
        cell.alpha = 1.0
        cell.transform = self.contextMenuHostCellOriginalTransform
      }
    }
    contextMenuHostCell = nil
    customContextMenuOverlay = nil
  }

  public func contextMenuDidSelectReaction(_ reaction: String, messageId: String) {
    // The overlay dismisses itself in animateOut, but we trigger it here if not already dismissing?
    // Wait, the delegate method is called on tap. The overlay is still present.
    // The overlay code calls delegate then... nothing.
    // So logic must call animateOut.
    customContextMenuOverlay?.animateOut(completion: nil)

    // Use the overlay's messageId directly as it's the source of truth
    guard let overlay = customContextMenuOverlay else { return }

    onNativeEvent([
      "type": "addReaction",
      "reaction": reaction,
      "messageId": overlay.messageId,
    ])
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId: String) {
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
      if let hostCell = self?.contextMenuHostCell {
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
