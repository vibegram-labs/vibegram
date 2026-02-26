import UIKit

final class ChatNativeHomeCardCell: UITableViewCell {
  static let reuseIdentifier = "ChatNativeHomeCardCell"
  private static let avatarImageCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 256
    return cache
  }()
  private static let avatarSession: URLSession = {
    if #available(iOS 13.0, *) {
      return ChatPhoenixClient.makePinnedURLSession()
    }
    return URLSession.shared
  }()

  private let pressOverlayView = UIView()
  private let dividerView = UIView()
  private let avatarContainer = UIView()
  private let avatarImageView = UIImageView()
  private let avatarFallbackIconView = UIImageView()
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
    unreadBadge.isHidden = true
    muteIconView.isHidden = true
    pinIconView.isHidden = true
    pressOverlayView.alpha = 0
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

  func configure(row: ChatNativeHomeListRow, isDark: Bool, avatarBackgroundColor: UIColor?) {
    let primary = isDark ? UIColor.white : UIColor(red: 22 / 255, green: 28 / 255, blue: 36 / 255, alpha: 1)
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
    let dividerColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.06)
      : UIColor.black.withAlphaComponent(0.03)

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

    let fallbackIconName = row.isSavedMessages ? "bookmark.fill" : "person.fill"
    avatarFallbackIconView.image = UIImage(systemName: fallbackIconName)
    avatarFallbackIconView.tintColor = isDark ? UIColor.white : UIColor.darkText

    let avatarBackground =
      avatarBackgroundColor
      ?? (isDark
        ? UIColor(red: 63 / 255, green: 70 / 255, blue: 85 / 255, alpha: 1)
        : UIColor(red: 222 / 255, green: 230 / 255, blue: 243 / 255, alpha: 1))
    avatarContainer.backgroundColor = avatarBackground
    pressOverlayView.backgroundColor = pressedColor
    dividerView.backgroundColor = dividerColor

    loadAvatarImage(urlString: row.avatarUri)
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

  private func configureView() {
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    pressOverlayView.translatesAutoresizingMaskIntoConstraints = false
    pressOverlayView.alpha = 0
    pressOverlayView.isUserInteractionEnabled = false

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    dividerView.isUserInteractionEnabled = false

    avatarContainer.translatesAutoresizingMaskIntoConstraints = false
    avatarContainer.layer.cornerRadius = 30
    avatarContainer.clipsToBounds = true

    avatarImageView.translatesAutoresizingMaskIntoConstraints = false
    avatarImageView.contentMode = .scaleAspectFill
    avatarImageView.clipsToBounds = true

    avatarFallbackIconView.translatesAutoresizingMaskIntoConstraints = false
    avatarFallbackIconView.contentMode = .scaleAspectFit
    avatarFallbackIconView.image = UIImage(systemName: "person.fill")
    avatarFallbackIconView.tintColor = UIColor.darkGray

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

    contentView.addSubview(pressOverlayView)
    contentView.addSubview(dividerView)
    contentView.addSubview(avatarContainer)
    avatarContainer.addSubview(avatarImageView)
    avatarContainer.addSubview(avatarFallbackIconView)
    contentView.addSubview(onlineDot)
    contentView.addSubview(textStack)
    contentView.addSubview(metaStack)
    unreadBadge.addSubview(unreadLabel)

    NSLayoutConstraint.activate([
      pressOverlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      pressOverlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      pressOverlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
      pressOverlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      dividerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

      avatarContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      avatarContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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

      onlineDot.widthAnchor.constraint(equalToConstant: 12),
      onlineDot.heightAnchor.constraint(equalToConstant: 12),
      onlineDot.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: -1),
      onlineDot.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor, constant: -1),

      textStack.leadingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: 14),
      textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: metaStack.leadingAnchor, constant: -8),

      metaStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      metaStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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
      contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 84),
    ])
  }

  private func loadAvatarImage(urlString: String?) {
    let normalizedURL = (urlString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if
      normalizedURL == lastAvatarURLString,
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
      guard let statusCode = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(statusCode)
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
