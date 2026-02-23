import Foundation
import UIKit

final class VibeNativeCallUiCoordinator {
  static let shared = VibeNativeCallUiCoordinator()

  private weak var module: VibeNativeCallModule?
  private var overlayWindow: UIWindow?
  private weak var controller: VibeNativeCallScreenController?
  private var state: [String: Any] = [:]

  private init() {}

  func attach(module: VibeNativeCallModule) {
    NSLog("[VibeNativeCall][UiCoord] attach module")
    self.module = module
  }

  func detach(module: VibeNativeCallModule) {
    if self.module === module {
      NSLog("[VibeNativeCall][UiCoord] detach module")
      self.module = nil
    }
  }

  func setState(_ payload: [String: Any]) {
    let mode = (payload["mode"] as? String) ?? "hidden"
    let visible = (payload["visible"] as? Bool) ?? (mode != "hidden")
    let callId = (payload["callId"] as? String) ?? (payload["call_id"] as? String) ?? "-"
    let status = (payload["callStatus"] as? String) ?? "-"
    NSLog(
      "[VibeNativeCall][UiCoord] setState mode=%@ visible=%@ callId=%@ status=%@",
      mode, visible ? "true" : "false", callId, status
    )
    state = payload
    DispatchQueue.main.async {
      self.applyStateOnMain(payload)
    }
  }

  func hide() {
    DispatchQueue.main.async {
      NSLog(
        "[VibeNativeCall][UiCoord] hide hasWindow=%@ hasController=%@",
        self.overlayWindow != nil ? "true" : "false",
        self.controller != nil ? "true" : "false"
      )
      self.overlayWindow?.rootViewController = nil
      self.overlayWindow?.isHidden = true
      self.overlayWindow = nil
      self.controller = nil
    }
  }

  func emitEvent(_ type: String, extra: [String: Any] = [:]) {
    NSLog("[VibeNativeCall][UiCoord] emitEvent type=%@", type)
    var payload = extra
    payload["type"] = type
    module?.emitCallUiEvent(payload)
  }

  private func applyStateOnMain(_ payload: [String: Any]) {
    let visible =
      (payload["visible"] as? Bool) ?? (((payload["mode"] as? String) ?? "hidden") != "hidden")
    guard visible else {
      NSLog("[VibeNativeCall][UiCoord] applyState hidden -> hide()")
      hide()
      return
    }

    // In-app native call pages are only for foreground runtime.
    // Background/closed call UI should remain OS-native (CallKit / notifications).
    if UIApplication.shared.applicationState != .active {
      NSLog(
        "[VibeNativeCall][UiCoord] applyState appState=%ld -> hide()",
        UIApplication.shared.applicationState.rawValue
      )
      hide()
      return
    }

    let controller = ensureController()
    NSLog("[VibeNativeCall][UiCoord] applyState forwardingToController")
    controller.applyState(payload)
  }

  private func ensureController() -> VibeNativeCallScreenController {
    if let controller {
      NSLog("[VibeNativeCall][UiCoord] ensureController reuse")
      return controller
    }

    let windowScene =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

    let window: UIWindow
    if let windowScene {
      window = UIWindow(windowScene: windowScene)
    } else {
      window = UIWindow(frame: UIScreen.main.bounds)
    }
    window.windowLevel = .alert + 1
    let root = VibeNativeCallScreenController(coordinator: self)
    NSLog(
      "[VibeNativeCall][UiCoord] ensureController create scene=%@",
      windowScene != nil ? "windowScene" : "screenBounds"
    )
    window.rootViewController = root
    window.isHidden = false
    window.makeKeyAndVisible()
    overlayWindow = window
    controller = root
    return root
  }
}

final class VibeNativeCallScreenController: UIViewController {
  private weak var coordinator: VibeNativeCallUiCoordinator?
  private var currentState: [String: Any] = [:]

  private let rootStack = UIStackView()
  private let chipLabel = UILabel()
  private let avatarView = UIView()
  private let initialsLabel = UILabel()
  private let nameLabel = UILabel()
  private let statusLabel = UILabel()
  private let spacer = UIView()
  private let utilityRow = UIStackView()
  private let incomingRow = UIStackView()
  private let activeBar = UIView()
  private let activeBarEffect = UIVisualEffectView()
  private let activeRow = UIStackView()

  private var buttons: [String: UIButton] = [:]
  private var buttonLabels: [String: UILabel] = [:]

  init(coordinator: VibeNativeCallUiCoordinator) {
    self.coordinator = coordinator
    super.init(nibName: nil, bundle: nil)
    modalPresentationCapturesStatusBarAppearance = true
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    NSLog("[VibeNativeCall][UiScreen] viewDidLoad")
    setupUi()
  }

