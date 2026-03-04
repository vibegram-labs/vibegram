import ExpoModulesCore
import UIKit

private struct ChatProfileRow {
  let messageId: String
  let type: String
  let text: String
  let mediaUrl: String?
  let fileName: String?
  let fileSize: Int64?
  let timestampMs: Int64?
  let isPinned: Bool

  static func parse(_ raw: [String: Any]) -> ChatProfileRow? {
    let message = raw["message"] as? [String: Any] ?? raw
    let messageId =
      (message["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? UUID().uuidString
    let type = ((message["type"] as? String) ?? (raw["type"] as? String) ?? "text").lowercased()
    let text = (message["text"] as? String) ?? (raw["text"] as? String) ?? ""
    let mediaUrl = (message["mediaUrl"] as? String) ?? (raw["mediaUrl"] as? String)
    let fileName = (message["fileName"] as? String) ?? (raw["fileName"] as? String)

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

    return ChatProfileRow(
      messageId: messageId,
      type: type,
      text: text,
      mediaUrl: mediaUrl,
      fileName: fileName,
      fileSize: fileSize,
      timestampMs: timestampMs,
      isPinned: isPinned
    )
  }
}

private struct ChatProfileLinkItem {
  let row: ChatProfileRow
  let url: String
}

private enum ChatProfileTab: String, CaseIterable {
  case media
  case music
  case files
  case links
  case pinned

  var label: String {
    switch self {
    case .media:
      return "Media"
    case .music:
      return "Music"
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

private final class ChatProfileTabsCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileTabsCell"

  private let segmentedControl = UISegmentedControl(items: [])
  private var onChanged: ((Int) -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    segmentedControl.addTarget(self, action: #selector(handleValueChanged), for: .valueChanged)
    if #available(iOS 13.0, *) {
      segmentedControl.selectedSegmentTintColor = UIColor.systemGray5
    }
    contentView.addSubview(segmentedControl)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    segmentedControl.frame = contentView.bounds.insetBy(dx: 16.0, dy: 6.0)
  }

  func configure(
    titles: [String],
    selectedIndex: Int,
    onChanged: @escaping (Int) -> Void
  ) {
    self.onChanged = onChanged

    while segmentedControl.numberOfSegments > 0 {
      segmentedControl.removeSegment(at: 0, animated: false)
    }

    for (index, title) in titles.enumerated() {
      segmentedControl.insertSegment(withTitle: title, at: index, animated: false)
    }

    if titles.indices.contains(selectedIndex) {
      segmentedControl.selectedSegmentIndex = selectedIndex
    } else {
      segmentedControl.selectedSegmentIndex = UISegmentedControl.noSegment
    }
  }

  @objc private func handleValueChanged() {
    onChanged?(segmentedControl.selectedSegmentIndex)
  }
}

final class ChatProfileMainView: ExpoView, UITableViewDataSource, UITableViewDelegate {
  public var onViewportChanged = EventDispatcher()
  public var onNativeEvent = EventDispatcher()

  @objc public var surfaceId: String = ""

  private let headerContainer = UIView()
  private let headerMaskView = UIView()
  private let headerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerMaskOverlayView = UIView()
  private let headerMaskGradientLayer = CAGradientLayer()
  private let headerContentView = UIView()
  private let backButton = UIButton(type: .system)
  private let menuButton = UIButton(type: .system)
  private let headerAvatarGlassView = UIVisualEffectView(effect: nil)
  private let headerAvatarImageView = UIImageView()
  private let headerAvatarFallbackView = UIView()
  private let headerAvatarFallbackIconView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)

  private let heroHeaderView = UIView()
  private let heroBannerView = UIView()
  private let heroBannerImageView = UIImageView()
  private let heroBannerFallbackView = UIView()
  private let heroBannerFallbackIconView = UIImageView()
  private let heroBannerShadeLayer = CAGradientLayer()
  private let avatarView = UIImageView()
  private let avatarFallbackView = UIView()
  private let avatarFallbackIconView = UIImageView()
  private let onlineDotView = UIView()
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
  private var musicRows: [ChatProfileRow] = []
  private var fileRows: [ChatProfileRow] = []
  private var pinnedRows: [ChatProfileRow] = []
  private var linkRows: [ChatProfileLinkItem] = []

  private var availableTabs: [ChatProfileTab] = []
  private var activeTab: ChatProfileTab = .media

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

  private var avatarLoadTask: URLSessionDataTask?
  private static let listDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    configureView()
    applyTheme()
    rebuildDerivedContent()
    reloadHeaderText()
    refreshHeroContent()
    rebuildMenu()
  }

  deinit {
    avatarLoadTask?.cancel()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let safeTop = safeAreaInsets.top
    let headerHeight = safeTop + 60.0

    headerContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerHeight)
    headerMaskView.frame = headerContainer.bounds
    headerMaskBlurView.frame = headerMaskView.bounds
    headerMaskOverlayView.frame = headerMaskBlurView.bounds
    headerMaskGradientLayer.frame = headerMaskView.bounds
    headerContainer.bringSubviewToFront(headerContentView)
    headerContentView.frame = CGRect(
      x: 12.0,
      y: safeTop + 8.0,
      width: max(0.0, bounds.width - 24.0),
      height: 44.0
    )
    backButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    menuButton.frame = CGRect(
      x: max(0.0, headerContentView.bounds.width - 44.0), y: 0.0, width: 44.0, height: 44.0)
    headerAvatarGlassView.frame = CGRect(
      x: (headerContentView.bounds.width - 38.0) * 0.5,
      y: 3.0,
      width: 38.0,
      height: 38.0
    )
    headerAvatarImageView.frame = headerAvatarGlassView.bounds.insetBy(dx: 2.0, dy: 2.0)
    headerAvatarFallbackView.frame = headerAvatarImageView.frame
    headerAvatarFallbackIconView.frame = headerAvatarFallbackView.bounds.insetBy(dx: 7.5, dy: 7.5)
    let textX = headerAvatarGlassView.frame.maxX + 12.0
    let textWidth = menuButton.frame.minX - textX - 8.0
    let textAvailable = textWidth > 40.0
    titleLabel.frame =
      textAvailable ? CGRect(x: textX, y: 3.0, width: textWidth, height: 20.0) : .zero
    subtitleLabel.frame =
      textAvailable ? CGRect(x: textX, y: 23.0, width: textWidth, height: 16.0) : .zero
    titleLabel.textAlignment = .left
    subtitleLabel.textAlignment = .left

    tableView.frame = bounds
    tableView.scrollIndicatorInsets = UIEdgeInsets(
      top: headerHeight, left: 0.0, bottom: 0.0, right: 0.0)

    layoutHeroHeaderViewIfNeeded(force: true)
    updateAvatarMorphProgress()

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
    tableView.reloadData()
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
    clipsToBounds = true

    addSubview(headerContainer)
    headerContainer.clipsToBounds = false
    headerMaskView.isUserInteractionEnabled = false
    headerContainer.addSubview(headerMaskView)
    headerMaskView.addSubview(headerMaskBlurView)
    headerMaskBlurView.contentView.addSubview(headerMaskOverlayView)
    headerMaskGradientLayer.colors = [
      UIColor.black.withAlphaComponent(0.95).cgColor,
      UIColor.black.withAlphaComponent(0.72).cgColor,
      UIColor.clear.cgColor,
    ]
    headerMaskGradientLayer.locations = [0.0, 0.58, 1.0]
    headerMaskView.layer.mask = headerMaskGradientLayer
    headerContainer.addSubview(headerContentView)
    headerContainer.layer.zPosition = 50.0
    headerContentView.addSubview(backButton)
    headerContentView.addSubview(headerAvatarGlassView)
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

    headerAvatarGlassView.clipsToBounds = true
    headerAvatarGlassView.isUserInteractionEnabled = false
    headerAvatarGlassView.layer.cornerCurve = .continuous
    headerAvatarGlassView.layer.cornerRadius = 19.0
    headerAvatarGlassView.alpha = 0.0
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      headerAvatarGlassView.effect = effect
    } else {
      headerAvatarGlassView.effect = UIBlurEffect(style: .systemMaterial)
      headerAvatarGlassView.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    }
    headerAvatarGlassView.contentView.addSubview(headerAvatarImageView)
    headerAvatarGlassView.contentView.addSubview(headerAvatarFallbackView)

    headerAvatarImageView.contentMode = .scaleAspectFill
    headerAvatarImageView.clipsToBounds = true
    headerAvatarImageView.layer.cornerRadius = 17.0
    headerAvatarImageView.isHidden = true

    headerAvatarFallbackView.clipsToBounds = true
    headerAvatarFallbackView.layer.cornerRadius = 17.0
    headerAvatarFallbackView.addSubview(headerAvatarFallbackIconView)
    headerAvatarFallbackIconView.contentMode = .scaleAspectFit
    headerAvatarFallbackIconView.image = UIImage(systemName: "person.fill")

    titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.isHidden = true
    subtitleLabel.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
    subtitleLabel.textAlignment = .center
    subtitleLabel.isHidden = true

    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProfileCell")
    tableView.register(
      ChatProfileTabsCell.self, forCellReuseIdentifier: ChatProfileTabsCell.reuseIdentifier)
    tableView.separatorInset = UIEdgeInsets(top: 0.0, left: 16.0, bottom: 0.0, right: 16.0)
    tableView.contentInsetAdjustmentBehavior = .never
    if #available(iOS 15.0, *) {
      tableView.sectionHeaderTopPadding = 0.0
    }
    addSubview(tableView)

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

