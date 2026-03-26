import UIKit

protocol ChatNativeHomeCardCellSwipeDelegate: AnyObject {
  func homeCardCellDidBeginSwipe(_ cell: ChatNativeHomeCardCell)
  func homeCardCellDidCloseSwipe(_ cell: ChatNativeHomeCardCell)
  func homeCardCell(
    _ cell: ChatNativeHomeCardCell,
    didTriggerSwipeEvent eventType: String,
    chatId: String
  )
}

final class ChatNativeHomeCardCell: UITableViewCell {
  static let reuseIdentifier = "ChatNativeHomeCardCell"
  static let avatarImageCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 256
    return cache
  }()

  static func avatarCached(forKey key: String) -> UIImage? {
    avatarImageCache.object(forKey: key as NSString)
  }

  static func cacheAvatar(_ image: UIImage, forKey key: String) {
    avatarImageCache.setObject(image, forKey: key as NSString)
  }
  private static let avatarSession: URLSession = {
    if #available(iOS 13.0, *) {
      return ChatPhoenixClient.makePinnedURLSession()
    }
    return URLSession.shared
  }()

  private let pressOverlayView = UIView()
  private let selectionOverlayView = UIView()
  private let dividerView = UIView()
  private let leadingActionsContainer = UIView()
  private let trailingActionsContainer = UIView()
  private let leadingActionsMaskLayer = CALayer()
  private let trailingActionsMaskLayer = CALayer()
  private let leadingFullSwipeView = ChatNativeHomeSwipeActionTileView(frame: .zero)
  private let trailingFullSwipeView = ChatNativeHomeSwipeActionTileView(frame: .zero)
  private let rowContentContainer = UIView()
  private let editSelectionContainer = UIView()
  private let avatarContainer = UIView()
  private let avatarImageView = UIImageView()
  private let avatarFallbackIconView = UIImageView()
  private let editSelectionBackgroundView = UIView()
  private let editSelectionCheckView = UIImageView()
  private let onlineDot = UIView()

  private let titleLabel = UILabel()
  private let previewLabel = UILabel()
  private let timeLabel = UILabel()
  private let unreadBadge = UIView()
  private let unreadLabel = UILabel()
  private let muteIconView = UIImageView()
  private let pinIconView = UIImageView()

  private var avatarLoadTask: URLSessionDataTask?
  private var avatarToken = UUID().uuidString
  private var lastAvatarURLString: String?
  private var rowContentLeadingConstraint: NSLayoutConstraint?
  private var currentEditingLayout = false
  private lazy var swipePanGestureRecognizer: UIPanGestureRecognizer = {
    let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
    gesture.delegate = self
    gesture.cancelsTouchesInView = true
    return gesture
  }()
  private var currentRow: ChatNativeHomeListRow?
  private var isSwipeEnabled = true
  private var swipeOffset: CGFloat = 0
  private var swipeStartOffset: CGFloat = 0
  private var hasCommittedSwipeGesture = false
  private var isPerformingSwipeAction = false
  private var didEmitLargeSwipeHaptic = false
  private var leadingDisplaySpecs: [ChatNativeHomeSwipeActionSpec] = []
  private var trailingDisplaySpecs: [ChatNativeHomeSwipeActionSpec] = []
  private var leadingActionButtons: [ChatNativeHomeSwipeActionButton] = []
  private var trailingActionButtons: [ChatNativeHomeSwipeActionButton] = []
  private var leadingFullSwipeSpec: ChatNativeHomeSwipeActionSpec?
  private var trailingFullSwipeSpec: ChatNativeHomeSwipeActionSpec?
  private let largeSwipeHapticGenerator = UIImpactFeedbackGenerator(style: .medium)
  private let avatarGradientLayerName = "avatarGradient"

  weak var swipeDelegate: ChatNativeHomeCardCellSwipeDelegate?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    configureView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureView()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    avatarLoadTask?.cancel()
    avatarLoadTask = nil
    avatarToken = UUID().uuidString
    lastAvatarURLString = nil
    avatarImageView.image = nil
    avatarFallbackIconView.isHidden = false
    avatarContainer.layer.sublayers?.removeAll(where: { $0.name == self.avatarGradientLayerName })
    unreadBadge.isHidden = true
    muteIconView.isHidden = true
    pinIconView.isHidden = true
    selectionOverlayView.alpha = 0
    pressOverlayView.alpha = 0
    editSelectionContainer.alpha = 0
    editSelectionBackgroundView.isHidden = true
    editSelectionCheckView.isHidden = true
    rowContentLeadingConstraint?.constant = 0
    currentRow = nil
    leadingDisplaySpecs = []
    trailingDisplaySpecs = []
    leadingFullSwipeSpec = nil
    trailingFullSwipeSpec = nil
    hasCommittedSwipeGesture = false
    isPerformingSwipeAction = false
    didEmitLargeSwipeHaptic = false
    closeSwipe(animated: false, notifyDelegate: false)
    currentEditingLayout = false
    transform = .identity
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    setPressedState(highlighted, animated: animated)
  }

  override func setSelected(_ selected: Bool, animated: Bool) {
    super.setSelected(selected, animated: animated)
    setPressedState(selected, animated: animated)
  }

  func configure(
    row: ChatNativeHomeListRow,
    isDark: Bool,
    avatarBackgroundColor: UIColor?,
    avatarGradientColors: (UIColor, UIColor)?,
    isEditing: Bool,
    isEditSelected: Bool
  ) {
    let primary =
      isDark ? UIColor.white : UIColor(red: 22 / 255, green: 28 / 255, blue: 36 / 255, alpha: 1)
    let secondary =
      isDark
      ? UIColor(white: 0.76, alpha: 1)
      : UIColor(red: 114 / 255, green: 123 / 255, blue: 138 / 255, alpha: 1)
    let typingColor =
      isDark
      ? UIColor(red: 138 / 255, green: 202 / 255, blue: 255 / 255, alpha: 1)
      : UIColor(red: 43 / 255, green: 135 / 255, blue: 210 / 255, alpha: 1)
    let badgeBackground =
      isDark
      ? UIColor(red: 157 / 255, green: 216 / 255, blue: 255 / 255, alpha: 1)
      : UIColor(red: 23 / 255, green: 132 / 255, blue: 209 / 255, alpha: 1)
    let pressedColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.08)
      : UIColor.black.withAlphaComponent(0.05)
    let selectedOverlayColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.06)
      : UIColor.black.withAlphaComponent(0.035)
    let dividerColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.06)
      : UIColor.black.withAlphaComponent(0.03)
    let selectionRingColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.22)
      : UIColor.black.withAlphaComponent(0.12)
    let selectionIdleBackgroundColor =
      isDark
      ? UIColor.black.withAlphaComponent(0.14)
      : UIColor.white.withAlphaComponent(0.84)

    titleLabel.text = row.title
    titleLabel.textColor = primary
    previewLabel.text = row.isTyping ? "typing..." : row.preview
    previewLabel.textColor = row.isTyping ? typingColor : secondary
    timeLabel.text = row.timeLabel
    timeLabel.textColor = secondary

    unreadBadge.isHidden = !(row.unreadCount > 0 || row.markedUnread)
    unreadLabel.text = row.unreadCount > 0 ? "\(row.unreadCount)" : ""
    unreadLabel.textColor = isDark ? UIColor.black : UIColor.white
    unreadBadge.backgroundColor = badgeBackground

    muteIconView.isHidden = !row.muted
    pinIconView.isHidden = !row.pinned
    muteIconView.tintColor = secondary
    pinIconView.tintColor = secondary
    onlineDot.isHidden = !row.isOnline
    selectionOverlayView.backgroundColor = selectedOverlayColor
    selectionOverlayView.alpha = isEditSelected ? 1 : 0
    editSelectionContainer.alpha = isEditing ? 1 : 0
    editSelectionBackgroundView.isHidden = !isEditing
    editSelectionBackgroundView.backgroundColor = isEditSelected ? badgeBackground : selectionIdleBackgroundColor
    editSelectionBackgroundView.layer.borderColor = (isEditSelected ? badgeBackground : selectionRingColor).cgColor
    editSelectionCheckView.isHidden = !(isEditing && isEditSelected)
    editSelectionCheckView.tintColor = isDark ? UIColor.black : UIColor.white

    avatarFallbackIconView.image = UIImage(systemName: row.isSavedMessages ? "bookmark.fill" : "person.fill")
    avatarFallbackIconView.tintColor = .white

    let resolvedAvatarGradientColors =
      avatarGradientColors
      ?? (row.isSavedMessages ? Self.savedMessagesGradientColors(isDark: isDark) : nil)
    if let resolvedAvatarGradientColors {
      applyAvatarGradient(
        startColor: resolvedAvatarGradientColors.0,
        endColor: resolvedAvatarGradientColors.1
      )
    } else {
      avatarContainer.layer.sublayers?.removeAll(where: { $0.name == avatarGradientLayerName })
      let avatarBackground =
        avatarBackgroundColor
        ?? (isDark
          ? UIColor(red: 63 / 255, green: 70 / 255, blue: 85 / 255, alpha: 1)
          : UIColor(red: 222 / 255, green: 230 / 255, blue: 243 / 255, alpha: 1))
      avatarContainer.backgroundColor = avatarBackground
    }
    pressOverlayView.backgroundColor = pressedColor
    dividerView.backgroundColor = dividerColor
    updateEditingLayout(isEditing, animated: true)
    configureSwipeActions(for: row, isEditing: isEditing)

    loadAvatarImage(urlString: row.avatarUri)
  }

  private func updateEditingLayout(_ isEditing: Bool, animated: Bool) {
    let targetLeading: CGFloat = isEditing ? 44 : 0
    let updates = {
      self.rowContentLeadingConstraint?.constant = targetLeading
      self.layoutIfNeeded()
    }

    let shouldAnimate = animated && currentEditingLayout != isEditing
    currentEditingLayout = isEditing

    if shouldAnimate {
      UIView.animate(
        withDuration: 0.24,
        delay: 0,
        options: [.curveEaseInOut, .beginFromCurrentState]
      ) {
        updates()
      }
    } else {
      updates()
    }
  }

  private func setPressedState(_ pressed: Bool, animated: Bool) {
    let targetAlpha: CGFloat = pressed ? 1 : 0
    if animated {
      UIView.animate(withDuration: 0.14) {
        self.pressOverlayView.alpha = targetAlpha
      }
    } else {
      pressOverlayView.alpha = targetAlpha
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    avatarContainer.layer.sublayers?.first(where: { $0.name == avatarGradientLayerName })?.frame =
      avatarContainer.bounds
    layoutSwipeActionViews()
  }

  private func applyAvatarGradient(startColor: UIColor, endColor: UIColor) {
    var gradient =
      avatarContainer.layer.sublayers?.first(where: { $0.name == avatarGradientLayerName })
      as? CAGradientLayer
    if gradient == nil {
      gradient = CAGradientLayer()
      gradient?.name = avatarGradientLayerName
      avatarContainer.layer.insertSublayer(gradient!, at: 0)
    }
    gradient?.colors = [startColor.cgColor, endColor.cgColor]
    gradient?.startPoint = CGPoint(x: 0.5, y: 0)
    gradient?.endPoint = CGPoint(x: 0.5, y: 1)
    gradient?.frame = avatarContainer.bounds
    avatarContainer.backgroundColor = .clear
  }

  private static func savedMessagesGradientColors(isDark: Bool) -> (UIColor, UIColor) {
    let startColor =
      isDark
      ? UIColor(red: 77 / 255, green: 217 / 255, blue: 229 / 255, alpha: 1)
      : UIColor(red: 43 / 255, green: 165 / 255, blue: 181 / 255, alpha: 1)
    let endColor =
      isDark
      ? UIColor(red: 43 / 255, green: 165 / 255, blue: 181 / 255, alpha: 1)
      : UIColor(red: 0 / 255, green: 122 / 255, blue: 124 / 255, alpha: 1)
    return (startColor, endColor)
  }

  private func configureView() {
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.clipsToBounds = true

    leadingActionsContainer.translatesAutoresizingMaskIntoConstraints = false
    leadingActionsContainer.backgroundColor = .clear
    leadingActionsContainer.clipsToBounds = true
    leadingActionsMaskLayer.backgroundColor = UIColor.black.cgColor
    leadingActionsContainer.layer.mask = leadingActionsMaskLayer

    trailingActionsContainer.translatesAutoresizingMaskIntoConstraints = false
    trailingActionsContainer.backgroundColor = .clear
    trailingActionsContainer.clipsToBounds = true
    trailingActionsMaskLayer.backgroundColor = UIColor.black.cgColor
    trailingActionsContainer.layer.mask = trailingActionsMaskLayer

    leadingFullSwipeView.isHidden = true
    trailingFullSwipeView.isHidden = true

    selectionOverlayView.translatesAutoresizingMaskIntoConstraints = false
    selectionOverlayView.alpha = 0
    selectionOverlayView.isUserInteractionEnabled = false

    pressOverlayView.translatesAutoresizingMaskIntoConstraints = false
    pressOverlayView.alpha = 0
    pressOverlayView.isUserInteractionEnabled = false

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    dividerView.isUserInteractionEnabled = false

    rowContentContainer.translatesAutoresizingMaskIntoConstraints = false
    rowContentContainer.backgroundColor = .clear
    rowContentContainer.clipsToBounds = false

    editSelectionContainer.translatesAutoresizingMaskIntoConstraints = false
    editSelectionContainer.alpha = 0
    editSelectionContainer.isUserInteractionEnabled = false

    avatarContainer.translatesAutoresizingMaskIntoConstraints = false
    avatarContainer.layer.cornerRadius = 30
    avatarContainer.clipsToBounds = true

    avatarImageView.translatesAutoresizingMaskIntoConstraints = false
    avatarImageView.contentMode = .scaleAspectFill
    avatarImageView.clipsToBounds = true

    avatarFallbackIconView.translatesAutoresizingMaskIntoConstraints = false
    avatarFallbackIconView.contentMode = .scaleAspectFit
    avatarFallbackIconView.image = UIImage(systemName: "person.fill")
    avatarFallbackIconView.tintColor = UIColor.white

    editSelectionBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    editSelectionBackgroundView.backgroundColor = .clear
    editSelectionBackgroundView.layer.cornerRadius = 11
    editSelectionBackgroundView.layer.borderWidth = 1.25
    editSelectionBackgroundView.isHidden = true

    editSelectionCheckView.translatesAutoresizingMaskIntoConstraints = false
    editSelectionCheckView.image = UIImage(systemName: "checkmark")
    editSelectionCheckView.contentMode = .scaleAspectFit
    editSelectionCheckView.isHidden = true

    onlineDot.translatesAutoresizingMaskIntoConstraints = false
    onlineDot.backgroundColor = UIColor(red: 61 / 255, green: 208 / 255, blue: 102 / 255, alpha: 1)
    onlineDot.layer.cornerRadius = 6
    onlineDot.layer.borderWidth = 2
    onlineDot.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
    onlineDot.isHidden = true

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 17, weight: .medium)
    titleLabel.numberOfLines = 1

    previewLabel.translatesAutoresizingMaskIntoConstraints = false
    previewLabel.font = .systemFont(ofSize: 15, weight: .regular)
    previewLabel.numberOfLines = 1

    timeLabel.translatesAutoresizingMaskIntoConstraints = false
    timeLabel.font = .systemFont(ofSize: 13, weight: .medium)
    timeLabel.textAlignment = .right

    unreadBadge.translatesAutoresizingMaskIntoConstraints = false
    unreadBadge.layer.cornerRadius = 10
    unreadBadge.isHidden = true

    unreadLabel.translatesAutoresizingMaskIntoConstraints = false
    unreadLabel.font = .systemFont(ofSize: 11, weight: .bold)
    unreadLabel.textAlignment = .center

    muteIconView.translatesAutoresizingMaskIntoConstraints = false
    muteIconView.image = UIImage(systemName: "speaker.slash.fill")
    muteIconView.isHidden = true
    muteIconView.contentMode = .scaleAspectFit

    pinIconView.translatesAutoresizingMaskIntoConstraints = false
    pinIconView.image = UIImage(systemName: "pin.fill")
    pinIconView.isHidden = true
    pinIconView.contentMode = .scaleAspectFit
    pinIconView.transform = CGAffineTransform(rotationAngle: CGFloat.pi / 4)

    let textStack = UIStackView(arrangedSubviews: [titleLabel, previewLabel])
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.axis = .vertical
    textStack.spacing = 2
    textStack.alignment = .fill

    let iconStack = UIStackView(arrangedSubviews: [muteIconView, pinIconView])
    iconStack.translatesAutoresizingMaskIntoConstraints = false
    iconStack.axis = .horizontal
    iconStack.spacing = 7
    iconStack.alignment = .center

    let metaStack = UIStackView(arrangedSubviews: [timeLabel, unreadBadge, iconStack])
    metaStack.translatesAutoresizingMaskIntoConstraints = false
    metaStack.axis = .vertical
    metaStack.spacing = 5
    metaStack.alignment = .trailing
    metaStack.distribution = .equalSpacing

    contentView.addSubview(leadingActionsContainer)
    contentView.addSubview(trailingActionsContainer)
    contentView.addSubview(selectionOverlayView)
    contentView.addSubview(pressOverlayView)
    contentView.addSubview(dividerView)
    contentView.addSubview(editSelectionContainer)
    contentView.addSubview(rowContentContainer)
    leadingActionsContainer.addSubview(leadingFullSwipeView)
    trailingActionsContainer.addSubview(trailingFullSwipeView)
    rowContentContainer.addSubview(avatarContainer)
    avatarContainer.addSubview(avatarImageView)
    avatarContainer.addSubview(avatarFallbackIconView)
    editSelectionContainer.addSubview(editSelectionBackgroundView)
    editSelectionBackgroundView.addSubview(editSelectionCheckView)
    rowContentContainer.addSubview(onlineDot)
    rowContentContainer.addSubview(textStack)
    rowContentContainer.addSubview(metaStack)
    unreadBadge.addSubview(unreadLabel)

    let rowContentLeadingConstraint = rowContentContainer.leadingAnchor.constraint(
      equalTo: contentView.leadingAnchor)
    self.rowContentLeadingConstraint = rowContentLeadingConstraint

    NSLayoutConstraint.activate([
      leadingActionsContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      leadingActionsContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      leadingActionsContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      leadingActionsContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      trailingActionsContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      trailingActionsContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      trailingActionsContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      trailingActionsContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      selectionOverlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      selectionOverlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      selectionOverlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
      selectionOverlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      pressOverlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      pressOverlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      pressOverlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
      pressOverlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      dividerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

      editSelectionContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      editSelectionContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      editSelectionContainer.widthAnchor.constraint(equalToConstant: 44),
      editSelectionContainer.heightAnchor.constraint(equalToConstant: 44),

      rowContentLeadingConstraint,
      rowContentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      rowContentContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      rowContentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      avatarContainer.leadingAnchor.constraint(equalTo: rowContentContainer.leadingAnchor, constant: 16),
      avatarContainer.centerYAnchor.constraint(equalTo: rowContentContainer.centerYAnchor),
      avatarContainer.widthAnchor.constraint(equalToConstant: 60),
      avatarContainer.heightAnchor.constraint(equalToConstant: 60),

      avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
      avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
      avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
      avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),

      avatarFallbackIconView.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
      avatarFallbackIconView.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
      avatarFallbackIconView.widthAnchor.constraint(equalToConstant: 24),
      avatarFallbackIconView.heightAnchor.constraint(equalToConstant: 24),

      editSelectionBackgroundView.centerXAnchor.constraint(equalTo: editSelectionContainer.centerXAnchor),
      editSelectionBackgroundView.centerYAnchor.constraint(equalTo: editSelectionContainer.centerYAnchor),
      editSelectionBackgroundView.widthAnchor.constraint(equalToConstant: 22),
      editSelectionBackgroundView.heightAnchor.constraint(equalToConstant: 22),
      editSelectionCheckView.centerXAnchor.constraint(equalTo: editSelectionBackgroundView.centerXAnchor),
      editSelectionCheckView.centerYAnchor.constraint(equalTo: editSelectionBackgroundView.centerYAnchor),
      editSelectionCheckView.widthAnchor.constraint(equalToConstant: 11),
      editSelectionCheckView.heightAnchor.constraint(equalToConstant: 11),

      onlineDot.widthAnchor.constraint(equalToConstant: 12),
      onlineDot.heightAnchor.constraint(equalToConstant: 12),
      onlineDot.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: -1),
      onlineDot.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor, constant: -1),

      textStack.leadingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: 14),
      textStack.centerYAnchor.constraint(equalTo: rowContentContainer.centerYAnchor),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: metaStack.leadingAnchor, constant: -8),

      metaStack.trailingAnchor.constraint(equalTo: rowContentContainer.trailingAnchor, constant: -16),
      metaStack.centerYAnchor.constraint(equalTo: rowContentContainer.centerYAnchor),
      metaStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),

      unreadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
      unreadBadge.heightAnchor.constraint(equalToConstant: 20),
      unreadLabel.leadingAnchor.constraint(equalTo: unreadBadge.leadingAnchor, constant: 6),
      unreadLabel.trailingAnchor.constraint(equalTo: unreadBadge.trailingAnchor, constant: -6),
      unreadLabel.centerYAnchor.constraint(equalTo: unreadBadge.centerYAnchor),

      muteIconView.widthAnchor.constraint(equalToConstant: 14),
      muteIconView.heightAnchor.constraint(equalToConstant: 14),
      pinIconView.widthAnchor.constraint(equalToConstant: 14),
      pinIconView.heightAnchor.constraint(equalToConstant: 14),
      { let c = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 84); c.priority = .defaultHigh; return c }(),
    ])

    rowContentContainer.addGestureRecognizer(swipePanGestureRecognizer)
  }

  func closeSwipe(animated: Bool) {
    closeSwipe(animated: animated, notifyDelegate: true)
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === swipePanGestureRecognizer, isSwipeEnabled else { return false }
    let velocity = swipePanGestureRecognizer.velocity(in: contentView)
    return abs(velocity.x) > abs(velocity.y)
  }

  @objc private func handleSwipePan(_ gestureRecognizer: UIPanGestureRecognizer) {
    guard isSwipeEnabled, !isPerformingSwipeAction else { return }

    let translationX = gestureRecognizer.translation(in: contentView).x
    let velocityX = gestureRecognizer.velocity(in: contentView).x

    switch gestureRecognizer.state {
    case .began:
      swipeStartOffset = swipeOffset
      hasCommittedSwipeGesture = abs(swipeOffset) > 0.5
      didEmitLargeSwipeHaptic = false
      largeSwipeHapticGenerator.prepare()
    case .changed:
      let rawOffset = swipeStartOffset + translationX
      let nextOffset: CGFloat
      if hasCommittedSwipeGesture || abs(swipeStartOffset) > 0.5 {
        nextOffset = clampedSwipeOffset(for: rawOffset)
      } else if abs(rawOffset) <= swipeActivationThreshold {
        nextOffset = 0
      } else {
        hasCommittedSwipeGesture = true
        swipeDelegate?.homeCardCellDidBeginSwipe(self)
        let direction: CGFloat = rawOffset >= 0 ? 1 : -1
        nextOffset = clampedSwipeOffset(for: rawOffset - (direction * swipeActivationThreshold))
      }
      setSwipeOffset(nextOffset, animated: false)
      maybeTriggerImmediateLargeSwipeAction(for: nextOffset)
    case .ended, .cancelled, .failed:
      if isPerformingSwipeAction {
        return
      }
      finalizeSwipe(velocityX: velocityX)
    default:
      break
    }
  }

  private func configureSwipeActions(for row: ChatNativeHomeListRow, isEditing: Bool) {
    currentRow = row
    isSwipeEnabled = !isEditing
    swipePanGestureRecognizer.isEnabled = !isEditing

    leadingDisplaySpecs = orderedSwipeSpecs(row.leadingSwipeActionSpecs, edge: .leading)
    trailingDisplaySpecs = orderedSwipeSpecs(row.trailingSwipeActionSpecs, edge: .trailing)
    leadingFullSwipeSpec =
      row.leadingSwipeActionSpecs.first(where: \.isFullSwipeTarget) ?? leadingDisplaySpecs.last
    trailingFullSwipeSpec =
      row.trailingSwipeActionSpecs.first(where: \.isFullSwipeTarget)
      ?? trailingDisplaySpecs.first(where: { $0.eventType == "swipeDelete" })

    syncSwipeButtons(
      in: leadingActionsContainer,
      buttons: &leadingActionButtons,
      specs: leadingDisplaySpecs,
      edge: .leading
    )
    syncSwipeButtons(
      in: trailingActionsContainer,
      buttons: &trailingActionButtons,
      specs: trailingDisplaySpecs,
      edge: .trailing
    )

    if isEditing {
      closeSwipe(animated: false, notifyDelegate: false)
    } else {
      hasCommittedSwipeGesture = false
      setSwipeOffset(0, animated: false)
    }
  }

  private func syncSwipeButtons(
    in container: UIView,
    buttons: inout [ChatNativeHomeSwipeActionButton],
    specs: [ChatNativeHomeSwipeActionSpec],
    edge: ChatNativeHomeSwipeEdge
  ) {
    if buttons.count > specs.count {
      for button in buttons[specs.count...] {
        button.removeFromSuperview()
      }
      buttons.removeSubrange(specs.count...)
    }

    while buttons.count < specs.count {
      let button = ChatNativeHomeSwipeActionButton(frame: .zero)
      button.addTarget(self, action: #selector(handleSwipeActionButtonTap(_:)), for: .touchUpInside)
      container.addSubview(button)
      buttons.append(button)
    }

    for (index, spec) in specs.enumerated() {
      buttons[index].configure(spec: spec, edge: edge)
    }
  }

  @objc private func handleSwipeActionButtonTap(_ sender: ChatNativeHomeSwipeActionButton) {
    guard let row = currentRow, let spec = sender.spec else { return }
    closeSwipe(animated: true, notifyDelegate: false)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.swipeDelegate?.homeCardCell(self, didTriggerSwipeEvent: spec.eventType, chatId: row.chatId)
    }
  }

  private func orderedSwipeSpecs(
    _ specs: [ChatNativeHomeSwipeActionSpec],
    edge: ChatNativeHomeSwipeEdge
  ) -> [ChatNativeHomeSwipeActionSpec] {
    let priorities: [String: Int]
    switch edge {
    case .leading:
      priorities = [
        "swipeMarkRead": 0,
        "swipePin": 1,
      ]
    case .trailing:
      priorities = [
        "swipeMute": 0,
        "swipeDelete": 1,
        "swipeArchive": 2,
      ]
    }

    return specs.sorted { lhs, rhs in
      let lhsPriority = priorities[lhs.eventType] ?? 99
      let rhsPriority = priorities[rhs.eventType] ?? 99
      if lhsPriority == rhsPriority {
        return lhs.title < rhs.title
      }
      return lhsPriority < rhsPriority
    }
  }

  private func clampedSwipeOffset(for proposedOffset: CGFloat) -> CGFloat {
    if proposedOffset > 0 {
      guard !leadingDisplaySpecs.isEmpty else { return 0 }
      return min(proposedOffset, max(leadingOpenWidth, bounds.width - 20))
    }
    if proposedOffset < 0 {
      guard !trailingDisplaySpecs.isEmpty else { return 0 }
      return max(proposedOffset, -max(trailingOpenWidth, bounds.width - 20))
    }
    return 0
  }

  private func maybeTriggerImmediateLargeSwipeAction(for offset: CGFloat) {
    guard abs(offset) > 0.5, !isPerformingSwipeAction else { return }

    if offset < 0,
      let spec = trailingFullSwipeSpec,
      (-offset) >= trailingFullSwipeTriggerDistance
    {
      performImmediateLargeSwipeAction(spec: spec, edge: .trailing)
      return
    }

    if offset > 0,
      let spec = leadingFullSwipeSpec,
      offset >= leadingFullSwipeTriggerDistance
    {
      performImmediateLargeSwipeAction(spec: spec, edge: .leading)
    }
  }

  private func finalizeSwipe(velocityX: CGFloat) {
    if swipeOffset < 0 {
      let revealWidth = -swipeOffset
      if let fullSwipeSpec = trailingFullSwipeSpec,
        revealWidth >= trailingFullSwipeTriggerDistance
          || (velocityX < -1400 && revealWidth > trailingOpenWidth * 0.88)
      {
        triggerFullSwipe(spec: fullSwipeSpec, edge: .trailing)
        return
      }
      let shouldStayOpen = revealWidth > trailingOpenWidth * 0.46 || velocityX < -520
      setSwipeOffset(shouldStayOpen ? -trailingOpenWidth : 0, animated: true)
      if !shouldStayOpen {
        swipeDelegate?.homeCardCellDidCloseSwipe(self)
      }
      return
    }

    if swipeOffset > 0 {
      let revealWidth = swipeOffset
      if let fullSwipeSpec = leadingFullSwipeSpec,
        revealWidth >= leadingFullSwipeTriggerDistance
          || (velocityX > 1400 && revealWidth > leadingOpenWidth * 0.88)
      {
        triggerFullSwipe(spec: fullSwipeSpec, edge: .leading)
        return
      }
      let shouldStayOpen = revealWidth > leadingOpenWidth * 0.46 || velocityX > 520
      setSwipeOffset(shouldStayOpen ? leadingOpenWidth : 0, animated: true)
      if !shouldStayOpen {
        swipeDelegate?.homeCardCellDidCloseSwipe(self)
      }
      return
    }

    swipeDelegate?.homeCardCellDidCloseSwipe(self)
  }

  private func performImmediateLargeSwipeAction(
    spec: ChatNativeHomeSwipeActionSpec,
    edge: ChatNativeHomeSwipeEdge
  ) {
    guard let row = currentRow, !isPerformingSwipeAction else { return }
    isPerformingSwipeAction = true
    hasCommittedSwipeGesture = false

    if !didEmitLargeSwipeHaptic {
      didEmitLargeSwipeHaptic = true
      largeSwipeHapticGenerator.impactOccurred(intensity: 0.92)
    }

    let accentOffset = edge == .leading
      ? min(bounds.width * 0.28, leadingOpenWidth + 26)
      : -min(bounds.width * 0.28, trailingOpenWidth + 26)
    setSwipeOffset(accentOffset, animated: true, duration: 0.12)

    swipePanGestureRecognizer.isEnabled = false
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.swipeDelegate?.homeCardCell(self, didTriggerSwipeEvent: spec.eventType, chatId: row.chatId)
      self.closeSwipe(animated: true, notifyDelegate: false)
      self.swipePanGestureRecognizer.isEnabled = self.isSwipeEnabled
      self.isPerformingSwipeAction = false
      self.didEmitLargeSwipeHaptic = false
    }
  }

  private func triggerFullSwipe(
    spec: ChatNativeHomeSwipeActionSpec,
    edge: ChatNativeHomeSwipeEdge
  ) {
    performImmediateLargeSwipeAction(spec: spec, edge: edge)
  }

  private func setSwipeOffset(
    _ offset: CGFloat,
    animated: Bool,
    duration: TimeInterval = 0.22
  ) {
    let updates = {
      self.swipeOffset = offset
      let transform = CGAffineTransform(translationX: offset, y: 0)
      self.selectionOverlayView.transform = transform
      self.pressOverlayView.transform = transform
      self.dividerView.transform = transform
      self.rowContentContainer.transform = transform
      self.editSelectionContainer.transform = transform
      self.layoutSwipeActionViews()
    }

    if animated {
      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveEaseOut, .beginFromCurrentState]
      ) {
        updates()
      }
    } else {
      updates()
    }
  }

  private func closeSwipe(animated: Bool, notifyDelegate: Bool) {
    let didClose = abs(swipeOffset) > 0.5
    hasCommittedSwipeGesture = false
    didEmitLargeSwipeHaptic = false
    setSwipeOffset(0, animated: animated)
    if notifyDelegate && didClose {
      swipeDelegate?.homeCardCellDidCloseSwipe(self)
    }
  }

  private func layoutSwipeActionViews() {
    let bounds = contentView.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }

    let leadingRevealWidth = max(0, swipeOffset)
    let trailingRevealWidth = max(0, -swipeOffset)
    let leadingExpansionProgress = expansionProgress(revealWidth: leadingRevealWidth, openWidth: leadingOpenWidth)
    let trailingExpansionProgress = expansionProgress(revealWidth: trailingRevealWidth, openWidth: trailingOpenWidth)

    leadingActionsContainer.alpha = 1
    trailingActionsContainer.alpha = 1
    leadingActionsContainer.isHidden = leadingDisplaySpecs.isEmpty
    trailingActionsContainer.isHidden = trailingDisplaySpecs.isEmpty
    leadingFullSwipeView.isHidden = true
    trailingFullSwipeView.isHidden = true
    updateActionsMask(
      leadingActionsMaskLayer,
      visibleRect: CGRect(x: 0, y: 0, width: leadingRevealWidth, height: bounds.height)
    )
    updateActionsMask(
      trailingActionsMaskLayer,
      visibleRect: CGRect(
        x: max(0, bounds.width - trailingRevealWidth),
        y: 0,
        width: trailingRevealWidth,
        height: bounds.height
      )
    )

    layoutLeadingButtons(
      revealWidth: leadingRevealWidth,
      expansionProgress: leadingExpansionProgress,
      height: bounds.height
    )
    layoutTrailingButtons(
      revealWidth: trailingRevealWidth,
      expansionProgress: trailingExpansionProgress,
      height: bounds.height,
      boundsWidth: bounds.width
    )
  }

  private func layoutLeadingButtons(
    revealWidth: CGFloat,
    expansionProgress: CGFloat,
    height: CGFloat
  ) {
    guard !leadingActionButtons.isEmpty else { return }
    if revealWidth <= 0.5 {
      leadingActionButtons.forEach {
        $0.frame = .zero
        $0.alpha = 0
      }
      return
    }

    let targetIndex = leadingDisplaySpecs.firstIndex(where: \.isFullSwipeTarget)
      ?? max(0, leadingActionButtons.count - 1)
    if revealWidth <= leadingOpenWidth {
      let exposedRect = CGRect(x: 0, y: 0, width: revealWidth, height: height)
      var currentLeft: CGFloat = 0
      for button in leadingActionButtons {
        button.frame = CGRect(x: currentLeft, y: 0, width: leadingActionWidth, height: height)
        let visibleWidth = max(0, button.frame.intersection(exposedRect).width)
        button.alpha = visibleWidth > 0.5 ? 1 : 0
        button.updateRevealWidth(visibleWidth, expansionProgress: 0)
        currentLeft += leadingActionWidth
      }
      return
    }

    let extraWidth = revealWidth - leadingOpenWidth
    let exposedRect = CGRect(x: 0, y: 0, width: revealWidth, height: height)
    var x: CGFloat = 0
    for (index, button) in leadingActionButtons.enumerated() {
      let width = leadingActionWidth + (index == targetIndex ? max(0, extraWidth) : 0)
      button.frame = CGRect(x: x, y: 0, width: width, height: height)
      button.alpha = 1
      let visibleWidth = max(0, button.frame.intersection(exposedRect).width)
      button.updateRevealWidth(
        visibleWidth,
        expansionProgress: index == targetIndex ? expansionProgress : 0
      )
      x += width
    }
  }

  private func layoutTrailingButtons(
    revealWidth: CGFloat,
    expansionProgress: CGFloat,
    height: CGFloat,
    boundsWidth: CGFloat
  ) {
    guard !trailingActionButtons.isEmpty else { return }
    if revealWidth <= 0.5 {
      trailingActionButtons.forEach {
        $0.frame = .zero
        $0.alpha = 0
      }
      return
    }

    let targetIndex = trailingDisplaySpecs.firstIndex(where: \.isFullSwipeTarget) ?? 0
    if revealWidth <= trailingOpenWidth {
      let exposedRect = CGRect(
        x: boundsWidth - revealWidth,
        y: 0,
        width: revealWidth,
        height: height
      )
      var currentLeft = boundsWidth - trailingOpenWidth
      for button in trailingActionButtons {
        button.frame = CGRect(x: currentLeft, y: 0, width: trailingActionWidth, height: height)
        let visibleWidth = max(0, button.frame.intersection(exposedRect).width)
        button.alpha = visibleWidth > 0.5 ? 1 : 0
        button.updateRevealWidth(visibleWidth, expansionProgress: 0)
        currentLeft += trailingActionWidth
      }
      return
    }

    let extraWidth = max(0, revealWidth - trailingOpenWidth)
    let widths = trailingActionButtons.enumerated().map { index, _ in
      trailingActionWidth + (index == targetIndex ? extraWidth : 0)
    }
    let exposedRect = CGRect(
      x: boundsWidth - revealWidth,
      y: 0,
      width: revealWidth,
      height: height
    )
    var currentRight = boundsWidth
    for (index, button) in trailingActionButtons.enumerated().reversed() {
      let width = widths[index]
      button.frame = CGRect(x: currentRight - width, y: 0, width: width, height: height)
      button.alpha = 1
      let visibleWidth = max(0, button.frame.intersection(exposedRect).width)
      button.updateRevealWidth(
        visibleWidth,
        expansionProgress: index == targetIndex ? expansionProgress : 0
      )
      currentRight -= width
    }
  }

  private var leadingActionWidth: CGFloat { 72 }
  private var trailingActionWidth: CGFloat { 74 }
  private var leadingOpenWidth: CGFloat { CGFloat(leadingDisplaySpecs.count) * leadingActionWidth }
  private var trailingOpenWidth: CGFloat { CGFloat(trailingDisplaySpecs.count) * trailingActionWidth }
  private var swipeActivationThreshold: CGFloat { 12 }
  private var leadingFullSwipeTriggerDistance: CGFloat {
    min(bounds.width - 24, max(leadingOpenWidth + 18, bounds.width * 0.58))
  }
  private var trailingFullSwipeTriggerDistance: CGFloat {
    min(bounds.width - 24, max(trailingOpenWidth + 18, bounds.width * 0.58))
  }

  private func expansionProgress(revealWidth: CGFloat, openWidth: CGFloat) -> CGFloat {
    guard revealWidth > openWidth else { return 0 }
    let denominator = max(1, bounds.width - openWidth)
    return clamp((revealWidth - openWidth) / denominator)
  }

  private func updateActionsMask(_ maskLayer: CALayer, visibleRect: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(UIView.inheritedAnimationDuration <= 0)
    maskLayer.frame = visibleRect
    CATransaction.commit()
  }

  private func clamp(_ value: CGFloat) -> CGFloat {
    min(1, max(0, value))
  }

  private func loadAvatarImage(urlString: String?) {
    let transportStatus = ChatEngine.shared.getTransportStatus()
    let transportMode = (transportStatus["transportMode"] as? String) ?? "direct"
    let disableRemoteAvatars = (transportStatus["disableRemoteAvatars"] as? Bool) ?? false
    if transportMode == "bridge_text" || disableRemoteAvatars {
      avatarLoadTask?.cancel()
      avatarLoadTask = nil
      avatarImageView.image = nil
      avatarFallbackIconView.isHidden = false
      lastAvatarURLString = nil
      return
    }
    let normalizedURL = (urlString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedURL == lastAvatarURLString,
      avatarImageView.image != nil
    {
      avatarFallbackIconView.isHidden = true
      return
    }

    avatarLoadTask?.cancel()
    avatarLoadTask = nil
    avatarToken = UUID().uuidString
    lastAvatarURLString = normalizedURL

    guard
      !normalizedURL.isEmpty,
      let url = URL(string: normalizedURL),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    else {
      avatarImageView.image = nil
      avatarFallbackIconView.isHidden = false
      lastAvatarURLString = nil
      return
    }

    if let cached = Self.avatarImageCache.object(forKey: normalizedURL as NSString) {
      avatarImageView.image = cached
      avatarFallbackIconView.isHidden = true
      return
    }

    avatarImageView.image = nil
    avatarFallbackIconView.isHidden = false

    let token = avatarToken
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 12.0
    request.cachePolicy = .returnCacheDataElseLoad
    request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    let task = Self.avatarSession.dataTask(with: request) { [weak self] data, response, _ in
      guard let self else { return }
      guard token == self.avatarToken else { return }
      guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
        (200...299).contains(statusCode)
      else { return }
      guard token == self.avatarToken, let data, let image = UIImage(data: data) else { return }
      Self.avatarImageCache.setObject(image, forKey: normalizedURL as NSString)
      DispatchQueue.main.async {
        guard token == self.avatarToken else { return }
        self.avatarImageView.image = image
        self.avatarFallbackIconView.isHidden = true
      }
    }
    avatarLoadTask = task
    task.resume()
  }
}

