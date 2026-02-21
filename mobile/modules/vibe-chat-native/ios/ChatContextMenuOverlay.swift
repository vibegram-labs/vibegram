import UIKit

public protocol ChatContextMenuOverlayDelegate: AnyObject {
  func contextMenuDidDismiss(overlay: ChatContextMenuOverlay)
  func contextMenuDidSelectReaction(_ reaction: String, messageId: String)
  func contextMenuDidSelectAction(_ actionId: String, messageId: String)
}

// MARK: - Glass Helper

/// Creates a UIVisualEffectView that uses real UIGlassEffect on iOS 26+,
/// and falls back to UIBlurEffect on older iOS versions.
private func makeLiquidGlassView(
  style: UIBlurEffect.Style = .systemMaterial,
  cornerRadius: CGFloat,
  capsuleCorners: Bool = false,
  interactive: Bool = false
) -> UIVisualEffectView {
  let view = UIVisualEffectView(effect: nil)
  if #available(iOS 26.0, *) {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = interactive
    view.effect = effect
    if capsuleCorners {
      view.cornerConfiguration = .capsule()
    } else {
      view.layer.cornerRadius = cornerRadius
      view.layer.cornerCurve = .continuous
    }
  } else {
    view.effect = UIBlurEffect(style: style)
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
  }
  view.clipsToBounds = true
  return view
}

// MARK: - ChatContextMenuOverlay

