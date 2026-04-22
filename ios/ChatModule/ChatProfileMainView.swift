import ExpoModulesCore
import UIKit
import AVFoundation

private struct ChatProfileRow {
  let messageId: String
  let type: String
  let text: String
  let mediaUrl: String?
  let localMediaUrl: String?
  let mediaKey: String?
  let fileName: String?
  let fileSize: Int64?
  let timestampMs: Int64?
  let isPinned: Bool
  let duration: CGFloat?
  let waveform: [CGFloat]?
  let thumbnailBase64: String?

  static func parse(_ raw: [String: Any]) -> ChatProfileRow? {
    let message = raw["message"] as? [String: Any] ?? raw
    let metadata = message["metadata"] as? [String: Any]
    let messageId =
      (message["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? UUID().uuidString
    let type = ((message["type"] as? String) ?? (raw["type"] as? String) ?? "text").lowercased()
    let text = (message["text"] as? String) ?? (raw["text"] as? String) ?? ""
    let localMediaUrl =
      (message["localMediaUrl"] as? String)
      ?? (message["local_media_url"] as? String)
      ?? (metadata?["localMediaUrl"] as? String)
      ?? (metadata?["local_media_url"] as? String)
    let resolvedLocalMediaUrl =
      localMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasUsableLocalMedia: Bool = {
      guard let resolvedLocalMediaUrl, !resolvedLocalMediaUrl.isEmpty else { return false }
      let localPath: String
      if let parsed = URL(string: resolvedLocalMediaUrl), parsed.isFileURL {
        localPath = parsed.path
      } else {
        localPath = resolvedLocalMediaUrl
      }
      return FileManager.default.fileExists(atPath: localPath)
    }()
    let remoteMediaUrl =
      (message["mediaUrl"] as? String)
      ?? (message["media_url"] as? String)
      ?? (metadata?["mediaUrl"] as? String)
      ?? (metadata?["media_url"] as? String)
      ?? (raw["mediaUrl"] as? String)
    let mediaUrl = hasUsableLocalMedia ? resolvedLocalMediaUrl : remoteMediaUrl
    let mediaKey =
      (message["mediaKey"] as? String)
      ?? (message["media_key"] as? String)
      ?? (metadata?["mediaKey"] as? String)
      ?? (metadata?["media_key"] as? String)
    let fileName =
      (message["fileName"] as? String)
      ?? (message["file_name"] as? String)
      ?? (metadata?["fileName"] as? String)
      ?? (metadata?["file_name"] as? String)
      ?? (raw["fileName"] as? String)

    let messageFileSizeNumber = message["fileSize"] as? NSNumber
    let rawFileSizeNumber = raw["fileSize"] as? NSNumber
    let fileSize = messageFileSizeNumber?.int64Value ?? rawFileSizeNumber?.int64Value

    let timestampRaw =
      message["timestampMs"] ?? message["timestamp"] ?? raw["timestampMs"] ?? raw["timestamp"]
    let timestampMs: Int64? = {
      if let number = timestampRaw as? NSNumber {
        let value = number.int64Value
        return value < 2_000_000_000 ? (value * 1000) : value
      }
      if let text = timestampRaw as? String {
        if let numeric = Double(text), numeric.isFinite {
          let value = Int64(numeric)
          return value < 2_000_000_000 ? (value * 1000) : value
        }
        let parsed = ISO8601DateFormatter().date(from: text)
        if let parsed { return Int64(parsed.timeIntervalSince1970 * 1000.0) }
      }
      return nil
    }()

    let isPinned =
      (message["isPinned"] as? Bool == true)
      || (raw["isPinned"] as? Bool == true)
      || (message["pinned"] as? Bool == true)
      || (raw["pinned"] as? Bool == true)

    let duration: CGFloat? = {
      if let val = message["duration"] as? NSNumber { return CGFloat(val.floatValue) }
      if let val = raw["duration"] as? NSNumber { return CGFloat(val.floatValue) }
      return nil
    }()

    let waveform = parseChatProfileWaveform(message["waveform"] ?? raw["waveform"])
    
    let thumbnailBase64 = 
      (message["thumbnailBase64"] as? String)
      ?? (message["thumbnail_base64"] as? String)
      ?? (metadata?["thumbnailBase64"] as? String)
      ?? (metadata?["thumbnail_base64"] as? String)
      ?? (raw["thumbnailBase64"] as? String)

    return ChatProfileRow(
      messageId: messageId,
      type: type,
      text: text,
      mediaUrl: mediaUrl,
      localMediaUrl: localMediaUrl,
      mediaKey: mediaKey,
      fileName: fileName,
      fileSize: fileSize,
      timestampMs: timestampMs,
      isPinned: isPinned,
      duration: duration,
      waveform: waveform,
      thumbnailBase64: thumbnailBase64
    )
  }
}

private func normalizeChatProfileWaveformArray(_ rawList: [Any]) -> [CGFloat]? {
  let values: [CGFloat] = rawList.compactMap { item in
    if let number = item as? NSNumber {
      return CGFloat(truncating: number)
    }
    if let text = item as? String, let value = Double(text) {
      return CGFloat(value)
    }
    return nil
  }
  let normalized = values.filter { $0.isFinite }.map { max(0.0, min(1.0, $0)) }
  return normalized.isEmpty ? nil : normalized
}

private func chatProfileWaveformBitValue(
  data: UnsafeRawPointer,
  length: Int,
  bitOffset: Int,
  bitWidth: Int
) -> Int32 {
  guard length > 0, bitWidth > 0 else { return 0 }

  let byteOffset = bitOffset / 8
  guard byteOffset < length else { return 0 }

  let normalizedData = data.advanced(by: byteOffset)
  let normalizedBitOffset = bitOffset % 8
  let mask = UInt32((1 << bitWidth) - 1)

  var value: UInt32 = 0
  let bytesToCopy = min(MemoryLayout<UInt32>.size, length - byteOffset)
  memcpy(&value, normalizedData, bytesToCopy)

  return Int32((value >> UInt32(normalizedBitOffset)) & mask)
}

private func decodeChatProfileWaveformBitstream(_ data: Data, bitsPerSample: Int = 5) -> [CGFloat]? {
  guard !data.isEmpty, bitsPerSample > 0 else { return nil }

  let sampleCount = (data.count * 8) / bitsPerSample
  guard sampleCount > 0 else { return nil }

  let maxValue = CGFloat((1 << bitsPerSample) - 1)
  var result: [CGFloat] = []
  result.reserveCapacity(sampleCount)

  data.withUnsafeBytes { bytes in
    guard let baseAddress = bytes.baseAddress else { return }
    for index in 0..<sampleCount {
      let value = chatProfileWaveformBitValue(
        data: baseAddress,
        length: data.count,
        bitOffset: index * bitsPerSample,
        bitWidth: bitsPerSample
      )
      result.append(max(0.0, min(1.0, CGFloat(value) / maxValue)))
    }
  }

  return result.isEmpty ? nil : result
}

private func parseChatProfileWaveform(_ raw: Any?) -> [CGFloat]? {
  if let array = raw as? [Any], !array.isEmpty {
    return normalizeChatProfileWaveformArray(array)
  }

  guard let text = raw as? String else { return nil }
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  if trimmed.hasPrefix("["),
    let data = trimmed.data(using: .utf8),
    let json = try? JSONSerialization.jsonObject(with: data),
    let array = json as? [Any]
  {
    return normalizeChatProfileWaveformArray(array)
  }

  if let data = Data(base64Encoded: trimmed) {
    return decodeChatProfileWaveformBitstream(data)
  }

  return nil
}

private struct ChatProfileLinkItem {
  let row: ChatProfileRow
  let url: String
}

private enum ChatProfileTab: String, CaseIterable {
  case media
  case voice
  case gifs
  case files
  case links
  case pinned

  var label: String {
    switch self {
    case .media:
      return "Media"
    case .voice:
      return "Voice"
    case .gifs:
      return "GIFs"
    case .files:
      return "Files"
    case .links:
      return "Links"
    case .pinned:
      return "Pinned"
    }
  }
}

private enum ChatProfileInfoRow {
  case members
  case identifier
  case agent
  case bio
}

private final class ChatProfileListRowCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileListRowCell"

  let rowNode = ChatMainProfileListRowNode()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    contentView.backgroundColor = .clear
    rowNode.isUserInteractionEnabled = false
    contentView.addSubview(rowNode)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    rowNode.frame = contentView.bounds
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    rowNode.isHighlighted = highlighted
  }

  override func setSelected(_ selected: Bool, animated: Bool) {
    super.setSelected(selected, animated: animated)
    rowNode.isHighlighted = selected
  }
}

private final class ChatProfileTabStripView: UIView {
  static let preferredHeight: CGFloat = 34.0

  var onSelect: ((ChatProfileTab) -> Void)?

  private let chromeView = UIVisualEffectView(effect: nil)
  private let chromeOverlayView = UIView()
  private let scrollView = UIScrollView()
  private let stackView = UIStackView()
  private let selectionView = UIView()
  private var currentTabs: [ChatProfileTab] = []
  private var activeTab: ChatProfileTab = .media
  private var buttonsByTab: [ChatProfileTab: UIButton] = [:]
  private var isDark = false
  private let selectionFeedback = UISelectionFeedbackGenerator()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    backgroundColor = .clear
    clipsToBounds = false

    chromeView.translatesAutoresizingMaskIntoConstraints = false
    chromeView.clipsToBounds = true
    chromeView.layer.cornerCurve = .continuous
    addSubview(chromeView)