  func applyState(_ state: [String: Any]) {
    let mode = (state["mode"] as? String) ?? "hidden"
    let callId = (state["callId"] as? String) ?? (state["call_id"] as? String) ?? "-"
    let status = (state["callStatus"] as? String) ?? "-"
    NSLog("[VibeNativeCall][UiScreen] applyState mode=%@ callId=%@ status=%@", mode, callId, status)
    currentState = state
    let isDark = (state["isDark"] as? Bool) ?? true
    let palette = isDark ? Palette.dark : .light
    view.backgroundColor = palette.background

    let callType = (state["callType"] as? String) ?? "voice"
    chipLabel.text =
      mode == "incoming"
      ? (callType == "video" ? "Incoming video call" : "Incoming voice call")
      : (callType == "video" ? "Vibe Video" : "Vibe Audio")
    chipLabel.textColor = palette.textSubtle
    chipLabel.backgroundColor = palette.surfaceSoft

    let remoteName =
      ((state["remoteUserName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
      .flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown"
    nameLabel.text = remoteName
    initialsLabel.text = String(remoteName.prefix(1)).uppercased()
    nameLabel.textColor = palette.text
    statusLabel.textColor = palette.textSubtle
    initialsLabel.textColor = palette.text
    avatarView.backgroundColor = palette.avatarBg

    statusLabel.text =
      mode == "incoming"
      ? "Tap accept to answer"
      : activeStatus(from: state)

    utilityRow.isHidden = mode != "incoming"
    incomingRow.isHidden = mode != "incoming"
    activeBar.isHidden = mode != "active"

    let isMuted = (state["isMuted"] as? Bool) ?? false
    let isSpeaker = (state["isSpeakerOn"] as? Bool) ?? false
    let isVideo = (state["isVideoEnabled"] as? Bool) ?? false

    styleButton("incomingDecline", bg: palette.danger, symbol: "phone.down.fill", fg: .white)
    styleButton(
      "incomingAccept", bg: UIColor(red: 0.17, green: 0.44, blue: 1, alpha: 1),
      symbol: "phone.fill", fg: .white)
    styleButton("msg", bg: palette.controlBg, symbol: "message.fill", fg: palette.text)
    styleButton("remind", bg: palette.controlBg, symbol: "bell.fill", fg: palette.text)
    styleButton("end", bg: palette.danger, symbol: "phone.down.fill", fg: .white)

    styleToggle(
      "mute", active: isMuted, symbol: isMuted ? "mic.slash.fill" : "mic.fill", palette: palette)
    styleToggle("speaker", active: isSpeaker, symbol: "speaker.wave.3.fill", palette: palette)
    styleToggle(
      "video", active: isVideo, symbol: isVideo ? "video.fill" : "video.slash.fill",
      palette: palette)
    styleButton(
      "flip", bg: palette.controlBg, symbol: "arrow.triangle.2.circlepath.camera.fill",
      fg: palette.text)

    buttons["flip"]?.superview?.superview?.isHidden =
      !(((state["canFlipCamera"] as? Bool) ?? false) && isVideo)

    activeBar.backgroundColor = palette.controlBarBg
  }

  private func activeStatus(from state: [String: Any]) -> String {
    let status = (state["callStatus"] as? String) ?? "active"
    switch status {
    case "connecting": return "Connecting..."
    case "reconnecting": return "Reconnecting..."
    case "ringing": return "Ringing..."
    case "active":
      let total = (state["callDuration"] as? NSNumber)?.intValue ?? 0
      return "\(total / 60):" + String(format: "%02d", total % 60)
    default:
      return status.capitalized
    }
  }

  private func setupUi() {
    view.isOpaque = true
    view.addSubview(rootStack)
    rootStack.axis = .vertical
    rootStack.alignment = .center
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    rootStack.spacing = 12

    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
      rootStack.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])

    chipLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    chipLabel.textAlignment = .center
    chipLabel.layer.cornerRadius = 18
    chipLabel.layer.masksToBounds = true
    chipLabel.layer.borderWidth = 1
    chipLabel.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    chipLabel.layoutMargins = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    chipLabel.translatesAutoresizingMaskIntoConstraints = false
    let chipWrap = UIView()
    chipWrap.addSubview(chipLabel)
    chipLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      chipLabel.leadingAnchor.constraint(equalTo: chipWrap.leadingAnchor),
      chipLabel.trailingAnchor.constraint(equalTo: chipWrap.trailingAnchor),
      chipLabel.topAnchor.constraint(equalTo: chipWrap.topAnchor),
      chipLabel.bottomAnchor.constraint(equalTo: chipWrap.bottomAnchor),
    ])
    rootStack.addArrangedSubview(chipWrap)

    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.layer.cornerRadius = 78
    avatarView.layer.masksToBounds = true
    NSLayoutConstraint.activate([
      avatarView.widthAnchor.constraint(equalToConstant: 156),
      avatarView.heightAnchor.constraint(equalToConstant: 156),
    ])
    initialsLabel.translatesAutoresizingMaskIntoConstraints = false
    initialsLabel.font = .systemFont(ofSize: 52, weight: .bold)
    initialsLabel.textAlignment = .center
    avatarView.addSubview(initialsLabel)
    NSLayoutConstraint.activate([
      initialsLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
      initialsLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
    ])
    let avatarSpacer = UIView()
    avatarSpacer.addSubview(avatarView)
    avatarView.centerXAnchor.constraint(equalTo: avatarSpacer.centerXAnchor).isActive = true
    avatarView.topAnchor.constraint(equalTo: avatarSpacer.topAnchor, constant: 28).isActive = true
    avatarView.bottomAnchor.constraint(equalTo: avatarSpacer.bottomAnchor).isActive = true
    rootStack.addArrangedSubview(avatarSpacer)