public final class ChatContextMenuOverlay: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  let messageId: String

  // The bubble snapshot (bubble+tail only, already positioned in window coords)
  private let bubbleSnapshot: UIView
  // The bubble's original frame in window coords (before any shifting)
  private let originalBubbleFrame: CGRect

  private let appearance: ChatListAppearance

  // Full-screen native glass background (same as Telegram / UIContextMenuInteraction)
  private let backgroundGlassView: UIVisualEffectView

  // Reaction picker pill
  private let reactionPicker: ReactionPickerView

  // Action menu card
  private let contextMenu: ContextMenuView

  private var isDismissing = false

  // MARK: - Init

  init(
    messageId: String,
    bubbleSnapshot: UIView,
    bubbleFrame: CGRect,
    appearance: ChatListAppearance
  ) {
    self.messageId = messageId
    self.bubbleSnapshot = bubbleSnapshot
    self.originalBubbleFrame = bubbleFrame
    self.appearance = appearance

    // Full-screen background: native system glass (ultraThin), same as Telegram
    let bgStyle: UIBlurEffect.Style =
      appearance.backgroundMode == "dark"
      ? .systemUltraThinMaterialDark
      : .systemUltraThinMaterial
    self.backgroundGlassView = makeLiquidGlassView(
      style: bgStyle,
      cornerRadius: 0
    )

    self.reactionPicker = ReactionPickerView(appearance: appearance, messageId: messageId)
    self.contextMenu = ContextMenuView(appearance: appearance, messageId: messageId)

    super.init(frame: .zero)

    setupViews()
    setupGestures()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    // 1. Full-screen glass background
    backgroundGlassView.alpha = 0
    addSubview(backgroundGlassView)

    // 2. Bubble snapshot (already has correct frame in window coords)
    bubbleSnapshot.alpha = 0
    addSubview(bubbleSnapshot)

    // 3. Reaction picker (above bubble)
    reactionPicker.alpha = 0
    reactionPicker.delegate = self
    addSubview(reactionPicker)

    // 4. Context menu (below or above bubble)
    contextMenu.alpha = 0
    contextMenu.delegate = self
    addSubview(contextMenu)
  }

  private func setupGestures() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
    tap.delegate = self
    addGestureRecognizer(tap)
  }

  @objc private func handleBackgroundTap() {
    animateOut()
  }

  // MARK: - Layout

  /// Computes the shifted bubble frame and positions all elements.
  /// Returns the final bubble frame (may be shifted from original).
  @discardableResult
  private func layoutMenus() -> CGRect {
    let safeTop = safeAreaInsets.top + 8
    let safeBottom = bounds.height - safeAreaInsets.bottom - 8

    // Measure reaction picker
    let pickerSize = reactionPicker.intrinsicContentSize
    let pickerHeight = pickerSize.height
    let pickerGap: CGFloat = 8

    // Measure context menu
    let menuWidth: CGFloat = 250
    let menuHeight = contextMenu.systemLayoutSizeFitting(
      CGSize(width: menuWidth, height: UIView.layoutFittingCompressedSize.height)
    ).height
    // Keep the action menu visually attached to the bubble (Telegram-like spacing).
    let menuGap: CGFloat = 1

    // Keep the composition near the original bubble, don't center vertically
    // Total vertical space needed: picker above + bubble + menu below
    let totalHeight =
      pickerHeight + pickerGap + originalBubbleFrame.height + menuGap + menuHeight

    var compositionTop = originalBubbleFrame.minY - pickerHeight - pickerGap

    // Clamp to safe area
    compositionTop = max(safeTop, compositionTop)
    if compositionTop + totalHeight > safeBottom {
      compositionTop = safeBottom - totalHeight
      compositionTop = max(safeTop, compositionTop)
    }

    // Compute each element's Y
    let pickerY = compositionTop
    let bubbleY = pickerY + pickerHeight + pickerGap
    let menuY = bubbleY + originalBubbleFrame.height + menuGap

    // Horizontal alignment: align to bubble's leading/trailing edge
    let isRightAligned = originalBubbleFrame.midX > bounds.midX

    // Reaction picker: align to bubble edge, clamped to screen
    let pickerWidth = min(pickerSize.width, bounds.width - 32)
    let pickerX: CGFloat
    if isRightAligned {
      pickerX = max(16, originalBubbleFrame.maxX - pickerWidth)
    } else {
      pickerX = min(bounds.width - pickerWidth - 16, originalBubbleFrame.minX)
    }
    reactionPicker.frame = CGRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)

    // Bubble: keep original X, shift Y to new position
    let finalBubbleFrame = CGRect(
      x: originalBubbleFrame.minX,
      y: bubbleY,
      width: originalBubbleFrame.width,
      height: originalBubbleFrame.height
    )
    bubbleSnapshot.frame = finalBubbleFrame

    // Context menu: align to bubble edge
    let menuX: CGFloat
    if isRightAligned {
      menuX = max(16, finalBubbleFrame.maxX - menuWidth)
    } else {
      menuX = min(bounds.width - menuWidth - 16, finalBubbleFrame.minX)
    }
    contextMenu.frame = CGRect(x: menuX, y: menuY, width: menuWidth, height: menuHeight)

    return finalBubbleFrame
  }

  // MARK: - Animate In / Out

  func animateIn() {
    guard let window = window else { return }
    frame = window.bounds
    backgroundGlassView.frame = bounds

    // Place bubble at original position first (before layout shifts it)
    bubbleSnapshot.frame = originalBubbleFrame
    bubbleSnapshot.alpha = 1

    layoutIfNeeded()

    // Compute final layout (this shifts the bubble)
    let finalBubbleFrame = layoutMenus()

    // --- Background glass fade in ---
    UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
      self.backgroundGlassView.alpha = 1
    }

    // --- Bubble: spring from original position to shifted position ---
    let deltaY = finalBubbleFrame.minY - originalBubbleFrame.minY
    bubbleSnapshot.frame = originalBubbleFrame  // start at original
    bubbleSnapshot.transform = .identity

    let springParams = UISpringTimingParameters(dampingRatio: 0.75, initialVelocity: .zero)
    let bubbleAnimator = UIViewPropertyAnimator(duration: 0.45, timingParameters: springParams)
    bubbleAnimator.addAnimations {
      self.bubbleSnapshot.transform = CGAffineTransform(translationX: 0, y: deltaY)
    }
    bubbleAnimator.startAnimation()

    // --- Reaction picker: slide up from bubble top edge ---
    let pickerFinalFrame = reactionPicker.frame
    reactionPicker.frame = CGRect(
      x: pickerFinalFrame.minX,
      y: pickerFinalFrame.maxY,  // start just below its final position (from bubble top)
      width: pickerFinalFrame.width,
      height: pickerFinalFrame.height
    )
    reactionPicker.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)

    UIView.animate(
      withDuration: 0.38, delay: 0.05,
      usingSpringWithDamping: 0.72, initialSpringVelocity: 0.3,
      options: .curveEaseOut
    ) {
      self.reactionPicker.alpha = 1
      self.reactionPicker.frame = pickerFinalFrame
      self.reactionPicker.transform = .identity
    }

    // --- Context menu: scale in from top (attached to bubble bottom) ---
    contextMenu.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
      .translatedBy(x: 0, y: -6)

    UIView.animate(
      withDuration: 0.35, delay: 0.08,
      usingSpringWithDamping: 0.78, initialSpringVelocity: 0.2,
      options: .curveEaseOut
    ) {
      self.contextMenu.alpha = 1
      self.contextMenu.transform = .identity
    }
  }

  func animateOut(completion: (() -> Void)? = nil) {
    if isDismissing { return }
    isDismissing = true

    UIView.animate(
      withDuration: 0.22, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]
    ) {
      self.backgroundGlassView.alpha = 0
      self.reactionPicker.alpha = 0
      self.contextMenu.alpha = 0
      self.bubbleSnapshot.alpha = 0
      // Snap bubble back to original position
      self.bubbleSnapshot.transform = .identity
      self.bubbleSnapshot.frame = self.originalBubbleFrame
    } completion: { _ in
      self.removeFromSuperview()
      self.delegate?.contextMenuDidDismiss(overlay: self)
      completion?()
    }
  }
}

