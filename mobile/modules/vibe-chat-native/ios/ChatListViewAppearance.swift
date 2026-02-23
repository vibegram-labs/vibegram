import UIKit

struct ChatListAppearance {
  let backgroundMode: String
  let wallpaperGradient: [UIColor]
  let wallpaperOpacity: CGFloat
  let wallpaperPatternGradient: [UIColor]
  let wallpaperPatternLocations: [NSNumber]?
  let wallpaperPatternOpacity: CGFloat
  let wallpaperMaskKey: String?

  let bubbleMeGradient: [UIColor]
  let bubbleThemColor: UIColor

  let textColorMe: UIColor
  let textColorThem: UIColor
  let timeColorMe: UIColor
  let timeColorThem: UIColor

  let dayTextColor: UIColor
  let dayBackgroundColor: UIColor
  let dayBorderColor: UIColor

  /// Controls the insertion animation approach:
  ///   0 = None (instant, no animation)
  ///   1 = SlideUpNewOnly (only new cells slide up)
  ///   2 = TelegramOffset (record pre/post positions, animate deltas)
  ///   3 = SpringBatch (UIView.animate with spring wrapping the batch)
  let insertionAnimationMode: Int

  static let fallback = ChatListAppearance(
    backgroundMode: "transparent",
    wallpaperGradient: [
      UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0),
      UIColor(red: 0.07, green: 0.07, blue: 0.16, alpha: 1.0)
    ],
    wallpaperOpacity: 1.0,
    wallpaperPatternGradient: [],
    wallpaperPatternLocations: nil,
    wallpaperPatternOpacity: 0.0,
    wallpaperMaskKey: nil,
    bubbleMeGradient: [
      UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0),
      UIColor(red: 0.42, green: 0.31, blue: 0.81, alpha: 1.0)
    ],
    bubbleThemColor: UIColor(red: 0.17, green: 0.17, blue: 0.29, alpha: 1.0),
    textColorMe: .white,
    textColorThem: UIColor(white: 0.87, alpha: 1.0),
    timeColorMe: UIColor(white: 1.0, alpha: 0.72),
    timeColorThem: UIColor(white: 1.0, alpha: 0.5),
    dayTextColor: UIColor(white: 0.93, alpha: 0.82),
    dayBackgroundColor: UIColor(red: 0.08, green: 0.08, blue: 0.13, alpha: 0.42),
    dayBorderColor: UIColor(white: 1.0, alpha: 0.16),
    insertionAnimationMode: 2
  )

  static func from(raw: [String: Any]?) -> ChatListAppearance {
    guard let raw else {
      return .fallback
    }

    if let nativeResolved = nativePresetAppearance(from: raw, fallback: .fallback) {
      return nativeResolved
    }

    let fallback = ChatListAppearance.fallback
    let mode = (raw["backgroundMode"] as? String) ?? fallback.backgroundMode
    let gradientStrings = raw["wallpaperGradient"] as? [String]
    let patternGradientStrings = raw["wallpaperPatternGradient"] as? [String]
    let meGradientStrings = raw["bubbleMeGradient"] as? [String]

    let wallpaperGradient = parseGradient(gradientStrings, fallback: fallback.wallpaperGradient)
    let wallpaperPatternGradient = parseGradient(
      patternGradientStrings, fallback: fallback.wallpaperPatternGradient)
    let bubbleMeGradient = parseGradient(meGradientStrings, fallback: fallback.bubbleMeGradient)

    return ChatListAppearance(
      backgroundMode: mode,
      wallpaperGradient: wallpaperGradient,
      wallpaperOpacity: CGFloat((raw["wallpaperOpacity"] as? NSNumber)?.doubleValue ?? 1.0),
      wallpaperPatternGradient: wallpaperPatternGradient,
      wallpaperPatternLocations: parseNumberArray(raw["wallpaperPatternLocations"]),
      wallpaperPatternOpacity: CGFloat((raw["wallpaperPatternOpacity"] as? NSNumber)?.doubleValue ?? 0.0),
      wallpaperMaskKey: normalizedString(raw["wallpaperMaskKey"]),
      bubbleMeGradient: bubbleMeGradient,
      bubbleThemColor: parseColor(raw["bubbleThemColor"] as? String) ?? fallback.bubbleThemColor,
      textColorMe: parseColor(raw["textColorMe"] as? String) ?? fallback.textColorMe,
      textColorThem: parseColor(raw["textColorThem"] as? String) ?? fallback.textColorThem,
      timeColorMe: parseColor(raw["timeColorMe"] as? String) ?? fallback.timeColorMe,
      timeColorThem: parseColor(raw["timeColorThem"] as? String) ?? fallback.timeColorThem,
      dayTextColor: parseColor(raw["dayTextColor"] as? String) ?? fallback.dayTextColor,
      dayBackgroundColor: parseColor(raw["dayBackgroundColor"] as? String) ?? fallback.dayBackgroundColor,
      dayBorderColor: parseColor(raw["dayBorderColor"] as? String) ?? fallback.dayBorderColor,
      insertionAnimationMode: (raw["insertionAnimationMode"] as? NSNumber)?.intValue ?? fallback.insertionAnimationMode
    )
  }

  var visualKey: String {
    let wallpaperKey = wallpaperGradient.map(colorKey).joined(separator: ",")
    let wallpaperPatternKey = wallpaperPatternGradient.map(colorKey).joined(separator: ",")
    let wallpaperPatternLocationsKey =
      wallpaperPatternLocations?.map { String(format: "%.4f", $0.doubleValue) }.joined(separator: ",")
      ?? ""
    let meKey = bubbleMeGradient.map(colorKey).joined(separator: ",")
    return [
      backgroundMode,
      String(format: "%.4f", wallpaperOpacity),
      wallpaperKey,
      wallpaperPatternKey,
      wallpaperPatternLocationsKey,
      String(format: "%.4f", wallpaperPatternOpacity),
      wallpaperMaskKey ?? "",
      meKey,
      colorKey(bubbleThemColor),
      colorKey(textColorMe),
      colorKey(textColorThem),
      colorKey(timeColorMe),
      colorKey(timeColorThem),
      colorKey(dayTextColor),
      colorKey(dayBackgroundColor),
      colorKey(dayBorderColor)
    ].joined(separator: "|")
  }
}

