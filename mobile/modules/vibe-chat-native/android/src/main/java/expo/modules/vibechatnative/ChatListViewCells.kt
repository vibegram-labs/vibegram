package expo.modules.vibechatnative

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

internal class NativeRowViewHolder(
  val container: FrameLayout,
  val bubbleContainer: FrameLayout,
  val tailView: BubbleTailView,
  val textView: TextView,
  val inlineAttachmentView: FrameLayout,
  val inlineAttachmentTitleView: TextView,
  val inlineAttachmentSubtitleView: TextView,
  val voiceContainer: FrameLayout,
  val voiceButton: VoicePlayProgressView,
  val voiceWaveView: VoiceWaveformView,
  val voiceUploadProgressView: VoiceUploadProgressView,
  val voiceDurationView: TextView,
  val timeView: TextView,
  val statusView: BubbleStatusIndicatorView,
  val dayLabel: TextView,
  val agentSenderLabel: TextView,
) : RecyclerView.ViewHolder(container)

internal class BubbleTailView(context: Context) : View(context) {
  companion object {
    // Slightly softer than 25f on Android rasterization to avoid 1px seam artifacts.
    private const val TAIL_ROTATION_DEGREES = 24f
  }

  private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(255, 106, 79, 207)
  }
  private val path = Path()

  fun configure(isMe: Boolean, color: Int, visible: Boolean) {
    paint.color = color
    rotation = if (isMe) TAIL_ROTATION_DEGREES else -TAIL_ROTATION_DEGREES
    scaleX = if (isMe) 1f else -1f
    visibility = if (visible) View.VISIBLE else View.GONE
    invalidate()
  }

  override fun onDraw(canvas: Canvas) {
    if (visibility != View.VISIBLE) return
    path.reset()
    path.moveTo(0f, 0f)
    path.quadTo(-5f, 22f, 14f, 25f)
    path.quadTo(10.5f, 29f, 0f, 29f)
    path.close()

    canvas.save()
    val sx = width / 29f
    val sy = height / 29f
    canvas.scale(sx, sy)
    // Match iOS tail masking bounds to avoid exposing tiny rotated-edge artifacts.
    canvas.clipRect(-5f, 29f * 0.42f, 34f, 34f)
    canvas.drawPath(path, paint)
    canvas.restore()
  }
}

internal class BubbleStatusIndicatorView(context: Context) : View(context) {
  private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeJoin = Paint.Join.ROUND
    strokeWidth = dpF(1.35f)
    color = Color.WHITE
  }
  private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.WHITE
    textAlign = Paint.Align.CENTER
    textSize = dpF(10f)
  }
  private var status: String? = null
  private var baseColor: Int = Color.WHITE
  private val tmpPath = Path()

  fun bind(rawStatus: String?, color: Int) {
    val normalized = rawStatus?.trim()?.lowercase()
    if (status == normalized && baseColor == color) return
    status = normalized
    baseColor = color
    requestLayout()
    invalidate()
  }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val s = status
    val baseWidthDp = when (s) {
      "sent" -> 16
      "delivered", "read" -> 22
      else -> 16
    }
    val w = resolveSize(dp(baseWidthDp), widthMeasureSpec)
    val h = resolveSize(dp(14), heightMeasureSpec)
    setMeasuredDimension(w, h)
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val s = status ?: return
    val w = width.toFloat().coerceAtLeast(1f)
    val h = height.toFloat().coerceAtLeast(1f)
    when (s) {
      "pending" -> {
        textPaint.color = withAlpha(baseColor, 0.95f)
        textPaint.textSize = h * 0.90f
        val y = (h * 0.5f) - ((textPaint.descent() + textPaint.ascent()) * 0.5f)
        canvas.drawText("\u25F7", w * 0.5f, y, textPaint)
      }
      "error" -> {
        textPaint.color = Color.argb(255, 255, 122, 122)
        textPaint.textSize = h * 0.92f
        val y = (h * 0.5f) - ((textPaint.descent() + textPaint.ascent()) * 0.5f)
        canvas.drawText("!", w * 0.5f, y, textPaint)
      }
      "sent" -> drawChecks(canvas, w, h, doubleCheck = false, color = baseColor)
      "delivered" -> drawChecks(canvas, w, h, doubleCheck = true, color = baseColor)
      "read" -> drawChecks(canvas, w, h, doubleCheck = true, color = Color.argb(255, 0, 163, 255))
      else -> Unit
    }
  }

  private fun drawChecks(canvas: Canvas, w: Float, h: Float, doubleCheck: Boolean, color: Int) {
    strokePaint.color = color
    // Determine a base scale from the height to keep aspect ratio consistent
    val s = h / 24f
    
    // For single check, we center it. For double check, we right-align the entire glyph set.
    // Native double check typically has bounding box ~22x14, single check ~16x14.
    // The design paths here are from a 24x24 unit grid.
    
    // Calculate right bound of the path (the double check's right-most point is ~20 on the 24 grid)
    // If not double check, the right-most point is ~15 on the 24 grid.
    val pathWidthUnits = if (doubleCheck) 20f else 15f
    val pathWidth = pathWidthUnits * s
    
    // Offset x to right-align the icon block, preserving exactly 1x scale logic
    val offsetX = max(0f, (w - pathWidth) - (2f * s)) // small constant padding
    
    fun p(x: Float, y: Float): Pair<Float, Float> = Pair(offsetX + x * s, y * s)

    tmpPath.reset()
    p(4f, 12.9f).let { (x, y) -> tmpPath.moveTo(x, y) }
    p(7.14286f, 16.5f).let { (x, y) -> tmpPath.lineTo(x, y) }
    p(15f, 7.5f).let { (x, y) -> tmpPath.lineTo(x, y) }
    canvas.drawPath(tmpPath, strokePaint)

    if (doubleCheck) {
      tmpPath.reset()
      p(20f, 7.5625f).let { (x, y) -> tmpPath.moveTo(x, y) }
      p(11.4283f, 16.5625f).let { (x, y) -> tmpPath.lineTo(x, y) }
      p(11f, 16f).let { (x, y) -> tmpPath.lineTo(x, y) }
      canvas.drawPath(tmpPath, strokePaint)
    }
  }

  private fun dp(value: Int): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).toInt()
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }
}

