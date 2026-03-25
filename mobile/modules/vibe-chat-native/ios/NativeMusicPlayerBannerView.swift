import UIKit

struct NativeMusicPlayerTheme {
  var isDark = true
  var surface = UIColor(white: 0.08, alpha: 1.0)
  var text = UIColor.white
  var secondaryText = UIColor(white: 1.0, alpha: 0.68)
  var primary = UIColor.systemBlue
}

private struct NativeMusicPlayerViewState {
  let currentTrack: NativeMusicPlayerTrack?
  let isPlaying: Bool
  let progressMs: Double
  let durationMs: Double
  let artworkImage: UIImage?

  static let empty = NativeMusicPlayerViewState(
    currentTrack: nil,
    isPlaying: false,
    progressMs: 0.0,
    durationMs: 0.0,
    artworkImage: nil
  )

  static func from(payload: [String: Any]) -> NativeMusicPlayerViewState {
    let currentTrack = (payload["currentTrack"] as? [String: Any]).flatMap(NativeMusicPlayerTrack.init)
    return NativeMusicPlayerViewState(
      currentTrack: currentTrack,
      isPlaying: (payload["isPlaying"] as? Bool) ?? false,
      progressMs: (payload["progress"] as? NSNumber)?.doubleValue ?? (payload["progress"] as? Double) ?? 0.0,
      durationMs: (payload["duration"] as? NSNumber)?.doubleValue ?? (payload["duration"] as? Double) ?? 0.0,
      artworkImage: nil
    )
  }

  static func from(voiceSnapshot: VoiceBubblePlaybackSnapshot) -> NativeMusicPlayerViewState {
    guard let messageId = voiceSnapshot.messageId else { return .empty }
    let durationMs = max(0.0, voiceSnapshot.duration * 1000.0)
    let progressMs = durationMs * max(0.0, min(1.0, Double(voiceSnapshot.progress)))
    let track = NativeMusicPlayerTrack(
      trackId: messageId,
      videoId: nil,
      id: messageId,
      source: "chat-music",
      title: voiceSnapshot.title ?? "Audio",
      artist: voiceSnapshot.subtitle ?? "Vibegram",
      album: nil,
      duration: nil,
      durationSeconds: voiceSnapshot.duration > 0.0 ? voiceSnapshot.duration : nil,
      cover: nil,
      previewURL: nil,
      streamURL: nil,
      localURI: nil,
      cachedAt: nil,
      playCount: 0,
      lastPlayedAt: nil,
      links: [:]
    )
    return NativeMusicPlayerViewState(
      currentTrack: track,
      isPlaying: voiceSnapshot.isPlaying,
      progressMs: progressMs,
      durationMs: durationMs,
      artworkImage: voiceSnapshot.artwork
    )
  }
}

// MARK: - Native Music Player Banner (Pill)
// This is strictly the floating pill banner. 
// It does NOT handle the expanded modal state itself.
final class NativeMusicPlayerBannerView: UIView, UIGestureRecognizerDelegate {
  static let miniHeight: CGFloat = 48.0

  private let miniBlurView = UIVisualEffectView(effect: nil)
  private let miniArtworkView = UIImageView()
  private let miniArtworkFallbackView = UIImageView()
  private let miniTitleLabel = UILabel()
  private let miniSubtitleLabel = UILabel()
  private let miniProgressTrackView = UIView()
  private let miniProgressFillView = UIView()
  private let miniProgressImageView = UIImageView()
  private let miniProgressBlurView = UIVisualEffectView(effect: nil)
  private let miniProgressTintView = UIView()
  private let miniPlayButton = UIButton(type: .system)
  private let miniCloseButton = UIButton(type: .system)
  private let miniTextTapTarget = UIControl()

  private var theme = NativeMusicPlayerTheme()
  private var state = NativeMusicPlayerViewState.empty
  private var topInset: CGFloat = 0.0
  private var coverImageTask: URLSessionDataTask?
  private var miniDragOffset = CGPoint.zero
  private var miniDragStartOffset = CGPoint.zero
  private var renderedCoverTrackId: String?
  private var renderedCoverURL: String?
  private var renderedArtworkIdentifier: ObjectIdentifier?

