import ExpoModulesCore
import UIKit

private let chatListSendVerticalTiming = CAMediaTimingFunction(
  controlPoints: Float(0.19919472913616398),
  Float(0.010644531250000006),
  Float(0.27920937042459737),
  Float(0.91025390625)
)

public final class ChatListView: ExpoView, UICollectionViewDataSource,
  UICollectionViewDelegateFlowLayout
{
  public var onViewportChanged = EventDispatcher()
  public var onNativeEvent = EventDispatcher()

  @objc public var surfaceId: String = "" {
    didSet {
      if !surfaceId.isEmpty {
        ChatListRegistry.shared.register(surfaceId: surfaceId, view: self)
      }
    }
  }

  private let flowLayout: ChatCollectionFlowLayout
  let collectionView: UICollectionView
  private let wallpaperLayer = CAGradientLayer()
  var rows: [ChatListRow] = []
  private var appearance = ChatListAppearance.fallback
  private var shouldAutoScroll = true
  private var previousOffsetY: CGFloat = 0.0
  private var skipNextTransitionScrollCorrection = false
  private var lastKnownViewportHeight: CGFloat = 0.0
  private var contentPaddingBottom: CGFloat = sectionBottomInset
  private var isApplyingRowsUpdate = false
  private var pendingRowsPayload: [[String: Any]]?
  private var sourceRowsPayload: [[String: Any]] = []
  private var nativeSendEnabled = false
  private var nativeOutgoingRowsById: [String: [String: Any]] = [:]
  private var nativeOutgoingOrder: [String] = []
  private var isInternalScrollAdjustment = false
  private var isUpdatingBottomInset = false
  private var activeVoicePlaybackMessageId: String?
  private var activeVoicePlaybackIsPlaying = false
  private var activeVoicePlaybackProgress: CGFloat = 0.0
  private var lastViewportEmitTime: CFTimeInterval = 0.0
  private var lastViewportPayload:
    (
      contentHeight: CGFloat,
      layoutHeight: CGFloat,
      offsetY: CGFloat,
      distanceFromBottom: CGFloat,
      atBottom: Bool
    )?
  private let viewportEmitMinInterval: CFTimeInterval = 1.0 / 30.0

  private var hiddenMessageId: String?
  private var pendingSendTransition: SendTransitionPayload?
  private var activeSendTransition: SendTransitionState?
  var swipeReplyPanGesture: UIPanGestureRecognizer?
  var contextMenuLongPressGesture: UILongPressGestureRecognizer?
  var dismissInputTapGesture: UITapGestureRecognizer?
  var swipeReplyIndexPath: IndexPath?
  var swipeReplyMessageId: String?
  var swipeReplyIsMe: Bool = false
  var swipeReplyDidTrigger = false
  weak var contextMenuHostCell: UICollectionViewCell?
  var contextMenuHostCellOriginalTransform: CGAffineTransform = .identity
  var customContextMenuOverlay: ChatContextMenuOverlay?

  // --- Native input bar ---
  private(set) var inputBar: ChatInputBar?
  private var inputBarEnabled = false
  private var inputBarPlaceholder = "Message"
  private var keyboardHeight: CGFloat = 0
  /// Persistent overlay container that sits above everything for send transitions.
  private let transitionOverlayHost = UIView()

  // --- Debug animation tuning ---
  private var debugAnimDuration: CGFloat = 0.4
  private var debugAnimSlideOffset: CGFloat = 20.0
  private var debugPanelVisible = false {
    didSet { debugPanel?.isHidden = !debugPanelVisible }
  }
  private var debugPanel: UIView?
  private var debugDurationLabel: UILabel?
  private var debugOffsetLabel: UILabel?
  private var debugStatsLabel: UILabel?

  required init(appContext: AppContext? = nil) {
    NSLog("[ChatListView] init START")
    let layout = ChatCollectionFlowLayout()
    layout.minimumLineSpacing = 2
    layout.sectionInset = UIEdgeInsets(
      top: sectionTopInset, left: messageHorizontalInset, bottom: sectionBottomInset,
      right: messageHorizontalInset)
    layout.sectionHeadersPinToVisibleBounds = false

    flowLayout = layout
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    super.init(appContext: appContext)
    NSLog("[ChatListView] init super.init done")
    clipsToBounds = false

    layer.insertSublayer(wallpaperLayer, at: 0)

    addSubview(collectionView)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    collectionView.backgroundColor = .clear
    collectionView.clipsToBounds = false
    collectionView.alwaysBounceVertical = true
    collectionView.showsVerticalScrollIndicator = false
    collectionView.register(
      ChatListCell.self, forCellWithReuseIdentifier: ChatListCell.reuseIdentifier)
    collectionView.dataSource = self
    collectionView.delegate = self
    installInteractionGestures()
    applyWallpaperAppearance()

    // Transition overlay host — always on top of everything
    transitionOverlayHost.isUserInteractionEnabled = false
    transitionOverlayHost.clipsToBounds = false
    addSubview(transitionOverlayHost)

    setupDebugPanel()

    // Keyboard observers
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillHide(_:)),
      name: UIResponder.keyboardWillHideNotification, object: nil)

    NSLog("[ChatListView] init COMPLETE")
  }

  private func pixelAlignedValue(_ value: CGFloat) -> CGFloat {
    let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1.0)
    return (value * scale).rounded() / scale
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override public func layoutSubviews() {
    let previousHeight = lastKnownViewportHeight
    super.layoutSubviews()
    wallpaperLayer.frame = bounds
    transitionOverlayHost.frame = bounds
    layoutDebugPanel()

    // Layout native input bar if enabled
    if inputBarEnabled {
      layoutInputBarAndInset()
    }

    let currentHeight = collectionView.bounds.height
    lastKnownViewportHeight = currentHeight

    guard previousHeight > 0.0, abs(previousHeight - currentHeight) > 0.5 else {
      updateBottomAnchorInset()
      emitViewport(force: true)
      maybeStartPendingSendTransition()
      return
    }

    let distanceBeforeResize = max(
      0.0, collectionView.contentSize.height - (collectionView.contentOffset.y + previousHeight))
    if distanceBeforeResize <= listBottomThreshold || shouldAutoScroll {
      scrollToBottom(animated: false)
    } else {
      restoreStationaryDistance(distanceBeforeResize)
    }
    updateBottomAnchorInset()
    previousOffsetY = collectionView.contentOffset.y
    emitViewport(force: true)
    maybeStartPendingSendTransition()
  }

  func setRows(_ nextRows: [[String: Any]]) {
    sourceRowsPayload = nextRows
    NSLog(
      "[ChatListView] setRows called — count: %d, isApplying: %@", nextRows.count,
      isApplyingRowsUpdate ? "true" : "false")
    if isApplyingRowsUpdate {
      pendingRowsPayload = nextRows
      return
    }
    isApplyingRowsUpdate = true

    let mergedRows = mergedRowsPayload(from: nextRows)
    let visibleRows = filteredRowsPayloadForSendTransition(from: mergedRows)
    let parsed = visibleRows.compactMap(ChatListRow.init)
    NSLog("[ChatListView] setRows parsed: %d, previous: %d", parsed.count, rows.count)
    let previousRows = rows
    let previousDistanceFromBottom = currentDistanceFromBottom()
    let wasNearBottom = previousDistanceFromBottom <= listBottomThreshold

    // NOTE: Do NOT set `rows = parsed` here. The data source (`rows`) must
    // reflect the OLD count until inside performBatchUpdates, otherwise UIKit
    // sees a mismatch between "before" count and the insert/delete operations.

    // Capture a stationary anchor: the topmost visible item's key and its screen-Y.
    let stationaryAnchor: (key: String, screenY: CGFloat)? = {
      guard !wasNearBottom else { return nil }
      let visibleIndexPaths = collectionView.indexPathsForVisibleItems
        .sorted { lhs, rhs in
          if lhs.section == rhs.section {
            return lhs.item < rhs.item
          }
          return lhs.section < rhs.section
        }
      guard let topIndexPath = visibleIndexPaths.first,
        topIndexPath.item < previousRows.count,
        let cell = collectionView.cellForItem(at: topIndexPath)
      else {
        return nil
      }
      let row = previousRows[topIndexPath.item]
      let screenY = cell.frame.minY - collectionView.contentOffset.y
      return (row.key, screenY)
    }()

    let applyDataSource = { [weak self] in
      self?.rows = parsed
    }

    let finalize = { [weak self] (animated: Bool) in
      guard let self else {
        return
      }
      self.collectionView.layoutIfNeeded()
      self.updateBottomAnchorInset()
      // Force a second layout pass so contentSize reflects the inset change
      // before scrollToBottom reads it. Without this, maxOffsetY can be 0
      // causing the newest message to appear at the top instead of the bottom.
      self.collectionView.layoutIfNeeded()
      if wasNearBottom {
        self.scrollToBottom(animated: animated)
      } else if let anchor = stationaryAnchor,
        let newIndex = parsed.firstIndex(where: { $0.key == anchor.key })
      {
        let ip = IndexPath(item: newIndex, section: 0)
        if let attrs = self.collectionView.layoutAttributesForItem(at: ip) {
          let desiredOffset = attrs.frame.minY - anchor.screenY
          let maxOffset = max(
            0.0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
          let clampedOffset = pixelAlignedValue(max(0.0, min(maxOffset, desiredOffset)))
          self.performInternalScrollAdjustment {
            self.collectionView.setContentOffset(CGPoint(x: 0.0, y: clampedOffset), animated: false)
          }
        }
      } else {
        self.restoreStationaryDistance(previousDistanceFromBottom)
      }
      self.previousOffsetY = self.collectionView.contentOffset.y
      self.emitViewport(force: true)
      self.finishRowsUpdate()
      self.maybeStartPendingSendTransition()
    }

    let oldKeys = previousRows.map(\.key)
    let newKeys = parsed.map(\.key)
    let oldSet = Set(oldKeys)
    let newSet = Set(newKeys)
    let oldSharedOrder = oldKeys.filter { newSet.contains($0) }
    let newSharedOrder = newKeys.filter { oldSet.contains($0) }

    // Initial load or full replacement: use reloadData (no batch update needed).
    guard !previousRows.isEmpty else {
      applyDataSource()
      UIView.performWithoutAnimation {
        collectionView.reloadData()
      }
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        finalize(false)
        CATransaction.commit()
      }
      return
    }

    // Reorder/move-heavy updates are uncommon here; fallback to full reload.
    guard oldSharedOrder == newSharedOrder else {
      applyDataSource()
      UIView.performWithoutAnimation {
        collectionView.reloadData()
      }
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        finalize(false)
        CATransaction.commit()
      }
      return
    }

    let deletions = previousRows.enumerated()
      .filter { !newSet.contains($0.element.key) }
      .map { IndexPath(item: $0.offset, section: 0) }
      .sorted { $0.item > $1.item }
    let insertions = parsed.enumerated()
      .filter { !oldSet.contains($0.element.key) }
      .map { IndexPath(item: $0.offset, section: 0) }
      .sorted { $0.item < $1.item }

    let previousByKey = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.key, $0) })
    let previousIndexByKey = Dictionary(
      uniqueKeysWithValues: previousRows.enumerated().map { ($0.element.key, $0.offset) })
    let reloads = parsed.compactMap { row -> IndexPath? in
      guard let previous = previousByKey[row.key], let oldIndex = previousIndexByKey[row.key]
      else {
        return nil
      }
      return chatListRowContentEqual(previous, row)
        ? nil
        : IndexPath(item: oldIndex, section: 0)
    }
    let safeReloads = reloads.filter { $0.item >= 0 && $0.item < previousRows.count }

    guard !deletions.isEmpty || !insertions.isEmpty || !safeReloads.isEmpty else {
      NSLog("[ChatListView] setRows — no changes, finalize only")
      applyDataSource()
      finalize(false)
      return
    }

    if deletions.isEmpty && insertions.isEmpty && !safeReloads.isEmpty {
      applyDataSource()
      // Telegram approach: content updates are INSTANT — no opacity, no
      // crossfade, no animation of any kind. Just swap the content.
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for indexPath in safeReloads {
          guard indexPath.item < rows.count else { continue }
          if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell {
            cell.applyAppearance(appearance)
            cell.configure(row: rows[indexPath.item], hiddenMessageId: hiddenMessageId)
            cell.alpha = 1.0
            cell.contentView.alpha = 1.0
            cell.layer.opacity = 1.0
            cell.contentView.layer.opacity = 1.0
            cell.layer.removeAllAnimations()
            cell.contentView.layer.removeAllAnimations()
          }
        }
        CATransaction.commit()
      }
      // Lightweight finalize: skip updateBottomAnchorInset + scrollToBottom.
      // Reloads don't change cell count or total height, so insets and scroll
      // position are unchanged. Running the full finalize here triggers
      // updateBottomAnchorInset which can shift cells by 2-3px while additive
      // animations from a prior insertion are still in flight, causing flicker.
      previousOffsetY = collectionView.contentOffset.y
      emitViewport(force: true)
      finishRowsUpdate()
      maybeStartPendingSendTransition()
      return
    }

    NSLog(
      "[ChatListView] setRows batchUpdate — del:%d ins:%d reload:%d (dataSource before: %d, after: %d)",
      deletions.count, insertions.count, safeReloads.count, previousRows.count, parsed.count)

    let expectedAfterCount = previousRows.count + insertions.count - deletions.count
    guard expectedAfterCount == parsed.count else {
      NSLog(
        "[ChatListView] ⚠️ batch count mismatch (expected %d, got %d) — falling back to reloadData",
        expectedAfterCount, parsed.count)
      applyDataSource()
      UIView.performWithoutAnimation {
        collectionView.reloadData()
      }
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        finalize(false)
        CATransaction.commit()
      }
      return
    }

    // Determine animation mode from appearance (0=none, 1=slideUpNew, 2=telegramOffset, 3=springBatch)
    let animMode = appearance.insertionAnimationMode

    // Animate insertions for small incremental appends near the bottom.
    // During a send transition, we still animate EXISTING cells shifting
    // (so the list moves smoothly) but skip fade-in on the new cell
    // (the overlay handles that).
    let shouldAnimateInsertions =
      !insertions.isEmpty
      && insertions.count <= 5
      && wasNearBottom
      && animMode > 0  // mode 0 = no animation

    // Animate scroll-to-bottom for small appends, BUT NOT during a send
    // transition. During send, we scroll instantly so the cell is at its
    // final position before the overlay animation starts (otherwise the
    // overlay "chases" the scrolling cell and appears at the wrong spot).
    let hasPendingSend = pendingSendTransition != nil || activeSendTransition != nil
    let shouldAnimateScroll =
      !insertions.isEmpty
      && insertions.count <= 5
      && wasNearBottom
      && !hasPendingSend

    // --- Telegram-style frame recording (mode 2 only) ---
    // Record SCREEN-SPACE Y (center.y - contentOffset.y) so additive
    // animations account for any scroll change finalize introduces.
    var preUpdateScreenY: [String: CGFloat] = [:]
    var preUpdateOffset: CGFloat = 0
    if shouldAnimateInsertions && animMode == 2 {
      preUpdateOffset = collectionView.contentOffset.y
      for cell in collectionView.visibleCells {
        guard let ip = collectionView.indexPath(for: cell), ip.item < previousRows.count else {
          continue
        }
        let key = previousRows[ip.item].key
        preUpdateScreenY[key] = cell.center.y - preUpdateOffset
      }
    }
    let insertedKeySet = Set(
      insertions.compactMap { ip -> String? in
        guard ip.item < parsed.count else { return nil }
        return parsed[ip.item].key
      })

    // ===================================================================
    // MODE 3: Spring Batch — UIView.animate wraps entire performBatchUpdates
    // ===================================================================
    if shouldAnimateInsertions && animMode == 3 {
      UIView.animate(
        withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.0,
        options: [.allowUserInteraction, .beginFromCurrentState],
        animations: { [weak self] in
          guard let self else { return }
          self.collectionView.performBatchUpdates(
            {
              applyDataSource()
              if !deletions.isEmpty {
                self.collectionView.deleteItems(at: deletions)
              }
              if !insertions.isEmpty {
                self.collectionView.insertItems(at: insertions)
              }
              if !safeReloads.isEmpty {
                if #available(iOS 15.0, *) {
                  self.collectionView.reconfigureItems(at: safeReloads)
                } else {
                  self.collectionView.reloadItems(at: safeReloads)
                }
              }
            }, completion: nil)
        },
        completion: { _ in
          finalize(shouldAnimateScroll)
        })
      return
    }

    // ===================================================================
    // MODES 0, 1, 2: Batch update without UIKit animation, then add
    //                 additive CAAnimations synchronously (same frame).
    // ===================================================================
    // IMPORTANT: Animations are applied synchronously after the batch
    // update (not in the completion handler) to guarantee they're in the
    // same render frame. The completion handler fires asynchronously,
    // which causes a 1-frame jump before the animation starts.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    UIView.performWithoutAnimation {
      collectionView.performBatchUpdates(
        {
          applyDataSource()
          if !deletions.isEmpty {
            collectionView.deleteItems(at: deletions)
          }
          if !insertions.isEmpty {
            collectionView.insertItems(at: insertions)
          }
          if !safeReloads.isEmpty {
            if #available(iOS 15.0, *) {
              collectionView.reconfigureItems(at: safeReloads)
            } else {
              collectionView.reloadItems(at: safeReloads)
            }
          }
        },
        completion: nil)
    }
    CATransaction.commit()

    // Force layout so cells are at their final post-update positions.
    collectionView.layoutIfNeeded()

    // Finalize FIRST: settle layout + scroll to bottom instantly.
    // This ensures cells are at their true final screen positions
    // before we compute screen-space deltas for additive animations.
    // Always scroll instantly here — the additive CA animations
    // provide the smooth visual transition.
    finalize(false)

    // CRITICAL (Telegram approach): Strip ALL UIKit-implicit animations
    // from every visible cell. UICollectionView sneaks in opacity/position/
    // bounds animations during performBatchUpdates even inside
    // performWithoutAnimation. We must remove them BEFORE applying our
    // own additive position animations. Without this, cells show brief
    // opacity flicker/transparency during insertions.
    for cell in collectionView.visibleCells {
      cell.alpha = 1.0
      cell.contentView.alpha = 1.0
      cell.layer.removeAnimation(forKey: "opacity")
      cell.layer.removeAnimation(forKey: "position")
      cell.layer.removeAnimation(forKey: "bounds.size")
      cell.layer.removeAnimation(forKey: "bounds.origin")
      cell.layer.removeAnimation(forKey: "bounds")
      cell.layer.removeAnimation(forKey: "transform")
      cell.contentView.layer.removeAnimation(forKey: "opacity")
      cell.contentView.layer.removeAnimation(forKey: "position")
      // Ensure absolute full opacity — no transparency at any point.
      cell.layer.opacity = 1.0
      cell.contentView.layer.opacity = 1.0
    }

    if shouldAnimateInsertions {
      // Telegram timing: 0.3s spring (matches kCAMediaTimingFunctionSpring).
      // NOT a custom cubic bezier — a real spring with 0.3s settling time.
      let animDuration: CFTimeInterval = 0.3
      let animTiming = chatListSendVerticalTiming
      var dbgShifted = 0
      var dbgNewSlide = 0
      var dbgMaxDelta: CGFloat = 0
      var dbgScrollDelta: CGFloat = 0

      switch animMode {
      case 1:
        // MODE 1: SlideUpNewOnly — only new cells get animation
        for ip in insertions {
          guard let cell = collectionView.cellForItem(at: ip) else { continue }
          if let hid = hiddenMessageId, ip.item < rows.count,
            rows[ip.item].messageId == hid
          {
            continue
          }
          let slideUp = CABasicAnimation(keyPath: "position.y")
          slideUp.fromValue = pixelAlignedValue(debugAnimSlideOffset) as NSNumber
          slideUp.toValue = 0.0 as NSNumber
          slideUp.isAdditive = true
          slideUp.duration = animDuration
          slideUp.timingFunction = animTiming
          slideUp.isRemovedOnCompletion = true
          cell.layer.add(slideUp, forKey: "insertSlideUp")
          dbgNewSlide += 1
        }

      case 2:
        // MODE 2: TelegramOffset — additive position animation for ALL cells
        // Use screen-space deltas so the animation accounts for any
        // scroll change that finalize introduced.
        let postOffset = collectionView.contentOffset.y
        dbgScrollDelta = postOffset - preUpdateOffset
        NSLog(
          "[ChatListAnim] mode2 — preScreenY:%d preOff:%.1f postOff:%.1f scrollΔ:%.1f visible:%d",
          preUpdateScreenY.count, preUpdateOffset, postOffset, dbgScrollDelta,
          collectionView.visibleCells.count)

        for cell in collectionView.visibleCells {
          guard let ip = collectionView.indexPath(for: cell),
            ip.item < rows.count
          else { continue }
          let key = rows[ip.item].key

          if let oldScreenY = preUpdateScreenY[key] {
            let currentScreenY = cell.center.y - postOffset
            let delta = pixelAlignedValue(oldScreenY - currentScreenY)
            if abs(delta) > 0.5 {
              let anim = CABasicAnimation(keyPath: "position.y")
              anim.fromValue = delta as NSNumber
              anim.toValue = 0.0 as NSNumber
              anim.isAdditive = true
              anim.duration = animDuration
              anim.timingFunction = animTiming
              anim.isRemovedOnCompletion = true
              cell.layer.add(anim, forKey: "insertionShift")
              dbgShifted += 1
              dbgMaxDelta = max(dbgMaxDelta, abs(delta))
              NSLog(
                "[ChatListAnim]   shift '%@' Δ:%.1f (oldScr:%.1f newScr:%.1f)",
                String(key.prefix(12)), delta, oldScreenY, currentScreenY)
            }
          } else if insertedKeySet.contains(key) {
            let isHiddenForSend: Bool = {
              guard let hid = self.hiddenMessageId, ip.item < self.rows.count else { return false }
              return self.rows[ip.item].messageId == hid
            }()
            if !isHiddenForSend {
              let slideAnim = CABasicAnimation(keyPath: "position.y")
              slideAnim.fromValue = pixelAlignedValue(debugAnimSlideOffset) as NSNumber
              slideAnim.toValue = 0.0 as NSNumber
              slideAnim.isAdditive = true
              slideAnim.duration = animDuration
              slideAnim.timingFunction = animTiming
              slideAnim.isRemovedOnCompletion = true
              cell.layer.add(slideAnim, forKey: "insertSlideUp")
              dbgNewSlide += 1
              NSLog(
                "[ChatListAnim]   newSlide '%@' offset:%.0f", String(key.prefix(12)),
                debugAnimSlideOffset)
            } else {
              NSLog("[ChatListAnim]   skip hidden '%@'", String(key.prefix(12)))
            }
          } else {
            NSLog(
              "[ChatListAnim]   noAnim '%@' (not in preScreenY, not inserted)",
              String(key.prefix(12)))
          }
        }

      default:
        break
      }

      NSLog(
        "[ChatListAnim] result — shifted:%d newSlide:%d maxΔ:%.1f scrollΔ:%.1f dur:%.2f offset:%.0f",
        dbgShifted, dbgNewSlide, dbgMaxDelta, dbgScrollDelta, animDuration, debugAnimSlideOffset)
      updateDebugStats(
        shifted: dbgShifted, newSlide: dbgNewSlide,
        maxDelta: dbgMaxDelta, scrollDelta: dbgScrollDelta)
    }
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    let next = ChatListAppearance.from(raw: rawAppearance)
    let visualChanged = appearance.visualKey != next.visualKey
    appearance = next
    inputBar?.applyAppearance(next)
    if visualChanged {
      applyWallpaperAppearance()
      collectionView.reloadData()
    }
  }

  func resolvedAppearance() -> ChatListAppearance {
    appearance
  }

  func setContentPaddingBottom(_ value: Double) {
    // Native input mode owns bottom inset (bar height + keyboard height).
    // Ignore external padding updates to prevent keyboard overlap regressions.
    guard !inputBarEnabled else {
      return
    }
    let next = max(sectionBottomInset, CGFloat(value))
    if abs(next - contentPaddingBottom) <= 0.5 {
      return
    }
    contentPaddingBottom = next
    updateBottomAnchorInset()
    emitViewport(force: true)
  }

  func setVoicePlayback(_ payload: [String: Any]) {
    let nextMessageId = payload["messageId"] as? String
    let nextIsPlaying = (payload["isPlaying"] as? Bool) ?? false
    let nextProgressRaw = payload["progress"] as? Double ?? 0.0
    let nextProgress = max(0.0, min(1.0, CGFloat(nextProgressRaw)))

    if activeVoicePlaybackMessageId == nextMessageId
      && activeVoicePlaybackIsPlaying == nextIsPlaying
      && abs(activeVoicePlaybackProgress - nextProgress) <= 0.001
    {
      return
    }

    activeVoicePlaybackMessageId = nextMessageId
    activeVoicePlaybackIsPlaying = nextIsPlaying
    activeVoicePlaybackProgress = nextProgress
    applyVoicePlaybackToVisibleCells()
  }

  private func applyVoicePlaybackToVisibleCells() {
    for case let cell as ChatListCell in collectionView.visibleCells {
      cell.setExternalVoicePlayback(
        messageId: activeVoicePlaybackMessageId,
        isPlaying: activeVoicePlaybackIsPlaying,
        progress: activeVoicePlaybackProgress
      )
    }
  }

  func applyTransactions(_ transactions: [[String: Any]]) {
    onNativeEvent(["type": "transactionsApplied", "count": transactions.count])
  }

  func scrollToBottom(animated: Bool) {
    let maxOffsetY = pixelAlignedValue(
      max(0.0, collectionView.contentSize.height - collectionView.bounds.height))
    if animated {
      // For animated scroll, use UIView spring animation to match the insertion feel.
      shouldAutoScroll = true
      isInternalScrollAdjustment = true
      UIView.animate(
        withDuration: 0.4,
        delay: 0.0,
        usingSpringWithDamping: 0.88,
        initialSpringVelocity: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) { [weak self] in
        self?.collectionView.contentOffset = CGPoint(x: 0.0, y: maxOffsetY)
      } completion: { [weak self] _ in
        guard let self else { return }
        self.isInternalScrollAdjustment = false
        self.previousOffsetY = self.collectionView.contentOffset.y
        self.emitViewport(force: true)
      }
    } else {
      performInternalScrollAdjustment {
        collectionView.setContentOffset(CGPoint(x: 0.0, y: maxOffsetY), animated: false)
      }
      previousOffsetY = collectionView.contentOffset.y
      shouldAutoScroll = true
      emitViewport(force: true)
    }
  }

  func scrollToMessage(messageId: String, animated: Bool, viewPosition: Double) {
    guard let rowIndex = indexForMessage(messageId) else {
      return
    }
    let indexPath = IndexPath(item: rowIndex, section: 0)
    collectionView.layoutIfNeeded()
    guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else {
      return
    }
    let clamped = max(0.0, min(1.0, viewPosition))
    let targetY =
      attrs.frame.minY - ((collectionView.bounds.height - attrs.frame.height) * CGFloat(clamped))
    let maxOffset = max(0.0, collectionView.contentSize.height - collectionView.bounds.height)
    let clampedOffset = pixelAlignedValue(max(0.0, min(maxOffset, targetY)))
    collectionView.setContentOffset(CGPoint(x: 0.0, y: clampedOffset), animated: animated)
    previousOffsetY = clampedOffset
    shouldAutoScroll = false
    emitViewport(force: true)
  }

  func startSendTransition(_ payload: [String: Any]) {
    guard let parsed = SendTransitionPayload(payload: payload, hostView: self) else {
      NSLog("[ChatListView] startSendTransition — failed to parse payload")
      return
    }
    NSLog(
      "[ChatListView] startSendTransition — messageId: %@, hiding cell immediately",
      parsed.messageId)
    // Hide the message immediately so it never renders visibly before the
    // transition overlay starts. cellForItemAt checks hiddenMessageId.
    hiddenMessageId = parsed.messageId
    pendingSendTransition = parsed
    maybeStartPendingSendTransition()
  }

  func playReactionFx(_ payload: [String: Any]) {
    guard let emojiRaw = payload["emoji"] as? String else { return }
    let emoji = emojiRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !emoji.isEmpty else { return }
    guard
      let pointX = payloadCGFloat(payload["x"] ?? payload["sourceX"]),
      let pointY = payloadCGFloat(payload["y"] ?? payload["sourceY"])
    else {
      return
    }

    var localPoint = CGPoint(x: pointX, y: pointY)
    if let window {
      localPoint = convert(localPoint, from: window)
    }
    localPoint.x = min(max(localPoint.x, -32.0), bounds.width + 32.0)
    localPoint.y = min(max(localPoint.y, -32.0), bounds.height + 32.0)

    let color = resolvedReactionFxColor(payload["color"])
    renderNativeReactionFxBurst(emoji: emoji, at: localPoint, tintColor: color)
  }

  public func collectionView(
    _ collectionView: UICollectionView, numberOfItemsInSection section: Int
  ) -> Int {
    rows.count
  }

  public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    guard indexPath.item < rows.count else {
      // Reconfigure paths may request an index that has just shifted during a
      // batched delete+reload. Return the existing cell when present to avoid
      // UIKit's "different cell during reconfigure" assertion.
      if let existingCell = collectionView.cellForItem(at: indexPath) {
        return existingCell
      }
      return UICollectionViewCell()
    }
    guard
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: ChatListCell.reuseIdentifier, for: indexPath) as? ChatListCell
    else {
      return UICollectionViewCell()
    }
    cell.applyAppearance(appearance)
    cell.configure(row: rows[indexPath.item], hiddenMessageId: hiddenMessageId)
    // Removed onVoiceBubbleTap so iOS uses Native Audio playback for Voice bubbles (like Android)
    cell.setExternalVoicePlayback(
      messageId: activeVoicePlaybackMessageId,
      isPlaying: activeVoicePlaybackIsPlaying,
      progress: activeVoicePlaybackProgress
    )
    // Telegram rule: cells are NEVER transparent. Force full opacity
    // and strip any UIKit-implicit opacity animation.
    cell.alpha = 1.0
    cell.contentView.alpha = 1.0
    cell.layer.opacity = 1.0
    cell.contentView.layer.opacity = 1.0
    cell.layer.removeAnimation(forKey: "opacity")
    cell.contentView.layer.removeAnimation(forKey: "opacity")
    return cell
  }

  public func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    guard indexPath.item < rows.count else {
      return CGSize(width: max(0.0, bounds.width - (messageHorizontalInset * 2.0)), height: 56.0)
    }
    let row = rows[indexPath.item]
    let width = max(0.0, bounds.width - (messageHorizontalInset * 2.0))
    if row.kind == .day {
      return CGSize(width: width, height: 30.0)
    }
    if shouldSuppressMessageFromLayout(row.messageId) {
      // Keep the outgoing row out of layout while send transition is pending/active.
      return CGSize(width: width, height: 0.001)
    }
    return CGSize(width: width, height: estimateMessageHeight(row, rowWidth: width))
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if customContextMenuOverlay != nil {
      dismissCustomContextMenu(animated: false)
    }
    let offsetY = scrollView.contentOffset.y
    _ = offsetY - previousOffsetY  // delta unused
    previousOffsetY = offsetY

    if let activeSendTransition {
      if skipNextTransitionScrollCorrection {
        skipNextTransitionScrollCorrection = false
      } else {
        // With additive animations, we just update the model position to
        // follow the real cell. The additive offset decays independently.
        updateTransitionFrame(activeSendTransition)
      }
    }

    if !isInternalScrollAdjustment {
      let distanceFromBottom = currentDistanceFromBottom()
      shouldAutoScroll = distanceFromBottom <= listBottomThreshold
    }
    maybeStartPendingSendTransition()
    emitViewport()
  }

  private func updateBottomAnchorInset() {
    // Re-entry guard: this method invalidates layout and calls layoutIfNeeded,
    // which can trigger layoutSubviews → updateBottomAnchorInset again, causing
    // a visible bounce as insets oscillate.
    guard !isUpdatingBottomInset else { return }
    isUpdatingBottomInset = true
    defer { isUpdatingBottomInset = false }

    let baseInsets = UIEdgeInsets(
      top: sectionTopInset, left: messageHorizontalInset, bottom: contentPaddingBottom,
      right: messageHorizontalInset)
    let currentInsets = flowLayout.sectionInset
    let contentHeight = collectionView.collectionViewLayout.collectionViewContentSize.height
    let contentWithoutInsets = max(0.0, contentHeight - currentInsets.top - currentInsets.bottom)
    let desiredTop = max(
      baseInsets.top, collectionView.bounds.height - contentWithoutInsets - baseInsets.bottom)
    let topUnchanged = abs(desiredTop - currentInsets.top) <= 0.5
    let bottomUnchanged = abs(baseInsets.bottom - currentInsets.bottom) <= 0.5
    if topUnchanged && bottomUnchanged {
      return
    }
    flowLayout.sectionInset = UIEdgeInsets(
      top: desiredTop, left: baseInsets.left, bottom: baseInsets.bottom, right: baseInsets.right)
    flowLayout.invalidateLayout()
    collectionView.layoutIfNeeded()
  }

  private func estimateMessageHeight(_ row: ChatListRow, rowWidth: CGFloat) -> CGFloat {
    measureMessageBubbleLayout(row: row, rowWidth: rowWidth).bubbleHeight
  }

  private func currentDistanceFromBottom() -> CGFloat {
    let contentHeight = collectionView.contentSize.height
    let layoutHeight = collectionView.bounds.height
    let offsetY = collectionView.contentOffset.y
    return max(0.0, contentHeight - (offsetY + layoutHeight))
  }

  private func restoreStationaryDistance(_ distanceFromBottom: CGFloat) {
    let targetOffset = max(
      0.0, collectionView.contentSize.height - collectionView.bounds.height - distanceFromBottom)
    _ = targetOffset - collectionView.contentOffset.y  // delta unused
    if let activeSendTransition {
      skipNextTransitionScrollCorrection = true
      updateTransitionFrame(activeSendTransition)
    }
    performInternalScrollAdjustment {
      collectionView.setContentOffset(CGPoint(x: 0.0, y: targetOffset), animated: false)
    }
    previousOffsetY = collectionView.contentOffset.y
    shouldAutoScroll = false
  }

  private func finishRowsUpdate() {
    isApplyingRowsUpdate = false
    guard let queued = pendingRowsPayload else {
      return
    }
    NSLog(
      "[ChatListAnim] ⚠️ finishRowsUpdate — processing queued setRows (%d rows) during finalize",
      queued.count)
    pendingRowsPayload = nil
    setRows(queued)
  }

  private func performInternalScrollAdjustment(_ block: () -> Void) {
    isInternalScrollAdjustment = true
    block()
    DispatchQueue.main.async { [weak self] in
      self?.isInternalScrollAdjustment = false
    }
  }

  private func payloadCGFloat(_ value: Any?) -> CGFloat? {
    if let number = value as? NSNumber {
      return CGFloat(number.doubleValue)
    }
    if let number = value as? Double {
      return CGFloat(number)
    }
    if let number = value as? Int {
      return CGFloat(number)
    }
    if let text = value as? String, let parsed = Double(text) {
      return CGFloat(parsed)
    }
    return nil
  }

  private func resolvedReactionFxColor(_ value: Any?) -> UIColor {
    if let raw = value as? String, let color = parseReactionFxColor(raw) {
      return color
    }
    return (appearance.bubbleMeGradient.last ?? UIColor.white).withAlphaComponent(0.95)
  }

  private func parseReactionFxColor(_ raw: String) -> UIColor? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#") else { return nil }
    var hex = String(trimmed.dropFirst())
    if hex.count == 3 {
      hex = hex.map { "\($0)\($0)" }.joined()
    }
    guard hex.count == 6 else { return nil }
    var value: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
    let r = CGFloat((value & 0xFF0000) >> 16) / 255.0
    let g = CGFloat((value & 0x00FF00) >> 8) / 255.0
    let b = CGFloat(value & 0x0000FF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: 1.0)
  }

  private func renderNativeReactionFxBurst(emoji: String, at point: CGPoint, tintColor: UIColor) {
    let container = UIView(frame: bounds)
    container.clipsToBounds = false
    container.isUserInteractionEnabled = false
    transitionOverlayHost.addSubview(container)

    let emojiLabel = UILabel()
    emojiLabel.text = emoji
    emojiLabel.font = UIFont.systemFont(ofSize: 30)
    emojiLabel.sizeToFit()
    emojiLabel.center = point
    emojiLabel.alpha = 0.0
    emojiLabel.transform = CGAffineTransform(scaleX: 0.74, y: 0.74)
    container.addSubview(emojiLabel)

    UIView.animateKeyframes(
      withDuration: 0.52,
      delay: 0.0,
      options: [.calculationModeCubic, .beginFromCurrentState]
    ) {
      UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.25) {
        emojiLabel.alpha = 1.0
        emojiLabel.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
      }
      UIView.addKeyframe(withRelativeStartTime: 0.24, relativeDuration: 0.76) {
        emojiLabel.alpha = 0.0
        emojiLabel.center = CGPoint(x: point.x, y: point.y - 32.0)
        emojiLabel.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
      }
    }

    let particleCount = 11
    for index in 0..<particleCount {
      let dotSize = CGFloat.random(in: 3.4...6.2)
      let dot = UIView(frame: CGRect(x: 0, y: 0, width: dotSize, height: dotSize))
      dot.layer.cornerRadius = dotSize * 0.5
      dot.backgroundColor = tintColor.withAlphaComponent(CGFloat.random(in: 0.72...0.95))
      dot.center = point
      container.addSubview(dot)

      let angle = (CGFloat(index) / CGFloat(max(1, particleCount))) * (.pi * 2.0)
      let radial = CGFloat.random(in: 24.0...58.0)
      let dx = cos(angle) * radial
      let dy = (sin(angle) * radial * 0.72) - CGFloat.random(in: 14.0...26.0)

      UIView.animate(
        withDuration: 0.44,
        delay: Double(index % 4) * 0.015,
        options: [.curveEaseOut, .beginFromCurrentState]
      ) {
        dot.center = CGPoint(x: point.x + dx, y: point.y + dy)
        dot.alpha = 0.0
        dot.transform = CGAffineTransform(scaleX: 0.35, y: 0.35)
      } completion: { _ in
        dot.removeFromSuperview()
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
      container.removeFromSuperview()
    }
  }

  private func messageId(fromRawRow row: [String: Any]) -> String? {
    guard
      (row["kind"] as? String) == "message",
      let message = row["message"] as? [String: Any],
      let messageId = normalizedMessageId(message["id"])
    else {
      return nil
    }
    return messageId
  }

  private func normalizedMessageId(_ raw: Any?) -> String? {
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = raw as? NSNumber {
      return value.stringValue
    }
    if let value = raw as? Int {
      return String(value)
    }
    if let value = raw as? Double, value.isFinite {
      return String(value)
    }
    return nil
  }

  private func shouldSuppressMessageFromLayout(_ messageId: String?) -> Bool {
    guard let hiddenMessageId, let messageId, messageId == hiddenMessageId else {
      return false
    }
    // Suppress only while transition is pending (pre-animation). Once active,
    // the row must participate in layout so the list pushes smoothly.
    return pendingSendTransition != nil
  }

  private func filteredRowsPayloadForSendTransition(from rows: [[String: Any]]) -> [[String: Any]] {
    guard let hiddenMessageId, pendingSendTransition != nil else {
      return rows
    }
    return rows.filter { row in
      messageId(fromRawRow: row) != hiddenMessageId
    }
  }

  private func rawRow(messageId targetMessageId: String, in payload: [[String: Any]])
    -> [String: Any]?
  {
    payload.first(where: { messageId(fromRawRow: $0) == targetMessageId })
  }

  private func resolveTransitionRow(for payload: SendTransitionPayload) -> ChatListRow? {
    if let rowIndex = indexForMessage(payload.messageId), rowIndex < rows.count {
      return rows[rowIndex]
    }
    if let row = rawRow(messageId: payload.messageId, in: sourceRowsPayload),
      let parsed = ChatListRow(raw: row)
    {
      return parsed
    }
    if let row = nativeOutgoingRowsById[payload.messageId], let parsed = ChatListRow(raw: row) {
      return parsed
    }
    return nil
  }

  private func projectedTransitionTargetRect(for row: ChatListRow) -> CGRect? {
    guard row.kind == .message else {
      return nil
    }
    let rowWidth = max(1.0, collectionView.bounds.width - (messageHorizontalInset * 2.0))
    let metrics = measureMessageBubbleLayout(row: row, rowWidth: rowWidth)
    let bubbleXInRow =
      row.isMe ? rowWidth - metrics.bubbleWidth - bubbleSideMargin : bubbleSideMargin

    let bubbleYInHost: CGFloat = {
      let listMinY = collectionView.frame.minY
      if inputBarEnabled, let bar = inputBar {
        let barMinYInHost = bar.frame.minY
        return max(listMinY + sectionTopInset, barMinYInHost - metrics.bubbleHeight - 2.0)
      }
      let listVisibleBottom = listMinY + collectionView.bounds.height
      return max(
        listMinY + sectionTopInset,
        listVisibleBottom - contentPaddingBottom - metrics.bubbleHeight)
    }()

    return CGRect(
      x: collectionView.frame.minX + messageHorizontalInset + bubbleXInRow,
      y: bubbleYInHost,
      width: metrics.bubbleWidth,
      height: metrics.bubbleHeight
    ).integral
  }

  private func mergedRowsPayload(from baseRows: [[String: Any]]) -> [[String: Any]] {
    guard nativeSendEnabled, !nativeOutgoingOrder.isEmpty else {
      return baseRows
    }

    var merged = baseRows
    var baseMessageIds = Set<String>()
    for row in baseRows {
      if let messageId = messageId(fromRawRow: row) {
        baseMessageIds.insert(messageId)
      }
    }

    var nextOrder: [String] = []
    for messageId in nativeOutgoingOrder {
      guard let row = nativeOutgoingRowsById[messageId] else {
        continue
      }
      if baseMessageIds.contains(messageId) {
        nativeOutgoingRowsById.removeValue(forKey: messageId)
        continue
      }
      merged.append(row)
      nextOrder.append(messageId)
    }
    nativeOutgoingOrder = nextOrder
    return merged
  }

  private func queueNativeOutgoingMessage(
    messageId: String,
    text: String,
    timestamp: String,
    timestampMs: Double,
    replyToId: String? = nil
  ) {
    var message: [String: Any] = [
      "id": messageId,
      "text": text,
      "timestamp": timestamp,
      "timestampMs": timestampMs,
      "isMe": true,
      "status": "pending",
    ]
    if let replyToId {
      message["replyToId"] = replyToId
    }
    nativeOutgoingRowsById[messageId] = [
      "kind": "message",
      "key": "m-\(messageId)",
      "message": message,
    ]
    if !nativeOutgoingOrder.contains(messageId) {
      nativeOutgoingOrder.append(messageId)
    }
    setRows(sourceRowsPayload)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self,
        var row = self.nativeOutgoingRowsById[messageId],
        var message = row["message"] as? [String: Any]
      else {
        return
      }
      message["status"] = "sent"
      row["message"] = message
      self.nativeOutgoingRowsById[messageId] = row
      self.setRows(self.sourceRowsPayload)
    }
  }

  private func indexForMessage(_ messageId: String) -> Int? {
    rows.firstIndex(where: { row in
      row.kind == .message && row.messageId == messageId
    })
  }

  private func resolveTransitionTargetRect(
    messageId: String,
    fallbackPayload: SendTransitionPayload? = nil
  ) -> CGRect? {
    if let rowIndex = indexForMessage(messageId), rowIndex < rows.count {
      let indexPath = IndexPath(item: rowIndex, section: 0)
      if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell,
        let rect = cell.bubbleRect(in: self)
      {
        return rect
      }
    }
    if let fallbackPayload, let row = resolveTransitionRow(for: fallbackPayload) {
      return projectedTransitionTargetRect(for: row)
    }
    return nil
  }

  private func makeTransitionSnapshotCell(for row: ChatListRow) -> ChatListCell {
    let rowWidth = max(1.0, bounds.width - (messageHorizontalInset * 2.0))
    let rowHeight: CGFloat
    if row.kind == .day {
      rowHeight = 30.0
    } else {
      rowHeight = estimateMessageHeight(row, rowWidth: rowWidth)
    }

    let renderCell = ChatListCell(
      frame: CGRect(x: -10_000.0, y: -10_000.0, width: rowWidth, height: max(1.0, rowHeight)))
    renderCell.applyAppearance(appearance)
    renderCell.configure(row: row, hiddenMessageId: nil)
    transitionOverlayHost.addSubview(renderCell)
    renderCell.setNeedsLayout()
    renderCell.layoutIfNeeded()
    return renderCell
  }

  private func maybeStartPendingSendTransition() {
    guard activeSendTransition == nil, let payload = pendingSendTransition else {
      return
    }
    guard let targetRow = resolveTransitionRow(for: payload) else {
      NSLog(
        "[ChatListView] maybeStartPendingSendTransition — waiting, row unavailable for '%@'",
        payload.messageId)
      return
    }
    guard
      let targetRect = resolveTransitionTargetRect(
        messageId: payload.messageId,
        fallbackPayload: payload)
    else {
      NSLog(
        "[ChatListView] maybeStartPendingSendTransition — target rect unresolved for '%@'",
        payload.messageId)
      return
    }

    pendingSendTransition = nil
    let snapshotCell = makeTransitionSnapshotCell(for: targetRow)
    defer {
      snapshotCell.removeFromSuperview()
    }

    // Build native send overlay: source/input ghost + bubble crossfade/morph.
    let overlayParts = SendTransitionOverlayFactory.make(
      appearance: appearance,
      snapshotCell: snapshotCell,
      targetBubbleRect: targetRect,
      payload: payload,
      hostView: self
    )
    transitionOverlayHost.addSubview(overlayParts.container)

    let state = SendTransitionState(
      host: self,
      payload: payload,
      overlayContainer: overlayParts.container,
      clippingView: overlayParts.clippingView,
      sourceBackgroundSnapshot: overlayParts.sourceBackgroundSnapshot,
      bubbleBackgroundSnapshot: overlayParts.bubbleBackgroundSnapshot,
      destinationContentSnapshot: overlayParts.destinationContentSnapshot,
      sourceTextSnapshot: overlayParts.sourceTextSnapshot,
      sourceBackgroundStartFrame: overlayParts.sourceBackgroundStartFrame,
      sourceBackgroundEndFrame: overlayParts.sourceBackgroundEndFrame,
      sourceContentStartFrame: overlayParts.sourceContentStartFrame,
      destinationContentFrame: overlayParts.destinationContentFrame,
      sourceScrollOffset: overlayParts.sourceScrollOffset
    )
    activeSendTransition = state
    onNativeEvent(["type": "sendTransitionStarted", "messageId": payload.messageId])

    // Promote the hidden outgoing row into layout now (as an invisible row)
    // so the list shift is synchronized with transition motion.
    if isApplyingRowsUpdate {
      pendingRowsPayload = sourceRowsPayload
    } else {
      setRows(sourceRowsPayload)
    }

    collectionView.layoutIfNeeded()
    let settledTargetRect =
      resolveTransitionTargetRect(messageId: payload.messageId, fallbackPayload: payload)
      ?? targetRect

    // Start the additive animation from source rect → target rect.
    NSLog(
      "[ChatListView] sendTransition rects — source: (%.0f,%.0f %.0fx%.0f) target: (%.0f,%.0f %.0fx%.0f) bounds: %.0fx%.0f",
      overlayParts.sourceRect.minX, overlayParts.sourceRect.minY, overlayParts.sourceRect.width,
      overlayParts.sourceRect.height,
      settledTargetRect.minX, settledTargetRect.minY, settledTargetRect.width,
      settledTargetRect.height,
      bounds.width, bounds.height)
    state.start(sourceRect: overlayParts.sourceRect, targetRect: settledTargetRect)
  }

  /// Called by scrollViewDidScroll to keep the overlay tracking the real cell.
  func updateTransitionFrame(_ transition: SendTransitionState) {
    guard
      let targetRect = resolveTransitionTargetRect(
        messageId: transition.payload.messageId,
        fallbackPayload: transition.payload)
    else {
      return
    }
    transition.compensateScroll(targetRect: targetRect)
  }

  func completeTransition(_ transition: SendTransitionState) {
    guard activeSendTransition === transition else {
      NSLog("[ChatListView] completeTransition — ignoring stale transition")
      return
    }
    NSLog(
      "[ChatListView] completeTransition — revealing message '%@'", transition.payload.messageId)
    transition.invalidate()
    transition.overlayContainer.removeFromSuperview()
    activeSendTransition = nil

    let revealedMessageId = hiddenMessageId
    hiddenMessageId = nil
    if let revealedMessageId, let rowIndex = indexForMessage(revealedMessageId),
      rowIndex < rows.count
    {
      let indexPath = IndexPath(item: rowIndex, section: 0)
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell {
          cell.applyAppearance(appearance)
          cell.configure(row: rows[rowIndex], hiddenMessageId: nil)
          cell.alpha = 1.0
          cell.contentView.alpha = 1.0
          cell.layer.opacity = 1.0
          cell.contentView.layer.opacity = 1.0
          cell.layer.removeAllAnimations()
          cell.contentView.layer.removeAllAnimations()
        } else {
          if #available(iOS 15.0, *) {
            collectionView.reconfigureItems(at: [indexPath])
          } else {
            collectionView.reloadItems(at: [indexPath])
          }
        }
        CATransaction.commit()
      }
    } else if revealedMessageId != nil {
      // If the row is not yet materialized (e.g. async source update), ask the
      // list to apply latest payload once so the message becomes visible.
      setRows(sourceRowsPayload)
    }
    onNativeEvent(["type": "sendTransitionCompleted", "messageId": revealedMessageId ?? ""])
  }

  private var hasLoggedDispatcherStatus = false
  private func emitViewport(force: Bool = false) {
    if !hasLoggedDispatcherStatus {
      hasLoggedDispatcherStatus = true
      NSLog("[ChatListView] EventDispatcher status — dispatchers initialized (non-nil)")
    }
    let contentHeight = collectionView.contentSize.height
    let layoutHeight = collectionView.bounds.height
    let offsetY = collectionView.contentOffset.y
    let distanceFromBottom = max(0.0, contentHeight - (offsetY + layoutHeight))
    let atBottom = distanceFromBottom <= listBottomThreshold

    let now = CACurrentMediaTime()
    if !force, let last = lastViewportPayload {
      let atBottomChanged = atBottom != last.atBottom
      let payloadUnchanged =
        abs(contentHeight - last.contentHeight) <= 0.5
        && abs(layoutHeight - last.layoutHeight) <= 0.5
        && abs(offsetY - last.offsetY) <= 0.5
        && abs(distanceFromBottom - last.distanceFromBottom) <= 0.5
        && !atBottomChanged
      if payloadUnchanged {
        return
      }
      if (now - lastViewportEmitTime) < viewportEmitMinInterval && !atBottomChanged {
        return
      }
    }

    lastViewportEmitTime = now
    lastViewportPayload = (
      contentHeight: contentHeight,
      layoutHeight: layoutHeight,
      offsetY: offsetY,
      distanceFromBottom: distanceFromBottom,
      atBottom: atBottom
    )

    onViewportChanged([
      "contentHeight": contentHeight,
      "layoutHeight": layoutHeight,
      "offsetY": offsetY,
      "distanceFromBottom": distanceFromBottom,
      "atBottom": atBottom,
    ])
  }

  private func applyWallpaperAppearance() {
    wallpaperLayer.colors = appearance.wallpaperGradient.map(\.cgColor)
    wallpaperLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    wallpaperLayer.endPoint = CGPoint(x: 0.0, y: 1.0)
    wallpaperLayer.opacity = Float(max(0.0, min(1.0, appearance.wallpaperOpacity)))
    wallpaperLayer.isHidden = appearance.backgroundMode == "transparent"
  }

  // MARK: - Debug Animation Panel

  func setDebugAnimationPanel(_ enabled: Bool) {
    debugPanelVisible = enabled
  }

  private func setupDebugPanel() {
    let panel = UIView()
    panel.backgroundColor = UIColor(white: 0, alpha: 0.85)
    panel.layer.cornerRadius = 16
    panel.clipsToBounds = true
    panel.isHidden = true

    let titleLabel = UILabel()
    titleLabel.text = "Animation Debug"
    titleLabel.font = .boldSystemFont(ofSize: 14)
    titleLabel.textColor = .white
    titleLabel.tag = 300
    panel.addSubview(titleLabel)

    let durationLabel = UILabel()
    durationLabel.text = "Duration: 0.40s"
    durationLabel.font = .systemFont(ofSize: 12)
    durationLabel.textColor = .white
    panel.addSubview(durationLabel)
    debugDurationLabel = durationLabel

    let durationSlider = UISlider()
    durationSlider.minimumValue = 0.05
    durationSlider.maximumValue = 1.5
    durationSlider.value = 0.4
    durationSlider.tintColor = .systemBlue
    durationSlider.addTarget(self, action: #selector(debugDurationChanged(_:)), for: .valueChanged)
    durationSlider.tag = 301
    panel.addSubview(durationSlider)

    let offsetLabel = UILabel()
    offsetLabel.text = "Offset: 20px"
    offsetLabel.font = .systemFont(ofSize: 12)
    offsetLabel.textColor = .white
    panel.addSubview(offsetLabel)
    debugOffsetLabel = offsetLabel

    let offsetSlider = UISlider()
    offsetSlider.minimumValue = 0
    offsetSlider.maximumValue = 100
    offsetSlider.value = 20
    offsetSlider.tintColor = .systemOrange
    offsetSlider.addTarget(self, action: #selector(debugOffsetChanged(_:)), for: .valueChanged)
    offsetSlider.tag = 302
    panel.addSubview(offsetSlider)

    let statsLabel = UILabel()
    statsLabel.text = "Waiting for batch…"
    statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    statsLabel.textColor = UIColor(white: 1, alpha: 0.7)
    statsLabel.numberOfLines = 2
    panel.addSubview(statsLabel)
    debugStatsLabel = statsLabel

    addSubview(panel)
    debugPanel = panel
  }

  private func layoutDebugPanel() {
    guard let panel = debugPanel, !panel.isHidden else { return }
    let w = bounds.width - 32
    panel.frame = CGRect(x: 16, y: safeAreaInsets.top + 8, width: w, height: 180)

    let pad: CGFloat = 12
    let labelH: CGFloat = 18
    let sliderH: CGFloat = 30
    let innerW = w - pad * 2
    var cy: CGFloat = pad

    if let title = panel.viewWithTag(300) {
      title.frame = CGRect(x: pad, y: cy, width: innerW, height: labelH)
      cy += labelH + 4
    }
    debugDurationLabel?.frame = CGRect(x: pad, y: cy, width: innerW, height: labelH)
    cy += labelH
    if let slider = panel.viewWithTag(301) {
      slider.frame = CGRect(x: pad, y: cy, width: innerW, height: sliderH)
      cy += sliderH + 2
    }
    debugOffsetLabel?.frame = CGRect(x: pad, y: cy, width: innerW, height: labelH)
    cy += labelH
    if let slider = panel.viewWithTag(302) {
      slider.frame = CGRect(x: pad, y: cy, width: innerW, height: sliderH)
      cy += sliderH + 4
    }
    debugStatsLabel?.frame = CGRect(x: pad, y: cy, width: innerW, height: 36)

    bringSubviewToFront(panel)
  }

  @objc private func debugDurationChanged(_ sender: UISlider) {
    debugAnimDuration = CGFloat(sender.value)
    debugDurationLabel?.text = String(format: "Duration: %.2fs", sender.value)
  }

  @objc private func debugOffsetChanged(_ sender: UISlider) {
    debugAnimSlideOffset = CGFloat(sender.value)
    debugOffsetLabel?.text = String(format: "Offset: %.0fpx", sender.value)
  }

  private func updateDebugStats(
    shifted: Int, newSlide: Int, maxDelta: CGFloat, scrollDelta: CGFloat
  ) {
    debugStatsLabel?.text = String(
      format: "shifted:%d new:%d maxΔ:%.0f scrollΔ:%.0f\ndur:%.2fs off:%.0fpx",
      shifted, newSlide, maxDelta, scrollDelta, debugAnimDuration, debugAnimSlideOffset)
  }

  // MARK: - Native Input Bar

  func setInputBarEnabled(_ enabled: Bool) {
    guard enabled != inputBarEnabled else { return }
    inputBarEnabled = enabled

    if enabled {
      let bar = ChatInputBar()
      bar.delegate = self
      bar.placeholder = inputBarPlaceholder
      bar.applyAppearance(appearance)
      addSubview(bar)
      // Ensure overlay host is always on top
      bringSubviewToFront(transitionOverlayHost)
      inputBar = bar
      NSLog("[ChatListView] native input bar ENABLED")
    } else {
      inputBar?.removeFromSuperview()
      inputBar = nil
      NSLog("[ChatListView] native input bar DISABLED")
    }
    setNeedsLayout()
  }

  func setInputPlaceholder(_ value: String) {
    inputBarPlaceholder = value
    inputBar?.placeholder = value
  }

  func setNativeSendEnabled(_ enabled: Bool) {
    guard enabled != nativeSendEnabled else { return }
    nativeSendEnabled = enabled
    if !enabled {
      nativeOutgoingRowsById.removeAll()
      nativeOutgoingOrder.removeAll()
    }
    setRows(sourceRowsPayload)
  }

  // MARK: - Keyboard Tracking

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    guard inputBarEnabled else { return }
    guard let info = notification.userInfo,
      let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else { return }

    let endFrameInView = convert(endFrame, from: nil)
    let intersection = bounds.intersection(endFrameInView)
    let kbHeight = max(0, intersection.height)
    let duration =
      (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let curveRaw =
      (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

    keyboardHeight = kbHeight
    inputBar?.keyboardHeightForPanels = kbHeight
    inputBar?.keyboardProgress = kbHeight > 0 ? 1.0 : 0.0
    UIView.animate(withDuration: duration, delay: 0, options: options) { [weak self] in
      self?.layoutInputBarAndInset()
      self?.inputBar?.layoutIfNeeded()
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    guard inputBarEnabled else { return }
    guard let info = notification.userInfo else { return }
    let duration =
      (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let curveRaw =
      (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

    keyboardHeight = 0
    inputBar?.keyboardProgress = 0.0
    UIView.animate(withDuration: duration, delay: 0, options: options) { [weak self] in
      self?.layoutInputBarAndInset()
      self?.inputBar?.layoutIfNeeded()
    }
  }

  private func layoutInputBarAndInset() {
    guard let bar = inputBar else { return }
    let w = bounds.width
    let h = bounds.height
    guard w > 0, h > 0 else { return }
    let distanceBeforeInsetChange = currentDistanceFromBottom()
    let wasNearBottom = distanceBeforeInsetChange <= listBottomThreshold

    // When GIF panel is shown, the input bar itself owns the keyboard-sized
    // area and we must not also offset by keyboardHeight.
    let effectiveKeyboardHeight: CGFloat = bar.isGifPanelPresented ? 0 : keyboardHeight

    // If keyboard is effectively visible, safe area is handled by keyboard height.
    // Otherwise, account for bottom safe area in the bar layout.
    let safeBottom: CGFloat
    if effectiveKeyboardHeight > 0 {
      safeBottom = 0
    } else {
      safeBottom = safeAreaInsets.bottom
    }
    bar.bottomSafeAreaInset = safeBottom

    // Size the bar
    bar.frame = CGRect(x: 0, y: 0, width: w, height: 200)  // temporary width for layout calc
    bar.layoutIfNeeded()
    let barH = bar.barHeight

    // Position at bottom, above keyboard
    let barY = h - barH - effectiveKeyboardHeight
    bar.frame = CGRect(x: 0, y: barY, width: w, height: barH)

    // Update collection view bottom inset
    let totalBottomPadding = barH + effectiveKeyboardHeight
    let baseInsets = flowLayout.sectionInset
    if abs(baseInsets.bottom - totalBottomPadding) > 0.5 {
      contentPaddingBottom = totalBottomPadding
      updateBottomAnchorInset()
      if wasNearBottom {
        scrollToBottom(animated: false)
      } else {
        restoreStationaryDistance(distanceBeforeInsetChange)
      }
      emitViewport(force: true)
    }

    // Keep transition overlay host above everything
    transitionOverlayHost.frame = bounds
    bringSubviewToFront(transitionOverlayHost)
  }

  // MARK: - Native Send (synchronous, no bridge delay)

  private func handleNativeSend(text: String) {
    let messageId = UUID().uuidString.lowercased()
    let now = Date()
    let timestampMs = now.timeIntervalSince1970 * 1000
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let timestamp = formatter.string(from: now)

    // Capture reply-to ID before dismissing the banner (dismissing clears it).
    let replyToMessageId = inputBar?.activeReplyToMessageId

    NSLog(
      "[ChatListView] handleNativeSend START — messageId: %@, text length: %lu, nativeSendEnabled: %@, replyTo: %@",
      messageId, text.count, nativeSendEnabled ? "true" : "false", replyToMessageId ?? "nil")

    // 1. Dismiss reply banner (non-animated, before layout measurement).
    inputBar?.dismissReplyBanner(animated: false)

    // 2. Hide the message cell immediately (before it even exists).
    hiddenMessageId = messageId

    // 3. Compute source rects and capture live text snapshot (BEFORE clearing).
    let sourceRect: CGRect
    let sourceContainerRect: CGRect?
    let sourceBackgroundRectInContainer: CGRect?
    let sourceContentRectInContainer: CGRect?
    let sourceScrollOffset: CGFloat
    let sourceBackgroundSnapshotView: UIView?
    let sourceContentSnapshotView: UIView?
    if let bar = inputBar {
      if let capture = bar.captureSendTransition(in: self) {
        sourceRect = CGRect(
          x: capture.sourceContainerRect.minX + capture.sourceContentRectInContainer.minX,
          y: capture.sourceContainerRect.minY + capture.sourceContentRectInContainer.minY,
          width: capture.sourceContentRectInContainer.width,
          height: capture.sourceContentRectInContainer.height
        )
        sourceContainerRect = capture.sourceContainerRect
        sourceBackgroundRectInContainer = capture.sourceBackgroundRectInContainer
        sourceContentRectInContainer = capture.sourceContentRectInContainer
        sourceScrollOffset = capture.sourceScrollOffset
        sourceBackgroundSnapshotView = capture.sourceBackgroundSnapshotView
        sourceContentSnapshotView = capture.sourceContentSnapshotView
      } else {
        sourceRect = bar.textRect(in: self)
        sourceContainerRect = nil
        sourceBackgroundRectInContainer = nil
        sourceContentRectInContainer = nil
        sourceScrollOffset = 0.0
        sourceBackgroundSnapshotView = bar.transitionBackgroundSnapshot(in: self)
        sourceContentSnapshotView = bar.textContentSnapshot(in: self)
      }
    } else {
      sourceRect = CGRect(x: 16, y: bounds.height - 60, width: bounds.width - 32, height: 44)
      sourceContainerRect = nil
      sourceBackgroundRectInContainer = nil
      sourceContentRectInContainer = nil
      sourceScrollOffset = 0.0
      sourceBackgroundSnapshotView = nil
      sourceContentSnapshotView = nil
    }

    // 4. Store pending transition so it starts when the cell arrives.
    let payload = SendTransitionPayload(
      messageId: messageId,
      text: text,
      timestamp: timestamp,
      startRect: sourceRect,
      sourceContainerRect: sourceContainerRect,
      sourceBackgroundRectInContainer: sourceBackgroundRectInContainer,
      sourceContentRectInContainer: sourceContentRectInContainer,
      sourceScrollOffset: sourceScrollOffset,
      sourceBackgroundSnapshotView: sourceBackgroundSnapshotView,
      sourceContentSnapshotView: sourceContentSnapshotView
    )
    pendingSendTransition = payload

    // 5. Clear the input bar.
    inputBar?.clearText()

    // 6. Either append natively (no JS dependency) or delegate to JS.
    if nativeSendEnabled {
      NSLog("[ChatListView] handleNativeSend using native queue")
      queueNativeOutgoingMessage(
        messageId: messageId,
        text: text,
        timestamp: timestamp,
        timestampMs: timestampMs,
        replyToId: replyToMessageId
      )
    } else {
      NSLog("[ChatListView] handleNativeSend dispatching onNativeEvent sendMessage")
      var sendPayload: [String: Any] = [
        "type": "sendMessage",
        "messageId": messageId,
        "text": text,
        "timestamp": timestamp,
        "timestampMs": timestampMs,
      ]
      if let replyToMessageId {
        sendPayload["replyToMessageId"] = replyToMessageId
      }
      onNativeEvent(sendPayload)
      NSLog("[ChatListView] handleNativeSend onNativeEvent dispatched")
    }
    NSLog("[ChatListView] handleNativeSend END")
  }
}

// MARK: - ChatInputBarDelegate

extension ChatListView: ChatInputBarDelegate {
  func inputBarDidSend(text: String) {
    handleNativeSend(text: text)
  }

  func inputBarDidTapAttachment() {
    onNativeEvent(["type": "attachmentPressed"])
  }

  func inputBarDidTapAction() {
    onNativeEvent(["type": "inputActionPressed", "action": "mic"])
  }

  func inputBarTextDidChange(text: String) {
    onNativeEvent(["type": "textChanged", "text": text])
  }

  func inputBarHeightDidChange() {
    setNeedsLayout()
  }

  func inputBarRecordingStateDidChange(isRecording: Bool, isLocked: Bool, mode: String) {
    onNativeEvent([
      "type": "recordingState",
      "isRecording": isRecording,
      "isLocked": isLocked,
      "mode": mode,
    ])
  }

  func inputBarRecordingDidCancel() {
    onNativeEvent(["type": "recordingCanceled"])
  }

  func inputBarDidRecordVoice(uri: String, duration: Double, waveform: [Double]) {
    onNativeEvent([
      "type": "attachmentVoice",
      "uri": uri,
      "duration": duration,
      "name": "voice-message.m4a",
      "waveform": waveform,
    ])
  }

  func inputBarDidRecordVideoNote(uri: String, duration: Double) {
    onNativeEvent([
      "type": "attachmentVideoNote",
      "uri": uri,
      "duration": duration,
      "name": "video-note.mov",
    ])
  }

  func inputBarDidSelectImage(uri: String) {
    onNativeEvent(["type": "attachmentImage", "uri": uri])
  }

  func inputBarDidSelectGif(
    id: String,
    url: String,
    previewUrl: String,
    width: Int,
    height: Int
  ) {
    onNativeEvent([
      "type": "attachmentGif",
      "id": id,
      "url": url,
      "previewUrl": previewUrl,
      "width": width,
      "height": height,
    ])
  }

  func inputBarDidSelectFile(uri: String, name: String) {
    onNativeEvent(["type": "attachmentFile", "uri": uri, "name": name])
  }

  func inputBarDidSelectLocation(latitude: Double, longitude: Double) {
    onNativeEvent(["type": "attachmentLocation", "latitude": latitude, "longitude": longitude])
  }

  func inputBarReplyDismissed() {
    onNativeEvent(["type": "replyDismissed"])
  }
}
