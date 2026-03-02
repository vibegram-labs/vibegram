package expo.modules.vibechatnative

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

class ChatPinnedBannerView(context: Context) : FrameLayout(context) {
  companion object {
    const val PREFERRED_HEIGHT_DP = 44
  }

  private val iconBubble = TextView(context)
  private val titleView = TextView(context)
  private val bodyView = TextView(context)
  private val textStack = LinearLayout(context)
  private val overlay = GradientDrawable()
  private val iconBackground = GradientDrawable()

  init {
    clipToOutline = true
    background = overlay
    setPadding(dp(10), dp(6), dp(12), dp(6))

    iconBubble.text = "\uD83D\uDCCC"
    iconBubble.gravity = Gravity.CENTER
    iconBubble.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    iconBubble.background = iconBackground
    addView(
      iconBubble,
      LayoutParams(dp(28), dp(28)).apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL },
    )

    textStack.orientation = LinearLayout.VERTICAL
    textStack.gravity = Gravity.CENTER_VERTICAL
    textStack.setPadding(dp(38), 0, 0, 0)
    addView(
      textStack,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

    titleView.setTypeface(Typeface.DEFAULT_BOLD)
    titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    titleView.maxLines = 1
    titleView.includeFontPadding = false
    textStack.addView(
      titleView,
      LinearLayout.LayoutParams(
        LayoutParams.MATCH_PARENT,
        LayoutParams.WRAP_CONTENT,
      ),
    )

    bodyView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    bodyView.maxLines = 1
    bodyView.includeFontPadding = false
    textStack.addView(
      bodyView,
      LinearLayout.LayoutParams(
        LayoutParams.MATCH_PARENT,
        LayoutParams.WRAP_CONTENT,
      ),
    )
  }

  fun configure(title: String, body: String) {
    titleView.text = title
    bodyView.text = body
  }

  fun applyTheme(textColor: Int, surfaceColor: Int, isDark: Boolean) {
    val overlayColor = if (isDark) withAlpha(surfaceColor, 0.32f) else withAlpha(surfaceColor, 0.22f)
    val borderColor = withAlpha(textColor, if (isDark) 0.14f else 0.1f)
    overlay.shape = GradientDrawable.RECTANGLE
    overlay.cornerRadius = dp(PREFERRED_HEIGHT_DP / 2).toFloat()
    overlay.setColor(overlayColor)
    overlay.setStroke(dp(1), borderColor)

    iconBackground.shape = GradientDrawable.RECTANGLE
    iconBackground.cornerRadius = dp(14).toFloat()
    iconBackground.setColor(withAlpha(surfaceColor, if (isDark) 0.42f else 0.28f))

    iconBubble.setTextColor(withAlpha(textColor, 0.94f))
    titleView.setTextColor(withAlpha(textColor, 0.96f))
    bodyView.setTextColor(withAlpha(textColor, 0.82f))
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).toInt().coerceIn(0, 255)
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).toInt()
  }
}
