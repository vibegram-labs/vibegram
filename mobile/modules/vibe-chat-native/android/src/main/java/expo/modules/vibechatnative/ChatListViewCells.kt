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
import kotlin.math.sqrt

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

internal class BubbleStatusIndicatorView(context: Context) : android.widget.ImageView(context) {
  private var status: String? = null
  private var baseColor: Int = Color.WHITE

  init {
    scaleType = ScaleType.FIT_END
  }

  fun bind(rawStatus: String?, color: Int) {
    val normalized = rawStatus?.trim()?.lowercase()
    if (status == normalized && baseColor == color) return
    status = normalized
    baseColor = color

    when (normalized) {
      "pending" -> setImageResource(R.drawable.ic_bubble_pending)
      "error" -> setImageResource(R.drawable.ic_bubble_error)
      "sent" -> setImageResource(R.drawable.ic_bubble_sent)
      "delivered", "read" -> setImageResource(R.drawable.ic_bubble_read)
      else -> setImageDrawable(null)
    }

    val tintColor = if (normalized == "read") Color.argb(255, 0, 163, 255) else if (normalized == "error") Color.argb(255, 255, 122, 122) else baseColor
    setColorFilter(tintColor, android.graphics.PorterDuff.Mode.SRC_IN)

    requestLayout()
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

  private fun dp(value: Int): Int =
    android.util.TypedValue.applyDimension(
      android.util.TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()
}

internal class VoicePlayProgressView(context: Context) : View(context) {
  companion object {
    private const val BUTTON_SIZE_DP = 44f
    private const val PLAYBACK_ICON_SIZE_DP = 20f
    private const val UPLOAD_ICON_SIZE_DP = 16f
  }

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
  private val cancelDrawable = context.getDrawable(R.drawable.ic_voice_cancel)?.mutate()
  private val arcRect = RectF()
  private var isPlaying = false
  private var playbackProgress = 0f
  private var isUploading = false
  private var uploadProgress: Float? = null

  init {
    isClickable = true
    isFocusable = true
  }

  fun applyStyle(fillColor: Int, iconTint: Int, ringTint: Int) {
    val ringAlpha = Color.alpha(ringTint)
    val trackAlpha =
      if (ringAlpha == 0) {
        0
      } else {
        (ringAlpha * 0.38f).roundToInt().coerceIn(18, 255)
      }
    fillPaint.color = fillColor
    iconTintColor = iconTint
    ringTrackPaint.color =
      Color.argb(trackAlpha, Color.red(ringTint), Color.green(ringTint), Color.blue(ringTint))
    ringProgressPaint.color = ringTint
    invalidate()
  }

  fun setPlaybackState(isPlaying: Boolean, progress: Float) {
    if (isUploading) return
    val clampedProgress = progress.coerceIn(0f, 1f)
    if (this.isPlaying == isPlaying && kotlin.math.abs(playbackProgress - clampedProgress) < 0.001f)
      return
    this.isPlaying = isPlaying
    playbackProgress = clampedProgress
    invalidate()
  }

  fun setUploadState(isUploading: Boolean, progress: Float?) {
    val normalizedProgress =
      progress
        ?.takeIf { it.isFinite() }
        ?.coerceIn(0f, 1f)
    val previousProgress = uploadProgress
    val progressChanged =
      if (previousProgress == null && normalizedProgress == null) {
        false
      } else if (previousProgress != null && normalizedProgress != null) {
        kotlin.math.abs(previousProgress - normalizedProgress) > 0.001f
      } else {
        true
      }
    if (this.isUploading == isUploading && !progressChanged) return
    this.isUploading = isUploading
    uploadProgress = normalizedProgress
    invalidate()
  }

  fun preferredButtonSizePx(): Int = dpF(BUTTON_SIZE_DP).roundToInt()

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val desiredSize = preferredButtonSizePx()
    val resolvedWidth = resolveSize(desiredSize, widthMeasureSpec)
    val resolvedHeight = resolveSize(desiredSize, heightMeasureSpec)
    setMeasuredDimension(resolvedWidth, resolvedHeight)
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (width <= 0 || height <= 0) return
    val cx = width * 0.5f
    val cy = height * 0.5f
    val outerRadius = kotlin.math.min(cx, cy)
    val fillInset = dpF(2.5f)
    val fillRadius = (outerRadius - fillInset).coerceAtLeast(kotlin.math.min(dpF(14f), outerRadius))
    canvas.drawCircle(cx, cy, fillRadius, fillPaint)

    val showRing = isUploading || (Color.alpha(ringProgressPaint.color) > 0 && playbackProgress > 0.001f)
    if (showRing) {
      val ringRadius = kotlin.math.max(dpF(4f), fillRadius + dpF(1.8f))
      if (Color.alpha(ringTrackPaint.color) > 0) {
        canvas.drawCircle(cx, cy, ringRadius, ringTrackPaint)
      }
      arcRect.set(cx - ringRadius, cy - ringRadius, cx + ringRadius, cy + ringRadius)
      val sweepProgress =
        if (isUploading) {
          kotlin.math.max(0.05f, uploadProgress ?: 0.08f)
        } else {
          playbackProgress.coerceIn(0f, 1f)
        }
      val sweep = sweepProgress * 360f
      canvas.drawArc(arcRect, -90f, sweep, false, ringProgressPaint)
    }

    val icon =
      when {
        isUploading -> cancelDrawable
        isPlaying -> pauseDrawable
        else -> playDrawable
      }
    if (icon != null) {
      val iconSize =
        kotlin.math.min(
          (fillRadius * 2f) - dpF(9f),
          when {
            isUploading -> dpF(UPLOAD_ICON_SIZE_DP)
            else -> dpF(PLAYBACK_ICON_SIZE_DP)
          },
        )
      val leftShift =
        when {
          isUploading || isPlaying -> 0f
          else -> dpF(0.8f)
        }
      val left = (((width - iconSize) * 0.5f) + leftShift).roundToInt()
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
  companion object {
    private const val BAR_COUNT = 52
    private const val BAR_WIDTH_DP = 2f
    private const val BAR_SPACING_DP = 1f
    private const val WAVE_HEIGHT_DP = 16f
  }

  private val activePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.WHITE
  }
  private val inactivePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(74, 255, 255, 255)
  }
  private val blendedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
  }
  private var barCount = BAR_COUNT
  private var barEnvelope: FloatArray = makeDefaultEnvelope(barCount)
  private var playbackProgress = 0f
  private var level = 0f
  private var isPlaying = false

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val desiredHeight = dpF(WAVE_HEIGHT_DP).roundToInt()
    val desiredWidth = preferredContentWidth()
    val resolvedWidth = resolveSize(desiredWidth, widthMeasureSpec)
    val resolvedHeight = resolveSize(desiredHeight, heightMeasureSpec)
    setMeasuredDimension(resolvedWidth, resolvedHeight)
  }

  fun updatePlayback(progress: Float, level: Float, isPlaying: Boolean) {
    val clampedProgress = progress.coerceIn(0f, 1f)
    playbackProgress =
      if (isPlaying) {
        playbackProgress + ((clampedProgress - playbackProgress) * 0.22f)
      } else {
        clampedProgress
      }
    this.level = level.coerceIn(0f, 1f)
    this.isPlaying = isPlaying
    invalidate()
  }

  fun setWaveform(samples: List<Float>?, duration: Double? = null) {
    val normalized =
      samples
        ?.filter { it.isFinite() }
        ?.map { it.coerceIn(0f, 1f) }
        .orEmpty()

    if (normalized.isEmpty()) {
      barEnvelope = makeDefaultEnvelope(barCount)
      invalidate()
      requestLayout()
      return
    }

    if (normalized.size == barCount) {
      barEnvelope = shapeEnvelope(smoothEnvelope(smoothEnvelope(normalized.toFloatArray())))
      invalidate()
      requestLayout()
      return
    }

    val bucketSize = normalized.size.toFloat() / barCount.toFloat()
    val next = FloatArray(barCount)
    for (index in 0 until barCount) {
      val start = kotlin.math.floor(index * bucketSize).toInt()
      val clampedStart = start.coerceIn(0, normalized.size - 1)
      val clampedEnd =
        kotlin.math.min(
          normalized.size,
          kotlin.math.floor((index + 1) * bucketSize).toInt().coerceAtLeast(clampedStart + 1),
        )
      if (start < clampedEnd) {
        var maxPeak = 0f
        var sumSquares = 0f
        for (i in start until clampedEnd) {
          val value = normalized[i]
          if (value > maxPeak) maxPeak = value
          sumSquares += value * value
        }
        val sliceCount = (clampedEnd - start).coerceAtLeast(1)
        val rms = sqrt(sumSquares / sliceCount.toFloat())
        val energy = kotlin.math.max(maxPeak * 0.82f, rms * 0.72f)
        next[index] = energy.pow(0.9f).coerceIn(0f, 1f)
      } else {
        next[index] = normalized[clampedStart]
      }
    }
    barEnvelope = shapeEnvelope(smoothEnvelope(smoothEnvelope(next)))
    invalidate()
    requestLayout()
  }

  fun preferredContentWidth(maxWidthPx: Int? = null): Int {
    val desired =
      ((barCount * dpF(BAR_WIDTH_DP)) + ((barCount - 1).coerceAtLeast(0) * dpF(BAR_SPACING_DP)))
        .roundToInt()
    return maxWidthPx?.let { min(it, desired) } ?: desired
  }

  fun preferredContentHeightPx(): Int = dpF(WAVE_HEIGHT_DP).roundToInt()

  fun setColors(activeColor: Int, inactiveColor: Int) {
    if (activePaint.color == activeColor && inactivePaint.color == inactiveColor) return
    activePaint.color = activeColor
    inactivePaint.color = inactiveColor
    invalidate()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (width <= 0 || height <= 0) return
    val spacing = dpF(BAR_SPACING_DP)
    val totalSpacing = spacing * (barCount - 1)
    val barWidth = kotlin.math.max(dpF(1f), kotlin.math.floor((width - totalSpacing) / barCount.toFloat()))
    val minHeight = kotlin.math.max(dpF(2f), kotlin.math.floor(height * 0.2f))
    val maxHeight = kotlin.math.max(minHeight + 1f, kotlin.math.floor(height * 0.88f))
    val dynamicGain = if (isPlaying) 1f + (level * 0.16f) else 1f
    val progressX = playbackProgress.coerceIn(0f, 1f) * width.toFloat()
    var x = 0f
    for (index in 0 until barCount) {
      val amplitude = (barEnvelope[index] * dynamicGain).coerceIn(0.10f, 1f)
      val barHeight = minHeight + ((maxHeight - minHeight) * amplitude)
      val y = kotlin.math.floor((height - barHeight) * 0.5f)
      val barStart = x
      val barEnd = x + barWidth
      val fillFraction =
        ((progressX - barStart) / kotlin.math.max(1f, barEnd - barStart)).coerceIn(0f, 1f)
      val paint =
        when {
          fillFraction <= 0f -> inactivePaint
          fillFraction >= 1f -> activePaint
          else -> blendedPaint.apply {
            color = blend(inactivePaint.color, activePaint.color, fillFraction)
          }
        }
      val r = kotlin.math.min(barWidth * 0.5f, dpF(1f))
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
      out[i] = ((left * 0.2f) + (center * 0.6f) + (right * 0.2f)).coerceIn(0.14f, 1f)
    }
    return out
  }

  private fun shapeEnvelope(values: FloatArray): FloatArray {
    if (values.isEmpty()) return values
    val out = FloatArray(values.size)
    val lastIndex = max(1, values.size - 1)
    for (i in values.indices) {
      val edgeAttenuation = 1f - (kotlin.math.abs((i.toFloat() / lastIndex.toFloat()) - 0.5f) * 0.12f)
      out[i] = (values[i].pow(0.9f) * edgeAttenuation).coerceIn(0.10f, 1f)
    }
    return out
  }

  private fun makeDefaultEnvelope(count: Int): FloatArray {
    if (count <= 0) return floatArrayOf()
    val template = floatArrayOf(0.64f, 0.49f, 0.73f, 0.56f, 0.42f, 0.78f, 0.58f, 0.28f, 0.33f, 0.67f)
    val out = FloatArray(count)
    for (i in 0 until count) {
      out[i] = template[i % template.size]
    }
    return out
  }

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )

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
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
    },
  )
  voiceContainer.addView(
    voiceUploadProgress,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
    },
  )
  voiceContainer.addView(
    voiceWave,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      gravity = Gravity.START or Gravity.TOP
    },
  )
  voiceContainer.addView(
    voiceDuration,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      gravity = Gravity.START or Gravity.TOP
    },
  )
  bubble.addView(
    voiceContainer,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
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
