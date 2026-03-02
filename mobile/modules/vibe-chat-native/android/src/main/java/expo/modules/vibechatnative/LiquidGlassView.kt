package expo.modules.vibechatnative

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.LinearGradient
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.drawable.Drawable
import android.os.Build
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import android.view.animation.OvershootInterpolator
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.views.ExpoView
import kotlin.math.max
import kotlin.math.min

@SuppressLint("ViewConstructor")
class LiquidGlassView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  private val glassDrawable = AndroidLiquidGlassDrawable(context)

  private var blurIntensity = 10.0
  private var blurReductionFactor = 4.0
  private var interactive = true
  private var effect: String = "regular"
  private var tint: String? = null
  private var tintColor: Int? = null
  private var pressFeedbackEnabled = true
  private var borderEnabled = true
  private var shadowEnabled = true
  private var cornerRadiusPx = 0f
  private var isPressedVisual = false

  init {
    orientation = VERTICAL
    setWillNotDraw(false)
    background = glassDrawable
    clipToPadding = false
    updateOutline()
    applyVisuals()
  }

  private fun updateOutline() {
    val radius = cornerRadiusPx
    outlineProvider = object : ViewOutlineProvider() {
      override fun getOutline(view: View, outline: Outline) {
        outline.setRoundRect(0, 0, view.width, view.height, radius)
      }
    }
    clipToOutline = radius > 0f
    invalidateOutline()
  }

  private fun isDarkMode(): Boolean {
    val mode = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
    return mode == Configuration.UI_MODE_NIGHT_YES
  }

  private fun applyVisuals() {
    val isDark = isDarkMode()
    val blurNormalized = (blurIntensity / max(1.0, blurReductionFactor * 4.0)).toFloat().coerceIn(0f, 1.6f)
    val regularEffect = effect != "clear"

    val baseTint = tintColor ?: defaultTintColor(isDark, tint)
    val fillAlpha = when {
      regularEffect && isDark -> 0.42f
      regularEffect && !isDark -> 0.54f
      isDark -> 0.24f
      else -> 0.34f
    }
    val fillStrength = (0.78f + blurNormalized * 0.08f).coerceIn(0.68f, 0.9f)

    val topFill =
      withAlpha(
        mix(baseTint, Color.WHITE, if (isDark) 0.04f else 0.10f),
        fillAlpha * fillStrength,
      )
    val bottomFill =
      withAlpha(
        mix(baseTint, if (isDark) Color.BLACK else 0xFFE8EEF8.toInt(), if (isDark) 0.08f else 0.10f),
        (fillAlpha - if (isDark) 0.02f else 0.03f) * fillStrength,
      )

    val sheenStart = if (isDark) Color.argb(14, 255, 255, 255) else Color.argb(48, 255, 255, 255)
    val sheenMid = if (isDark) Color.argb(6, 255, 255, 255) else Color.argb(18, 255, 255, 255)
    val sheenEnd = Color.TRANSPARENT

    val border = if (isDark) {
      Color.argb((24 + (blurNormalized * 14f).toInt()).coerceIn(16, 42), 255, 255, 255)
    } else {
      Color.argb((18 + (blurNormalized * 12f).toInt()).coerceIn(14, 36), 24, 32, 48)
    }
    val innerBorder = if (isDark) Color.argb(12, 255, 255, 255) else Color.argb(42, 255, 255, 255)
    val pressedOverlay = if (isDark) Color.argb(12, 255, 255, 255) else Color.argb(16, 255, 255, 255)

    glassDrawable.updateStyle(
      cornerRadiusPx = cornerRadiusPx,
      topFill = topFill,
      bottomFill = bottomFill,
      sheenStart = sheenStart,
      sheenMid = sheenMid,
      sheenEnd = sheenEnd,
      borderColor = if (borderEnabled) border else Color.TRANSPARENT,
      innerBorderColor = if (borderEnabled) innerBorder else Color.TRANSPARENT,
      pressedOverlayColor = pressedOverlay,
    )

    val elevationDp = when {
      !regularEffect -> 1f
      blurIntensity < 8 -> 3f
      blurIntensity < 16 -> 5f
      else -> 7f
    }
    elevation = if (shadowEnabled) dp(elevationDp) else 0f
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      outlineAmbientShadowColor =
        if (shadowEnabled) {
          if (isDark) Color.argb(110, 0, 0, 0) else Color.argb(60, 42, 55, 84)
        } else {
          Color.TRANSPARENT
        }
      outlineSpotShadowColor =
        if (shadowEnabled) {
          if (isDark) Color.argb(140, 0, 0, 0) else Color.argb(72, 42, 55, 84)
        } else {
          Color.TRANSPARENT
        }
    }
    invalidate()
  }

  private fun setPressedVisual(pressed: Boolean) {
    if (!interactive || !pressFeedbackEnabled) return
    if (isPressedVisual == pressed) return
    isPressedVisual = pressed
    val nextScale = if (pressed) 0.972f else 1f
    animate()
      .scaleX(nextScale)
      .scaleY(nextScale)
      .setDuration(if (pressed) 90L else 180L)
      .setInterpolator(if (pressed) null else OvershootInterpolator(0.5f))
      .start()
    glassDrawable.setPressedFraction(if (pressed) 1f else 0f)
  }

  override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
    when (ev.actionMasked) {
      MotionEvent.ACTION_DOWN -> setPressedVisual(true)
      MotionEvent.ACTION_MOVE -> {
        val inside = ev.x >= 0f && ev.y >= 0f && ev.x <= width.toFloat() && ev.y <= height.toFloat()
        setPressedVisual(inside)
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> setPressedVisual(false)
    }
    return super.dispatchTouchEvent(ev)
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    animate().cancel()
    isPressedVisual = false
    glassDrawable.setPressedFraction(0f)
    scaleX = 1f
    scaleY = 1f
  }

  fun setBlurIntensity(intensity: Double) {
    blurIntensity = intensity.coerceIn(0.0, 100.0)
    applyVisuals()
  }

  fun setBlurReductionFactor(factor: Double?) {
    blurReductionFactor = (factor ?: 4.0).coerceIn(1.0, 12.0)
    applyVisuals()
  }

  fun setInteractive(value: Boolean?) {
    interactive = value ?: true
    if (!interactive) {
      setPressedVisual(false)
    }
  }

  fun setPressFeedbackEnabled(value: Boolean?) {
    pressFeedbackEnabled = value ?: true
    if (!pressFeedbackEnabled) {
      setPressedVisual(false)
    }
  }

  fun setEffect(value: String?) {
    effect = if (value == "clear") "clear" else "regular"
    applyVisuals()
  }

  fun setTint(value: String?) {
    tint = value
    applyVisuals()
  }

  fun setTintColor(value: Int?) {
    tintColor = value
    applyVisuals()
  }

  fun setBorderEnabled(value: Boolean?) {
    borderEnabled = value ?: true
    applyVisuals()
  }

  fun setShadowEnabled(value: Boolean?) {
    shadowEnabled = value ?: true
    applyVisuals()
  }

  fun setCornerRadius(value: Double?) {
    cornerRadiusPx = if (value != null && value > 0) dp(value.toFloat()) else 0f
    updateOutline()
    applyVisuals()
  }

  private fun dp(value: Float): Float = value * resources.displayMetrics.density

  private fun defaultTintColor(isDark: Boolean, tint: String?): Int {
    return when (tint) {
      "dark" -> Color.rgb(20, 24, 30)
      "light" -> Color.rgb(248, 251, 255)
      "extraLight" -> Color.rgb(252, 254, 255)
      "prominent" -> if (isDark) Color.rgb(26, 30, 40) else Color.rgb(240, 247, 255)
      "regular" -> if (isDark) Color.rgb(22, 26, 34) else Color.rgb(245, 249, 255)
      else -> if (isDark) Color.rgb(21, 24, 31) else Color.rgb(246, 250, 255)
    }
  }
}

