import CoreImage
import MetalKit
import UIKit

final class WelcomeViewController: UIViewController {
  private let backgroundView = WelcomeMetalBackgroundView()
  private let heroStack = UIStackView()
  private let eyebrowLabel = UILabel()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let detailsLabel = UILabel()
  private let footerContainerView = UIView()
  private let buttonStack = UIStackView()
  private let signUpButton = UIButton(type: .system)
  private let signInButton = UIButton(type: .system)
  private var footerButtonsBottomConstraint: NSLayoutConstraint?

  override var preferredStatusBarStyle: UIStatusBarStyle {
    palette.prefersDarkStatusBar ? .darkContent : .lightContent
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureView()
    applyPalette()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: false)
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    footerButtonsBottomConstraint?.constant = -(view.safeAreaInsets.bottom + 24)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true
    else {
      return
    }

    applyPalette()
    backgroundView.refreshAppearance()
    setNeedsStatusBarAppearanceUpdate()
  }

  private var palette: WelcomePalette {
    WelcomePalette(traits: traitCollection)
  }

  private func configureView() {
    view.backgroundColor = .systemBackground

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(backgroundView)

    heroStack.translatesAutoresizingMaskIntoConstraints = false
    heroStack.axis = .vertical
    heroStack.alignment = .leading
    heroStack.spacing = 10

    eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false
    eyebrowLabel.text = "Private by default"
    eyebrowLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    eyebrowLabel.textAlignment = .left

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.text = "Vibe"
    titleLabel.textAlignment = .left
    titleLabel.font = .systemFont(ofSize: 60, weight: .black)

    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.text = "Private chat, lit with focus."
    subtitleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
    subtitleLabel.numberOfLines = 0

    detailsLabel.translatesAutoresizingMaskIntoConstraints = false
    detailsLabel.text = "Return with your secret key or start a new identity."
    detailsLabel.font = .systemFont(ofSize: 17, weight: .medium)
    detailsLabel.numberOfLines = 0
    detailsLabel.lineBreakMode = .byWordWrapping
    detailsLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    heroStack.addArrangedSubview(eyebrowLabel)
    heroStack.addArrangedSubview(titleLabel)
    heroStack.addArrangedSubview(subtitleLabel)
    heroStack.addArrangedSubview(detailsLabel)

    footerContainerView.translatesAutoresizingMaskIntoConstraints = false
    footerContainerView.clipsToBounds = true
    footerContainerView.layer.cornerRadius = 34
    footerContainerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

    signUpButton.translatesAutoresizingMaskIntoConstraints = false
    signUpButton.addTarget(self, action: #selector(handleSignUp), for: .touchUpInside)

    signInButton.translatesAutoresizingMaskIntoConstraints = false
    signInButton.addTarget(self, action: #selector(handleSignIn), for: .touchUpInside)

    buttonStack.translatesAutoresizingMaskIntoConstraints = false
    buttonStack.axis = .vertical
    buttonStack.spacing = 12
    buttonStack.addArrangedSubview(signUpButton)
    buttonStack.addArrangedSubview(signInButton)

    footerContainerView.addSubview(buttonStack)

    view.addSubview(heroStack)
    view.addSubview(footerContainerView)

    footerButtonsBottomConstraint = buttonStack.bottomAnchor.constraint(
      equalTo: footerContainerView.bottomAnchor,
      constant: -(view.safeAreaInsets.bottom + 24)
    )

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      heroStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
      heroStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
      heroStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 54),
      heroStack.bottomAnchor.constraint(lessThanOrEqualTo: footerContainerView.topAnchor, constant: -40),

      footerContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footerContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footerContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      buttonStack.leadingAnchor.constraint(
        equalTo: footerContainerView.leadingAnchor,
        constant: 24
      ),
      buttonStack.trailingAnchor.constraint(
        equalTo: footerContainerView.trailingAnchor,
        constant: -24
      ),
      buttonStack.topAnchor.constraint(equalTo: footerContainerView.topAnchor, constant: 22),
      footerButtonsBottomConstraint!,
      signUpButton.heightAnchor.constraint(equalToConstant: 56),
      signInButton.heightAnchor.constraint(equalToConstant: 56),
    ])
  }

  private func applyPalette() {
    let palette = palette
    view.backgroundColor = palette.backgroundColor

    eyebrowLabel.textColor = palette.eyebrowTextColor
    titleLabel.textColor = palette.primaryTextColor
    subtitleLabel.textColor = palette.primaryTextColor
    detailsLabel.textColor = palette.secondaryTextColor

    footerContainerView.backgroundColor = .clear
    footerContainerView.layer.borderWidth = 0
    footerContainerView.layer.borderColor = nil

    var primary = UIButton.Configuration.filled()
    primary.title = "Create Account"
    primary.cornerStyle = .capsule
    primary.baseBackgroundColor = palette.primaryButtonBackgroundColor
    primary.baseForegroundColor = palette.primaryButtonForegroundColor
    primary.background.strokeColor = palette.primaryButtonStrokeColor
    primary.background.strokeWidth = 1
    signUpButton.configuration = primary

    var secondary = UIButton.Configuration.filled()
    secondary.title = "Sign In"
    secondary.cornerStyle = .capsule
    secondary.baseBackgroundColor = palette.secondaryButtonBackgroundColor
    secondary.baseForegroundColor = palette.secondaryButtonForegroundColor
    secondary.background.strokeColor = palette.secondaryButtonStrokeColor
    secondary.background.strokeWidth = 1
    signInButton.configuration = secondary
  }

  @objc private func handleSignIn() {
    presentAuth(mode: .signIn)
  }

  @objc private func handleSignUp() {
    presentAuth(mode: .signUp)
  }

  private func presentAuth(mode: AuthViewController.Mode) {
    AuthViewController.present(from: self, mode: mode) { [weak self] in
      self?.navigationController?.setNavigationBarHidden(false, animated: false)
      self?.navigationController?.setViewControllers([ChatHomeViewController()], animated: true)
    }
  }
}

