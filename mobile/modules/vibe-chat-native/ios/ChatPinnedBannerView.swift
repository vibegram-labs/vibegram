import UIKit

final class ChatPinnedBannerView: UIControl {
  static let preferredHeight: CGFloat = 44.0

  private let blurView = UIVisualEffectView(effect: nil)
  private let tintOverlayView = UIView()
  private let iconContainer = UIView()
  private let iconGlowView = UIView()
  private let iconImageView = UIImageView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let textStack = UIStackView()
  private var isFilePinned = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title: String, body: String, isFile: Bool, animateIcon: Bool = false) {
    let shouldAnimate =
      animateIcon
      || titleLabel.text != title
      || bodyLabel.text != body
      || isFilePinned != isFile
    titleLabel.text = title
    bodyLabel.text = body
    isFilePinned = isFile
    iconImageView.image = UIImage(systemName: isFile ? "pin.circle.fill" : "pin.fill")
    if shouldAnimate {
      animatePinIcon()
    }
  }

  func applyTheme(textColor: UIColor, surfaceColor: UIColor, isDark: Bool) {
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = false
      blurView.effect = glass
    } else {
      blurView.effect = UIBlurEffect(style: .systemThinMaterial)
    }
    tintOverlayView.backgroundColor = surfaceColor.withAlphaComponent(isDark ? 0.22 : 0.14)
    iconContainer.backgroundColor = surfaceColor.withAlphaComponent(isDark ? 0.30 : 0.20)
    iconGlowView.backgroundColor = textColor.withAlphaComponent(isDark ? 0.30 : 0.20)
    iconImageView.tintColor = textColor.withAlphaComponent(0.95)
    titleLabel.textColor = textColor.withAlphaComponent(0.96)
    bodyLabel.textColor = textColor.withAlphaComponent(0.82)
    layer.borderColor = textColor.withAlphaComponent(isDark ? 0.12 : 0.08).cgColor
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = ChatPinnedBannerView.preferredHeight / 2.0
    layer.borderWidth = 1.0
    layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    backgroundColor = .clear

    addSubview(blurView)
    blurView.contentView.addSubview(tintOverlayView)
    addSubview(iconContainer)
    iconContainer.addSubview(iconGlowView)
    iconContainer.addSubview(iconImageView)
    addSubview(textStack)

    iconImageView.image = UIImage(systemName: "pin.fill")
    iconImageView.contentMode = .scaleAspectFit
    iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 13, weight: .semibold)

    iconContainer.layer.cornerCurve = .continuous
    iconContainer.layer.cornerRadius = 14.0
    iconGlowView.layer.cornerCurve = .continuous
    iconGlowView.layer.cornerRadius = 14.0
    iconGlowView.alpha = 0.0

    titleLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail

    bodyLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    bodyLabel.numberOfLines = 1
    bodyLabel.lineBreakMode = .byTruncatingTail

    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.distribution = .fill
    textStack.spacing = 1.0
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(bodyLabel)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurView.frame = bounds
    tintOverlayView.frame = blurView.bounds

    let iconSize: CGFloat = 28.0
    iconContainer.frame = CGRect(x: 10.0, y: (bounds.height - iconSize) * 0.5, width: iconSize, height: iconSize)
    iconGlowView.frame = iconContainer.bounds
    iconImageView.frame = iconContainer.bounds.insetBy(dx: 7.0, dy: 7.0)

    let textX = iconContainer.frame.maxX + 10.0
    textStack.frame = CGRect(
      x: textX,
      y: 6.0,
      width: max(0.0, bounds.width - textX - 12.0),
      height: max(0.0, bounds.height - 12.0)
    )
  }

  private func animatePinIcon() {
    iconContainer.layer.removeAnimation(forKey: "pinScale")
    iconImageView.layer.removeAnimation(forKey: "pinWiggle")
    iconGlowView.layer.removeAnimation(forKey: "pinGlow")

    let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    wiggle.values = [0.0, -0.18, 0.14, -0.08, 0.04, 0.0]
    wiggle.keyTimes = [0.0, 0.2, 0.42, 0.62, 0.82, 1.0]
    wiggle.duration = 0.46
    wiggle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    iconImageView.layer.add(wiggle, forKey: "pinWiggle")

    let scale = CASpringAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.88
    scale.toValue = 1.0
    scale.initialVelocity = 0.7
    scale.damping = 10.0
    scale.stiffness = 140.0
    scale.mass = 0.9
    scale.duration = scale.settlingDuration
    iconContainer.layer.add(scale, forKey: "pinScale")

    iconGlowView.alpha = 0.0
    UIView.animate(
      withDuration: 0.18,
      delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      self.iconGlowView.alpha = 1.0
    } completion: { _ in
      UIView.animate(
        withDuration: 0.32,
        delay: 0.0,
        options: [.beginFromCurrentState, .curveEaseIn]
      ) {
        self.iconGlowView.alpha = 0.0
      }
    }
  }
}