// MARK: - UIGestureRecognizerDelegate

extension ChatContextMenuOverlay: UIGestureRecognizerDelegate {
  public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer)
    -> Bool
  {
    let point = gestureRecognizer.location(in: self)
    // Only dismiss if tap is outside the bubble, picker, and menu
    if bubbleSnapshot.frame.contains(point) { return false }
    if reactionPicker.frame.contains(point) { return false }
    if contextMenu.frame.contains(point) { return false }
    return true
  }
}

// MARK: - ChatContextMenuOverlayDelegate (self-forwarding)

extension ChatContextMenuOverlay: ChatContextMenuOverlayDelegate {
  public func contextMenuDidDismiss(overlay: ChatContextMenuOverlay) {}

  public func contextMenuDidSelectReaction(_ reaction: String, messageId _: String) {
    delegate?.contextMenuDidSelectReaction(reaction, messageId: messageId)
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId _: String) {
    delegate?.contextMenuDidSelectAction(actionId, messageId: messageId)
  }
}

// MARK: - Reaction Picker View

final class ReactionPickerView: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  private let glassView: UIVisualEffectView
  private let stack: UIStackView
  private let emojis = ["👍", "👎", "❤️", "🔥", "🎉", "💩"]

  let messageId: String

  override var intrinsicContentSize: CGSize {
    let emojiCount = CGFloat(emojis.count)
    let buttonSize: CGFloat = 44
    let spacing: CGFloat = 4
    let padding: CGFloat = 12
    let width = emojiCount * buttonSize + (emojiCount - 1) * spacing + padding * 2
    return CGSize(width: width, height: buttonSize + 8)
  }

  init(appearance: ChatListAppearance, messageId: String) {
    self.messageId = messageId
    // Liquid glass pill for reaction bar
    self.glassView = makeLiquidGlassView(
      style: appearance.backgroundMode == "dark" ? .systemThinMaterialDark : .systemThinMaterial,
      cornerRadius: 26,
      capsuleCorners: true
    )
    self.stack = UIStackView()

    super.init(frame: .zero)

    glassView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glassView)

    stack.axis = .horizontal
    stack.distribution = .fillEqually
    stack.spacing = 4
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false

    // Add stack to glass view's contentView so it renders above the glass
    glassView.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),

      stack.topAnchor.constraint(equalTo: glassView.contentView.topAnchor, constant: 4),
      stack.bottomAnchor.constraint(equalTo: glassView.contentView.bottomAnchor, constant: -4),
      stack.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor, constant: -12),
    ])

    for emoji in emojis {
      let btn = UIButton(type: .system)
      btn.setTitle(emoji, for: .normal)
      btn.titleLabel?.font = UIFont.systemFont(ofSize: 28)
      btn.translatesAutoresizingMaskIntoConstraints = false
      btn.widthAnchor.constraint(equalToConstant: 44).isActive = true
      btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
      btn.addTarget(self, action: #selector(didTapEmoji(_:)), for: .touchUpInside)
      stack.addArrangedSubview(btn)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func didTapEmoji(_ sender: UIButton) {
    guard let emoji = sender.title(for: .normal) else { return }
    // Spring bounce on tap
    UIView.animate(
      withDuration: 0.12, delay: 0, options: .curveEaseIn,
      animations: { sender.transform = CGAffineTransform(scaleX: 1.3, y: 1.3) }
    ) { _ in
      UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseOut) {
        sender.transform = .identity
      }
    }
    delegate?.contextMenuDidSelectReaction(emoji, messageId: messageId)
  }
}