  private lazy var miniPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleMiniPan(_:)))

  var onTogglePlayback: (() -> Void)?
  var onClose: (() -> Void)?
  var onOpenModal: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false

    miniBlurView.layer.cornerCurve = .continuous
    miniBlurView.layer.cornerRadius = Self.miniHeight / 2.0
    miniBlurView.clipsToBounds = true
    addSubview(miniBlurView)

    miniArtworkView.contentMode = .scaleAspectFill
    miniArtworkView.clipsToBounds = true
    miniArtworkView.layer.cornerCurve = .continuous
    miniArtworkView.layer.cornerRadius = 14.0
    addSubview(miniArtworkView)

    miniArtworkFallbackView.contentMode = .scaleAspectFit
    miniArtworkFallbackView.image = UIImage(systemName: "music.note")
    addSubview(miniArtworkFallbackView)

    miniProgressTrackView.layer.cornerCurve = .continuous
    miniProgressTrackView.layer.cornerRadius = Self.miniHeight / 2.0
    miniProgressTrackView.clipsToBounds = true
    miniBlurView.contentView.addSubview(miniProgressTrackView)

    miniProgressImageView.contentMode = .scaleAspectFill
    miniProgressImageView.clipsToBounds = true
    miniProgressFillView.addSubview(miniProgressImageView)

    miniProgressBlurView.isUserInteractionEnabled = false
    miniProgressFillView.addSubview(miniProgressBlurView)

    miniProgressTintView.isUserInteractionEnabled = false
    miniProgressFillView.addSubview(miniProgressTintView)

    miniProgressFillView.layer.cornerCurve = .continuous
    miniProgressFillView.layer.cornerRadius = Self.miniHeight / 2.0
    miniProgressFillView.clipsToBounds = true
    miniProgressTrackView.addSubview(miniProgressFillView)

    miniTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    miniTitleLabel.numberOfLines = 1
    addSubview(miniTitleLabel)

    miniSubtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    miniSubtitleLabel.numberOfLines = 1
    addSubview(miniSubtitleLabel)

    miniPlayButton.addTarget(self, action: #selector(handleTogglePlayback), for: .touchUpInside)
    addSubview(miniPlayButton)

    miniCloseButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    addSubview(miniCloseButton)

    miniTextTapTarget.addTarget(self, action: #selector(handleOpenModalClick), for: .touchUpInside)
    miniTextTapTarget.addGestureRecognizer(miniPanGesture)
    addSubview(miniTextTapTarget)
    bringSubviewToFront(miniPlayButton)
    bringSubviewToFront(miniCloseButton)

    isHidden = true
    applyTheme(theme)
  }

  required init?(coder: NSCoder) { nil }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme
    applyGlassMaterial(to: miniBlurView, interactive: true)
    miniBlurView.contentView.backgroundColor = theme.surface.withAlphaComponent(theme.isDark ? 0.10 : 0.08)
    
    let secondaryAlpha: CGFloat = theme.isDark ? 0.72 : 0.62
    miniArtworkView.backgroundColor = theme.text.withAlphaComponent(theme.isDark ? 0.08 : 0.06)
    miniArtworkFallbackView.tintColor = theme.secondaryText
    miniTitleLabel.textColor = theme.text
    miniSubtitleLabel.textColor = theme.text.withAlphaComponent(secondaryAlpha)
    
    miniProgressTrackView.backgroundColor = .clear
    miniProgressFillView.backgroundColor = .clear
    applyGlassMaterial(to: miniProgressBlurView, interactive: false)
    miniProgressTintView.backgroundColor = theme.primary.withAlphaComponent(theme.isDark ? 0.38 : 0.32)
    miniPlayButton.tintColor = theme.text
    miniCloseButton.tintColor = theme.secondaryText
    
    applyMiniControlButtonStyle(button: miniPlayButton, systemName: state.isPlaying ? "pause.fill" : "play.fill")
    applyMiniControlButtonStyle(button: miniCloseButton, systemName: "xmark")
    
    setNeedsLayout()
  }

  func setTopInset(_ value: CGFloat) {
    if abs(topInset - value) <= 0.5 { return }
    topInset = value
    setNeedsLayout()
  }

  func applyStatePayload(_ payload: [String: Any]) {
    applyState(NativeMusicPlayerViewState.from(payload: payload))
  }

  func applyVoiceSnapshot(_ snapshot: VoiceBubblePlaybackSnapshot) {
    applyState(NativeMusicPlayerViewState.from(voiceSnapshot: snapshot))
  }

  private func applyState(_ nextState: NativeMusicPlayerViewState) {
    state = nextState
    let shouldShow = nextState.currentTrack != nil
    isHidden = !shouldShow
    guard shouldShow, let track = nextState.currentTrack else { return }

    miniTitleLabel.text = track.title
    miniSubtitleLabel.text = playbackDetailText(for: nextState, track: track)

    updateCoverImageIfNeeded(for: track, directImage: nextState.artworkImage)
    applyPlaybackButtons(for: nextState)

    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let collapsedY = max(12.0, topInset + 30.0)
    let collapsedInset: CGFloat = 16.0
    let collapsedWidth = bounds.width - (collapsedInset * 2.0)
    let baseMiniFrame = CGRect(
      x: collapsedInset,
      y: collapsedY,
      width: max(0.0, collapsedWidth),
      height: Self.miniHeight
    )
    
    miniDragOffset = clampedMiniOffset(miniDragOffset, for: baseMiniFrame)
    let miniFrame = baseMiniFrame.offsetBy(dx: miniDragOffset.x, dy: miniDragOffset.y)

    miniBlurView.frame = miniFrame
    miniProgressTrackView.frame = miniBlurView.bounds
    
    let duration = max(state.durationMs, (state.currentTrack?.durationSeconds ?? 0.0) * 1000.0, 1.0)
    let progress = CGFloat(max(0.0, min(1.0, state.progressMs / duration)))
    
    let miniProgressWidth = miniProgressTrackView.bounds.width * progress
    miniProgressFillView.frame = CGRect(
      x: 0.0,
      y: 0.0,
      width: max(0.0, min(miniProgressTrackView.bounds.width, miniProgressWidth)),
      height: miniProgressTrackView.bounds.height
    )
    miniProgressImageView.frame = miniProgressFillView.bounds
    miniProgressBlurView.frame = miniProgressFillView.bounds
    miniProgressTintView.frame = miniProgressFillView.bounds

    let artworkSide: CGFloat = 24.0
    miniArtworkView.frame = CGRect(
      x: miniFrame.minX + 12.0,
      y: miniFrame.minY + (miniFrame.height - artworkSide) / 2.0,
      width: artworkSide,
      height: artworkSide
    )
    miniArtworkFallbackView.frame = miniArtworkView.frame.insetBy(dx: 6.5, dy: 6.5)

    let controlSide: CGFloat = 24.0
    miniCloseButton.frame = CGRect(
      x: miniFrame.maxX - 10.0 - controlSide,
      y: miniFrame.midY - (controlSide * 0.5),
      width: controlSide,
      height: controlSide
    )
    miniPlayButton.frame = CGRect(
      x: miniCloseButton.frame.minX - 30.0,
      y: miniFrame.midY - (controlSide * 0.5),
      width: controlSide,
      height: controlSide
    )
    let textX = miniArtworkView.frame.maxX + 10.0
    let textRight = miniPlayButton.frame.minX - 10.0
    miniTitleLabel.frame = CGRect(
      x: textX,
      y: miniFrame.minY + 7.0,
      width: max(0.0, textRight - textX),
      height: 15.0
    )
    miniSubtitleLabel.frame = CGRect(
      x: textX,
      y: miniTitleLabel.frame.maxY + 1.0,
      width: miniTitleLabel.frame.width,
      height: 13.0
    )
    miniTextTapTarget.frame = miniFrame.insetBy(dx: 0, dy: 0)
  }

  func containsInteractivePoint(_ point: CGPoint) -> Bool {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return false }
    let hitInset: CGFloat = 10.0
    return miniBlurView.frame.insetBy(dx: -hitInset, dy: -hitInset).contains(point)
  }

  private func clampedMiniOffset(_ proposedOffset: CGPoint, for baseFrame: CGRect) -> CGPoint {
    let minX = -baseFrame.minX + 12.0
    let maxX = bounds.width - baseFrame.maxX - 12.0
    let minY = -baseFrame.minY + max(12.0, topInset + 10.0)
    let maxY = max(minY, bounds.height - baseFrame.maxY - 24.0)
    return CGPoint(
      x: min(max(proposedOffset.x, minX), maxX),
      y: min(max(proposedOffset.y, minY), maxY)
    )
  }

  @objc private func handleMiniPan(_ gesture: UIPanGestureRecognizer) {
    guard !isHidden else { return }
    let collapsedY = max(12.0, topInset + 30.0)
    let collapsedInset: CGFloat = 16.0
    let baseMiniFrame = CGRect(
      x: collapsedInset,
      y: collapsedY,
      width: max(0.0, bounds.width - (collapsedInset * 2.0)),
      height: Self.miniHeight
    )
    switch gesture.state {
    case .began: miniDragStartOffset = miniDragOffset
    case .changed, .ended:
      let t = gesture.translation(in: self)
      miniDragOffset = clampedMiniOffset(CGPoint(x: miniDragStartOffset.x + t.x, y: miniDragStartOffset.y + t.y), for: baseMiniFrame)
      setNeedsLayout()
    default: break
    }
  }

  @objc private func handleTogglePlayback() { onTogglePlayback?() }
  @objc private func handleClose() { onClose?() }
  @objc private func handleOpenModalClick() { onOpenModal?() }

  private func applyGlassMaterial(to blurView: UIVisualEffectView, interactive: Bool) {
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = interactive
      blurView.effect = glass
    } else {
      blurView.effect = UIBlurEffect(style: .systemMaterial)
    }
  }

  private func applyMiniControlButtonStyle(button: UIButton, systemName: String) {
    button.setImage(UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
  }

  private func updateCoverImageIfNeeded(for track: NativeMusicPlayerTrack, directImage: UIImage?) {
    let normalizedCoverURL = track.cover?.trimmingCharacters(in: .whitespacesAndNewlines)
    let imageIdentifier = directImage.map(ObjectIdentifier.init)
    guard
      renderedCoverTrackId != track.trackId
        || renderedCoverURL != normalizedCoverURL
        || renderedArtworkIdentifier != imageIdentifier
    else {
      return
    }

    renderedCoverTrackId = track.trackId
    renderedCoverURL = normalizedCoverURL
    renderedArtworkIdentifier = imageIdentifier
    updateCoverImage(urlString: normalizedCoverURL, directImage: directImage)
  }

  private func updateCoverImage(urlString: String?, directImage: UIImage?) {
    coverImageTask?.cancel()
    coverImageTask = nil
    if let directImage {
      miniArtworkView.image = directImage
      miniProgressImageView.image = directImage
      miniArtworkFallbackView.isHidden = true
      return
    }
    miniArtworkView.image = nil
    miniProgressImageView.image = nil
    miniArtworkFallbackView.isHidden = false
    guard let urlStr = urlString, let url = URL(string: urlStr) else { return }
    coverImageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        self.miniArtworkView.image = image
        self.miniProgressImageView.image = image
        self.miniArtworkFallbackView.isHidden = true
      }
    }
    coverImageTask?.resume()
  }

  private func playbackDetailText(for state: NativeMusicPlayerViewState, track: NativeMusicPlayerTrack) -> String {
    let dur = max(state.durationMs, (track.durationSeconds ?? 0.0) * 1000.0)
    if dur > 0 {
      return "\(NativeMusicPlayerModalView.format(ms: state.progressMs)) / \(NativeMusicPlayerModalView.format(ms: dur))"
    }
    return track.artist
  }

  private func applyPlaybackButtons(for state: NativeMusicPlayerViewState) {
    let name = state.isPlaying ? "pause.fill" : "play.fill"
    miniPlayButton.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
  }
}
