import ExpoModulesCore
import UIKit

final class NativeGlobalMusicPlayerView: ExpoView {
  private let bannerView = NativeMusicPlayerBannerView()
  private let modalView = NativeMusicPlayerModalView()
  
  private var stateObserver: NSObjectProtocol?
  private var voiceObserver: NSObjectProtocol?
  private var enginePayload: [String: Any] = NativeMusicPlayerEngine.shared.getStatePayload()
  private var voiceSnapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
  private var isDark = true
  private var surfaceColor = UIColor(white: 0.08, alpha: 1.0)
  private var textColor = UIColor.white
  private var textSecondaryColor = UIColor(white: 1.0, alpha: 0.68)
  private var primaryColor = UIColor.systemBlue
  private var topInset: CGFloat = 0.0

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = false
    backgroundColor = .clear

    addSubview(bannerView)

    setupBannerCallbacks()
    setupModalCallbacks()

    setupObservers()

    applyTheme()
    applyResolvedState()
  }

  deinit {
    if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    if let voiceObserver { NotificationCenter.default.removeObserver(voiceObserver) }
  }

  private func setupBannerCallbacks() {
    bannerView.onTogglePlayback = { [weak self] in self?.handleTogglePlayback() }
    bannerView.onClose = { [weak self] in self?.handleClose() }
    bannerView.onOpenModal = { [weak self] in self?.modalView.show() }
  }

  private func setupModalCallbacks() {
    modalView.onTogglePlayback = { [weak self] in self?.handleTogglePlayback() }
    modalView.onPlayNext = { [weak self] in self?.handleNext() }
    modalView.onPlayPrev = { [weak self] in self?.handlePrev() }
    modalView.onToggleQueueOrder = { [weak self] in self?.handleQueueOrderToggle() }
    modalView.onToggleRepeat = { [weak self] in self?.handleRepeatToggle() }
    modalView.onSeek = { [weak self] ms in self?.handleSeek(ms) }
    modalView.onSelectTrack = { [weak self] id in self?.handleSelectTrack(id) }
  }

  private func setupObservers() {
    stateObserver = NotificationCenter.default.addObserver(
      forName: .nativeMusicPlayerStateDidChange,
      object: NativeMusicPlayerEngine.shared,
      queue: .main
    ) { [weak self] notification in
      guard let payload = notification.userInfo?["payload"] as? [String: Any] else { return }
      self?.enginePayload = payload
      self?.applyResolvedState()
    }

    voiceObserver = NotificationCenter.default.addObserver(
      forName: .voiceBubblePlaybackDidChange,
      object: VoiceBubblePlaybackCoordinator.shared,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.voiceSnapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
      self.applyResolvedState()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    bannerView.frame = bounds
    bannerView.setTopInset(topInset)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    if modalView.presentingViewController != nil {
      return true
    }
    return bannerView.containsInteractivePoint(point)
  }

  // MARK: - Handlers

  private func handleTogglePlayback() {
    if shouldRenderVoiceSnapshot {
      VoiceBubblePlaybackCoordinator.shared.toggleCurrentPlayback()
      return
    }
    let engine = NativeMusicPlayerEngine.shared
    engine.setIsPlaying(!((engine.getStatePayload()["isPlaying"] as? Bool) ?? false))
  }

  private func handleClose() {
    if shouldRenderVoiceSnapshot {
      VoiceBubblePlaybackCoordinator.shared.stopCurrentPlayback()
      return
    }
    NativeMusicPlayerEngine.shared.reset()
  }

  private func handleNext() {
    if shouldRenderVoiceSnapshot {
      VoiceBubblePlaybackCoordinator.shared.playNextTrack()
      return
    }
    NativeMusicPlayerEngine.shared.playNext()
  }

  private func handlePrev() {
    if shouldRenderVoiceSnapshot {
      VoiceBubblePlaybackCoordinator.shared.playPreviousTrack()
      return
    }
    NativeMusicPlayerEngine.shared.playPrev()
  }

  private func handleRateToggle() {
    if shouldRenderVoiceSnapshot {
      VoiceBubblePlaybackCoordinator.shared.cyclePlaybackRate()
      return
    }
    let engine = NativeMusicPlayerEngine.shared
    let currentRate = (engine.getStatePayload()["playbackRate"] as? NSNumber)?.doubleValue ?? (engine.getStatePayload()["playbackRate"] as? Double) ?? 1.0
    let rates: [Double] = [1.0, 1.5, 2.0]
    let index = rates.firstIndex(where: { abs($0 - currentRate) < 0.05 }) ?? 0
    engine.setPlaybackRate(rates[(index + 1) % rates.count])
  }

  private func handleQueueOrderToggle() {
    if shouldRenderVoiceSnapshot {
      VoiceBubblePlaybackCoordinator.shared.toggleQueueOrderMode()
      return
    }
    NativeMusicPlayerEngine.shared.toggleQueueOrderMode()
  }

  private func handleRepeatToggle() {
    if shouldRenderVoiceSnapshot {
      VoiceBubblePlaybackCoordinator.shared.toggleRepeatEnabled()
      return
    }
    NativeMusicPlayerEngine.shared.toggleRepeatEnabled()
  }

  private func handleSeek(_ ms: Double) {
    if shouldRenderVoiceSnapshot {
      VoiceBubblePlaybackCoordinator.shared.seek(toSeconds: ms / 1000.0)
      return
    }
    NativeMusicPlayerEngine.shared.seek(toMilliseconds: ms)
  }

  private func handleSelectTrack(_ trackId: String) {
    if shouldRenderVoiceSnapshot {
      VoiceBubblePlaybackCoordinator.shared.selectQueuedTrack(trackId)
      return
    }
    NativeMusicPlayerEngine.shared.selectTrack(trackId)
  }

  // MARK: - Public API

  func setIsDark(_ value: Bool) {
    isDark = value
    applyTheme()
  }

  func setSurfaceColor(_ value: String?) {
    if let color = UIColor.nativeMusicColor(from: value) {
      surfaceColor = color
      applyTheme()
    }
  }

  func setTextColor(_ value: String?) {
    if let color = UIColor.nativeMusicColor(from: value) {
      textColor = color
      applyTheme()
    }
  }

  func setTextSecondaryColor(_ value: String?) {
    if let color = UIColor.nativeMusicColor(from: value) {
      textSecondaryColor = color
      applyTheme()
    }
  }

  func setPrimaryColor(_ value: String?) {
    if let color = UIColor.nativeMusicColor(from: value) {
      primaryColor = color
      applyTheme()
    }
  }

  func setTopInset(_ value: Double) {
    topInset = CGFloat(value)
    setNeedsLayout()
  }

  private func applyTheme() {
    let nativeTheme = NativeMusicPlayerTheme(
      isDark: isDark,
      surface: surfaceColor,
      text: textColor,
      secondaryText: textSecondaryColor,
      primary: primaryColor
    )
    bannerView.applyTheme(nativeTheme)
    modalView.applyTheme(nativeTheme)
  }

  private var shouldRenderVoiceSnapshot: Bool {
    voiceSnapshot.presentsGlobalPlayer && voiceSnapshot.messageId != nil
  }

  private func applyResolvedState() {
    if shouldRenderVoiceSnapshot {
      let resolvedQueue = VoiceBubblePlaybackCoordinator.shared.displayQueueTracks()
      bannerView.applyVoiceSnapshot(voiceSnapshot)
      modalView.updateState(
        track: createTrackFromVoiceSnapshot(voiceSnapshot),
        queue: resolvedQueue,
        library: [],
        isPlaying: voiceSnapshot.isPlaying,
        progressMs: voiceSnapshot.duration * 1000.0 * Double(voiceSnapshot.progress),
        durationMs: voiceSnapshot.duration * 1000.0,
        queueOrderMode: voiceSnapshot.queueOrderMode,
        isRepeatEnabled: voiceSnapshot.isRepeatEnabled,
        artworkImage: voiceSnapshot.artwork
      )
    } else {
      bannerView.applyStatePayload(enginePayload)
      let currentTrack = (enginePayload["currentTrack"] as? [String: Any]).flatMap(NativeMusicPlayerTrack.init)
      let queue = (enginePayload["queue"] as? [[String: Any]] ?? []).compactMap(NativeMusicPlayerTrack.init)
      let library = (enginePayload["library"] as? [[String: Any]] ?? []).compactMap(NativeMusicPlayerTrack.init)
      modalView.updateState(
        track: currentTrack,
        queue: queue,
        library: library,
        isPlaying: (enginePayload["isPlaying"] as? Bool) ?? false,
        progressMs: (enginePayload["progress"] as? NSNumber)?.doubleValue ?? (enginePayload["progress"] as? Double) ?? 0.0,
        durationMs: (enginePayload["duration"] as? NSNumber)?.doubleValue ?? (enginePayload["duration"] as? Double) ?? 0.0,
        queueOrderMode: NativeMusicPlayerQueueOrderMode(
          rawValue: (enginePayload["queueOrderMode"] as? String) ?? ""
        ) ?? .forward,
        isRepeatEnabled: (enginePayload["isRepeatEnabled"] as? Bool) ?? false,
        artworkImage: nil
      )
    }
  }

  private func createTrackFromVoiceSnapshot(_ vs: VoiceBubblePlaybackSnapshot) -> NativeMusicPlayerTrack? {
    guard let mid = vs.messageId else { return nil }
    return NativeMusicPlayerTrack(
      trackId: mid, videoId: nil, id: mid, source: "chat", title: vs.title ?? "Audio", 
      artist: vs.subtitle ?? "Vibegram", album: nil, duration: nil, 
      durationSeconds: vs.duration > 0 ? vs.duration : nil, cover: nil, 
      previewURL: nil, streamURL: nil, localURI: nil, cachedAt: nil, 
      playCount: 0, lastPlayedAt: nil, links: [:]
    )
  }
}

