import SwiftUI
import UIKit

enum AppAppearanceOption: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return "System"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }

  var interfaceStyle: UIUserInterfaceStyle {
    switch self {
    case .system:
      return .unspecified
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }
}

enum AppAppearanceController {
  static let storageKey = "vibe.app.appearance"

  static var currentOption: AppAppearanceOption {
    let rawValue =
      UserDefaults.standard.string(forKey: storageKey)
      ?? AppAppearanceOption.system.rawValue
    return AppAppearanceOption(rawValue: rawValue) ?? .system
  }

  static func setOption(_ option: AppAppearanceOption) {
    UserDefaults.standard.set(option.rawValue, forKey: storageKey)
    applyStoredPreference()
  }

  static func applyStoredPreference(to window: UIWindow? = nil) {
    let style = currentOption.interfaceStyle

    if let window {
      window.overrideUserInterfaceStyle = style
    }

    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for sceneWindow in windowScene.windows {
        sceneWindow.overrideUserInterfaceStyle = style
      }
    }
  }
}

enum AppPrivacyChoice: String, CaseIterable, Identifiable {
  case everybody
  case contacts
  case nobody

  var id: String { rawValue }

  var title: String {
    switch self {
    case .everybody:
      return "Everybody"
    case .contacts:
      return "My Contacts"
    case .nobody:
      return "Nobody"
    }
  }
}

enum AppThemePlateOption: String, CaseIterable, Identifiable {
  case glacier
  case zen
  case ocean
  case obsidian

  var id: String { rawValue }

  var title: String {
    switch self {
    case .glacier:
      return "Glacier"
    case .zen:
      return "Zen"
    case .ocean:
      return "Ocean"
    case .obsidian:
      return "Obsidian"
    }
  }
}

enum AppThemePlateController {
  static let storageKey = "vibe.app.themePlate"

  static var currentOption: AppThemePlateOption {
    let rawValue =
      UserDefaults.standard.string(forKey: storageKey)
      ?? AppThemePlateOption.glacier.rawValue
    return AppThemePlateOption(rawValue: rawValue) ?? .glacier
  }

  static func setOption(_ option: AppThemePlateOption) {
    UserDefaults.standard.set(option.rawValue, forKey: storageKey)
  }
}

enum AppWallpaperPresetOption: String, CaseIterable, Identifiable {
  case glacier
  case zen
  case ocean
  case obsidian
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .glacier:
      return "Glacier"
    case .zen:
      return "Zen"
    case .ocean:
      return "Ocean"
    case .obsidian:
      return "Obsidian"
    case .custom:
      return "Custom"
    }
  }

  var subtitle: String {
    switch self {
    case .glacier:
      return "Cool mist"
    case .zen:
      return "Muted plum"
    case .ocean:
      return "Soft tide"
    case .obsidian:
      return "Quiet slate"
    case .custom:
      return "Your layers"
    }
  }
}

struct AppWallpaperStyle: Equatable {
  let preset: AppWallpaperPresetOption
  let layerColors: [String]
  let gradientColors: [String]
}

enum AppWallpaperController {
  static let presetStorageKey = "vibe.app.wallpaperPreset"
  static let customColorsStorageKey = "vibe.app.wallpaperCustomColors"

  static let colorLibrary: [String] = [
    "#567D8F",
    "#5E8D88",
    "#708F74",
    "#7D9768",
    "#8F8D74",
    "#9B8468",
    "#9C756B",
    "#956C7D",
    "#856D96",
    "#6F78A1",
    "#6389A5",
    "#7A93B2",
    "#8A9CB5",
    "#9A9387",
    "#8A8E7A",
    "#7A858C",
    "#86908E",
    "#9B8795",
  ]

  static var currentPreset: AppWallpaperPresetOption {
    let rawValue = UserDefaults.standard.string(forKey: presetStorageKey) ?? ""
    if let preset = AppWallpaperPresetOption(rawValue: rawValue), !rawValue.isEmpty {
      return preset
    }
    return defaultPreset(for: AppThemePlateController.currentOption)
  }