private final class ChatNativeHomeSwipeActionButton: UIButton {
  private let tileView = ChatNativeHomeSwipeActionTileView()
  private(set) var spec: ChatNativeHomeSwipeActionSpec?
  private var edge: ChatNativeHomeSwipeEdge = .trailing
  private var currentRevealWidth: CGFloat = 0
  private var currentExpansionProgress: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.cornerRadius = 0
    adjustsImageWhenHighlighted = false
    showsTouchWhenHighlighted = false
    addSubview(tileView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    tileView.frame = bounds
    tileView.updateRevealWidth(currentRevealWidth, expansionProgress: currentExpansionProgress)
  }

  func configure(spec: ChatNativeHomeSwipeActionSpec, edge: ChatNativeHomeSwipeEdge) {
    self.spec = spec
    self.edge = edge
    currentRevealWidth = 0
    currentExpansionProgress = 0
    backgroundColor = spec.backgroundColor
    tileView.configure(spec: spec, edge: edge)
    setNeedsLayout()
  }

  func updateRevealWidth(_ width: CGFloat, expansionProgress: CGFloat) {
    currentRevealWidth = width
    currentExpansionProgress = expansionProgress
    tileView.frame = bounds
    tileView.updateRevealWidth(width, expansionProgress: expansionProgress)
  }
}

