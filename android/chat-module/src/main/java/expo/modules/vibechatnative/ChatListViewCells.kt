package expo.modules.vibechatnative

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal class NativeRowViewHolder(
  val container: FrameLayout,
  val bubbleContainer: FrameLayout,
  val tailView: BubbleTailView,
  val textView: TextView,
  val inlineAttachmentView: FrameLayout,
  val mediaPreviewView: FrameLayout,
  val mediaImageView: ImageView,
  val mediaPlayBadgeView: TextView,
  val mediaDurationBadgeView: TextView,
  val mediaTransferOverlayView: FrameLayout,
  val mediaTransferRingView: BubbleUploadProgressView,
  val mediaTransferSizeView: TextView,
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
    private const val BUTTON_SIZE_DP = 52f
    private const val PLAYBACK_ICON_SIZE_DP = 18f
    private const val DOWNLOAD_ICON_SIZE_DP = 18f
    private const val UPLOAD_ICON_SIZE_DP = 16f
    private const val MINIMUM_UPLOAD_PROGRESS = 0.027f
    private const val UPLOAD_PROGRESS_DURATION_MS = 200L
    private const val UPLOAD_ROTATION_DURATION_MS = 1570L
  }

  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(245, 255, 255, 255)
  }
  private val ringProgressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeWidth = dpF(2.4f)
    color = Color.WHITE
  }
  private val fluidPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(64, 255, 255, 255)
  }
  private var iconTintColor: Int = Color.BLUE
  private var fluidColor: Int = Color.argb(64, 255, 255, 255)
  private val playDrawable = context.getDrawable(R.drawable.ic_voice_play)?.mutate()
  private val pauseDrawable = context.getDrawable(R.drawable.ic_voice_pause)?.mutate()
  private val cancelDrawable = context.getDrawable(R.drawable.ic_voice_cancel)?.mutate()
  private val downloadDrawable = context.getDrawable(R.drawable.ic_voice_download)?.mutate()
  private val arcRect = RectF()
  private var isPlaying = false
  private var isUploading = false
  private var needsDownload = false
  private var isDownloading = false
  private var uploadProgress: Float? = null
  private var lastResolvedUploadProgress: Float? = null
  private var downloadProgress: Float? = null
  private var lastResolvedDownloadProgress: Float? = null
  private var displayedUploadProgress = 0f
  private var uploadRotationDegrees = 0f
  private var playbackLevel = 0f
  private var playbackStartedAtMs = 0L
  private var progressAnimator: ValueAnimator? = null
  private var rotationAnimator: ValueAnimator? = null

  init {
    isClickable = true
    isFocusable = true
  }

  fun applyStyle(fillColor: Int, iconTint: Int, ringTint: Int) {
    fillPaint.color = fillColor
    iconTintColor = iconTint
    ringProgressPaint.color = ringTint
    fluidColor = withAlpha(ringTint, 0.35f)
    invalidate()
  }

  fun setPlaybackState(isPlaying: Boolean, progress: Float, level: Float = 0f) {
    if (isUploading || isDownloading || needsDownload) return
    val normalizedLevel = level.coerceIn(0f, 1f)
    val levelChanged = kotlin.math.abs(playbackLevel - normalizedLevel) > 0.01f
    if (this.isPlaying == isPlaying && !levelChanged) return
    if (isPlaying && !this.isPlaying) {
      playbackStartedAtMs = SystemClock.uptimeMillis()
    } else if (!isPlaying) {
      playbackStartedAtMs = 0L
    }
    this.isPlaying = isPlaying
    playbackLevel = if (isPlaying) normalizedLevel else 0f
    invalidate()
  }

  fun setUploadState(isUploading: Boolean, progress: Float?) {
    if (isUploading) {
      needsDownload = false
      isDownloading = false
      downloadProgress = null
      lastResolvedDownloadProgress = null
    }
    val resolvedProgress =
      if (isUploading) {
        when {
          progress != null && progress.isFinite() -> {
            progress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f).also { lastResolvedUploadProgress = it }
          }
          lastResolvedUploadProgress != null -> lastResolvedUploadProgress
          else -> MINIMUM_UPLOAD_PROGRESS.also { lastResolvedUploadProgress = it }
        }
      } else {
        lastResolvedUploadProgress = null
        null
      }

    if (this.isUploading == isUploading && uploadProgress == resolvedProgress) return
    this.isUploading = isUploading
    uploadProgress = resolvedProgress
    updateUploadVisualState()
  }

  fun setDownloadState(needsDownload: Boolean, isDownloading: Boolean, progress: Float?) {
    if (isUploading) return

    val resolvedProgress =
      if (isDownloading) {
        when {
          progress != null && progress.isFinite() -> {
            progress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f).also { lastResolvedDownloadProgress = it }
          }
          lastResolvedDownloadProgress != null -> lastResolvedDownloadProgress
          else -> MINIMUM_UPLOAD_PROGRESS.also { lastResolvedDownloadProgress = it }
        }
      } else {
        lastResolvedDownloadProgress = null
        null
      }

    if (
      this.needsDownload == needsDownload &&
        this.isDownloading == isDownloading &&
        downloadProgress == resolvedProgress
    ) {
      return
    }

    this.needsDownload = needsDownload
    this.isDownloading = isDownloading
    downloadProgress = resolvedProgress
    if (!needsDownload && !isDownloading) {
      stopUploadAnimations(resetProgress = true)
      invalidate()
      return
    }
    if (isDownloading) {
      updateUploadVisualState()
    } else {
      stopUploadAnimations(resetProgress = true)
      invalidate()
    }
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
    val fillInset = dpF(3f)
    val fillRadius = (outerRadius - fillInset).coerceAtLeast(kotlin.math.min(dpF(14f), outerRadius))

    if (!isUploading && !isDownloading && !needsDownload && (isPlaying || playbackLevel > 0.01f)) {
      drawFluidVisualizer(canvas, cx, cy, outerRadius)
      postInvalidateOnAnimation()
    }

    canvas.drawCircle(cx, cy, fillRadius, fillPaint)

    if (isUploading || isDownloading) {
      val ringRadius = kotlin.math.max(dpF(4f), fillRadius + dpF(1.8f))
      arcRect.set(cx - ringRadius, cy - ringRadius, cx + ringRadius, cy + ringRadius)
      canvas.save()
      canvas.rotate(uploadRotationDegrees, cx, cy)
      canvas.drawArc(
        arcRect,
        -90f,
        displayedUploadProgress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f) * 360f,
        false,
        ringProgressPaint,
      )
      canvas.restore()
    }

    val icon =
      when {
        isUploading || isDownloading -> cancelDrawable
        needsDownload -> downloadDrawable
        isPlaying -> pauseDrawable
        else -> playDrawable
      }
    if (icon != null) {
      val iconSize =
        kotlin.math.min(
          (fillRadius * 2f) - dpF(9f),
          when {
            isUploading || isDownloading -> dpF(UPLOAD_ICON_SIZE_DP)
            needsDownload -> dpF(DOWNLOAD_ICON_SIZE_DP)
            else -> dpF(PLAYBACK_ICON_SIZE_DP)
          },
        )
      val left = ((width - iconSize) * 0.5f).roundToInt()
      val top = ((height - iconSize) * 0.5f).roundToInt()
      val right = (left + iconSize).roundToInt()
      val bottom = (top + iconSize).roundToInt()
      icon.setBounds(left, top, right, bottom)
      icon.setTint(iconTintColor)
      icon.draw(canvas)
    }
  }

  override fun onDetachedFromWindow() {
    stopUploadAnimations(resetProgress = true)
    super.onDetachedFromWindow()
  }

  private fun updateUploadVisualState() {
    if (!isUploading && !isDownloading) {
      stopUploadAnimations(resetProgress = true)
      invalidate()
      return
    }
    ensureRotationAnimator()
    animateUploadProgressTo(
      when {
        isUploading -> uploadProgress ?: MINIMUM_UPLOAD_PROGRESS
        else -> downloadProgress ?: MINIMUM_UPLOAD_PROGRESS
      },
    )
  }

  private fun animateUploadProgressTo(target: Float) {
    val clampedTarget = target.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f)
    progressAnimator?.cancel()
    val start = displayedUploadProgress.takeIf { it > 0f } ?: clampedTarget
    progressAnimator =
      ValueAnimator.ofFloat(start, clampedTarget).apply {
        duration = UPLOAD_PROGRESS_DURATION_MS
        interpolator = AccelerateDecelerateInterpolator()
        addUpdateListener { animator ->
          displayedUploadProgress = (animator.animatedValue as Float).coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f)
          invalidate()
        }
        start()
      }
  }

  private fun ensureRotationAnimator() {
    if (rotationAnimator?.isRunning == true) return
    rotationAnimator =
      ValueAnimator.ofFloat(0f, 360f).apply {
        duration = UPLOAD_ROTATION_DURATION_MS
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { animator ->
          uploadRotationDegrees = animator.animatedValue as Float
          invalidate()
        }
        start()
      }
  }

  private fun stopUploadAnimations(resetProgress: Boolean) {
    progressAnimator?.cancel()
    progressAnimator = null
    rotationAnimator?.cancel()
    rotationAnimator = null
    uploadRotationDegrees = 0f
    playbackLevel = 0f
    playbackStartedAtMs = 0L
    if (resetProgress) {
      displayedUploadProgress = 0f
    }
  }

  private fun drawFluidVisualizer(canvas: Canvas, cx: Float, cy: Float, baseRadius: Float) {
    val elapsedSeconds =
      if (playbackStartedAtMs > 0L) {
        (SystemClock.uptimeMillis() - playbackStartedAtMs) / 1000f
      } else {
        0f
      }

    for (index in 0 until 3) {
      val layerIndex = (index + 1).toFloat()
      val idlePulse = (kotlin.math.sin((elapsedSeconds * 2f) + (index * 2f)) * 0.04f).toFloat()
      val activePush = playbackLevel * 0.4f * layerIndex
      val scale = (1f + idlePulse + activePush).coerceAtLeast(0.92f)
      val opacity = ((1f - ((scale - 1f) * 1.5f)).coerceIn(0f, 1f)) * 0.6f
      fluidPaint.color = withMultipliedAlpha(fluidColor, opacity)
      canvas.drawCircle(cx, cy, baseRadius * scale, fluidPaint)
    }
  }

  private fun withMultipliedAlpha(color: Int, factor: Float): Int {
    val alpha = (Color.alpha(color) * factor.coerceIn(0f, 1f)).roundToInt().coerceIn(0, 255)
    return Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val resolvedAlpha = (alpha.coerceIn(0f, 1f) * 255f).roundToInt().coerceIn(0, 255)
    return Color.argb(resolvedAlpha, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )
}

