package com.mohammadshayani.vibe.ui

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat

enum class AppAppearanceOption(
  val rawValue: String,
  val title: String,
) {
  SYSTEM("system", "System"),
  LIGHT("light", "Light"),
  DARK("dark", "Dark");

  companion object {
    fun from(value: String?): AppAppearanceOption {
      return entries.firstOrNull { it.rawValue == value } ?: SYSTEM
    }
  }
}

object AppAppearanceController {
  const val storageKey = "vibe.app.appearance"
  private const val prefsName = "vibe_app_preferences"

  fun current(context: Context): AppAppearanceOption {
    val raw = prefs(context).getString(storageKey, AppAppearanceOption.SYSTEM.rawValue)
    return AppAppearanceOption.from(raw)
  }

  fun setOption(context: Context, option: AppAppearanceOption) {
    prefs(context).edit().putString(storageKey, option.rawValue).apply()
    applyStoredPreference(context)
  }

  fun applyStoredPreference(context: Context) {
    val mode =
      when (current(context)) {
        AppAppearanceOption.SYSTEM -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
        AppAppearanceOption.LIGHT -> AppCompatDelegate.MODE_NIGHT_NO
        AppAppearanceOption.DARK -> AppCompatDelegate.MODE_NIGHT_YES
      }
    AppCompatDelegate.setDefaultNightMode(mode)
    NativeChatThemeBridge.sync(context)
  }

  fun resolvedIsDark(context: Context): Boolean {
    return when (current(context)) {
      AppAppearanceOption.LIGHT -> false
      AppAppearanceOption.DARK -> true
      AppAppearanceOption.SYSTEM -> isNightMode(context)
    }
  }

  private fun prefs(context: Context) =
    context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
}

enum class AppThemePlateOption(
  val rawValue: String,
  val title: String,
) {
  GLACIER("glacier", "Glacier"),
  ZEN("zen", "Zen"),
  OCEAN("ocean", "Ocean"),
  OBSIDIAN("obsidian", "Obsidian");

  companion object {
    fun from(value: String?): AppThemePlateOption {
      return entries.firstOrNull { it.rawValue == value } ?: GLACIER
    }
  }
}

object AppThemePlateController {
  const val storageKey = "vibe.app.themePlate"
  private const val prefsName = "vibe_app_preferences"

  fun current(context: Context): AppThemePlateOption {
    val raw = prefs(context).getString(storageKey, AppThemePlateOption.GLACIER.rawValue)
    return AppThemePlateOption.from(raw)
  }

  fun setOption(context: Context, option: AppThemePlateOption) {
    prefs(context).edit().putString(storageKey, option.rawValue).apply()
    NativeChatThemeBridge.sync(context)
  }

  private fun prefs(context: Context) =
    context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
}

data class AppThemePalette(
  val isDark: Boolean,
  val backgroundColor: Int,
  val secondaryBackgroundColor: Int,
  val cardColor: Int,
  val inputColor: Int,
  val elevatedColor: Int,
  val textColor: Int,
  val secondaryTextColor: Int,
  val tertiaryTextColor: Int,
  val accentColor: Int,
  val accentMutedColor: Int,
  val buttonColor: Int,
  val buttonTextColor: Int,
  val bubbleMeColor: Int,
  val bubbleThemColor: Int,
  val borderColor: Int,
  val dividerColor: Int,
  val overlayColor: Int,
  val successColor: Int,
  val warningColor: Int,
  val dangerColor: Int,
)