private class AndroidLiquidGlassDrawable(context: Context) : Drawable() {
  private val density = context.resources.displayMetrics.density
  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
  private val sheenPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
  private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = max(1f, density)
  }
  private val innerBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = max(0.75f, density * 0.75f)
  }
  private val pressedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
  private val path = Path()
  private val rect = RectF()
  private val insetRect = RectF()

  private var cornerRadiusPx = 0f
  private var topFill = Color.argb(220, 248, 251, 255)
  private var bottomFill = Color.argb(210, 235, 243, 255)
  private var sheenStart = Color.argb(140, 255, 255, 255)
  private var sheenMid = Color.argb(36, 255, 255, 255)
  private var sheenEnd = Color.TRANSPARENT
  private var borderColor = Color.argb(36, 0, 0, 0)
  private var innerBorderColor = Color.argb(100, 255, 255, 255)
  private var pressedOverlayColor = Color.argb(20, 255, 255, 255)
  private var pressedFraction = 0f

  fun updateStyle(
    cornerRadiusPx: Float,
    topFill: Int,
    bottomFill: Int,
    sheenStart: Int,
    sheenMid: Int,
    sheenEnd: Int,
    borderColor: Int,
    innerBorderColor: Int,
    pressedOverlayColor: Int,
  ) {
    this.cornerRadiusPx = cornerRadiusPx
    this.topFill = topFill
    this.bottomFill = bottomFill
    this.sheenStart = sheenStart
    this.sheenMid = sheenMid
    this.sheenEnd = sheenEnd
    this.borderColor = borderColor
    this.innerBorderColor = innerBorderColor
    this.pressedOverlayColor = pressedOverlayColor
    invalidateSelf()
  }

  fun setPressedFraction(value: Float) {
    pressedFraction = value.coerceIn(0f, 1f)
    invalidateSelf()
  }

  override fun draw(canvas: Canvas) {
    val b = bounds
    if (b.isEmpty) return

    rect.set(b.left.toFloat(), b.top.toFloat(), b.right.toFloat(), b.bottom.toFloat())
    val radius = max(0f, cornerRadiusPx)

    path.reset()
    path.addRoundRect(rect, radius, radius, Path.Direction.CW)

    fillPaint.shader = LinearGradient(
      rect.left,
      rect.top,
      rect.left,
      rect.bottom,
      topFill,
      bottomFill,
      Shader.TileMode.CLAMP,
    )

    val save = canvas.save()
    canvas.clipPath(path)
    canvas.drawRect(rect, fillPaint)

    sheenPaint.shader = LinearGradient(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      intArrayOf(sheenStart, sheenMid, sheenEnd),
      floatArrayOf(0f, 0.38f, 1f),
      Shader.TileMode.CLAMP,
    )
    canvas.drawRect(rect, sheenPaint)

    // Top highlight strip to mimic OneUI "liquid edge".
    val topBandHeight = min(rect.height() * 0.32f, 18f * density)
    if (topBandHeight > 0f) {
      sheenPaint.shader = LinearGradient(
        rect.left,
        rect.top,
        rect.left,
        rect.top + topBandHeight,
        intArrayOf(withAlpha(Color.WHITE, 0.18f), withAlpha(Color.WHITE, 0.06f), Color.TRANSPARENT),
        floatArrayOf(0f, 0.42f, 1f),
        Shader.TileMode.CLAMP,
      )
      canvas.drawRoundRect(
        rect.left + density,
        rect.top + density,
        rect.right - density,
        rect.top + topBandHeight,
        max(0f, radius - density),
        max(0f, radius - density),
        sheenPaint,
      )
    }

    if (pressedFraction > 0f) {
      pressedPaint.color = withAlpha(pressedOverlayColor, alphaFloat(pressedOverlayColor) * pressedFraction)
      canvas.drawRoundRect(rect, radius, radius, pressedPaint)
    }
    canvas.restoreToCount(save)

    borderPaint.color = borderColor
    canvas.drawRoundRect(
      rect.left + borderPaint.strokeWidth * 0.5f,
      rect.top + borderPaint.strokeWidth * 0.5f,
      rect.right - borderPaint.strokeWidth * 0.5f,
      rect.bottom - borderPaint.strokeWidth * 0.5f,
      max(0f, radius - borderPaint.strokeWidth * 0.5f),
      max(0f, radius - borderPaint.strokeWidth * 0.5f),
      borderPaint,
    )

    insetRect.set(rect)
    val inset = max(1f, density)
    insetRect.inset(inset, inset)
    innerBorderPaint.color = innerBorderColor
    canvas.drawRoundRect(
      insetRect,
      max(0f, radius - inset),
      max(0f, radius - inset),
      innerBorderPaint,
    )
  }

  override fun setAlpha(alpha: Int) {
    fillPaint.alpha = alpha
    sheenPaint.alpha = alpha
    borderPaint.alpha = alpha
    innerBorderPaint.alpha = alpha
    invalidateSelf()
  }

  override fun setColorFilter(colorFilter: ColorFilter?) {
    fillPaint.colorFilter = colorFilter
    sheenPaint.colorFilter = colorFilter
    borderPaint.colorFilter = colorFilter
    innerBorderPaint.colorFilter = colorFilter
    pressedPaint.colorFilter = colorFilter
    invalidateSelf()
  }

  @Deprecated("Deprecated in Java")
  override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}

private fun withAlpha(color: Int, alpha: Float): Int {
  val a = (alpha.coerceIn(0f, 1f) * 255f).toInt()
  return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
}

private fun alphaFloat(color: Int): Float = Color.alpha(color) / 255f

private fun mix(a: Int, b: Int, t: Float): Int {
  val clamped = t.coerceIn(0f, 1f)
  val ar = Color.red(a)
  val ag = Color.green(a)
  val ab = Color.blue(a)
  val aa = Color.alpha(a)
  val br = Color.red(b)
  val bg = Color.green(b)
  val bb = Color.blue(b)
  val ba = Color.alpha(b)
  return Color.argb(
    (aa + ((ba - aa) * clamped)).toInt(),
    (ar + ((br - ar) * clamped)).toInt(),
    (ag + ((bg - ag) * clamped)).toInt(),
    (ab + ((bb - ab) * clamped)).toInt(),
  )
}