    chromeOverlayView.translatesAutoresizingMaskIntoConstraints = false
    chromeOverlayView.isUserInteractionEnabled = false
    chromeView.contentView.addSubview(chromeOverlayView)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = false
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    chromeView.contentView.addSubview(scrollView)

    selectionView.isUserInteractionEnabled = false
    selectionView.layer.cornerCurve = .continuous
    scrollView.addSubview(selectionView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.alignment = .fill
    stackView.distribution = .fill
    stackView.spacing = 6.0
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      chromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
      chromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
      chromeView.topAnchor.constraint(equalTo: topAnchor),
      chromeView.bottomAnchor.constraint(equalTo: bottomAnchor),

      chromeOverlayView.leadingAnchor.constraint(equalTo: chromeView.contentView.leadingAnchor),
      chromeOverlayView.trailingAnchor.constraint(equalTo: chromeView.contentView.trailingAnchor),
      chromeOverlayView.topAnchor.constraint(equalTo: chromeView.contentView.topAnchor),
      chromeOverlayView.bottomAnchor.constraint(equalTo: chromeView.contentView.bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: chromeView.contentView.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: chromeView.contentView.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: chromeView.contentView.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: chromeView.contentView.bottomAnchor),

      stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])

    selectionFeedback.prepare()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    chromeView.layer.cornerRadius = bounds.height * 0.5
    updateSelectionFrame(animated: false)
  }

  func applyTheme(isDark: Bool) {
    self.isDark = isDark
    applyChrome()
  }

  private func applyChrome() {
    let blurStyle: UIBlurEffect.Style =
      isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight

    let primary = isDark ? UIColor(white: 0.95, alpha: 0.96) : UIColor(white: 0.12, alpha: 0.96)
    let secondary = isDark ? UIColor(white: 0.84, alpha: 0.62) : UIColor(white: 0.12, alpha: 0.42)
    chromeView.effect = UIBlurEffect(style: blurStyle)
    chromeOverlayView.backgroundColor =
      (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.10 : 0.08)
    selectionView.backgroundColor =
      isDark ? UIColor.white.withAlphaComponent(0.18) : UIColor.black.withAlphaComponent(0.10)

    for (tab, button) in buttonsByTab {
      let selected = tab == activeTab
      button.setTitleColor(selected ? primary : secondary, for: .normal)
      button.alpha = selected ? 1.0 : 0.94
    }
  }

  func configure(
    tabs: [ChatProfileTab],
    activeTab: ChatProfileTab,
    titleProvider: (ChatProfileTab) -> String
  ) {
    let tabsChanged = currentTabs != tabs
    let previousTab = self.activeTab
    self.activeTab = activeTab

    if tabsChanged {
      currentTabs = tabs
      rebuildItems(titleProvider: titleProvider)
    } else {
      updateTitles(titleProvider: titleProvider)
    }

    applyChrome()
    updateSelectionFrame(animated: previousTab != activeTab && !tabsChanged)
    scrollSelectedTabIntoView(animated: previousTab != activeTab)
  }

  private func rebuildItems(titleProvider: (ChatProfileTab) -> String) {
    for arrangedSubview in stackView.arrangedSubviews {
      stackView.removeArrangedSubview(arrangedSubview)
      arrangedSubview.removeFromSuperview()
    }

    buttonsByTab.removeAll()
    selectionView.alpha = 0.0

    for (index, tab) in currentTabs.enumerated() {
      let button = UIButton(type: .system)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.tag = index
      button.contentEdgeInsets = UIEdgeInsets(top: 0.0, left: 10.0, bottom: 0.0, right: 10.0)
      button.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
      button.titleLabel?.lineBreakMode = .byTruncatingTail
      button.setTitle(titleProvider(tab), for: .normal)
      button.addTarget(self, action: #selector(handleTabButtonPressed(_:)), for: .touchUpInside)
      stackView.addArrangedSubview(button)
      buttonsByTab[tab] = button
    }

    setNeedsLayout()
  }

  private func updateTitles(titleProvider: (ChatProfileTab) -> String) {
    for tab in currentTabs {
      buttonsByTab[tab]?.setTitle(titleProvider(tab), for: .normal)
    }
  }

  private func updateSelectionFrame(animated: Bool) {
    guard let button = buttonsByTab[activeTab] else {
      selectionView.alpha = 0.0
      return
    }

    let targetFrame = button.convert(button.bounds, to: scrollView)
    let applySelection = {
      self.selectionView.frame = targetFrame
      self.selectionView.layer.cornerRadius = targetFrame.height * 0.5
      self.selectionView.alpha = 1.0
    }

    guard animated, window != nil else {
      applySelection()
      return
    }

    UIView.animate(
      withDuration: 0.26,
      delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
    ) {
      applySelection()
    }
  }

  private func scrollSelectedTabIntoView(animated: Bool) {
    guard let button = buttonsByTab[activeTab] else { return }
    let targetFrame = button.convert(button.bounds, to: scrollView).insetBy(dx: -18.0, dy: 0.0)
    scrollView.scrollRectToVisible(targetFrame, animated: animated)
  }

  @objc private func handleTabButtonPressed(_ sender: UIButton) {
    guard currentTabs.indices.contains(sender.tag) else { return }
    let tab = currentTabs[sender.tag]
    guard tab != activeTab else { return }

    selectionFeedback.selectionChanged()
    onSelect?(tab)
  }
}


private final class ChatProfileTabStripCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileTabStripCell"

  let tabsView = ChatProfileTabStripView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.addSubview(tabsView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    tabsView.frame = contentView.bounds.insetBy(dx: 12.0, dy: 6.0)
  }
}

private final class ChatProfileMediaContentCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileMediaContentCell"

  private let thumbnailNode = ChatMainProfileMediaCellNode()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.numberOfLines = 1
    subtitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    subtitleLabel.numberOfLines = 1

    contentView.addSubview(thumbnailNode)
    contentView.addSubview(titleLabel)
    contentView.addSubview(subtitleLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let bounds = contentView.bounds.insetBy(dx: 16.0, dy: 8.0)
    thumbnailNode.frame = CGRect(x: bounds.minX, y: bounds.minY, width: 56.0, height: 56.0)
    titleLabel.frame = CGRect(
      x: thumbnailNode.frame.maxX + 12.0,
      y: bounds.minY + 8.0,
      width: max(0.0, bounds.width - 68.0),
      height: 20.0
    )
    subtitleLabel.frame = CGRect(
      x: thumbnailNode.frame.maxX + 12.0,
      y: titleLabel.frame.maxY + 4.0,
      width: max(0.0, bounds.width - 68.0),
      height: 18.0
    )
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    thumbnailNode.isHighlighted = highlighted
    UIView.animate(withDuration: highlighted ? 0.08 : 0.16) {
      self.titleLabel.alpha = highlighted ? 0.74 : 1.0
      self.subtitleLabel.alpha = highlighted ? 0.74 : 1.0
    }
  }

  func configure(
    title: String,
    subtitle: String,
    urlString: String?,
    isVideo: Bool,
    titleColor: UIColor,
    subtitleColor: UIColor,
    placeholderTintColor: UIColor,
    placeholderBackgroundColor: UIColor
  ) {
    titleLabel.text = title
    titleLabel.textColor = titleColor
    subtitleLabel.text = subtitle
    subtitleLabel.textColor = subtitleColor
    thumbnailNode.configure(urlString: urlString, isVideo: isVideo)
    thumbnailNode.applyTheme(
      placeholderTintColor: placeholderTintColor,
      placeholderBackgroundColor: placeholderBackgroundColor
    )
  }
}

private final class ChatProfileVoiceContentCell: UITableViewCell, VoicePlayableCell {
  static let reuseIdentifier = "ChatProfileVoiceContentCell"

  let voiceButtonView = VoicePlayProgressView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let dateLabel = UILabel()
  private var messageId: String?
  private var mediaUrl: String?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    voiceButtonView.isUserInteractionEnabled = false
    contentView.addSubview(voiceButtonView)

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    contentView.addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    contentView.addSubview(subtitleLabel)

    dateLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    dateLabel.textAlignment = .right
    contentView.addSubview(dateLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let bounds = contentView.bounds.insetBy(dx: 16.0, dy: 8.0)

    let buttonSize: CGFloat = 44.0
    voiceButtonView.frame = CGRect(
      x: bounds.minX,
      y: bounds.minY + floor((bounds.height - buttonSize) * 0.5),
      width: buttonSize,
      height: buttonSize
    )

    let textX = voiceButtonView.frame.maxX + 12.0

    let dateWidth: CGFloat = 70.0
    dateLabel.frame = CGRect(
      x: bounds.maxX - dateWidth,
      y: bounds.minY + 6.0,
      width: dateWidth,
      height: 20.0
    )

    let textWidth = max(20.0, dateLabel.frame.minX - textX - 8.0)
    titleLabel.frame = CGRect(
      x: textX,
      y: bounds.minY + 6.0,
      width: textWidth,
      height: 20.0
    )

    subtitleLabel.frame = CGRect(
      x: textX,
      y: titleLabel.frame.maxY + 2.0,
      width: textWidth,
      height: 18.0
    )
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    UIView.animate(withDuration: highlighted ? 0.08 : 0.16) {
      self.contentView.alpha = highlighted ? 0.74 : 1.0
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
    voiceButtonView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
    voiceButtonView.setPlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
  }

  func configure(
    title: String,
    subtitle: String,
    row: ChatProfileRow,
    titleColor: UIColor,
    subtitleColor: UIColor,
    accentColor: UIColor
  ) {
    messageId = row.messageId
    mediaUrl = row.mediaUrl

    titleLabel.text = title
    titleLabel.textColor = titleColor

    subtitleLabel.text = subtitle
    subtitleLabel.textColor = subtitleColor

    let dateMs = row.timestampMs ?? 0
    if dateMs > 0 {
      let date = Date(timeIntervalSince1970: TimeInterval(dateMs) / 1000.0)
      let formatter = DateFormatter()
      formatter.dateStyle = .none
      formatter.timeStyle = .short
      dateLabel.text = formatter.string(from: date)
    } else {
      dateLabel.text = ""
    }
    dateLabel.textColor = subtitleColor.withAlphaComponent(0.6)

    voiceButtonView.applyStyle(fillColor: accentColor, iconTint: .white, ringTint: accentColor)
  }

  func applyVoicePlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat) {
    voiceButtonView.setPlaybackState(isPlaying: isPlaying, progress: progress, level: level)
  }

