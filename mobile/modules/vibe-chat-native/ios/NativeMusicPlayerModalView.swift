import UIKit

private final class NativeMusicPlayerModalQueueRowView: UIControl {
  private let leadingContainerView = UIView()
  private let leadingArtworkView = UIImageView()
  private let leadingFallbackIconView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let separatorView = UIView()
  private let textStack = UIStackView()
  private let playingIndicator = PlayingIndicatorView()
  private var theme = NativeMusicPlayerTheme()
  private var trackId: String?
  private var imageTask: URLSessionDataTask?
  private var isActive = false

  var onSelectTrack: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    leadingContainerView.layer.cornerCurve = .continuous
    addSubview(leadingContainerView)

    leadingArtworkView.contentMode = .scaleAspectFill
    leadingArtworkView.clipsToBounds = true
    addSubview(leadingArtworkView)

    leadingFallbackIconView.contentMode = .scaleAspectFit
    leadingFallbackIconView.image = UIImage(systemName: "play.fill")
    addSubview(leadingFallbackIconView)

    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.numberOfLines = 1
    subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    subtitleLabel.numberOfLines = 2

    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.spacing = 3.0
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(subtitleLabel)
    addSubview(textStack)

    addSubview(playingIndicator)

    separatorView.isUserInteractionEnabled = false
    addSubview(separatorView)

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    imageTask?.cancel()
  }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme
    titleLabel.textColor = theme.text
    subtitleLabel.textColor = theme.secondaryText
    leadingFallbackIconView.tintColor = UIColor.white
    separatorView.backgroundColor = theme.text.withAlphaComponent(theme.isDark ? 0.10 : 0.08)
    playingIndicator.color = theme.primary
  }

  func configure(
    track: NativeMusicPlayerTrack,
    isActive: Bool,
    artworkImage: UIImage? = nil,
    showsSeparator: Bool
  ) {
    self.isActive = isActive
    trackId = track.trackId
    titleLabel.text = track.title
    subtitleLabel.text = detailText(for: track)
    separatorView.isHidden = !showsSeparator

    titleLabel.textColor = isActive ? theme.text : theme.text.withAlphaComponent(0.96)
    subtitleLabel.textColor =
      isActive ? theme.secondaryText.withAlphaComponent(0.92) : theme.secondaryText

    playingIndicator.isHidden = !isActive
    if isActive {
      playingIndicator.start()
    } else {
      playingIndicator.stop()
    }

    loadImage(urlString: track.cover, directImage: artworkImage)
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let inset: CGFloat = 10.0
    let leadingSide: CGFloat = 56.0

    leadingContainerView.frame = CGRect(
      x: 0.0,
      y: floor((bounds.height - leadingSide) * 0.5),
      width: leadingSide,
      height: leadingSide
    )
    leadingContainerView.layer.cornerRadius = leadingSide * 0.5
    leadingArtworkView.frame = leadingContainerView.frame
    leadingArtworkView.layer.cornerRadius = leadingSide * 0.5
    leadingFallbackIconView.frame = leadingContainerView.frame.insetBy(dx: 17.0, dy: 17.0)

    let indicatorSide: CGFloat = 18.0
    playingIndicator.frame = CGRect(
      x: leadingContainerView.frame.maxX - 10.0,
      y: leadingContainerView.frame.maxY - 10.0,
      width: indicatorSide,
      height: indicatorSide
    )
    playingIndicator.layer.cornerRadius = indicatorSide * 0.5

    let textX = leadingContainerView.frame.maxX + 14.0
    textStack.frame = CGRect(
      x: textX,
      y: floor((bounds.height - 40.0) * 0.5),
      width: max(0.0, bounds.width - textX - inset),
      height: 40.0
    )

    separatorView.frame = CGRect(
      x: textX,
      y: bounds.height - (1.0 / UIScreen.main.scale),
      width: max(0.0, bounds.width - textX),
      height: 1.0 / UIScreen.main.scale
    )
  }

  @objc private func handleTap() {
    guard let trackId else { return }
    onSelectTrack?(trackId)
  }

  private func detailText(for track: NativeMusicPlayerTrack) -> String {
    let components = [track.duration, track.artist].compactMap { value -> String? in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    return components.isEmpty ? "Audio" : components.joined(separator: " • ")
  }

  private func loadImage(urlString: String?, directImage: UIImage? = nil) {
    imageTask?.cancel()
    imageTask = nil
    leadingArtworkView.image = nil

    let fallbackBackground =
      theme.primary.withAlphaComponent(theme.isDark ? 0.96 : 0.90)
    leadingContainerView.backgroundColor = fallbackBackground
    leadingFallbackIconView.isHidden = false

    if let directImage {
      leadingArtworkView.image = directImage
      leadingContainerView.backgroundColor = .clear
      leadingFallbackIconView.isHidden = true
      return
    }

    guard
      let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty,
      let url = URL(string: trimmed)
    else {
      return
    }

    imageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        self.leadingArtworkView.image = image
        self.leadingContainerView.backgroundColor = .clear
        self.leadingFallbackIconView.isHidden = true
      }
    }
    imageTask?.resume()
  }
}