    heroBannerImageView.contentMode = .scaleAspectFill
    heroBannerImageView.clipsToBounds = true
    heroBannerImageView.isHidden = true
    heroBannerView.addSubview(heroBannerImageView)

    heroBannerFallbackView.clipsToBounds = true
    heroBannerFallbackView.addSubview(heroBannerFallbackIconView)
    heroBannerFallbackIconView.contentMode = .scaleAspectFit
    heroBannerFallbackIconView.image = UIImage(systemName: "person.fill")
    heroBannerView.addSubview(heroBannerFallbackView)

    heroBannerShadeLayer.colors = [
      UIColor.black.withAlphaComponent(0.06).cgColor,
      UIColor.black.withAlphaComponent(0.12).cgColor,
      UIColor.black.withAlphaComponent(0.34).cgColor,
    ]
    heroBannerShadeLayer.locations = [0.0, 0.62, 1.0]
    heroBannerView.layer.addSublayer(heroBannerShadeLayer)

    avatarView.contentMode = .scaleAspectFill
    avatarView.clipsToBounds = true
    avatarView.isHidden = true
    heroBannerView.addSubview(avatarView)

    avatarFallbackView.clipsToBounds = true
    avatarFallbackView.addSubview(avatarFallbackIconView)
    avatarFallbackIconView.contentMode = .scaleAspectFit
    avatarFallbackIconView.image = UIImage(systemName: "person.fill")
    heroBannerView.addSubview(avatarFallbackView)

