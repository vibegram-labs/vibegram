package com.mohammadshayani.vibe.home

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

internal class ChatHomeUndoBannerView(context: Context) : FrameLayout(context) {
  companion object {
    const val PREFERRED_HEIGHT_DP = 58f
  }

  private val iconView = TextView(context)
  private val textColumn = LinearLayout(context)
  private val titleView = TextView(context)
  private val bodyView = TextView(context)
  private val actionColumn = LinearLayout(context)
  private val actionPill = TextView(context)
  private val timerView = TextView(context)
  private var isDestructive = true

  init {
    layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, dp(PREFERRED_HEIGHT_DP))
    minimumHeight = dp(PREFERRED_HEIGHT_DP)
    foregroundGravity = Gravity.CENTER_VERTICAL
    setPadding(dp(10f), dp(8f), dp(12f), dp(8f))
    clipToOutline = true
    elevation = dp(4f).toFloat()

    val row = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }
    addView(row)

    iconView.layoutParams = LinearLayout.LayoutParams(dp(30f), dp(30f))
    iconView.gravity = Gravity.CENTER
    iconView.textSize = 15f
    row.addView(iconView)

    textColumn.orientation = LinearLayout.VERTICAL
    textColumn.gravity = Gravity.CENTER_VERTICAL
    textColumn.layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply {
      marginStart = dp(10f)
      marginEnd = dp(10f)
    }
    row.addView(textColumn)

    titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    titleView.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    titleView.maxLines = 1
    textColumn.addView(titleView)

    bodyView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    bodyView.maxLines = 1
    textColumn.addView(bodyView)

    actionColumn.orientation = LinearLayout.VERTICAL
    actionColumn.gravity = Gravity.END or Gravity.CENTER_VERTICAL
    actionColumn.layoutParams = LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
    row.addView(actionColumn)

    actionPill.minWidth = dp(66f)
    actionPill.gravity = Gravity.CENTER
    actionPill.setPadding(dp(12f), dp(7f), dp(12f), dp(7f))
    actionPill.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    actionPill.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    actionColumn.addView(actionPill)

    timerView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    timerView.gravity = Gravity.END
    actionColumn.addView(timerView)
  }

  fun bind(
    title: String,
    body: String,
    actionTitle: String,
    timerText: String,
    destructive: Boolean,
    isDark: Boolean
  ) {
    isDestructive = destructive
    titleView.text = title
    bodyView.text = body
    actionPill.text = actionTitle
    timerView.text = timerText
    iconView.text = if (destructive) "\u21B6" else "\u2713"

    val baseTextColor = if (isDark) Color.WHITE else Color.rgb(22, 28, 36)
    val accentColor = if (destructive) Color.rgb(237, 61, 64) else Color.rgb(54, 127, 237)
    background = roundedDrawable(
      fillColor = if (isDark) Color.argb(232, 26, 29, 36) else Color.argb(242, 248, 249, 252),
      strokeColor = if (isDark) Color.argb(30, 255, 255, 255) else Color.argb(18, 22, 28, 36),
      radiusDp = 29f,
      strokeWidthDp = 1f,
    )
    iconView.background = roundedDrawable(
      fillColor = adjustAlpha(accentColor, if (isDark) 0.24f else 0.14f),
      radiusDp = 15f,
    )
    iconView.setTextColor(accentColor)
    titleView.setTextColor(adjustAlpha(baseTextColor, 0.96f))
    bodyView.setTextColor(adjustAlpha(baseTextColor, 0.76f))
    actionPill.background = roundedDrawable(
      fillColor = adjustAlpha(accentColor, if (isDark) 0.22f else 0.13f),
      strokeColor = adjustAlpha(accentColor, if (isDark) 0.26f else 0.16f),
      radiusDp = 15f,
      strokeWidthDp = 1f,
    )
    actionPill.setTextColor(accentColor)
    timerView.setTextColor(adjustAlpha(baseTextColor, 0.66f))
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      resources.displayMetrics,
    ).toInt()

  private fun roundedDrawable(
    fillColor: Int,
    strokeColor: Int = Color.TRANSPARENT,
    radiusDp: Float,
    strokeWidthDp: Float = 0f,
  ): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = dp(radiusDp).toFloat()
      setColor(fillColor)
      if (strokeWidthDp > 0f) {
        setStroke(dp(strokeWidthDp), strokeColor)
      }
    }
  }

  private fun adjustAlpha(color: Int, alpha: Float): Int {
    val clampedAlpha = (alpha.coerceIn(0f, 1f) * 255f).toInt()
    return Color.argb(clampedAlpha, Color.red(color), Color.green(color), Color.blue(color))
  }
}