private final class WelcomeMetalBackgroundView: UIView, MTKViewDelegate {
  private let mtkView: MTKView?
  private let fallbackLayer = CAGradientLayer()
  private var ciContext: CIContext?
  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  private let startedAt = CACurrentMediaTime()

  override class var layerClass: AnyClass {
    CAGradientLayer.self
  }

  override init(frame: CGRect) {
    if let device = MTLCreateSystemDefaultDevice() {
      let metalView = MTKView(frame: .zero, device: device)
      metalView.isPaused = false
      metalView.enableSetNeedsDisplay = false
      metalView.framebufferOnly = false
      metalView.preferredFramesPerSecond = 24
      metalView.clearColor = MTLClearColorMake(0.03, 0.05, 0.1, 1)
      metalView.autoResizeDrawable = true
      metalView.colorPixelFormat = .bgra8Unorm
      mtkView = metalView
      ciContext = CIContext(mtlDevice: device)
    } else {
      mtkView = nil
    }
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    fallbackLayer.frame = bounds
    mtkView?.frame = bounds
  }

  private func configure() {
    fallbackLayer.startPoint = CGPoint(x: 0.08, y: 0.0)
    fallbackLayer.endPoint = CGPoint(x: 0.95, y: 1.0)
    layer.addSublayer(fallbackLayer)

    if let mtkView {
      mtkView.delegate = self
      mtkView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(mtkView)
      sendSubviewToBack(mtkView)
    }

    refreshAppearance()
  }