public final class NativeGlobalMusicPlayerModule: Module {
  private var stateObserver: NSObjectProtocol?
  public func definition() -> ModuleDefinition {
    Name("NativeGlobalMusicPlayer")
    OnCreate {
      self.stateObserver = NotificationCenter.default.addObserver(forName: .nativeMusicPlayerStateDidChange, object: NativeMusicPlayerEngine.shared, queue: .main) { [weak self] n in
        guard let p = n.userInfo?["payload"] as? [String: Any] else { return }
        self?.sendEvent("onPlaybackState", p)
      }
    }
    OnDestroy { if let s = self.stateObserver { NotificationCenter.default.removeObserver(s); self.stateObserver = nil } }
    Events("onPlaybackState")
    Function("isSupported") { true }
    Function("getState") { NativeMusicPlayerEngine.shared.getStatePayload() }
    Function("setQueue") { (p: [[String: Any]]) in NativeMusicPlayerEngine.shared.setQueue(p) }
    Function("setTrack") { (p: [String: Any]) in NativeMusicPlayerEngine.shared.setTrack(p) }
    Function("setIsPlaying") { (v: Bool) in NativeMusicPlayerEngine.shared.setIsPlaying(v) }
    Function("setIsExpanded") { (v: Bool) in NativeMusicPlayerEngine.shared.setIsExpanded(v) }
    Function("setPlaybackRate") { (v: Double) in NativeMusicPlayerEngine.shared.setPlaybackRate(v) }
    Function("playNext") { NativeMusicPlayerEngine.shared.playNext() }
    Function("playPrev") { NativeMusicPlayerEngine.shared.playPrev() }
    Function("reset") { NativeMusicPlayerEngine.shared.reset() }
    Function("seekTo") { (m: Double) in NativeMusicPlayerEngine.shared.seek(toMilliseconds: m) }
    Function("cacheTrack") { (p: [String: Any]) -> Any in NativeMusicPlayerEngine.shared.cacheTrack(p) ?? NSNull() }
    Function("getTrack") { (id: String) -> Any in NativeMusicPlayerEngine.shared.getTrack(id) ?? NSNull() }
    Function("removeTrack") { (id: String) in NativeMusicPlayerEngine.shared.removeTrack(id) }
    AsyncFunction("downloadTrack") { (p: [String: Any], pr: Promise) in NativeMusicPlayerEngine.shared.downloadTrack(p) { r in pr.resolve(r) } }
    
    View(NativeGlobalMusicPlayerView.self) {
      Prop("isDark") { $0.setIsDark($1) }
      Prop("surfaceColor") { $0.setSurfaceColor($1) }
      Prop("textColor") { $0.setTextColor($1) }
      Prop("textSecondaryColor") { $0.setTextSecondaryColor($1) }
      Prop("primaryColor") { $0.setPrimaryColor($1) }
      Prop("topInset") { $0.setTopInset($1 ?? 0.0) }
    }
  }
}

private extension UIColor {
  static func nativeMusicColor(from v: String?) -> UIColor? {
    guard let r = v?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
    if r.hasPrefix("#") {
      let hex = String(r.dropFirst())
      guard hex.count == 6, let n = Int(hex, radix: 16) else { return nil }
      return UIColor(red: CGFloat((n >> 16) & 0xff) / 255, green: CGFloat((n >> 8) & 0xff) / 255, blue: CGFloat(n & 0xff) / 255, alpha: 1)
    }
    return nil
  }
}