private final class PlayingIndicatorView: UIView {
  var color: UIColor = .systemBlue {
    didSet { bars.forEach { $0.backgroundColor = color } }
  }
  private let bars: [UIView] = (0..<3).map { _ in UIView() }

  init() {
    super.init(frame: .zero)
    backgroundColor = .clear
    isHidden = true
    clipsToBounds = true
    bars.forEach { bar in
      bar.layer.cornerRadius = 1.0
      addSubview(bar)
    }
  }

  required init?(coder: NSCoder) { nil }

  func start() {
    stop()
    for (i, bar) in bars.enumerated() {
      let anim = CABasicAnimation(keyPath: "transform.scale.y")
      anim.fromValue = 0.3
      anim.toValue = 1.0
      anim.duration = 0.4 + (Double(i) * 0.1)
      anim.repeatCount = .infinity
      anim.autoreverses = true
      anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      bar.layer.add(anim, forKey: "pulse")
    }
  }

  func stop() {
    bars.forEach { $0.layer.removeAllAnimations() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let barWidth: CGFloat = 3.0
    let spacing: CGFloat = 2.0
    let totalWidth = (barWidth * 3) + (spacing * 2)
    let startX = (bounds.width - totalWidth) / 2
    for (i, bar) in bars.enumerated() {
      let h = bounds.height
      bar.frame = CGRect(
        x: startX + CGFloat(i) * (barWidth + spacing),
        y: h,
        width: barWidth,
        height: -h // Draw upwards from bottom
      )
    }
  }
}

final class NativeMusicPlayerModalView: UIViewController, UIScrollViewDelegate {
  var onTogglePlayback: (() -> Void)?
  var onDismiss: (() -> Void)?
  var onPlayNext: (() -> Void)?
  var onPlayPrev: (() -> Void)?
  var onToggleQueueOrder: (() -> Void)?
  var onToggleRepeat: (() -> Void)?
  var onSeek: ((Double) -> Void)?
  var onSelectTrack: ((String) -> Void)?

  private let sheetContent = UIView()

  private let coverTapControl = UIControl()
  private let coverView = UIImageView()
  private let coverFallbackView = UIImageView()
  private let shareButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let artistLabel = UILabel()
  private let currentTimeLabel = UILabel()
  private let durationLabel = UILabel()
  private let progressSlider = UISlider()
  private let rateButton = UIButton(type: .system)
  private let prevButton = UIButton(type: .system)
  private let playButton = UIButton(type: .system)
  private let nextButton = UIButton(type: .system)
  private let artworkModeButton = UIButton(type: .system)
  private let primaryActionButton = UIButton(type: .system)
  private let queueTitleLabel = UILabel()
  private let queueScrollView = UIScrollView()
  private var queueRowViews: [NativeMusicPlayerModalQueueRowView] = []

  private var theme = NativeMusicPlayerTheme()
  private var isShowing = false
  private var showsExpandedArtwork = false
  private var queueCanScroll = false
  private var coverImageTask: URLSessionDataTask?
  private var pendingSeekValue: Float?