  static var currentCustomColors: [String] {
    normalizedColorArray(
      UserDefaults.standard.stringArray(forKey: customColorsStorageKey),
      fallback: presetLayerColors(for: defaultPreset(for: AppThemePlateController.currentOption))
    )
  }

  static func setPreset(_ option: AppWallpaperPresetOption) {
    UserDefaults.standard.set(option.rawValue, forKey: presetStorageKey)
  }

  static func setCustomColors(_ colors: [String]) {
    UserDefaults.standard.set(
      normalizedColorArray(colors, fallback: presetLayerColors(for: .glacier)),
      forKey: customColorsStorageKey
    )
  }

  static func style(
    for preset: AppWallpaperPresetOption = currentPreset,
    isDark: Bool,
    customColors: [String]? = nil
  ) -> AppWallpaperStyle {
    let resolvedLayerColors = normalizedColorArray(
      preset == .custom ? (customColors ?? currentCustomColors) : presetLayerColors(for: preset),
      fallback: presetLayerColors(for: .glacier)
    )
    return AppWallpaperStyle(
      preset: preset,
      layerColors: resolvedLayerColors,
      gradientColors: gradientColors(for: resolvedLayerColors, isDark: isDark)
    )
  }

  static func appearancePayload(isDark: Bool) -> [String: Any] {
    let wallpaper = style(isDark: isDark)
    return [
      "theme": isDark ? "dark" : "light",
      "backgroundMode": "gradient",
      "wallpaperGradient": wallpaper.gradientColors,
      "wallpaperOpacity": 1.0,
      "wallpaperPatternGradient": [],
      "wallpaperPatternOpacity": 0.0,
    ]
  }

  static func defaultPreset(for plate: AppThemePlateOption) -> AppWallpaperPresetOption {
    switch plate {
    case .glacier:
      return .glacier
    case .zen:
      return .zen
    case .ocean:
      return .ocean
    case .obsidian:
      return .obsidian
    }
  }

  private static func presetLayerColors(for preset: AppWallpaperPresetOption) -> [String] {
    switch preset {
    case .glacier:
      return ["#5C888B", "#6F8DA1", "#8B7E9E"]
    case .zen:
      return ["#7A6F94", "#8B7890", "#9A846E"]
    case .ocean:
      return ["#5A8092", "#6C8B8E", "#7F82A3"]
    case .obsidian:
      return ["#5A6D82", "#6D7B86", "#85726E"]
    case .custom:
      return currentCustomColors
    }
  }

  private static func baseGradient(isDark: Bool) -> [UIColor] {
    if isDark {
      return [
        color(from: "#101317") ?? .black,
        color(from: "#1A1E25") ?? .black,
      ]
    }
    return [
      color(from: "#FBF8F3") ?? .white,
      color(from: "#EEE8E1") ?? .white,
    ]
  }

  private static func gradientColors(for layerColors: [String], isDark: Bool) -> [String] {
    let resolvedLayers = normalizedColorArray(
      layerColors,
      fallback: presetLayerColors(for: .glacier)
    )
    let base = baseGradient(isDark: isDark)
    let start = base[0]
    let end = base[1]
    let center = blend(start, with: end, amount: 0.5)
    let anchors = [
      blend(start, with: center, amount: 0.34),
      center,
      blend(center, with: end, amount: 0.66),
    ]
    let mixAmounts: [CGFloat] = isDark ? [0.46, 0.52, 0.48] : [0.28, 0.34, 0.30]

    let softenedLayers = zip(resolvedLayers, zip(anchors, mixAmounts)).map { hex, values in
      let (anchor, amount) = values
      let target = color(from: hex) ?? anchor
      return hexString(blend(anchor, with: target, amount: amount))
    }

    return [hexString(start)] + softenedLayers + [hexString(end)]
  }

  private static func normalizedColorArray(_ colors: [String]?, fallback: [String]) -> [String] {
    let resolved = (colors ?? [])
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
      .filter { color(from: $0) != nil }

    if resolved.count >= 3 {
      return Array(resolved.prefix(3))
    }

    var filled = resolved
    let fallbackColors = fallback.map { $0.uppercased() }
    for color in fallbackColors where filled.count < 3 {
      filled.append(color)
    }
    return Array(filled.prefix(3))
  }