internal class VoicePlayProgressView(context: Context) : View(context) {
  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(245, 255, 255, 255)
  }
  private val ringTrackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeWidth = dpF(2.2f)
    color = Color.argb(72, 255, 255, 255)
  }
  private val ringProgressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeWidth = dpF(2.2f)
    color = Color.WHITE
  }
  private var iconTintColor: Int = Color.BLUE
  private val playDrawable = context.getDrawable(R.drawable.ic_voice_play)?.mutate()
  private val pauseDrawable = context.getDrawable(R.drawable.ic_voice_pause)?.mutate()
  private val arcRect = RectF()
  private var isPlaying = false
  private var playbackProgress = 0f

  init {
    isClickable = true
    isFocusable = true
  }

  fun applyStyle(fillColor: Int, iconTint: Int, ringTint: Int) {
    val trackAlpha = (Color.alpha(ringTint) * 0.38f).roundToInt().coerceIn(18, 255)
    fillPaint.color = fillColor
    iconTintColor = iconTint
    ringTrackPaint.color =
      Color.argb(trackAlpha, Color.red(ringTint), Color.green(ringTint), Color.blue(ringTint))
    ringProgressPaint.color = ringTint
    invalidate()
  }

  fun setPlaybackState(isPlaying: Boolean, progress: Float) {
    val clampedProgress = progress.coerceIn(0f, 1f)
    if (this.isPlaying == isPlaying && kotlin.math.abs(playbackProgress - clampedProgress) < 0.001f)
      return
    this.isPlaying = isPlaying
    playbackProgress = clampedProgress
    invalidate()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (width <= 0 || height <= 0) return
    val cx = width * 0.5f
    val cy = height * 0.5f
    val outerRadius = kotlin.math.min(cx, cy)
    val fillRadius = kotlin.math.max(dpF(10f), outerRadius - dpF(3f))
    canvas.drawCircle(cx, cy, fillRadius, fillPaint)

    val ringRadius = kotlin.math.min(
      outerRadius - (ringTrackPaint.strokeWidth * 0.5f),
      fillRadius + dpF(1.8f),
    )
    if (ringRadius > 0f) {
      canvas.drawCircle(cx, cy, ringRadius, ringTrackPaint)
      if (playbackProgress > 0.001f) {
        arcRect.set(cx - ringRadius, cy - ringRadius, cx + ringRadius, cy + ringRadius)
        canvas.drawArc(arcRect, -90f, playbackProgress * 360f, false, ringProgressPaint)
      }
    }

    val icon = if (isPlaying) pauseDrawable else playDrawable
    if (icon != null) {
      val iconSize = min(width, height) * 0.42f
      val left = ((width - iconSize) * 0.5f).roundToInt()
      val top = ((height - iconSize) * 0.5f).roundToInt()
      val right = (left + iconSize).roundToInt()
      val bottom = (top + iconSize).roundToInt()
      icon.setBounds(left, top, right, bottom)
      icon.setTint(iconTintColor)
      icon.draw(canvas)
    }
  }

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )
}