  private var currentTrack: NativeMusicPlayerTrack?
  private var currentState: (progressMs: Double, durationMs: Double, isPlaying: Bool) =
    (0.0, 0.0, false)
  private var currentQueue: [NativeMusicPlayerTrack] = []
  private var currentLibrary: [NativeMusicPlayerTrack] = []
  private var currentArtwork: UIImage?
  private var queueOrderMode: NativeMusicPlayerQueueOrderMode = .forward
  private var isRepeatEnabled = false
  private var renderedPlayButtonIsPlaying: Bool?
  private var renderedCoverTrackId: String?
  private var renderedCoverURL: String?
  private var renderedCoverImageIdentifier: ObjectIdentifier?
  private var renderedQueueTracks: [NativeMusicPlayerTrack] = []
  private var renderedQueueActiveTrackId: String?
  private var renderedQueueArtworkIdentifier: ObjectIdentifier?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    sheetContent.clipsToBounds = false
    view.addSubview(sheetContent)

    configureSheet()

    coverTapControl.addTarget(self, action: #selector(handleArtworkModeToggle), for: .touchUpInside)
    sheetContent.addSubview(coverTapControl)

    coverView.contentMode = .scaleAspectFill
    coverView.clipsToBounds = true
    coverView.layer.cornerCurve = .continuous
    coverTapControl.addSubview(coverView)

    coverFallbackView.contentMode = .scaleAspectFit
    coverFallbackView.image = UIImage(systemName: "music.note")
    coverTapControl.addSubview(coverFallbackView)

    shareButton.configuration = .plain()
    shareButton.configuration?.contentInsets = .zero
    shareButton.addTarget(self, action: #selector(handleShare), for: .touchUpInside)
    sheetContent.addSubview(shareButton)

    titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
    titleLabel.numberOfLines = 2
    titleLabel.lineBreakMode = .byTruncatingTail
    sheetContent.addSubview(titleLabel)
    
    artistLabel.font = .systemFont(ofSize: 14, weight: .medium)
    artistLabel.numberOfLines = 2
    artistLabel.lineBreakMode = .byTruncatingTail
    sheetContent.addSubview(artistLabel)

    currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    durationLabel.textAlignment = .right
    sheetContent.addSubview(currentTimeLabel)
    sheetContent.addSubview(durationLabel)

    progressSlider.minimumValue = 0.0
    progressSlider.maximumValue = 1.0
    progressSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    progressSlider.addTarget(self, action: #selector(sliderCommit), for: .touchUpInside)
    progressSlider.addTarget(self, action: #selector(sliderCommit), for: .touchUpOutside)
    progressSlider.addTarget(self, action: #selector(sliderCommit), for: .touchCancel)
    sheetContent.addSubview(progressSlider)

    rateButton.addTarget(self, action: #selector(handleQueueOrderToggle), for: .touchUpInside)
    prevButton.addTarget(self, action: #selector(handlePrev), for: .touchUpInside)
    playButton.addTarget(self, action: #selector(handlePlay), for: .touchUpInside)
    nextButton.addTarget(self, action: #selector(handleNext), for: .touchUpInside)
    artworkModeButton.addTarget(self, action: #selector(handleRepeatToggle), for: .touchUpInside)
    [rateButton, prevButton, playButton, nextButton, artworkModeButton].forEach {
      sheetContent.addSubview($0)
    }

    primaryActionButton.isHidden = true
    sheetContent.addSubview(primaryActionButton)

    queueTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    queueTitleLabel.text = "AUDIO IN THIS CHAT"
    queueTitleLabel.isHidden = true
    sheetContent.addSubview(queueTitleLabel)

    queueScrollView.alwaysBounceVertical = false
    queueScrollView.showsVerticalScrollIndicator = false
    queueScrollView.contentInsetAdjustmentBehavior = .never
    queueScrollView.clipsToBounds = true
    queueScrollView.delegate = self
    sheetContent.addSubview(queueScrollView)

    applyTheme(theme)
  }

  private func configureSheet() {
    modalPresentationStyle = .pageSheet
    if let sheet = sheetPresentationController {
      sheet.detents = [
        .custom { context in return 380 },
        .large()
      ]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 32.0
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      sheet.selectedDetentIdentifier = .init("custom")
    }
  }

  required init?(coder: NSCoder) {
    return nil
  }

  init() {
    super.init(nibName: nil, bundle: nil)
  }

  deinit {
    coverImageTask?.cancel()
  }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme

    let backgroundColor =
      theme.isDark ? UIColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 0.985) : theme.surface
    view.backgroundColor = backgroundColor

    coverView.backgroundColor = theme.text.withAlphaComponent(theme.isDark ? 0.08 : 0.06)
    coverFallbackView.tintColor = theme.secondaryText

    titleLabel.textColor = theme.text
    artistLabel.textColor = theme.primary
    currentTimeLabel.textColor = theme.secondaryText
    durationLabel.textColor = theme.secondaryText
    queueTitleLabel.textColor = theme.secondaryText.withAlphaComponent(0.92)

    progressSlider.minimumTrackTintColor = theme.primary
    progressSlider.maximumTrackTintColor = theme.text.withAlphaComponent(theme.isDark ? 0.22 : 0.16)
    let thumb = circleThumbImage(color: theme.primary)
    progressSlider.setThumbImage(thumb, for: .normal)
    progressSlider.setThumbImage(thumb, for: .highlighted)

    shareButton.tintColor = theme.primary
    shareButton.setImage(
      UIImage(systemName: "square.and.arrow.up")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 14.0, weight: .semibold)),
      for: .normal
    )
    shareButton.adjustsImageWhenHighlighted = true

    updateQueueControlButtons(animated: false)
    applyTransportButtonStyle(
      prevButton,
      systemName: "backward.fill",
      pointSize: 29.0,
      tintColor: theme.text
    )
    applyTransportButtonStyle(
      nextButton,
      systemName: "forward.fill",
      pointSize: 29.0,
      tintColor: theme.text
    )
    applyPrimaryPlayButtonStyle(forceImageRefresh: true)
    primaryActionButton.backgroundColor = theme.primary
    primaryActionButton.setTitleColor(.white, for: .normal)
    primaryActionButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    primaryActionButton.layer.cornerCurve = .continuous
    primaryActionButton.layer.cornerRadius = 26.0
    primaryActionButton.setImage(
      UIImage(systemName: "list.bullet")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)),
      for: .normal
    )
    primaryActionButton.adjustsImageWhenHighlighted = false
    primaryActionButton.tintColor = .white
    primaryActionButton.semanticContentAttribute = .forceLeftToRight
    primaryActionButton.contentEdgeInsets = UIEdgeInsets(top: 0.0, left: 18.0, bottom: 0.0, right: 18.0)
    primaryActionButton.imageEdgeInsets = UIEdgeInsets(top: 0.0, left: -6.0, bottom: 0.0, right: 6.0)

    queueRowViews.forEach { $0.applyTheme(theme) }
    view.setNeedsLayout()
  }

  func updateState(
    track: NativeMusicPlayerTrack?,
    queue: [NativeMusicPlayerTrack],
    library: [NativeMusicPlayerTrack],
    isPlaying: Bool,
    progressMs: Double,
    durationMs: Double,
    queueOrderMode: NativeMusicPlayerQueueOrderMode,
    isRepeatEnabled: Bool,
    artworkImage: UIImage?
  ) {
    let previousQueueHidden = queueTitleLabel.isHidden
    currentTrack = track
    currentQueue = queue
    currentLibrary = library
    currentArtwork = artworkImage
    self.queueOrderMode = queueOrderMode
    self.isRepeatEnabled = isRepeatEnabled

    guard let track else {
      let clearedQueue = clearQueueRowsIfNeeded()
      queueTitleLabel.isHidden = true
      if !previousQueueHidden || clearedQueue {
        view.setNeedsLayout()
      }
      return
    }

    titleLabel.text = track.title
    artistLabel.text = track.artist

    let effectiveDuration = max(durationMs, (track.durationSeconds ?? 0.0) * 1000.0)
    currentState = (progressMs, effectiveDuration, isPlaying)
    let remainingMs = max(0.0, effectiveDuration - progressMs)
    currentTimeLabel.text = Self.format(ms: progressMs)
    durationLabel.text = "-" + Self.format(ms: remainingMs)

    if !progressSlider.isTracking {
      let dur = max(effectiveDuration, 1.0)
      progressSlider.value = Float(max(0.0, min(1.0, progressMs / dur)))
    }

    updatePlayButton(isPlaying: isPlaying)
    updateCoverIfNeeded(for: track, directImage: artworkImage)
    let queueDidChange = updateQueueRowsIfNeeded(
      track: track,
      queue: queue,
      library: library,
      artworkImage: artworkImage
    )
    updateQueueControlButtons()

    if queueDidChange || previousQueueHidden != queueTitleLabel.isHidden {
      view.setNeedsLayout()
    }
  }

  var isModalVisible: Bool { isShowing }

  func show(animated: Bool = true) {
    guard !isShowing else { return }
    isShowing = true
    
    guard let controller = topMostViewController() else { return }
    controller.present(self, animated: animated)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed {
      isShowing = false
      onDismiss?()
    }
  }

  @objc func dismissModal(animated: Bool = true) {
    dismiss(animated: animated)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    let width = view.bounds.width
    let height = view.bounds.height
    let topInset: CGFloat = 12.0
    let bottomInset = view.safeAreaInsets.bottom + 12.0
    let pad: CGFloat = 24.0
    let contentWidth = width
    let usableWidth = max(0.0, contentWidth - (pad * 2.0))
    
    sheetContent.frame = view.bounds
    
    var y = topInset

    if showsExpandedArtwork {
      let coverSide = min(usableWidth, 360.0)
      coverTapControl.frame = CGRect(
        x: floor((contentWidth - coverSide) * 0.5),
        y: y,
        width: coverSide,
        height: coverSide
      )
      coverView.frame = coverTapControl.bounds
      coverView.layer.cornerRadius = 18.0
      coverFallbackView.frame = coverTapControl.bounds.insetBy(dx: coverSide * 0.28, dy: coverSide * 0.28)
      y = coverTapControl.frame.maxY + 22.0

      let shareSide: CGFloat = 24.0
      titleLabel.textAlignment = .left
      artistLabel.textAlignment = .left
      
      // Calculate dynamic block height for centering
      let titleHeight: CGFloat = 22.0
      let artistHeight: CGFloat = 20.0
      let spacing: CGFloat = 4.0
      let textBlockHeight = titleHeight + spacing + artistHeight
      
      let textX = pad
      let textWidthLimit = usableWidth - shareSide - 12.0
      titleLabel.frame = CGRect(x: textX, y: y, width: textWidthLimit, height: titleHeight)
      artistLabel.frame = CGRect(x: textX, y: titleLabel.frame.maxY + spacing, width: textWidthLimit, height: artistHeight)
      
      shareButton.frame = CGRect(
        x: textX + min(titleLabel.intrinsicContentSize.width, textWidthLimit) + 8.0,
        y: y + 1.0,
        width: shareSide,
        height: shareSide
      )
      y = max(artistLabel.frame.maxY, shareButton.frame.maxY) + 24.0
    } else {
      let compactSide: CGFloat = 76.0
      coverTapControl.frame = CGRect(x: pad, y: y, width: compactSide, height: compactSide)
      coverView.frame = coverTapControl.bounds
      coverView.layer.cornerRadius = 16.0
      coverFallbackView.frame = coverTapControl.bounds.insetBy(dx: 22.0, dy: 22.0)

      let shareSide: CGFloat = 22.0
      let titleHeight: CGFloat = 20.0
      let artistHeight: CGFloat = 18.0
      let textBlockHeight: CGFloat = titleHeight + 4.0 + artistHeight
      
      let labelX = coverTapControl.frame.maxX + 16.0
      let labelWidthLimit = width - pad - labelX - shareSide - 16.0
      titleLabel.textAlignment = .left
      artistLabel.textAlignment = .left
      
      let titleSize = titleLabel.sizeThatFits(CGSize(width: labelWidthLimit, height: 40))
      titleLabel.frame = CGRect(x: labelX, y: y + floor((compactSide - textBlockHeight) * 0.5), width: labelWidthLimit, height: min(titleHeight, titleSize.height))
      artistLabel.frame = CGRect(x: labelX, y: titleLabel.frame.maxY + 4.0, width: labelWidthLimit, height: artistHeight)

      let titleDisplayWidth = min(titleLabel.intrinsicContentSize.width, labelWidthLimit)
      shareButton.frame = CGRect(
        x: labelX + titleDisplayWidth + 8.0,
        y: titleLabel.frame.minY - 1.0,
        width: shareSide,
        height: shareSide
      )
      y = coverTapControl.frame.maxY + 24.0
    }

    currentTimeLabel.frame = CGRect(x: pad, y: y, width: 64.0, height: 16.0)
    durationLabel.frame = CGRect(x: width - pad - 64.0, y: y, width: 64.0, height: 16.0)
    y = currentTimeLabel.frame.maxY + 6.0

    progressSlider.frame = CGRect(x: pad, y: y, width: usableWidth, height: 20.0)
    progressSlider.transform = CGAffineTransform.identity
    y = progressSlider.frame.maxY + 18.0

    let utilitySide: CGFloat = 44.0
    let navSide: CGFloat = 54.0
    let playSide: CGFloat = 78.0
    let outerGap: CGFloat = 22.0
    let centerGap: CGFloat = 30.0
    let controlRowWidth =
      utilitySide + outerGap + navSide + centerGap + playSide + centerGap + navSide + outerGap
      + utilitySide
    let controlStartX = floor((width - controlRowWidth) * 0.5)
    let controlRowTop = y

    rateButton.frame = CGRect(
      x: controlStartX,
      y: controlRowTop + floor((playSide - utilitySide) * 0.5),
      width: utilitySide,
      height: utilitySide
    )
    prevButton.frame = CGRect(
      x: rateButton.frame.maxX + outerGap,
      y: controlRowTop + floor((playSide - navSide) * 0.5),
      width: navSide,
      height: navSide
    )
    playButton.frame = CGRect(
      x: prevButton.frame.maxX + centerGap,
      y: controlRowTop,
      width: playSide,
      height: playSide
    )
    nextButton.frame = CGRect(
      x: playButton.frame.maxX + centerGap,
      y: prevButton.frame.minY,
      width: navSide,
      height: navSide
    )
    artworkModeButton.frame = CGRect(
      x: nextButton.frame.maxX + outerGap,
      y: rateButton.frame.minY,
      width: utilitySide,
      height: utilitySide
    )
    y = playButton.frame.maxY + 26.0

    queueTitleLabel.font = .systemFont(ofSize: 12, weight: .bold)
    queueTitleLabel.text = "AUDIO IN THIS CHAT"
    queueTitleLabel.frame = CGRect(x: pad, y: y, width: usableWidth, height: 16.0)
    y = queueTitleLabel.frame.maxY + 12.0

    let queueHeight = max(0.0, height - y - bottomInset)
    queueScrollView.frame = CGRect(x: pad, y: y, width: usableWidth, height: queueHeight)

    var rowY: CGFloat = 0.0
    for row in queueRowViews {
      row.frame = CGRect(x: 0.0, y: rowY, width: queueScrollView.bounds.width, height: 82.0)
      rowY += 82.0
    }
    queueScrollView.contentSize = CGSize(width: queueScrollView.bounds.width, height: rowY)
    queueCanScroll = (rowY - queueHeight) > 1.0
    queueScrollView.isScrollEnabled = queueCanScroll
    queueScrollView.alwaysBounceVertical = queueCanScroll
    queueScrollView.bounces = queueCanScroll
    queueScrollView.showsVerticalScrollIndicator = queueCanScroll
    if !queueCanScroll, queueScrollView.contentOffset != .zero {
      queueScrollView.setContentOffset(.zero, animated: false)
    }
    primaryActionButton.frame = .zero
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // Native sheet handles pulling down automatically
  }

  @objc private func handlePlay() {
    onTogglePlayback?()
  }

  @objc private func handlePrev() {
    onPlayPrev?()
  }

  @objc private func handleNext() {
    onPlayNext?()
  }

  @objc private func handleQueueOrderToggle() {
    onToggleQueueOrder?()
  }

  @objc private func handleRepeatToggle() {
    onToggleRepeat?()
  }

  @objc private func handleArtworkModeToggle() {
    showsExpandedArtwork.toggle()
    applyTheme(theme)
    UIView.animate(
      withDuration: 0.26,
      delay: 0.0,
      usingSpringWithDamping: 0.94,
      initialSpringVelocity: 0.10,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }
  }

  @objc private func handleShare() {
    guard let currentTrack else { return }
    var items: [Any] = []
    let shareText = [currentTrack.title, currentTrack.artist]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: " • ")
    if !shareText.isEmpty {
      items.append(shareText)
    }
    if let url = shareURL(for: currentTrack) {
      items.append(url)
    }
    guard !items.isEmpty, let controller = topMostViewController() else { return }
    let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      popover.sourceView = shareButton
      popover.sourceRect = shareButton.bounds
    }
    controller.present(activity, animated: true)
  }

  @objc private func sliderChanged() {
    pendingSeekValue = progressSlider.value
    let duration = max(currentState.durationMs, 1.0)
    currentTimeLabel.text = Self.format(ms: Double(progressSlider.value) * duration)
  }

  @objc private func sliderCommit() {
    guard let pendingSeekValue else { return }
    self.pendingSeekValue = nil
    onSeek?(Double(pendingSeekValue) * max(currentState.durationMs, 1.0))
  }

  private func applyTransportButtonStyle(
    _ button: UIButton,
    systemName: String,
    pointSize: CGFloat,
    tintColor: UIColor,
    animated: Bool = false
  ) {
    let update = {
      button.configuration = .plain()
      button.configuration?.contentInsets = .zero
      button.tintColor = tintColor
      button.setImage(
        UIImage(systemName: systemName)?.withConfiguration(
          UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        ),
        for: .normal
      )
      button.adjustsImageWhenHighlighted = true
    }
    
    if animated {
      UIView.transition(with: button, duration: 0.16, options: .transitionCrossDissolve, animations: update)
    } else {
      update()
    }
  }

  private func applyPrimaryPlayButtonStyle(forceImageRefresh: Bool) {
    playButton.configuration = .plain()
    playButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0.0, leading: 0.0, bottom: 0.0, trailing: 0.0)
    playButton.tintColor = theme.text
    playButton.backgroundColor = UIColor.clear
    playButton.layer.cornerRadius = 39.0
    playButton.layer.cornerCurve = .continuous
    playButton.adjustsImageWhenHighlighted = false
    updatePlayButtonImage(animated: false, force: forceImageRefresh)
  }