  func refreshAppearance() {
    let palette = WelcomeMetalPalette(style: traitCollection.userInterfaceStyle)
    fallbackLayer.colors = palette.fallbackColors
    mtkView?.clearColor = palette.clearColor
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
      let ciContext,
      view.drawableSize.width > 0,
      view.drawableSize.height > 0
    else {
      return
    }

    let size = CGSize(width: view.drawableSize.width, height: view.drawableSize.height)
    let bounds = CGRect(origin: .zero, size: size)
    let time = CGFloat(CACurrentMediaTime() - startedAt)
    let palette = WelcomeMetalPalette(style: traitCollection.userInterfaceStyle)

    let base = linearGradient(
      startPoint: CGPoint(x: size.width * 0.14, y: 0),
      endPoint: CGPoint(x: size.width * 0.94, y: size.height),
      startColor: palette.baseTopColor,
      endColor: palette.baseBottomColor
    )
    let source = radialGlow(
      center: CGPoint(
        x: size.width * (0.94 + 0.01 * sin(time * 0.21)),
        y: size.height * (0.06 + 0.01 * cos(time * 0.17))
      ),
      radius: max(size.width, size.height) * 0.24,
      color: palette.sourceGlowColor
    )
    let beamMid = radialGlow(
      center: CGPoint(
        x: size.width * (0.72 + 0.02 * cos(time * 0.19)),
        y: size.height * (0.14 + 0.014 * sin(time * 0.16))
      ),
      radius: max(size.width, size.height) * 0.34,
      color: palette.beamGlowColor
    )
    let beamNearText = radialGlow(
      center: CGPoint(
        x: size.width * (0.44 + 0.02 * sin(time * 0.15)),
        y: size.height * (0.20 + 0.014 * cos(time * 0.11))
      ),
      radius: max(size.width, size.height) * 0.22,
      color: palette.textGlowColor
    )
    let warmLift = radialGlow(
      center: CGPoint(
        x: size.width * (0.26 + 0.03 * sin(time * 0.08)),
        y: size.height * (0.36 + 0.02 * cos(time * 0.07))
      ),
      radius: max(size.width, size.height) * 0.54,
      color: palette.secondaryAmbientGlowColor
    )
    let ambient = radialGlow(
      center: CGPoint(
        x: size.width * (0.56 + 0.03 * cos(time * 0.09)),
        y: size.height * (0.78 + 0.03 * sin(time * 0.13))
      ),
      radius: max(size.width, size.height) * 0.82,
      color: palette.ambientGlowColor
    )

    let image = beamNearText
      .composited(over: beamMid)
      .composited(over: source)
      .composited(over: warmLift)
      .composited(over: ambient)
      .composited(over: base)
      .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 20.0])
      .cropped(to: bounds)

    ciContext.render(image, to: drawable.texture, commandBuffer: nil, bounds: bounds, colorSpace: colorSpace)
    drawable.present()
  }

  private func radialGlow(center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage {
    let transparent = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
    return CIFilter(
      name: "CIRadialGradient",
      parameters: [
        "inputCenter": CIVector(cgPoint: center),
        "inputRadius0": radius * 0.12,
        "inputRadius1": radius,
        "inputColor0": color,
        "inputColor1": transparent,
      ]
    )?.outputImage ?? CIImage.empty()
  }

  private func linearGradient(
    startPoint: CGPoint,
    endPoint: CGPoint,
    startColor: CIColor,
    endColor: CIColor
  ) -> CIImage {
    CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": CIVector(cgPoint: startPoint),
        "inputPoint1": CIVector(cgPoint: endPoint),
        "inputColor0": startColor,
        "inputColor1": endColor,
      ]
    )?.outputImage ?? CIImage.empty()
  }
}

private struct WelcomePalette {
  let prefersDarkStatusBar: Bool
  let backgroundColor: UIColor
  let eyebrowTextColor: UIColor
  let primaryTextColor: UIColor
  let secondaryTextColor: UIColor
  let footerTintColor: UIColor
  let footerBorderColor: UIColor
  let primaryButtonBackgroundColor: UIColor
  let primaryButtonForegroundColor: UIColor
  let primaryButtonStrokeColor: UIColor
  let secondaryButtonBackgroundColor: UIColor
  let secondaryButtonForegroundColor: UIColor
  let secondaryButtonStrokeColor: UIColor