internal class VoiceUploadProgressView(context: Context) : View(context) {
  private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 2.5f, context.resources.displayMetrics)
    strokeCap = Paint.Cap.ROUND
    color = Color.WHITE
  }
  private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(85, 0, 0, 0)
  }
  private val rect = RectF()
  var progress: Float = 0f
    set(value) {
      val clamped = value.coerceIn(0f, 1f)
      if (field != clamped) {
        field = clamped
        invalidate()
      }
    }

  override fun onDraw(canvas: Canvas) {
    if (progress <= 0f || progress >= 1f) return
    val cx = width / 2f
    val cy = height / 2f
    val radius = kotlin.math.min(cx, cy)
    canvas.drawCircle(cx, cy, radius, bgPaint)
    val pad = paint.strokeWidth / 2f + TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 2f, context.resources.displayMetrics)
    rect.set(pad, pad, width - pad, height - pad)
    val sweep = progress * 360f
    canvas.drawArc(rect, -90f, sweep, false, paint)
  }
}

internal class VoiceWaveformView(context: Context) : View(context) {
  private val activePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.WHITE
  }
  private val inactivePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(74, 255, 255, 255)
  }
  private val barCount = 34
  private var barEnvelope: FloatArray = makeDefaultEnvelope(barCount)
  private var playbackProgress = 0f
  private var level = 0f
  private var isPlaying = false
  private var phase = 0f

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val desiredHeight = dp(10)
    val resolvedHeight = resolveSize(desiredHeight, heightMeasureSpec)
    super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(resolvedHeight, MeasureSpec.EXACTLY))
  }

  fun updatePlayback(progress: Float, level: Float, isPlaying: Boolean) {
    playbackProgress = progress.coerceIn(0f, 1f)
    this.level = level.coerceIn(0f, 1f)
    this.isPlaying = isPlaying
    if (isPlaying) {
      phase += 0.34f
    }
    invalidate()
  }

  fun setWaveform(samples: List<Float>?) {
    val normalized =
      samples
        ?.map { it.coerceIn(0f, 1f) }
        ?.filter { it.isFinite() }
        .orEmpty()
    if (normalized.isEmpty()) {
      barEnvelope = makeDefaultEnvelope(barCount)
      invalidate()
      return
    }
    if (normalized.size == barCount) {
      barEnvelope = shapeEnvelope(normalized.toFloatArray())
      invalidate()
      return
    }
    val bucketSize = normalized.size.toFloat() / barCount.toFloat()
    val next = FloatArray(barCount)
    for (index in 0 until barCount) {
      val start = kotlin.math.floor(index * bucketSize).toInt()
      val end = kotlin.math.max(start + 1, kotlin.math.floor((index + 1) * bucketSize).toInt())
      val clampedEnd = kotlin.math.min(normalized.size, end)
      if (start < clampedEnd) {
        var sumSquares = 0f
        var maxPeak = 0f
        for (i in start until clampedEnd) {
          val value = normalized[i]
          sumSquares += value * value
          if (value > maxPeak) maxPeak = value
        }
        val count = (clampedEnd - start).toFloat()
        val rms = kotlin.math.sqrt(sumSquares / count)
        val energy = (rms * 0.58f) + (maxPeak * 0.42f)
        next[index] = energy.coerceIn(0.04f, 1f).toDouble().pow(0.76).toFloat()
      } else {
        next[index] = 0.04f
      }
    }
    barEnvelope = shapeEnvelope(smoothEnvelope(next))
    invalidate()
  }
  fun setColors(activeColor: Int, inactiveColor: Int) {
    if (activePaint.color == activeColor && inactivePaint.color == inactiveColor) return
    activePaint.color = activeColor
    inactivePaint.color = inactiveColor
    invalidate()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (width <= 0 || height <= 0) return
    val spacing = dpF(1.75f)
    val totalSpacing = spacing * (barCount - 1)
    val barWidth = kotlin.math.max(dpF(2f), (width - totalSpacing) / barCount.toFloat())
    val minHeight = dpF(2.5f)
    val maxHeight = height.toFloat()
    var x = 0f
    for (index in 0 until barCount) {
      val normalizedIndex = index / kotlin.math.max(1f, barCount.toFloat())
      val base = barEnvelope[index]
      val pulse =
        if (isPlaying) {
          (kotlin.math.sin((phase + (index * 0.62f)).toDouble()) * 0.10 + 0.90).toFloat()
        } else {
          1.0f
        }
      val spectralBias = (0.95f + (0.05f * kotlin.math.sin((index * 0.52f).toDouble()).toFloat())).coerceIn(0.90f, 1.05f)
      val liveBoost = if (isPlaying) level * 0.22f else 0f
      val amplitude = ((base + liveBoost) * pulse * spectralBias).coerceIn(0.04f, 1f)
      val barHeight = minHeight + ((maxHeight - minHeight) * amplitude)
      val y = (height - barHeight) * 0.5f
      val paint = if (normalizedIndex < playbackProgress) activePaint else inactivePaint
      val r = barWidth * 0.5f
      canvas.drawRoundRect(x, y, x + barWidth, y + barHeight, r, r, paint)
      x += barWidth + spacing
    }
  }

  private fun smoothEnvelope(values: FloatArray): FloatArray {
    if (values.size <= 2) return values
    val out = FloatArray(values.size)
    for (i in values.indices) {
      val left = values[max(0, i - 1)]
      val center = values[i]
      val right = values[min(values.size - 1, i + 1)]
      out[i] = ((left * 0.2f) + (center * 0.6f) + (right * 0.2f)).coerceIn(0.12f, 1f)
    }
    return out
  }

  private fun shapeEnvelope(values: FloatArray): FloatArray {
    if (values.isEmpty()) return values
    val last = max(1f, (values.size - 1).toFloat())
    val out = FloatArray(values.size)
    for (i in values.indices) {
      val t = i / last
      val edgeAttenuation = 1f - (kotlin.math.abs(t - 0.5f) * 0.18f)
      out[i] = (values[i].toDouble().pow(0.86).toFloat() * edgeAttenuation).coerceIn(0.12f, 1f)
    }
    return out
  }

  private fun makeDefaultEnvelope(count: Int): FloatArray {
    if (count <= 0) return floatArrayOf()
    val out = FloatArray(count)
    for (i in 0 until count) {
      val t = i.toFloat() / max(1f, (count - 1).toFloat())
      val wave = (kotlin.math.sin((t * Math.PI * 5.0) + 0.7) * 0.5 + 0.5).toFloat()
      out[i] = (0.22f + (wave * 0.55f)).coerceIn(0.18f, 0.82f)
    }
    return out
  }

  private fun dp(value: Int): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).toInt()
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun blend(from: Int, to: Int, amount: Float): Int {
    val t = amount.coerceIn(0f, 1f)
    val inv = 1f - t
    return Color.argb(
      (Color.alpha(from) * inv + Color.alpha(to) * t).toInt(),
      (Color.red(from) * inv + Color.red(to) * t).toInt(),
      (Color.green(from) * inv + Color.green(to) * t).toInt(),
      (Color.blue(from) * inv + Color.blue(to) * t).toInt(),
    )
  }
}