private struct NativeThemeVariant {
  let backgroundGradient: [String]
  let bubbleMe: String
  let bubbleMeGradient: [String]
  let bubbleThem: String
  let bubbleThemGradient: [String]
  let patternGradientColors: [String]
  let patternGradientLocations: [Double]
  let patternOpacity: Double
  let textColorMe: String
  let textColorThem: String
}

private struct NativeThemePreset {
  let id: String
  let maskedImage: String?
  let light: NativeThemeVariant
  let dark: NativeThemeVariant
}

private func nativePresetAppearance(
  from raw: [String: Any],
  fallback: ChatListAppearance
) -> ChatListAppearance? {
  guard
    let themeId = normalizedString(raw["nativeThemeId"]),
    let preset = nativePreset(for: themeId)
  else {
    return nil
  }
  let isDark = parseBool(raw["nativeThemeIsDark"]) ?? true
  let mode = (raw["backgroundMode"] as? String) ?? fallback.backgroundMode
  let wallpaperOpacity = CGFloat((raw["wallpaperOpacity"] as? NSNumber)?.doubleValue ?? 1.0)
  let insertionAnimationMode = (raw["insertionAnimationMode"] as? NSNumber)?.intValue ?? fallback.insertionAnimationMode

  let variant = isDark ? preset.dark : preset.light
  let resolvedBackgroundGradient: [String]
  let resolvedPatternGradientColors: [String]
  let resolvedPatternOpacity: Double

  if isDark {
    resolvedBackgroundGradient = variant.backgroundGradient
    resolvedPatternGradientColors = variant.patternGradientColors
    resolvedPatternOpacity = variant.patternOpacity
  } else {
    // Matches JS resolveThemeVariant() light overrides in wallpaper-store.ts
    resolvedBackgroundGradient = ["#F9F3EA", "#EFE6D9"]
    resolvedPatternGradientColors = ["#5A8A66", "#5A6675", "#8A75A3"]
    resolvedPatternOpacity = 0.04
  }

  let wallpaperGradient = parseGradient(resolvedBackgroundGradient, fallback: fallback.wallpaperGradient)
  let patternGradient = parseGradient(resolvedPatternGradientColors, fallback: [])
  let bubbleMeGradient = parseGradient(variant.bubbleMeGradient, fallback: fallback.bubbleMeGradient)
  let bubbleThemColor = parseColor(variant.bubbleThemGradient.first) ?? parseColor(variant.bubbleThem) ?? fallback.bubbleThemColor
  let textColorMe = parseColor(variant.textColorMe) ?? fallback.textColorMe
  let textColorThem = parseColor(variant.textColorThem) ?? fallback.textColorThem
  let dayBackgroundBase = wallpaperGradient.first ?? fallback.wallpaperGradient.first ?? .black

  return ChatListAppearance(
    backgroundMode: mode,
    wallpaperGradient: wallpaperGradient,
    wallpaperOpacity: wallpaperOpacity,
    wallpaperPatternGradient: patternGradient,
    wallpaperPatternLocations: variant.patternGradientLocations.map { NSNumber(value: $0) },
    wallpaperPatternOpacity: CGFloat(resolvedPatternOpacity),
    wallpaperMaskKey: preset.maskedImage,
    bubbleMeGradient: bubbleMeGradient,
    bubbleThemColor: bubbleThemColor,
    textColorMe: textColorMe,
    textColorThem: textColorThem,
    timeColorMe: colorWithAlpha(textColorMe, 0.72),
    timeColorThem: colorWithAlpha(textColorThem, 0.5),
    dayTextColor: colorWithAlpha(textColorThem, 0.82),
    dayBackgroundColor: colorWithAlpha(dayBackgroundBase, 0.42),
    dayBorderColor: colorWithAlpha(.white, 0.16),
    insertionAnimationMode: insertionAnimationMode
  )
}