    nameLabel.font = .systemFont(ofSize: 30, weight: .bold)
    nameLabel.textAlignment = .center
    rootStack.addArrangedSubview(nameLabel)

    statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
    statusLabel.textAlignment = .center
    rootStack.addArrangedSubview(statusLabel)

    spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
    rootStack.addArrangedSubview(spacer)

    utilityRow.axis = .horizontal
    utilityRow.alignment = .center
    utilityRow.spacing = 14
    utilityRow.distribution = .fillEqually
    utilityRow.translatesAutoresizingMaskIntoConstraints = false
    utilityRow.addArrangedSubview(makeButtonStack(key: "msg", label: "Message", size: 52))
    utilityRow.addArrangedSubview(makeButtonStack(key: "remind", label: "Remind", size: 52))
    rootStack.addArrangedSubview(utilityRow)

    incomingRow.axis = .horizontal
    incomingRow.alignment = .center
    incomingRow.spacing = 18
    incomingRow.distribution = .fillEqually
    incomingRow.translatesAutoresizingMaskIntoConstraints = false
    incomingRow.addArrangedSubview(
      makeButtonStack(key: "incomingDecline", label: "Decline", size: 76))
    incomingRow.addArrangedSubview(
      makeButtonStack(key: "incomingAccept", label: "Accept", size: 76))
    rootStack.addArrangedSubview(incomingRow)

    // Active Bar Glass Wrapper
    activeBar.translatesAutoresizingMaskIntoConstraints = false
    activeBar.layer.cornerRadius = 32
    activeBar.layer.masksToBounds = true