    onlineDotView.layer.borderWidth = 3.0
    onlineDotView.layer.cornerCurve = .continuous
    heroBannerView.addSubview(onlineDotView)

    heroNameLabel.font = UIFont.systemFont(ofSize: 30.0, weight: .bold)
    heroNameLabel.textAlignment = .center
    heroBannerView.addSubview(heroNameLabel)

    heroHandleButton.titleLabel?.font = UIFont.systemFont(ofSize: 18.0, weight: .medium)
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

    // Remove duplicate background banner images, we will only use avatarView conditionally
    heroBannerImageView.isHidden = true
    heroBannerFallbackView.isHidden = true

    heroBannerShadeLayer.frame = heroBannerView.bounds

    // Calculate avatar expansion when pulling down to top
    let maxStretch: CGFloat = 80.0
    var expansion = stretch / maxStretch
    expansion = max(0.0, min(1.0, expansion))

    // Smoothly animate between avatar (circle) and banner (rounded rect)
    let baseAvatarSize: CGFloat = 106.0
    let baseAvatarY: CGFloat = 16.0  // slightly increased top padding as requested
    let baseAvatarX = (heroBannerView.bounds.width - baseAvatarSize) * 0.5

    let targetX: CGFloat = 0.0
    let targetY: CGFloat = 0.0
    let targetWidth = heroBannerView.bounds.width
    let targetHeight = heroBannerView.bounds.height
    let targetCorner = heroBannerView.layer.cornerRadius

