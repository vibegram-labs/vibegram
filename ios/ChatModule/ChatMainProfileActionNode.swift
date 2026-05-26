import UIKit

final class ChatMainProfileActionNode: UIControl {
  private let glassView = UIVisualEffectView(effect: nil)
  private let iconView = UIImageView()
  private let titleView = UILabel()
  private let pressedOverlay = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous

    glassView.clipsToBounds = true
    glassView.layer.cornerCurve = .continuous
    glassView.isUserInteractionEnabled = false
    addSubview(glassView)

    iconView.contentMode = .scaleAspectFit
    addSubview(iconView)

    titleView.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    titleView.textAlignment = .center
    titleView.numberOfLines = 1
    addSubview(titleView)

    pressedOverlay.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    pressedOverlay.alpha = 0
    pressedOverlay.isUserInteractionEnabled = false
    addSubview(pressedOverlay)
  }

  override var isHighlighted: Bool {
    didSet {
      let scale: CGFloat = isHighlighted ? 0.97 : 1.0
      let duration: TimeInterval = isHighlighted ? 0.08 : 0.18
      UIView.animate(
        withDuration: duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]
      ) {
        self.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.pressedOverlay.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = 16
    glassView.layer.cornerRadius = 16
    glassView.frame = bounds

    let iconSize: CGFloat = 24
    let titleHeight: CGFloat = 17
    let spacing: CGFloat = 6
    let totalHeight = iconSize + spacing + titleHeight
    let startY = max(6.0, (bounds.height - totalHeight) * 0.5)
    iconView.frame = CGRect(
      x: (bounds.width - iconSize) * 0.5, y: startY, width: iconSize, height: iconSize)
    titleView.frame = CGRect(
      x: 6.0,
      y: iconView.frame.maxY + spacing,
      width: bounds.width - 12.0,
      height: titleHeight
    )
    pressedOverlay.frame = bounds
  }

  func configure(title: String, symbol: String) {
    titleView.text = title
    let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    iconView.image = UIImage(systemName: symbol, withConfiguration: cfg)
  }

  func setTitle(_ title: String) {
    titleView.text = title
  }

  func applyTheme(foreground: UIColor, background: UIColor) {
    titleView.textColor = foreground
    iconView.tintColor = foreground
    self.backgroundColor = .clear

    glassView.effect = nil
    glassView.contentView.backgroundColor = background.withAlphaComponent(0.68)
  }
}
