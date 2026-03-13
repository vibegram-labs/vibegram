import ExpoModulesCore
import QuickLook
import UIKit

private final class ChatListDocumentPreviewDataSource: NSObject, QLPreviewControllerDataSource {
  private let previewURL: URL

  init(previewURL: URL) {
    self.previewURL = previewURL
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
    -> QLPreviewItem
  {
    previewURL as NSURL
  }
}

private final class ChatListTextPreviewController: UIViewController {
  private let previewTitle: String
  private let textContent: String
  private let textView = UITextView()

  init(title: String, text: String) {
    self.previewTitle = title
    self.textContent = text
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = previewTitle

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.alwaysBounceVertical = true
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    textView.text = textContent

    view.addSubview(textView)
    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}

private let chatListSendVerticalTiming = CAMediaTimingFunction(
  controlPoints: Float(0.19919472913616398),
  Float(0.010644531250000006),
  Float(0.27920937042459737),
  Float(0.91025390625)
)
private let chatReactionDebugLogs = true

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
  private let wallpaperPatternLayer = CAGradientLayer()
  private let wallpaperPatternMaskLayer = CALayer()
  private let scrollToneOverlay = UIView()
  private let scrollToneTopLayer = CAGradientLayer()
  private let scrollToneBottomLayer = CAGradientLayer()
  var rows: [ChatListRow] = []
  private var appearance = ChatListAppearance.fallback
  private var queuedAppearanceAfterSendTransition: ChatListAppearance?
  private var shouldAutoScroll = true
  private var previousOffsetY: CGFloat = 0.0
  private var skipNextTransitionScrollCorrection = false
  private var lastKnownViewportWidth: CGFloat = 0.0
  private var lastKnownViewportHeight: CGFloat = 0.0
  private var contentPaddingTop: CGFloat = sectionTopInset
  private var contentPaddingBottom: CGFloat = sectionBottomInset
  private var isApplyingRowsUpdate = false
  private var _setRowsGeneration: UInt = 0
  private var pendingRowsPayload: [[String: Any]]?
  private var sourceRowsPayload: [[String: Any]] = []
  private var nativeSendEnabled = false
  private var engineSurfaceId: String = ""
  private var engineChatId: String = ""
  private var engineMyUserId: String = ""
  private var enginePeerUserId: String = ""
  private var engineOpenedChatId: String = ""
  private var statusAuthorityEnabled = false
  private var nativeOutgoingRowsById: [String: [String: Any]] = [:]
  private var nativeOutgoingOrder: [String] = []
  private var nativeEngineRowsById: [String: [String: Any]] = [:]
  private var nativeEngineOrder: [String] = []
  private var nativeDeletedMessageIds = Set<String>()
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
  private var documentPreviewDataSource: ChatListDocumentPreviewDataSource?
  private var documentPreviewCacheByRemoteURL: [String: URL] = [:]
  private var documentPreviewInFlightURLs = Set<String>()
  private var reactionDebugTargetMessageId: String?
  private var reactionDebugTargetEmoji: String?
  private var reactionDebugRemainingRowsChecks: Int = 0

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
  var customContextMenuWindow: UIWindow?

  // --- Native input bar ---
  private(set) var inputBar: ChatInputBar?
  private var inputBarEnabled = false
  private var inputBarPlaceholder = "Message"
  var keyboardHeight: CGFloat = 0
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
  private static var wallpaperMaskImageCache: [String: CGImage] = [:]
  private static let cachedThemeIdDefaultsKey = "vibe.chat.native.themeId.v1"
  private static let cachedThemeIsDarkDefaultsKey = "vibe.chat.native.themeIsDark.v1"
  private static let documentPreviewSession: URLSession = {
    if #available(iOS 13.0, *) {
      return ChatPhoenixClient.makePinnedURLSession()
    }
    return URLSession.shared
  }()

  private var isPeerTyping: Bool = false
  private var isGroupOrChannel: Bool = false

  // Floating activity overlay (typing / agent progress) — lives OUTSIDE the collection view
  private let activityOverlay = UIView()
  private let activityDotContainer = UIView()
  private let activityDots: [UIView] = (0..<3).map { _ in UIView() }
  private let activityTextLabel = UILabel()

  func setIsGroupOrChannel(_ value: Bool) {
    isGroupOrChannel = value
  }