    let currentX = baseAvatarX + (targetX - baseAvatarX) * expansion
    let currentY = baseAvatarY + (targetY - baseAvatarY) * expansion
    let currentWidth = baseAvatarSize + (targetWidth - baseAvatarSize) * expansion
    let currentHeight = baseAvatarSize + (targetHeight - baseAvatarSize) * expansion
    let currentCorner = (baseAvatarSize * 0.5) + (targetCorner - (baseAvatarSize * 0.5)) * expansion

    avatarView.frame = CGRect(x: currentX, y: currentY, width: currentWidth, height: currentHeight)
    avatarView.layer.cornerRadius = currentCorner
    avatarFallbackView.frame = avatarView.frame
    avatarFallbackView.layer.cornerRadius = currentCorner
    let fallbackInset = currentWidth * 0.28
    avatarFallbackIconView.frame = avatarFallbackView.bounds.insetBy(
      dx: fallbackInset, dy: fallbackInset)

    // Shade should ideally cover the expanded banner but not the avatar.
    // We adjust shade opacity based on expansion.
    heroBannerShadeLayer.opacity = Float(expansion)
    // Make sure shade is above the avatar so text is readable
    heroBannerView.layer.insertSublayer(heroBannerShadeLayer, above: avatarFallbackView.layer)
    if let avatarLayer = avatarView.layer.superlayer != nil ? avatarView.layer : nil {
      heroBannerView.layer.insertSublayer(heroBannerShadeLayer, above: avatarLayer)
    }

    let dotSize: CGFloat = 20.0
    onlineDotView.frame = CGRect(
      x: avatarView.frame.maxX - dotSize - 2.0,
      y: avatarView.frame.maxY - dotSize - 2.0,
      width: dotSize,
      height: dotSize
    )
    onlineDotView.layer.cornerRadius = dotSize * 0.5

    var y = avatarView.frame.maxY + 8.0

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

    backgroundColor = background
    headerContainer.backgroundColor = .clear
    headerMaskBlurView.effect = {
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

    avatarFallbackView.backgroundColor = text.withAlphaComponent(isDark ? 0.14 : 0.08)
    avatarFallbackIconView.tintColor = text.withAlphaComponent(0.90)
    heroBannerFallbackView.backgroundColor = text.withAlphaComponent(isDark ? 0.10 : 0.06)
    heroBannerFallbackIconView.tintColor = text.withAlphaComponent(0.84)
    headerAvatarFallbackView.backgroundColor = text.withAlphaComponent(isDark ? 0.16 : 0.10)
    headerAvatarFallbackIconView.tintColor = text.withAlphaComponent(0.92)

    onlineDotView.backgroundColor = isOnline ? UIColor.systemGreen : text.withAlphaComponent(0.20)
    onlineDotView.layer.borderColor = background.cgColor

    [muteActionButton, searchActionButton, audioActionButton, videoActionButton].forEach {
      $0.applyTheme(foreground: text, background: card)
    }
    configureBackButtonStyle()

    reloadDataKeepingSelection()
  }

  private func reloadHeaderText() {
    titleLabel.text =
      profileName.isEmpty ? (headerTitle.isEmpty ? "Profile" : headerTitle) : profileName

    if isOnline {
      subtitleLabel.text = "Online"
      return
    }

    if !headerSubtitle.isEmpty {
      subtitleLabel.text = headerSubtitle
    } else {
      subtitleLabel.text = isGroupOrChannel ? "Group Profile" : "Profile"
    }
  }