    activeBarEffect.frame = activeBar.bounds
    activeBarEffect.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if #available(iOS 26.0, *) {
      activeBarEffect.effect = UIGlassEffect()
    } else {
      activeBarEffect.effect = UIBlurEffect(style: .systemUltraThinMaterial)
    }
    activeBar.addSubview(activeBarEffect)

    activeRow.axis = .horizontal
    activeRow.alignment = .center
    activeRow.spacing = 12
    activeRow.distribution = .equalSpacing
    activeRow.translatesAutoresizingMaskIntoConstraints = false
    activeBar.addSubview(activeRow)

    activeRow.addArrangedSubview(
      makeButtonStack(key: "mute", label: "Mic", size: 48, showLabel: false))
    activeRow.addArrangedSubview(
      makeButtonStack(key: "video", label: "Video", size: 48, showLabel: false))
    activeRow.addArrangedSubview(
      makeButtonStack(key: "flip", label: "Flip", size: 48, showLabel: false))
    activeRow.addArrangedSubview(
      makeButtonStack(key: "speaker", label: "Audio", size: 48, showLabel: false))
    activeRow.addArrangedSubview(
      makeButtonStack(key: "end", label: "End", size: 56, showLabel: false))

    NSLayoutConstraint.activate([
      activeRow.leadingAnchor.constraint(equalTo: activeBar.leadingAnchor, constant: 16),
      activeRow.trailingAnchor.constraint(equalTo: activeBar.trailingAnchor, constant: -16),
      activeRow.topAnchor.constraint(equalTo: activeBar.topAnchor, constant: 8),
      activeRow.bottomAnchor.constraint(equalTo: activeBar.bottomAnchor, constant: -8),
      activeBar.heightAnchor.constraint(equalToConstant: 64),
    ])

    rootStack.addArrangedSubview(activeBar)
  }

  private func makeButtonStack(key: String, label: String, size: CGFloat, showLabel: Bool = true)
    -> UIView
  {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 5

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      container.widthAnchor.constraint(equalToConstant: size),
      container.heightAnchor.constraint(equalToConstant: size),
    ])

    let glass = UIVisualEffectView()
    glass.translatesAutoresizingMaskIntoConstraints = false
    glass.layer.cornerRadius = size / 2
    glass.layer.masksToBounds = true
    if #available(iOS 26.0, *) {
      glass.effect = UIGlassEffect()
    } else {
      glass.effect = UIBlurEffect(style: .systemUltraThinMaterial)
    }
    container.addSubview(glass)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      glass.topAnchor.constraint(equalTo: container.topAnchor),
      glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.layer.cornerRadius = size / 2
    button.layer.masksToBounds = true
    button.addTarget(self, action: #selector(onButtonTap(_:)), for: .touchUpInside)
    button.accessibilityIdentifier = key
    container.addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      button.topAnchor.constraint(equalTo: container.topAnchor),
      button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    stack.addArrangedSubview(container)

    if showLabel {
      let labelView = UILabel()
      labelView.text = label
      labelView.font = .systemFont(ofSize: 10, weight: .semibold)
      labelView.textAlignment = .center
      stack.addArrangedSubview(labelView)
      buttonLabels[key] = labelView
    }

    buttons[key] = button
    return stack
  }

  @objc private func onButtonTap(_ sender: UIButton) {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.prepare()
    generator.impactOccurred()

    guard let key = sender.accessibilityIdentifier else { return }
    let event: String
    switch key {
    case "incomingAccept": event = "accept"
    case "incomingDecline": event = "decline"
    case "msg": event = "message"
    case "remind": event = "remind"
    case "mute": event = "toggleMute"
    case "speaker": event = "toggleSpeaker"
    case "video": event = "toggleVideo"
    case "flip": event = "flipCamera"
    case "end": event = "end"
    default: event = "noop"
    }
    NSLog("[VibeNativeCall][UiScreen] buttonTap key=%@ event=%@", key, event)
    coordinator?.emitEvent(event)
  }

  private func styleToggle(_ key: String, active: Bool, symbol: String, palette: Palette) {
    styleButton(
      key, bg: active ? palette.controlActiveBg : palette.controlBg, symbol: symbol,
      fg: active ? palette.background : palette.text)
  }

  private func styleButton(_ key: String, bg: UIColor, symbol: String, fg: UIColor) {
    guard let button = buttons[key] else { return }
    button.backgroundColor = bg
    button.tintColor = fg

    let config = UIImage.SymbolConfiguration(weight: .semibold)
    button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)

    buttonLabels[key]?.textColor = palette(for: currentState).textSubtle
  }

  private func palette(for state: [String: Any]) -> Palette {
    let isDark = (state["isDark"] as? Bool) ?? true
    return isDark ? .dark : .light
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    let isDark = (currentState["isDark"] as? Bool) ?? true
    return isDark ? .lightContent : .darkContent
  }
}

private struct Palette {
  let background: UIColor
  let text: UIColor
  let textSubtle: UIColor
  let textDim: UIColor
  let surfaceSoft: UIColor
  let avatarBg: UIColor
  let avatarRing: UIColor
  let controlBg: UIColor
  let controlActiveBg: UIColor
  let controlBarBg: UIColor
  let danger: UIColor

  static let dark = Palette(
    background: UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1),
    text: .white,
    textSubtle: UIColor.white.withAlphaComponent(0.66),
    textDim: UIColor.white.withAlphaComponent(0.82),
    surfaceSoft: UIColor.white.withAlphaComponent(0.1),
    avatarBg: UIColor(red: 0.17, green: 0.44, blue: 1, alpha: 0.28),
    avatarRing: UIColor.white.withAlphaComponent(0.18),
    controlBg: UIColor.white.withAlphaComponent(0.16),
    controlActiveBg: UIColor.white.withAlphaComponent(0.9),
    controlBarBg: UIColor.black.withAlphaComponent(0.48),
    danger: UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 0.9)
  )

  static let light = Palette(
    background: UIColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1),
    text: .black,
    textSubtle: UIColor.black.withAlphaComponent(0.58),
    textDim: UIColor.black.withAlphaComponent(0.72),
    surfaceSoft: UIColor.black.withAlphaComponent(0.05),
    avatarBg: UIColor(red: 0.17, green: 0.44, blue: 1, alpha: 0.18),
    avatarRing: UIColor.black.withAlphaComponent(0.1),
    controlBg: UIColor.black.withAlphaComponent(0.12),
    controlActiveBg: UIColor.black.withAlphaComponent(0.82),
    controlBarBg: UIColor.white.withAlphaComponent(0.36),
    danger: UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 0.9)
  )
}