  func applyVoiceDownloadState(needsDownload: Bool, isDownloading: Bool, progress: CGFloat?) {
    voiceButtonView.setDownloadState(
      needsDownload: needsDownload,
      isDownloading: isDownloading,
      progress: progress
    )
  }
}

final class ChatProfileMainView: ExpoView, UITableViewDataSource, UITableViewDelegate {
  public var onViewportChanged = EventDispatcher()
  public var onNativeEvent = EventDispatcher()

  @objc public var surfaceId: String = ""

  private let headerMaskContainer = UIView()
  private let headerMaskView = UIView()
  private let headerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerMaskOverlayView = UIView()
  private let headerMaskGradientLayer = CAGradientLayer()
  private let headerContainer = UIView()
  private let headerContentView = UIView()
  private let backButton = UIButton(type: .system)
  private let menuButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let stickyTabsContainer = UIView()
  private let stickyTabsView = ChatProfileTabStripView()
  private let floatingAvatarView: NativeProfileAvatarView

  private let heroHeaderView = UIView()
  private let heroBannerView = UIView()
  private let heroNameLabel = UILabel()
  private let heroHandleButton = UIButton(type: .system)
  private let heroBioLabel = UILabel()

  private let actionsStack = UIStackView()
  private let muteActionButton = ChatMainProfileActionNode()
  private let searchActionButton = ChatMainProfileActionNode()
  private let audioActionButton = ChatMainProfileActionNode()
  private let videoActionButton = ChatMainProfileActionNode()

  private var rows: [ChatProfileRow] = []
  private var mediaRows: [ChatProfileRow] = []
  private var voiceRows: [ChatProfileRow] = []
  private var gifRows: [ChatProfileRow] = []
  private var fileRows: [ChatProfileRow] = []
  private var pinnedRows: [ChatProfileRow] = []
  private var linkRows: [ChatProfileLinkItem] = []

  private var availableTabs: [ChatProfileTab] = []
  private var activeTab: ChatProfileTab = .media
  private weak var inlineTabsCell: ChatProfileTabStripCell?


  private var profileName = "User"
  private var profileHandle = ""
  private var profileBio = ""
  private var headerTitle = "Profile"
  private var headerSubtitle = ""
  private var avatarUri: String?
  private var isChatMuted = false
  private var isGroupOrChannel = false
  private var isOnline = false
  private var groupMemberCount: Int?
  private var groupMembers: [[String: Any]] = []

  private var engineChatId = ""
  private var enginePeerUserId = ""
  private var agentConfig: [String: Any]?
  private var avatarMorphProgress: CGFloat = 0.0
  private var currentHeroTop: CGFloat = 0.0
  private var currentCollapsedTop: CGFloat = 0.0
  private var currentTextColor: UIColor = .label
  private var currentSecondaryTextColor: UIColor = .secondaryLabel
  private var currentRowSeparatorColor: UIColor = UIColor(white: 0.0, alpha: 0.08)
  private var currentRowHighlightColor: UIColor = UIColor(white: 0.0, alpha: 0.04)
  private var currentRowCardColor: UIColor = UIColor.white
  private var currentRowAccentColor: UIColor = UIColor(
    red: 0.17, green: 0.65, blue: 0.71, alpha: 1.0)
  private var currentRowIconBackgroundColor: UIColor = UIColor(
    red: 0.17,
    green: 0.65,
    blue: 0.71,
    alpha: 0.12
  )
  private static let listDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  required init(appContext: AppContext? = nil) {
    floatingAvatarView = NativeProfileAvatarView(appContext: appContext)
    super.init(appContext: appContext)
    configureView()
    applyTheme()
    rebuildDerivedContent()
    reloadHeaderText()
    refreshHeroContent()
    rebuildMenu()
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    updateAvatarMetrics()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let safeTop = safeAreaInsets.top
    let headerHeight = safeTop + 60.0
    updateAvatarMetrics()

    headerMaskContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerHeight)
    headerMaskView.frame = headerMaskContainer.bounds
    headerMaskBlurView.frame = headerMaskView.bounds
    headerMaskOverlayView.frame = headerMaskBlurView.bounds
    headerMaskGradientLayer.frame = headerMaskView.bounds
    headerContainer.frame = headerMaskContainer.frame
    headerContentView.frame = CGRect(
      x: 12.0,
      y: safeTop + 8.0,
      width: max(0.0, bounds.width - 24.0),
      height: 44.0
    )
    backButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    menuButton.frame = CGRect(
      x: max(0.0, headerContentView.bounds.width - 44.0), y: 0.0, width: 44.0, height: 44.0)
    let textX = backButton.frame.maxX + 12.0
    let textWidth = menuButton.frame.minX - textX - 12.0
    let textAvailable = textWidth > 40.0
    titleLabel.frame =
      textAvailable ? CGRect(x: textX, y: 2.0, width: textWidth, height: 20.0) : .zero
    subtitleLabel.frame =
      textAvailable ? CGRect(x: textX, y: 22.0, width: textWidth, height: 16.0) : .zero
    titleLabel.textAlignment = .center
    subtitleLabel.textAlignment = .center

    tableView.frame = bounds
    tableView.scrollIndicatorInsets = UIEdgeInsets(
      top: headerHeight, left: 0.0, bottom: 0.0, right: 0.0)
    stickyTabsContainer.frame = CGRect(
      x: 12.0,
      y: headerHeight + 8.0,
      width: max(0.0, bounds.width - 24.0),
      height: availableTabs.isEmpty ? 0.0 : ChatProfileTabStripView.preferredHeight
    )
    stickyTabsView.frame = stickyTabsContainer.bounds

    layoutHeroHeaderViewIfNeeded(force: true)
    layoutFloatingAvatarView()
    updateAvatarMorphProgress()
    updateStickyTabsPresentation()
    bringSubviewToFront(headerMaskContainer)
    bringSubviewToFront(stickyTabsContainer)
    bringSubviewToFront(floatingAvatarView)
    bringSubviewToFront(headerContainer)