internal fun createNativeMessageRowViewHolder(context: Context): NativeRowViewHolder {
  fun dp(value: Int): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()

  fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )

  val root = FrameLayout(context).apply {
    layoutParams = RecyclerView.LayoutParams(
      RecyclerView.LayoutParams.MATCH_PARENT,
      RecyclerView.LayoutParams.WRAP_CONTENT,
    )
    clipChildren = false
    clipToPadding = false
    setPadding(dp(8), dp(1), dp(8), dp(1))
  }

  val bubble = FrameLayout(context).apply {
    layoutParams = FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    )
    clipChildren = false
    clipToPadding = false
    setPadding(dp(10), dp(7), dp(10), dp(7))
    minimumWidth = dp(26)
    alpha = 1f
  }

  val tail = BubbleTailView(context).apply {
    visibility = View.GONE
  }

  val agentSender = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    setTextColor(Color.argb(255, 125, 92, 225))
    setTypeface(Typeface.DEFAULT_BOLD)
    includeFontPadding = false
    visibility = View.GONE
    maxLines = 1
  }

  val text = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    setTextColor(Color.WHITE)
    setLineSpacing(0f, 1.1f)
    includeFontPadding = false
    maxWidth = (context.resources.displayMetrics.widthPixels * 0.85f).toInt()
  }

  val inlineAttachment = FrameLayout(context).apply {
    visibility = View.GONE
    background = GradientDrawable().apply {
      cornerRadius = dpF(12f)
      setColor(Color.argb(52, 0, 0, 0))
    }
    setPadding(dp(12), dp(8), dp(12), dp(8))
    minimumWidth = dp(170)
    isClickable = true
    isFocusable = true
  }
  val inlineAttachmentIcon = TextView(context).apply {
    setText("\uD83D\uDCC4")
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    includeFontPadding = false
  }
  val inlineAttachmentTitle = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    setTypeface(Typeface.DEFAULT_BOLD)
    includeFontPadding = false
    maxLines = 1
  }
  val inlineAttachmentSubtitle = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    includeFontPadding = false
    setText("Tap to open")
    maxLines = 1
  }
  inlineAttachment.addView(
    inlineAttachmentIcon,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.START or Gravity.CENTER_VERTICAL,
    ),
  )
  inlineAttachment.addView(
    inlineAttachmentTitle,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.START or Gravity.TOP,
    ).apply {
      leftMargin = dp(24)
    },
  )
  inlineAttachment.addView(
    inlineAttachmentSubtitle,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.START or Gravity.BOTTOM,
    ).apply {
      leftMargin = dp(24)
    },
  )

  val voiceContainer = FrameLayout(context).apply {
    visibility = View.GONE
    alpha = 1f
  }

  val voiceButton = VoicePlayProgressView(context).apply {
    applyStyle(
      fillColor = Color.argb(245, 255, 255, 255),
      iconTint = Color.WHITE,
      ringTint = Color.argb(186, 255, 255, 255),
    )
  }

  val voiceWave = VoiceWaveformView(context)
  val voiceUploadProgress = VoiceUploadProgressView(context)

  val voiceDuration = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    setTextColor(Color.argb(200, 255, 255, 255))
    gravity = Gravity.END or Gravity.CENTER_VERTICAL
    includeFontPadding = false
  }

  val time = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
    setTextColor(Color.argb(184, 255, 255, 255))
    gravity = Gravity.END
    includeFontPadding = false
  }

  val status = BubbleStatusIndicatorView(context).apply {
    visibility = View.GONE
  }

  val day = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    setTextColor(Color.argb(210, 236, 239, 255))
    gravity = Gravity.CENTER
    setPadding(dp(11), dp(4), dp(11), dp(4))
    visibility = View.GONE
  }

  bubble.addView(
    agentSender,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ),
  )
  bubble.addView(
    text,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ),
  )
  bubble.addView(
    inlineAttachment,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      dp(48),
    ).apply {
      gravity = Gravity.START or Gravity.TOP
    },
  )
  voiceContainer.addView(
    voiceButton,
    FrameLayout.LayoutParams(dp(38), dp(38)).apply {
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
      leftMargin = dp(4)
    },
  )
  voiceContainer.addView(
    voiceUploadProgress,
    FrameLayout.LayoutParams(dp(38), dp(38)).apply {
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
      leftMargin = dp(4)
    },
  )
  voiceContainer.addView(
    voiceWave,
    FrameLayout.LayoutParams(dp(182), dp(18)).apply {
      gravity = Gravity.START or Gravity.TOP
      leftMargin = dp(52)
      topMargin = dp(8)
    },
  )
  voiceContainer.addView(
    voiceDuration,
    FrameLayout.LayoutParams(dp(58), dp(14)).apply {
      gravity = Gravity.START or Gravity.TOP
      leftMargin = dp(52)
      topMargin = dp(31)
    },
  )
  bubble.addView(
    voiceContainer,
    FrameLayout.LayoutParams(dp(242), dp(52)).apply {
      gravity = Gravity.START
    },
  )
  bubble.addView(
    time,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.END or Gravity.BOTTOM,
    ).apply {
      rightMargin = dp(0)
      bottomMargin = dp(0)
    },
  )
  bubble.addView(
    status,
    FrameLayout.LayoutParams(dp(16), dp(14), Gravity.END or Gravity.BOTTOM).apply {
      rightMargin = 0
      bottomMargin = 0
    },
  )
  root.addView(
    tail,
    FrameLayout.LayoutParams(dp(29), dp(29)),
  )
  root.addView(bubble)
  root.addView(
    day,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.CENTER_HORIZONTAL,
    ),
  )

  return NativeRowViewHolder(
    root,
    bubble,
    tail,
    text,
    inlineAttachment,
    inlineAttachmentTitle,
    inlineAttachmentSubtitle,
    voiceContainer,
    voiceButton,
    voiceWaveView = voiceWave,
    voiceUploadProgressView = voiceUploadProgress,
    voiceDurationView = voiceDuration,
    time,
    status,
    day,
    agentSender,
  )
}