  init(traits: UITraitCollection) {
    let isDark = traits.userInterfaceStyle == .dark
    prefersDarkStatusBar = !isDark
    backgroundColor = isDark
      ? UIColor(red: 0.15, green: 0.13, blue: 0.12, alpha: 1)
      : UIColor(red: 0.97, green: 0.95, blue: 0.93, alpha: 1)
    eyebrowTextColor = isDark
      ? UIColor(red: 0.97, green: 0.94, blue: 0.91, alpha: 0.78)
      : UIColor(red: 0.37, green: 0.31, blue: 0.29, alpha: 0.78)
    primaryTextColor = isDark
      ? UIColor(red: 0.99, green: 0.96, blue: 0.92, alpha: 1)
      : UIColor(red: 0.17, green: 0.14, blue: 0.13, alpha: 1)
    secondaryTextColor = isDark
      ? UIColor(red: 0.88, green: 0.82, blue: 0.76, alpha: 0.82)
      : UIColor(red: 0.39, green: 0.32, blue: 0.29, alpha: 0.76)
    footerTintColor = isDark
      ? UIColor(red: 0.26, green: 0.21, blue: 0.19, alpha: 0.62)
      : UIColor(red: 0.98, green: 0.96, blue: 0.94, alpha: 0.66)
    footerBorderColor = isDark
      ? UIColor.white.withAlphaComponent(0.14)
      : UIColor.white.withAlphaComponent(0.72)
    primaryButtonBackgroundColor = isDark
      ? UIColor(red: 0.97, green: 0.96, blue: 0.95, alpha: 0.94)
      : UIColor(red: 0.11, green: 0.10, blue: 0.11, alpha: 0.96)
    primaryButtonForegroundColor = isDark
      ? UIColor(red: 0.13, green: 0.11, blue: 0.10, alpha: 1)
      : UIColor.white
    primaryButtonStrokeColor = isDark
      ? UIColor.white.withAlphaComponent(0.18)
      : UIColor.white.withAlphaComponent(0.28)
    secondaryButtonBackgroundColor = isDark
      ? UIColor.white.withAlphaComponent(0.12)
      : UIColor.white.withAlphaComponent(0.58)
    secondaryButtonForegroundColor = primaryTextColor
    secondaryButtonStrokeColor = isDark
      ? UIColor(red: 0.79, green: 0.72, blue: 0.66, alpha: 0.34)
      : UIColor(red: 0.83, green: 0.77, blue: 0.72, alpha: 0.92)
  }
}

private struct WelcomeMetalPalette {
  let fallbackColors: [CGColor]
  let clearColor: MTLClearColor
  let baseTopColor: CIColor
  let baseBottomColor: CIColor
  let sourceGlowColor: CIColor
  let beamGlowColor: CIColor
  let textGlowColor: CIColor
  let ambientGlowColor: CIColor
  let secondaryAmbientGlowColor: CIColor

  init(style: UIUserInterfaceStyle) {
    let isDark = style != .light
    if isDark {
      fallbackColors = [
        UIColor(red: 0.16, green: 0.14, blue: 0.13, alpha: 1).cgColor,
        UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1).cgColor,
        UIColor(red: 0.09, green: 0.08, blue: 0.08, alpha: 1).cgColor,
      ]
      clearColor = MTLClearColorMake(0.16, 0.14, 0.13, 1)
      baseTopColor = CIColor(red: 0.14, green: 0.13, blue: 0.12, alpha: 1)
      baseBottomColor = CIColor(red: 0.10, green: 0.09, blue: 0.09, alpha: 1)
      sourceGlowColor = CIColor(red: 0.98, green: 0.85, blue: 0.67, alpha: 0.92)
      beamGlowColor = CIColor(red: 0.99, green: 0.95, blue: 0.89, alpha: 0.42)
      textGlowColor = CIColor(red: 0.98, green: 0.92, blue: 0.84, alpha: 0.34)
      ambientGlowColor = CIColor(red: 0.46, green: 0.34, blue: 0.31, alpha: 0.28)
      secondaryAmbientGlowColor = CIColor(red: 0.64, green: 0.50, blue: 0.42, alpha: 0.34)
    } else {
      fallbackColors = [
        UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor,
        UIColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 1).cgColor,
        UIColor(red: 0.89, green: 0.84, blue: 0.80, alpha: 1).cgColor,
      ]
      clearColor = MTLClearColorMake(0.98, 0.97, 0.95, 1)
      baseTopColor = CIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
      baseBottomColor = CIColor(red: 0.91, green: 0.88, blue: 0.84, alpha: 1)
      sourceGlowColor = CIColor(red: 0.92, green: 0.75, blue: 0.58, alpha: 0.58)
      beamGlowColor = CIColor(red: 0.94, green: 0.87, blue: 0.81, alpha: 0.32)
      textGlowColor = CIColor(red: 0.99, green: 0.97, blue: 0.93, alpha: 0.26)
      ambientGlowColor = CIColor(red: 0.86, green: 0.76, blue: 0.70, alpha: 0.28)
      secondaryAmbientGlowColor = CIColor(red: 0.83, green: 0.67, blue: 0.56, alpha: 0.32)
    }
  }
}