private func nativePreset(for id: String) -> NativeThemePreset? {
  switch id {
  case "glacier":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFFFFF", "#FFFFFF"],
        bubbleMe: "#00838F",
        bubbleMeGradient: ["#00ACC1", "#00838F"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#FFFFFF"],
        patternGradientColors: ["#B2EBF2", "#80DEEA", "#4DD0E1"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.12,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#000000", "#050507"],
        bubbleMe: "#2A8585",
        bubbleMeGradient: ["#3A9595", "#1A7575"],
        bubbleThem: "#24242C",
        bubbleThemGradient: ["#2F3338", "#20242A"],
        patternGradientColors: ["#115E59", "#0891B2", "#0284C7"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.12,
        textColorMe: "#F0FCFC",
        textColorThem: "#FFFFFF"
      )
    )
  case "zen":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFFFFF", "#FFFFFF"],
        bubbleMe: "#3F51B5",
        bubbleMeGradient: ["#5C6BC0", "#3949AB"],
        bubbleThem: "#F3F4FB",
        bubbleThemGradient: ["#FFFFFF", "#FFFFFF"],
        patternGradientColors: ["#C5CAE9", "#9FA8DA", "#7986CB"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.12,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#000000", "#050507"],
        bubbleMe: "#7C3AED",
        bubbleMeGradient: ["#8B5CF6", "#6D28D9"],
        bubbleThem: "#24242C",
        bubbleThemGradient: ["#312B3B", "#231E2C"],
        patternGradientColors: ["#2563EB", "#4F46E5", "#7C3AED", "#C026D3", "#DB2777"],
        patternGradientLocations: [0, 0.25, 0.5, 0.75, 1],
        patternOpacity: 0.12,
        textColorMe: "#F4F6F7",
        textColorThem: "#FFFFFF"
      )
    )
  case "ocean":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFFFFF", "#FFFFFF"],
        bubbleMe: "#0277BD",
        bubbleMeGradient: ["#039BE5", "#0277BD"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#FFFFFF"],
        patternGradientColors: ["#B3E5FC", "#81D4FA", "#4FC3F7"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.12,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#000000", "#050507"],
        bubbleMe: "#3A7DA8",
        bubbleMeGradient: ["#4A8DB8", "#2A6D98"],
        bubbleThem: "#24242C",
        bubbleThemGradient: ["#2A313A", "#1B232C"],
        patternGradientColors: ["#1E3A8A", "#0F766E", "#06B6D4", "#22D3EE"],
        patternGradientLocations: [0, 0.4, 0.8, 1],
        patternOpacity: 0.15,
        textColorMe: "#F4F8FC",
        textColorThem: "#FFFFFF"
      )
    )
  case "obsidian":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFFFFF", "#FFFFFF"],
        bubbleMe: "#1565C0",
        bubbleMeGradient: ["#1E88E5", "#1565C0"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#FFFFFF"],
        patternGradientColors: ["#BBDEFB", "#90CAF9", "#64B5F6"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.12,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#000000", "#050507"],
        bubbleMe: "#4A7DC4",
        bubbleMeGradient: ["#5A8FD4", "#3A6AB8"],
        bubbleThem: "#24242C",
        bubbleThemGradient: ["#2D313C", "#1F2430"],
        patternGradientColors: ["#312E81", "#4338CA", "#4F46E5", "#818CF8"],
        patternGradientLocations: [0, 0.3, 0.7, 1],
        patternOpacity: 0.18,
        textColorMe: "#F4F6F8",
        textColorThem: "#FFFFFF"
      )
    )
  case "music":
    return NativeThemePreset(
      id: id,
      maskedImage: "music",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFFFFF", "#FFFFFF"],
        bubbleMe: "#7B1FA2",
        bubbleMeGradient: ["#9C27B0", "#7B1FA2"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#FFFFFF"],
        patternGradientColors: ["#E1BEE7", "#CE93D8", "#BA68C8"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.14,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#000000", "#050507"],
        bubbleMe: "#8B5CF6",
        bubbleMeGradient: ["#A78BFA", "#7C3AED"],
        bubbleThem: "#24242C",
        bubbleThemGradient: ["#332A3E", "#251F30"],
        patternGradientColors: ["#22D3EE", "#E879F9", "#8B5CF6"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.15,
        textColorMe: "#F8F6FC",
        textColorThem: "#FFFFFF"
      )
    )
  case "terracotta":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFFFFF", "#FFFFFF"],
        bubbleMe: "#E65100",
        bubbleMeGradient: ["#F57C00", "#E65100"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#FFFFFF"],
        patternGradientColors: ["#FFE0B2", "#FFCC80", "#FFB74D"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.14,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#000000", "#050507"],
        bubbleMe: "#B87050",
        bubbleMeGradient: ["#C88060", "#A86040"],
        bubbleThem: "#24242C",
        bubbleThemGradient: ["#3B2F2A", "#2B221F"],
        patternGradientColors: ["#DC2626", "#EA580C", "#B45309"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.12,
        textColorMe: "#FAF0E8",
        textColorThem: "#FFFFFF"
      )
    )
  default:
    return nil
  }
}

private func normalizedString(_ raw: Any?) -> String? {
  guard let value = raw as? String else {
    return nil
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func parseBool(_ raw: Any?) -> Bool? {
  if let value = raw as? Bool {
    return value
  }
  if let value = raw as? NSNumber {
    return value.boolValue
  }
  if let text = raw as? String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["1", "true", "yes"].contains(normalized) {
      return true
    }
    if ["0", "false", "no"].contains(normalized) {
      return false
    }
  }
  return nil
}

private func parseNumberArray(_ raw: Any?) -> [NSNumber]? {
  if let array = raw as? [NSNumber] {
    return array
  }
  if let array = raw as? [Double] {
    return array.map { NSNumber(value: $0) }
  }
  if let array = raw as? [Int] {
    return array.map { NSNumber(value: $0) }
  }
  if let array = raw as? [String] {
    let parsed = array.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return parsed.count == array.count ? parsed.map { NSNumber(value: $0) } : nil
  }
  return nil
}

private func colorWithAlpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var currentAlpha: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &currentAlpha) {
    return UIColor(red: r, green: g, blue: b, alpha: max(0.0, min(1.0, alpha)))
  }
  if let converted = color.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
     let components = converted.components {
    if components.count >= 3 {
      let r = components[0]
      let g = components.count > 1 ? components[1] : components[0]
      let b = components.count > 2 ? components[2] : components[0]
      return UIColor(red: r, green: g, blue: b, alpha: max(0.0, min(1.0, alpha)))
    }
  }
  return color.withAlphaComponent(max(0.0, min(1.0, alpha)))
}

private func colorKey(_ color: UIColor) -> String {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
    return String(format: "%.4f,%.4f,%.4f,%.4f", r, g, b, a)
  }
  if let converted = color.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
     let components = converted.components {
    let cr: CGFloat
    let cg: CGFloat
    let cb: CGFloat
    let ca: CGFloat
    if components.count >= 4 {
      cr = components[0]
      cg = components[1]
      cb = components[2]
      ca = components[3]
    } else if components.count == 2 {
      cr = components[0]
      cg = components[0]
      cb = components[0]
      ca = components[1]
    } else {
      cr = 0
      cg = 0
      cb = 0
      ca = 1
    }
    return String(format: "%.4f,%.4f,%.4f,%.4f", cr, cg, cb, ca)
  }
  return "0,0,0,0"
}

private func parseGradient(_ values: [String]?, fallback: [UIColor]) -> [UIColor] {
  guard let values else {
    return fallback
  }
  let colors = values.compactMap(parseColor)
  return colors.count >= 2 ? colors : fallback
}

private func parseGradient(_ values: [String], fallback: [UIColor]) -> [UIColor] {
  let colors = values.compactMap(parseColor)
  return colors.count >= 2 ? colors : fallback
}

private func parseColor(_ value: String?) -> UIColor? {
  guard let value else {
    return nil
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if trimmed.hasPrefix("#") {
    return parseHexColor(trimmed)
  }
  if trimmed.hasPrefix("rgba(") || trimmed.hasPrefix("rgb(") {
    return parseRgbColor(trimmed)
  }
  return nil
}

private func parseHexColor(_ value: String) -> UIColor? {
  var hex = value
  if hex.hasPrefix("#") {
    hex.removeFirst()
  }
  if hex.count == 3 || hex.count == 4 {
    hex = hex.map { "\($0)\($0)" }.joined()
  }
  guard hex.count == 6 || hex.count == 8 else {
    return nil
  }

  var rgba: UInt64 = 0
  guard Scanner(string: hex).scanHexInt64(&rgba) else {
    return nil
  }

  if hex.count == 6 {
    let r = CGFloat((rgba & 0xFF0000) >> 16) / 255.0
    let g = CGFloat((rgba & 0x00FF00) >> 8) / 255.0
    let b = CGFloat(rgba & 0x0000FF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: 1.0)
  }

  let r = CGFloat((rgba & 0xFF000000) >> 24) / 255.0
  let g = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
  let b = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
  let a = CGFloat(rgba & 0x000000FF) / 255.0
  return UIColor(red: r, green: g, blue: b, alpha: a)
}

private func parseRgbColor(_ value: String) -> UIColor? {
  guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else {
    return nil
  }
  let args = value[value.index(after: open)..<close].split(separator: ",").map {
    $0.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  guard args.count == 3 || args.count == 4 else {
    return nil
  }

  guard
    let r = Double(args[0]),
    let g = Double(args[1]),
    let b = Double(args[2])
  else {
    return nil
  }
  let a = args.count == 4 ? (Double(args[3]) ?? 1.0) : 1.0
  return UIColor(
    red: CGFloat(max(0.0, min(255.0, r)) / 255.0),
    green: CGFloat(max(0.0, min(255.0, g)) / 255.0),
    blue: CGFloat(max(0.0, min(255.0, b)) / 255.0),
    alpha: CGFloat(max(0.0, min(1.0, a)))
  )
}