  private static func color(from hex: String) -> UIColor? {
    let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
    guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else { return nil }
    return UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255.0,
      green: CGFloat((value >> 8) & 0xFF) / 255.0,
      blue: CGFloat(value & 0xFF) / 255.0,
      alpha: 1.0
    )
  }

  private static func hexString(_ color: UIColor) -> String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
      return "#000000"
    }
    return String(
      format: "#%02X%02X%02X",
      Int(round(red * 255.0)),
      Int(round(green * 255.0)),
      Int(round(blue * 255.0))
    )
  }

  private static func blend(_ from: UIColor, with to: UIColor, amount: CGFloat) -> UIColor {
    let t = max(0.0, min(1.0, amount))
    var fr: CGFloat = 0
    var fg: CGFloat = 0
    var fb: CGFloat = 0
    var fa: CGFloat = 0
    var tr: CGFloat = 0
    var tg: CGFloat = 0
    var tb: CGFloat = 0
    var ta: CGFloat = 0

    guard from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa),
      to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
    else {
      return from
    }

    let inverse = 1.0 - t
    return UIColor(
      red: (fr * inverse) + (tr * t),
      green: (fg * inverse) + (tg * t),
      blue: (fb * inverse) + (tb * t),
      alpha: (fa * inverse) + (ta * t)
    )
  }
}

struct AppThemePalette {
  let backgroundUIColor: UIColor
  let secondaryBackgroundUIColor: UIColor
  let cardUIColor: UIColor
  let inputUIColor: UIColor
  let elevatedUIColor: UIColor
  let textUIColor: UIColor
  let secondaryTextUIColor: UIColor
  let tertiaryTextUIColor: UIColor
  let accentUIColor: UIColor
  let accentMutedUIColor: UIColor
  let buttonUIColor: UIColor
  let buttonTextUIColor: UIColor
  let bubbleMeUIColor: UIColor
  let bubbleThemUIColor: UIColor
  let borderUIColor: UIColor
  let dividerUIColor: UIColor
  let overlayUIColor: UIColor
  let successUIColor: UIColor
  let warningUIColor: UIColor
  let dangerUIColor: UIColor

  var background: Color { Color(uiColor: backgroundUIColor) }
  var secondaryBackground: Color { Color(uiColor: secondaryBackgroundUIColor) }
  var card: Color { Color(uiColor: cardUIColor) }
  var input: Color { Color(uiColor: inputUIColor) }
  var elevated: Color { Color(uiColor: elevatedUIColor) }
  var text: Color { Color(uiColor: textUIColor) }
  var secondaryText: Color { Color(uiColor: secondaryTextUIColor) }
  var tertiaryText: Color { Color(uiColor: tertiaryTextUIColor) }
  var accent: Color { Color(uiColor: accentUIColor) }
  var accentMuted: Color { Color(uiColor: accentMutedUIColor) }
  var button: Color { Color(uiColor: buttonUIColor) }
  var buttonText: Color { Color(uiColor: buttonTextUIColor) }
  var bubbleMe: Color { Color(uiColor: bubbleMeUIColor) }
  var bubbleThem: Color { Color(uiColor: bubbleThemUIColor) }
  var border: Color { Color(uiColor: borderUIColor) }
  var divider: Color { Color(uiColor: dividerUIColor) }
  var overlay: Color { Color(uiColor: overlayUIColor) }
  var success: Color { Color(uiColor: successUIColor) }
  var warning: Color { Color(uiColor: warningUIColor) }
  var danger: Color { Color(uiColor: dangerUIColor) }