    onViewportChanged([
      "width": bounds.width,
      "height": bounds.height,
      "surfaceId": surfaceId,
    ])
  }

  func setProfileOnly(_ value: Bool) {
    _ = value
  }

  func setRows(_ rows: [[String: Any]]) {
    self.rows = rows.compactMap(ChatProfileRow.parse)
    rebuildDerivedContent()
    reloadDataKeepingSelection()
  }

  func setEngineSurfaceId(_ value: String) {
    _ = value
  }

  func setEngineChatId(_ value: String) {
    engineChatId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    fetchAgentConfigForCurrentChat()
  }

  func setEngineMyUserId(_ value: String) {
    _ = value
  }

  func setEnginePeerUserId(_ value: String) {
    enginePeerUserId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    tableView.reloadData()
    refreshAvatar()
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    _ = enabled
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    let isDarkValue =
      (rawAppearance["isDark"] as? Bool)
      ?? (rawAppearance["nativeThemeIsDark"] as? Bool)

    if let isDarkValue {
      overrideUserInterfaceStyle = isDarkValue ? .dark : .light
    }

    applyTheme()
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
  }

  func setHeaderTitle(_ value: String) {
    headerTitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    reloadHeaderText()
    refreshHeroContent()
  }

  func setHeaderSubtitle(_ value: String) {
    headerSubtitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    reloadHeaderText()
  }

  func setProfileName(_ value: String) {
    profileName = value.trimmingCharacters(in: .whitespacesAndNewlines)
    reloadHeaderText()
    refreshHeroContent()
  }

  func setProfileHandle(_ value: String) {
    profileHandle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    refreshHeroContent()
    tableView.reloadData()
  }

  func setProfileBio(_ value: String) {
    profileBio = value.trimmingCharacters(in: .whitespacesAndNewlines)
    refreshHeroContent()
    tableView.reloadData()
  }

  func setAvatarUri(_ value: String?) {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    avatarUri = normalized
    refreshAvatar()
  }

  func setIsOnline(_ value: Bool) {
    if isOnline == value { return }
    isOnline = value
    reloadHeaderText()
    refreshHeroContent()
  }

  func setIsChatMuted(_ value: Bool) {
    if isChatMuted == value { return }
    isChatMuted = value
    updateActionButtons()
    rebuildMenu()
    tableView.reloadData()
  }

  func setIsGroupOrChannel(_ value: Bool) {
    if isGroupOrChannel == value { return }
    isGroupOrChannel = value
    reloadHeaderText()
    refreshHeroContent()
    refreshAvatar()
    tableView.reloadData()
  }

  func setGroupMembers(_ members: [[String: Any]]) {
    groupMembers = members
    tableView.reloadData()
  }

  func setGroupMemberCount(_ value: Int?) {
    groupMemberCount = value
    tableView.reloadData()
  }

  func setAgentConfig(_ config: [String: Any]?) {
    agentConfig = normalizedAgentConfig(config, fallbackChatId: engineChatId)
    tableView.reloadData()
  }

  func setPage(_ value: String, animated: Bool) {
    _ = animated
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "agent" {
      presentAgentConfigEditor()
    }
  }

  private func configureView() {
    clipsToBounds = false

    addSubview(headerMaskContainer)
    headerMaskContainer.clipsToBounds = false
    headerMaskContainer.isUserInteractionEnabled = false
    headerMaskContainer.layer.zPosition = 20.0
    headerMaskContainer.alpha = 0.0
    headerMaskView.isUserInteractionEnabled = false
    headerMaskContainer.addSubview(headerMaskView)
    headerMaskView.addSubview(headerMaskBlurView)
    headerMaskBlurView.contentView.addSubview(headerMaskOverlayView)
    headerMaskGradientLayer.colors = [
      UIColor.black.withAlphaComponent(0.95).cgColor,
      UIColor.black.withAlphaComponent(0.72).cgColor,
      UIColor.clear.cgColor,
    ]
    headerMaskGradientLayer.locations = [0.0, 0.58, 1.0]
    headerMaskView.layer.mask = headerMaskGradientLayer
    addSubview(headerContainer)
    headerContainer.clipsToBounds = false
    headerContainer.addSubview(headerContentView)
    headerContainer.layer.zPosition = 60.0
    headerContentView.addSubview(backButton)
    headerContentView.addSubview(menuButton)
    headerContentView.addSubview(titleLabel)
    headerContentView.addSubview(subtitleLabel)

    backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    backButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)

    ChatMainProfileHeaderHelpers.applyProfileMenuButtonStyle(menuButton)
    if #available(iOS 14.0, *) {
      menuButton.showsMenuAsPrimaryAction = true
    } else {
      menuButton.addTarget(self, action: #selector(handleLegacyMenuPressed), for: .touchUpInside)
    }

    titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.isHidden = true
    subtitleLabel.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
    subtitleLabel.textAlignment = .center
    subtitleLabel.isHidden = true

    tableView.dataSource = self
    tableView.delegate = self
    tableView.separatorStyle = .none
    tableView.register(
      ChatProfileListRowCell.self, forCellReuseIdentifier: ChatProfileListRowCell.reuseIdentifier)
    tableView.register(
      ChatProfileTabStripCell.self, forCellReuseIdentifier: ChatProfileTabStripCell.reuseIdentifier)
    tableView.register(
      ChatProfileMediaContentCell.self,
      forCellReuseIdentifier: ChatProfileMediaContentCell.reuseIdentifier)
    tableView.register(
      ChatProfileVoiceContentCell.self,
      forCellReuseIdentifier: ChatProfileVoiceContentCell.reuseIdentifier)
    tableView.register(
      ChatProfileMediaGridRowCell.self,
      forCellReuseIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier)
    tableView.separatorInset = UIEdgeInsets(top: 0.0, left: 16.0, bottom: 0.0, right: 16.0)
    tableView.contentInsetAdjustmentBehavior = .never
    tableView.estimatedRowHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    if #available(iOS 15.0, *) {
      tableView.sectionHeaderTopPadding = 0.0
    }
    addSubview(tableView)

    stickyTabsContainer.alpha = 0.0
    stickyTabsContainer.isHidden = true
    stickyTabsContainer.clipsToBounds = false
    stickyTabsContainer.layer.zPosition = 54.0
    stickyTabsContainer.addSubview(stickyTabsView)
    addSubview(stickyTabsContainer)

    addSubview(floatingAvatarView)
    floatingAvatarView.clipsToBounds = false
    floatingAvatarView.isUserInteractionEnabled = false
    floatingAvatarView.layer.zPosition = 40.0
    bringSubviewToFront(headerMaskContainer)
    bringSubviewToFront(stickyTabsContainer)
    bringSubviewToFront(floatingAvatarView)
    bringSubviewToFront(headerContainer)

    configureHeroHeaderView()

    configureBackButtonStyle()

    updateActionButtons()
    refreshAvatar()
  }

  private func configureHeroHeaderView() {
    heroHeaderView.backgroundColor = .clear
    heroHeaderView.clipsToBounds = false

    heroBannerView.clipsToBounds = true
    heroBannerView.layer.cornerCurve = .continuous
    heroBannerView.layer.cornerRadius = 26.0
    heroHeaderView.addSubview(heroBannerView)

    heroNameLabel.font = UIFont.systemFont(ofSize: 30.0, weight: .bold)
    heroNameLabel.textAlignment = .center
    heroBannerView.addSubview(heroNameLabel)

    heroHandleButton.titleLabel?.font = UIFont.systemFont(ofSize: 18.0, weight: .medium)
    heroHandleButton.titleLabel?.lineBreakMode = .byTruncatingTail
    heroHandleButton.contentHorizontalAlignment = .center
    heroHandleButton.addTarget(
      self, action: #selector(handleIdentifierPressed), for: .touchUpInside)
    heroBannerView.addSubview(heroHandleButton)

    heroBioLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
    heroBioLabel.textAlignment = .center
    heroBioLabel.numberOfLines = 0
    heroBannerView.addSubview(heroBioLabel)

    actionsStack.axis = .horizontal
    actionsStack.distribution = .fillEqually
    actionsStack.alignment = .fill
    actionsStack.spacing = 8.0
    actionsStack.semanticContentAttribute = .forceLeftToRight
    heroBannerView.addSubview(actionsStack)

    [audioActionButton, videoActionButton, muteActionButton, searchActionButton].forEach {
      actionsStack.addArrangedSubview($0)
    }

    muteActionButton.addTarget(self, action: #selector(handleMutePressed), for: .touchUpInside)
    searchActionButton.addTarget(self, action: #selector(handleSearchPressed), for: .touchUpInside)
    audioActionButton.addTarget(self, action: #selector(handleAudioPressed), for: .touchUpInside)
    videoActionButton.addTarget(self, action: #selector(handleVideoPressed), for: .touchUpInside)

    tableView.tableHeaderView = heroHeaderView
  }

  private func layoutHeroHeaderViewIfNeeded(force: Bool) {
    guard tableView.bounds.width > 0 else { return }

    let width = tableView.bounds.width
    let sideInset: CGFloat = 16.0
    let bannerTop: CGFloat = 0.0
    let baseBannerHeight = min(max(bounds.height * 0.40, 220.0), 420.0)
    let stretch = max(0.0, -tableView.contentOffset.y)
    let bannerHeight = baseBannerHeight + stretch
    let bannerFrame = CGRect(
      x: sideInset, y: bannerTop, width: width - (sideInset * 2.0), height: bannerHeight)
    heroBannerView.frame = bannerFrame

    var y =
      currentHeroTop
      + NativeProfileAvatarHeroMetrics.expandedSize
      + NativeProfileAvatarHeroMetrics.bottomSpacing

    let nameHeight: CGFloat = 36.0
    heroNameLabel.frame = CGRect(
      x: 12.0, y: y, width: heroBannerView.bounds.width - 24.0, height: nameHeight)
    y = heroNameLabel.frame.maxY + 2.0

    let handleHeight: CGFloat = 24.0
    heroHandleButton.frame = CGRect(
      x: 12.0, y: y, width: heroBannerView.bounds.width - 24.0, height: handleHeight)
    y = heroHandleButton.frame.maxY + 8.0

    let bioText = heroBioLabel.text ?? ""
    let bioVisible = !bioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let maxBioWidth = heroBannerView.bounds.width - 26.0
    let bioHeight: CGFloat = {
      guard bioVisible else { return 0.0 }
      let size = CGSize(width: maxBioWidth, height: CGFloat.greatestFiniteMagnitude)
      let rect = (bioText as NSString).boundingRect(
        with: size,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: heroBioLabel.font as Any],
        context: nil
      )
      return ceil(max(20.0, rect.height))
    }()

    heroBioLabel.isHidden = !bioVisible
    if bioVisible {
      heroBioLabel.frame = CGRect(x: 13.0, y: y, width: maxBioWidth, height: bioHeight)
      y = heroBioLabel.frame.maxY + 14.0
    }

    let actionsHeight: CGFloat = 72.0
    let actionsY = min(
      max(y, heroBannerView.bounds.height - actionsHeight - 14.0),
      heroBannerView.bounds.height - actionsHeight - 8.0)
    actionsStack.frame = CGRect(
      x: 10.0, y: actionsY, width: heroBannerView.bounds.width - 20.0, height: actionsHeight)

    let headerHeight = heroBannerView.frame.maxY + 10.0
    if force || heroHeaderView.frame.width != width
      || abs(heroHeaderView.frame.height - headerHeight) > 0.5
    {
      heroHeaderView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: headerHeight)
      tableView.tableHeaderView = heroHeaderView
    }
  }

  private func updateAvatarMetrics() {
    let topInset = safeAreaInsets.top
    currentHeroTop = NativeProfileAvatarHeroMetrics.expandedTop(for: topInset)
    currentCollapsedTop = NativeProfileAvatarHeroMetrics.collapsedTop(for: topInset)

    floatingAvatarView.setExpandedSize(NativeProfileAvatarHeroMetrics.expandedSize)
    floatingAvatarView.setCollapsedSize(NativeProfileAvatarHeroMetrics.collapsedSize)
    floatingAvatarView.setExpandedTopInset(currentHeroTop)
    floatingAvatarView.setCollapsedTopInset(currentCollapsedTop)
  }

  private func layoutFloatingAvatarView() {
    guard bounds.width > 0 else { return }
    let hostHeight = NativeProfileAvatarHeroMetrics.hostHeight(for: safeAreaInsets.top)

    floatingAvatarView.frame = CGRect(
      x: 0.0,
      y: 0.0,
      width: bounds.width,
      height: hostHeight
    )
    updateAvatarMetrics()
  }

  private func applyTheme() {
    let isDark = traitCollection.userInterfaceStyle == .dark
    let background =
      isDark
      ? UIColor(red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 20.0 / 255.0, alpha: 1.0)
      : UIColor(red: 246.0 / 255.0, green: 246.0 / 255.0, blue: 248.0 / 255.0, alpha: 1.0)

    let text = isDark ? UIColor.white : UIColor.black
    let secondary = isDark ? UIColor(white: 0.76, alpha: 1.0) : UIColor(white: 0.44, alpha: 1.0)
    let card =
      isDark
      ? UIColor(red: 35.0 / 255.0, green: 35.0 / 255.0, blue: 38.0 / 255.0, alpha: 0.96)
      : UIColor.white
    let rowAccent =
      isDark
      ? UIColor(red: 77 / 255, green: 217 / 255, blue: 229 / 255, alpha: 1.0)
      : UIColor(red: 0 / 255, green: 122 / 255, blue: 124 / 255, alpha: 1.0)
    let fallbackAvatarBackground =
      isDark
      ? UIColor(red: 248 / 255, green: 246 / 255, blue: 252 / 255, alpha: 20 / 255)
      : UIColor(red: 26 / 255, green: 26 / 255, blue: 31 / 255, alpha: 13 / 255)
    let fallbackAvatarIconTint = text

    backgroundColor = background
    headerContainer.backgroundColor = .clear
    headerMaskContainer.backgroundColor = .clear
    headerMaskBlurView.effect = { () -> UIVisualEffect? in
      if #available(iOS 26.0, *) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        return effect
      }
      return UIBlurEffect(style: isDark ? .systemMaterialDark : .systemMaterialLight)
    }()
    headerMaskOverlayView.backgroundColor =
      (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.12 : 0.10)

    titleLabel.textColor = text
    subtitleLabel.textColor = secondary
    backButton.tintColor = text
    menuButton.tintColor = text

    tableView.backgroundColor = .clear
    tableView.separatorColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.08)
      : UIColor(white: 0.0, alpha: 0.08)

    heroNameLabel.textColor = text
    heroHandleButton.setTitleColor(secondary, for: .normal)
    heroBioLabel.textColor = secondary
    heroBannerView.backgroundColor = .clear
    stickyTabsContainer.backgroundColor = .clear
    stickyTabsView.applyTheme(isDark: isDark)
    floatingAvatarView.setIslandCoverUIColor(background)
    floatingAvatarView.setFallbackBackgroundUIColor(fallbackAvatarBackground)
    floatingAvatarView.setFallbackIconTintUIColor(fallbackAvatarIconTint)

    currentTextColor = text
    currentSecondaryTextColor = secondary
    currentRowSeparatorColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.08)
      : UIColor(white: 0.0, alpha: 0.08)
    currentRowHighlightColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.06)
      : UIColor(white: 0.0, alpha: 0.04)
    currentRowCardColor =
      isDark
      ? UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.72)
      : card.withAlphaComponent(0.98)
    currentRowAccentColor = rowAccent
    currentRowIconBackgroundColor = rowAccent.withAlphaComponent(0.12)

    [muteActionButton, searchActionButton, audioActionButton, videoActionButton].forEach {
      $0.applyTheme(foreground: text, background: card)
    }
    configureBackButtonStyle()

    reloadDataKeepingSelection()
  }

  private func resolvedDefaultSubtitleText() -> String {
    if isOnline {
      return "Online"
    }

    if !headerSubtitle.isEmpty {
      return headerSubtitle
    }

    return isGroupOrChannel ? "Group Profile" : "Profile"
  }

  private func resolvedActiveTabSubtitleText() -> String? {
    guard !availableTabs.isEmpty else { return nil }
    return "\(sharedCount(for: activeTab)) \(sharedTitle(for: activeTab))"
  }

  private func resolvedHeroSubheaderText() -> String {
    return resolvedActiveTabSubtitleText() ?? resolvedIdentifierText()
  }

  private func reloadHeaderText() {
    titleLabel.text =
      profileName.isEmpty ? (headerTitle.isEmpty ? "Profile" : headerTitle) : profileName
    subtitleLabel.text = resolvedActiveTabSubtitleText() ?? resolvedDefaultSubtitleText()
  }

  private func refreshHeroSubheader() {
    let subheader = resolvedHeroSubheaderText()
    heroHandleButton.setTitle(subheader, for: .normal)
    heroHandleButton.isHidden = subheader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func refreshHeroContent() {
    let resolvedName =
      profileName.isEmpty ? (headerTitle.isEmpty ? "User" : headerTitle) : profileName
    heroNameLabel.text = resolvedName
    floatingAvatarView.setFallbackText(resolvedAvatarFallbackText())

    refreshHeroSubheader()

    let bio = profileBio.trimmingCharacters(in: .whitespacesAndNewlines)
    heroBioLabel.text = bio

    updateActionButtons()
    layoutHeroHeaderViewIfNeeded(force: true)
  }

  private func updateActionButtons() {
    muteActionButton.configure(
      title: isChatMuted ? "Unmute" : "Mute", symbol: isChatMuted ? "bell" : "bell.slash")
    searchActionButton.configure(title: "Search", symbol: "magnifyingglass")
    audioActionButton.configure(title: "Call", symbol: "phone")
    videoActionButton.configure(title: "Video", symbol: "video")
  }

  private func configureBackButtonStyle() {
    let symbol = UIImage(
      systemName: "chevron.left",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)
    )

    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.cornerStyle = .capsule
      config.image = symbol
      config.contentInsets = NSDirectionalEdgeInsets(
        top: 10.0, leading: 10.0, bottom: 10.0, trailing: 10.0)
      backButton.configuration = config
      return
    }

    backButton.configuration = nil
    backButton.setImage(symbol, for: .normal)
    backButton.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.92)
    backButton.layer.cornerRadius = 21.0
    backButton.layer.cornerCurve = .continuous
  }

  private func updateAvatarMorphProgress() {
    guard tableView.bounds.width > 0 else { return }

    let offset = max(0.0, tableView.contentOffset.y)
    let travelDistance = max(1.0, currentHeroTop - currentCollapsedTop)
    let progress = max(0.0, min(1.0, offset / travelDistance))
    avatarMorphProgress = progress
    floatingAvatarView.setScrollOffset(offset)
    headerMaskContainer.alpha = max(0.0, min(1.0, (progress - 0.06) / 0.24))

    let textAlpha = max(0.0, (progress - 0.5) * 2.0)
    titleLabel.isHidden = textAlpha == 0
    subtitleLabel.isHidden =
      textAlpha == 0
      || (subtitleLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    titleLabel.alpha = textAlpha
    subtitleLabel.alpha = textAlpha
    updateStickyTabsPresentation()
  }

  private func refreshAvatar() {
    floatingAvatarView.setFallbackText(resolvedAvatarFallbackText())
    floatingAvatarView.setImageUri(resolvedAvatarUri())
  }

  private func resolvedAvatarUri() -> String? {
    return ChatNativeAvatarURLResolver.resolve(
      rawAvatar: avatarUri,
      peerUserId: enginePeerUserId,
      chatId: engineChatId,
      preferPushAvatar: !isGroupOrChannel
    )
  }

  private func resolvedAvatarFallbackText() -> String {
    let resolvedName =
      profileName.isEmpty ? (headerTitle.isEmpty ? "User" : headerTitle) : profileName
    let trimmed = resolvedName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "U" : String(trimmed.prefix(1)).uppercased()
  }

  private func rebuildDerivedContent() {
    mediaRows = rows.filter { ["image", "video", "sticker"].contains($0.type) }
    voiceRows = rows.filter { $0.type == "voice" }
    gifRows = rows.filter { $0.type == "gif" }
    fileRows = rows.filter { ["file", "music"].contains($0.type) }
    pinnedRows = rows.filter { $0.isPinned }

    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var links: [ChatProfileLinkItem] = []
    for row in rows {
      guard let detector else { continue }
      let candidates = [row.text, row.mediaUrl ?? ""]

      for candidate in candidates {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let nsText = trimmed as NSString
        let matches = detector.matches(
          in: trimmed, options: [], range: NSRange(location: 0, length: nsText.length))
        if let firstURL = matches.first?.url?.absoluteString, !firstURL.isEmpty {
          links.append(ChatProfileLinkItem(row: row, url: firstURL))
          break
        }
      }
    }
    linkRows = links

    var tabs: [ChatProfileTab] = []
    if !mediaRows.isEmpty { tabs.append(.media) }
    if !voiceRows.isEmpty { tabs.append(.voice) }
    if !gifRows.isEmpty { tabs.append(.gifs) }
    if !fileRows.isEmpty { tabs.append(.files) }
    if !linkRows.isEmpty { tabs.append(.links) }
    if !pinnedRows.isEmpty { tabs.append(.pinned) }
    availableTabs = tabs
    if !availableTabs.contains(activeTab), let first = availableTabs.first {
      activeTab = first
    }
    reloadHeaderText()
    refreshHeroSubheader()
    syncTabViews()
  }

  private func currentInfoRows() -> [ChatProfileInfoRow] {
    var result: [ChatProfileInfoRow] = []
    if isGroupOrChannel {
      result.append(.members)
      result.append(.agent)
    } else {
      result.append(.identifier)
    }

    if !profileBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      result.append(.bio)
    }

    return result
  }

  private func sharedCount(for tab: ChatProfileTab) -> Int {
    switch tab {
    case .media:
      return mediaRows.count
    case .voice:
      return voiceRows.count
    case .gifs:
      return gifRows.count
    case .files:
      return fileRows.count
    case .links:
      return linkRows.count
    case .pinned:
      return pinnedRows.count
    }
  }

  private func sharedTitle(for tab: ChatProfileTab) -> String {
    switch tab {
    case .media:
      return "Media"
    case .voice:
      return "Voice"
    case .gifs:
      return "GIFs"
    case .files:
      return "Files"
    case .links:
      return "Links"
    case .pinned:
      return "Pinned"
    }
  }

  private func sharedIconName(for tab: ChatProfileTab) -> String {
    switch tab {
    case .media:
      return "photo.on.rectangle.angled"
    case .voice:
      return "waveform"
    case .gifs:
      return "sparkles.tv"
    case .files:
      return "doc.text.fill"
    case .links:
      return "link"
    case .pinned:
      return "pin.fill"
    }
  }

  private func groupMembersSummary() -> String {
    let names = groupMembers.compactMap { member -> String? in
      let displayName =
        (member["name"] as? String)
        ?? (member["displayName"] as? String)
        ?? (member["username"] as? String)
        ?? (member["userId"] as? String)
      let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }
    guard !names.isEmpty else { return "View all participants" }
    return names.prefix(3).joined(separator: ", ")
  }

  private func configureListRowCell(
    _ cell: ChatProfileListRowCell,
    title: String,
    subtitle: String,
    value: String = "",
    iconName: String,
    showsSeparator: Bool,
    showsChevron: Bool = true
  ) {
    cell.rowNode.configure(
      title: title,
      subtitle: subtitle,
      value: value,
      showsSeparator: showsSeparator,
      iconName: iconName,
      iconTintColor: currentRowAccentColor,
      iconBackgroundColor: currentRowIconBackgroundColor,
      showsChevron: showsChevron
    )
    cell.rowNode.applyTheme(
      titleColor: currentTextColor,
      subtitleColor: currentSecondaryTextColor,
      separatorColor: currentRowSeparatorColor,
      highlightedColor: currentRowHighlightColor,
      valueColor: currentSecondaryTextColor
    )
    cell.accessoryType = .none
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .clear
    if #available(iOS 14.0, *) {
      var background = UIBackgroundConfiguration.listGroupedCell()
      background.backgroundColor = currentRowCardColor
      background.cornerRadius = 22.0
      cell.backgroundConfiguration = background
    } else {
      let backgroundView = UIView()
      backgroundView.backgroundColor = currentRowCardColor
      backgroundView.layer.cornerRadius = 22.0
      backgroundView.layer.cornerCurve = .continuous
      cell.backgroundView = backgroundView
    }
  }

  private func resolvedBioPreview() -> String {
    let bio = profileBio.trimmingCharacters(in: .whitespacesAndNewlines)
    return bio.isEmpty ? "No bio" : bio
  }

  private func resolvedIdentifierPreview() -> String {
    let value = resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "Unavailable" : value
  }

  private func resolvedAgentValue() -> String {
    guard let config = agentConfig else { return "Off" }
    return normalizedAgentEnabledValue(config["enabled"], defaultValue: true) ? "On" : "Off"
  }

  private func resolvedAgentSubtitle() -> String {
    guard let config = agentConfig else { return "Not configured" }
    let name = normalizedAgentString(config["name"]) ?? "Vibe AI"
    let docs = getAgentDocuments().count
    return "\(name) • \(docs) docs"
  }

  private func resolveSectionTitle(_ section: Section) -> String? {
    switch section {
    case .info:
      return isGroupOrChannel ? "Overview" : nil
    case .tabs, .content:
      return nil
    }
  }

  private func tabButtonTitle(_ tab: ChatProfileTab) -> String {
    sharedTitle(for: tab)
  }

  private func currentContentCount() -> Int {
    switch activeTab {
    case .media:
      return Int(ceil(Double(mediaRows.count) / 3.0))
    case .voice:
      return voiceRows.count
    case .gifs:
      return gifRows.count
    case .files:
      return fileRows.count
    case .links:
      return linkRows.count
    case .pinned:
      return pinnedRows.count
    }
  }

  private func contentRow(at index: Int) -> ChatProfileRow? {
    switch activeTab {
    case .media:
      guard mediaRows.indices.contains(index) else { return nil }
      return mediaRows[index]
    case .voice:
      guard voiceRows.indices.contains(index) else { return nil }
      return voiceRows[index]
    case .gifs:
      guard gifRows.indices.contains(index) else { return nil }
      return gifRows[index]
    case .files:
      guard fileRows.indices.contains(index) else { return nil }
      return fileRows[index]
    case .links:
      guard linkRows.indices.contains(index) else { return nil }
      return linkRows[index].row
    case .pinned:
      guard pinnedRows.indices.contains(index) else { return nil }
      return pinnedRows[index]
    }
  }

  private func contentSubtitle(for row: ChatProfileRow) -> String {
    switch activeTab {
    case .media:
      return formattedRowDate(row) ?? "Media"
    case .voice:
      return [formattedFileSize(row.fileSize), formattedRowDate(row)].compactMap { $0 }
        .joined(separator: " · ")
    case .gifs:
      return formattedRowDate(row) ?? "GIF"
    case .files:
      return [formattedFileSize(row.fileSize), formattedRowDate(row)].compactMap { $0 }
        .joined(separator: " · ")
    case .links:
      return formattedRowDate(row) ?? "Link"
    case .pinned:
      return formattedRowDate(row) ?? "Pinned"
    }
  }

  private func contentTitle(for row: ChatProfileRow, index: Int) -> String {
    switch activeTab {
    case .media:
      if row.type == "video" { return "Video" }
      if row.type == "sticker" { return "Sticker" }
      return "Photo"
    case .voice:
      return row.fileName ?? "Voice message"
    case .gifs:
      return "GIF"
    case .files:
      return row.fileName ?? "File"
    case .links:
      return linkRows[index].url
    case .pinned:
      let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? "Pinned message" : text
    }
  }

  private func reloadContentSectionWithoutAnimation() {
    guard tableView.numberOfSections > Section.content.rawValue else { return }

    UIView.performWithoutAnimation {
      tableView.reloadSections(IndexSet(integer: Section.content.rawValue), with: .none)
      tableView.layoutIfNeeded()
    }
  }

  private func switchToTab(_ nextTab: ChatProfileTab, animated: Bool) {
    guard availableTabs.contains(nextTab), nextTab != activeTab else { return }
    activeTab = nextTab
    reloadHeaderText()
    refreshHeroSubheader()
    syncTabViews()

    // Reload content in-place without any overlay or cross-fade.
    reloadContentSectionWithoutAnimation()

    // Scroll just enough so the inline tabs row sits right below the
    // header (at the sticky position). Content items appear directly
    // below the tabs — no over-scrolling past the tabs.
    guard animated else { return }
    scrollTabsIntoView(animated: true)
  }

  private func scrollTabsIntoView(animated: Bool) {
    guard !availableTabs.isEmpty else { return }
    let indexPath = IndexPath(row: 0, section: Section.tabs.rawValue)
    guard tableView.numberOfSections > indexPath.section,
      tableView.numberOfRows(inSection: indexPath.section) > 0
    else { return }

    let headerHeight = safeAreaInsets.top + 60.0
    let targetRect = tableView.rectForRow(at: indexPath)
    let stickyTop = headerHeight + 8.0
    let convertedRect = tableView.convert(targetRect, to: self)
    if convertedRect.minY >= stickyTop - 4.0 && convertedRect.minY <= stickyTop + 12.0 {
      return
    }
    let targetY = max(0.0, targetRect.minY - headerHeight - 8.0)
    if abs(tableView.contentOffset.y - targetY) > 1.0 {
      tableView.setContentOffset(CGPoint(x: 0.0, y: targetY), animated: animated)
    }
  }

  private func syncTabViews() {
    let configureTabs: (ChatProfileTabStripView) -> Void = { [self] view in
      view.applyTheme(isDark: traitCollection.userInterfaceStyle == .dark)
      view.onSelect = { [weak self] tab in
        self?.switchToTab(tab, animated: true)
      }
      view.configure(
        tabs: availableTabs,
        activeTab: activeTab,
        titleProvider: tabButtonTitle(_:))
    }

    if let inlineTabsCell {
      configureTabs(inlineTabsCell.tabsView)
    }
    configureTabs(stickyTabsView)
  }

  private func updateStickyTabsPresentation() {
    guard !availableTabs.isEmpty else {
      stickyTabsContainer.alpha = 0.0
      stickyTabsContainer.isHidden = true
      return
    }

    let tabsIndexPath = IndexPath(row: 0, section: Section.tabs.rawValue)
    guard tableView.numberOfSections > tabsIndexPath.section,
      tableView.numberOfRows(inSection: tabsIndexPath.section) > 0
    else {
      stickyTabsContainer.alpha = 0.0
      stickyTabsContainer.isHidden = true
      return
    }

    let convertedRect = tableView.convert(tableView.rectForRow(at: tabsIndexPath), to: self)
    let stickyTop = safeAreaInsets.top + 60.0 + 8.0
    let progress = max(0.0, min(1.0, (stickyTop - convertedRect.minY) / 28.0))
    stickyTabsContainer.isHidden = progress <= 0.0
    stickyTabsContainer.alpha = progress
    stickyTabsContainer.transform = CGAffineTransform(translationX: 0.0, y: (1.0 - progress) * -8.0)
  }

  private func resolvedIdentifierText() -> String {
    let handle = resolvedIdentifierRawValue()
    if handle.isEmpty {
      return "Username unavailable"
    }
    return handle
  }

  private func resolvedIdentifierRawValue() -> String {
    let handle = profileHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !handle.isEmpty, !handle.lowercased().hasPrefix("id:") {
      return handle.hasPrefix("@") ? handle : "@\(handle)"
    }

    let fallbackName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let compact =
      fallbackName
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .joined()
      .lowercased()
    if !compact.isEmpty {
      return "@\(compact)"
    }
    return ""
  }

  private func getAgentDocuments() -> [(id: String, name: String, url: String)] {
    return fileRows.compactMap { item in
      let url = item.mediaUrl ?? ""
      if url.contains("/api/agent/document/") || url.contains("/uploads/agent-docs/")
        || url.contains("/agent/document/") || url.contains("/agent-docs/")
      {
        return (
          id: item.messageId,
          name: (item.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? item.fileName!
            : "Document",
          url: url
        )
      }
      return nil
    }
  }

  private func rebuildMenu() {
    if #available(iOS 14.0, *) {
      let clearAction = UIAction(
        title: "Clear Chat",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
      }

      let deleteAction = UIAction(
        title: "Delete",
        image: UIImage(systemName: "xmark.bin"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "delete"])
      }

      let blockAction = UIAction(
        title: "Block",
        image: UIImage(systemName: "hand.raised"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "blockUser"])
      }

      menuButton.menu = UIMenu(children: [clearAction, deleteAction, blockAction])
    }
  }

  @objc private func handleBackPressed() {
    onNativeEvent(["type": "headerBack"])
  }

  @objc private func handleLegacyMenuPressed() {
    guard let presenter = topMostViewController() else { return }
    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

    sheet.addAction(
      UIAlertAction(title: "Clear Chat", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
      })

    sheet.addAction(
      UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "delete"])
      })

    sheet.addAction(
      UIAlertAction(title: "Block", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "blockUser"])
      })

    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    if let popover = sheet.popoverPresentationController {
      popover.sourceView = menuButton
      popover.sourceRect = menuButton.bounds
      popover.permittedArrowDirections = [.up, .down]
    }

    presenter.present(sheet, animated: true)
  }

  @objc private func handleMutePressed() {
    onNativeEvent(["type": "headerMenuAction", "action": "muteToggle"])
  }

  @objc private func handleSearchPressed() {
    onNativeEvent(["type": "headerSearchPressed"])
  }

  @objc private func handleAudioPressed() {
    onNativeEvent(["type": "headerAudioCallPressed"])
  }

  @objc private func handleVideoPressed() {
    onNativeEvent(["type": "headerVideoCallPressed"])
  }

  @objc private func handleIdentifierPressed() {
    if !availableTabs.isEmpty {
      scrollTabsIntoView(animated: true)
      return
    }

    let raw = resolvedIdentifierRawValue()
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    UIPasteboard.general.string = raw
    onNativeEvent(["type": "profileIdPressed", "id": raw])
  }

  private func reloadDataKeepingSelection() {
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
    syncTabViews()
    updateStickyTabsPresentation()
  }

  // MARK: UITableViewDataSource

  private enum Section: Int, CaseIterable {
    case info
    case tabs
    case content
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === tableView else { return }
    if scrollView.contentOffset.y < 0.0 {
      layoutHeroHeaderViewIfNeeded(force: false)
    }
    updateAvatarMorphProgress()
  }

  func numberOfSections(in tableView: UITableView) -> Int {
    return Section.allCases.count
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    guard let section = Section(rawValue: section) else { return 0 }

    switch section {
    case .info:
      return currentInfoRows().count
    case .tabs:
      return availableTabs.isEmpty ? 0 : 1
    case .content:
      return currentContentCount()
    }
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    guard let section = Section(rawValue: section) else { return nil }
    return resolveSectionTitle(section)
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    guard let section = Section(rawValue: section) else { return .leastNormalMagnitude }
    return resolveSectionTitle(section)?.isEmpty == false
      ? 30.0
      : .leastNormalMagnitude
  }

  func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    10.0
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    guard let section = Section(rawValue: indexPath.section) else {
      return UITableView.automaticDimension
    }

    switch section {
    case .info:
      let infoRows = currentInfoRows()
      guard infoRows.indices.contains(indexPath.row) else { return 68.0 }
      switch infoRows[indexPath.row] {
      case .bio:
        return 84.0
      default:
        return 68.0
      }
    case .tabs:
      return ChatProfileTabStripView.preferredHeight + 12.0
    case .content:
      switch activeTab {
      case .media:
        let cols: CGFloat = 3.0
        let padding: CGFloat = 16.0
        let gap: CGFloat = 2.0
        let avail = max(0.0, tableView.bounds.width - padding * 2.0 - gap * (cols - 1))
        let itemHeight = floor(avail / cols)
        return itemHeight + gap
      case .voice, .gifs:
        return 72.0
      default:
        return 68.0
      }
    }
  }

  private func contentListCell(
    _ tableView: UITableView,
    indexPath: IndexPath
  ) -> UITableViewCell {
    guard let row = contentRow(at: indexPath.row) else {
      return UITableViewCell(style: .default, reuseIdentifier: nil)
    }
    if activeTab == .voice {
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: ChatProfileVoiceContentCell.reuseIdentifier,
          for: indexPath
        ) as? ChatProfileVoiceContentCell
      else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }

      cell.configure(
        title: contentTitle(for: row, index: indexPath.row),
        subtitle: contentSubtitle(for: row),
        row: row,
        titleColor: currentTextColor,
        subtitleColor: currentSecondaryTextColor,
        accentColor: currentRowAccentColor
      )
      VoiceBubblePlaybackCoordinator.shared.bind(
        cell: cell,
        messageId: row.messageId,
        mediaURL: row.mediaUrl,
        mediaKey: row.mediaKey,
        fileName: row.fileName
      )
      return cell
    }

    if activeTab == .media {
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier,
          for: indexPath
        ) as? ChatProfileMediaGridRowCell
      else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }
      var items: [(url: String?, isVideo: Bool, thumbnailBase64: String?)] = []
      let startIndex = indexPath.row * 3
      for i in 0..<3 {
        let absIndex = startIndex + i
        if absIndex < mediaRows.count {
          let r = mediaRows[absIndex]
          items.append((url: r.mediaUrl, isVideo: r.type == "video", thumbnailBase64: r.thumbnailBase64))
        }
      }
      cell.configure(
        items: items,
        startIndex: startIndex,
        placeholderTintColor: currentTextColor.withAlphaComponent(0.72),
        placeholderBackgroundColor: currentRowCardColor
      )
      cell.onMediaTapped = { [weak self] index in
        self?.handleMediaGridTapped(at: index)
      }
      return cell
    }

    if activeTab == .gifs {
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: ChatProfileMediaContentCell.reuseIdentifier,
          for: indexPath
        ) as? ChatProfileMediaContentCell
      else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }
      cell.backgroundColor = .clear
      cell.contentView.backgroundColor = .clear
      if #available(iOS 14.0, *) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = currentRowCardColor
        background.cornerRadius = 22.0
        cell.backgroundConfiguration = background
      }
      cell.configure(
        title: contentTitle(for: row, index: indexPath.row),
        subtitle: contentSubtitle(for: row),
        urlString: row.mediaUrl,
        isVideo: row.type == "video",
        titleColor: currentTextColor,
        subtitleColor: currentSecondaryTextColor,
        placeholderTintColor: currentTextColor.withAlphaComponent(0.72),
        placeholderBackgroundColor: currentRowCardColor
      )
      return cell
    }

    guard
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ChatProfileListRowCell.reuseIdentifier,
        for: indexPath
      ) as? ChatProfileListRowCell
    else {
      return UITableViewCell(style: .default, reuseIdentifier: nil)
    }

    let isLast = indexPath.row == currentContentCount() - 1
    configureListRowCell(
      cell,
      title: contentTitle(for: row, index: indexPath.row),
      subtitle: contentSubtitle(for: row),
      iconName: sharedIconName(for: activeTab),
      showsSeparator: !isLast,
      showsChevron: activeTab != .pinned
    )
    return cell
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let section = Section(rawValue: indexPath.section) else {
      return UITableViewCell(style: .default, reuseIdentifier: nil)
    }

    switch section {
    case .info:
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: ChatProfileListRowCell.reuseIdentifier,
          for: indexPath
        ) as? ChatProfileListRowCell
      else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }
      let infoRows = currentInfoRows()
      guard infoRows.indices.contains(indexPath.row) else { return cell }
      let isLast = indexPath.row == infoRows.count - 1
      switch infoRows[indexPath.row] {
      case .members:
        configureListRowCell(
          cell,
          title: "Members",
          subtitle: groupMembersSummary(),
          value: "\(groupMemberCount ?? groupMembers.count)",
          iconName: "person.3.fill",
          showsSeparator: !isLast
        )
      case .identifier:
        configureListRowCell(
          cell,
          title: "Username",
          subtitle: resolvedIdentifierPreview(),
          iconName: "at",
          showsSeparator: !isLast,
          showsChevron: false
        )
      case .agent:
        configureListRowCell(
          cell,
          title: "Agent",
          subtitle: resolvedAgentSubtitle(),
          value: resolvedAgentValue(),
          iconName: "sparkles",
          showsSeparator: !isLast
        )
      case .bio:
        configureListRowCell(
          cell,
          title: "Bio",
          subtitle: resolvedBioPreview(),
          iconName: "text.quote",
          showsSeparator: !isLast,
          showsChevron: false
        )
      }

      return cell

    case .tabs:
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: ChatProfileTabStripCell.reuseIdentifier,
          for: indexPath
        ) as? ChatProfileTabStripCell
      else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }
      inlineTabsCell = cell
      cell.backgroundColor = .clear
      cell.contentView.backgroundColor = .clear
      cell.tabsView.applyTheme(isDark: traitCollection.userInterfaceStyle == .dark)
      cell.tabsView.onSelect = { [weak self] tab in
        self?.switchToTab(tab, animated: true)
      }
      cell.tabsView.configure(
        tabs: availableTabs,
        activeTab: activeTab,
        titleProvider: tabButtonTitle(_:))
      return cell

    case .content:
      return contentListCell(tableView, indexPath: indexPath)
    }
  }

  func tableView(
    _ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath
  ) {
    guard let section = Section(rawValue: indexPath.section) else { return }
    if section == .tabs, inlineTabsCell === cell {
      inlineTabsCell = nil
    } else if section == .content {
      if let voiceCell = cell as? VoicePlayableCell {
        VoiceBubblePlaybackCoordinator.shared.unbind(cell: voiceCell)
      }
    }
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    defer { tableView.deselectRow(at: indexPath, animated: true) }

    guard let section = Section(rawValue: indexPath.section) else { return }

    switch section {
    case .info:
      let infoRows = currentInfoRows()
      guard infoRows.indices.contains(indexPath.row) else { return }

      switch infoRows[indexPath.row] {
      case .members:
        onNativeEvent([
          "type": "profileMembersPressed",
          "chatId": engineChatId,
        ])
      case .identifier:
        handleIdentifierPressed()
      case .agent:
        if isGroupOrChannel {
          presentAgentConfigEditor()
        }
      case .bio:
        break
      }

    case .tabs:
      break

    case .content:
      guard let row = contentRow(at: indexPath.row) else { return }
      if activeTab == .voice {
        if let cell = tableView.cellForRow(at: indexPath) as? VoicePlayableCell {
          VoiceBubblePlaybackCoordinator.shared.toggle(
            cell: cell,
            messageId: row.messageId,
            mediaURL: row.mediaUrl,
            mediaKey: row.mediaKey,
            fileName: row.fileName
          )
        }
        return
      }

      if activeTab == .media {
        return
      }

      var payload: [String: Any] = [
        "type": "profileContentPressed",
        "tab": activeTab.rawValue,
        "messageId": row.messageId,
      ]

      if activeTab == .links {
        payload["url"] = linkRows[indexPath.row].url
      } else if let mediaUrl = row.mediaUrl, !mediaUrl.isEmpty {
        payload["url"] = mediaUrl
      }

      onNativeEvent(payload)
    }
  }

  private func handleMediaGridTapped(at index: Int) {
    guard activeTab == .media, index >= 0, index < mediaRows.count else { return }
    let row = mediaRows[index]

    if row.type == "video", let mediaUrl = row.mediaUrl, !mediaUrl.isEmpty {
      let resolvedUrlStr = ChatEngine.shared.resolveURLForOpen(mediaUrl) ?? mediaUrl
      guard let url = URL(string: resolvedUrlStr) else { return }
      
      var options: [String: Any]? = nil
      if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https",
         let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
        options = ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": authHeader]]
      }
      
      let asset = AVURLAsset(url: url, options: options)
      let controller = ChatVideoEditViewController(
        asset: asset,
        initialCaption: row.text,
        headerTitle: "Video",
        previewOnly: true
      )
      
      if let presenter = topMostViewController() {
        presenter.present(controller, animated: true)
      }
      return
    }

    onNativeEvent([
      "type": "profileContentPressed",
      "tab": activeTab.rawValue,
      "messageId": row.messageId,
      "url": row.mediaUrl ?? ""
    ])
  }

  // MARK: Agent Config

  private func fetchAgentConfigForCurrentChat() {
    let currentId = engineChatId
    guard !currentId.isEmpty else { return }
    ChatEngine.shared.fetchAgentConfig(chatId: currentId) { [weak self] config in
      guard let self, self.engineChatId == currentId else { return }
      self.agentConfig = self.normalizedAgentConfig(config, fallbackChatId: currentId)
      self.tableView.reloadData()
    }
  }

  private func presentAgentConfigEditor() {
    guard isGroupOrChannel else {
      onNativeEvent(["type": "headerAgentPressed"])
      return
    }

    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }

    let controller = ChatAgentConfigViewController()
    controller.chatId = chatId
    controller.agentConfig = agentConfig
    controller.documents = getAgentDocuments()
    controller.onSave = { [weak self] config in
      guard let self else { return }
      let normalized = self.normalizedAgentConfig(config, fallbackChatId: chatId) ?? config
      ChatEngine.shared.saveAgentConfig(chatId: chatId, config: normalized) { [weak self] success in
        guard let self else { return }
        if success {
          self.agentConfig = normalized
          self.tableView.reloadData()
        }
      }
    }

    controller.onDelete = { [weak self] in
      guard let self else { return }
      ChatEngine.shared.deleteAgentConfig(chatId: chatId) { [weak self] success in
        guard let self else { return }
        if success {
          self.agentConfig = nil
          self.tableView.reloadData()
        }
      }
    }

    if let presenter = topMostViewController() {
      if let nav = presenter.navigationController {
        nav.pushViewController(controller, animated: true)
      } else {
        let navigation = UINavigationController(rootViewController: controller)
        presenter.present(navigation, animated: true)
      }
    }

    onNativeEvent(["type": "headerAgentPressed"])
  }

  private func normalizedAgentConfig(_ config: [String: Any]?, fallbackChatId: String)
    -> [String: Any]?
  {
    guard let config else { return nil }
    var normalized: [String: Any] = [:]

    let resolvedChatId =
      normalizedAgentString(config["chat_id"]) ?? normalizedAgentString(config["chatId"])
      ?? fallbackChatId
    normalized["chat_id"] = resolvedChatId

    normalized["name"] = normalizedAgentString(config["name"]) ?? "Vibe AI"

    let resolvedPrompt =
      normalizedAgentString(config["system_prompt"]) ?? normalizedAgentString(
        config["systemPrompt"])
      ?? ""
    normalized["system_prompt"] = resolvedPrompt

    normalized["enabled"] = normalizedAgentEnabledValue(config["enabled"], defaultValue: true)

    if let enabledTools = normalizedAgentToolList(config["enabled_tools"])
      ?? normalizedAgentToolList(config["enabledTools"]),
      !enabledTools.isEmpty
    {
      normalized["enabled_tools"] = enabledTools
    }

    if let id = normalizedAgentString(config["id"]), !id.isEmpty {
      normalized["id"] = id
    }

    if let avatar = normalizedAgentString(config["avatar_url"])
      ?? normalizedAgentString(config["avatarUrl"])
    {
      normalized["avatar_url"] = avatar
    }

    if let createdBy = normalizedAgentString(config["created_by"])
      ?? normalizedAgentString(config["createdBy"])
    {
      normalized["created_by"] = createdBy
    }

    return normalized
  }

  private func normalizedAgentString(_ rawValue: Any?) -> String? {
    if let string = rawValue as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = rawValue as? NSNumber {
      return number.stringValue
    }
    return nil
  }

  private func normalizedAgentEnabledValue(_ rawValue: Any?, defaultValue: Bool) -> Bool {
    guard let rawValue else { return defaultValue }
    if let boolValue = rawValue as? Bool { return boolValue }
    if let numberValue = rawValue as? NSNumber { return numberValue.boolValue }
    if let stringValue = rawValue as? String {
      switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "1", "yes", "on":
        return true
      case "false", "0", "no", "off":
        return false
      default:
        break
      }
    }
    return defaultValue
  }

  private func normalizedAgentToolList(_ rawValue: Any?) -> [String]? {
    guard let rawArray = rawValue as? [Any] else { return nil }
    let normalized =
      rawArray
      .compactMap { value -> String? in
        if let text = value as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
          return number.stringValue
        }
        return nil
      }
    return normalized.isEmpty ? nil : normalized
  }

  // MARK: Formatting

  private func formattedRowDate(_ row: ChatProfileRow) -> String? {
    guard let timestampMs = row.timestampMs, timestampMs > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    return Self.listDateFormatter.string(from: date)
  }

  private func formattedFileSize(_ bytes: Int64?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    if bytes < 1024 {
      return "\(bytes) B"
    }
    if bytes < 1024 * 1024 {
      return String(format: "%.1f KB", Double(bytes) / 1024.0)
    }
    return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
  }

  private func topMostViewController() -> UIViewController? {
    let root = window?.rootViewController
    var current = root
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }
}