// MARK: - Context Menu View

final class ContextMenuView: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  private let glassView: UIVisualEffectView
  private let stack: UIStackView

  struct ActionItem {
    let id: String
    let title: String
    let iconName: String
    let isDestructive: Bool
  }

  private let actions: [ActionItem] = [
    ActionItem(
      id: "reply", title: "Reply", iconName: "arrowshape.turn.up.left", isDestructive: false),
    ActionItem(id: "copy", title: "Copy", iconName: "doc.on.doc", isDestructive: false),
    ActionItem(id: "resend", title: "Resend", iconName: "arrow.clockwise", isDestructive: false),
    ActionItem(id: "pin", title: "Pin", iconName: "pin", isDestructive: false),
    ActionItem(id: "delete", title: "Delete", iconName: "trash", isDestructive: true),
  ]

  let messageId: String

  init(appearance: ChatListAppearance, messageId: String) {
    self.messageId = messageId
    // Liquid glass card for action menu — same material as native iOS context menus
    self.glassView = makeLiquidGlassView(
      style: appearance.backgroundMode == "dark" ? .systemMaterialDark : .systemMaterial,
      cornerRadius: 12,
      capsuleCorners: false
    )
    self.stack = UIStackView()

    super.init(frame: .zero)

    glassView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glassView)

    stack.axis = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    glassView.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),

      stack.topAnchor.constraint(equalTo: glassView.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: glassView.contentView.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor),
    ])

    for action in actions {
      let row = ContextMenuRow(action: action)
      row.addTarget(self, action: #selector(didTapAction(_:)), for: .touchUpInside)
      stack.addArrangedSubview(row)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func didTapAction(_ sender: ContextMenuRow) {
    delegate?.contextMenuDidSelectAction(sender.actionId, messageId: messageId)
  }
}

// MARK: - Context Menu Row

final class ContextMenuRow: UIControl {
  let actionId: String
  private let titleLabel: UILabel
  private let iconView: UIImageView

  init(action: ContextMenuView.ActionItem) {
    self.actionId = action.id
    self.titleLabel = UILabel()
    self.iconView = UIImageView()
    super.init(frame: .zero)

    backgroundColor = .clear

    titleLabel.text = action.title
    titleLabel.font = UIFont.systemFont(ofSize: 17)
    titleLabel.textColor = action.isDestructive ? .systemRed : .label

    let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
    if let image = UIImage(systemName: action.iconName, withConfiguration: config) {
      iconView.image = image
      iconView.tintColor = action.isDestructive ? .systemRed : .label
    }
    iconView.contentMode = .scaleAspectFit

    addSubview(titleLabel)
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    iconView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 44),

      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 22),
      iconView.heightAnchor.constraint(equalToConstant: 22),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.1) {
        self.backgroundColor =
          self.isHighlighted
          ? UIColor.label.withAlphaComponent(0.08)
          : .clear
      }
    }
  }
}