  required init(appContext: AppContext? = nil) {
    let layout = ChatCollectionFlowLayout()
    layout.minimumLineSpacing = 2
    layout.sectionInset = UIEdgeInsets(
      top: sectionTopInset, left: messageHorizontalInset, bottom: sectionBottomInset,
      right: messageHorizontalInset)
    layout.sectionHeadersPinToVisibleBounds = false

    flowLayout = layout
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    super.init(appContext: appContext)
    clipsToBounds = false

    if let cachedAppearance = Self.bootstrapCachedAppearance() {
      appearance = cachedAppearance
    }

    wallpaperPatternLayer.mask = wallpaperPatternMaskLayer
    wallpaperPatternMaskLayer.contentsGravity = .resizeAspectFill
    wallpaperPatternMaskLayer.contentsScale = UIScreen.main.scale
    layer.insertSublayer(wallpaperLayer, at: 0)
    layer.insertSublayer(wallpaperPatternLayer, above: wallpaperLayer)

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

    scrollToneOverlay.isUserInteractionEnabled = false
    scrollToneOverlay.backgroundColor = .clear
    scrollToneOverlay.clipsToBounds = true
    scrollToneOverlay.layer.addSublayer(scrollToneTopLayer)
    scrollToneOverlay.layer.addSublayer(scrollToneBottomLayer)
    addSubview(scrollToneOverlay)

    applyWallpaperAppearance()
    applyScrollToneTheme()
    updateScrollToneOverlay(offsetY: 0.0)

    // Transition overlay host — always on top of everything
    transitionOverlayHost.isUserInteractionEnabled = false
    transitionOverlayHost.clipsToBounds = false
    addSubview(transitionOverlayHost)

    setupActivityOverlay()
    setupDebugPanel()

    // Keyboard observers
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillHide(_:)),
      name: UIResponder.keyboardWillHideNotification, object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineChanged(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )

  }

  private func pixelAlignedValue(_ value: CGFloat) -> CGFloat {
    let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1.0)
    return (value * scale).rounded() / scale
  }

  private func reactionDebugLog(_ message: String) {
    guard chatReactionDebugLogs else { return }
    NSLog("[ChatReactionDebug] %@", message)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    updateChatEngineChannelBinding(forceDetach: true)
    if !engineSurfaceId.isEmpty {
      _ = ChatEngine.shared.unbindSurface(["surfaceId": engineSurfaceId])
    }
  }

  override public func didMoveToWindow() {
    super.didMoveToWindow()
    updateChatEngineChannelBinding()
  }

  override public func layoutSubviews() {
    let previousHeight = lastKnownViewportHeight
    let previousWidth = lastKnownViewportWidth
    super.layoutSubviews()
    wallpaperLayer.frame = bounds
    wallpaperPatternLayer.frame = bounds
    wallpaperPatternMaskLayer.frame = wallpaperPatternLayer.bounds
    scrollToneOverlay.frame = bounds
    updateScrollToneOverlay(offsetY: collectionView.contentOffset.y)
    transitionOverlayHost.frame = bounds
    layoutDebugPanel()

    // Layout native input bar if enabled
    if inputBarEnabled {
      layoutInputBarAndInset()
    }
    layoutActivityOverlay()

    let currentHeight = collectionView.bounds.height
    let currentWidth = collectionView.bounds.width
    lastKnownViewportHeight = currentHeight
    lastKnownViewportWidth = currentWidth

    if abs(previousWidth - currentWidth) > 0.5 {
      collectionView.collectionViewLayout.invalidateLayout()
    }

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
    _setRowsGeneration &+= 1
    let mySetRowsGeneration = _setRowsGeneration

    let mergedRows = mergedRowsPayload(from: nextRows)
    let parsed = mergedRows.compactMap(ChatListRow.init).filter { row in
      row.messageType != "agent_progress"
    }
    if let targetMessageId = reactionDebugTargetMessageId, reactionDebugRemainingRowsChecks > 0 {
      reactionDebugRemainingRowsChecks -= 1
      if let row = parsed.first(where: { $0.messageId == targetMessageId }) {
        reactionDebugLog(
          "setRows target id=\(targetMessageId) reaction=\(row.reactionEmoji ?? "nil") checksLeft=\(reactionDebugRemainingRowsChecks)"
        )
      } else {
        reactionDebugLog(
          "setRows target missing id=\(targetMessageId) parsedCount=\(parsed.count) checksLeft=\(reactionDebugRemainingRowsChecks)"
        )
      }
    }
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
      let preInsetContentH = self.collectionView.contentSize.height
      let preInsetOffset = self.collectionView.contentOffset.y
      self.collectionView.layoutIfNeeded()
      self.updateBottomAnchorInset()
      // Force a second layout pass so contentSize reflects the inset change
      // before scrollToBottom reads it. Without this, maxOffsetY can be 0
      // causing the newest message to appear at the top instead of the bottom.
      self.collectionView.layoutIfNeeded()
      let postInsetContentH = self.collectionView.contentSize.height
      let postInsetOffset = self.collectionView.contentOffset.y
      NSLog(
        "[ChatListFinalize] wasNear:%@ anim:%@ preOff:%.1f postOff:%.1f preH:%.1f postH:%.1f bounds:%.1f rows:%d queued:%@",
        wasNearBottom ? "Y" : "N", animated ? "Y" : "N",
        preInsetOffset, postInsetOffset, preInsetContentH, postInsetContentH,
        self.collectionView.bounds.height, parsed.count,
        self.pendingRowsPayload != nil ? "Y" : "N")
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
      // Find first mismatch to help debug which key triggered the reorder
      var mismatchIdx = -1
      for i in 0..<min(oldSharedOrder.count, newSharedOrder.count) {
        if oldSharedOrder[i] != newSharedOrder[i] {
          mismatchIdx = i
          break
        }
      }
      if mismatchIdx < 0 && oldSharedOrder.count != newSharedOrder.count {
        mismatchIdx = min(oldSharedOrder.count, newSharedOrder.count)
      }
      let insertedKeys = newKeys.filter { !oldSet.contains($0) }
      let deletedKeys = oldKeys.filter { !newSet.contains($0) }
      NSLog(
        "[ChatListView] ⚠️ reorder fallback — oldShared:%d newShared:%d mismatchAt:%d inserted:%d deleted:%d insertedKeys:%@ deletedKeys:%@",
        oldSharedOrder.count, newSharedOrder.count, mismatchIdx,
        insertedKeys.count, deletedKeys.count,
        insertedKeys.prefix(3).map { String($0.prefix(16)) }.joined(separator: ","),
        deletedKeys.prefix(3).map { String($0.prefix(16)) }.joined(separator: ","))
      if mismatchIdx >= 0, mismatchIdx < min(oldSharedOrder.count, newSharedOrder.count) {
        NSLog(
          "[ChatListView]   mismatch old:'%@' new:'%@'",
          String(oldSharedOrder[mismatchIdx].prefix(20)),
          String(newSharedOrder[mismatchIdx].prefix(20)))
      }

      // Animate small reorders near the bottom (e.g. after completeTransition
      // swaps the last 2 items). Capture pre-update screen positions BEFORE
      // reloadData so we can apply mode2 additive animations afterward.
      let reorderAnimMode = appearance.insertionAnimationMode
      let shouldAnimateReorder =
        wasNearBottom
        && reorderAnimMode == 2
        && insertedKeys.count + deletedKeys.count <= 3

      var preReorderScreenY: [String: CGFloat] = [:]
      var preReorderOffset: CGFloat = 0
      if shouldAnimateReorder {
        preReorderOffset = collectionView.contentOffset.y
        for cell in collectionView.visibleCells {
          guard let ip = collectionView.indexPath(for: cell), ip.item < rows.count else { continue }
          preReorderScreenY[rows[ip.item].key] = cell.center.y - preReorderOffset
        }
      }

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

      // Apply mode2 additive animations after reloadData so the reorder
      // appears smooth instead of an instant jump.
      // Skip if a queued setRows ran during finalize (cells were
      // recreated/repositioned — our pre-reorder positions are stale).
      let reorderQueuedProcessed = _setRowsGeneration != mySetRowsGeneration
      if shouldAnimateReorder, !preReorderScreenY.isEmpty, !reorderQueuedProcessed {
        collectionView.layoutIfNeeded()

        // Strip UIKit implicit animations (same as the batch-update path).
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
          cell.layer.opacity = 1.0
          cell.contentView.layer.opacity = 1.0
        }

        let postReorderOffset = collectionView.contentOffset.y
        let animDuration: CFTimeInterval = 0.3
        let animTiming = chatListSendVerticalTiming
        var reorderShifted = 0

        for cell in collectionView.visibleCells {
          guard let ip = collectionView.indexPath(for: cell), ip.item < rows.count else { continue }
          let key = rows[ip.item].key
          if let oldScreenY = preReorderScreenY[key] {
            let currentScreenY = cell.center.y - postReorderOffset
            let delta = pixelAlignedValue(oldScreenY - currentScreenY)
            if abs(delta) > 0.5 {
              let anim = CABasicAnimation(keyPath: "position.y")
              anim.fromValue = delta as NSNumber
              anim.toValue = 0.0 as NSNumber
              anim.isAdditive = true
              anim.duration = animDuration
              anim.timingFunction = animTiming
              anim.isRemovedOnCompletion = true
              cell.layer.add(anim, forKey: "reorderShift")
              reorderShifted += 1
            }
          } else {
            // New cell that wasn't visible before — fade in.
            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 0.0 as NSNumber
            fadeAnim.toValue = 1.0 as NSNumber
            fadeAnim.duration = animDuration
            fadeAnim.timingFunction = animTiming
            fadeAnim.isRemovedOnCompletion = true
            cell.layer.add(fadeAnim, forKey: "reorderFadeIn")
          }
        }
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
      applyDataSource()
      finalize(false)
      return
    }

    if deletions.isEmpty && insertions.isEmpty && !safeReloads.isEmpty {
      let rowWidth = max(0.0, bounds.width - (messageHorizontalInset * 2.0))
      let requiresLayoutReload = safeReloads.contains { indexPath in
        guard indexPath.item < previousRows.count, indexPath.item < parsed.count else {
          return true
        }
        let previousRow = previousRows[indexPath.item]
        let nextRow = parsed[indexPath.item]
        guard previousRow.kind == nextRow.kind else {
          return true
        }
        guard previousRow.kind == .message else {
          return false
        }
        return abs(
          estimateMessageHeight(previousRow, rowWidth: rowWidth)
            - estimateMessageHeight(nextRow, rowWidth: rowWidth)
        ) > 0.5
      }

      applyDataSource()

      // Reactions add badge height to the bubble, so a content-only reconfigure
      // is not enough. Force a targeted relayout for height-changing reloads.
      if requiresLayoutReload {
        UIView.performWithoutAnimation {
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          flowLayout.invalidateLayout()
          collectionView.performBatchUpdates(
            {
              collectionView.reloadItems(at: safeReloads)
            },
            completion: nil)
          CATransaction.commit()
        }
        UIView.performWithoutAnimation {
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          finalize(false)
          CATransaction.commit()
        }
        return
      }

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
      let insertedKeys = parsed.enumerated().filter { !oldSet.contains($0.element.key) }.map {
        String($0.element.key.prefix(16))
      }
      NSLog(
        "[ChatListView] ⚠️ batch count mismatch (expected %d, got %d) — falling back to reloadData insertedKeys:%@",
        expectedAfterCount, parsed.count, insertedKeys.prefix(5).joined(separator: ","))
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

    // Animate insertions and deletions for small incremental appends near the bottom.
    // During a send transition, we still animate EXISTING cells shifting
    // (so the list moves smoothly) but skip fade-in on the new cell
    // (the overlay handles that).
    let isSmallUpdate =
      (insertions.count + deletions.count) > 0 && (insertions.count + deletions.count) <= 5
    let shouldAnimateUpdate =
      isSmallUpdate
      && wasNearBottom
      && animMode > 0  // mode 0 = no animation

    let insertedKeysSummary = insertions.prefix(3).compactMap { ip -> String? in
      guard ip.item < parsed.count else { return nil }
      let row = parsed[ip.item]
      return
        "\(String(row.key.prefix(12)))(\(row.isMe ? "me" : "them"),\(row.isAgentMessage ? "agent" : "user"))"
    }.joined(separator: " ")
    NSLog(
      "[ChatListView] animDecision — shouldAnim:%@ isSmall:%@ wasNear:%@ mode:%d del:%d ins:%d reload:%d keys:[%@]",
      shouldAnimateUpdate ? "Y" : "N", isSmallUpdate ? "Y" : "N",
      wasNearBottom ? "Y" : "N", animMode,
      deletions.count, insertions.count, safeReloads.count, insertedKeysSummary)

    // Animate scroll-to-bottom for small appends, BUT NOT during a send
    // transition. During send, we scroll instantly so the cell is at its
    // final position before the overlay animation starts (otherwise the
    // overlay "chases" the scrolling cell and appears at the wrong spot).
    let hasPendingSend = pendingSendTransition != nil || activeSendTransition != nil
    let shouldAnimateScroll =
      isSmallUpdate
      && wasNearBottom
      && !hasPendingSend

    // --- Telegram-style frame recording (mode 2 only) ---
    // Record SCREEN-SPACE Y (center.y - contentOffset.y) so additive
    // animations account for any scroll change finalize introduces.
    var preUpdateScreenY: [String: CGFloat] = [:]
    var preUpdateOffset: CGFloat = 0
    if shouldAnimateUpdate && animMode == 2 {
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
    if shouldAnimateUpdate && animMode == 3 {
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

    // For mode2 inserts (received messages): use ANIMATED scroll instead
    // of instant scroll + additive animations. This gives a natural
    // "push up" effect identical to one-on-one chats — the scroll
    // animation itself moves existing cells up and reveals the new cell
    // from below. The additive approach can't achieve this because the
    // new cell starts off-screen (below the clip boundary) and "pops in".
    // During send transitions we still use the additive path because
    // the cell is hidden and the overlay handles the visual.
    let useAnimatedScrollInsert =
      shouldAnimateUpdate
      && animMode == 2
      && shouldAnimateScroll  // wasNearBottom + !hasPendingSend
      && !insertions.isEmpty
      && deletions.isEmpty

    if useAnimatedScrollInsert {
      // Finalize settles layout + inset but scrolls instantly.
      finalize(false)

      // Strip UIKit implicit animations (prevent opacity flicker).
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
        cell.layer.opacity = 1.0
        cell.contentView.layer.opacity = 1.0
      }

      // Undo the instant scroll, then animate it. The UIView spring
      // scroll naturally pushes existing cells up and reveals the new
      // cell from the bottom — no additive animations needed.
      // Scroll back to pre-update position BEFORE starting the animated scroll.
      // Use performInternalScrollAdjustment to avoid the scrollViewDidScroll
      // logic marking the list as not-near-bottom.
      performInternalScrollAdjustment {
        collectionView.setContentOffset(
          CGPoint(x: 0, y: preUpdateOffset), animated: false)
      }
      // Now animate to bottom. scrollToBottom sets isInternalScrollAdjustment
      // and resets it in the completion handler.
      scrollToBottom(animated: true)

      updateDebugStats(shifted: 0, newSlide: 0, maxDelta: 0, scrollDelta: 0)
      return
    }

    // Finalize: settle layout + scroll to bottom instantly.
    // Cells land at their true final screen positions so we can
    // compute screen-space deltas for additive animations.
    finalize(false)

    // Detect if finishRowsUpdate processed a queued setRows (recursive).
    // When that happens, cells may have been recreated/repositioned by
    // the recursive update's own animation (reorder, reload, etc).
    // Applying additive animations from the OUTER batch update would use
    // stale preUpdateScreenY positions and conflict with the recursive
    // update's animation, causing a visible gap/shift.
    let queuedUpdateProcessed = _setRowsGeneration != mySetRowsGeneration

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

    if queuedUpdateProcessed {
      NSLog("[ChatListAnim] skipping additive — queued setRows processed during finalize")
      maybeStartPendingSendTransition()
      return
    }

    if shouldAnimateUpdate {
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
          // Skip slide animation for media/GIF/sticker — just appear in place.
          if ip.item < rows.count {
            let vk = rows[ip.item].visualKind
            if vk == .media || vk == .sticker || vk == .video || vk == .videoNote {
              continue
            }
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

        // --- Pass 1: compute shift deltas for existing cells ---
        // We need the max delta BEFORE applying new-cell animations so
        // the new cell's slide distance matches the existing shift.
        // Without this, the new cell uses a tiny fixed offset (e.g. 20)
        // while existing cells shift by ~74, causing the new cell to
        // visually overlap/appear above existing bubbles at T=0.
        struct CellAnimInfo {
          let cell: UICollectionViewCell
          let key: String
          let indexPath: IndexPath
          let delta: CGFloat  // shift delta for existing cells
          let isNew: Bool
          let isHiddenForSend: Bool
        }
        var cellInfos: [CellAnimInfo] = []
        for cell in collectionView.visibleCells {
          guard let ip = collectionView.indexPath(for: cell),
            ip.item < rows.count
          else { continue }
          let key = rows[ip.item].key

          if let oldScreenY = preUpdateScreenY[key] {
            let currentScreenY = cell.center.y - postOffset
            let delta = pixelAlignedValue(oldScreenY - currentScreenY)
            cellInfos.append(
              CellAnimInfo(
                cell: cell, key: key, indexPath: ip, delta: delta,
                isNew: false, isHiddenForSend: false))
            if abs(delta) > 0.5 {
              dbgMaxDelta = max(dbgMaxDelta, abs(delta))
            }
          } else if insertedKeySet.contains(key) {
            let isHidden: Bool = {
              guard let hid = self.hiddenMessageId, ip.item < self.rows.count else { return false }
              return self.rows[ip.item].messageId == hid
            }()
            cellInfos.append(
              CellAnimInfo(
                cell: cell, key: key, indexPath: ip, delta: 0,
                isNew: true, isHiddenForSend: isHidden))
          }
        }

        // New cells must start BELOW all existing cells' old positions.
        // Use the max existing shift (which equals how far existing cells
        // "push up") so the new cell slides in from below, not from the
        // middle of existing bubbles.
        let newCellSlideOffset = pixelAlignedValue(
          max(dbgMaxDelta, debugAnimSlideOffset))

        // --- Pass 2: apply animations ---
        for info in cellInfos {
          if !info.isNew {
            if abs(info.delta) > 0.5 {
              let anim = CABasicAnimation(keyPath: "position.y")
              anim.fromValue = info.delta as NSNumber
              anim.toValue = 0.0 as NSNumber
              anim.isAdditive = true
              anim.duration = animDuration
              anim.timingFunction = animTiming
              anim.isRemovedOnCompletion = true
              info.cell.layer.add(anim, forKey: "insertionShift")
              dbgShifted += 1
            }
          } else if !info.isHiddenForSend {
            // Skip slide animation for media/GIF/sticker — just appear in place.
            let skipSlide: Bool = {
              guard info.indexPath.item < rows.count else { return false }
              let vk = rows[info.indexPath.item].visualKind
              return vk == .media || vk == .sticker || vk == .video || vk == .videoNote
            }()
            if !skipSlide {
              // Additive path fallback (only reached during send transitions
              // where shouldAnimateScroll is false). For normal receives, the
              // animated-scroll path above handles the visual transition.
              let slideAnim = CABasicAnimation(keyPath: "position.y")
              slideAnim.fromValue = newCellSlideOffset as NSNumber
              slideAnim.toValue = 0.0 as NSNumber
              slideAnim.isAdditive = true
              slideAnim.duration = animDuration
              slideAnim.timingFunction = animTiming
              slideAnim.isRemovedOnCompletion = true
              info.cell.layer.add(slideAnim, forKey: "insertSlideUp")
              dbgNewSlide += 1
            }
          }
        }

      default:
        break
      }

      updateDebugStats(
        shifted: dbgShifted, newSlide: dbgNewSlide,
        maxDelta: dbgMaxDelta, scrollDelta: dbgScrollDelta)
    }

    // Safety net: ensure the send overlay starts even if the attempt
    // inside finalize failed (e.g. cell wasn't laid out yet).
    maybeStartPendingSendTransition()
  }

  func setEngineSurfaceId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if engineSurfaceId == next { return }
    if !engineSurfaceId.isEmpty {
      _ = ChatEngine.shared.unbindSurface(["surfaceId": engineSurfaceId])
    }
    engineSurfaceId = next
    updateChatEngineBinding()
  }

  func setEngineChatId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if engineChatId == next { return }
    engineChatId = next
    nativeEngineRowsById.removeAll()
    nativeEngineOrder.removeAll()
    nativeDeletedMessageIds.removeAll()
    updateChatEngineBinding()
    updateChatEngineChannelBinding()
    refreshVisibleStatuses(reason: "chatId")
    // Eagerly load native rows if history is already cached in ChatEngine.
    // This allows the list to render instantly without waiting for JS props.
    if statusAuthorityEnabled, !engineChatId.isEmpty,
      ChatEngine.shared.isChatHistoryLoaded(chatId: engineChatId)
    {
      setRows(sourceRowsPayload)
    }
  }

  func setEngineMyUserId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if engineMyUserId == next { return }
    engineMyUserId = next
    updateChatEngineBinding()
  }

  func setEnginePeerUserId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if enginePeerUserId == next { return }
    enginePeerUserId = next
    updateChatEngineBinding()
    refreshVisibleStatuses(reason: "peerUserId")
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    if statusAuthorityEnabled == enabled { return }
    statusAuthorityEnabled = enabled
    refreshVisibleStatuses(reason: "statusAuthorityEnabled")
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    Self.cacheNativeThemeSeed(from: rawAppearance)
    let next = ChatListAppearance.from(raw: rawAppearance)
    let visualChanged = appearance.visualKey != next.visualKey
    let hasPendingOrActiveSendTransition =
      pendingSendTransition != nil || activeSendTransition != nil
    if visualChanged && hasPendingOrActiveSendTransition {
      queuedAppearanceAfterSendTransition = next
      return
    }
    queuedAppearanceAfterSendTransition = nil
    applyResolvedAppearance(next)
  }

  func resolvedAppearance() -> ChatListAppearance {
    appearance
  }

  private func applyResolvedAppearance(_ next: ChatListAppearance) {
    let visualChanged = appearance.visualKey != next.visualKey
    appearance = next
    inputBar?.applyAppearance(next)
    if visualChanged {
      applyWallpaperAppearance()
      applyScrollToneTheme()
      updateScrollToneOverlay(offsetY: collectionView.contentOffset.y)
      applyActivityOverlayTheme()
      collectionView.reloadData()
    }
  }

  private func flushQueuedAppearanceAfterTransitionIfNeeded() {
    guard activeSendTransition == nil, pendingSendTransition == nil,
      let queued = queuedAppearanceAfterSendTransition
    else {
      return
    }
    queuedAppearanceAfterSendTransition = nil
    applyResolvedAppearance(queued)
  }

  private static func cacheNativeThemeSeed(from rawAppearance: [String: Any]) {
    guard let themeIdRaw = rawAppearance["nativeThemeId"] else { return }
    let themeId: String
    if let value = themeIdRaw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      themeId = trimmed
    } else {
      return
    }

    let isDark: Bool = {
      if let value = rawAppearance["nativeThemeIsDark"] as? Bool { return value }
      if let value = rawAppearance["nativeThemeIsDark"] as? NSNumber { return value.boolValue }
      if let value = rawAppearance["nativeThemeIsDark"] as? String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "true", "yes"].contains(normalized)
      }
      return true
    }()

    let defaults = UserDefaults.standard
    defaults.set(themeId, forKey: cachedThemeIdDefaultsKey)
    defaults.set(isDark, forKey: cachedThemeIsDarkDefaultsKey)
  }

  private static func bootstrapCachedAppearance() -> ChatListAppearance? {
    let defaults = UserDefaults.standard
    guard let themeId = defaults.string(forKey: cachedThemeIdDefaultsKey), !themeId.isEmpty else {
      return nil
    }
    let isDark = defaults.bool(forKey: cachedThemeIsDarkDefaultsKey)
    return ChatListAppearance.from(
      raw: [
        "backgroundMode": "transparent",
        "nativeThemeId": themeId,
        "nativeThemeIsDark": isDark,
      ])
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

  func setContentPaddingTop(_ value: Double) {
    let next = max(sectionTopInset, CGFloat(value))
    if abs(next - contentPaddingTop) <= 0.5 {
      return
    }
    contentPaddingTop = next
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

  func openPinnedDocument(urlString: String) {
    openDocumentInApp(urlString: urlString)
  }

  func startSendTransition(_ payload: [String: Any]) {
    guard let parsed = SendTransitionPayload(payload: payload, hostView: self) else {
      NSLog("[ChatListView] startSendTransition — failed to parse payload")
      return
    }
    let typeHint =
      ((payload["type"] as? String) ?? (payload["messageType"] as? String))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let hasMediaHint =
      payload["mediaUrl"] != nil
      || payload["media_url"] != nil
      || payload["uri"] != nil
      || payload["fileName"] != nil
      || payload["file_name"] != nil
    let trimmedText = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if typeHint != nil && typeHint != "text" || hasMediaHint || trimmedText.isEmpty {
      NSLog(
        "[ChatListView] startSendTransition — ignored non-text payload (messageId=%@, type=%@, hasMedia=%@, textLen=%lu)",
        parsed.messageId,
        typeHint ?? "nil",
        hasMediaHint ? "true" : "false",
        trimmedText.count
      )
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
    cell.resolveDisplayStatus = { [weak self] row in
      self?.resolvedDisplayStatus(for: row)
    }
    cell.configure(row: rows[indexPath.item], hiddenMessageId: hiddenMessageId)
    cell.onInlineAttachmentTap = { [weak self] row in
      guard let self else { return }
      guard let mediaURL = row.mediaUrl, !mediaURL.isEmpty else { return }
      self.openDocumentInApp(urlString: mediaURL)
    }
    cell.onMediaNaturalSizeResolved = { [weak self] messageId, mediaURL, size in
      self?.handleResolvedMediaSize(messageId: messageId, mediaURL: mediaURL, size: size)
    }
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
    _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
  ) {
    guard indexPath.item < rows.count else { return }
    let row = rows[indexPath.item]
    guard let mediaURLRaw = row.mediaUrl else { return }
    let mediaURL = mediaURLRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !mediaURL.isEmpty else { return }
    let hasFileNameHint =
      !(row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    let isFileLikeType = row.messageType == "file"
    let isVoiceVisual = row.visualKind == .voice
    let lowerMediaURL = mediaURL.lowercased()
    let isAgentDocURL =
      lowerMediaURL.contains("/uploads/agent-docs/")
      || lowerMediaURL.contains("/api/agent/document/")
    if isVoiceVisual {
      if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell {
        VoiceBubblePlaybackCoordinator.shared.toggle(
          cell: cell, messageId: row.messageId, mediaURL: mediaURL
        )
      }
      return
    }
    let isImageVisual = row.visualKind == .media && row.messageType != "file"
    if isImageVisual {
      let seedImage = (collectionView.cellForItem(at: indexPath) as? ChatListCell)?
        .currentMediaImage()
      presentImageEditView(for: row, mediaURL: mediaURL, seedImage: seedImage)
      return
    }
    let isMediaOrVideo =
      row.visualKind == .media || row.visualKind == .video || row.visualKind == .videoNote
    guard isFileLikeType || hasFileNameHint || isAgentDocURL || isMediaOrVideo else { return }
    openDocumentInApp(urlString: mediaURL)
  }

  @objc private func handleChatEngineChanged(_ note: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineChanged(note)
      }
      return
    }
    guard statusAuthorityEnabled else { return }
    let changedChatId = (note.userInfo?["chatId"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    if let changedChatId, !changedChatId.isEmpty, changedChatId != engineChatId {
      return
    }
    let reason = (note.userInfo?["reason"] as? String) ?? "engine"
    if reason == "peerTyping" {
      // Typing indicator is handled in header; do not show list-level typing UI.
      setPeerTyping(false)
      return
    }
    if reason == "chatMessageInserted"
      || reason == "chatMessageEdited"
      || reason == "chatMessageDeleted"
      || reason == "chatMessageChanged"
    {
      let messageId = normalizedMessageId(note.userInfo?["messageId"])
      let action = (note.userInfo?["action"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      syncNativeEngineMessageMutation(reason: reason, messageId: messageId, action: action)
      return
    }
    if reason == "messageStatusChanged" {
      let messageId = normalizedMessageId(note.userInfo?["messageId"])
      if messageId != nil {
        syncNativeEngineMessageMutation(
          reason: "chatMessageChanged",
          messageId: messageId,
          action: "updated"
        )
        return
      }
    }
    if reason == "chatRowsReloaded" {
      setRows(sourceRowsPayload)
      return
    }
    refreshVisibleStatuses(reason: reason)
  }

  private func updateChatEngineBinding() {
    guard !engineSurfaceId.isEmpty else { return }
    _ = ChatEngine.shared.bindSurface([
      "surfaceId": engineSurfaceId,
      "chatId": engineChatId,
      "myUserId": engineMyUserId,
      "peerUserId": enginePeerUserId,
    ])
  }

  private func updateChatEngineChannelBinding(forceDetach: Bool = false) {
    let desiredChatId: String?
    if forceDetach || window == nil {
      desiredChatId = nil
    } else {
      desiredChatId = engineChatId.isEmpty ? nil : engineChatId
    }

    if !engineOpenedChatId.isEmpty, engineOpenedChatId != desiredChatId {
      _ = ChatEngine.shared.closeChatChannel(["chatId": engineOpenedChatId])
      engineOpenedChatId = ""
    }

    if let desiredChatId, engineOpenedChatId != desiredChatId {
      _ = ChatEngine.shared.openChatChannel(["chatId": desiredChatId])
      engineOpenedChatId = desiredChatId
    }
  }

  private func resolvedDisplayStatus(for row: ChatListRow) -> String? {
    guard statusAuthorityEnabled else {
      return row.status?.lowercased()
    }
    return ChatEngine.shared.resolveDisplayStatus(
      chatId: engineChatId.isEmpty ? nil : engineChatId,
      messageId: row.messageId,
      rawStatus: row.status,
      isMe: row.isMe,
      peerUserId: enginePeerUserId.isEmpty ? nil : enginePeerUserId
    )
  }

  private func refreshVisibleStatuses(reason: String) {
    guard statusAuthorityEnabled else { return }
    guard window != nil else { return }
    guard !rows.isEmpty else { return }
    for case let cell as ChatListCell in collectionView.visibleCells {
      guard let indexPath = collectionView.indexPath(for: cell), indexPath.item < rows.count else {
        continue
      }
      cell.resolveDisplayStatus = { [weak self] row in
        self?.resolvedDisplayStatus(for: row)
      }
      cell.configure(row: rows[indexPath.item], hiddenMessageId: hiddenMessageId)
    }
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
    return CGSize(width: width, height: estimateMessageHeight(row, rowWidth: width))
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if customContextMenuOverlay != nil {
      dismissCustomContextMenu(animated: false)
    }
    let offsetY = scrollView.contentOffset.y
    _ = offsetY - previousOffsetY  // delta unused
    previousOffsetY = offsetY
    updateScrollToneOverlay(offsetY: offsetY)

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
      top: contentPaddingTop, left: messageHorizontalInset,
      bottom: contentPaddingBottom,
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
    return measureMessageBubbleLayout(row: row, rowWidth: rowWidth).bubbleHeight
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
    ChatReactionFxModule.shared.playLandingEffect(
      emoji: emoji,
      at: point,
      in: transitionOverlayHost,
      tintOverride: tintColor
    )
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

  private func rawRow(messageId targetMessageId: String, in payload: [[String: Any]])
    -> [String: Any]?
  {
    payload.first(where: { messageId(fromRawRow: $0) == targetMessageId })
  }

  private func rowByApplyingReactionEmoji(
    _ emoji: String,
    toMessageId targetMessageId: String,
    row: [String: Any]
  ) -> (row: [String: Any], changed: Bool) {
    guard messageId(fromRawRow: row) == targetMessageId else { return (row, false) }
    guard var message = row["message"] as? [String: Any] else { return (row, false) }
    let existing = (message["reactionEmoji"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    if existing == emoji {
      return (row, false)
    }
    message["reactionEmoji"] = emoji
    var patched = row
    patched["message"] = message
    return (patched, true)
  }

  func applyLocalReactionEmoji(_ emoji: String, toMessageId messageId: String) {
    let targetMessageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetMessageId.isEmpty, !trimmedEmoji.isEmpty else { return }
    reactionDebugTargetMessageId = targetMessageId
    reactionDebugTargetEmoji = trimmedEmoji
    reactionDebugRemainingRowsChecks = 12
    reactionDebugLog(
      "applyLocal start id=\(targetMessageId) emoji=\(trimmedEmoji) sourceCount=\(sourceRowsPayload.count) nativeOut=\(nativeOutgoingRowsById[targetMessageId] != nil ? "Y" : "N") nativeEngine=\(nativeEngineRowsById[targetMessageId] != nil ? "Y" : "N")"
    )

    var didPatch = false
    var sourcePatched = false
    var outgoingPatched = false
    var enginePatched = false
    var patchedSourceRow: [String: Any]?

    if !sourceRowsPayload.isEmpty {
      let patched = sourceRowsPayload.map { row -> [String: Any] in
        let result = rowByApplyingReactionEmoji(
          trimmedEmoji, toMessageId: targetMessageId, row: row)
        if result.changed {
          didPatch = true
          sourcePatched = true
          patchedSourceRow = result.row
        }
        return result.row
      }
      sourceRowsPayload = patched
    }

    if let row = nativeOutgoingRowsById[targetMessageId] {
      let result = rowByApplyingReactionEmoji(trimmedEmoji, toMessageId: targetMessageId, row: row)
      nativeOutgoingRowsById[targetMessageId] = result.row
      didPatch = didPatch || result.changed
      outgoingPatched = result.changed
    }

    if let row = nativeEngineRowsById[targetMessageId] {
      let result = rowByApplyingReactionEmoji(trimmedEmoji, toMessageId: targetMessageId, row: row)
      nativeEngineRowsById[targetMessageId] = result.row
      didPatch = didPatch || result.changed
      enginePatched = result.changed
    } else if let patchedRow = patchedSourceRow {
      // Store reaction overlay so it survives mergedRowsPayload when engine
      // rows replace sourceRowsPayload as the effective base.
      nativeEngineRowsById[targetMessageId] = patchedRow
      enginePatched = true
    }

    reactionDebugLog(
      "applyLocal patchResult id=\(targetMessageId) didPatch=\(didPatch ? "Y" : "N") source=\(sourcePatched ? "Y" : "N") outgoing=\(outgoingPatched ? "Y" : "N") engine=\(enginePatched ? "Y" : "N")"
    )
    guard didPatch else {
      reactionDebugLog("applyLocal skipped id=\(targetMessageId) no row changed")
      return
    }
    setRows(sourceRowsPayload)
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
        return max(listMinY + contentPaddingTop, barMinYInHost - metrics.bubbleHeight - 2.0)
      }
      let listVisibleBottom = listMinY + collectionView.bounds.height
      return max(
        listMinY + contentPaddingTop,
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
    let effectiveBaseRows: [[String: Any]] = {
      guard statusAuthorityEnabled, !engineChatId.isEmpty else { return baseRows }
      // Only use native engine rows as the primary source when native history
      // has actually been fetched from the server AND the native row count is
      // at least as large as what JS provides. If decryption failed for most
      // messages the native set will be tiny — never replace a larger JS set
      // with a smaller native set or messages will visually disappear.
      let historyReady = ChatEngine.shared.isChatHistoryLoaded(chatId: engineChatId)
      if historyReady {
        let nativeRows = ChatEngine.shared.getChatRows(["chatId": engineChatId])
        if !nativeRows.isEmpty, nativeRows.count >= baseRows.count || baseRows.isEmpty {
          return nativeRows
        }
      }
      return baseRows
    }()

    var engineMergedRows = effectiveBaseRows
    if !nativeEngineRowsById.isEmpty || !nativeDeletedMessageIds.isEmpty {
      var filteredBase: [[String: Any]] = []
      filteredBase.reserveCapacity(effectiveBaseRows.count)
      var baseMessageIds = Set<String>()

      for row in effectiveBaseRows {
        if let messageId = messageId(fromRawRow: row) {
          if nativeDeletedMessageIds.contains(messageId) {
            continue
          }
          baseMessageIds.insert(messageId)
        }
        filteredBase.append(row)
      }

      nativeDeletedMessageIds = nativeDeletedMessageIds.filter { deletedId in
        baseMessageIds.contains(deletedId) || nativeEngineRowsById[deletedId] != nil
      }.reduce(into: Set<String>()) { $0.insert($1) }

      var mergedRows: [[String: Any]] = []
      mergedRows.reserveCapacity(filteredBase.count + nativeEngineRowsById.count)
      for row in filteredBase {
        if let messageId = messageId(fromRawRow: row),
          let overlay = nativeEngineRowsById[messageId]
        {
          mergedRows.append(mergeMessageRowPreservingShape(baseRow: row, overlayRow: overlay))
        } else {
          mergedRows.append(row)
        }
      }

      var nextEngineOrder: [String] = []
      nextEngineOrder.reserveCapacity(nativeEngineOrder.count)
      for messageId in nativeEngineOrder {
        guard let overlay = nativeEngineRowsById[messageId] else { continue }
        if baseMessageIds.contains(messageId) {
          nextEngineOrder.append(messageId)
          continue
        }
        mergedRows.append(overlay)
        nextEngineOrder.append(messageId)
      }
      nativeEngineOrder = nextEngineOrder
      engineMergedRows = mergedRows
    }

    guard nativeSendEnabled, !nativeOutgoingOrder.isEmpty else {
      return engineMergedRows
    }

    var baseMessageIds = Set<String>()
    for row in engineMergedRows {
      if let messageId = messageId(fromRawRow: row) {
        baseMessageIds.insert(messageId)
      }
    }

    var effectiveBaseIds = Set<String>()
    for row in effectiveBaseRows {
      if let messageId = messageId(fromRawRow: row) {
        effectiveBaseIds.insert(messageId)
      }
    }

    // Pre-clean: remove native outgoing copies whose server-confirmed version
    // is already present in the base rows. Do this BEFORE building the merged
    // array so the diff algorithm never sees the same key jump positions
    // (which would trigger a full reloadData and cause cells to flash).
    var nextOrder: [String] = []
    for messageId in nativeOutgoingOrder {
      if nativeOutgoingRowsById[messageId] == nil {
        continue
      }
      if effectiveBaseIds.contains(messageId) {
        nativeOutgoingRowsById.removeValue(forKey: messageId)
        continue
      }
      nextOrder.append(messageId)
    }
    nativeOutgoingOrder = nextOrder

    guard !nativeOutgoingOrder.isEmpty else {
      return engineMergedRows
    }

    var merged = engineMergedRows
    for messageId in nativeOutgoingOrder {
      if baseMessageIds.contains(messageId) {
        continue
      }
      guard let row = nativeOutgoingRowsById[messageId] else {
        continue
      }
      merged.append(row)
    }
    return merged
  }

  private func mergeMessageRowPreservingShape(baseRow: [String: Any], overlayRow: [String: Any])
    -> [String: Any]
  {
    guard
      let baseMessage = baseRow["message"] as? [String: Any],
      let overlayMessage = overlayRow["message"] as? [String: Any]
    else {
      return overlayRow
    }

    var mergedMessage = baseMessage
    for (key, value) in overlayMessage {
      mergedMessage[key] = value
    }
    if let baseBubbleShape = baseMessage["bubbleShape"] {
      mergedMessage["bubbleShape"] = baseBubbleShape
    }
    if let targetMessageId = reactionDebugTargetMessageId,
      let baseId = normalizedMessageId(baseMessage["id"]),
      baseId == targetMessageId
    {
      let baseReaction = (baseMessage["reactionEmoji"] as? String) ?? "nil"
      let overlayReaction = (overlayMessage["reactionEmoji"] as? String) ?? "nil"
      let mergedReaction = (mergedMessage["reactionEmoji"] as? String) ?? "nil"
      reactionDebugLog(
        "mergeRow id=\(targetMessageId) baseReaction=\(baseReaction) overlayReaction=\(overlayReaction) mergedReaction=\(mergedReaction)"
      )
    }

    var mergedRow = baseRow
    for (key, value) in overlayRow {
      mergedRow[key] = value
    }
    mergedRow["message"] = mergedMessage
    return mergedRow
  }

  private func syncNativeEngineMessageMutation(reason: String, messageId: String?, action: String?)
  {
    let resolvedMessageId = messageId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resolvedChatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedChatId.isEmpty, !resolvedMessageId.isEmpty else { return }

    let normalizedAction = action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let isDeleteReason = reason == "chatMessageDeleted" || normalizedAction == "deleted"

    if isDeleteReason {
      nativeEngineRowsById.removeValue(forKey: resolvedMessageId)
      nativeDeletedMessageIds.insert(resolvedMessageId)
    } else if reason == "chatMessageInserted" || reason == "chatMessageEdited"
      || reason == "chatMessageChanged"
    {
      if let row = ChatEngine.shared.getLiveMessageRow([
        "chatId": resolvedChatId,
        "messageId": resolvedMessageId,
      ]) {
        nativeEngineRowsById[resolvedMessageId] = row
        nativeDeletedMessageIds.remove(resolvedMessageId)
        if !nativeEngineOrder.contains(resolvedMessageId) {
          nativeEngineOrder.append(resolvedMessageId)
        }
      } else if ChatEngine.shared.isLiveMessageDeleted([
        "chatId": resolvedChatId,
        "messageId": resolvedMessageId,
      ]) {
        nativeEngineRowsById.removeValue(forKey: resolvedMessageId)
        nativeDeletedMessageIds.insert(resolvedMessageId)
      }
    }

    let isAgent: Bool = {
      if let row = nativeEngineRowsById[resolvedMessageId],
        let msg = row["message"] as? [String: Any]
      {
        return (msg["isAgentMessage"] as? Bool) == true
      }
      return false
    }()
    NSLog(
      "[ChatListEngine] syncMutation reason:%@ msgId:%@ action:%@ isAgent:%@ engineRows:%d engineOrder:%d",
      reason, String(resolvedMessageId.prefix(12)), normalizedAction ?? "nil",
      isAgent ? "Y" : "N", nativeEngineRowsById.count, nativeEngineOrder.count)
    setRows(sourceRowsPayload)
  }

  private func queueNativeOutgoingMessage(
    messageId: String,
    text: String,
    timestamp: String,
    timestampMs: Double,
    replyToId: String? = nil,
    autoMarkSent: Bool = true
  ) {
    let isPreviousMe: Bool = {
      if let lastMessageRow = rows.last(where: { $0.kind == .message }) {
        return lastMessageRow.isMe
      }
      return false
    }()

    let borderTopRightRadius: CGFloat = isPreviousMe ? 5 : 18

    var message: [String: Any] = [
      "id": messageId,
      "text": text,
      "timestamp": timestamp,
      "timestampMs": timestampMs,
      "isMe": true,
      "status": "pending",
      "type": "text",
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": borderTopRightRadius,
        "borderBottomRightRadius": 18,
        "borderBottomLeftRadius": 18,
      ],
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

    guard autoMarkSent else { return }
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

  private func setNativeOutgoingMessageStatus(_ messageId: String, status: String) {
    guard var row = nativeOutgoingRowsById[messageId],
      var message = row["message"] as? [String: Any]
    else {
      return
    }
    message["status"] = status
    row["message"] = message
    nativeOutgoingRowsById[messageId] = row
    setRows(sourceRowsPayload)
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
    DispatchQueue.main.asyncAfter(
      deadline: .now() + TelegramSendMorphProfile.duration + 0.22
    ) { [weak self, weak state] in
      guard let self, let state else { return }
      guard self.activeSendTransition === state else { return }
      NSLog(
        "[ChatListView] sendTransition watchdog — forcing completion for messageId=%@",
        state.payload.messageId
      )
      self.completeTransition(state)
    }
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

    // Smoothly fade out the overlay instead of dropping it instantly
    // The real cell becomes visible instantly behind it, creating a perfect crossfade.
    let overlay = transition.overlayContainer
    UIView.animate(
      withDuration: 0.15, delay: 0, options: [.curveEaseOut],
      animations: {
        overlay.alpha = 0.0
      }
    ) { _ in
      overlay.removeFromSuperview()
    }

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
      setRows(sourceRowsPayload)
    }
    flushQueuedAppearanceAfterTransitionIfNeeded()
    onNativeEvent(["type": "sendTransitionCompleted", "messageId": revealedMessageId ?? ""])
  }

  private func emitViewport(force: Bool = false) {
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
    wallpaperLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    wallpaperLayer.opacity = Float(max(0.0, min(1.0, appearance.wallpaperOpacity)))
    wallpaperLayer.isHidden = appearance.backgroundMode == "transparent"

    let canShowPattern =
      appearance.backgroundMode != "transparent"
      && appearance.wallpaperPatternGradient.count >= 2
      && appearance.wallpaperPatternOpacity > 0.001
      && (appearance.wallpaperMaskKey?.isEmpty == false)

    guard
      canShowPattern,
      let maskKey = appearance.wallpaperMaskKey,
      let maskImage = resolvedWallpaperMaskImage(for: maskKey)
    else {
      wallpaperPatternLayer.isHidden = true
      wallpaperPatternLayer.colors = nil
      wallpaperPatternLayer.locations = nil
      wallpaperPatternLayer.opacity = 0.0
      wallpaperPatternMaskLayer.contents = nil
      return
    }

    wallpaperPatternLayer.colors = appearance.wallpaperPatternGradient.map(\.cgColor)
    wallpaperPatternLayer.locations = appearance.wallpaperPatternLocations
    wallpaperPatternLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    wallpaperPatternLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    wallpaperPatternLayer.opacity = Float(max(0.0, min(1.0, appearance.wallpaperPatternOpacity)))
    wallpaperPatternMaskLayer.contents = maskImage
    wallpaperPatternMaskLayer.frame = wallpaperPatternLayer.bounds
    wallpaperPatternLayer.isHidden = false
  }

  private func applyScrollToneTheme() {
    let isDark = appearance.isDark
    let topBase = appearance.wallpaperGradient.first ?? (isDark ? UIColor.black : UIColor.white)
    let bottomBase = appearance.wallpaperGradient.last ?? topBase
    let topTint = blendedScrollToneBase(color: topBase, isDark: isDark)
    let bottomTint = blendedScrollToneBase(color: bottomBase, isDark: isDark)

    scrollToneTopLayer.colors = [
      topTint.withAlphaComponent(isDark ? 0.20 : 0.14).cgColor,
      UIColor.clear.cgColor,
    ]
    scrollToneTopLayer.locations = [0.0, 1.0]
    scrollToneTopLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    scrollToneTopLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

    scrollToneBottomLayer.colors = [
      UIColor.clear.cgColor,
      bottomTint.withAlphaComponent(isDark ? 0.12 : 0.08).cgColor,
    ]
    scrollToneBottomLayer.locations = [0.0, 1.0]
    scrollToneBottomLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    scrollToneBottomLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
  }

  private func updateScrollToneOverlay(offsetY: CGFloat) {
    guard bounds.width > 0.0, bounds.height > 0.0 else { return }

    let topHeight = min(bounds.height * 0.34, 250.0)
    let bottomHeight = min(bounds.height * 0.24, 180.0)
    scrollToneTopLayer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: topHeight)
    scrollToneBottomLayer.frame = CGRect(
      x: 0.0, y: bounds.height - bottomHeight, width: bounds.width, height: bottomHeight)

    let normalized = max(0.0, min(1.0, offsetY / 220.0))
    let isDark = appearance.isDark
    let topBaseOpacity: Float = isDark ? 0.34 : 0.26
    let bottomBaseOpacity: Float = isDark ? 0.30 : 0.20
    scrollToneTopLayer.opacity = min(0.62, topBaseOpacity + (Float(normalized) * 0.22))
    scrollToneBottomLayer.opacity = min(0.48, bottomBaseOpacity + (Float(normalized) * 0.15))

    let drift = max(-32.0, min(48.0, offsetY * 0.12))
    scrollToneTopLayer.transform = CATransform3DMakeTranslation(0.0, -drift, 0.0)
    scrollToneBottomLayer.transform = CATransform3DMakeTranslation(0.0, drift * 0.45, 0.0)
  }

  private func blendedScrollToneBase(color: UIColor, isDark: Bool) -> UIColor {
    let target = isDark ? UIColor.black : UIColor.white
    var cr: CGFloat = 0.0
    var cg: CGFloat = 0.0
    var cb: CGFloat = 0.0
    var ca: CGFloat = 0.0
    var tr: CGFloat = 0.0
    var tg: CGFloat = 0.0
    var tb: CGFloat = 0.0
    var ta: CGFloat = 0.0
    guard color.getRed(&cr, green: &cg, blue: &cb, alpha: &ca),
      target.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
    else {
      return color
    }
    let mix: CGFloat = isDark ? 0.35 : 0.24
    let inv = 1.0 - mix
    return UIColor(
      red: (cr * inv) + (tr * mix),
      green: (cg * inv) + (tg * mix),
      blue: (cb * inv) + (tb * mix),
      alpha: 1.0
    )
  }

  private func resolvedWallpaperMaskImage(for key: String) -> CGImage? {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedKey.isEmpty else { return nil }
    if let cached = Self.wallpaperMaskImageCache[normalizedKey] {
      return cached
    }
    guard let baseName = Self.wallpaperMaskBaseName(for: normalizedKey) else {
      return nil
    }

    let bundles = [Bundle.main, Bundle(for: ChatListView.self)]
    for bundle in bundles {
      if let image = UIImage(named: baseName, in: bundle, compatibleWith: nil)?.cgImage {
        Self.wallpaperMaskImageCache[normalizedKey] = image
        return image
      }
      if let image = UIImage(named: "\(baseName).png", in: bundle, compatibleWith: nil)?.cgImage {
        Self.wallpaperMaskImageCache[normalizedKey] = image
        return image
      }
      if let path = bundle.path(forResource: baseName, ofType: "png"),
        let image = UIImage(contentsOfFile: path)?.cgImage
      {
        Self.wallpaperMaskImageCache[normalizedKey] = image
        return image
      }
    }
    return nil
  }

  private static func wallpaperMaskBaseName(for key: String) -> String? {
    switch key {
    case "doodles", "hearts":
      return "doodle_transparent"
    case "music":
      return "music_transparent"
    case "music2":
      return "music2_transparent"
    case "food":
      return "food_transparent"
    case "animals":
      return "animals_transparent"
    default:
      return nil
    }
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
    inputBar?.keyboardHeightForPanels = 0
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

    // The composer can reserve either the native keyboard area or a custom
    // bottom accessory surface like the GIF panel overlay.
    let effectiveKeyboardHeight = max(keyboardHeight, bar.presentedBottomAccessoryHeight)

    // If keyboard is effectively visible, safe area is handled by keyboard height.
    // Otherwise, account for bottom safe area in the bar layout.
    let safeBottom: CGFloat
    if effectiveKeyboardHeight > 0 {
      safeBottom = 0
    } else {
      safeBottom = safeAreaInsets.bottom
    }
    bar.bottomSafeAreaInset = safeBottom

    // Size the bar by updating its width (avoiding y-origin jumps during UIView animations)
    bar.frame = CGRect(x: 0, y: bar.frame.minY, width: w, height: bar.frame.height)
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
    layoutActivityOverlay()
  }

  // MARK: - Native Send (synchronous, no bridge delay)

  private func handleNativeSend(text: String, agentMention: Bool = false, agentText: String? = nil)
  {
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
      queueNativeOutgoingMessage(
        messageId: messageId,
        text: text,
        timestamp: timestamp,
        timestampMs: timestampMs,
        replyToId: replyToMessageId,
        autoMarkSent: false
      )
      let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      let myUserId = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
      let peerUserId = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
      if chatId.isEmpty {
        NSLog(
          "[ChatListView] native ChatEngine send blocked: empty chatId (messageId=%@, myUserId=%@, peerUserId=%@)",
          messageId,
          myUserId,
          peerUserId
        )
        setNativeOutgoingMessageStatus(messageId, status: "error")
        return
      }
      var sendPayload: [String: Any] = [
        "chatId": chatId,
        "messageId": messageId,
        "type": "text",
        "text": text,
        "timestampMs": timestampMs,
        "replyToId": replyToMessageId as Any,
        "myUserId": myUserId,
        "peerUserId": peerUserId,
        "isGroup": isGroupOrChannel,
      ]
      if agentMention, let agentText {
        sendPayload["agentMention"] = true
        sendPayload["agentText"] = agentText
      }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let result = ChatEngine.shared.sendMessage(sendPayload)
        let accepted = (result["accepted"] as? Bool) == true
        let queued = (result["queued"] as? Bool) == true
        if !accepted {
          let statusSnapshot = ChatEngine.shared.getStatus()
          let journalTail = Array(ChatEngine.shared.getJournal().suffix(6))
          NSLog(
            "[ChatListView] native ChatEngine sendMessage rejected: %@ status=%@ journalTail=%@",
            String(describing: result),
            String(describing: statusSnapshot),
            String(describing: journalTail)
          )
          DispatchQueue.main.async {
            self?.setNativeOutgoingMessageStatus(messageId, status: "error")
          }
          return
        }

        if queued {
          let statusSnapshot = ChatEngine.shared.getStatus()
          let journalTail = Array(ChatEngine.shared.getJournal().suffix(6))
          let reason = (result["reason"] as? String) ?? "unknown"
          NSLog(
            "[ChatListView] native ChatEngine sendMessage queued: reason=%@ result=%@ status=%@ journalTail=%@",
            reason,
            String(describing: result),
            String(describing: statusSnapshot),
            String(describing: journalTail)
          )
        }

        // Determine the status to show on the bubble.
        let resolvedStatus: String = {
          if let stateValue = result["state"] as? String {
            let normalized = stateValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "error" || normalized == "pending" || normalized == "sent"
              || normalized == "delivered" || normalized == "read"
            {
              return normalized
            }
          }
          // If the engine accepted and didn't return an explicit state, mark sent.
          return accepted ? "sent" : "error"
        }()
        DispatchQueue.main.async {
          self?.setNativeOutgoingMessageStatus(messageId, status: resolvedStatus)
        }
      }
    } else {
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
      if agentMention, let agentText {
        sendPayload["agentMention"] = true
        sendPayload["agentText"] = agentText
      }
      onNativeEvent(sendPayload)
    }
  }

  private func topPresentingViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let current = responder {
      if let vc = current as? UIViewController {
        var top = vc
        while let presented = top.presentedViewController {
          top = presented
        }
        return top
      }
      responder = current.next
    }
    return window?.rootViewController
  }

  private func handleResolvedMediaSize(messageId: String?, mediaURL: String, size: CGSize) {
    guard size.width > 1.0, size.height > 1.0 else { return }
    let hasMatchingRow = rows.contains { row in
      if let messageId, let rowMessageId = row.messageId, rowMessageId == messageId {
        return true
      }
      return row.mediaUrl == mediaURL
    }
    guard hasMatchingRow else { return }

    flowLayout.invalidateLayout()
    collectionView.performBatchUpdates(nil)
  }

  private func resolvedImageEditorHeaderTitle() -> String {
    let peerUserId = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let myUserId = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    if peerUserId.isEmpty || (!myUserId.isEmpty && peerUserId.caseInsensitiveCompare(myUserId) == .orderedSame) {
      return "Saved Messages"
    }
    return peerUserId
  }

  private func presentImageEditView(for row: ChatListRow, mediaURL: String, seedImage: UIImage?) {
    guard let presenter = topPresentingViewController() else { return }
    ChatImageEditModule.presentEditor(
      from: presenter,
      messageId: row.messageId,
      mediaURL: mediaURL,
      initialImage: seedImage,
      initialCaption: row.text,
      headerTitle: resolvedImageEditorHeaderTitle()
    ) { [weak self] payload in
      guard let self else { return }
      var event: [String: Any] = [
        "type": payload.eventType.rawValue,
        "mediaUrl": payload.mediaURL,
      ]
      if let messageId = payload.messageId {
        event["messageId"] = messageId
      }
      if let caption = payload.caption, !caption.isEmpty {
        event["caption"] = caption
      }
      if let editedImageURL = payload.editedImageURL {
        event["editedImageUri"] = editedImageURL.absoluteString
      }
      self.onNativeEvent(event)

      if payload.eventType == .reply, let inputBar = self.inputBar, let messageId = row.messageId {
        let preview = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        inputBar.showReplyBanner(
          messageId: messageId,
          text: preview.isEmpty ? "Photo" : preview,
          isMe: row.isMe
        )
      }
    }
  }

  private func openDocumentInApp(urlString: String) {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let resolved = ChatEngine.shared.resolveURLForOpen(trimmed) ?? trimmed
    if let remoteURL = URL(string: resolved), let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      openRemoteDocumentInPreview(remoteURL: remoteURL, fallbackURL: resolved)
      return
    }

    let resolvedLocalURL: URL? = {
      if let parsed = URL(string: resolved), parsed.isFileURL {
        return parsed
      }
      if resolved.hasPrefix("/") {
        return URL(fileURLWithPath: resolved)
      }
      if let decoded = resolved.removingPercentEncoding, decoded.hasPrefix("/") {
        return URL(fileURLWithPath: decoded)
      }
      return nil
    }()

    if let localURL = resolvedLocalURL {
      presentDocumentPreview(localURL: localURL)
      return
    }

    NSLog("[ChatListView] openDocumentInApp unsupported url=%@", resolved)
  }

  private func presentDocumentPreview(localURL: URL) {
    guard let presenter = topPresentingViewController() else {
      NSLog(
        "[ChatListView] presentDocumentPreview skipped - presenter unavailable for %@",
        localURL.path)
      return
    }

    if presentPlainTextDocumentPreviewIfSupported(localURL: localURL, presenter: presenter) {
      return
    }

    let preview = QLPreviewController()
    let dataSource = ChatListDocumentPreviewDataSource(previewURL: localURL)
    documentPreviewDataSource = dataSource
    preview.dataSource = dataSource
    presenter.present(preview, animated: true)
  }

  private func openRemoteDocumentInPreview(remoteURL: URL, fallbackURL: String) {
    guard topPresentingViewController() != nil else {
      NSLog(
        "[ChatListView] openRemoteDocumentInPreview skipped - presenter unavailable for %@",
        fallbackURL)
      return
    }

    let remoteKey = remoteURL.absoluteString
    if let cachedURL = documentPreviewCacheByRemoteURL[remoteKey],
      FileManager.default.fileExists(atPath: cachedURL.path)
    {
      presentDocumentPreview(localURL: cachedURL)
      return
    }

    guard !documentPreviewInFlightURLs.contains(remoteKey) else { return }
    documentPreviewInFlightURLs.insert(remoteKey)

    var request = URLRequest(url: remoteURL)
    request.timeoutInterval = 60
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
      request.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }
    let task = Self.documentPreviewSession.downloadTask(with: request) {
      [weak self] tempURL, response, error in
      guard let self else { return }
      let localURL = self.persistDownloadedDocument(
        tempURL: tempURL,
        remoteURL: remoteURL,
        response: response,
        error: error
      )
      DispatchQueue.main.async {
        self.documentPreviewInFlightURLs.remove(remoteKey)
        if let localURL {
          self.documentPreviewCacheByRemoteURL[remoteKey] = localURL
          self.presentDocumentPreview(localURL: localURL)
          return
        }
        NSLog("[ChatListView] openRemoteDocumentInPreview failed url=%@", fallbackURL)
      }
    }
    task.resume()
  }

  private func persistDownloadedDocument(
    tempURL: URL?,
    remoteURL: URL,
    response: URLResponse?,
    error: Error?
  ) -> URL? {
    guard error == nil, let tempURL else { return nil }
    if let statusCode = (response as? HTTPURLResponse)?.statusCode,
      !(200...299).contains(statusCode)
    {
      return nil
    }

    let fileManager = FileManager.default
    let previewDir = fileManager.temporaryDirectory
      .appendingPathComponent("vibe-chat-preview-docs", isDirectory: true)
    do {
      try fileManager.createDirectory(at: previewDir, withIntermediateDirectories: true)
    } catch {
      return nil
    }

    let preferredName = preferredDownloadFileName(remoteURL: remoteURL, response: response)
    let preferredExtension = preferredDownloadFileExtension(
      remoteURL: remoteURL,
      response: response,
      fallbackName: preferredName,
      tempURL: tempURL
    )

    let fileBaseName =
      preferredName
      .replacingOccurrences(of: "\\.[A-Za-z0-9]{1,12}$", with: "", options: .regularExpression)

    let safeBase =
      (fileBaseName.isEmpty ? "document" : fileBaseName)
      .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    let extensionValue = preferredExtension
    let destinationName =
      "\(safeBase)-\(UUID().uuidString)\(extensionValue.isEmpty ? "" : ".\(extensionValue)")"
    let destinationURL = previewDir.appendingPathComponent(destinationName, isDirectory: false)

    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
      }
      try fileManager.moveItem(at: tempURL, to: destinationURL)
      return destinationURL
    } catch {
      do {
        try fileManager.copyItem(at: tempURL, to: destinationURL)
        return destinationURL
      } catch {
        return nil
      }
    }
  }

  private func presentPlainTextDocumentPreviewIfSupported(
    localURL: URL,
    presenter: UIViewController
  ) -> Bool {
    let ext = localURL.pathExtension.lowercased()
    // Spreadsheet/PDF files should use native Quick Look so users get table/page previews.
    let quickLookPreferredExtensions: Set<String> = ["csv", "tsv", "xls", "xlsx", "pdf"]
    if quickLookPreferredExtensions.contains(ext) { return false }

    let textLikeExtensions: Set<String> = ["txt", "md", "markdown", "json", "log"]
    guard textLikeExtensions.contains(ext) else { return false }

    guard
      let data = try? Data(contentsOf: localURL),
      data.count <= 5_000_000
    else {
      return false
    }

    let decodedText =
      String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? String(data: data, encoding: .unicode)
      ?? String(data: data, encoding: .ascii)
    guard let text = decodedText else { return false }

    let title = localURL.lastPathComponent.isEmpty ? "Document" : localURL.lastPathComponent
    let controller = ChatListTextPreviewController(title: title, text: text)
    let nav = UINavigationController(rootViewController: controller)
    controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(dismissPresentedPreview)
    )
    presenter.present(nav, animated: true)
    return true
  }

  @objc private func dismissPresentedPreview() {
    topPresentingViewController()?.dismiss(animated: true)
  }

  private func preferredDownloadFileName(remoteURL: URL, response: URLResponse?) -> String {
    if let http = response as? HTTPURLResponse,
      let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
      let fromHeader = parseFileNameFromContentDisposition(disposition)
    {
      return fromHeader
    }

    if let suggested = response?.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
      !suggested.isEmpty
    {
      return suggested
    }

    let urlName = remoteURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if !urlName.isEmpty, urlName != remoteURL.host {
      return urlName
    }

    return "document"
  }

  private func preferredDownloadFileExtension(
    remoteURL: URL,
    response: URLResponse?,
    fallbackName: String,
    tempURL: URL
  ) -> String {
    let nameExtension = (fallbackName as NSString).pathExtension.lowercased()
    if !nameExtension.isEmpty { return nameExtension }

    let remoteExtension = remoteURL.pathExtension.lowercased()
    if !remoteExtension.isEmpty { return remoteExtension }

    if let mime = response?.mimeType?.lowercased() {
      switch mime {
      case "text/csv":
        return "csv"
      case "application/pdf":
        return "pdf"
      case "application/vnd.ms-excel":
        return "xls"
      case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
        return "xlsx"
      case "application/msword":
        return "doc"
      case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
        return "docx"
      case "application/vnd.ms-powerpoint":
        return "ppt"
      case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
        return "pptx"
      case "application/json":
        return "json"
      case "text/plain":
        return "txt"
      case "text/markdown":
        return "md"
      case "text/html":
        return "html"
      default:
        break
      }
    }

    return tempURL.pathExtension.lowercased()
  }

  private func parseFileNameFromContentDisposition(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let range = trimmed.range(of: "filename*=", options: .caseInsensitive) {
      let encodedPart = String(trimmed[range.upperBound...])
        .components(separatedBy: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let encodedPart, let decoded = decodeRFC5987FileName(encodedPart), !decoded.isEmpty {
        return decoded
      }
    }

    if let range = trimmed.range(of: "filename=", options: .caseInsensitive) {
      let raw = String(trimmed[range.upperBound...])
        .components(separatedBy: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let cleaned = raw?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) ?? ""
      if !cleaned.isEmpty { return cleaned }
    }
    return nil
  }

  private func decodeRFC5987FileName(_ raw: String) -> String? {
    let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    let parts = cleaned.components(separatedBy: "'")
    if parts.count >= 3 {
      let encodedName = parts[2]
      return encodedName.removingPercentEncoding ?? encodedName
    }
    return cleaned.removingPercentEncoding
  }
}