fun resolveAppThemePalette(
  context: Context,
  plate: AppThemePlateOption = AppThemePlateController.current(context),
): AppThemePalette {
  val isDark = AppAppearanceController.resolvedIsDark(context)
  val baseBackground = if (isDark) colorHex(0x121212) else colorHex(0xF5F4F1)
  val baseSecondaryBackground = if (isDark) colorHex(0x151515) else colorHex(0xF5F4F1)
  val baseCard = if (isDark) colorHex(0x242424) else colorHex(0xFFFFFF)
  val baseInput = if (isDark) colorHex(0x222222) else colorHex(0xF2F2F2)
  val baseElevated = if (isDark) colorHex(0x252530) else colorHex(0xFFFFFF)
  val text = if (isDark) colorHex(0xE8E6F0) else colorHex(0x1A1A1F)
  val secondaryText = if (isDark) colorHex(0x9896A8) else colorHex(0x5A5A66)
  val tertiaryText = if (isDark) colorHex(0x5D5B6B) else colorHex(0x9A9AA3)

  val accent: Int
  val accentMuted: Int
  val button: Int
  val bubbleMe: Int
  val bubbleThem: Int

  when (plate) {
    AppThemePlateOption.GLACIER ->
      if (isDark) {
        accent = colorHex(0x2A8585)
        accentMuted = colorRgba(42, 133, 133, 0.6f)
        button = colorHex(0x2A8585)
        bubbleMe = colorHex(0x2A8585)
        bubbleThem = colorHex(0x24242C)
      } else {
        accent = colorHex(0x00838F)
        accentMuted = colorRgba(0, 131, 143, 0.6f)
        button = colorHex(0x00838F)
        bubbleMe = colorHex(0x00838F)
        bubbleThem = colorHex(0xFFFFFF)
      }

    AppThemePlateOption.ZEN ->
      if (isDark) {
        accent = colorHex(0x7C3AED)
        accentMuted = colorRgba(124, 58, 237, 0.6f)
        button = colorHex(0x7C3AED)
        bubbleMe = colorHex(0x7C3AED)
        bubbleThem = colorHex(0x2B2335)
      } else {
        accent = colorHex(0x3F51B5)
        accentMuted = colorRgba(63, 81, 181, 0.6f)
        button = colorHex(0x3F51B5)
        bubbleMe = colorHex(0x3F51B5)
        bubbleThem = colorHex(0xF3F4FB)
      }

    AppThemePlateOption.OCEAN ->
      if (isDark) {
        accent = colorHex(0x3A7DA8)
        accentMuted = colorRgba(58, 125, 168, 0.6f)
        button = colorHex(0x3A7DA8)
        bubbleMe = colorHex(0x3A7DA8)
        bubbleThem = colorHex(0x23313A)
      } else {
        accent = colorHex(0x0277BD)
        accentMuted = colorRgba(2, 119, 189, 0.6f)
        button = colorHex(0x0277BD)
        bubbleMe = colorHex(0x0277BD)
        bubbleThem = colorHex(0xFFFFFF)
      }

    AppThemePlateOption.OBSIDIAN ->
      if (isDark) {
        accent = colorHex(0x1565C0)
        accentMuted = colorRgba(21, 101, 192, 0.6f)
        button = colorHex(0x1565C0)
        bubbleMe = colorHex(0x1565C0)
        bubbleThem = colorHex(0x24242C)
      } else {
        accent = colorHex(0x1565C0)
        accentMuted = colorRgba(21, 101, 192, 0.6f)
        button = colorHex(0x1565C0)
        bubbleMe = colorHex(0x1565C0)
        bubbleThem = colorHex(0xFFFFFF)
      }
  }

  return AppThemePalette(
    isDark = isDark,
    backgroundColor = baseBackground,
    secondaryBackgroundColor = baseSecondaryBackground,
    cardColor = baseCard,
    inputColor = baseInput,
    elevatedColor = baseElevated,
    textColor = text,
    secondaryTextColor = secondaryText,
    tertiaryTextColor = tertiaryText,
    accentColor = accent,
    accentMutedColor = accentMuted,
    buttonColor = button,
    buttonTextColor = if (isDark) Color.WHITE else Color.WHITE,
    bubbleMeColor = bubbleMe,
    bubbleThemColor = bubbleThem,
    borderColor = if (isDark) colorRgba(255, 255, 255, 0.08f) else colorRgba(0, 0, 0, 0.08f),
    dividerColor = if (isDark) colorRgba(255, 255, 255, 0.08f) else colorRgba(0, 0, 0, 0.08f),
    overlayColor = if (isDark) colorRgba(0, 0, 0, 0.34f) else colorRgba(0, 0, 0, 0.12f),
    successColor = colorHex(0x34C759),
    warningColor = colorHex(0xFF9F0A),
    dangerColor = colorHex(0xFF3B30),
  )
}

internal fun buildNativeThemeSeed(context: Context): Map<String, Any> {
  return mapOf(
    "backgroundMode" to "gradient",
    "nativeThemeId" to AppThemePlateController.current(context).rawValue,
    "nativeThemeIsDark" to AppAppearanceController.resolvedIsDark(context),
  )
}

internal fun appThemeSignature(context: Context): String {
  return buildString {
    append(AppAppearanceController.current(context).rawValue)
    append('|')
    append(AppThemePlateController.current(context).rawValue)
    append('|')
    append(if (AppAppearanceController.resolvedIsDark(context)) "dark" else "light")
  }
}

internal fun applyThemedSystemBars(activity: Activity, palette: AppThemePalette) {
  WindowCompat.setDecorFitsSystemWindows(activity.window, false)
  activity.window.statusBarColor = Color.TRANSPARENT
  activity.window.navigationBarColor = palette.backgroundColor
  WindowInsetsControllerCompat(activity.window, activity.window.decorView).apply {
    isAppearanceLightStatusBars = !palette.isDark
    isAppearanceLightNavigationBars = !palette.isDark
  }
}

internal fun isNightMode(context: Context): Boolean {
  return (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
    Configuration.UI_MODE_NIGHT_YES
}

private object NativeChatThemeBridge {
  private const val prefsName = "vibe_chat_native"
  private const val themeIdKey = "chat_native_theme_id_v1"
  private const val themeIsDarkKey = "chat_native_theme_is_dark_v1"

  fun sync(context: Context) {
    context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
      .edit()
      .putString(themeIdKey, AppThemePlateController.current(context).rawValue)
      .putBoolean(themeIsDarkKey, AppAppearanceController.resolvedIsDark(context))
      .apply()
  }
}

internal fun colorHex(value: Int): Int {
  return Color.rgb(
    (value shr 16) and 0xFF,
    (value shr 8) and 0xFF,
    value and 0xFF,
  )
}

internal fun colorRgba(red: Int, green: Int, blue: Int, alpha: Float): Int {
  return Color.argb(
    (alpha.coerceIn(0f, 1f) * 255f).toInt(),
    red.coerceIn(0, 255),
    green.coerceIn(0, 255),
    blue.coerceIn(0, 255),
  )
}

internal fun adjustColor(color: Int, amount: Float): Int {
  val clamped = amount.coerceIn(-1f, 1f)
  val target = if (clamped >= 0f) Color.WHITE else Color.BLACK
  val ratio = kotlin.math.abs(clamped)
  return Color.argb(
    Color.alpha(color),
    (Color.red(color) + ((Color.red(target) - Color.red(color)) * ratio)).toInt().coerceIn(0, 255),
    (Color.green(color) + ((Color.green(target) - Color.green(color)) * ratio)).toInt().coerceIn(0, 255),
    (Color.blue(color) + ((Color.blue(target) - Color.blue(color)) * ratio)).toInt().coerceIn(0, 255),
  )
}