  static func resolve(
    for colorScheme: ColorScheme,
    plate: AppThemePlateOption = AppThemePlateController.currentOption
  ) -> AppThemePalette {
    let isDark = colorScheme == .dark
    let baseBackground = isDark ? hex(0x121212) : hex(0xF5F4F1)
    let baseSecondaryBackground = isDark ? hex(0x151515) : hex(0xF5F4F1)
    let baseCard = isDark ? hex(0x242424) : hex(0xFFFFFF)
    let baseInput = isDark ? hex(0x222222) : hex(0xF2F2F2)
    let baseElevated = isDark ? hex(0x252530) : hex(0xFFFFFF)
    let text = isDark ? hex(0xE8E6F0) : hex(0x1A1A1F)
    let secondaryText = isDark ? hex(0x9896A8) : hex(0x5A5A66)
    let tertiaryText = isDark ? hex(0x5D5B6B) : hex(0x9A9AA3)

    let accent: UIColor
    let accentMuted: UIColor
    let button: UIColor
    let bubbleMe: UIColor
    let bubbleThem: UIColor

    switch (plate, isDark) {
    case (.glacier, true):
      accent = hex(0x2A8585)
      accentMuted = rgba(42, 133, 133, 0.6)
      button = hex(0x2A8585)
      bubbleMe = hex(0x2A8585)
      bubbleThem = hex(0x24242C)
    case (.glacier, false):
      accent = hex(0x00838F)
      accentMuted = rgba(0, 131, 143, 0.6)
      button = hex(0x00838F)
      bubbleMe = hex(0x00838F)
      bubbleThem = hex(0xFFFFFF)
    case (.zen, true):
      accent = hex(0x7C3AED)
      accentMuted = rgba(124, 58, 237, 0.6)
      button = hex(0x7C3AED)
      bubbleMe = hex(0x7C3AED)
      bubbleThem = hex(0x2B2335)
    case (.zen, false):
      accent = hex(0x3F51B5)
      accentMuted = rgba(63, 81, 181, 0.6)
      button = hex(0x3F51B5)
      bubbleMe = hex(0x3F51B5)
      bubbleThem = hex(0xF3F4FB)
    case (.ocean, true):
      accent = hex(0x3A7DA8)
      accentMuted = rgba(58, 125, 168, 0.6)
      button = hex(0x3A7DA8)
      bubbleMe = hex(0x3A7DA8)
      bubbleThem = hex(0x23313A)
    case (.ocean, false):
      accent = hex(0x0277BD)
      accentMuted = rgba(2, 119, 189, 0.6)
      button = hex(0x0277BD)
      bubbleMe = hex(0x0277BD)
      bubbleThem = hex(0xFFFFFF)
    case (.obsidian, true):
      accent = hex(0x1565C0)
      accentMuted = rgba(21, 101, 192, 0.6)
      button = hex(0x1565C0)
      bubbleMe = hex(0x1565C0)
      bubbleThem = hex(0x24242C)
    case (.obsidian, false):
      accent = hex(0x1565C0)
      accentMuted = rgba(21, 101, 192, 0.6)
      button = hex(0x1565C0)
      bubbleMe = hex(0x1565C0)
      bubbleThem = hex(0xFFFFFF)
    }

    return AppThemePalette(
      backgroundUIColor: baseBackground,
      secondaryBackgroundUIColor: baseSecondaryBackground,
      cardUIColor: baseCard,
      inputUIColor: baseInput,
      elevatedUIColor: baseElevated,
      textUIColor: text,
      secondaryTextUIColor: secondaryText,
      tertiaryTextUIColor: tertiaryText,
      accentUIColor: accent,
      accentMutedUIColor: accentMuted,
      buttonUIColor: button,
      buttonTextUIColor: isDark ? hex(0xFAFBFC) : hex(0xFEFEFE),
      bubbleMeUIColor: bubbleMe,
      bubbleThemUIColor: bubbleThem,
      borderUIColor: isDark ? rgba(248, 246, 252, 0.09) : rgba(26, 26, 31, 0.07),
      dividerUIColor: isDark ? rgba(248, 246, 252, 0.05) : rgba(26, 26, 31, 0.035),
      overlayUIColor: isDark ? rgba(13, 13, 18, 0.88) : rgba(250, 249, 247, 0.90),
      successUIColor: isDark ? hex(0x5ABF8F) : hex(0x428A6A),
      warningUIColor: isDark ? hex(0xC9A33D) : hex(0xB89338),
      dangerUIColor: isDark ? hex(0xD45A5A) : hex(0xC44A4A)
    )
  }