// MARK: - ChatInputBarDelegate

extension ChatListView: ChatInputBarDelegate {
  func inputBarDidSend(text: String) {
    handleNativeSend(text: text)
  }

  func inputBarDidSendWithAgentMention(text: String, agentText: String) {
    handleNativeSend(text: text, agentMention: true, agentText: agentText)
  }

  func inputBarDidTapAttachment() {
    onNativeEvent(["type": "attachmentPressed"])
  }

  func inputBarDidTapAction() {
    onNativeEvent(["type": "inputActionPressed", "action": "mic"])
  }

  func inputBarTextDidChange(text: String) {
    if nativeSendEnabled {
      let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !chatId.isEmpty {
        let isTyping = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        DispatchQueue.global(qos: .utility).async {
          _ = ChatEngine.shared.sendTypingState([
            "chatId": chatId,
            "typing": isTyping,
          ])
        }
      }
    }
    onNativeEvent(["type": "textChanged", "text": text])
  }

  func inputBarHeightDidChange() {
    setNeedsLayout()
  }

  func inputBarRecordingStateDidChange(isRecording: Bool, isLocked: Bool, mode: String) {
    if nativeSendEnabled {
      let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !chatId.isEmpty {
        DispatchQueue.global(qos: .utility).async {
          _ = ChatEngine.shared.sendRecordingState([
            "chatId": chatId,
            "isRecording": isRecording,
            "isLocked": isLocked,
            "mode": mode,
          ])
        }
      }
    }
    onNativeEvent([
      "type": "recordingState",
      "isRecording": isRecording,
      "isLocked": isLocked,
      "mode": mode,
    ])
  }

