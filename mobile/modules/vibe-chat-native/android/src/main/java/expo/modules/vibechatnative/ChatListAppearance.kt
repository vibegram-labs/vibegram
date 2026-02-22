package expo.modules.vibechatnative

import android.graphics.Color
import kotlin.math.max
import kotlin.math.min

data class ChatListAppearance(
  val backgroundMode: String = "transparent",
  val wallpaperGradient: IntArray = intArrayOf(
    Color.argb(255, 26, 26, 46),
    Color.argb(255, 18, 18, 42),
  ),
  val wallpaperOpacity: Float = 1f,
  val bubbleMeGradient: IntArray = intArrayOf(
    Color.argb(255, 124, 92, 224),
    Color.argb(255, 106, 79, 207),
  ),
  val bubbleThemColor: Int = Color.argb(255, 43, 43, 74),
  val textColorMe: Int = Color.WHITE,
  val textColorThem: Int = Color.argb(255, 221, 221, 221),
  val timeColorMe: Int = Color.argb(184, 255, 255, 255),
  val timeColorThem: Int = Color.argb(128, 255, 255, 255),
  val dayTextColor: Int = Color.argb(210, 236, 239, 255),
  val dayBackgroundColor: Int = Color.argb(107, 20, 20, 34),
  val dayBorderColor: Int = Color.argb(41, 255, 255, 255),
) {
  fun visualEquals(other: ChatListAppearance): Boolean {
    return backgroundMode == other.backgroundMode &&
      wallpaperGradient.contentEquals(other.wallpaperGradient) &&
      wallpaperOpacity == other.wallpaperOpacity &&
      bubbleMeGradient.contentEquals(other.bubbleMeGradient) &&
      bubbleThemColor == other.bubbleThemColor &&
      textColorMe == other.textColorMe &&
      textColorThem == other.textColorThem &&
      timeColorMe == other.timeColorMe &&
      timeColorThem == other.timeColorThem &&
      dayTextColor == other.dayTextColor &&
      dayBackgroundColor == other.dayBackgroundColor &&
      dayBorderColor == other.dayBorderColor
  }

  companion object {
    fun from(raw: Map<String, Any?>?): ChatListAppearance {
      if (raw == null) return ChatListAppearance()

      val backgroundMode = raw["backgroundMode"] as? String ?: "transparent"
      val wallpaperGradient = parseGradient(raw["wallpaperGradient"] as? List<*>, ChatListAppearance().wallpaperGradient)
      val bubbleMeGradient = parseGradient(raw["bubbleMeGradient"] as? List<*>, ChatListAppearance().bubbleMeGradient)

      return ChatListAppearance(
        backgroundMode = backgroundMode,
        wallpaperGradient = wallpaperGradient,
        wallpaperOpacity = ((raw["wallpaperOpacity"] as? Number)?.toFloat() ?: 1f).coerceIn(0f, 1f),
        bubbleMeGradient = bubbleMeGradient,
        bubbleThemColor = parseColor(raw["bubbleThemColor"] as? String) ?: ChatListAppearance().bubbleThemColor,
        textColorMe = parseColor(raw["textColorMe"] as? String) ?: ChatListAppearance().textColorMe,
        textColorThem = parseColor(raw["textColorThem"] as? String) ?: ChatListAppearance().textColorThem,
        timeColorMe = parseColor(raw["timeColorMe"] as? String) ?: ChatListAppearance().timeColorMe,
        timeColorThem = parseColor(raw["timeColorThem"] as? String) ?: ChatListAppearance().timeColorThem,
        dayTextColor = parseColor(raw["dayTextColor"] as? String) ?: ChatListAppearance().dayTextColor,
        dayBackgroundColor = parseColor(raw["dayBackgroundColor"] as? String) ?: ChatListAppearance().dayBackgroundColor,
        dayBorderColor = parseColor(raw["dayBorderColor"] as? String) ?: ChatListAppearance().dayBorderColor,
      )
    }
  }
}

private fun parseGradient(values: List<*>?, fallback: IntArray): IntArray {
  if (values == null) return fallback
  val parsed = values.mapNotNull { parseColor(it as? String) }
  return if (parsed.size >= 2) parsed.toIntArray() else fallback
}

private fun parseColor(value: String?): Int? {
  if (value.isNullOrBlank()) return null
  val v = value.trim().lowercase()
  return try {
    when {
      v.startsWith("#") -> parseHexColor(v)
      v.startsWith("rgba(") -> parseRgba(v)
      v.startsWith("rgb(") -> parseRgb(v)
      else -> null
    }
  } catch (_: Throwable) {
    null
  }
}

private fun parseHexColor(value: String): Int? {
  // JS often sends #RRGGBBAA while Android Color.parseColor expects #AARRGGBB.
  if (value.length == 9 && value.startsWith("#")) {
    val rrggbbaa = value.substring(1)
    val aarrggbb = rrggbbaa.substring(6, 8) + rrggbbaa.substring(0, 6)
    return Color.parseColor("#$aarrggbb")
  }
  if (value.length == 5 && value.startsWith("#")) {
    // Convert #RGBA -> #AARRGGBB
    val rgba = value.substring(1)
    val r = "${rgba[0]}${rgba[0]}"
    val g = "${rgba[1]}${rgba[1]}"
    val b = "${rgba[2]}${rgba[2]}"
    val a = "${rgba[3]}${rgba[3]}"
    return Color.parseColor("#$a$r$g$b")
  }
  return Color.parseColor(value)
}

private fun parseRgb(value: String): Int? {
  val body = value.substringAfter("(", "").substringBeforeLast(")")
  val args = body.split(",").map { it.trim() }
  if (args.size != 3) return null
  val r = args[0].toFloatOrNull() ?: return null
  val g = args[1].toFloatOrNull() ?: return null
  val b = args[2].toFloatOrNull() ?: return null
  return Color.argb(
    255,
    min(255f, max(0f, r)).toInt(),
    min(255f, max(0f, g)).toInt(),
    min(255f, max(0f, b)).toInt(),
  )
}

private fun parseRgba(value: String): Int? {
  val body = value.substringAfter("(", "").substringBeforeLast(")")
  val args = body.split(",").map { it.trim() }
  if (args.size != 4) return null
  val r = args[0].toFloatOrNull() ?: return null
  val g = args[1].toFloatOrNull() ?: return null
  val b = args[2].toFloatOrNull() ?: return null
  val a = args[3].toFloatOrNull() ?: return null
  return Color.argb(
    (min(1f, max(0f, a)) * 255f).toInt(),
    min(255f, max(0f, r)).toInt(),
    min(255f, max(0f, g)).toInt(),
    min(255f, max(0f, b)).toInt(),
  )
}
