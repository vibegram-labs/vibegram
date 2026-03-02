import ExpoModulesCore
import UIKit

class LiquidGlassView: ExpoView {
  private let visualEffectView: UIVisualEffectView
  private var currentBlurStyle: UIBlurEffect.Style?
  private var glassStyle: String = "clear"
  private var glassInteractive: Bool = true
  private var pressFeedbackEnabled: Bool = false
  private var isPressFeedbackActive: Bool = false
  private let glassPressedOverlayColor = UIColor(white: 1.0, alpha: 0.08)
  private var glassTintColor: UIColor?
  private var glassTint: String?
  private var glassCornerRadius: CGFloat?

  required init(appContext: AppContext? = nil) {
    visualEffectView = UIVisualEffectView(effect: nil)
    currentBlurStyle = .systemUltraThinMaterial

    super.init(appContext: appContext)

    visualEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    visualEffectView.isUserInteractionEnabled = false
    visualEffectView.backgroundColor = .clear
    visualEffectView.layer.zPosition = -1
    backgroundColor = .clear
    addSubview(visualEffectView)
    ensureEffectViewLayering()
    layer.cornerCurve = .continuous
    applyCornerStyling()
    applyCurrentEffect()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    visualEffectView.frame = bounds
    ensureEffectViewLayering()
    applyCornerStyling()
  }

