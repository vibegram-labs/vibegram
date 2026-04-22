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
  let bubbleThemGradient: [UIColor]
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
      UIColor(red: 0.07, green: 0.07, blue: 0.16, alpha: 1.0),
    ],
    wallpaperOpacity: 1.0,
    wallpaperPatternGradient: [],
    wallpaperPatternLocations: nil,
    wallpaperPatternOpacity: 0.0,
    wallpaperMaskKey: nil,
    bubbleMeGradient: [
      UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0),
      UIColor(red: 0.42, green: 0.31, blue: 0.81, alpha: 1.0),
    ],
    bubbleThemGradient: [
      UIColor(red: 0.17, green: 0.17, blue: 0.29, alpha: 1.0),
      UIColor(red: 0.17, green: 0.17, blue: 0.29, alpha: 1.0),
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
    let themGradientStrings = raw["bubbleThemGradient"] as? [String]

    let bubbleThemColor = parseColor(raw["bubbleThemColor"] as? String) ?? fallback.bubbleThemColor
    let wallpaperGradient = parseGradient(gradientStrings, fallback: fallback.wallpaperGradient)
    let wallpaperPatternGradient = parseGradient(
      patternGradientStrings, fallback: fallback.wallpaperPatternGradient)
    let bubbleMeGradient = parseGradient(meGradientStrings, fallback: fallback.bubbleMeGradient)
    let bubbleThemGradient = parseGradient(
      themGradientStrings,
      fallback: [bubbleThemColor, bubbleThemColor]
    )
    let textColorMe = parseColor(raw["textColorMe"] as? String) ?? fallback.textColorMe
    let textColorThem = parseColor(raw["textColorThem"] as? String) ?? fallback.textColorThem
    let isDark = isDarkColor(wallpaperGradient.first ?? fallback.wallpaperGradient.first ?? .black)
    let dayPlateBase = resolvedDayPlateBase(
      bubbleThemColor: bubbleThemColor,
      wallpaperGradient: wallpaperGradient,
      isDark: isDark
    )
    return ChatListAppearance(
      backgroundMode: mode,
      wallpaperGradient: wallpaperGradient,
      wallpaperOpacity: CGFloat((raw["wallpaperOpacity"] as? NSNumber)?.doubleValue ?? 1.0),
      wallpaperPatternGradient: wallpaperPatternGradient,
      wallpaperPatternLocations: parseNumberArray(raw["wallpaperPatternLocations"]),
      wallpaperPatternOpacity: CGFloat(
        (raw["wallpaperPatternOpacity"] as? NSNumber)?.doubleValue ?? 0.0),
      wallpaperMaskKey: normalizedString(raw["wallpaperMaskKey"]),
      bubbleMeGradient: bubbleMeGradient,
      bubbleThemGradient: bubbleThemGradient,
      bubbleThemColor: bubbleThemColor,
      textColorMe: textColorMe,
      textColorThem: textColorThem,
      timeColorMe: parseColor(raw["timeColorMe"] as? String) ?? fallback.timeColorMe,
      timeColorThem: parseColor(raw["timeColorThem"] as? String)
        ?? colorWithAlpha(textColorThem, isDark ? 0.62 : 0.56),
      dayTextColor: parseColor(raw["dayTextColor"] as? String)
        ?? colorWithAlpha(textColorThem, isDark ? 0.90 : 0.84),
      dayBackgroundColor: parseColor(raw["dayBackgroundColor"] as? String)
        ?? colorWithAlpha(dayPlateBase, isDark ? 0.84 : 0.76),
      dayBorderColor: parseColor(raw["dayBorderColor"] as? String)
        ?? colorWithAlpha(textColorThem, isDark ? 0.08 : 0.10),
      insertionAnimationMode: (raw["insertionAnimationMode"] as? NSNumber)?.intValue
        ?? fallback.insertionAnimationMode
    )
  }

  var visualKey: String {
    let wallpaperKey = wallpaperGradient.map(colorKey).joined(separator: ",")
    let wallpaperPatternKey = wallpaperPatternGradient.map(colorKey).joined(separator: ",")
    let wallpaperPatternLocationsKey =
      wallpaperPatternLocations?.map { String(format: "%.4f", $0.doubleValue) }.joined(
        separator: ",")
      ?? ""
    let meKey = bubbleMeGradient.map(colorKey).joined(separator: ",")
    let themKey = bubbleThemGradient.map(colorKey).joined(separator: ",")
    return [
      backgroundMode,
      String(format: "%.4f", wallpaperOpacity),
      wallpaperKey,
      wallpaperPatternKey,
      wallpaperPatternLocationsKey,
      String(format: "%.4f", wallpaperPatternOpacity),
      wallpaperMaskKey ?? "",
      meKey,
      themKey,
      colorKey(bubbleThemColor),
      colorKey(textColorMe),
      colorKey(textColorThem),
      colorKey(timeColorMe),
      colorKey(timeColorThem),
      colorKey(dayTextColor),
      colorKey(dayBackgroundColor),
      colorKey(dayBorderColor),
    ].joined(separator: "|")
  }

  /// Derives whether this appearance is "dark" by inspecting
  /// the luminance of the primary wallpaper gradient colour.
  var isDark: Bool {
    guard let firstColor = wallpaperGradient.first else { return true }
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    if firstColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
      let luminance = 0.299 * r + 0.587 * g + 0.114 * b
      return luminance < 0.5
    }
    return true
  }

  var hasPatternWallpaper: Bool {
    backgroundMode != "transparent"
      && wallpaperPatternGradient.count >= 2
      && wallpaperPatternOpacity > 0.001
      && (wallpaperMaskKey?.isEmpty == false)
  }

  var wallpaperAnchorColor: UIColor {
    let wallFirst = wallpaperGradient.first ?? (isDark ? UIColor.black : UIColor.white)
    let wallLast = wallpaperGradient.last ?? wallFirst
    return blendColor(wallFirst, with: wallLast, amount: 0.42)
  }

  var incomingBasePlateColor: UIColor {
    blendColor(
      bubbleThemGradient.first ?? bubbleThemColor,
      with: bubbleThemGradient.last ?? bubbleThemColor,
      amount: 0.5
    )
  }

  var outgoingBasePlateColor: UIColor {
    blendColor(
      bubbleMeGradient.first ?? bubbleThemColor,
      with: bubbleMeGradient.last ?? bubbleThemColor,
      amount: 0.5
    )
  }

  var incomingWallpaperSampleOpacity: CGFloat {
    guard backgroundMode != "transparent" else { return 0.0 }
    if hasPatternWallpaper {
      return isDark ? 0.10 : 0.08
    }
    return isDark ? 0.04 : 0.03
  }

  var outgoingWallpaperSampleOpacity: CGFloat {
    guard backgroundMode != "transparent" else { return 0.0 }
    if hasPatternWallpaper {
      return isDark ? 0.06 : 0.05
    }
    return isDark ? 0.03 : 0.02
  }

  var incomingPlateFillOpacity: CGFloat {
    if hasPatternWallpaper {
      return isDark ? 0.985 : 0.98
    }
    if backgroundMode != "transparent" {
      return isDark ? 0.985 : 0.98
    }
    return isDark ? 0.90 : 0.94
  }

  var outgoingPlateFillOpacity: CGFloat {
    if hasPatternWallpaper {
      return isDark ? 0.985 : 0.98
    }
    if backgroundMode != "transparent" {
      return isDark ? 0.99 : 0.985
    }
    return 0.0
  }

  private var wallpaperToneSamplingData: (colors: [UIColor], locations: [CGFloat]) {
    if hasPatternWallpaper, wallpaperPatternGradient.count >= 2 {
      return normalizedGradientSamplingData(
        colors: wallpaperPatternGradient,
        locations: wallpaperPatternLocations
      )
    }
    return normalizedGradientSamplingData(colors: wallpaperGradient, locations: nil)
  }

  func wallpaperPlateColor(
    isMe: Bool,
    sampleRect: CGRect,
    containerSize: CGSize
  ) -> UIColor {
    let baseColor = isMe ? outgoingBasePlateColor : incomingBasePlateColor
    guard backgroundMode != "transparent" else {
      return baseColor
    }

    let samplePoint = CGPoint(x: sampleRect.midX, y: sampleRect.midY)
    let wallpaperColor = wallpaperToneColor(at: samplePoint, containerSize: containerSize)
    if isMe {
      let tinted = blendColor(
        baseColor,
        with: wallpaperColor,
        amount: hasPatternWallpaper ? (isDark ? 0.18 : 0.14) : (isDark ? 0.08 : 0.05)
      )
      return blendColor(
        tinted,
        with: UIColor.black,
        amount: hasPatternWallpaper ? (isDark ? 0.12 : 0.06) : (isDark ? 0.08 : 0.03)
      )
    }

    let darkerIncomingReference = blendColor(
      bubbleThemGradient.first ?? bubbleThemColor,
      with: bubbleThemGradient.last ?? bubbleThemColor,
      amount: 0.82
    )
    let isolatedIncomingBase = blendColor(
      baseColor,
      with: darkerIncomingReference,
      amount: hasPatternWallpaper ? 0.76 : 0.58
    )
    let anchoredIncomingWallpaper = blendColor(
      wallpaperColor,
      with: wallpaperAnchorColor,
      amount: hasPatternWallpaper ? 0.68 : 0.80
    )
    let tinted = blendColor(
      isolatedIncomingBase,
      with: anchoredIncomingWallpaper,
      amount: hasPatternWallpaper ? (isDark ? 0.13 : 0.10) : (isDark ? 0.06 : 0.04)
    )
    let harmonized = blendColor(
      tinted,
      with: darkerIncomingReference,
      amount: hasPatternWallpaper ? 0.18 : 0.10
    )
    return blendColor(
      harmonized,
      with: UIColor.black,
      amount: hasPatternWallpaper ? (isDark ? 0.26 : 0.15) : (isDark ? 0.15 : 0.08)
    )
  }

  private func wallpaperToneColor(at point: CGPoint, containerSize: CGSize) -> UIColor {
    guard containerSize.width > 1.0, containerSize.height > 1.0 else {
      return wallpaperAnchorColor
    }
    let normalizedX = clampUnit(point.x / containerSize.width)
    let normalizedY = clampUnit(point.y / containerSize.height)
    let diagonalProgress = clampUnit((normalizedX * 0.38) + (normalizedY * 0.62))
    let samplingData = wallpaperToneSamplingData
    return interpolatedGradientColor(
      colors: samplingData.colors,
      locations: samplingData.locations,
      at: diagonalProgress
    )
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
  let insertionAnimationMode =
    (raw["insertionAnimationMode"] as? NSNumber)?.intValue ?? fallback.insertionAnimationMode

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

  let wallpaperGradient = parseGradient(
    (raw["wallpaperGradient"] as? [String]) ?? resolvedBackgroundGradient,
    fallback: fallback.wallpaperGradient)
  let patternGradient = parseGradient(
    (raw["wallpaperPatternGradient"] as? [String]) ?? resolvedPatternGradientColors,
    fallback: [])
  let bubbleMeGradient = parseGradient(
    (raw["bubbleMeGradient"] as? [String]) ?? variant.bubbleMeGradient,
    fallback: fallback.bubbleMeGradient)
  let rawBubbleThemColor =
    parseColor(raw["bubbleThemColor"] as? String)
    ?? parseColor(variant.bubbleThemGradient.first)
    ?? parseColor(variant.bubbleThem)
    ?? fallback.bubbleThemColor
  let textColorMe = parseColor(raw["textColorMe"] as? String) ?? parseColor(variant.textColorMe)
    ?? fallback.textColorMe
  let textColorThem =
    parseColor(raw["textColorThem"] as? String) ?? parseColor(variant.textColorThem)
    ?? fallback.textColorThem
  let dayPlateBase = resolvedDayPlateBase(
    bubbleThemColor: rawBubbleThemColor,
    wallpaperGradient: wallpaperGradient,
    isDark: isDark
  )
  return ChatListAppearance(
    backgroundMode: mode,
    wallpaperGradient: wallpaperGradient,
    wallpaperOpacity: wallpaperOpacity,
    wallpaperPatternGradient: patternGradient,
    wallpaperPatternLocations: parseNumberArray(raw["wallpaperPatternLocations"])
      ?? variant.patternGradientLocations.map { NSNumber(value: $0) },
    wallpaperPatternOpacity: CGFloat(
      (raw["wallpaperPatternOpacity"] as? NSNumber)?.doubleValue ?? resolvedPatternOpacity),
    wallpaperMaskKey: normalizedString(raw["wallpaperMaskKey"]) ?? preset.maskedImage,
    bubbleMeGradient: bubbleMeGradient,
    bubbleThemGradient: parseGradient(
      raw["bubbleThemGradient"] as? [String],
      fallback: variant.bubbleThemGradient.compactMap(parseColor)
    ),
    bubbleThemColor: rawBubbleThemColor,
    textColorMe: textColorMe,
    textColorThem: textColorThem,
    timeColorMe: parseColor(raw["timeColorMe"] as? String) ?? colorWithAlpha(textColorMe, 0.72),
    timeColorThem: parseColor(raw["timeColorThem"] as? String)
      ?? colorWithAlpha(textColorThem, isDark ? 0.62 : 0.56),
    dayTextColor: parseColor(raw["dayTextColor"] as? String)
      ?? colorWithAlpha(textColorThem, isDark ? 0.90 : 0.84),
    dayBackgroundColor: parseColor(raw["dayBackgroundColor"] as? String)
      ?? colorWithAlpha(dayPlateBase, isDark ? 0.84 : 0.76),
    dayBorderColor: parseColor(raw["dayBorderColor"] as? String)
      ?? colorWithAlpha(textColorThem, isDark ? 0.08 : 0.10),
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

private func resolvedDayPlateBase(
  bubbleThemColor: UIColor,
  wallpaperGradient: [UIColor],
  isDark: Bool
) -> UIColor {
  let wallFirst = wallpaperGradient.first ?? (isDark ? UIColor.black : UIColor.white)
  let wallLast = wallpaperGradient.last ?? wallFirst
  let wallpaperAnchor = blendColor(wallFirst, with: wallLast, amount: 0.38)
  return blendColor(bubbleThemColor, with: wallpaperAnchor, amount: isDark ? 0.14 : 0.08)
}

private func softenedBubblePalette(
  bubbleMeGradient: [UIColor],
  bubbleThemColor: UIColor,
  wallpaperGradient: [UIColor],
  isDark: Bool
) -> (me: [UIColor], them: UIColor) {
  let wallFirst = wallpaperGradient.first ?? (isDark ? UIColor.black : UIColor.white)
  let wallLast = wallpaperGradient.last ?? wallFirst
  let wallpaperAnchor = blendColor(wallFirst, with: wallLast, amount: 0.36)

  let softenedMe = bubbleMeGradient.map { color in
    let contrast = contrastRatio(color, wallpaperAnchor)
    let extra = max(0.0, min(0.12, (contrast - (isDark ? 4.2 : 3.8)) * 0.05))
    let mix = (isDark ? 0.12 : 0.10) + extra
    let base = blendColor(color, with: wallpaperAnchor, amount: mix)
    return colorWithAlpha(base, 0.96)
  }

  let themContrast = contrastRatio(bubbleThemColor, wallpaperAnchor)
  let themExtra = max(0.0, min(0.14, (themContrast - (isDark ? 2.6 : 2.2)) * 0.07))
  let themMix = (isDark ? 0.12 : 0.09) + themExtra
  var softenedThem = blendColor(bubbleThemColor, with: wallpaperAnchor, amount: themMix)
  softenedThem = colorWithAlpha(softenedThem, isDark ? 0.94 : 0.96)

  return (me: softenedMe, them: softenedThem)
}

private func blendColor(_ from: UIColor, with to: UIColor, amount: CGFloat) -> UIColor {
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

  let inv = 1.0 - t
  return UIColor(
    red: (fr * inv) + (tr * t),
    green: (fg * inv) + (tg * t),
    blue: (fb * inv) + (tb * t),
    alpha: (fa * inv) + (ta * t)
  )
}

private func clampUnit(_ value: CGFloat) -> CGFloat {
  min(1.0, max(0.0, value))
}

private func normalizedGradientSamplingData(
  colors: [UIColor],
  locations: [NSNumber]?
) -> (colors: [UIColor], locations: [CGFloat]) {
  guard !colors.isEmpty else {
    return ([.black], [0.0])
  }

  if colors.count == 1 {
    return (colors, [0.0])
  }

  let resolvedLocations: [CGFloat] = {
    if let locations, locations.count == colors.count {
      var lastValue: CGFloat = 0.0
      return locations.enumerated().map { index, value in
        let clamped = clampUnit(CGFloat(truncating: value))
        let monotonic = index == 0 ? clamped : max(lastValue, clamped)
        lastValue = monotonic
        return monotonic
      }
    }

    return (0..<colors.count).map { index in
      CGFloat(index) / CGFloat(max(colors.count - 1, 1))
    }
  }()

  switch colors.count {
  case 2:
    let start = resolvedLocations[0]
    let end = resolvedLocations[1]
    return (
      [
        colors[0],
        blendColor(colors[0], with: colors[1], amount: 0.25),
        blendColor(colors[0], with: colors[1], amount: 0.50),
        blendColor(colors[0], with: colors[1], amount: 0.75),
        colors[1],
      ],
      [
        start,
        start + ((end - start) * 0.25),
        start + ((end - start) * 0.50),
        start + ((end - start) * 0.75),
        end,
      ]
    )
  case 3:
    let start = resolvedLocations[0]
    let middle = resolvedLocations[1]
    let end = resolvedLocations[2]
    return (
      [
        colors[0],
        blendColor(colors[0], with: colors[1], amount: 0.5),
        colors[1],
        blendColor(colors[1], with: colors[2], amount: 0.5),
        colors[2],
      ],
      [
        start,
        start + ((middle - start) * 0.5),
        middle,
        middle + ((end - middle) * 0.5),
        end,
      ]
    )
  case 4:
    let middleLocation = resolvedLocations[1] + ((resolvedLocations[2] - resolvedLocations[1]) * 0.5)
    return (
      [
        colors[0],
        colors[1],
        blendColor(colors[1], with: colors[2], amount: 0.5),
        colors[2],
        colors[3],
      ],
      [
        resolvedLocations[0],
        resolvedLocations[1],
        middleLocation,
        resolvedLocations[2],
        resolvedLocations[3],
      ]
    )
  default:
    return (colors, resolvedLocations)
  }
}

private func interpolatedGradientColor(
  colors: [UIColor],
  locations: [CGFloat]? = nil,
  at progress: CGFloat
) -> UIColor {
  guard !colors.isEmpty else { return .black }
  if colors.count == 1 { return colors[0] }

  let clamped = clampUnit(progress)
  let resolvedLocations: [CGFloat] = {
    if let locations, locations.count == colors.count {
      return locations
    }
    return (0..<colors.count).map { index in
      CGFloat(index) / CGFloat(max(colors.count - 1, 1))
    }
  }()

  if clamped <= resolvedLocations[0] {
    return colors[0]
  }
  if clamped >= resolvedLocations[colors.count - 1] {
    return colors[colors.count - 1]
  }

  for index in 0..<(colors.count - 1) {
    let start = resolvedLocations[index]
    let end = resolvedLocations[index + 1]
    guard clamped >= start, clamped <= end else { continue }
    let distance = max(end - start, 0.0001)
    let localT = clampUnit((clamped - start) / distance)
    return blendColor(colors[index], with: colors[index + 1], amount: localT)
  }

  return colors[colors.count - 1]
}

private func isDarkColor(_ color: UIColor) -> Bool {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return true }
  let luminance = 0.299 * r + 0.587 * g + 0.114 * b
  return luminance < 0.5
}

private func contrastRatio(_ c1: UIColor, _ c2: UIColor) -> CGFloat {
  let l1 = relativeLuminance(c1)
  let l2 = relativeLuminance(c2)
  let hi = max(l1, l2)
  let lo = min(l1, l2)
  return (hi + 0.05) / (lo + 0.05)
}

private func relativeLuminance(_ color: UIColor) -> CGFloat {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0.0 }

  func linear(_ value: CGFloat) -> CGFloat {
    if value <= 0.03928 { return value / 12.92 }
    return pow((value + 0.055) / 1.055, 2.4)
  }

  let lr = linear(r)
  let lg = linear(g)
  let lb = linear(b)
  return (0.2126 * lr) + (0.7152 * lg) + (0.0722 * lb)
}

private func colorWithAlpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var currentAlpha: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &currentAlpha) {
    return UIColor(red: r, green: g, blue: b, alpha: max(0.0, min(1.0, alpha)))
  }
  if let converted = color.cgColor.converted(
    to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
    let components = converted.components
  {
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
  if let converted = color.cgColor.converted(
    to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
    let components = converted.components
  {
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

  let r = CGFloat((rgba & 0xFF00_0000) >> 24) / 255.0
  let g = CGFloat((rgba & 0x00FF_0000) >> 16) / 255.0
  let b = CGFloat((rgba & 0x0000_FF00) >> 8) / 255.0
  let a = CGFloat(rgba & 0x0000_00FF) / 255.0
  return UIColor(red: r, green: g, blue: b, alpha: a)
}

private func parseRgbColor(_ value: String) -> UIColor? {
  guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close
  else {
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