  private func updatePlayButton(isPlaying: Bool) {
    currentState.isPlaying = isPlaying
    updatePlayButtonImage(animated: renderedPlayButtonIsPlaying != nil)
  }

  private func updatePlayButtonImage(animated: Bool, force: Bool = false) {
    let targetIsPlaying = currentState.isPlaying
    guard force || renderedPlayButtonIsPlaying != targetIsPlaying else { return }
    renderedPlayButtonIsPlaying = targetIsPlaying

    let iconName = targetIsPlaying ? "pause.fill" : "play.fill"
    let image = UIImage(systemName: iconName)?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 42.0, weight: .bold)
    )
    let updateImage = {
      self.playButton.setImage(image, for: .normal)
    }
    if animated {
      UIView.transition(
        with: playButton,
        duration: 0.14,
        options: [.transitionCrossDissolve, .allowUserInteraction],
        animations: updateImage
      )
    } else {
      updateImage()
    }
  }

  private func queueOrderIconName() -> String {
    switch queueOrderMode {
    case .forward:
      return "chevron.down"
    case .reverse:
      return "chevron.up"
    case .random:
      return "shuffle"
    }
  }

  private func queueOrderTintColor() -> UIColor {
    switch queueOrderMode {
    case .forward:
      return theme.secondaryText
    case .reverse, .random:
      return theme.primary
    }
  }

  private func updateQueueControlButtons(animated: Bool = true) {
    applyTransportButtonStyle(
      rateButton,
      systemName: queueOrderIconName(),
      pointSize: 16.0,
      tintColor: queueOrderTintColor(),
      animated: animated
    )
    applyTransportButtonStyle(
      artworkModeButton,
      systemName: isRepeatEnabled ? "repeat.1" : "repeat",
      pointSize: 16.0,
      tintColor: isRepeatEnabled ? theme.primary : theme.secondaryText.withAlphaComponent(0.8),
      animated: animated
    )
  }


  private func updateCoverIfNeeded(for track: NativeMusicPlayerTrack, directImage: UIImage?) {
    let normalizedCoverURL = track.cover?.trimmingCharacters(in: .whitespacesAndNewlines)
    let imageIdentifier = directImage.map(ObjectIdentifier.init)
    guard
      renderedCoverTrackId != track.trackId
        || renderedCoverURL != normalizedCoverURL
        || renderedCoverImageIdentifier != imageIdentifier
    else {
      return
    }

    renderedCoverTrackId = track.trackId
    renderedCoverURL = normalizedCoverURL
    renderedCoverImageIdentifier = imageIdentifier
    updateCover(urlString: normalizedCoverURL, directImage: directImage)
  }

  private func updateCover(urlString: String?, directImage: UIImage?) {
    coverImageTask?.cancel()
    coverImageTask = nil
    coverView.image = nil
    coverFallbackView.isHidden = false

    if let directImage {
      coverView.image = directImage
      coverFallbackView.isHidden = true
      return
    }

    guard
      let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty,
      let url = URL(string: trimmed)
    else {
      return
    }

    coverImageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        self.coverView.image = image
        self.coverFallbackView.isHidden = true
      }
    }
    coverImageTask?.resume()
  }

  private func updateQueueRowsIfNeeded(
    track: NativeMusicPlayerTrack,
    queue: [NativeMusicPlayerTrack],
    library: [NativeMusicPlayerTrack],
    artworkImage: UIImage?
  ) -> Bool {
    let tracks = resolvedDisplayTracks(queue: queue, library: library)
    let queueWasHidden = queueTitleLabel.isHidden
    queueTitleLabel.isHidden = tracks.isEmpty

    let queueStructureChanged = tracks != renderedQueueTracks
    if queueStructureChanged {
      queueRowViews.forEach { $0.removeFromSuperview() }
      queueRowViews.removeAll(keepingCapacity: true)
      renderedQueueTracks = tracks

      for _ in tracks {
        let row = NativeMusicPlayerModalQueueRowView()
        row.applyTheme(theme)
        row.onSelectTrack = { [weak self] trackId in
          self?.onSelectTrack?(trackId)
        }
        queueScrollView.addSubview(row)
        queueRowViews.append(row)
      }
    }

    let queueArtworkIdentifier = artworkImage.map(ObjectIdentifier.init)
    let activeTrackChanged = renderedQueueActiveTrackId != track.trackId
    let artworkChanged = renderedQueueArtworkIdentifier != queueArtworkIdentifier
    if queueStructureChanged || activeTrackChanged || artworkChanged {
      for (index, candidate) in tracks.enumerated() {
        let row = queueRowViews[index]
        let artwork =
          ChatAudioQueueRegistry.shared.artwork(for: candidate.trackId, in: candidate.links["chat_id"])
          ?? (candidate.trackId == track.trackId ? artworkImage : nil)
        row.configure(
          track: candidate,
          isActive: candidate.trackId == track.trackId,
          artworkImage: artwork,
          showsSeparator: index < tracks.count - 1
        )
      }
      renderedQueueActiveTrackId = track.trackId
      renderedQueueArtworkIdentifier = queueArtworkIdentifier
    }

    return queueStructureChanged || queueWasHidden != queueTitleLabel.isHidden
  }

  private func clearQueueRowsIfNeeded() -> Bool {
    guard !queueRowViews.isEmpty || !renderedQueueTracks.isEmpty else { return false }
    queueRowViews.forEach { $0.removeFromSuperview() }
    queueRowViews.removeAll(keepingCapacity: true)
    renderedQueueTracks = []
    renderedQueueActiveTrackId = nil
    renderedQueueArtworkIdentifier = nil
    return true
  }

  private func resolvedDisplayTracks(
    queue: [NativeMusicPlayerTrack],
    library: [NativeMusicPlayerTrack]
  ) -> [NativeMusicPlayerTrack] {
    var seen = Set<String>()
    var tracks: [NativeMusicPlayerTrack] = []
    for candidate in queue + library {
      if seen.insert(candidate.trackId).inserted {
        tracks.append(candidate)
      }
    }
    return tracks
  }

  private func circleThumbImage(color: UIColor) -> UIImage? {
    let size = CGSize(width: 12.0, height: 12.0)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
      let rect = CGRect(origin: .zero, size: size)
      context.cgContext.setFillColor(color.cgColor)
      context.cgContext.fillEllipse(in: rect)
    }
  }

  private func shareURL(for track: NativeMusicPlayerTrack) -> URL? {
    let candidates = [track.localURI, track.streamURL, track.previewURL, track.cover]
    for candidate in candidates {
      guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        continue
      }
      if let url = URL(string: trimmed) {
        return url
      }
      if trimmed.hasPrefix("/") {
        return URL(fileURLWithPath: trimmed)
      }
    }
    return nil
  }

  private func topMostViewController() -> UIViewController? {
    guard
      let root =
        view.window?.rootViewController
        ?? UIApplication.shared.connectedScenes
        .compactMap({ scene -> UIViewController? in
          guard let windowScene = scene as? UIWindowScene else { return nil }
          return windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        })
        .first
    else { return nil }
    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  static func format(ms: Double) -> String {
    guard ms.isFinite, ms > 0.0 else { return "0:00" }
    let seconds = Int((ms / 1000.0).rounded())
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