private final class ChatNativeHomeSwipeActionTileView: UIView {
  private let stackView = UIStackView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private var stackLeadingConstraint: NSLayoutConstraint?
  private var stackTrailingConstraint: NSLayoutConstraint?
  private var iconWidthConstraint: NSLayoutConstraint?
  private var iconHeightConstraint: NSLayoutConstraint?
  private var spec: ChatNativeHomeSwipeActionSpec?
  private var edge: ChatNativeHomeSwipeEdge = .trailing

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    layer.cornerRadius = 0

    iconView.contentMode = .scaleAspectFit
    iconView.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 1
    titleLabel.adjustsFontSizeToFitWidth = true
    titleLabel.minimumScaleFactor = 0.75

    stackView.axis = .vertical
    stackView.alignment = .center
    stackView.distribution = .fill
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.addArrangedSubview(iconView)
    stackView.addArrangedSubview(titleLabel)

    addSubview(stackView)

    let stackLeadingConstraint = stackView.leadingAnchor.constraint(
      greaterThanOrEqualTo: leadingAnchor,
      constant: 8
    )
    let stackTrailingConstraint = stackView.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor,
      constant: -8
    )
    let iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 30)
    let iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 30)
    self.stackLeadingConstraint = stackLeadingConstraint
    self.stackTrailingConstraint = stackTrailingConstraint
    self.iconWidthConstraint = iconWidthConstraint
    self.iconHeightConstraint = iconHeightConstraint

    let centerXConstraint = stackView.centerXAnchor.constraint(equalTo: centerXAnchor)
    let centerYConstraint = stackView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1)
    centerXConstraint.priority = .defaultHigh
    centerYConstraint.priority = .defaultHigh
    stackLeadingConstraint.priority = .defaultHigh
    stackTrailingConstraint.priority = .defaultHigh

    NSLayoutConstraint.activate([
      centerXConstraint,
      centerYConstraint,
      stackLeadingConstraint,
      stackTrailingConstraint,
      iconWidthConstraint,
      iconHeightConstraint,
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(spec: ChatNativeHomeSwipeActionSpec, edge: ChatNativeHomeSwipeEdge) {
    self.spec = spec
    self.edge = edge
    backgroundColor = spec.backgroundColor
    iconView.tintColor = spec.foregroundColor
    titleLabel.text = spec.title
    titleLabel.textColor = spec.foregroundColor
    titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
    let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
    iconView.image = UIImage(systemName: spec.systemImageName, withConfiguration: config)?
      .withRenderingMode(.alwaysTemplate)
    updateRevealWidth(bounds.width, expansionProgress: 0)
  }

  func updateRevealWidth(_ width: CGFloat, expansionProgress: CGFloat) {
    let clampedWidth = max(0.0, width)
    let horizontalInset = min(8.0, floor(clampedWidth * 0.25))
    stackLeadingConstraint?.constant = horizontalInset
    stackTrailingConstraint?.constant = -horizontalInset
    let iconSide = min(30.0, max(0.0, clampedWidth - (horizontalInset * 2.0)))
    iconWidthConstraint?.constant = iconSide
    iconHeightConstraint?.constant = iconSide

    let titleProgress = clamp((width - 42) / 16)

    stackView.spacing = 5
    stackView.alpha = clampedWidth > 0.5 ? 1 : 0
    stackView.transform = .identity
    titleLabel.isHidden = titleProgress <= 0.01
    titleLabel.alpha = titleProgress
    titleLabel.transform = .identity
    iconView.alpha = iconSide > 0.5 ? 1 : 0
    iconView.transform = .identity
  }

  private func clamp(_ value: CGFloat) -> CGFloat {
    min(1, max(0, value))
  }
}