  private static func hex(_ value: UInt, alpha: CGFloat = 1.0) -> UIColor {
    UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255.0,
      green: CGFloat((value >> 8) & 0xFF) / 255.0,
      blue: CGFloat(value & 0xFF) / 255.0,
      alpha: alpha
    )
  }

  private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat)
    -> UIColor
  {
    UIColor(
      red: red / 255.0,
      green: green / 255.0,
      blue: blue / 255.0,
      alpha: alpha
    )
  }
}

@MainActor
final class AppToastController: ObservableObject {
  static let shared = AppToastController()

  @Published private(set) var message: String?
  private var hideTask: Task<Void, Never>?

  private init() {}

  func show(_ message: String, duration: TimeInterval = 2.6) {
    hideTask?.cancel()
    self.message = message
    hideTask = Task { [weak self] in
      guard duration > 0 else { return }
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.message = nil
      }
    }
  }

  func clear() {
    hideTask?.cancel()
    hideTask = nil
    message = nil
  }
}

struct AppUserProfile: Equatable {
  let userID: String
  let username: String
  let name: String?
  let phoneNumber: String?
  let bio: String?
  let dateOfBirth: String?
  let profileImage: String?
  let showLastSeen: Bool
  let showOnlineStatus: Bool
  let autoDeleteTimer: Int?
  let privacyLastSeen: AppPrivacyChoice
  let privacyForward: AppPrivacyChoice
  let privacyCalls: AppPrivacyChoice
  let privacyPhoneNumber: AppPrivacyChoice
  let privacyProfilePhotos: AppPrivacyChoice
  let privacyBio: AppPrivacyChoice
  let privacyGifts: AppPrivacyChoice
  let privacyBirthday: AppPrivacyChoice
  let privacySavedMusic: AppPrivacyChoice

  var displayName: String {
    name?.nilIfBlank ?? username
  }

  var subtitle: String {
    if let phoneNumber, !phoneNumber.isEmpty {
      return phoneNumber
    }
    return "@\(username)"
  }

  init?(
    userID: String,
    username: String,
    name: String? = nil,
    phoneNumber: String? = nil,
    bio: String? = nil,
    dateOfBirth: String? = nil,
    profileImage: String? = nil,
    showLastSeen: Bool = true,
    showOnlineStatus: Bool = true,
    autoDeleteTimer: Int? = nil,
    privacyLastSeen: AppPrivacyChoice = .everybody,
    privacyForward: AppPrivacyChoice = .everybody,
    privacyCalls: AppPrivacyChoice = .everybody,
    privacyPhoneNumber: AppPrivacyChoice = .everybody,
    privacyProfilePhotos: AppPrivacyChoice = .everybody,
    privacyBio: AppPrivacyChoice = .everybody,
    privacyGifts: AppPrivacyChoice = .everybody,
    privacyBirthday: AppPrivacyChoice = .everybody,
    privacySavedMusic: AppPrivacyChoice = .everybody
  ) {
    let resolvedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedUserID.isEmpty, !resolvedUsername.isEmpty else { return nil }

    self.userID = resolvedUserID
    self.username = resolvedUsername
    self.name = name?.nilIfBlank
    self.phoneNumber = phoneNumber?.nilIfBlank
    self.bio = bio?.nilIfBlank
    self.dateOfBirth = dateOfBirth?.nilIfBlank
    self.profileImage = profileImage?.nilIfBlank
    self.showLastSeen = showLastSeen
    self.showOnlineStatus = showOnlineStatus
    self.autoDeleteTimer = autoDeleteTimer
    self.privacyLastSeen = privacyLastSeen
    self.privacyForward = privacyForward
    self.privacyCalls = privacyCalls
    self.privacyPhoneNumber = privacyPhoneNumber
    self.privacyProfilePhotos = privacyProfilePhotos
    self.privacyBio = privacyBio
    self.privacyGifts = privacyGifts
    self.privacyBirthday = privacyBirthday
    self.privacySavedMusic = privacySavedMusic
  }