  func inputBarRecordingDidCancel() {
    if nativeSendEnabled {
      let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !chatId.isEmpty {
        DispatchQueue.global(qos: .utility).async {
          _ = ChatEngine.shared.sendRecordingState([
            "chatId": chatId,
            "isRecording": false,
            "isLocked": false,
            "mode": "voice",
          ])
        }
      }
    }
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

  func inputBarDidSelectImage(uri: String, caption: String?) {
    var payload: [String: Any] = ["type": "attachmentImage", "uri": uri]
    if let caption = caption, !caption.isEmpty {
      payload["caption"] = caption
    }
    onNativeEvent(payload)
  }

  func inputBarDidSelectGif(
    id: String,
    url: String,
    previewUrl: String,
    width: Int,
    height: Int
  ) {
    // Prefetch the GIF into the media cache so it displays instantly
    // when the optimistic row appears.
    chatMediaPrefetch(urlString: url, animated: true)
    if previewUrl != url {
      chatMediaPrefetch(urlString: previewUrl, animated: true)
    }
    onNativeEvent([
      "type": "attachmentGif",
      "id": id,
      "url": url,
      "previewUrl": previewUrl,
      "width": width,
      "height": height,
    ])
  }

  func inputBarDidSelectSticker(
    stickerId: String,
    packId: String,
    bundleFileName: String?,
    emoji: String?,
    width: Int,
    height: Int
  ) {
    var payload: [String: Any] = [
      "type": "attachmentSticker",
      "stickerId": stickerId,
      "packId": packId,
      "width": width,
      "height": height,
    ]
    if let bundleFileName { payload["bundleFileName"] = bundleFileName }
    if let emoji { payload["emoji"] = emoji }
    onNativeEvent(payload)
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

  // MARK: - Activity Overlay (Typing / Agent Progress)

  private func setupActivityOverlay() {
    activityOverlay.isUserInteractionEnabled = false
    activityOverlay.alpha = 0
    activityOverlay.clipsToBounds = true

    // Dot container holds the three animated dots
    activityDotContainer.isUserInteractionEnabled = false
    let dotSize: CGFloat = 5
    let dotSpacing: CGFloat = 4
    for (i, dot) in activityDots.enumerated() {
      dot.frame = CGRect(
        x: CGFloat(i) * (dotSize + dotSpacing), y: 0,
        width: dotSize, height: dotSize)
      dot.layer.cornerRadius = dotSize / 2
      activityDotContainer.addSubview(dot)
    }
    let dotsW = CGFloat(activityDots.count) * dotSize + CGFloat(activityDots.count - 1) * dotSpacing
    activityDotContainer.frame = CGRect(x: 10, y: 0, width: dotsW, height: dotSize)
    activityOverlay.addSubview(activityDotContainer)

    activityTextLabel.font = .systemFont(ofSize: 13, weight: .medium)
    activityTextLabel.numberOfLines = 1
    activityTextLabel.lineBreakMode = .byTruncatingTail
    activityOverlay.addSubview(activityTextLabel)

    insertSubview(activityOverlay, belowSubview: transitionOverlayHost)
  }

  private func applyActivityOverlayTheme() {
    let isDark = appearance.isDark
    activityOverlay.backgroundColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.08)
      : UIColor(white: 0.0, alpha: 0.05)
    activityOverlay.layer.cornerRadius = 14
    let dotColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.5)
      : UIColor(white: 0.0, alpha: 0.35)
    for dot in activityDots {
      dot.backgroundColor = dotColor
    }
    activityTextLabel.textColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.65)
      : UIColor(white: 0.0, alpha: 0.5)
  }

  private func layoutActivityOverlay() {
    guard activityOverlay.alpha > 0 || isPeerTyping else { return }

    let overlayH: CGFloat = 28
    let overlayMaxW = min(bounds.width - 32, 260)
    let dotSize: CGFloat = 5
    let dotSpacing: CGFloat = 4
    let dotsW = CGFloat(activityDots.count) * dotSize + CGFloat(activityDots.count - 1) * dotSpacing
    let labelX: CGFloat = 10 + dotsW + 6
    let text = activityTextLabel.text ?? ""
    let textSize = (text as NSString).size(withAttributes: [.font: activityTextLabel.font!])
    let labelW = min(ceil(textSize.width), overlayMaxW - labelX - 10)
    let overlayW = labelX + labelW + 10

    // Position dots vertically centered
    activityDotContainer.frame = CGRect(
      x: 10, y: (overlayH - dotSize) / 2, width: dotsW, height: dotSize)
    activityTextLabel.frame = CGRect(
      x: labelX, y: 0, width: labelW, height: overlayH)

    // Position overlay just above the content padding (input bar area)
    let bottomY: CGFloat
    if inputBarEnabled, let bar = inputBar {
      bottomY = bar.frame.minY - 6
    } else {
      bottomY = bounds.height - contentPaddingBottom - 6
    }
    let overlayX: CGFloat = messageHorizontalInset
    activityOverlay.frame = CGRect(
      x: overlayX, y: bottomY - overlayH,
      width: overlayW, height: overlayH)
  }

  private func showActivityOverlay(text: String) {
    applyActivityOverlayTheme()
    activityTextLabel.text = text
    layoutActivityOverlay()
    startDotPulseAnimation()

    guard activityOverlay.alpha < 1.0 else {
      // Already visible — just update text + layout
      UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
        self.layoutActivityOverlay()
      }
      return
    }

    activityOverlay.transform = CGAffineTransform(translationX: 0, y: 8)
    UIView.animate(
      withDuration: 0.25, delay: 0,
      usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
      options: .curveEaseOut
    ) {
      self.activityOverlay.alpha = 1.0
      self.activityOverlay.transform = .identity
    }
  }

  private func hideActivityOverlay() {
    guard activityOverlay.alpha > 0 else { return }
    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
      self.activityOverlay.alpha = 0
      self.activityOverlay.transform = CGAffineTransform(translationX: 0, y: 4)
    } completion: { _ in
      self.stopDotPulseAnimation()
      self.activityOverlay.transform = .identity
    }
  }

  private func startDotPulseAnimation() {
    for (i, dot) in activityDots.enumerated() {
      dot.layer.removeAnimation(forKey: "dotPulse")
      let anim = CABasicAnimation(keyPath: "opacity")
      anim.fromValue = 0.3
      anim.toValue = 1.0
      anim.duration = 0.5
      anim.autoreverses = true
      anim.repeatCount = .infinity
      anim.beginTime = CACurrentMediaTime() + Double(i) * 0.15
      anim.isRemovedOnCompletion = false
      dot.layer.add(anim, forKey: "dotPulse")
    }
  }

  private func stopDotPulseAnimation() {
    for dot in activityDots {
      dot.layer.removeAnimation(forKey: "dotPulse")
    }
  }

  private func setPeerTyping(_ _: Bool) {
    let next = false
    if isPeerTyping == next { return }
    isPeerTyping = next
    updateActivityOverlayState()
  }

  private func updateActivityOverlayState() {
    hideActivityOverlay()
  }
}