internal class BubbleUploadProgressView(context: Context) : View(context) {
  companion object {
    private const val MINIMUM_UPLOAD_PROGRESS = 0.027f
    private const val PROGRESS_DURATION_MS = 200L
    private const val ROTATION_DURATION_MS = 1570L
  }

  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(148, 0, 0, 0)
  }
  private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeWidth = dpF(3f)
    color = Color.argb(72, 255, 255, 255)
  }
  private val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeWidth = dpF(3f)
    color = Color.WHITE
  }
  private val cancelDrawable = context.getDrawable(R.drawable.ic_voice_cancel)?.mutate()
  private val arcRect = RectF()
  private var isUploading = false
  private var needsDownload = false
  private var isDownloading = false
  private var uploadProgress: Float? = null
  private var lastResolvedUploadProgress: Float? = null
  private var downloadProgress: Float? = null
  private var lastResolvedDownloadProgress: Float? = null
  private var displayedProgress = 0f
  private var rotationDegrees = 0f
  private var progressAnimator: ValueAnimator? = null
  private var rotationAnimator: ValueAnimator? = null

  fun setUploadState(isUploading: Boolean, progress: Float?) {
    if (isUploading) {
      needsDownload = false
      isDownloading = false
      downloadProgress = null
      lastResolvedDownloadProgress = null
    }
    val resolvedProgress =
      if (isUploading) {
        when {
          progress != null && progress.isFinite() -> {
            progress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f).also { lastResolvedUploadProgress = it }
          }
          lastResolvedUploadProgress != null -> lastResolvedUploadProgress
          else -> MINIMUM_UPLOAD_PROGRESS.also { lastResolvedUploadProgress = it }
        }
      } else {
        lastResolvedUploadProgress = null
        null
      }
    if (this.isUploading == isUploading && uploadProgress == resolvedProgress) return
    this.isUploading = isUploading
    uploadProgress = resolvedProgress
    updateVisualState()
  }

  fun setDownloadState(needsDownload: Boolean, isDownloading: Boolean, progress: Float?) {
    if (isUploading) return
    val resolvedProgress =
      if (isDownloading) {
        when {
          progress != null && progress.isFinite() -> {
            progress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f).also { lastResolvedDownloadProgress = it }
          }
          lastResolvedDownloadProgress != null -> lastResolvedDownloadProgress
          else -> MINIMUM_UPLOAD_PROGRESS.also { lastResolvedDownloadProgress = it }
        }
      } else {
        lastResolvedDownloadProgress = null
        null
      }
    if (
      this.needsDownload == needsDownload &&
        this.isDownloading == isDownloading &&
        downloadProgress == resolvedProgress
    ) {
      return
    }
    this.needsDownload = needsDownload
    this.isDownloading = isDownloading
    downloadProgress = resolvedProgress
    updateVisualState()
  }

  override fun onDetachedFromWindow() {
    stopAnimations(resetProgress = true)
    super.onDetachedFromWindow()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val shouldDrawDownload = needsDownload && isDownloading
    if ((!isUploading && !shouldDrawDownload) || width <= 0 || height <= 0) return

    val cx = width * 0.5f
    val cy = height * 0.5f
    val outerRadius = kotlin.math.min(cx, cy)
    val fillRadius = (outerRadius - dpF(5f)).coerceAtLeast(dpF(8f))
    canvas.drawCircle(cx, cy, fillRadius, fillPaint)

    val ringRadius = kotlin.math.max(dpF(6f), fillRadius + dpF(2f))
    arcRect.set(cx - ringRadius, cy - ringRadius, cx + ringRadius, cy + ringRadius)
    canvas.drawArc(arcRect, 0f, 360f, false, trackPaint)
    canvas.save()
    canvas.rotate(rotationDegrees, cx, cy)
    canvas.drawArc(
      arcRect,
      -90f,
      displayedProgress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f) * 360f,
      false,
      progressPaint,
    )
    canvas.restore()

    if (isUploading) {
      val icon = cancelDrawable ?: return
      val iconSize = kotlin.math.min(dpF(16f), fillRadius * 1.2f)
      val left = ((width - iconSize) * 0.5f).roundToInt()
      val top = ((height - iconSize) * 0.5f).roundToInt()
      icon.setBounds(left, top, (left + iconSize).roundToInt(), (top + iconSize).roundToInt())
      icon.setTint(Color.WHITE)
      icon.draw(canvas)
    }
  }

  private fun updateVisualState() {
    val shouldAnimate = isUploading || (needsDownload && isDownloading)
    if (!shouldAnimate) {
      stopAnimations(resetProgress = true)
      invalidate()
      return
    }
    ensureRotationAnimator()
    animateProgressTo(
      when {
        isUploading -> uploadProgress ?: MINIMUM_UPLOAD_PROGRESS
        else -> downloadProgress ?: MINIMUM_UPLOAD_PROGRESS
      },
    )
  }

  private fun animateProgressTo(target: Float) {
    val clampedTarget = target.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f)
    progressAnimator?.cancel()
    val start = displayedProgress.takeIf { it > 0f } ?: clampedTarget
    progressAnimator =
      ValueAnimator.ofFloat(start, clampedTarget).apply {
        duration = PROGRESS_DURATION_MS
        interpolator = AccelerateDecelerateInterpolator()
        addUpdateListener { animator ->
          displayedProgress = (animator.animatedValue as Float).coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f)
          invalidate()
        }
        start()
      }
  }

  private fun ensureRotationAnimator() {
    if (rotationAnimator?.isRunning == true) return
    rotationAnimator =
      ValueAnimator.ofFloat(0f, 360f).apply {
        duration = ROTATION_DURATION_MS
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { animator ->
          rotationDegrees = animator.animatedValue as Float
          invalidate()
        }
        start()
      }
  }

  private fun stopAnimations(resetProgress: Boolean) {
    progressAnimator?.cancel()
    progressAnimator = null
    rotationAnimator?.cancel()
    rotationAnimator = null
    rotationDegrees = 0f
    if (resetProgress) {
      displayedProgress = 0f
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
    private const val BAR_WIDTH_DP = 2f
    private const val BAR_SPACING_DP = 2f
    private const val WAVE_HEIGHT_DP = 20f
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
  private var barCount = 40
  private var barEnvelope: FloatArray = makeDefaultEnvelope(barCount)
  private var rawSamples: List<Float>? = null
  private var playbackProgress = 0f

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val desiredHeight = dpF(WAVE_HEIGHT_DP).roundToInt()
    val desiredWidth = preferredContentWidth()
    val resolvedWidth = resolveSize(desiredWidth, widthMeasureSpec)
    val resolvedHeight = resolveSize(desiredHeight, heightMeasureSpec)
    setMeasuredDimension(resolvedWidth, resolvedHeight)
  }

  fun updatePlayback(progress: Float, level: Float, isPlaying: Boolean) {
    playbackProgress = progress.coerceIn(0f, 1f)
    invalidate()
  }

  fun setWaveform(samples: List<Float>?, duration: Double? = null) {
    rawSamples =
      samples
        ?.filter { it.isFinite() }
        ?.map { it.coerceIn(0f, 1f) }
        ?.takeIf { it.isNotEmpty() }
    rebuildEnvelope()
    invalidate()
    requestLayout()
  }

  fun preferredContentWidth(maxWidthPx: Int? = null): Int {
    if (maxWidthPx != null) return maxWidthPx.coerceAtLeast(1)
    val desired =
      ((barCount * dpF(BAR_WIDTH_DP)) + ((barCount - 1).coerceAtLeast(0) * dpF(BAR_SPACING_DP)))
        .roundToInt()
    return desired.coerceAtLeast(1)
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
    val expectedBarWidth = dpF(BAR_WIDTH_DP)
    val expectedSpacing = dpF(BAR_SPACING_DP)
    val newCount =
      kotlin.math.max(1, (width.toFloat() / (expectedBarWidth + expectedSpacing)).toInt())
    if (newCount != barCount) {
      barCount = newCount
      rebuildEnvelope()
    }

    val barWidth = expectedBarWidth
    val spacing = expectedSpacing
    val minHeight = dpF(2f)
    val peakHeight = kotlin.math.max(minHeight, kotlin.math.min(height.toFloat(), dpF(18f)))
    val progressX = playbackProgress.coerceIn(0f, 1f) * width.toFloat()
    var x = 0f
    for (index in 0 until barCount) {
      val amplitude = barEnvelope.getOrElse(index) { 0f }.coerceIn(0f, 1f)
      val barHeight = kotlin.math.max(minHeight, peakHeight * amplitude)
      val barStart = x
      val barEnd = x + barWidth
      val fillFraction =
        ((progressX - barStart) / kotlin.math.max(1f, barEnd - barStart)).coerceIn(0f, 1f)
      val renderedHeight = kotlin.math.max(1f, kotlin.math.floor(barHeight))
      val y = kotlin.math.floor(height - renderedHeight)
      val paint =
        when {
          fillFraction <= 0f -> inactivePaint
          fillFraction >= 1f -> activePaint
          else -> blendedPaint.apply {
            color = blend(inactivePaint.color, activePaint.color, fillFraction)
          }
        }
      canvas.drawRoundRect(
        x,
        y,
        x + barWidth,
        y + renderedHeight,
        barWidth * 0.5f,
        barWidth * 0.5f,
        paint,
      )
      x += barWidth + spacing
    }
  }

  private fun rebuildEnvelope() {
    if (barCount <= 0) return
    val normalized = rawSamples.orEmpty()
    if (normalized.isEmpty()) {
      barEnvelope = makeDefaultEnvelope(barCount)
      return
    }

    val resampled = FloatArray(barCount)
    for (index in normalized.indices) {
      val bucketIndex = kotlin.math.min(barCount - 1, (index * barCount) / kotlin.math.max(1, normalized.size))
      resampled[bucketIndex] = kotlin.math.max(resampled[bucketIndex], normalized[index])
    }

    val maxSample = resampled.maxOrNull() ?: 0f
    if (maxSample <= 0.0001f) {
      barEnvelope = FloatArray(barCount)
      return
    }

    for (index in resampled.indices) {
      resampled[index] = (resampled[index] / maxSample).coerceIn(0f, 1f)
    }

    if (resampled.all { it <= 0.001f }) {
      barEnvelope = FloatArray(barCount)
      return
    }

    barEnvelope = resampled
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
  val mediaPreview = FrameLayout(context).apply {
    visibility = View.GONE
    clipChildren = true
    clipToPadding = true
    background = GradientDrawable().apply {
      cornerRadius = dpF(12f)
      setColor(Color.argb(32, 0, 0, 0))
    }
    outlineProvider = ViewOutlineProvider.BACKGROUND
    clipToOutline = true
  }
  val mediaImage = ImageView(context).apply {
    scaleType = ImageView.ScaleType.CENTER_CROP
    adjustViewBounds = false
    setBackgroundColor(Color.argb(42, 0, 0, 0))
  }
  val mediaPlayBadge = TextView(context).apply {
    this.text = "\u25B6"
    setTextColor(Color.WHITE)
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
    gravity = Gravity.CENTER
    background = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(Color.argb(71, 0, 0, 0))
    }
    visibility = View.GONE
  }
  val mediaDurationBadge = TextView(context).apply {
    setTextColor(Color.WHITE)
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
    includeFontPadding = false
    gravity = Gravity.CENTER
    setPadding(dp(8), dp(4), dp(8), dp(4))
    background = GradientDrawable().apply {
      cornerRadius = dpF(11f)
      setColor(Color.argb(143, 0, 0, 0))
    }
    visibility = View.GONE
  }
  val mediaTransferOverlay = FrameLayout(context).apply {
    visibility = View.GONE
    clipChildren = false
    clipToPadding = false
    setBackgroundColor(Color.TRANSPARENT)
    isClickable = true
    isFocusable = true
  }
  val mediaTransferRing = BubbleUploadProgressView(context)
  val mediaTransferSize = TextView(context).apply {
    setTextColor(Color.WHITE)
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
    includeFontPadding = false
    gravity = Gravity.CENTER
    setPadding(dp(8), dp(4), dp(8), dp(4))
    background = GradientDrawable().apply {
      cornerRadius = dpF(10f)
      setColor(Color.argb(124, 10, 14, 20))
    }
    visibility = View.GONE
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
    mediaPreview,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.MATCH_PARENT,
    ),
  )
  mediaPreview.addView(
    mediaImage,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.MATCH_PARENT,
    ),
  )
  mediaPreview.addView(
    mediaPlayBadge,
    FrameLayout.LayoutParams(dp(44), dp(44), Gravity.CENTER),
  )
  mediaPreview.addView(
    mediaDurationBadge,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.TOP or Gravity.START,
    ).apply {
      leftMargin = dp(8)
      topMargin = dp(8)
    },
  )
  mediaPreview.addView(
    mediaTransferOverlay,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.MATCH_PARENT,
    ),
  )
  mediaTransferOverlay.addView(
    mediaTransferRing,
    FrameLayout.LayoutParams(dp(44), dp(44), Gravity.CENTER),
  )
  mediaTransferOverlay.addView(
    mediaTransferSize,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM,
    ).apply {
      bottomMargin = dp(12)
    },
  )
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
    mediaPreview,
    mediaImage,
    mediaPlayBadge,
    mediaDurationBadge,
    mediaTransferOverlay,
    mediaTransferRing,
    mediaTransferSize,
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