  private func refreshHeroContent() {
    let resolvedName =
      profileName.isEmpty ? (headerTitle.isEmpty ? "User" : headerTitle) : profileName
    heroNameLabel.text = resolvedName

    let identifier = resolvedIdentifierText()
    heroHandleButton.setTitle(identifier, for: .normal)
    heroHandleButton.isHidden = identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    let bio = profileBio.trimmingCharacters(in: .whitespacesAndNewlines)
    heroBioLabel.text = bio

    onlineDotView.backgroundColor =
      isOnline
      ? UIColor.systemGreen
      : (traitCollection.userInterfaceStyle == .dark
        ? UIColor(white: 1.0, alpha: 0.20) : UIColor(white: 0.0, alpha: 0.20))

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
    let progress = max(0.0, min(1.0, offset / 150.0))
    avatarMorphProgress = progress

    let heroSource = avatarView.isHidden ? avatarFallbackView : avatarView
    let heroCenterInHost =
      heroSource.superview?.convert(heroSource.center, to: self)
      ?? heroHeaderView.convert(heroSource.center, to: self)
    let targetCenter =
      headerAvatarGlassView.superview?.convert(headerAvatarGlassView.center, to: self)
      ?? headerAvatarGlassView.center
    let dx = (targetCenter.x - heroCenterInHost.x) * progress
    let dy = (targetCenter.y - heroCenterInHost.y) * progress
    let scale = max(0.32, 1.0 - (0.68 * progress))

    let transform =
      CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    avatarView.transform = transform
    avatarFallbackView.transform = transform
    onlineDotView.alpha = 1.0 - progress
    onlineDotView.transform = CGAffineTransform(
      scaleX: max(0.65, 1.0 - (0.35 * progress)), y: max(0.65, 1.0 - (0.35 * progress)))

    headerAvatarGlassView.alpha = progress
    headerAvatarGlassView.transform = CGAffineTransform(
      scaleX: 0.88 + (0.12 * progress), y: 0.88 + (0.12 * progress))

    let textAlpha = max(0.0, (progress - 0.5) * 2.0)
    titleLabel.isHidden = textAlpha == 0
    subtitleLabel.isHidden =
      textAlpha == 0
      || (subtitleLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    titleLabel.alpha = textAlpha
    subtitleLabel.alpha = textAlpha
  }

  private func refreshAvatar() {
    avatarLoadTask?.cancel()
    avatarLoadTask = nil

    avatarView.image = nil
    heroBannerImageView.image = nil
    headerAvatarImageView.image = nil
    avatarView.isHidden = true
    heroBannerImageView.isHidden = true
    headerAvatarImageView.isHidden = true
    avatarFallbackView.isHidden = false
    heroBannerFallbackView.isHidden = false
    headerAvatarFallbackView.isHidden = false

    guard let avatarUri,
      !avatarUri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let url = URL(string: avatarUri)
    else {
      return
    }

    if url.isFileURL {
      if let image = UIImage(contentsOfFile: url.path) {
        avatarView.image = image
        heroBannerImageView.image = image
        headerAvatarImageView.image = image
        avatarView.isHidden = false
        heroBannerImageView.isHidden = false
        headerAvatarImageView.isHidden = false
        avatarFallbackView.isHidden = true
        heroBannerFallbackView.isHidden = true
        headerAvatarFallbackView.isHidden = true
      }
      return
    }

    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        self.avatarView.image = image
        self.heroBannerImageView.image = image
        self.headerAvatarImageView.image = image
        self.avatarView.isHidden = false
        self.heroBannerImageView.isHidden = false
        self.headerAvatarImageView.isHidden = false
        self.avatarFallbackView.isHidden = true
        self.heroBannerFallbackView.isHidden = true
        self.headerAvatarFallbackView.isHidden = true
      }
    }
    avatarLoadTask = task
    task.resume()
  }

  private func rebuildDerivedContent() {
    mediaRows = rows.filter { ["image", "video", "gif"].contains($0.type) }
    musicRows = rows.filter { $0.type == "music" }
    fileRows = rows.filter { ["file", "voice"].contains($0.type) }
    pinnedRows = rows.filter { $0.isPinned }

    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var links: [ChatProfileLinkItem] = []
    for row in rows {
      let text = row.text
      guard !text.isEmpty, let detector else { continue }
      let nsText = text as NSString
      let matches = detector.matches(
        in: text, options: [], range: NSRange(location: 0, length: nsText.length))
      if let firstURL = matches.first?.url?.absoluteString, !firstURL.isEmpty {
        links.append(ChatProfileLinkItem(row: row, url: firstURL))
      }
    }
    linkRows = links

    var tabs: [ChatProfileTab] = []
    if !mediaRows.isEmpty { tabs.append(.media) }
    if !musicRows.isEmpty { tabs.append(.music) }
    if !fileRows.isEmpty { tabs.append(.files) }
    if !linkRows.isEmpty { tabs.append(.links) }
    if !pinnedRows.isEmpty { tabs.append(.pinned) }

    availableTabs = tabs
    if !availableTabs.contains(activeTab), let first = availableTabs.first {
      activeTab = first
    }
  }

  private func currentInfoRows() -> [ChatProfileInfoRow] {
    var result: [ChatProfileInfoRow] = []
    result.append(isGroupOrChannel ? .members : .identifier)
    result.append(.agent)

    if !profileBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      result.append(.bio)
    }

    return result
  }

  private func tabCountLabel(_ tab: ChatProfileTab) -> String {
    switch tab {
    case .media:
      return "\(tab.label) \(mediaRows.count)"
    case .music:
      return "\(tab.label) \(musicRows.count)"
    case .files:
      return "\(tab.label) \(fileRows.count)"
    case .links:
      return "\(tab.label) \(linkRows.count)"
    case .pinned:
      return "\(tab.label) \(pinnedRows.count)"
    }
  }

  private func currentTabRowsCount() -> Int {
    switch activeTab {
    case .media:
      return mediaRows.count
    case .music:
      return musicRows.count
    case .files:
      return fileRows.count
    case .links:
      return linkRows.count
    case .pinned:
      return pinnedRows.count
    }
  }

  private func rowForCurrentTab(at index: Int) -> ChatProfileRow? {
    switch activeTab {
    case .media:
      guard mediaRows.indices.contains(index) else { return nil }
      return mediaRows[index]
    case .music:
      guard musicRows.indices.contains(index) else { return nil }
      return musicRows[index]
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

  private func agentStatusText() -> String {
    guard isGroupOrChannel else {
      return "Available in group profile"
    }

    guard let config = agentConfig else {
      return "Not configured"
    }

    let enabled = normalizedAgentEnabledValue(config["enabled"], defaultValue: true)
    let name = normalizedAgentString(config["name"]) ?? "Vibe AI"
    let docs = getAgentDocuments().count
    return "\(enabled ? "Enabled" : "Disabled") • \(name) • \(docs) docs"
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
    let raw = resolvedIdentifierRawValue()
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    UIPasteboard.general.string = raw
    onNativeEvent(["type": "profileIdPressed", "id": raw])
  }

  private func reloadDataKeepingSelection() {
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
  }

  // MARK: UITableViewDataSource

  private enum Section: Int, CaseIterable {
    case info
    case tabs
    case content
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === tableView else { return }
    layoutHeroHeaderViewIfNeeded(force: false)
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
      guard !availableTabs.isEmpty else { return 0 }
      let count = currentTabRowsCount()
      return max(1, count)
    }
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    guard let section = Section(rawValue: section) else { return nil }

    switch section {
    case .info:
      return nil
    case .tabs:
      return availableTabs.isEmpty ? nil : "Shared Content"
    case .content:
      return nil
    }
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    guard let section = Section(rawValue: indexPath.section) else {
      return UITableView.automaticDimension
    }

    switch section {
    case .tabs:
      return 46.0
    case .content:
      if currentTabRowsCount() == 0 {
        return 52.0
      }
      return 58.0
    case .info:
      return UITableView.automaticDimension
    }
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let section = Section(rawValue: indexPath.section) else {
      return tableView.dequeueReusableCell(withIdentifier: "ProfileCell", for: indexPath)
    }

    switch section {
    case .tabs:
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: ChatProfileTabsCell.reuseIdentifier,
          for: indexPath
        ) as? ChatProfileTabsCell
      else {
        return tableView.dequeueReusableCell(withIdentifier: "ProfileCell", for: indexPath)
      }

      let titles = availableTabs.map(tabCountLabel(_:))
      let selectedIndex = availableTabs.firstIndex(of: activeTab) ?? 0
      cell.configure(titles: titles, selectedIndex: selectedIndex) { [weak self] index in
        guard let self, self.availableTabs.indices.contains(index) else { return }
        let nextTab = self.availableTabs[index]
        if self.activeTab == nextTab { return }
        self.activeTab = nextTab
        self.tableView.reloadSections(IndexSet(integer: Section.content.rawValue), with: .fade)
      }
      return cell

    case .info:
      let cell = tableView.dequeueReusableCell(withIdentifier: "ProfileCell", for: indexPath)
      var content = cell.defaultContentConfiguration()
      content.secondaryTextProperties.numberOfLines = 2
      content.secondaryTextProperties.lineBreakMode = .byTruncatingTail

      let infoRows = currentInfoRows()
      guard infoRows.indices.contains(indexPath.row) else {
        cell.contentConfiguration = content
        return cell
      }

      switch infoRows[indexPath.row] {
      case .members:
        let count = groupMemberCount ?? groupMembers.count
        content.text = "Members"
        content.secondaryText = "\(count) members"
        content.image = UIImage(systemName: "person.3.fill")
        cell.accessoryType = .disclosureIndicator
      case .identifier:
        content.text = "ID"
        content.secondaryText =
          resolvedIdentifierRawValue().isEmpty ? "Unavailable" : resolvedIdentifierRawValue()
        content.image = nil
        cell.accessoryType = .none
      case .agent:
        content.text = "Agent"
        content.secondaryText = agentStatusText()
        content.image = nil
        cell.accessoryType = .disclosureIndicator
      case .bio:
        content.text = "Bio"
        content.secondaryText = profileBio
        content.image = UIImage(systemName: "quote.bubble")
        cell.accessoryType = .none
      }

      cell.contentConfiguration = content
      return cell

    case .content:
      let cell = tableView.dequeueReusableCell(withIdentifier: "ProfileCell", for: indexPath)
      var content = cell.defaultContentConfiguration()
      content.secondaryTextProperties.numberOfLines = 1
      content.secondaryTextProperties.lineBreakMode = .byTruncatingTail

      let count = currentTabRowsCount()
      guard count > 0 else {
        content.text = "No \(activeTab.label.lowercased()) yet"
        content.secondaryText = nil
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryType = .none
        return cell
      }

      guard let row = rowForCurrentTab(at: indexPath.row) else {
        cell.contentConfiguration = content
        return cell
      }

      switch activeTab {
      case .media:
        let typeLabel: String = {
          switch row.type {
          case "video": return "Video"
          case "gif": return "GIF"
          default: return "Photo"
          }
        }()
        content.text = typeLabel
        content.secondaryText = formattedRowDate(row) ?? "Media"
        content.image = UIImage(systemName: row.type == "video" ? "video" : "photo")
        cell.accessoryType = .disclosureIndicator
      case .music:
        content.text = row.fileName ?? "Audio"
        content.secondaryText = [formattedFileSize(row.fileSize), formattedRowDate(row)].compactMap
        { $0 }.joined(separator: " · ")
        content.image = UIImage(systemName: "music.note")
        cell.accessoryType = .disclosureIndicator
      case .files:
        content.text = row.fileName ?? "File"
        content.secondaryText = [formattedFileSize(row.fileSize), formattedRowDate(row)].compactMap
        { $0 }.joined(separator: " · ")
        content.image = UIImage(systemName: "doc")
        cell.accessoryType = .disclosureIndicator
      case .links:
        let url = linkRows[indexPath.row].url
        content.text = url
        content.secondaryText = formattedRowDate(row)
        content.image = UIImage(systemName: "link")
        cell.accessoryType = .disclosureIndicator
      case .pinned:
        content.text =
          row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "Pinned message" : row.text
        content.secondaryText = formattedRowDate(row)
        content.image = UIImage(systemName: "pin")
        cell.accessoryType = .none
      }

      cell.contentConfiguration = content
      cell.selectionStyle = .default
      return cell
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
        presentAgentConfigEditor()
      case .bio:
        break
      }

    case .tabs:
      break

    case .content:
      guard currentTabRowsCount() > 0 else { return }
      guard let row = rowForCurrentTab(at: indexPath.row) else { return }

      var payload: [String: Any] = [
        "type": "profileContentPressed",
        "tab": activeTab.rawValue,
        "messageId": row.messageId,
      ]

      if activeTab == .links {
        let url = linkRows[indexPath.row].url
        payload["url"] = url
      } else if let mediaUrl = row.mediaUrl, !mediaUrl.isEmpty {
        payload["url"] = mediaUrl
      }

      onNativeEvent(payload)
    }
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