  init?(payload: [String: Any], fallbackConfig: AppSessionConfig? = nil) {
    let fallbackUserID = fallbackConfig?.userID ?? ""
    let fallbackUsername = fallbackConfig?.username ?? fallbackConfig?.name ?? ""
    let userID = Self.normalizedString(payload["userId"] ?? payload["id"]) ?? fallbackUserID
    let username =
      Self.normalizedString(payload["username"])
      ?? Self.normalizedString(payload["name"])
      ?? fallbackUsername

    guard let profile = AppUserProfile(
      userID: userID,
      username: username,
      name: Self.normalizedString(payload["name"]) ?? fallbackConfig?.name,
      phoneNumber: Self.normalizedString(payload["phoneNumber"] ?? payload["phone"])
        ?? fallbackConfig?.phoneNumber,
      bio: Self.normalizedString(payload["bio"]) ?? fallbackConfig?.bio,
      dateOfBirth: Self.normalizedString(payload["dateOfBirth"]) ?? fallbackConfig?.dateOfBirth,
      profileImage: Self.normalizedString(payload["profileImage"] ?? payload["profile_image"])
        ?? fallbackConfig?.profileImage,
      showLastSeen: Self.normalizedBool(payload["showLastSeen"]) ?? fallbackConfig?.showLastSeen
        ?? true,
      showOnlineStatus: Self.normalizedBool(payload["showOnlineStatus"])
        ?? fallbackConfig?.showOnlineStatus ?? true,
      autoDeleteTimer: Self.normalizedInt(payload["autoDeleteTimer"])
        ?? fallbackConfig?.autoDeleteTimer,
      privacyLastSeen: Self.normalizedPrivacyChoice(payload["privacyLastSeen"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyLastSeen) ?? .everybody,
      privacyForward: Self.normalizedPrivacyChoice(payload["privacyForward"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyForward) ?? .everybody,
      privacyCalls: Self.normalizedPrivacyChoice(payload["privacyCalls"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyCalls) ?? .everybody,
      privacyPhoneNumber: Self.normalizedPrivacyChoice(payload["privacyPhoneNumber"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyPhoneNumber) ?? .everybody,
      privacyProfilePhotos: Self.normalizedPrivacyChoice(payload["privacyProfilePhotos"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyProfilePhotos) ?? .everybody,
      privacyBio: Self.normalizedPrivacyChoice(payload["privacyBio"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyBio) ?? .everybody,
      privacyGifts: Self.normalizedPrivacyChoice(payload["privacyGifts"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyGifts) ?? .everybody,
      privacyBirthday: Self.normalizedPrivacyChoice(payload["privacyBirthday"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyBirthday) ?? .everybody,
      privacySavedMusic: Self.normalizedPrivacyChoice(payload["privacySavedMusic"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacySavedMusic) ?? .everybody
    ) else {
      return nil
    }

    self = profile
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func normalizedBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
      return value
    }
    if let value = value as? NSNumber {
      return value.boolValue
    }
    if let value = value as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on":
        return true
      case "0", "false", "no", "off":
        return false
      default:
        return nil
      }
    }
    return nil
  }

  private static func normalizedInt(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = value as? String {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private static func normalizedPrivacyChoice(_ value: Any?) -> AppPrivacyChoice? {
    guard let value = normalizedString(value) else { return nil }
    return AppPrivacyChoice(rawValue: value)
  }
}

struct AppUserProfileDraft: Equatable {
  var name: String
  var username: String
  var phoneNumber: String
  var bio: String
  var dateOfBirth: String

  init(profile: AppUserProfile?) {
    self.name = profile?.name ?? ""
    self.username = profile?.username ?? AppSessionConfig.current?.username ?? ""
    self.phoneNumber = profile?.phoneNumber ?? AppSessionConfig.current?.phoneNumber ?? ""
    self.bio = profile?.bio ?? ""
    self.dateOfBirth = profile?.dateOfBirth ?? ""
  }

  var trimmedPayload: [String: Any] {
    [
      "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
      "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
      "phoneNumber": phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines),
      "bio": bio.trimmingCharacters(in: .whitespacesAndNewlines),
      "dateOfBirth": dateOfBirth.trimmingCharacters(in: .whitespacesAndNewlines),
    ]
  }
}

@MainActor
final class AppProfileController: ObservableObject {
  static let shared = AppProfileController()

  @Published private(set) var profile: AppUserProfile?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private var hasLoaded = false

  private init() {}

  func loadIfNeeded() async {
    if profile == nil {
      seedFromCurrentSession()
    }
    guard !hasLoaded else { return }
    await refresh()
  }

  func refresh() async {
    guard let config = AppSessionConfig.current else {
      profile = nil
      hasLoaded = false
      errorMessage = nil
      return
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let fetchedProfile = try await AppProfileService.fetchProfile(config: config)
      profile = fetchedProfile
      hasLoaded = true
      persistProfileToSession(fetchedProfile)
    } catch {
      errorMessage = error.localizedDescription
      if profile == nil {
        seedFromCurrentSession()
      }
    }
  }

  func update(_ draft: AppUserProfileDraft) async throws {
    guard let config = AppSessionConfig.current else {
      throw AppProfileServiceError.invalidConfiguration
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let updatedProfile = try await AppProfileService.updateProfile(config: config, draft: draft)
      profile = updatedProfile
      hasLoaded = true
      persistProfileToSession(updatedProfile)
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func updateFields(_ fields: [String: Any]) async throws {
    guard let config = AppSessionConfig.current else {
      throw AppProfileServiceError.invalidConfiguration
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let updatedProfile = try await AppProfileService.updateFields(config: config, fields: fields)
      profile = updatedProfile
      hasLoaded = true
      persistProfileToSession(updatedProfile)
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func reset() {
    profile = nil
    isLoading = false
    errorMessage = nil
    hasLoaded = false
  }

  private func seedFromCurrentSession() {
    guard let config = AppSessionConfig.current else { return }
    profile =
      AppUserProfile(
        userID: config.userID,
        username: config.username ?? config.name ?? config.userID,
        name: config.name,
        phoneNumber: config.phoneNumber,
        bio: config.bio,
        dateOfBirth: config.dateOfBirth,
        profileImage: config.profileImage,
        showLastSeen: config.showLastSeen ?? true,
        showOnlineStatus: config.showOnlineStatus ?? true,
        autoDeleteTimer: config.autoDeleteTimer,
        privacyLastSeen: AppPrivacyChoice(rawValue: config.privacyLastSeen ?? "") ?? .everybody,
        privacyForward: AppPrivacyChoice(rawValue: config.privacyForward ?? "") ?? .everybody,
        privacyCalls: AppPrivacyChoice(rawValue: config.privacyCalls ?? "") ?? .everybody,
        privacyPhoneNumber: AppPrivacyChoice(rawValue: config.privacyPhoneNumber ?? "") ?? .everybody,
        privacyProfilePhotos: AppPrivacyChoice(rawValue: config.privacyProfilePhotos ?? "")
          ?? .everybody,
        privacyBio: AppPrivacyChoice(rawValue: config.privacyBio ?? "") ?? .everybody,
        privacyGifts: AppPrivacyChoice(rawValue: config.privacyGifts ?? "") ?? .everybody,
        privacyBirthday: AppPrivacyChoice(rawValue: config.privacyBirthday ?? "") ?? .everybody,
        privacySavedMusic: AppPrivacyChoice(rawValue: config.privacySavedMusic ?? "")
          ?? .everybody
      )
  }

  private func persistProfileToSession(_ profile: AppUserProfile) {
    ChatEngineStore.shared.updateConfig([
      "username": profile.username,
      "name": profile.name,
      "phoneNumber": profile.phoneNumber,
      "bio": profile.bio,
      "dateOfBirth": profile.dateOfBirth,
      "profileImage": profile.profileImage,
      "showLastSeen": profile.showLastSeen,
      "showOnlineStatus": profile.showOnlineStatus,
      "autoDeleteTimer": profile.autoDeleteTimer,
      "privacyLastSeen": profile.privacyLastSeen.rawValue,
      "privacyForward": profile.privacyForward.rawValue,
      "privacyCalls": profile.privacyCalls.rawValue,
      "privacyPhoneNumber": profile.privacyPhoneNumber.rawValue,
      "privacyProfilePhotos": profile.privacyProfilePhotos.rawValue,
      "privacyBio": profile.privacyBio.rawValue,
      "privacyGifts": profile.privacyGifts.rawValue,
      "privacyBirthday": profile.privacyBirthday.rawValue,
      "privacySavedMusic": profile.privacySavedMusic.rawValue,
    ])
  }
}

private enum AppProfileService {
  static func fetchProfile(config: AppSessionConfig) async throws -> AppUserProfile {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/user/\(config.userID)") else {
      throw AppProfileServiceError.invalidConfiguration
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    applyHeaders(&request, token: config.authToken)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AppProfileServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw AppProfileServiceError.http(
        httpResponse.statusCode,
        String(data: data, encoding: .utf8) ?? ""
      )
    }

    guard
      let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        as? [String: Any],
      let profile = AppUserProfile(payload: raw, fallbackConfig: config)
    else {
      throw AppProfileServiceError.invalidResponse
    }
    return profile
  }

  static func updateProfile(config: AppSessionConfig, draft: AppUserProfileDraft) async throws
    -> AppUserProfile
  {
    var body = draft.trimmedPayload
    body["userId"] = config.userID
    return try await sendProfileUpdate(config: config, body: body)
  }

  static func updateFields(config: AppSessionConfig, fields: [String: Any]) async throws
    -> AppUserProfile
  {
    var body = fields
    body["userId"] = config.userID
    return try await sendProfileUpdate(config: config, body: body)
  }

  private static func sendProfileUpdate(config: AppSessionConfig, body: [String: Any]) async throws
    -> AppUserProfile
  {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/user/profile") else {
      throw AppProfileServiceError.invalidConfiguration
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    applyHeaders(&request, token: config.authToken)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AppProfileServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw AppProfileServiceError.http(
        httpResponse.statusCode,
        String(data: data, encoding: .utf8) ?? ""
      )
    }

    guard
      let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        as? [String: Any],
      let profile = AppUserProfile(payload: raw, fallbackConfig: config)
    else {
      throw AppProfileServiceError.invalidResponse
    }
    return profile
  }

  private static func apiURL(base: String, path: String) -> URL? {
    var normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    guard !normalized.isEmpty else { return nil }

    let pathBase = normalized.lowercased().hasSuffix("/api") ? normalized : "\(normalized)/api"
    return URL(string: pathBase + path)
  }

  private static func applyHeaders(_ request: inout URLRequest, token: String) {
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  }
}

enum AppProfileServiceError: LocalizedError {
  case invalidConfiguration
  case invalidResponse
  case http(Int, String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      return "The current session is missing profile configuration."
    case .invalidResponse:
      return "The profile service returned an invalid response."
    case let .http(statusCode, body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Profile update failed (\(statusCode))."
        : "Profile update failed (\(statusCode)): \(trimmed)"
    }
  }
}

@MainActor
enum AppRootControllerFactory {
  static func makeInitialController() -> UIViewController {
    if AppSessionConfig.current != nil {
      return makeAuthenticatedController()
    }
    return makeWelcomeController()
  }

  static func makeAuthenticatedController() -> UIViewController {
    UIHostingController(rootView: AppRootView())
  }

  static func makeWelcomeController() -> UIViewController {
    let navigationController = UINavigationController(rootViewController: WelcomeViewController())
    navigationController.navigationBar.prefersLargeTitles = true
    return navigationController
  }

  static func showAuthenticatedRoot(animated: Bool = true) {
    replaceRoot(with: makeAuthenticatedController(), animated: animated)
  }

  static func showWelcomeRoot(animated: Bool = true) {
    replaceRoot(with: makeWelcomeController(), animated: animated)
  }

  static func signOut(animated: Bool = true) {
    AppProfileController.shared.reset()
    AppToastController.shared.clear()
    ChatEngineStore.shared.clearConfig()
    showWelcomeRoot(animated: animated)
  }

  private static func replaceRoot(with controller: UIViewController, animated: Bool) {
    guard let window = activeWindow() else { return }

    let applyRoot = {
      window.rootViewController = controller
      AppAppearanceController.applyStoredPreference(to: window)
      window.makeKeyAndVisible()
    }

    if animated {
      UIView.transition(
        with: window,
        duration: 0.25,
        options: [.transitionCrossDissolve, .allowAnimatedContent]
      ) {
        applyRoot()
      }
    } else {
      applyRoot()
    }
  }

  private static func activeWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
        return keyWindow
      }
    }
    return nil
  }
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