  override func didAddSubview(_ subview: UIView) {
    super.didAddSubview(subview)
    guard subview !== visualEffectView else { return }
    ensureEffectViewLayering()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard #available(iOS 26.0, *) else {
      return
    }
    let oldStyle = previousTraitCollection?.userInterfaceStyle
    if oldStyle != traitCollection.userInterfaceStyle {
      applyCurrentEffect()
    }
  }

  private func applyBlurStyle(_ style: UIBlurEffect.Style) {
    currentBlurStyle = style
    if #available(iOS 26.0, *) {
      return
    }
    visualEffectView.effect = UIBlurEffect(style: style)
  }

  private func applyCurrentEffect() {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = glassInteractive
      visualEffectView.effect = effect
      visualEffectView.backgroundColor = .clear
      visualEffectView.contentView.backgroundColor = resolvedGlassTintColor()
      return
    }

    if let blurStyle = currentBlurStyle {
      visualEffectView.effect = UIBlurEffect(style: blurStyle)
    } else {
      visualEffectView.effect = nil
    }
    visualEffectView.backgroundColor = .clear
  }

  private func applyCornerStyling() {
    if #available(iOS 26.0, *) {
      let radius = max(0, Double(glassCornerRadius ?? 0))
      let shouldClip = radius > 0
      clipsToBounds = shouldClip
      visualEffectView.clipsToBounds = shouldClip
      visualEffectView.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
      return
    }

    let radius = max(0, glassCornerRadius ?? 0)
    layer.cornerRadius = radius
    visualEffectView.layer.cornerRadius = radius
    clipsToBounds = radius > 0
    visualEffectView.clipsToBounds = radius > 0
  }

  private func ensureEffectViewLayering() {
    guard visualEffectView.superview === self else { return }
    sendSubviewToBack(visualEffectView)
  }

  private func animatePressFeedback(isPressed: Bool) {
    guard pressFeedbackEnabled else { return }
    guard #unavailable(iOS 26.0) else { return }
    guard isPressFeedbackActive != isPressed else { return }
    isPressFeedbackActive = isPressed

    let duration: TimeInterval = isPressed ? 0.1 : 0.25
    let damping: CGFloat = isPressed ? 1.0 : 0.6
    let velocity: CGFloat = isPressed ? 0.0 : 0.4

    UIView.animate(
      withDuration: duration,
      delay: 0,
      usingSpringWithDamping: damping,
      initialSpringVelocity: velocity,
      options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.visualEffectView.contentView.backgroundColor =
        isPressed
        ? self.glassPressedOverlayColor
        : .clear
    }
  }

  private func resetPressFeedbackAppearance() {
    isPressFeedbackActive = false
    if #available(iOS 26.0, *) {
      visualEffectView.contentView.backgroundColor = resolvedGlassTintColor()
    } else {
      visualEffectView.contentView.backgroundColor = .clear
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    animatePressFeedback(isPressed: true)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesMoved(touches, with: event)
    guard let touch = touches.first else { return }
    let isInside = bounds.contains(touch.location(in: self))
    animatePressFeedback(isPressed: isInside)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    animatePressFeedback(isPressed: false)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    animatePressFeedback(isPressed: false)
  }

  private func resolvedGlassTintColor() -> UIColor? {
    if let explicitTint = glassTintColor {
      return explicitTint
    }

    guard #available(iOS 26.0, *) else {
      return nil
    }
    guard let tint = glassTint, !tint.isEmpty else {
      // No explicit tint -> keep native system material appearance.
      return nil
    }

    let isDarkMode = traitCollection.userInterfaceStyle == .dark
    let styleMultiplier: CGFloat = glassStyle == "regular" ? 1.3 : 1.0
    let scaledAlpha: (CGFloat) -> CGFloat = { base in
      min(0.28, max(0.02, base * styleMultiplier))
    }

    switch tint {
    case "dark":
      return UIColor.black.withAlphaComponent(scaledAlpha(isDarkMode ? 0.16 : 0.14))
    case "light":
      return UIColor.white.withAlphaComponent(scaledAlpha(isDarkMode ? 0.08 : 0.1))
    case "extraLight":
      return UIColor.white.withAlphaComponent(scaledAlpha(isDarkMode ? 0.12 : 0.14))
    case "prominent":
      return isDarkMode
        ? UIColor.white.withAlphaComponent(scaledAlpha(0.16))
        : UIColor.black.withAlphaComponent(scaledAlpha(0.12))
    case "regular":
      return isDarkMode
        ? UIColor.white.withAlphaComponent(scaledAlpha(0.095))
        : UIColor.black.withAlphaComponent(scaledAlpha(0.08))
    case "default":
      return isDarkMode
        ? UIColor.white.withAlphaComponent(scaledAlpha(0.085))
        : UIColor.black.withAlphaComponent(scaledAlpha(0.07))
    default:
      return nil
    }
  }

  func setBlurIntensity(_ intensity: Double) {
    if #available(iOS 26.0, *) {
      return
    }

    let style: UIBlurEffect.Style

    // Map intensity (0-100) to appropriate UIBlurEffectStyles
    if intensity <= 0 {
      currentBlurStyle = nil
      visualEffectView.effect = nil
      return
    }

    if intensity < 8 {
      style = .systemUltraThinMaterial
    } else if intensity < 15 {
      style = .systemThinMaterial
    } else if intensity < 25 {
      style = .systemMaterial
    } else if intensity < 40 {
      style = .systemThickMaterial
    } else {
      style = .systemChromeMaterial  // Strongest standard material
    }
    applyBlurStyle(style)
  }

  func setInteractive(_ interactive: Bool?) {
    let resolvedInteractive = interactive ?? true
    glassInteractive = resolvedInteractive
    if !resolvedInteractive {
      resetPressFeedbackAppearance()
    }
    applyCurrentEffect()
  }

  func setPressFeedbackEnabled(_ enabled: Bool?) {
    pressFeedbackEnabled = enabled ?? false
    if !pressFeedbackEnabled {
      resetPressFeedbackAppearance()
    }
  }

  func setEffect(_ effect: String?) {
    glassStyle = effect == "clear" ? "clear" : "regular"
    applyCurrentEffect()
  }

  func setTintColor(_ tintColor: UIColor?) {
    glassTintColor = tintColor
    applyCurrentEffect()
  }

  func setTint(_ tint: String?) {
    glassTint = tint
    if #available(iOS 26.0, *) {
      applyCurrentEffect()
      return
    }

    guard let tint = tint else { return }

    switch tint {
    case "dark":
      applyBlurStyle(.systemThinMaterialDark)
    case "light":
      applyBlurStyle(.systemThinMaterialLight)
    case "extraLight":
      // Fallback or specific mapping
      if currentBlurStyle == .systemUltraThinMaterial {
        // No direct "SystemUltraThinMaterialLight", but light can often imply just light mode
        // We might rely on system behavior or force light interface style if needed
        // For now, let's map explicit tints to the available styles
        applyBlurStyle(.systemChromeMaterialLight)
      } else {
        applyBlurStyle(.light)
      }
    case "default":
      // Reset to adaptive
      applyBlurStyle(.systemThinMaterial)
    default:
      break
    }
  }

  func setCornerRadius(_ cornerRadius: Double?) {
    if let cornerRadius, cornerRadius > 0 {
      glassCornerRadius = CGFloat(cornerRadius)
    } else {
      glassCornerRadius = nil
    }
    applyCornerStyling()
  }
}

public class LiquidGlassModule: Module {
  public func definition() -> ModuleDefinition {
    Name("LiquidGlass")

    View(LiquidGlassView.self) {
      Prop("blurIntensity") { (view: LiquidGlassView, intensity: Double) in
        view.setBlurIntensity(intensity)
      }

      Prop("tint") { (view: LiquidGlassView, tint: String?) in
        view.setTint(tint)
      }

      Prop("interactive") { (view: LiquidGlassView, interactive: Bool?) in
        view.setInteractive(interactive)
      }

      Prop("pressFeedbackEnabled") { (view: LiquidGlassView, enabled: Bool?) in
        view.setPressFeedbackEnabled(enabled)
      }

      Prop("effect") { (view: LiquidGlassView, effect: String?) in
        view.setEffect(effect)
      }

      Prop("tintColor") { (view: LiquidGlassView, tintColor: UIColor?) in
        view.setTintColor(tintColor)
      }

      Prop("cornerRadius") { (view: LiquidGlassView, cornerRadius: Double?) in
        view.setCornerRadius(cornerRadius)
      }
    }
  }
}
