import AVFoundation
import AVKit
import QuickLook
import UIKit

private let chatListMediaVerboseDebugLogs = false
private let chatListInlineVideoVerboseDebugLogs = false

public final class NativeEventDispatcher {
  public var handler: (([String: Any]) -> Void)?

  public init(handler: (([String: Any]) -> Void)? = nil) {
    self.handler = handler
  }

  public func callAsFunction(_ payload: [String: Any]) {
    handler?(payload)
  }
}

private func chatListDebugLog(_ enabled: Bool, _ format: String, _ args: CVarArg...) {
  guard enabled else { return }
  withVaList(args) { pointer in
    NSLogv(format, pointer)
  }
}

func normalizedWallpaperSampleRect(_ rect: CGRect, containerSize: CGSize) -> CGRect {
  guard containerSize.width > 1.0, containerSize.height > 1.0 else {
    return CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
  }

  let clampedX = max(0.0, min(rect.minX, containerSize.width))
  let clampedY = max(0.0, min(rect.minY, containerSize.height))
  let remainingWidth = max(1.0, containerSize.width - clampedX)
  let remainingHeight = max(1.0, containerSize.height - clampedY)
  let clampedWidth = max(1.0, min(rect.width, remainingWidth))
  let clampedHeight = max(1.0, min(rect.height, remainingHeight))

  return CGRect(
    x: clampedX / containerSize.width,
    y: clampedY / containerSize.height,
    width: clampedWidth / containerSize.width,
    height: clampedHeight / containerSize.height
  )
}

