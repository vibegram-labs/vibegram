package expo.modules.vibechatnative

import android.content.Context
import android.graphics.PorterDuff
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

internal class ChatMainProfileActionNode(
  context: Context,
) : FrameLayout(context) {
  private val stack = LinearLayout(context)
  private val iconView = ImageView(context)
  private val titleView = TextView(context)
  private val pressedOverlay = FrameLayout(context)

  private var iconResId: Int = 0

  init {
    clipToOutline = false
    clipChildren = true
    clipToPadding = false

    stack.orientation = LinearLayout.VERTICAL
    stack.gravity = Gravity.CENTER
    addView(
      stack,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

    iconView.scaleType = ImageView.ScaleType.CENTER_INSIDE
    stack.addView(
      iconView,
      LinearLayout.LayoutParams(dp(22), dp(22)),
    )

    titleView.setTypeface(Typeface.DEFAULT, Typeface.NORMAL)
    titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    titleView.setPadding(0, dp(5), 0, 0)
    stack.addView(
      titleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    pressedOverlay.alpha = 0f
    addView(
      pressedOverlay,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )
  }

  fun configure(title: String, iconRes: Int) {
    setTitle(title)
    setIcon(iconRes)
  }

  fun setTitle(title: String) {
    titleView.text = title
  }

  fun setIcon(iconRes: Int) {
    iconResId = iconRes
    iconView.setImageResource(iconRes)
  }

  fun applyTheme(foreground: Int, background: Int) {
    titleView.setTextColor(foreground)
    if (iconResId != 0) {
      iconView.setImageResource(iconResId)
    }
    iconView.setColorFilter(foreground, PorterDuff.Mode.SRC_IN)
    this.background = roundedShape(background, dp(16))
    pressedOverlay.setBackgroundColor(withAlpha(foreground, 0.08f))
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        scaleX = 0.97f
        scaleY = 0.97f
        pressedOverlay.alpha = 1f
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_OUTSIDE -> {
        scaleX = 1f
        scaleY = 1f
        pressedOverlay.alpha = 0f
      }
    }
    return super.onTouchEvent(event)
  }

  private fun roundedShape(color: Int, radiusPx: Int) = GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = radiusPx.toFloat()
    setColor(color)
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).toInt().coerceIn(0, 255)
    return android.graphics.Color.argb(
      a,
      android.graphics.Color.red(color),
      android.graphics.Color.green(color),
      android.graphics.Color.blue(color),
    )
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).toInt()
  }
}
