import UIKit

final class ChatHomeUndoBannerView: UIControl {
  static let preferredHeight: CGFloat = 58.0

  private let blurView = UIVisualEffectView(effect: nil)
  private let iconContainer = UIView()
  private let iconImageView = UIImageView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let textStack = UIStackView()
  private let actionPillView = UIView()
  private let actionLabel = UILabel()
  private let timerLabel = UILabel()
  private var destructive = true

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    title: String,
    body: String,
    actionTitle: String,
    timerText: String,
    destructive: Bool
  ) {
    self.destructive = destructive
    titleLabel.text = title
    bodyLabel.text = body
    actionLabel.text = actionTitle
    timerLabel.text = timerText
    iconImageView.image = UIImage(
      systemName: destructive ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"
    )
  }

  func applyTheme(textColor: UIColor, surfaceColor: UIColor, isDark: Bool) {
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      blurView.effect = glass
    } else {
      blurView.effect = UIBlurEffect(style: .systemThinMaterial)
    }

    let accentColor = destructive
      ? UIColor(red: 0.93, green: 0.24, blue: 0.25, alpha: 1)
      : UIColor(red: 0.21, green: 0.58, blue: 0.98, alpha: 1)

    blurView.contentView.backgroundColor = surfaceColor.withAlphaComponent(isDark ? 0.16 : 0.10)
    blurView.alpha = isDark ? 0.98 : 0.95
    blurView.layer.borderColor = textColor.withAlphaComponent(isDark ? 0.10 : 0.06).cgColor

    iconContainer.backgroundColor = accentColor.withAlphaComponent(isDark ? 0.22 : 0.14)
    iconImageView.tintColor = accentColor
    titleLabel.textColor = textColor.withAlphaComponent(0.96)
    bodyLabel.textColor = textColor.withAlphaComponent(0.78)

    actionPillView.backgroundColor = accentColor.withAlphaComponent(isDark ? 0.20 : 0.14)
    actionPillView.layer.borderColor = accentColor.withAlphaComponent(isDark ? 0.24 : 0.16).cgColor
    actionLabel.textColor = accentColor
    timerLabel.textColor = textColor.withAlphaComponent(0.70)
  }

  private func setup() {
    backgroundColor = .clear

    addSubview(blurView)
    blurView.layer.cornerCurve = .continuous
    blurView.layer.cornerRadius = ChatHomeUndoBannerView.preferredHeight / 2.0
    blurView.layer.borderWidth = 1.0
    blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    blurView.clipsToBounds = true

    blurView.contentView.addSubview(iconContainer)
    blurView.contentView.addSubview(textStack)
    blurView.contentView.addSubview(actionPillView)
    blurView.contentView.addSubview(timerLabel)

    iconContainer.layer.cornerCurve = .continuous
    iconContainer.layer.cornerRadius = 15.0
    iconContainer.addSubview(iconImageView)

    iconImageView.contentMode = .scaleAspectFit
    iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 16,
      weight: .semibold
    )

    titleLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
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

    actionPillView.layer.cornerCurve = .continuous
    actionPillView.layer.cornerRadius = 15.0
    actionPillView.layer.borderWidth = 1.0
    actionPillView.addSubview(actionLabel)

    actionLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    actionLabel.textAlignment = .center

    timerLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    timerLabel.textAlignment = .right
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurView.frame = bounds

    let iconSize: CGFloat = 30.0
    iconContainer.frame = CGRect(
      x: 10.0,
      y: (bounds.height - iconSize) * 0.5,
      width: iconSize,
      height: iconSize
    )
    iconImageView.frame = iconContainer.bounds.insetBy(dx: 7.0, dy: 7.0)

    let actionWidth: CGFloat = 66.0
    let actionX = max(0, bounds.width - actionWidth - 14.0)
    actionPillView.frame = CGRect(x: actionX, y: 8.0, width: actionWidth, height: 30.0)
    actionLabel.frame = actionPillView.bounds.insetBy(dx: 8.0, dy: 6.0)
    timerLabel.frame = CGRect(x: actionX, y: actionPillView.frame.maxY + 4.0, width: actionWidth, height: 12.0)

    let textX = iconContainer.frame.maxX + 10.0
    let textWidth = max(0.0, actionX - textX - 10.0)
    textStack.frame = CGRect(
      x: textX,
      y: 8.0,
      width: textWidth,
      height: max(0.0, bounds.height - 16.0)
    )
  }
}