private func blendedWallpaperEdgeTint(color: UIColor, isDark: Bool) -> UIColor {
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

enum ChatWallpaperEdge {
  case top
  case bottom
}

final class ChatWallpaperEdgeEffectView: UIView {
  private let edge: ChatWallpaperEdge
  private let sampleLayer = CALayer()
  private let tintLayer = CAGradientLayer()
  private let sampleMaskLayer = CAGradientLayer()
  private let blurView = UIVisualEffectView(effect: nil)
  private let blurMaskLayer = CAGradientLayer()
  private var appearance = ChatListAppearance.fallback
  private var sampleRect: CGRect = .zero
  private var containerSize: CGSize = .zero
  private var backdropSnapshot: CGImage?
  private var edgeAlpha: CGFloat = 0.0
  private var blurEnabled = false

  init(edge: ChatWallpaperEdge) {
    self.edge = edge
    super.init(frame: .zero)

    isUserInteractionEnabled = false
    backgroundColor = .clear
    clipsToBounds = true

    sampleLayer.contentsGravity = .resize
    sampleLayer.contentsScale = UIScreen.main.scale
    sampleLayer.mask = sampleMaskLayer
    layer.addSublayer(sampleLayer)

    blurView.isUserInteractionEnabled = false
    blurView.clipsToBounds = true
    blurView.layer.mask = blurMaskLayer
    addSubview(blurView)

    layer.addSublayer(tintLayer)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyAppearance(_ appearance: ChatListAppearance) {
    self.appearance = appearance

    let isDark = appearance.isDark
    let topBase = appearance.wallpaperGradient.first ?? (isDark ? UIColor.black : UIColor.white)
    let bottomBase = appearance.wallpaperGradient.last ?? topBase
    let tintBase = edge == .top ? topBase : bottomBase
    let tintColor = blendedWallpaperEdgeTint(color: tintBase, isDark: isDark)
    let tintAlpha: CGFloat
    switch edge {
    case .top:
      tintAlpha = isDark ? 0.18 : 0.10
    case .bottom:
      tintAlpha = isDark ? 0.12 : 0.06
    }

    tintLayer.colors =
      edge == .top
      ? [tintColor.withAlphaComponent(tintAlpha).cgColor, UIColor.clear.cgColor]
      : [UIColor.clear.cgColor, tintColor.withAlphaComponent(tintAlpha).cgColor]
    tintLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    tintLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

    blurView.effect = UIBlurEffect(
      style: isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
    setNeedsLayout()
  }

  func updateBackdrop(
    snapshot: CGImage?,
    containerSize: CGSize,
    sampleRect: CGRect,
    alpha: CGFloat,
    blur: Bool
  ) {
    backdropSnapshot = snapshot
    self.containerSize = containerSize
    self.sampleRect = sampleRect
    edgeAlpha = alpha
    blurEnabled = blur
    applyBackdrop()
  }

  private func applyBackdrop() {
    let hasBackdrop =
      backdropSnapshot != nil
      && containerSize.width > 1.0
      && containerSize.height > 1.0
      && edgeAlpha > 0.001
      && !isHidden

    sampleLayer.isHidden = !hasBackdrop
    tintLayer.isHidden = !hasBackdrop
    blurView.isHidden = !hasBackdrop || !blurEnabled
    alpha = hasBackdrop ? 1.0 : 0.0

    guard hasBackdrop, let snapshot = backdropSnapshot else {
      sampleLayer.contents = nil
      return
    }

    sampleLayer.contents = snapshot
    sampleLayer.contentsRect = normalizedWallpaperSampleRect(sampleRect, containerSize: containerSize)
    let sampleOpacity: CGFloat
    let tintOpacity: CGFloat
    let blurAlpha: CGFloat
    switch edge {
    case .top:
      sampleOpacity = min(0.05, edgeAlpha * 0.14)
      tintOpacity = min(0.12, edgeAlpha * 0.42)
      blurAlpha = blurEnabled ? min(0.18, edgeAlpha * 0.52) : 0.0
    case .bottom:
      sampleOpacity = min(0.03, edgeAlpha * 0.10)
      tintOpacity = min(0.08, edgeAlpha * 0.28)
      blurAlpha = blurEnabled ? min(0.10, edgeAlpha * 0.20) : 0.0
    }
    sampleLayer.opacity = Float(sampleOpacity)
    tintLayer.opacity = Float(tintOpacity)
    blurView.alpha = blurAlpha
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    sampleLayer.frame = bounds
    tintLayer.frame = bounds
    blurView.frame = bounds

    let maskColors: [CGColor]
    switch edge {
    case .top:
      maskColors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
      sampleMaskLayer.locations = [0.0, 0.10, 0.46]
      blurMaskLayer.locations = [0.0, 0.14, 0.56]
    case .bottom:
      maskColors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
      sampleMaskLayer.locations = [0.58, 0.90, 1.0]
      blurMaskLayer.locations = [0.54, 0.88, 1.0]
    }

    sampleMaskLayer.frame = bounds
    sampleMaskLayer.colors = maskColors
    sampleMaskLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    sampleMaskLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

    blurMaskLayer.frame = bounds
    blurMaskLayer.colors = maskColors
    blurMaskLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    blurMaskLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
  }
}

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

private func formatNativeMusicPlayerTime(_ seconds: Double) -> String {
  guard seconds.isFinite, seconds > 0 else { return "0:00" }
  let total = max(0, Int(seconds.rounded()))
  return String(format: "%d:%02d", total / 60, total % 60)
}

private final class ChatNativeMusicPlayerBar: UIView {
  static let preferredHeight: CGFloat = 68.0

  private let blurView = UIVisualEffectView(effect: nil)
  private let artworkView = UIImageView()
  private let artworkPlaceholderView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let playbackButton = VoicePlayProgressView()
  private let closeButton = UIButton(type: .system)
  private let progressTrackView = UIView()
  private let progressFillView = UIView()
  private var snapshot = VoiceBubblePlaybackSnapshot.empty

  var onTogglePlayback: (() -> Void)?
  var onClose: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    layer.cornerCurve = .continuous
    layer.cornerRadius = 20.0

    blurView.isUserInteractionEnabled = false
    blurView.clipsToBounds = true
    blurView.layer.cornerCurve = .continuous
    blurView.layer.cornerRadius = 20.0
    addSubview(blurView)

    artworkView.contentMode = .scaleAspectFill
    artworkView.clipsToBounds = true
    artworkView.layer.cornerCurve = .continuous
    artworkView.layer.cornerRadius = 12.0
    addSubview(artworkView)

    artworkPlaceholderView.contentMode = .scaleAspectFit
    artworkPlaceholderView.image = UIImage(systemName: "music.note")
    addSubview(artworkPlaceholderView)

    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.numberOfLines = 1
    addSubview(titleLabel)

    subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    subtitleLabel.numberOfLines = 1
    addSubview(subtitleLabel)

    playbackButton.isUserInteractionEnabled = true
    playbackButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTogglePlayback)))
    addSubview(playbackButton)

    closeButton.tintColor = .white
    closeButton.setImage(
      UIImage(systemName: "xmark")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)),
      for: .normal
    )
    closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    addSubview(closeButton)

    progressTrackView.isUserInteractionEnabled = false
    progressTrackView.layer.cornerCurve = .continuous
    progressTrackView.layer.cornerRadius = 1.5
    addSubview(progressTrackView)

    progressFillView.isUserInteractionEnabled = false
    progressFillView.layer.cornerCurve = .continuous
    progressFillView.layer.cornerRadius = 1.5
    addSubview(progressFillView)

    isHidden = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyAppearance(_ appearance: ChatListAppearance) {
    let isDark = appearance.isDark
    blurView.effect = UIBlurEffect(
      style: isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
    backgroundColor = UIColor.clear
    artworkView.backgroundColor = UIColor(white: isDark ? 1.0 : 0.0, alpha: isDark ? 0.08 : 0.06)
    artworkPlaceholderView.tintColor = UIColor(white: isDark ? 1.0 : 0.0, alpha: 0.48)
    titleLabel.textColor = isDark ? .white : UIColor(white: 0.08, alpha: 1.0)
    subtitleLabel.textColor = isDark ? UIColor(white: 1.0, alpha: 0.68) : UIColor(white: 0.16, alpha: 0.72)
    progressTrackView.backgroundColor = UIColor(white: isDark ? 1.0 : 0.0, alpha: isDark ? 0.12 : 0.10)
    progressFillView.backgroundColor = appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor
    playbackButton.applyStyle(
      fillColor: UIColor(white: 1.0, alpha: 0.96),
      iconTint: appearance.bubbleMeGradient.first ?? UIColor.systemBlue,
      ringTint: (appearance.bubbleMeGradient.first ?? UIColor.systemBlue).withAlphaComponent(0.8)
    )
  }

  func applySnapshot(_ snapshot: VoiceBubblePlaybackSnapshot) {
    self.snapshot = snapshot
    let shouldShow = snapshot.presentsGlobalPlayer && snapshot.messageId != nil
    isHidden = !shouldShow
    guard shouldShow else { return }

    artworkView.image = snapshot.artwork
    artworkPlaceholderView.isHidden = snapshot.artwork != nil
    titleLabel.text = snapshot.title ?? "Audio"
    
    let newSubtitle: String
    if snapshot.isDownloading {
      let percent = Int(round(Double(snapshot.downloadProgress ?? 0.0) * 100.0))
      newSubtitle = percent > 0 ? "Downloading \(percent)%" : "Downloading"
    } else if snapshot.duration > 0.0 {
      let current = snapshot.duration * Double(snapshot.progress)
      newSubtitle = "\(formatNativeMusicPlayerTime(current)) / \(formatNativeMusicPlayerTime(snapshot.duration))"
    } else {
      newSubtitle = snapshot.subtitle ?? ""
    }
    if subtitleLabel.text != newSubtitle {
      subtitleLabel.text = newSubtitle
    }

    playbackButton.setArtworkImage(nil)
    playbackButton.setUploadState(isUploading: false, progress: nil)
    if snapshot.isDownloading {
      playbackButton.setDownloadState(
        needsDownload: true,
        isDownloading: true,
        progress: snapshot.downloadProgress
      )
    } else {
      playbackButton.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      playbackButton.setPlaybackState(
        isPlaying: snapshot.isPlaying,
        progress: snapshot.progress,
        level: snapshot.isPlaying ? 0.22 : 0.0
      )
    }
    
    if bounds.width > 0 {
      let progressWidth = max(0.0, closeButton.frame.minX - 10.0 - titleLabel.frame.minX)
      progressFillView.frame.size.width = progressWidth * max(0.0, min(1.0, snapshot.progress))
      let hideProgress = snapshot.isDownloading || snapshot.duration <= 0.0
      if progressTrackView.isHidden != hideProgress {
        progressTrackView.isHidden = hideProgress
        progressFillView.isHidden = hideProgress
      }
    } else {
      setNeedsLayout()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurView.frame = bounds

    let inset: CGFloat = 10.0
    let artworkSide: CGFloat = bounds.height - (inset * 2.0)
    artworkView.frame = CGRect(x: inset, y: inset, width: artworkSide, height: artworkSide)
    artworkPlaceholderView.frame = artworkView.frame.insetBy(dx: 10.0, dy: 10.0)

    let closeSide: CGFloat = 28.0
    closeButton.frame = CGRect(
      x: bounds.width - inset - closeSide,
      y: floor((bounds.height - closeSide) * 0.5),
      width: closeSide,
      height: closeSide
    )

    let playbackSide: CGFloat = 34.0
    playbackButton.frame = CGRect(
      x: closeButton.frame.minX - 8.0 - playbackSide,
      y: floor((bounds.height - playbackSide) * 0.5),
      width: playbackSide,
      height: playbackSide
    )

    let textX = artworkView.frame.maxX + 10.0
    let textRight = playbackButton.frame.minX - 10.0
    let textWidth = max(0.0, textRight - textX)
    titleLabel.frame = CGRect(x: textX, y: inset + 8.0, width: textWidth, height: 18.0)
    subtitleLabel.frame = CGRect(x: textX, y: titleLabel.frame.maxY + 4.0, width: textWidth, height: 16.0)

    let progressX = textX
    let progressY = bounds.height - 10.0
    let progressWidth = max(0.0, closeButton.frame.minX - 10.0 - progressX)
    progressTrackView.frame = CGRect(x: progressX, y: progressY, width: progressWidth, height: 3.0)
    progressFillView.frame = CGRect(
      x: progressX,
      y: progressY,
      width: progressWidth * max(0.0, min(1.0, snapshot.progress)),
      height: 3.0
    )
    progressTrackView.isHidden = snapshot.isDownloading || snapshot.duration <= 0.0
    progressFillView.isHidden = progressTrackView.isHidden
  }

  @objc private func handleTogglePlayback() {
    onTogglePlayback?()
  }

  @objc private func handleClose() {
    onClose?()
  }
}

private let chatListSendVerticalTiming = CAMediaTimingFunction(
  controlPoints: Float(0.19919472913616398),
  Float(0.010644531250000006),
  Float(0.27920937042459737),
  Float(0.91025390625)
)
private let chatReactionDebugLogs = true
private let chatGapDebugOverlayEnabled = false

public final class ChatListView: UIView, UICollectionViewDataSource,
  UICollectionViewDelegateFlowLayout
{
  public var onViewportChanged = NativeEventDispatcher()
  public var onNativeEvent = NativeEventDispatcher()

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
  private let scrollToneTopView = ChatWallpaperEdgeEffectView(edge: .top)
  private let scrollToneBottomView = ChatWallpaperEdgeEffectView(edge: .bottom)
  private let gapDebugOverlay = UIView()
  private let gapDebugLabel = UILabel()
  var rows: [ChatListRow] = []
  private var appearance = ChatListAppearance.fallback
  private var queuedAppearanceAfterSendTransition: ChatListAppearance?
  private var shouldAutoScroll = true
  private var previousOffsetY: CGFloat = 0.0
  private var skipNextTransitionScrollCorrection = false
  private var lastKnownViewportWidth: CGFloat = 0.0
  private var lastKnownViewportHeight: CGFloat = 0.0
  private var contentPaddingTop: CGFloat = sectionTopInset
  private var requestedContentPaddingBottom: CGFloat = sectionBottomInset
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
  private var enginePeerAgentId: String = ""
  private var enginePeerDisplayName: String = ""
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
  private var onDemandRemoteMediaDownloadKeys = Set<String>()
  private var mediaDownloadProgressByRemoteKey: [String: Double] = [:]
  private var mediaDownloadObservations: [String: NSKeyValueObservation] = [:]
  private var mediaDownloadTasks: [String: URLSessionDownloadTask] = [:]
  private var visibleAutoDownloadWorkItem: DispatchWorkItem?
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
  private static var wallpaperSnapshotCache: [String: CGImage] = [:]
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
  private var wallpaperSnapshot: CGImage?
  private var wallpaperSnapshotSize: CGSize = .zero
  private var wallpaperSnapshotCacheKey: String = ""

  // Floating activity overlay (typing / agent progress) — lives OUTSIDE the collection view
  private let activityOverlay = UIView()
  private let activityDotContainer = UIView()
  private let activityDots: [UIView] = (0..<3).map { _ in UIView() }
  private let activityTextLabel = UILabel()

  func setIsGroupOrChannel(_ value: Bool) {
    isGroupOrChannel = value
  }

  override init(frame: CGRect) {
    let layout = ChatCollectionFlowLayout()
    layout.minimumLineSpacing = 2
    layout.sectionInset = UIEdgeInsets(
      top: sectionTopInset, left: messageHorizontalInset, bottom: sectionBottomInset,
      right: messageHorizontalInset)
    layout.sectionHeadersPinToVisibleBounds = false

    flowLayout = layout
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    super.init(frame: frame)
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
    scrollToneOverlay.addSubview(scrollToneTopView)
    scrollToneOverlay.addSubview(scrollToneBottomView)
    addSubview(scrollToneOverlay)

    applyWallpaperAppearance()
    applyScrollToneTheme()
    updateScrollToneOverlay(offsetY: 0.0)

    // Transition overlay host — always on top of everything
    transitionOverlayHost.isUserInteractionEnabled = false
    transitionOverlayHost.clipsToBounds = false
    addSubview(transitionOverlayHost)

    if chatGapDebugOverlayEnabled {
      gapDebugOverlay.isUserInteractionEnabled = false
      gapDebugOverlay.backgroundColor = UIColor.red.withAlphaComponent(0.24)
      gapDebugOverlay.layer.borderColor = UIColor.red.withAlphaComponent(0.95).cgColor
      gapDebugOverlay.layer.borderWidth = 1

      gapDebugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
      gapDebugLabel.textColor = .white
      gapDebugLabel.backgroundColor = UIColor.red.withAlphaComponent(0.82)
      gapDebugLabel.textAlignment = .center
      gapDebugLabel.layer.cornerRadius = 4
      gapDebugLabel.clipsToBounds = true

      gapDebugOverlay.addSubview(gapDebugLabel)
      addSubview(gapDebugOverlay)
    }

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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleVoiceBubblePlaybackChanged(_:)),
      name: .voiceBubblePlaybackDidChange,
      object: VoiceBubblePlaybackCoordinator.shared
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAgentCodeBlockExpanded(_:)),
      name: Notification.Name("AgentCodeBlockExpanded"),
      object: nil
    )

  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func pixelAlignedValue(_ value: CGFloat) -> CGFloat {
    let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1.0)
    return (value * scale).rounded() / scale
  }

  private func layoutGapDebugOverlay() {
    guard chatGapDebugOverlayEnabled else { return }

    let overlayHeight = max(0, contentPaddingBottom)
    gapDebugOverlay.isHidden = overlayHeight <= 0.5
    guard overlayHeight > 0.5 else { return }

    gapDebugOverlay.frame = CGRect(
      x: 0,
      y: max(0, bounds.height - overlayHeight),
      width: bounds.width,
      height: overlayHeight
    )
    let labelWidth = min(max(128, bounds.width * 0.46), max(128, bounds.width - 16))
    gapDebugLabel.frame = CGRect(x: 8, y: 6, width: labelWidth, height: 18)
    gapDebugLabel.text = String(
      format: "LIST inset %.0f req %.0f",
      contentPaddingBottom,
      requestedContentPaddingBottom
    )

    bringSubviewToFront(gapDebugOverlay)
    if let inputBar {
      bringSubviewToFront(inputBar)
    }
    bringSubviewToFront(transitionOverlayHost)
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
    updateChatEngineBinding()
    updateChatEngineChannelBinding()
    if window != nil {
      hydrateRowsFromNativeHistoryIfReady(trigger: "didMoveToWindow")
    }
  }

  override public func layoutSubviews() {
    let previousHeight = lastKnownViewportHeight
    let previousWidth = lastKnownViewportWidth
    super.layoutSubviews()
    wallpaperLayer.frame = bounds
    wallpaperPatternLayer.frame = bounds
    wallpaperPatternMaskLayer.frame = wallpaperPatternLayer.bounds
    scrollToneOverlay.frame = bounds
    refreshWallpaperSnapshotIfNeeded()
    updateScrollToneOverlay(offsetY: collectionView.contentOffset.y)
    updateVisibleWallpaperBackdropLayouts()
    transitionOverlayHost.frame = bounds
    layoutDebugPanel()

    // Layout native input bar if enabled
    if inputBarEnabled {
      layoutInputBarAndInset()
    } else {
      let desiredBottomPadding = requestedContentPaddingBottom
      if abs(contentPaddingBottom - desiredBottomPadding) > 0.5 {
        contentPaddingBottom = desiredBottomPadding
        updateBottomAnchorInset()
      }
    }
    layoutActivityOverlay()
    layoutGapDebugOverlay()

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
    updateBottomAnchorInset()
    if distanceBeforeResize <= listBottomThreshold || shouldAutoScroll
      || pendingSendTransition != nil || activeSendTransition != nil || hiddenMessageId != nil
    {
      scrollToBottom(animated: false)
    } else {
      restoreStationaryDistance(distanceBeforeResize)
    }
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
      guard let self else { return }
      self.rows = parsed
      let engineChatId = self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      let resolvedChatId: String
      if !engineChatId.isEmpty {
        resolvedChatId = engineChatId
      } else {
        resolvedChatId =
          parsed.first(where: { row in
            if let chatId = row.chatId?.trimmingCharacters(in: .whitespacesAndNewlines) {
              return !chatId.isEmpty
            }
            return false
          })?.chatId?.trimmingCharacters(in: .whitespacesAndNewlines)
          ?? ""
      }
      if !resolvedChatId.isEmpty {
        ChatAudioQueueRegistry.shared.setRows(parsed, for: resolvedChatId)
        VoiceBubblePlaybackCoordinator.shared.refreshCurrentSnapshotIfNeeded(forChatId: resolvedChatId)
      }
    }

    let finalize = { [weak self] (animated: Bool) in
      guard let self else {
        return
      }
      let shouldForceBottomForPendingSend =
        self.pendingSendTransition != nil || self.activeSendTransition != nil
        || self.hiddenMessageId != nil
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
      if wasNearBottom || shouldForceBottomForPendingSend {
        self.scrollToBottom(animated: shouldForceBottomForPendingSend ? false : animated)
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
            bindWallpaperBackdrop(to: cell)
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
    hydrateRowsFromNativeHistoryIfReady(trigger: "chatId")
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

  func setEnginePeerAgentId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if enginePeerAgentId == next { return }
    enginePeerAgentId = next
    updateChatEngineBinding()
  }

  func setEnginePeerDisplayName(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if enginePeerDisplayName == next { return }
    enginePeerDisplayName = next
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    if statusAuthorityEnabled == enabled { return }
    statusAuthorityEnabled = enabled
    if enabled {
      hydrateRowsFromNativeHistoryIfReady(trigger: "statusAuthorityEnabled")
    }
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
      refreshWallpaperSnapshotIfNeeded(force: true)
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
    let next = max(sectionBottomInset, CGFloat(value))
    requestedContentPaddingBottom = next

    // Native input mode owns bottom inset (bar height + keyboard height).
    // Ignore external padding updates while still remembering the requested
    // value so it can be restored if native input mode is disabled.
    guard !inputBarEnabled else {
      return
    }
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

  @objc private func handleVoiceBubblePlaybackChanged(_ notification: Notification) {
    let snapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
    let nextMessageId = snapshot.messageId
    let nextIsPlaying = snapshot.isPlaying
    let nextProgress = max(0.0, min(1.0, snapshot.progress))

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
    let row = rows[indexPath.item]
    let preferredMediaURL = resolvedPreferredMediaURL(for: row)
    let preferredLocalMediaURLOverride: String? = {
      guard let preferredMediaURL else { return nil }
      if let parsed = URL(string: preferredMediaURL), parsed.isFileURL {
        return preferredMediaURL
      }
      if preferredMediaURL.hasPrefix("/") {
        return preferredMediaURL
      }
      return nil
    }()
    cell.applyAppearance(appearance)
    cell.resolveDisplayStatus = { [weak self] row in
      self?.resolvedDisplayStatus(for: row)
    }
    let mediaDownloadState = remoteMediaDownloadState(for: row)
    cell.configure(
      row: row,
      hiddenMessageId: hiddenMessageId,
      skipRemoteMediaLoad: mediaDownloadState.needsDownload,
      preferredLocalMediaURLOverride: preferredLocalMediaURLOverride
    )
    bindWallpaperBackdrop(to: cell)
    cell.applyMediaDownloadState(
      needsDownload: mediaDownloadState.needsDownload,
      isDownloading: mediaDownloadState.isDownloading,
      progress: mediaDownloadState.progress
    )
    let currentlyVisible = collectionView.indexPathsForVisibleItems.contains(indexPath)
    if rowRepresentsVideoMedia(row) {
      chatListDebugLog(
        chatListInlineVideoVerboseDebugLogs,
        "[ChatInlineVideoList] configure msgId=%@ visibleNow=%@ needsDownload=%@ downloading=%@ preferredLocal=%@ remote=%@",
        row.messageId ?? "-",
        currentlyVisible ? "Y" : "N",
        mediaDownloadState.needsDownload ? "Y" : "N",
        mediaDownloadState.isDownloading ? "Y" : "N",
        preferredLocalMediaURLOverride ?? "nil",
        row.mediaUrl ?? "nil"
      )
    }
    cell.setInlineVideoPlaybackActive(currentlyVisible)
    cell.onInlineAttachmentTap = { [weak self] row in
      guard let self else { return }
      if !row.relatedMessageIds.isEmpty {
        self.onNativeEvent([
          "type": "relatedMessagesPressed",
          "messageId": row.messageId ?? "",
          "relatedMessageIds": row.relatedMessageIds,
          "title": row.relatedMessagesTitle ?? "",
          "subtitle": row.relatedMessagesSubtitle ?? "",
        ])
      } else {
        self.openDocumentInApp(row: row)
      }
    }
    cell.onMediaNaturalSizeResolved = { [weak self] messageId, mediaURL, size in
      self?.handleResolvedMediaSize(messageId: messageId, mediaURL: mediaURL, size: size)
    }
    cell.onVoiceUploadCancelTap = { [weak self] row in
      guard let self, let messageId = row.messageId, !messageId.isEmpty else { return }
      let downloadState = self.remoteMediaDownloadState(for: row)
      if downloadState.isDownloading {
        if let remoteURL = URL(string: row.mediaUrl ?? "") {
          let remoteKey = self.remoteMediaCacheKey(
            remoteURL: remoteURL,
            mediaKey: self.resolvedMediaKey(for: row)
          )
          self.mediaDownloadTasks[remoteKey]?.cancel()
        }
        return
      }
      self.onNativeEvent([
        "type": "cancelOutgoingUpload",
        "messageId": messageId,
      ])
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
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    guard indexPath.item < rows.count else { return }
    let row = rows[indexPath.item]
    if rowRepresentsVideoMedia(row) {
      chatListDebugLog(
        chatListInlineVideoVerboseDebugLogs,
        "[ChatInlineVideoList] willDisplay msgId=%@ needsDownload=%@ remote=%@",
        row.messageId ?? "-",
        remoteMediaDownloadState(for: row).needsDownload ? "Y" : "N",
        row.mediaUrl ?? "nil"
      )
    }
    (cell as? ChatListCell)?.setInlineVideoPlaybackActive(true)
    scheduleAutoRemoteMediaDownloadIfNeeded(for: row)
  }

  public func collectionView(
    _ collectionView: UICollectionView,
    didEndDisplaying cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    if indexPath.item < rows.count {
      let row = rows[indexPath.item]
      if rowRepresentsVideoMedia(row) {
        chatListDebugLog(
          chatListInlineVideoVerboseDebugLogs,
          "[ChatInlineVideoList] didEndDisplaying msgId=%@",
          row.messageId ?? "-"
        )
      }
    }
    (cell as? ChatListCell)?.setInlineVideoPlaybackActive(false)
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
    let isUploadCancelableVisual =
      row.visualKind == .voice
      || row.visualKind == .media
      || row.visualKind == .video
      || row.visualKind == .videoNote
      || row.visualKind == .sticker
    let lowerMediaURL = mediaURL.lowercased()
    let isAgentDocURL =
      lowerMediaURL.contains("/uploads/agent-docs/")
      || lowerMediaURL.contains("/api/agent/document/")
    if isUploadCancelableVisual, row.shouldShowUploadOverlay {
      if let messageId = row.messageId, !messageId.isEmpty {
        onNativeEvent([
          "type": "cancelOutgoingUpload",
          "messageId": messageId,
        ])
      }
      return
    }
    if isVoiceVisual {
      if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell {
        VoiceBubblePlaybackCoordinator.shared.toggle(
          cell: cell,
          messageId: row.messageId,
          mediaURL: mediaURL,
          mediaKey: resolvedMediaKey(for: row),
          fileName: row.fileName
        )
      }
      return
    }
    let isImageVisual = row.visualKind == .media && row.messageType != "file"
    if isImageVisual {
      let mediaDownloadState = remoteMediaDownloadState(for: row)
      if mediaDownloadState.needsDownload {
        startRemoteMediaDownload(for: row, presentOnComplete: true)
        return
      }
      let seedImage = (collectionView.cellForItem(at: indexPath) as? ChatListCell)?
        .currentMediaImage()
      presentImageEditView(
        for: row,
        mediaURL: resolvedPreferredMediaURL(for: row) ?? mediaURL,
        seedImage: seedImage)
      return
    }
    let isMediaOrVideo =
      row.visualKind == .media || row.visualKind == .video || row.visualKind == .videoNote
    if isMediaOrVideo {
      let mediaDownloadState = remoteMediaDownloadState(for: row)
      if mediaDownloadState.needsDownload {
        // Skip the full-file download for unencrypted remote audio — openDocumentInApp will stream it.
        let isStreamableAudio: Bool = {
          let key = resolvedMediaKey(for: row)
          let noKey = key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
          guard noKey, let rawURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
          return isAudioAttachmentURI(rawURL, fileNameHint: row.fileName)
            && (URL(string: rawURL)?.scheme.map { ["http","https"].contains($0.lowercased()) } ?? false)
        }()
        if !isStreamableAudio {
          startRemoteMediaDownload(for: row, presentOnComplete: true)
          return
        }
      }
    }
    guard isFileLikeType || hasFileNameHint || isAgentDocURL || isMediaOrVideo else { return }
    openDocumentInApp(row: row)
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
      hydrateRowsFromNativeHistoryIfReady(trigger: "chatRowsReloaded")
      return
    }
    refreshVisibleStatuses(reason: reason)
  }

  private func hydrateRowsFromNativeHistoryIfReady(trigger: String) {
    guard statusAuthorityEnabled else { return }
    let resolvedChatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedChatId.isEmpty else { return }

    // Restore overlay rows from ChatEngine's live index so messages sent while
    // the view was detached can render immediately before JS catches up.
    if nativeEngineRowsById.isEmpty {
      let liveRows = ChatEngine.shared.getLiveMessageRows(["chatId": resolvedChatId])
      if !liveRows.isEmpty {
        for (rawMessageId, row) in liveRows {
          guard let messageId = normalizedMessageId(rawMessageId) else { continue }
          nativeEngineRowsById[messageId] = row
          if !nativeEngineOrder.contains(messageId) {
            nativeEngineOrder.append(messageId)
          }
        }
        NSLog(
          "[ChatListView] hydrateRowsFromNativeHistoryIfReady restored overlay from live rows trigger=%@ chatId=%@ count=%d",
          trigger, resolvedChatId, liveRows.count
        )
      }
    }

    let historyLoaded = ChatEngine.shared.isChatHistoryLoaded(chatId: resolvedChatId)
    if !historyLoaded && nativeEngineRowsById.isEmpty { return }
    NSLog(
      "[ChatListView] hydrateRowsFromNativeHistoryIfReady trigger=%@ chatId=%@ sourceRows=%d overlay=%d historyLoaded=%@",
      trigger, resolvedChatId, sourceRowsPayload.count, nativeEngineRowsById.count,
      historyLoaded ? "Y" : "N"
    )
    setRows(sourceRowsPayload)
  }

  private func updateChatEngineBinding() {
    guard !engineSurfaceId.isEmpty else { return }
    _ = ChatEngine.shared.bindSurface([
      "surfaceId": engineSurfaceId,
      "chatId": engineChatId,
      "myUserId": engineMyUserId,
      "peerUserId": enginePeerUserId,
      "peerAgentId": enginePeerAgentId,
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
      bindWallpaperBackdrop(to: cell)
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
    updateVisibleWallpaperBackdropLayouts()

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
    scheduleVisibleAutoDownloads()
    maybeStartPendingSendTransition()
    emitViewport()
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      runVisibleAutoDownloads()
    }
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    runVisibleAutoDownloads()
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
    updateScrollToneOverlay(offsetY: collectionView.contentOffset.y)
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

  private func nonEmptyString(from raw: Any?) -> String? {
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

  private func mediaKey(fromRawRow row: [String: Any]) -> String? {
    let message = row["message"] as? [String: Any]
    let metadata = message?["metadata"] as? [String: Any]
    return nonEmptyString(from: message?["mediaKey"])
      ?? nonEmptyString(from: message?["media_key"])
      ?? nonEmptyString(from: metadata?["mediaKey"])
      ?? nonEmptyString(from: metadata?["media_key"])
      ?? nonEmptyString(from: row["mediaKey"])
      ?? nonEmptyString(from: row["media_key"])
  }

  private func resolvedMediaKey(for row: ChatListRow) -> String? {
    if let mediaKey = nonEmptyString(from: row.mediaKey) {
      return mediaKey
    }
    guard let messageId = normalizedMessageId(row.messageId) else {
      return nil
    }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let liveEngineRow: [String: Any]? = {
      guard !chatId.isEmpty else { return nil }
      return ChatEngine.shared.getLiveMessageRow([
        "chatId": chatId,
        "messageId": messageId,
      ])
    }()
    let candidates: [[String: Any]?] = [
      rawRow(messageId: messageId, in: sourceRowsPayload),
      nativeOutgoingRowsById[messageId],
      nativeEngineRowsById[messageId],
      liveEngineRow,
    ]
    for candidate in candidates {
      guard let candidate, let mediaKey = mediaKey(fromRawRow: candidate) else { continue }
      return mediaKey
    }
    return nil
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

  private func queueNativeOutgoingMediaMessage(
    messageId: String,
    type: String,
    localUri: String,
    caption: String?,
    timestamp: String,
    timestampMs: Double,
    fileName: String? = nil,
    fileSize: Int64? = nil,
    duration: Double? = nil,
    mediaSize: CGSize? = nil,
    thumbnailBase64: String? = nil,
    replyToId: String? = nil
  ) {
    let isPreviousMe: Bool = {
      if let lastMessageRow = rows.last(where: { $0.kind == .message }) {
        return lastMessageRow.isMe
      }
      return false
    }()

    let borderTopRightRadius: CGFloat = isPreviousMe ? 5 : 18
    var metadata: [String: Any] = [
      "mediaUrl": localUri,
      "localMediaUrl": localUri,
      "uploadProgress": 0.027,
    ]
    if let fileName { metadata["fileName"] = fileName }
    if let fileSize, fileSize > 0 { metadata["fileSize"] = fileSize }
    if let duration { metadata["duration"] = duration }
    if let mediaSize, mediaSize.width > 1.0, mediaSize.height > 1.0 {
      metadata["width"] = Int(mediaSize.width)
      metadata["height"] = Int(mediaSize.height)
    }
    if let thumbnailBase64, !thumbnailBase64.isEmpty {
      metadata["thumbnailBase64"] = thumbnailBase64
    }

    var message: [String: Any] = [
      "id": messageId,
      "text": caption ?? "",
      "timestamp": timestamp,
      "timestampMs": timestampMs,
      "isMe": true,
      "status": "pending",
      "type": type,
      "mediaUrl": localUri,
      "localMediaUrl": localUri,
      "uploadProgress": 0.027,
      "metadata": metadata,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": borderTopRightRadius,
        "borderBottomRightRadius": 18,
        "borderBottomLeftRadius": 18,
      ],
    ]
    if let fileName { message["fileName"] = fileName }
    if let fileSize, fileSize > 0 { message["fileSize"] = fileSize }
    if let duration { message["duration"] = duration }
    if let mediaSize, mediaSize.width > 1.0, mediaSize.height > 1.0 {
      message["width"] = Int(mediaSize.width)
      message["height"] = Int(mediaSize.height)
    }
    if let thumbnailBase64, !thumbnailBase64.isEmpty {
      message["thumbnailBase64"] = thumbnailBase64
    }
    if let replyToId { message["replyToId"] = replyToId }

    nativeOutgoingRowsById[messageId] = [
      "kind": "message",
      "key": "m-\(messageId)",
      "message": message,
    ]
    if !nativeOutgoingOrder.contains(messageId) {
      nativeOutgoingOrder.append(messageId)
    }
    setRows(sourceRowsPayload)
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
      frame: CGRect(x: -10_000.0, y: -10_000.0, width: rowWidth, height: max(1.0, rowHeight))
    )
    renderCell.applyAppearance(appearance)
    renderCell.configure(row: row, hiddenMessageId: nil)
    bindWallpaperBackdrop(to: renderCell)
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
          bindWallpaperBackdrop(to: cell)
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
    wallpaperSnapshotCacheKey = ""
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
    scrollToneTopView.applyAppearance(appearance)
    scrollToneBottomView.applyAppearance(appearance)
  }

  private func updateScrollToneOverlay(offsetY: CGFloat) {
    guard bounds.width > 0.0, bounds.height > 0.0 else { return }
    let _ = offsetY

    let hasPattern =
      appearance.backgroundMode != "transparent"
      && appearance.wallpaperPatternGradient.count >= 2
      && appearance.wallpaperPatternOpacity > 0.001
      && (appearance.wallpaperMaskKey?.isEmpty == false)

    let edgeAlpha: CGFloat = {
      guard appearance.backgroundMode != "transparent" else { return 0.0 }
      if hasPattern {
        return appearance.isDark ? 0.04 : 0.03
      } else {
        return appearance.isDark ? 0.03 : 0.02
      }
    }()

    let topHeight = min(bounds.height, max(100.0, contentPaddingTop + 34.0))
    let bottomHeight = min(bounds.height, max(100.0, contentPaddingBottom + 20.0))

    let topFrame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: topHeight)
    let bottomFrame = CGRect(
      x: 0.0,
      y: max(0.0, bounds.height - bottomHeight),
      width: bounds.width,
      height: bottomHeight
    )
    scrollToneTopView.frame = topFrame
    scrollToneBottomView.frame = bottomFrame
    scrollToneTopView.updateBackdrop(
      snapshot: wallpaperSnapshot,
      containerSize: wallpaperSnapshotSize,
      sampleRect: topFrame,
      alpha: edgeAlpha,
      blur: false
    )
    scrollToneBottomView.updateBackdrop(
      snapshot: wallpaperSnapshot,
      containerSize: wallpaperSnapshotSize,
      sampleRect: bottomFrame,
      alpha: edgeAlpha,
      blur: false
    )
  }

  private func refreshWallpaperSnapshotIfNeeded(force: Bool = false) {
    guard
      appearance.backgroundMode != "transparent",
      bounds.width > 1.0,
      bounds.height > 1.0,
      !wallpaperLayer.isHidden
    else {
      wallpaperSnapshot = nil
      wallpaperSnapshotSize = .zero
      wallpaperSnapshotCacheKey = ""
      return
    }

    let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1.0)
    let cacheKey =
      "\(appearance.visualKey)|\(Int(bounds.width.rounded() * scale))x\(Int(bounds.height.rounded() * scale))"
    if !force, wallpaperSnapshotCacheKey == cacheKey, wallpaperSnapshot != nil {
      return
    }

    if let cached = Self.wallpaperSnapshotCache[cacheKey] {
      wallpaperSnapshot = cached
      wallpaperSnapshotSize = bounds.size
      wallpaperSnapshotCacheKey = cacheKey
      return
    }

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
    let image = renderer.image { context in
      wallpaperLayer.render(in: context.cgContext)
      if !wallpaperPatternLayer.isHidden {
        wallpaperPatternLayer.render(in: context.cgContext)
      }
    }
    guard let cgImage = image.cgImage else { return }
    Self.wallpaperSnapshotCache[cacheKey] = cgImage
    wallpaperSnapshot = cgImage
    wallpaperSnapshotSize = bounds.size
    wallpaperSnapshotCacheKey = cacheKey
  }

  private func bindWallpaperBackdrop(to cell: ChatListCell) {
    cell.applyWallpaperBackdrop(
      snapshot: wallpaperSnapshot,
      containerSize: wallpaperSnapshotSize,
      coordinateView: self
    )
  }

  private func updateVisibleWallpaperBackdropLayouts() {
    for case let cell as ChatListCell in collectionView.visibleCells {
      bindWallpaperBackdrop(to: cell)
      cell.updateWallpaperBackdropLayoutIfNeeded()
    }
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
      if abs(contentPaddingBottom - sectionBottomInset) > 0.5 {
        contentPaddingBottom = sectionBottomInset
        updateBottomAnchorInset()
      }
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
      if abs(contentPaddingBottom - requestedContentPaddingBottom) > 0.5 {
        contentPaddingBottom = requestedContentPaddingBottom
        updateBottomAnchorInset()
      }
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

    let effectiveKeyboardHeight: CGFloat
    let safeBottom: CGFloat
    if bar.isGifPanelPresented {
      effectiveKeyboardHeight = 0
      safeBottom = 0
    } else {
      effectiveKeyboardHeight = keyboardHeight
      safeBottom = keyboardHeight > 0 ? 0 : safeAreaInsets.bottom
    }
    bar.bottomSafeAreaInset = safeBottom

    // Size the bar by updating its width (avoiding y-origin jumps during UIView animations)
    bar.frame = CGRect(x: 0, y: bar.frame.minY, width: w, height: bar.frame.height)
    bar.layoutIfNeeded()
    let barH = bar.barHeight

    // Position at bottom, above keyboard. When the GIF panel is open, `barH`
    // already includes both the composer and the panel.
    let barY = h - barH - effectiveKeyboardHeight
    bar.frame = CGRect(x: 0, y: barY, width: w, height: barH)
    bar.alpha = 1
    bar.isUserInteractionEnabled = true

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

  private func handleNativeSend(
    text: String,
    agentMention: Bool = false,
    agentText: String? = nil,
    mentionedAgentUsername: String? = nil
  )
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
      let peerAgentId = enginePeerAgentId.trimmingCharacters(in: .whitespacesAndNewlines)
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
        "peerAgentId": peerAgentId,
        "isGroup": isGroupOrChannel,
      ]
      if agentMention, let agentText {
        sendPayload["agentMention"] = true
        sendPayload["agentText"] = agentText
      }
      if let mentionedAgentUsername, !mentionedAgentUsername.isEmpty {
        sendPayload["mentionedAgentUsername"] = mentionedAgentUsername
        if let agentText, !agentText.isEmpty {
          sendPayload["agentText"] = agentText
        }
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
      if let mentionedAgentUsername, !mentionedAgentUsername.isEmpty {
        sendPayload["mentionedAgentUsername"] = mentionedAgentUsername
        if let agentText, !agentText.isEmpty {
          sendPayload["agentText"] = agentText
        }
      }
      onNativeEvent(sendPayload)
    }
  }

  private func makeAttachmentSendTransitionPayload(
    messageId: String,
    text: String,
    timestamp: String,
    transitionCapture: ChatAttachmentTransitionCapture?
  ) -> SendTransitionPayload? {
    guard let transitionCapture else { return nil }
    let sourceContainerRect: CGRect
    if let window {
      sourceContainerRect = convert(transitionCapture.sourceContainerFrameInWindow, from: window)
    } else {
      sourceContainerRect = transitionCapture.sourceContainerFrameInWindow
    }
    let localRect = CGRect(origin: .zero, size: sourceContainerRect.size)
    return SendTransitionPayload(
      messageId: messageId,
      text: text,
      timestamp: timestamp,
      startRect: sourceContainerRect,
      sourceContainerRect: sourceContainerRect,
      sourceBackgroundRectInContainer: localRect,
      sourceContentRectInContainer: localRect,
      sourceScrollOffset: 0.0,
      sourceBackgroundSnapshotView: transitionCapture.sourceBackgroundSnapshotView,
      sourceContentSnapshotView: transitionCapture.sourceContentSnapshotView
    )
  }

  private func handleNativeAttachmentSend(
    uri: String,
    caption: String?,
    transitionCapture: ChatAttachmentTransitionCapture?
  ) {
    let messageId = UUID().uuidString.lowercased()
    let now = Date()
    let timestampMs = now.timeIntervalSince1970 * 1000
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let timestamp = formatter.string(from: now)
    let replyToMessageId = inputBar?.activeReplyToMessageId
    let isVideo = isVideoAttachmentURI(uri)
    let type = isVideo ? "video" : "image"
    let fileName = localAttachmentFileName(for: uri)
    let fileSize = localAttachmentFileSize(for: uri)
    let duration = isVideo ? localMediaDurationSeconds(for: uri) : nil
    let mediaSize = isVideo ? localVideoNaturalSize(for: uri) : localImagePixelSize(for: uri)
    let thumbnailBase64 = isVideo ? localVideoThumbnailBase64(for: uri) : nil
    let effectiveText = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    inputBar?.dismissReplyBanner(animated: false)
    if let transitionPayload = makeAttachmentSendTransitionPayload(
      messageId: messageId,
      text: effectiveText,
      timestamp: timestamp,
      transitionCapture: transitionCapture
    ) {
      hiddenMessageId = messageId
      pendingSendTransition = transitionPayload
    }

    queueNativeOutgoingMediaMessage(
      messageId: messageId,
      type: type,
      localUri: uri,
      caption: effectiveText.isEmpty ? nil : effectiveText,
      timestamp: timestamp,
      timestampMs: timestampMs,
      fileName: fileName,
      fileSize: fileSize,
      duration: duration,
      mediaSize: mediaSize,
      thumbnailBase64: thumbnailBase64,
      replyToId: replyToMessageId
    )

    if pendingSendTransition == nil {
      DispatchQueue.main.async { [weak self] in
        self?.scrollToBottom(animated: true)
      }
    }

    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let myUserId = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let peerUserId = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let peerAgentId = enginePeerAgentId.trimmingCharacters(in: .whitespacesAndNewlines)
    if chatId.isEmpty {
      setNativeOutgoingMessageStatus(messageId, status: "error")
      return
    }

    var metadata: [String: Any] = ["mediaUrl": uri]
    if let fileName, !fileName.isEmpty { metadata["fileName"] = fileName }
    if let fileSize, fileSize > 0 { metadata["fileSize"] = fileSize }
    if let duration { metadata["duration"] = duration }
    if let mediaSize, mediaSize.width > 1.0, mediaSize.height > 1.0 {
      metadata["width"] = Int(mediaSize.width)
      metadata["height"] = Int(mediaSize.height)
    }
    if let thumbnailBase64, !thumbnailBase64.isEmpty {
      metadata["thumbnailBase64"] = thumbnailBase64
    }

    let sendPayload: [String: Any] = [
      "chatId": chatId,
      "messageId": messageId,
      "type": type,
      "text": effectiveText,
      "timestampMs": timestampMs,
      "replyToId": replyToMessageId as Any,
      "metadata": metadata,
      "myUserId": myUserId,
      "peerUserId": peerUserId,
      "peerAgentId": peerAgentId,
      "isGroup": isGroupOrChannel,
    ]

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = ChatEngine.shared.sendMessage(sendPayload)
      let accepted = (result["accepted"] as? Bool) == true
      let resolvedStatus: String = {
        if let stateValue = result["state"] as? String {
          let normalized = stateValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          if normalized == "error" || normalized == "pending" || normalized == "sent"
            || normalized == "delivered" || normalized == "read"
          {
            return normalized
          }
        }
        return accepted ? "sent" : "error"
      }()
      DispatchQueue.main.async {
        self?.setNativeOutgoingMessageStatus(messageId, status: resolvedStatus)
      }
    }
  }

  private func handleNativeAudioFileSend(uri: String, displayName: String?) {
    let messageId = UUID().uuidString.lowercased()
    let now = Date()
    let timestampMs = now.timeIntervalSince1970 * 1000
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let timestamp = formatter.string(from: now)
    let replyToMessageId = inputBar?.activeReplyToMessageId
    let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName =
      trimmedDisplayName?.isEmpty == false ? trimmedDisplayName : localAttachmentFileName(for: uri)
    let fileSize = localAttachmentFileSize(for: uri)
    let duration = localMediaDurationSeconds(for: uri)
    let thumbnailBase64 = localAudioThumbnailBase64(for: uri)

    inputBar?.dismissReplyBanner(animated: false)

    queueNativeOutgoingMediaMessage(
      messageId: messageId,
      type: "music",
      localUri: uri,
      caption: nil,
      timestamp: timestamp,
      timestampMs: timestampMs,
      fileName: fileName,
      fileSize: fileSize,
      duration: duration,
      thumbnailBase64: thumbnailBase64,
      replyToId: replyToMessageId
    )

    DispatchQueue.main.async { [weak self] in
      self?.scrollToBottom(animated: true)
    }

    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let myUserId = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let peerUserId = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let peerAgentId = enginePeerAgentId.trimmingCharacters(in: .whitespacesAndNewlines)
    if chatId.isEmpty {
      setNativeOutgoingMessageStatus(messageId, status: "error")
      return
    }

    var metadata: [String: Any] = ["mediaUrl": uri]
    if let fileName, !fileName.isEmpty { metadata["fileName"] = fileName }
    if let fileSize, fileSize > 0 { metadata["fileSize"] = fileSize }
    if let duration { metadata["duration"] = duration }
    if let thumbnailBase64, !thumbnailBase64.isEmpty {
      metadata["thumbnailBase64"] = thumbnailBase64
    }

    let sendPayload: [String: Any] = [
      "chatId": chatId,
      "messageId": messageId,
      "type": "music",
      "text": "",
      "timestampMs": timestampMs,
      "replyToId": replyToMessageId as Any,
      "metadata": metadata,
      "myUserId": myUserId,
      "peerUserId": peerUserId,
      "peerAgentId": peerAgentId,
      "isGroup": isGroupOrChannel,
    ]

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = ChatEngine.shared.sendMessage(sendPayload)
      let accepted = (result["accepted"] as? Bool) == true
      let resolvedStatus: String = {
        if let stateValue = result["state"] as? String {
          let normalized = stateValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          if normalized == "error" || normalized == "pending" || normalized == "sent"
            || normalized == "delivered" || normalized == "read"
          {
            return normalized
          }
        }
        return accepted ? "sent" : "error"
      }()
      DispatchQueue.main.async {
        self?.setNativeOutgoingMessageStatus(messageId, status: resolvedStatus)
      }
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

  @objc private func handleAgentCodeBlockExpanded(_ notification: Notification) {
    guard window != nil else {
      flowLayout.invalidateLayout()
      return
    }

    let distanceFromBottom = currentDistanceFromBottom()
    flowLayout.invalidateLayout()
    collectionView.performBatchUpdates(nil) { [weak self] _ in
      self?.restoreStationaryDistance(distanceFromBottom)
    }
  }

  private func resolvedMediaPreviewHeaderTitle(for row: ChatListRow?) -> String {
    if row?.isMe == true {
      return "You"
    }
    let peerDisplayName = enginePeerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !peerDisplayName.isEmpty {
      return peerDisplayName
    }
    let peerUserId = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let myUserId = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    if !peerUserId.isEmpty,
      myUserId.isEmpty || peerUserId.caseInsensitiveCompare(myUserId) != .orderedSame
    {
      return peerUserId
    }
    return "User"
  }

  private func normalizedMediaExtension(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let ext: String
    if let url = URL(string: trimmed), !url.pathExtension.isEmpty {
      ext = url.pathExtension
    } else {
      ext = (trimmed as NSString).pathExtension
    }
    let normalized = ext.replacingOccurrences(of: ".", with: "").lowercased()
    return normalized.isEmpty ? nil : normalized
  }

  private func isVideoMediaExtension(_ value: String?) -> Bool {
    guard let ext = normalizedMediaExtension(value) else { return false }
    return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
  }

  private func isAudioMediaExtension(_ value: String?) -> Bool {
    guard let ext = normalizedMediaExtension(value) else { return false }
    return ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "oga", "opus", "caf", "alac"]
      .contains(ext)
  }

  private func rowRepresentsVideoMedia(_ row: ChatListRow) -> Bool {
    if row.visualKind == .video || row.visualKind == .videoNote {
      return true
    }
    let candidates = [
      row.fileName,
      row.mediaUrl,
      row.localMediaUrl,
    ]
    return candidates.contains(where: isVideoMediaExtension)
  }

  private func shouldAutoDownloadRemoteMedia(for row: ChatListRow) -> Bool {
    switch row.visualKind {
    case .video, .videoNote:
      return true
    case .media:
      return row.messageType != "file"
    case .text, .voice, .sticker:
      return false
    }
  }

  private func scheduleVisibleAutoDownloads() {
    visibleAutoDownloadWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.runVisibleAutoDownloads()
    }
    visibleAutoDownloadWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: workItem)
  }

  private func runVisibleAutoDownloads() {
    visibleAutoDownloadWorkItem?.cancel()
    visibleAutoDownloadWorkItem = nil
    let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
    for indexPath in visibleIndexPaths where indexPath.item < rows.count {
      scheduleAutoRemoteMediaDownloadIfNeeded(for: rows[indexPath.item])
    }
  }

  private func visibleIndexPaths(for row: ChatListRow) -> [IndexPath] {
    collectionView.indexPathsForVisibleItems.filter { indexPath in
      guard indexPath.item < rows.count else { return false }
      let visibleRow = rows[indexPath.item]
      if let messageId = row.messageId, !messageId.isEmpty {
        return visibleRow.messageId == messageId
      }
      if visibleRow.key == row.key {
        return true
      }
      if let mediaURL = row.mediaUrl, !mediaURL.isEmpty {
        return visibleRow.mediaUrl == mediaURL
      }
      return false
    }
  }

  private func updateVisibleMediaDownloadState(for row: ChatListRow, reloadCell: Bool = false) {
    let targetIndexPaths = visibleIndexPaths(for: row)
    guard !targetIndexPaths.isEmpty else { return }

    if reloadCell {
      collectionView.reloadItems(at: targetIndexPaths)
      return
    }

    let state = remoteMediaDownloadState(for: row)
    for indexPath in targetIndexPaths {
      guard let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell else { continue }
      cell.applyMediaDownloadState(
        needsDownload: state.needsDownload,
        isDownloading: state.isDownloading,
        progress: state.progress
      )
    }
  }

  private func scheduleAutoRemoteMediaDownloadIfNeeded(for row: ChatListRow) {
    guard shouldAutoDownloadRemoteMedia(for: row) else {
      if rowRepresentsVideoMedia(row) {
        chatListDebugLog(
          chatListInlineVideoVerboseDebugLogs,
          "[ChatInlineVideoList] autoDownload skip=policy msgId=%@",
          row.messageId ?? "-"
        )
      }
      return
    }
    let downloadState = remoteMediaDownloadState(for: row)
    guard downloadState.needsDownload, !downloadState.isDownloading else {
      if rowRepresentsVideoMedia(row) {
        chatListDebugLog(
          chatListInlineVideoVerboseDebugLogs,
          "[ChatInlineVideoList] autoDownload skip=state msgId=%@ needsDownload=%@ downloading=%@ progress=%.3f",
          row.messageId ?? "-",
          downloadState.needsDownload ? "Y" : "N",
          downloadState.isDownloading ? "Y" : "N",
          downloadState.progress ?? -1.0
        )
      }
      return
    }
    if rowRepresentsVideoMedia(row) {
      chatListDebugLog(
        chatListInlineVideoVerboseDebugLogs,
        "[ChatInlineVideoList] autoDownload start msgId=%@ remote=%@",
        row.messageId ?? "-",
        row.mediaUrl ?? "nil"
      )
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let refreshedState = self.remoteMediaDownloadState(for: row)
      guard refreshedState.needsDownload, !refreshedState.isDownloading else { return }
      self.startRemoteMediaDownload(for: row, presentOnComplete: false)
    }
  }

  private func mediaRequiresLocalDownload(_ row: ChatListRow) -> Bool {
    let trimmedKey = resolvedMediaKey(for: row) ?? ""
    return !trimmedKey.isEmpty
  }

  private func localFileURL(from raw: String?) -> URL? {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let parsed = URL(string: trimmed), parsed.isFileURL {
      return parsed
    }
    if trimmed.hasPrefix("/") {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }

  private func localFileSize(at url: URL) -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
  }

  private func localVideoHeaderData(url: URL, maxCount: Int = 64) -> Data? {
    guard
      let handle = try? FileHandle(forReadingFrom: url),
      let headerData = try? handle.read(upToCount: maxCount)
    else {
      return nil
    }
    defer {
      try? handle.close()
    }
    return headerData
  }

  private func localVideoHeaderSummary(url: URL) -> String {
    guard let headerData = localVideoHeaderData(url: url), !headerData.isEmpty else {
      return "none"
    }
    let bytes = [UInt8](headerData.prefix(16))
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    var brand = "-"
    if headerData.count >= 12 {
      let brandData = headerData.subdata(in: 8..<12)
      brand = String(data: brandData, encoding: .ascii) ?? "-"
    }
    return "hex=\(hex) brand=\(brand)"
  }

  private func hasRecognizableLocalVideoContainerHeader(url: URL) -> Bool {
    guard let headerData = localVideoHeaderData(url: url) else { return false }
    guard headerData.count >= 12 else { return false }
    if headerData.count >= 8 {
      let ftypRange = 4..<(min(headerData.count, 32) - 3)
      if ftypRange.lowerBound < ftypRange.upperBound {
        for index in ftypRange {
          if headerData[index] == 0x66,
            headerData[index + 1] == 0x74,
            headerData[index + 2] == 0x79,
            headerData[index + 3] == 0x70
          {
            return true
          }
        }
      }
    }
    let headerPrefix = [UInt8](headerData.prefix(4))
    if headerPrefix == [0x1A, 0x45, 0xDF, 0xA3] {
      return true
    }
    return false
  }

  private func isUsableLocalVideoPreview(url: URL, logContext: String) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let byteSize = localFileSize(at: url)
    guard byteSize > 0 else { return false }
    let asset = AVURLAsset(url: url)
    if asset.isPlayable || !asset.tracks(withMediaType: .video).isEmpty {
      return true
    }
    if hasRecognizableLocalVideoContainerHeader(url: url) {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaVideo] local accepted by header context=%@ path=%@ bytes=%lld playable=%@ header=%@",
        logContext,
        url.path,
        byteSize,
        asset.isPlayable ? "Y" : "N",
        localVideoHeaderSummary(url: url)
      )
      return true
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640.0, height: 640.0)
    do {
      _ = try generator.copyCGImage(at: .zero, actualTime: nil)
      return true
    } catch {
      NSLog(
        "[ChatMediaVideo] local unusable context=%@ path=%@ bytes=%lld error=%@ header=%@",
        logContext,
        url.path,
        byteSize,
        error.localizedDescription,
        localVideoHeaderSummary(url: url)
      )
      return false
    }
  }

  private func usableLocalMediaURL(
    from raw: String?,
    for row: ChatListRow,
    logContext: String,
    allowVideoPlaybackFallback: Bool = false
  ) -> URL? {
    guard let localURL = localFileURL(from: raw) else { return nil }
    guard FileManager.default.fileExists(atPath: localURL.path) else {
      NSLog(
        "[ChatMediaChoice] local missing context=%@ msgId=%@ path=%@ remote=%@",
        logContext,
        row.messageId ?? "-",
        localURL.path,
        row.mediaUrl ?? "-"
      )
      return nil
    }
    if rowRepresentsVideoMedia(row) {
      if isUsableLocalVideoPreview(url: localURL, logContext: logContext) {
        return localURL
      }
      if allowVideoPlaybackFallback {
        let byteSize = localFileSize(at: localURL)
        if byteSize > 1024 {
          chatListDebugLog(
            chatListMediaVerboseDebugLogs,
            "[ChatMediaVideo] local accepted by playback fallback context=%@ path=%@ bytes=%lld",
            logContext,
            localURL.path,
            byteSize
          )
          return localURL
        }
      }
      return nil
    }
    if row.visualKind == .media && UIImage(contentsOfFile: localURL.path) == nil {
      NSLog(
        "[ChatMediaChoice] local image unusable context=%@ msgId=%@ path=%@ bytes=%lld",
        logContext,
        row.messageId ?? "-",
        localURL.path,
        localFileSize(at: localURL)
      )
      return nil
    }
    return localURL
  }

  private func validatedCachedDownloadedMediaURL(
    remoteURL: URL,
    row: ChatListRow,
    logContext: String
  ) -> URL? {
    let mediaKey = resolvedMediaKey(for: row)
    guard
      let cachedURL = cachedDownloadedMediaURL(
        remoteURL: remoteURL,
        mediaKey: mediaKey,
        fileName: row.fileName
      )
    else {
      return nil
    }
    let allowVideoPlaybackFallback =
      rowRepresentsVideoMedia(row)
      && ((mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
    if usableLocalMediaURL(
      from: cachedURL.absoluteString,
      for: row,
      logContext: logContext,
      allowVideoPlaybackFallback: allowVideoPlaybackFallback
    ) != nil {
      return cachedURL
    }
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    documentPreviewCacheByRemoteURL.removeValue(forKey: remoteKey)
    try? FileManager.default.removeItem(at: cachedURL)
    NSLog(
      "[ChatMediaChoice] cached invalid context=%@ msgId=%@ removed=%@ remote=%@ hasMediaKey=%@",
      logContext,
      row.messageId ?? "-",
      cachedURL.lastPathComponent,
      remoteURL.absoluteString,
      (mediaKey?.isEmpty == false) ? "Y" : "N"
    )
    return nil
  }

  private func remoteMediaCacheKey(remoteURL: URL, mediaKey: String?) -> String {
    let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return remoteURL.absoluteString + "|" + trimmedKey
  }

  private func persistedPreviewLocalURL(
    remoteURL: URL,
    mediaKey: String?,
    fileName: String?,
    response: URLResponse? = nil,
    tempURL: URL? = nil
  ) -> URL {
    let fileManager = FileManager.default
    let previewDir = fileManager.temporaryDirectory
      .appendingPathComponent("vibe-chat-preview-docs", isDirectory: true)
    try? fileManager.createDirectory(at: previewDir, withIntermediateDirectories: true)

    let preferredName =
      fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? fileName!
      : preferredDownloadFileName(remoteURL: remoteURL, response: response)
    let fallbackTempURL = tempURL ?? remoteURL
    let preferredExtension = preferredDownloadFileExtension(
      remoteURL: remoteURL,
      response: response,
      fallbackName: preferredName,
      tempURL: fallbackTempURL
    )
    let fileBaseName =
      preferredName
      .replacingOccurrences(of: "\\.[A-Za-z0-9]{1,12}$", with: "", options: .regularExpression)
    let safeBase =
      (fileBaseName.isEmpty ? "document" : fileBaseName)
      .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    let hashComponent = String(format: "%016llx", UInt64(bitPattern: Int64(remoteKey.hashValue)))
    let destinationName =
      "\(safeBase)-\(hashComponent)\(preferredExtension.isEmpty ? "" : ".\(preferredExtension)")"
    return previewDir.appendingPathComponent(destinationName, isDirectory: false)
  }

  private func cachedDownloadedMediaURL(
    remoteURL: URL,
    mediaKey: String?,
    fileName: String?
  ) -> URL? {
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    if let cachedURL = documentPreviewCacheByRemoteURL[remoteKey],
      FileManager.default.fileExists(atPath: cachedURL.path)
    {
      return cachedURL
    }
    let persistedURL = persistedPreviewLocalURL(
      remoteURL: remoteURL,
      mediaKey: mediaKey,
      fileName: fileName
    )
    guard FileManager.default.fileExists(atPath: persistedURL.path) else {
      return nil
    }
    documentPreviewCacheByRemoteURL[remoteKey] = persistedURL
    return persistedURL
  }

  private func remoteMediaDownloadState(for row: ChatListRow) -> (
    needsDownload: Bool, isDownloading: Bool, progress: Double?
  ) {
    guard row.visualKind == .media || row.visualKind == .video || row.visualKind == .videoNote,
      let mediaURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      let remoteURL = URL(string: mediaURL),
      let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      return (false, false, nil)
    }

    let mediaKey = resolvedMediaKey(for: row)
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    let shouldShowDownloadState =
      mediaRequiresLocalDownload(row)
      || shouldAutoDownloadRemoteMedia(for: row)
      || onDemandRemoteMediaDownloadKeys.contains(remoteKey)
    guard shouldShowDownloadState else {
      return (false, false, nil)
    }

    if usableLocalMediaURL(from: row.localMediaUrl, for: row, logContext: "download_state.local")
      != nil
    {
      return (false, false, nil)
    }

    if validatedCachedDownloadedMediaURL(
      remoteURL: remoteURL,
      row: row,
      logContext: "download_state.cached"
    ) != nil
    {
      return (false, false, nil)
    }

    let state = (
      true,
      documentPreviewInFlightURLs.contains(remoteKey),
      mediaDownloadProgressByRemoteKey[remoteKey]
    )
    chatListDebugLog(
      chatListMediaVerboseDebugLogs,
      "[ChatMediaDownload] state msgId=%@ needs=Y downloading=%@ progress=%.3f remote=%@ hasMediaKey=%@ localRaw=%@",
      row.messageId ?? "-",
      state.1 ? "Y" : "N",
      state.2 ?? -1.0,
      remoteURL.absoluteString,
      (mediaKey?.isEmpty == false) ? "Y" : "N",
      row.localMediaUrl ?? "nil"
    )
    return state
  }

  private func rowByApplyingLocalMediaURL(
    _ localMediaURL: String,
    toMessageId messageId: String,
    row: [String: Any]
  ) -> (changed: Bool, row: [String: Any]) {
    guard var message = row["message"] as? [String: Any],
      let currentId = (message["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      currentId == messageId
    else {
      return (false, row)
    }
    let currentLocalMediaURL =
      (message["localMediaUrl"] as? String)
      ?? (message["metadata"] as? [String: Any])?["localMediaUrl"] as? String
    if currentLocalMediaURL == localMediaURL {
      return (false, row)
    }
    message["localMediaUrl"] = localMediaURL
    var metadata = (message["metadata"] as? [String: Any]) ?? [:]
    metadata["localMediaUrl"] = localMediaURL
    message["metadata"] = metadata
    var patched = row
    patched["message"] = message
    return (true, patched)
  }

  private func cacheDownloadedMediaURL(_ localURL: URL, for row: ChatListRow) {
    guard let messageId = row.messageId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !messageId.isEmpty
    else {
      return
    }
    let localValue = localURL.absoluteString
    if !sourceRowsPayload.isEmpty {
      sourceRowsPayload = sourceRowsPayload.map { rowPayload in
        rowByApplyingLocalMediaURL(localValue, toMessageId: messageId, row: rowPayload).row
      }
    }
    if let rowPayload = nativeOutgoingRowsById[messageId] {
      nativeOutgoingRowsById[messageId] =
        rowByApplyingLocalMediaURL(localValue, toMessageId: messageId, row: rowPayload).row
    }
    if let rowPayload = nativeEngineRowsById[messageId] {
      nativeEngineRowsById[messageId] =
        rowByApplyingLocalMediaURL(localValue, toMessageId: messageId, row: rowPayload).row
    }
  }

  private func resolvedPreferredMediaURL(for row: ChatListRow) -> String? {
    if let localURL = usableLocalMediaURL(
      from: row.localMediaUrl,
      for: row,
      logContext: "resolved.local"
    ) {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaChoice] resolved local msgId=%@ path=%@",
        row.messageId ?? "-",
        localURL.path
      )
      return localURL.absoluteString
    }
    if let remoteMediaURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      let remoteURL = URL(string: remoteMediaURL),
      let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let cachedURL = validatedCachedDownloadedMediaURL(
        remoteURL: remoteURL,
        row: row,
        logContext: "resolved.cached"
      )
    {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaChoice] resolved cached msgId=%@ path=%@ remote=%@",
        row.messageId ?? "-",
        cachedURL.path,
        remoteMediaURL
      )
      return cachedURL.absoluteString
    }
    if let remote = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty {
      let mediaKey = resolvedMediaKey(for: row)
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaChoice] resolved remote msgId=%@ remote=%@ hasMediaKey=%@",
        row.messageId ?? "-",
        remote,
        (mediaKey?.isEmpty == false) ? "Y" : "N"
      )
    }
    return row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func presentImageEditView(for row: ChatListRow, mediaURL: String, seedImage: UIImage?) {
    guard let presenter = topPresentingViewController() else { return }
    ChatImageEditModule.presentEditor(
      from: presenter,
      messageId: row.messageId,
      mediaURL: mediaURL,
      initialImage: seedImage,
      initialCaption: row.text,
      headerTitle: resolvedMediaPreviewHeaderTitle(for: row)
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

      if payload.eventType == .reply {
        self.showReplyBanner(for: row, fallbackText: "Photo")
      }
    }
  }

  private func showReplyBanner(for row: ChatListRow, fallbackText: String) {
    guard let inputBar = inputBar, let messageId = row.messageId else { return }
    let preview = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
    inputBar.showReplyBanner(
      messageId: messageId,
      text: preview.isEmpty ? fallbackText : preview,
      isMe: row.isMe
    )
  }

  private func startRemoteMediaDownload(for row: ChatListRow, presentOnComplete: Bool) {
    guard let mediaURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      let remoteURL = URL(string: mediaURL),
      let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      return
    }

    let mediaKey = resolvedMediaKey(for: row)
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    let shouldTrackOnDemandState =
      !mediaRequiresLocalDownload(row) && presentOnComplete

    if let cachedURL = validatedCachedDownloadedMediaURL(
      remoteURL: remoteURL,
      row: row,
      logContext: "download_start.cached"
    ) {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaDownload] reuse cached msgId=%@ remote=%@ path=%@",
        row.messageId ?? "-",
        remoteURL.absoluteString,
        cachedURL.path
      )
      cacheDownloadedMediaURL(cachedURL, for: row)
      onDemandRemoteMediaDownloadKeys.remove(remoteKey)
      updateVisibleMediaDownloadState(for: row, reloadCell: true)
      if presentOnComplete {
        openDocumentInApp(
          urlString: cachedURL.absoluteString,
          mediaKey: nil,
          fileName: row.fileName,
          row: row
        )
      }
      return
    }

    guard !documentPreviewInFlightURLs.contains(remoteKey) else { return }
    documentPreviewInFlightURLs.insert(remoteKey)
    if shouldTrackOnDemandState {
      onDemandRemoteMediaDownloadKeys.insert(remoteKey)
    }
    mediaDownloadProgressByRemoteKey[remoteKey] = 0.027
    chatListDebugLog(
      chatListMediaVerboseDebugLogs,
      "[ChatMediaDownload] start msgId=%@ remote=%@ hasMediaKey=%@ onDemand=%@ fileName=%@",
      row.messageId ?? "-",
      remoteURL.absoluteString,
      (mediaKey?.isEmpty == false) ? "Y" : "N",
      shouldTrackOnDemandState ? "Y" : "N",
      row.fileName ?? "-"
    )
    updateVisibleMediaDownloadState(for: row)

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
        error: error,
        mediaKey: mediaKey,
        originalFileName: row.fileName
      )
      DispatchQueue.main.async {
        self.documentPreviewInFlightURLs.remove(remoteKey)
        self.onDemandRemoteMediaDownloadKeys.remove(remoteKey)
        self.mediaDownloadObservations.removeValue(forKey: remoteKey)?.invalidate()
        self.mediaDownloadProgressByRemoteKey.removeValue(forKey: remoteKey)
        self.mediaDownloadTasks.removeValue(forKey: remoteKey)
        if let localURL,
          self.usableLocalMediaURL(
            from: localURL.absoluteString,
            for: row,
            logContext: "download_complete",
            allowVideoPlaybackFallback: self.rowRepresentsVideoMedia(row)
              && ((mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
          ) != nil
        {
          self.documentPreviewCacheByRemoteURL[remoteKey] = localURL
          self.cacheDownloadedMediaURL(localURL, for: row)
          self.updateVisibleMediaDownloadState(for: row, reloadCell: true)
          chatListDebugLog(
            chatListMediaVerboseDebugLogs,
            "[ChatMediaDownload] ready msgId=%@ remote=%@ local=%@ bytes=%lld",
            row.messageId ?? "-",
            remoteURL.absoluteString,
            localURL.path,
            self.localFileSize(at: localURL)
          )
          if presentOnComplete {
            self.openDocumentInApp(
              urlString: localURL.absoluteString,
              mediaKey: nil,
              fileName: row.fileName,
              row: row
            )
          }
        } else {
          if let localURL {
            NSLog(
              "[ChatMediaDownload] invalid local after download msgId=%@ remote=%@ local=%@ hasMediaKey=%@",
              row.messageId ?? "-",
              remoteURL.absoluteString,
              localURL.path,
              (mediaKey?.isEmpty == false) ? "Y" : "N"
            )
            try? FileManager.default.removeItem(at: localURL)
          }
          self.updateVisibleMediaDownloadState(for: row)
          NSLog("[ChatListView] remote media download failed url=%@", remoteURL.absoluteString)
        }
      }
    }

    mediaDownloadObservations[remoteKey] = task.progress.observe(
      \.fractionCompleted,
      options: [.initial, .new]
    ) { [weak self] progress, _ in
      guard let self else { return }
      let value = max(0.027, min(1.0, progress.fractionCompleted))
      DispatchQueue.main.async {
        let previous = self.mediaDownloadProgressByRemoteKey[remoteKey] ?? 0.0
        if abs(previous - value) < 0.01 {
          return
        }
        self.mediaDownloadProgressByRemoteKey[remoteKey] = value
        self.updateVisibleMediaDownloadState(for: row)
      }
    }
    mediaDownloadTasks[remoteKey] = task
    task.resume()
  }

  private func openDocumentInApp(row: ChatListRow) {
    // Stream unencrypted remote audio directly via AVPlayer.
    // AVPlayer performs progressive HTTP buffering so playback starts after the
    // first few seconds of data arrive, not after the full file is downloaded.
    let audioMediaKey = resolvedMediaKey(for: row)
    let noEncryptionKey = audioMediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    if noEncryptionKey,
       row.visualKind != .voice,
       let rawAudioURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
       isAudioAttachmentURI(rawAudioURL, fileNameHint: row.fileName),
       let remoteAudioURL = URL(string: rawAudioURL),
       ["http", "https"].contains(remoteAudioURL.scheme?.lowercased() ?? ""),
       let presenter = topPresentingViewController()
    {
      NSLog(
        "[ChatListView] streamAudio progressive msgId=%@ remote=%@",
        row.messageId ?? "-",
        remoteAudioURL.absoluteString
      )
      let player = AVPlayer(url: remoteAudioURL)
      let playerVC = AVPlayerViewController()
      playerVC.player = player
      presenter.present(playerVC, animated: true) {
        player.play()
      }
      return
    }

    let downloadState = remoteMediaDownloadState(for: row)
    if downloadState.needsDownload {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaOpen] redirect to download msgId=%@ remote=%@ downloading=%@ progress=%.3f",
        row.messageId ?? "-",
        row.mediaUrl ?? "-",
        downloadState.isDownloading ? "Y" : "N",
        downloadState.progress ?? -1.0
      )
      startRemoteMediaDownload(for: row, presentOnComplete: true)
      return
    }
    guard let urlString = resolvedPreferredMediaURL(for: row), !urlString.isEmpty else { return }
    let mediaKey = resolvedMediaKey(for: row)
    if rowRepresentsVideoMedia(row),
      let presenter = topPresentingViewController(),
      let resolvedURL = URL(string: urlString),
      let scheme = resolvedURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      ((mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
    {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaOpen] remote video streaming msgId=%@ remote=%@ header=%@",
        row.messageId ?? "-",
        resolvedURL.absoluteString,
        resolvedMediaPreviewHeaderTitle(for: row)
      )
      let asset = AVURLAsset(
        url: resolvedURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
      )
      ChatVideoEditModule.presentPreview(
        from: presenter,
        asset: asset,
        initialCaption: row.text,
        headerTitle: resolvedMediaPreviewHeaderTitle(for: row),
        onReply: { [weak self] in
          self?.showReplyBanner(for: row, fallbackText: "Video")
        }
      )
      return
    }
    chatListDebugLog(
      chatListMediaVerboseDebugLogs,
      "[ChatMediaOpen] open msgId=%@ resolved=%@ remote=%@ local=%@",
      row.messageId ?? "-",
      urlString,
      row.mediaUrl ?? "-",
      row.localMediaUrl ?? "-"
    )
    openDocumentInApp(
      urlString: urlString,
      mediaKey: mediaKey,
      fileName: row.fileName,
      row: row
    )
  }

  private func openDocumentInApp(
    urlString: String,
    mediaKey: String? = nil,
    fileName: String? = nil,
    row: ChatListRow? = nil
  ) {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let resolved = ChatEngine.shared.resolveURLForOpen(trimmed) ?? trimmed
    if let remoteURL = URL(string: resolved), let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      let effectiveMediaKey = mediaKey ?? row.flatMap { resolvedMediaKey(for: $0) }
      openRemoteDocumentInPreview(
        remoteURL: remoteURL,
        fallbackURL: resolved,
        mediaKey: effectiveMediaKey,
        fileName: fileName,
        row: row
      )
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
      presentDocumentPreview(localURL: localURL, row: row)
      return
    }

    NSLog("[ChatListView] openDocumentInApp unsupported url=%@", resolved)
  }

  private func presentDocumentPreview(localURL: URL, row: ChatListRow? = nil) {
    guard let presenter = topPresentingViewController() else {
      NSLog(
        "[ChatListView] presentDocumentPreview skipped - presenter unavailable for %@",
        localURL.path)
      return
    }

    if presentVideoPreviewIfSupported(localURL: localURL, presenter: presenter, row: row) {
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

  private func presentVideoPreviewIfSupported(
    localURL: URL,
    presenter: UIViewController,
    row: ChatListRow?
  ) -> Bool {
    let ext = localURL.pathExtension.lowercased()
    let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    guard videoExtensions.contains(ext) else { return false }
    let byteSize = localFileSize(at: localURL)
    guard byteSize > 0 else {
      NSLog(
        "[ChatListView] presentVideoPreview skipped empty local path=%@ ext=%@ bytes=%lld",
        localURL.path,
        ext,
        byteSize
      )
      return false
    }
    if !isUsableLocalVideoPreview(url: localURL, logContext: "present_video") {
      NSLog(
        "[ChatListView] presentVideoPreview continuing despite preview validation failure path=%@ ext=%@ bytes=%lld header=%@",
        localURL.path,
        ext,
        byteSize,
        localVideoHeaderSummary(url: localURL)
      )
    }

    let asset = AVURLAsset(
      url: localURL,
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
    )
    NSLog(
      "[ChatListView] presentVideoPreview module path=%@ ext=%@ bytes=%lld header=%@ caption=%@",
      localURL.lastPathComponent,
      ext,
      byteSize,
      localVideoHeaderSummary(url: localURL),
      row?.text ?? ""
    )
    ChatVideoEditModule.presentPreview(
      from: presenter,
      asset: asset,
      initialCaption: row?.text,
      headerTitle: resolvedMediaPreviewHeaderTitle(for: row),
      onReply: { [weak self] in
        guard let self, let row else { return }
        self.showReplyBanner(for: row, fallbackText: "Video")
      }
    )
    return true
  }

  private func openRemoteDocumentInPreview(
    remoteURL: URL,
    fallbackURL: String,
    mediaKey: String?,
    fileName: String?,
    row: ChatListRow?
  ) {
    guard topPresentingViewController() != nil else {
      NSLog(
        "[ChatListView] openRemoteDocumentInPreview skipped - presenter unavailable for %@",
        fallbackURL)
      return
    }

    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    if let cachedURL = cachedDownloadedMediaURL(
      remoteURL: remoteURL,
      mediaKey: mediaKey,
      fileName: fileName
    )
    {
      presentDocumentPreview(localURL: cachedURL, row: row)
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
        error: error,
        mediaKey: mediaKey,
        originalFileName: fileName
      )
      DispatchQueue.main.async {
        self.documentPreviewInFlightURLs.remove(remoteKey)
        if let localURL {
          self.documentPreviewCacheByRemoteURL[remoteKey] = localURL
          self.presentDocumentPreview(localURL: localURL, row: row)
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
    error: Error?,
    mediaKey: String?,
    originalFileName: String?
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

    let destinationURL = persistedPreviewLocalURL(
      remoteURL: remoteURL,
      mediaKey: mediaKey,
      fileName: originalFileName,
      response: response,
      tempURL: tempURL
    )

    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
      }
      let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmedKey.isEmpty {
        let encryptedData = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
        guard let decryptedData = ChatEngine.shared.decryptMediaDataIfNeeded(encryptedData, mediaKey: trimmedKey)
        else {
          return nil
        }
        try decryptedData.write(to: destinationURL, options: [.atomic])
        try? fileManager.removeItem(at: tempURL)
      } else {
        try fileManager.moveItem(at: tempURL, to: destinationURL)
      }
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaDownload] persisted remote=%@ local=%@ mime=%@ suggested=%@ bytes=%lld hasMediaKey=%@ header=%@",
        remoteURL.absoluteString,
        destinationURL.path,
        response?.mimeType ?? "nil",
        response?.suggestedFilename ?? "nil",
        localFileSize(at: destinationURL),
        trimmedKey.isEmpty ? "N" : "Y",
        localVideoHeaderSummary(url: destinationURL)
      )
      return destinationURL
    } catch {
      do {
        let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedKey.isEmpty {
          let encryptedData = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
          guard let decryptedData = ChatEngine.shared.decryptMediaDataIfNeeded(encryptedData, mediaKey: trimmedKey)
          else {
            return nil
          }
          try decryptedData.write(to: destinationURL, options: [.atomic])
        } else {
          try fileManager.copyItem(at: tempURL, to: destinationURL)
        }
        chatListDebugLog(
          chatListMediaVerboseDebugLogs,
          "[ChatMediaDownload] persisted-copy remote=%@ local=%@ mime=%@ suggested=%@ bytes=%lld hasMediaKey=%@ header=%@",
          remoteURL.absoluteString,
          destinationURL.path,
          response?.mimeType ?? "nil",
          response?.suggestedFilename ?? "nil",
          localFileSize(at: destinationURL),
          trimmedKey.isEmpty ? "N" : "Y",
          localVideoHeaderSummary(url: destinationURL)
        )
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

  func inputBarDidSendWithStandaloneAgentMention(
    text: String,
    agentText: String,
    agentUsername: String
  ) {
    handleNativeSend(
      text: text,
      agentText: agentText,
      mentionedAgentUsername: agentUsername
    )
  }

  func inputBarDidRequestVibeAgentBuilder() {
    onNativeEvent(["type": "openVibeAgentBuilder"])
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

  func inputBarDidSelectImage(
    uri: String,
    caption: String?,
    transitionCapture: ChatAttachmentTransitionCapture?
  ) {
    if nativeSendEnabled {
      handleNativeAttachmentSend(
        uri: uri,
        caption: caption,
        transitionCapture: transitionCapture
      )
      return
    }
    var payload: [String: Any] = ["type": "attachmentImage", "uri": uri]
    if let caption = caption, !caption.isEmpty {
      payload["caption"] = caption
    }
    if isVideoAttachmentURI(uri) {
      if let duration = localMediaDurationSeconds(for: uri) {
        payload["duration"] = duration
      }
      if let fileName = localAttachmentFileName(for: uri), !fileName.isEmpty {
        payload["name"] = fileName
      }
      if let thumbnailBase64 = localVideoThumbnailBase64(for: uri), !thumbnailBase64.isEmpty {
        payload["thumbnailBase64"] = thumbnailBase64
      }
      // Extract natural video dimensions so the bubble sizes correctly.
      if let size = localVideoNaturalSize(for: uri) {
        payload["width"] = Int(size.width)
        payload["height"] = Int(size.height)
      }
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

  private func isVideoAttachmentURI(_ raw: String, fileNameHint: String? = nil) -> Bool {
    isVideoMediaExtension(fileNameHint) || isVideoMediaExtension(raw)
  }

  private func isAudioAttachmentURI(_ raw: String, fileNameHint: String? = nil) -> Bool {
    isAudioMediaExtension(fileNameHint) || isAudioMediaExtension(raw)
  }

  private func localAttachmentFileURL(for raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.isFileURL {
      return url
    }
    if trimmed.hasPrefix("/") {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }

  private func materializedLocalAttachmentURI(
    for raw: String,
    preferredFileName: String? = nil,
    logContext: String
  ) -> String? {
    guard let sourceURL = localAttachmentFileURL(for: raw) else { return nil }
    let normalizedURL = sourceURL.standardizedFileURL
    let normalizedPath = normalizedURL.path
    let homePath = NSHomeDirectory()
    if normalizedPath == homePath || normalizedPath.hasPrefix(homePath + "/") {
      return normalizedURL.absoluteString
    }

    let fileManager = FileManager.default
    let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let importDir = caches.appendingPathComponent("chat-local-attachments", isDirectory: true)
    do {
      try fileManager.createDirectory(at: importDir, withIntermediateDirectories: true)
    } catch {
      NSLog(
        "[ChatListView] local import create-dir failed context=%@ error=%@",
        logContext,
        error.localizedDescription
      )
      return nil
    }

    let preferredName = preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceName =
      preferredName?.isEmpty == false
      ? preferredName!
      : localAttachmentFileName(for: raw) ?? normalizedURL.lastPathComponent
    let baseName = (sourceName as NSString).deletingPathExtension
    let safeBase =
      (baseName.isEmpty ? "attachment" : baseName)
      .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    let ext = {
      let fromPreferred = (sourceName as NSString).pathExtension
      if !fromPreferred.isEmpty { return fromPreferred }
      return normalizedURL.pathExtension.isEmpty ? "dat" : normalizedURL.pathExtension
    }()
    let hashComponent = String(
      format: "%016llx", UInt64(bitPattern: Int64(normalizedURL.absoluteString.hashValue)))
    let destinationURL = importDir
      .appendingPathComponent("\(safeBase)-\(hashComponent)", isDirectory: false)
      .appendingPathExtension(ext)

    if fileManager.fileExists(atPath: destinationURL.path) {
      return destinationURL.absoluteString
    }

    let didAccessScopedResource = normalizedURL.startAccessingSecurityScopedResource()
    defer {
      if didAccessScopedResource {
        normalizedURL.stopAccessingSecurityScopedResource()
      }
    }

    var coordinationError: NSError?
    var copyError: Error?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(readingItemAt: normalizedURL, options: [], error: &coordinationError) {
      readableURL in
      do {
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        do {
          try fileManager.copyItem(at: readableURL, to: destinationURL)
        } catch {
          let data = try Data(contentsOf: readableURL, options: [.mappedIfSafe])
          try data.write(to: destinationURL, options: [.atomic])
        }
      } catch {
        copyError = error
      }
    }

    if let copyError {
      NSLog(
        "[ChatListView] local import failed context=%@ source=%@ error=%@",
        logContext,
        normalizedURL.path,
        copyError.localizedDescription
      )
    } else if let coordinationError {
      NSLog(
        "[ChatListView] local import coordination failed context=%@ source=%@ error=%@",
        logContext,
        normalizedURL.path,
        coordinationError.localizedDescription
      )
    }

    guard fileManager.fileExists(atPath: destinationURL.path) else {
      return nil
    }
    return destinationURL.absoluteString
  }

  private func localAttachmentFileName(for raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), !url.lastPathComponent.isEmpty {
      return url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    }
    let pathComponent = (trimmed as NSString).lastPathComponent
    return pathComponent.isEmpty ? nil : pathComponent
  }

  private func localAttachmentFileSize(for raw: String) -> Int64? {
    guard let fileURL = localAttachmentFileURL(for: raw) else { return nil }
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
      let size = attrs[.size] as? NSNumber
    else {
      return nil
    }
    let bytes = size.int64Value
    return bytes > 0 ? bytes : nil
  }

  private func localMediaDurationSeconds(for raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fileURL = localAttachmentFileURL(for: trimmed)
    guard let fileURL else { return nil }
    let duration = AVURLAsset(url: fileURL).duration.seconds
    guard duration.isFinite, duration > 0 else { return nil }
    return duration
  }

  private func localImagePixelSize(for raw: String) -> CGSize? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fileURL = localAttachmentFileURL(for: trimmed)
    guard let fileURL else { return nil }
    if let image = UIImage(contentsOfFile: fileURL.path) {
      return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }
    return nil
  }

  private func localVideoThumbnailImage(for raw: String, maxDimension: CGFloat = 480.0) -> UIImage? {
    guard let fileURL = localAttachmentFileURL(for: raw) else { return nil }
    let asset = AVURLAsset(url: fileURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
    let durationSeconds = asset.duration.seconds
    let safeDuration = durationSeconds.isFinite ? max(0.0, durationSeconds) : 0.0
    let candidateTimes: [Double] = [0.0, 0.04, 0.12, 0.24, 0.5, 1.0]
      .filter { safeDuration <= 0.01 || $0 <= safeDuration }
    for seconds in candidateTimes {
      do {
        let cgImage = try generator.copyCGImage(
          at: CMTime(seconds: seconds, preferredTimescale: 600),
          actualTime: nil
        )
        return UIImage(cgImage: cgImage)
      } catch {
        continue
      }
    }
    return nil
  }

  private func localVideoThumbnailBase64(for raw: String) -> String? {
    guard let thumbnailImage = localVideoThumbnailImage(for: raw) else {
      NSLog("[ChatVideoThumb] generation failed uri=%@", raw)
      return nil
    }
    let maxDimension: CGFloat = 480.0
    let imageSize = thumbnailImage.size
    let scaleRatio = min(
      1.0,
      min(
        maxDimension / max(1.0, imageSize.width),
        maxDimension / max(1.0, imageSize.height)
      )
    )
    let targetSize = CGSize(
      width: max(1.0, floor(imageSize.width * scaleRatio)),
      height: max(1.0, floor(imageSize.height * scaleRatio))
    )
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let renderedImage = renderer.image { _ in
      thumbnailImage.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    guard let jpegData = renderedImage.jpegData(compressionQuality: 0.72) else {
      NSLog("[ChatVideoThumb] jpeg encode failed uri=%@", raw)
      return nil
    }
    NSLog(
      "[ChatVideoThumb] generated uri=%@ bytes=%lu size=%@",
      raw,
      jpegData.count,
      NSCoder.string(for: CGRect(origin: .zero, size: targetSize))
    )
    return jpegData.base64EncodedString()
  }

  private func localAudioThumbnailBase64(for raw: String) -> String? {
    guard let fileURL = localAttachmentFileURL(for: raw) else { return nil }
    let asset = AVURLAsset(url: fileURL)
    let artworkData: Data? = asset.commonMetadata.first(where: { item in
      item.commonKey?.rawValue.lowercased() == "artwork"
    })?.dataValue
      ?? asset.commonMetadata.first(where: { item in
        item.commonKey?.rawValue.lowercased() == "artwork"
      })?.value as? Data
    guard let artworkData, let image = UIImage(data: artworkData) else { return nil }

    let maxDimension: CGFloat = 240.0
    let imageSize = image.size
    let scaleRatio = min(
      1.0,
      min(
        maxDimension / max(1.0, imageSize.width),
        maxDimension / max(1.0, imageSize.height)
      )
    )
    let targetSize = CGSize(
      width: max(1.0, floor(imageSize.width * scaleRatio)),
      height: max(1.0, floor(imageSize.height * scaleRatio))
    )
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let renderedImage = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    guard let jpegData = renderedImage.jpegData(compressionQuality: 0.72) else {
      return nil
    }
    return jpegData.base64EncodedString()
  }

  private func localVideoNaturalSize(for raw: String) -> CGSize? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fileURL = localAttachmentFileURL(for: trimmed)
    guard let fileURL else { return nil }
    let asset = AVURLAsset(url: fileURL)
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }
    let naturalSize = track.naturalSize
    // Apply the preferred transform to handle portrait videos correctly.
    let transformed = naturalSize.applying(track.preferredTransform)
    let w = abs(transformed.width)
    let h = abs(transformed.height)
    guard w > 1, h > 1 else { return nil }
    return CGSize(width: w, height: h)
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
    let effectiveURI =
      materializedLocalAttachmentURI(
        for: uri,
        preferredFileName: name,
        logContext: "document_picker"
      ) ?? uri

    if nativeSendEnabled, isAudioAttachmentURI(effectiveURI, fileNameHint: name) {
      handleNativeAudioFileSend(uri: effectiveURI, displayName: name)
      return
    }

    var payload: [String: Any] = ["type": "attachmentFile", "uri": effectiveURI, "name": name]
    if isAudioAttachmentURI(effectiveURI, fileNameHint: name) {
      if let duration = localMediaDurationSeconds(for: effectiveURI) {
        payload["duration"] = duration
      }
      if let thumbnailBase64 = localAudioThumbnailBase64(for: effectiveURI),
        !thumbnailBase64.isEmpty
      {
        payload["thumbnailBase64"] = thumbnailBase64
      }
      if let fileSize = localAttachmentFileSize(for: effectiveURI), fileSize > 0 {
        payload["fileSize"] = fileSize
      }
    }
    onNativeEvent(payload)
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
