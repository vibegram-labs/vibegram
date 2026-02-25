package expo.modules.vibechatnative

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.PathInterpolator
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.Editable
import android.text.TextWatcher
import android.widget.FrameLayout
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.TextView
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.ViewConfiguration
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

private const val LIST_BOTTOM_THRESHOLD = 40.0
private const val SEND_DURATION_MS = 300L

private val horizontalInterpolator = PathInterpolator(0.23f, 1.0f, 0.32f, 1.0f)
private val verticalInterpolator = PathInterpolator(
  0.19919473f,
  0.010644531f,
  0.27920938f,
  0.9102539f,
)

private data class NativeBubbleShape(
  val showTail: Boolean,
  val topLeft: Float,
  val topRight: Float,
  val bottomRight: Float,
  val bottomLeft: Float,
)

private data class NativeRowItem(
  val kind: String,
  val key: String,
  val text: String,
  val timestamp: String,
  val status: String?,
  val isMe: Boolean,
  val messageId: String?,
  val shape: NativeBubbleShape,
  val messageType: String,
  val mediaUrl: String?,
  val duration: Double?,
  val waveform: List<Float>?,
)

private data class SendTransitionPayload(
  val messageId: String,
  val text: String,
  val timestamp: String,
  val startRect: RectF,
  val startBackgroundRect: RectF? = null,
  val startContentRect: RectF? = null,
  val sourceScrollOffset: Float = 0f,
) {
  fun motionStartRect(): RectF = RectF(startBackgroundRect ?: startRect)
  fun sourceContentRectResolved(): RectF = RectF(startContentRect ?: startRect)
}

private class NativeRowViewHolder(
  val container: FrameLayout,
  val bubbleContainer: FrameLayout,
  val tailView: BubbleTailView,
  val textView: TextView,
  val voiceContainer: FrameLayout,
  val voiceButton: TextView,
  val voiceWaveView: VoiceWaveformView,
  val voiceDurationView: TextView,
  val timeView: TextView,
  val statusView: BubbleStatusIndicatorView,
  val dayLabel: TextView,
) : RecyclerView.ViewHolder(container)

private class BubbleTailView(context: Context) : View(context) {
  private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(255, 106, 79, 207)
  }
  private val path = Path()

  fun configure(isMe: Boolean, color: Int, visible: Boolean) {
    paint.color = color
    rotation = if (isMe) 25f else -25f
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
    // Match iOS tail mask clipping to avoid the tiny top closing-path seam line.
    canvas.clipRect(-5f, 29f * 0.4f, 34f, 34f)
    canvas.drawPath(path, paint)
    canvas.restore()
  }
}

private class BubbleStatusIndicatorView(context: Context) : View(context) {
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
    invalidate()
  }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val w = resolveSize(dp(16), widthMeasureSpec)
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
    val sx = w / 24f
    val sy = h / 24f
    fun p(x: Float, y: Float): Pair<Float, Float> = Pair(x * sx, y * sy)

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

private class VoiceWaveformView(context: Context) : View(context) {
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
      barEnvelope = shapeEnvelope(smoothEnvelope(normalized.toFloatArray()))
      invalidate()
      return
    }
    val bucketSize = normalized.size.toFloat() / barCount.toFloat()
    val next = FloatArray(barCount)
    for (index in 0 until barCount) {
      val start = kotlin.math.floor(index * bucketSize).toInt()
      val end = min(normalized.size, kotlin.math.floor((index + 1) * bucketSize).toInt())
      if (start < end) {
        var sumSquares = 0f
        var peak = 0f
        for (i in start until end) {
          val value = normalized[i]
          sumSquares += value * value
          if (value > peak) peak = value
        }
        val count = (end - start).toFloat()
        val rms = sqrt(sumSquares / max(1f, count))
        val energy = (rms * 0.58f) + (peak * 0.42f)
        next[index] = energy.coerceIn(0f, 1f).toDouble().pow(0.76).toFloat().coerceIn(0.12f, 1f)
      } else {
        val clamped = min(max(0, start), normalized.size - 1)
        next[index] = normalized[clamped]
      }
    }
    barEnvelope = shapeEnvelope(smoothEnvelope(smoothEnvelope(next)))
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
    val spacing = dpF(2f)
    val totalSpacing = spacing * (barCount - 1)
    val barWidth = max(1f, (width - totalSpacing) / barCount.toFloat())
    val minHeight = max(1f, height * 0.28f)
    val maxHeight = max(minHeight + 1f, height * 0.92f)
    var x = 0f
    for (index in 0 until barCount) {
      val normalizedIndex = index / max(1f, barCount.toFloat())
      val base = barEnvelope[index]
      val pulse =
        if (isPlaying) {
          (sin((phase + (index * 0.62f)).toDouble()) * 0.10 + 0.90).toFloat()
        } else {
          1.0f
        }
      val spectralBias = (0.92f + (0.12f * sin((index * 0.52f).toDouble()).toFloat())).coerceIn(0.82f, 1.12f)
      val liveBoost = if (isPlaying) level * 0.22f else 0f
      val amplitude = ((base + liveBoost) * pulse * spectralBias).coerceIn(0.12f, 1f)
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

private class TypingRowViewHolder(val container: FrameLayout, val shimmerView: ShimmerTextView) : RecyclerView.ViewHolder(container)

private const val VIEW_TYPE_MESSAGE = 0
private const val VIEW_TYPE_TYPING = 1

private class NativeRowsAdapter(
  private val context: Context,
  private val appContext: AppContext? = null,
  private val emitNativeEvent: (Map<String, Any>) -> Unit,
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
  private val rows = mutableListOf<NativeRowItem>()
  private val pendingBottomInsertKeys = LinkedHashSet<String>()
  private var hiddenMessageId: String? = null
  private var appearance = ChatListAppearance()
  private var statusResolver: ((NativeRowItem) -> String?)? = null
  private val voicePlayback = VoicePlaybackCoordinator()
  private var externalVoiceMessageId: String? = null
  private var externalVoiceIsPlaying = false
  private var externalVoiceProgress = 0f
  private data class ActiveContextMenuOverlay(
    val popup: PopupWindow,
    val backdropView: View,
    val sheetWrap: View,
    var closing: Boolean = false,
  )

  private var activeContextMenu: ActiveContextMenuOverlay? = null

  init {
    setHasStableIds(true)
  }

  private inner class VoicePlaybackCoordinator {
    private var activeMessageId: String? = null
    private var activeHolder: NativeRowViewHolder? = null
    private var mediaPlayer: MediaPlayer? = null
    private var isPrepared = false
    private val handler = Handler(Looper.getMainLooper())
    private var ticker: Runnable? = null
    private var progress = 0f
    private var level = 0f
    private var isPlaying = false

    fun bind(holder: NativeRowViewHolder, item: NativeRowItem) {
      if (activeMessageId == item.messageId) {
        activeHolder = holder
        applyState(holder, isPlaying, progress, level)
      } else {
        applyState(holder, false, 0f, 0f)
      }
    }

    fun detach(holder: NativeRowViewHolder) {
      if (activeHolder === holder) {
        activeHolder = null
      }
    }

    fun toggle(holder: NativeRowViewHolder, item: NativeRowItem) {
      val messageId = item.messageId?.takeIf { it.isNotBlank() }
      val mediaUrl = item.mediaUrl?.takeIf { it.isNotBlank() }
      Log.d(
        "ChatListView",
        "voice tap messageId=${messageId ?: "-"} status=${item.status ?: "-"} type=${item.messageType} mediaUrl=${shortMediaUrl(mediaUrl)}",
      )
      if (messageId.isNullOrBlank()) {
        Log.w("ChatListView", "voice tap ignored: missing messageId")
        return
      }
      if (mediaUrl.isNullOrBlank()) {
        Log.w("ChatListView", "voice tap ignored: missing mediaUrl messageId=$messageId")
        return
      }

      if (activeMessageId == messageId) {
        val player = mediaPlayer ?: return
        if (!isPrepared) {
          Log.d("ChatListView", "voice tap ignored: player preparing messageId=$messageId")
          return
        }
        if (player.isPlaying) {
          player.pause()
          isPlaying = false
          Log.d("ChatListView", "voice pause messageId=$messageId progress=${"%.3f".format(progress)}")
          applyState(holder, false, progress, level)
        } else {
          player.start()
          isPlaying = true
          Log.d("ChatListView", "voice resume messageId=$messageId progress=${"%.3f".format(progress)}")
        }
        return
      }

      stop(resetProgress = true)

      val player = MediaPlayer()
      try {
        if (mediaUrl.startsWith("content://")) {
          val uri = Uri.parse(mediaUrl)
          Log.d("ChatListView", "voice setDataSource(content) messageId=$messageId uri=${shortMediaUrl(mediaUrl)}")
          player.setDataSource(context, uri)
        } else {
          Log.d("ChatListView", "voice setDataSource(raw) messageId=$messageId uri=${shortMediaUrl(mediaUrl)}")
          player.setDataSource(mediaUrl)
        }
      } catch (error: Throwable) {
        Log.e(
          "ChatListView",
          "voice setDataSource failed messageId=$messageId uri=${shortMediaUrl(mediaUrl)} error=${error.message}",
          error,
        )
        player.release()
        return
      }

      activeMessageId = messageId
      activeHolder = holder
      mediaPlayer = player
      isPrepared = false
      progress = 0f
      level = 0f
      isPlaying = false
      applyState(holder, false, 0f, 0f)

      player.setOnPreparedListener {
        isPrepared = true
        Log.d(
          "ChatListView",
          "voice prepared messageId=$messageId durationMs=${runCatching { it.duration }.getOrDefault(-1)}",
        )
        it.start()
        isPlaying = true
        startTicker()
      }
      player.setOnCompletionListener {
        Log.d("ChatListView", "voice completed messageId=$messageId")
        stop(resetProgress = true)
      }
      player.setOnErrorListener { _, what, extra ->
        Log.e(
          "ChatListView",
          "voice player error messageId=$messageId what=$what extra=$extra uri=${shortMediaUrl(mediaUrl)}",
        )
        stop(resetProgress = true)
        true
      }
      Log.d("ChatListView", "voice prepareAsync messageId=$messageId uri=${shortMediaUrl(mediaUrl)}")
      player.prepareAsync()
    }

    private fun startTicker() {
      if (ticker != null) {
        return
      }
      val runnable = object : Runnable {
        override fun run() {
          val player = mediaPlayer
          if (player == null) {
            stop(resetProgress = true)
            return
          }
          if (!isPrepared) {
            handler.postDelayed(this, 16L)
            return
          }
          val duration: Int
          val position: Int
          try {
            duration = player.duration
            position = player.currentPosition
          } catch (_: IllegalStateException) {
            handler.postDelayed(this, 16L)
            return
          }
          progress =
            if (duration > 0) {
              (position.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
            } else {
              0f
            }
          val t = SystemClock.uptimeMillis() * 0.001f
          level =
            if (player.isPlaying) {
              (0.42f + 0.38f * kotlin.math.abs(kotlin.math.sin((t * 8.5f).toDouble()))).toFloat()
            } else {
              0.12f
            }
          isPlaying = player.isPlaying
          activeHolder?.let { applyState(it, isPlaying, progress, level) }
          handler.postDelayed(this, 16L)
        }
      }
      ticker = runnable
      handler.post(runnable)
    }

    private fun applyState(holder: NativeRowViewHolder, isPlaying: Boolean, progress: Float, level: Float) {
      holder.voiceButton.text = if (isPlaying) "⏸" else "▶"
      holder.voiceWaveView.updatePlayback(progress, level, isPlaying)
    }

    private fun stop(resetProgress: Boolean) {
      ticker?.let { handler.removeCallbacks(it) }
      ticker = null
      mediaPlayer?.setOnCompletionListener(null)
      mediaPlayer?.setOnPreparedListener(null)
      mediaPlayer?.setOnErrorListener(null)
      try {
        mediaPlayer?.stop()
      } catch (_: Throwable) {
        // no-op: player can still be in preparing state
      }
      mediaPlayer?.release()
      mediaPlayer = null
      isPrepared = false
      isPlaying = false
      if (resetProgress) {
        progress = 0f
        level = 0f
      }
      activeHolder?.let { applyState(it, false, progress, level) }
      activeHolder = null
      activeMessageId = null
    }

    private fun shortMediaUrl(value: String?): String {
      if (value.isNullOrBlank()) return "-"
      return if (value.length <= 120) value else value.take(117) + "..."
    }
  }

  private var diffGeneration = 0

  fun setRows(next: List<NativeRowItem>) {
    dismissContextMenu()
    val previous = rows.toList()

    // Fast path: skip if list hasn't changed (same keys in same order with same contents)
    if (previous.size == next.size && previous.size > 0) {
      var same = true
      for (i in previous.indices) {
        if (previous[i] != next[i]) { same = false; break }
      }
      if (same) return
    }

    val isAppendOnly =
      previous.isNotEmpty() &&
        next.size > previous.size &&
        previous.size <= next.size &&
        previous.indices.all { index -> previous[index].key == next[index].key }

    rows.clear()
    rows.addAll(next)
    if (previous.isEmpty()) {
      notifyDataSetChanged()
      return
    }
    if (isAppendOnly) {
      val start = previous.size
      val count = next.size - previous.size
      if (count > 0) {
        for (i in start until next.size) {
          pendingBottomInsertKeys.add(next[i].key)
        }
        notifyItemRangeInserted(start, count)
        return
      }
    }

    // Run DiffUtil on a background thread to avoid blocking the main/UI thread.
    val generation = ++diffGeneration
    val snapshot = rows.toList() // snapshot for the background thread
    diffExecutor.execute {
      val diffResult = DiffUtil.calculateDiff(object : DiffUtil.Callback() {
        override fun getOldListSize(): Int = previous.size
        override fun getNewListSize(): Int = snapshot.size
        override fun areItemsTheSame(oldItemPosition: Int, newItemPosition: Int): Boolean {
          return previous[oldItemPosition].key == snapshot[newItemPosition].key
        }
        override fun areContentsTheSame(oldItemPosition: Int, newItemPosition: Int): Boolean {
          return previous[oldItemPosition] == snapshot[newItemPosition]
        }
      })
      mainHandler.post {
        // Only apply if no newer setRows call has been made while we were diffing
        if (generation == diffGeneration) {
          diffResult.dispatchUpdatesTo(this)
        }
      }
    }
  }

  fun setHiddenMessageId(nextId: String?) {
    val previousId = hiddenMessageId
    hiddenMessageId = nextId
    if (previousId == nextId) {
      return
    }
    previousId?.let { id ->
      val index = findMessageIndex(id)
      if (index >= 0) notifyItemChanged(index)
    }
    nextId?.let { id ->
      val index = findMessageIndex(id)
      if (index >= 0) notifyItemChanged(index)
    }
  }

  fun setAppearance(nextAppearance: ChatListAppearance) {
    if (appearance.visualEquals(nextAppearance)) return
    appearance = nextAppearance
    notifyDataSetChanged()
  }

  fun setStatusResolver(resolver: ((NativeRowItem) -> String?)?) {
    statusResolver = resolver
    notifyDataSetChanged()
  }

  fun refreshStatusDecorations() {
    notifyDataSetChanged()
  }

  fun setVoicePlayback(messageId: String?, isPlaying: Boolean, progress: Float) {
    val clampedProgress = progress.coerceIn(0f, 1f)
    if (
      externalVoiceMessageId == messageId &&
      externalVoiceIsPlaying == isPlaying &&
      kotlin.math.abs(externalVoiceProgress - clampedProgress) < 0.001f
    ) {
      return
    }

    val previousMessageId = externalVoiceMessageId
    externalVoiceMessageId = messageId
    externalVoiceIsPlaying = isPlaying
    externalVoiceProgress = clampedProgress

    // Progress updates can be frequent; update visible holders directly first.
    var updatedVisible = false
    for (index in 0 until itemCount) {
      val row = rows[index]
      if (row.messageId == messageId || row.messageId == previousMessageId) {
        notifyItemChanged(index)
        updatedVisible = true
      }
    }
    if (!updatedVisible) {
      notifyDataSetChanged()
    }
  }

  fun rowAt(position: Int): NativeRowItem? {
    if (position < 0 || position >= rows.size) return null
    return rows[position]
  }

  fun findMessageIndex(messageId: String): Int {
    return rows.indexOfFirst { it.messageId == messageId }
  }

  override fun getItemId(position: Int): Long {
    return rows[position].key.hashCode().toLong()
  }

  override fun getItemViewType(position: Int): Int {
    if (rows[position].messageType == "typing") return VIEW_TYPE_TYPING
    return VIEW_TYPE_MESSAGE
  }

  override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
    if (viewType == VIEW_TYPE_TYPING) {
      val root = FrameLayout(context).apply {
        layoutParams = RecyclerView.LayoutParams(
          RecyclerView.LayoutParams.MATCH_PARENT,
          RecyclerView.LayoutParams.WRAP_CONTENT,
        )
        clipChildren = false
        clipToPadding = false
        setPadding(dp(8), dp(4), dp(8), dp(4))
      }
      val shimmerView = ShimmerTextView(context)
      shimmerView.text = "Typing..."
      root.addView(shimmerView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT).apply {
        leftMargin = dp(4)
      })
      return TypingRowViewHolder(root, shimmerView)
    }

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

    val text = TextView(context).apply {
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
      setTextColor(Color.WHITE)
      setLineSpacing(0f, 1.1f)
      includeFontPadding = false
      maxWidth = (context.resources.displayMetrics.widthPixels * 0.85f).toInt()
    }

    val voiceContainer = FrameLayout(context).apply {
      visibility = View.GONE
      alpha = 1f
    }

    val voiceButton = TextView(context).apply {
      this.text = "▶"
      gravity = Gravity.CENTER
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      setTextColor(Color.WHITE)
      background = GradientDrawable().apply {
        setColor(Color.argb(56, 255, 255, 255))
        shape = GradientDrawable.OVAL
      }
      includeFontPadding = false
    }

    val voiceWave = VoiceWaveformView(context)

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
      text,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    voiceContainer.addView(
      voiceButton,
      FrameLayout.LayoutParams(dp(30), dp(30)).apply {
        gravity = Gravity.START or Gravity.CENTER_VERTICAL
      },
    )
    voiceContainer.addView(
      voiceWave,
      FrameLayout.LayoutParams(dp(128), dp(10)).apply {
        gravity = Gravity.START or Gravity.CENTER_VERTICAL
        leftMargin = dp(38)
      },
    )
    voiceContainer.addView(
      voiceDuration,
      FrameLayout.LayoutParams(dp(42), FrameLayout.LayoutParams.WRAP_CONTENT).apply {
        gravity = Gravity.END or Gravity.CENTER_VERTICAL
      },
    )
    bubble.addView(
      voiceContainer,
      FrameLayout.LayoutParams(dp(188), dp(34)).apply {
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
    root.addView(bubble)
    root.addView(
      tail,
      FrameLayout.LayoutParams(dp(29), dp(29)),
    )
    root.addView(
      day,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER_HORIZONTAL,
      ),
    )

    return NativeRowViewHolder(root, bubble, tail, text, voiceContainer, voiceButton, voiceWave, voiceDuration, time, status, day)
  }

  override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
    val item = rows[position]
    
    if (holder is TypingRowViewHolder) {
      if (pendingBottomInsertKeys.remove(item.key)) {
        holder.container.clearAnimation()
        holder.container.alpha = 0f
        holder.container.translationY = dpF(18f)
        holder.container.animate()
          .alpha(1f)
          .translationY(0f)
          .setDuration(220L)
          .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
          .start()
      } else {
        holder.container.alpha = 1f
        holder.container.translationY = 0f
      }
      return
    }

    if (holder is NativeRowViewHolder) {
      holder.bind(item, hiddenMessageId == item.messageId)
      if (pendingBottomInsertKeys.remove(item.key)) {
        holder.container.clearAnimation()
        holder.container.alpha = 0f
        holder.container.translationY = dpF(18f)
        holder.container.animate()
          .alpha(1f)
          .translationY(0f)
          .setDuration(220L)
          .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
          .start()
      } else {
        holder.container.alpha = 1f
        holder.container.translationY = 0f
      }
    }
  }

  override fun getItemCount(): Int = rows.size

  override fun onViewRecycled(holder: RecyclerView.ViewHolder) {
    super.onViewRecycled(holder)
    if (holder is NativeRowViewHolder) {
      holder.container.setOnLongClickListener(null)
      voicePlayback.detach(holder)
      holder.voiceWaveView.updatePlayback(0f, 0f, false)
      holder.voiceWaveView.setWaveform(null)
      holder.voiceButton.text = "▶"
    } else if (holder is TypingRowViewHolder) {
      holder.shimmerView.stopShimmer()
    }
  }

  override fun onViewAttachedToWindow(holder: RecyclerView.ViewHolder) {
    super.onViewAttachedToWindow(holder)
    if (holder is TypingRowViewHolder) {
      holder.shimmerView.startShimmer()
    }
  }

  override fun onViewDetachedFromWindow(holder: RecyclerView.ViewHolder) {
    super.onViewDetachedFromWindow(holder)
    if (holder is TypingRowViewHolder) {
      holder.shimmerView.stopShimmer()
    }
  }

  private fun NativeRowViewHolder.bind(item: NativeRowItem, hidden: Boolean) {
    if (item.kind == "day") {
      voicePlayback.detach(this)
      dayLabel.visibility = View.VISIBLE
      dayLabel.text = item.text
      dayLabel.setTextColor(appearance.dayTextColor)
      dayLabel.background = GradientDrawable().apply {
        cornerRadius = dpF(12f)
        setColor(appearance.dayBackgroundColor)
        setStroke(1, appearance.dayBorderColor)
      }
      bubbleContainer.visibility = View.GONE
      tailView.visibility = View.GONE
      statusView.visibility = View.GONE
      voiceWaveView.setWaveform(null)
      container.setOnLongClickListener(null)
      return
    }

    dayLabel.visibility = View.GONE
    bubbleContainer.visibility = View.VISIBLE
    bubbleContainer.alpha = if (hidden) 0f else 1f

    val isVoice = item.messageType == "voice" || item.messageType == "music"
    textView.text = item.text
    timeView.text = item.timestamp
    textView.setTextColor(if (item.isMe) appearance.textColorMe else appearance.textColorThem)
    timeView.setTextColor(if (item.isMe) appearance.timeColorMe else appearance.timeColorThem)
    voiceDurationView.text = formatDuration(item.duration)
    voiceWaveView.setWaveform(item.waveform)

    val lp = bubbleContainer.layoutParams as FrameLayout.LayoutParams
    lp.gravity = if (item.isMe) Gravity.END else Gravity.START
    bubbleContainer.layoutParams = lp

    val bubbleThemFill = appearance.bubbleThemColor
    val metaBaseColor = if (item.isMe) appearance.timeColorMe else appearance.timeColorThem
    val displayStatus = statusResolver?.invoke(item) ?: item.status
    statusView.bind(displayStatus, metaBaseColor)
    val showStatus = item.isMe && when (displayStatus?.lowercase()) {
      "pending", "sent", "delivered", "read", "error" -> true
      else -> false
    }
    statusView.visibility = if (showStatus) View.VISIBLE else View.GONE

    val statusLp = statusView.layoutParams as FrameLayout.LayoutParams
    statusLp.gravity = Gravity.END or Gravity.BOTTOM
    statusLp.rightMargin = 0
    statusLp.bottomMargin = 0
    statusView.layoutParams = statusLp

    val timeLp = timeView.layoutParams as FrameLayout.LayoutParams
    timeLp.gravity = Gravity.END or Gravity.BOTTOM
    timeLp.rightMargin = if (showStatus) dp(16 + 3) else 0
    timeLp.bottomMargin = 0
    timeView.layoutParams = timeLp

    val drawable = if (item.isMe) {
      GradientDrawable(
        GradientDrawable.Orientation.TL_BR,
        appearance.bubbleMeGradient,
      )
    } else {
      GradientDrawable().apply { setColor(bubbleThemFill) }
    }
    drawable.cornerRadii = floatArrayOf(
      dpF(item.shape.topLeft), dpF(item.shape.topLeft),
      dpF(item.shape.topRight), dpF(item.shape.topRight),
      dpF(item.shape.bottomRight), dpF(item.shape.bottomRight),
      dpF(item.shape.bottomLeft), dpF(item.shape.bottomLeft),
    )
    bubbleContainer.background = drawable

    if (isVoice) {
      bubbleContainer.setPadding(dp(10), dp(7), dp(10), dp(17))
      textView.visibility = View.GONE
      voiceContainer.visibility = View.VISIBLE
      bubbleContainer.minimumWidth = dp(220)
      val voiceAccent = if (item.isMe) withAlpha(appearance.textColorMe, 0.20f) else withAlpha(appearance.textColorThem, 0.13f)
      val voiceIconTint = if (item.isMe) appearance.textColorMe else appearance.textColorThem
      voiceButton.background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(voiceAccent)
      }
      voiceButton.setTextColor(voiceIconTint)
      voiceDurationView.setTextColor(if (item.isMe) withAlpha(appearance.textColorMe, 0.82f) else withAlpha(appearance.textColorThem, 0.78f))
      voiceWaveView.setColors(
        activeColor = withAlpha(voiceIconTint, 0.96f),
        inactiveColor = withAlpha(voiceIconTint, if (item.isMe) 0.34f else 0.26f),
      )
      voiceButton.setOnClickListener {
        voicePlayback.toggle(this, item)
      }
      val isExternallyActive =
        externalVoiceMessageId != null &&
          item.messageId != null &&
          externalVoiceMessageId == item.messageId
      if (isExternallyActive) {
        voicePlayback.detach(this)
        voiceWaveView.updatePlayback(externalVoiceProgress, if (externalVoiceIsPlaying) 0.2f else 0f, externalVoiceIsPlaying)
        voiceButton.text = if (externalVoiceIsPlaying) "⏸" else "▶"
      } else {
        voicePlayback.bind(this, item)
      }
    } else {
      bubbleContainer.setPadding(dp(10), dp(7), dp(10), dp(7))
      textView.visibility = View.VISIBLE
      voiceContainer.visibility = View.GONE
      bubbleContainer.minimumWidth = dp(26)
      voiceButton.setOnClickListener(null)
      voicePlayback.detach(this)
      voiceWaveView.updatePlayback(0f, 0f, false)
      voiceWaveView.setWaveform(null)

      val timeWidth = kotlin.math.ceil(timeView.paint.measureText(item.timestamp ?: "")).toInt()
      val statusReserve = if (showStatus) dp(16 + 3) else 0
      val metaReserve = dp(6) + timeWidth + statusReserve
      val maxBubbleWidth = (context.resources.displayMetrics.widthPixels * 0.85f).toInt()
      textView.maxWidth = (maxBubbleWidth - dp(20) - metaReserve).coerceAtLeast(dp(24))
      val textLp = textView.layoutParams as FrameLayout.LayoutParams
      textLp.gravity = Gravity.START or Gravity.TOP
      textLp.rightMargin = metaReserve
      textLp.bottomMargin = 0
      textView.layoutParams = textLp
    }

    container.setOnLongClickListener {
      if (hidden) return@setOnLongClickListener false
      val messageId = item.messageId?.takeIf { it.isNotBlank() } ?: return@setOnLongClickListener false
      container.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
      showContextMenu(anchor = bubbleContainer, item = item, messageId = messageId)
      true
    }

    if (!hidden && item.shape.showTail) {
      tailView.configure(
        isMe = item.isMe,
        visible = true,
        color = if (item.isMe) appearance.bubbleMeGradient.lastOrNull() ?: Color.WHITE else bubbleThemFill,
      )
      val tailLp = tailView.layoutParams as FrameLayout.LayoutParams
      tailLp.gravity = if (item.isMe) Gravity.END or Gravity.BOTTOM else Gravity.START or Gravity.BOTTOM
      tailLp.marginStart = 0
      tailLp.marginEnd = 0
      tailLp.bottomMargin = 0
      if (item.isMe) tailLp.marginEnd = dp(-28) else tailLp.marginStart = dp(-28)
      tailView.layoutParams = tailLp
    } else {
      tailView.visibility = View.GONE
    }
  }

  private fun dismissContextMenu(animated: Boolean = true) {
    val active = activeContextMenu ?: return
    if (active.closing) return
    if (!animated) {
      active.popup.dismiss()
      return
    }
    active.closing = true
    active.backdropView.animate()
      .alpha(0f)
      .setDuration(170L)
      .start()
    active.sheetWrap.animate()
      .alpha(0f)
      .translationY(dpF(36f))
      .setDuration(220L)
      .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
      .setListener(object : AnimatorListenerAdapter() {
        override fun onAnimationEnd(animation: Animator) {
          active.popup.dismiss()
        }
      })
      .start()
  }

  private fun showContextMenu(anchor: View, item: NativeRowItem, messageId: String) {
    dismissContextMenu(animated = false)

    emitNativeEvent(
      mapOf(
        "type" to "contextMenuOpened",
        "messageId" to messageId,
      ),
    )

    val reactionSource = IntArray(2).also { anchor.getLocationInWindow(it) }
    val reactionSourceX = reactionSource[0] + (anchor.width / 2f)
    val reactionSourceY = reactionSource[1] + (anchor.height * 0.20f)

    val actions = ArrayList<Pair<String, String>>()
    actions.add("reply" to "Reply")
    if (item.text.isNotBlank()) {
      actions.add("copy" to "Copy")
    }
    if (item.isMe && item.text.isNotBlank()) {
      actions.add("edit" to "Edit")
    }
    actions.add("pin" to "Pin")
    if (item.isMe && item.status?.lowercase() == "error") {
      actions.add("resend" to "Resend")
    }
    actions.add("delete" to "Delete")

    fun luminance(color: Int): Float {
      fun channel(v: Int): Float {
        val s = (v / 255f)
        return if (s <= 0.03928f) s / 12.92f else ((s + 0.055f) / 1.055f).pow(2.4f)
      }
      return 0.2126f * channel(Color.red(color)) + 0.7152f * channel(Color.green(color)) + 0.0722f * channel(Color.blue(color))
    }

    val isLightTheme = luminance(appearance.bubbleThemColor) > 0.45f
    val cardFill = if (isLightTheme) Color.argb(236, 248, 251, 255) else Color.argb(236, 18, 22, 29)
    val cardStroke = if (isLightTheme) Color.argb(64, 255, 255, 255) else Color.argb(30, 255, 255, 255)
    val textColor = if (isLightTheme) Color.argb(240, 20, 24, 32) else Color.argb(236, 255, 255, 255)
    val secondaryText = if (isLightTheme) Color.argb(190, 36, 42, 52) else Color.argb(190, 245, 247, 255)
    val dividerColor = if (isLightTheme) Color.argb(24, 16, 24, 32) else Color.argb(26, 255, 255, 255)
    val chipFill = if (isLightTheme) Color.argb(34, 18, 26, 38) else Color.argb(22, 255, 255, 255)
    val rowFill = if (isLightTheme) Color.argb(18, 16, 24, 32) else Color.argb(10, 255, 255, 255)
    val scrimColor = if (isLightTheme) Color.argb(64, 8, 12, 20) else Color.argb(92, 0, 0, 0)

    fun makeCardContainer(cornerDp: Float): FrameLayout {
      val card = FrameLayout(context).apply {
        clipChildren = true
        clipToPadding = true
        background = GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadius = dpF(cornerDp)
          setColor(cardFill)
          setStroke(max(1, dp(1)), cardStroke)
        }
        elevation = dpF(12f)
      }
      if (appContext != null) {
        val glass = LiquidGlassView(context, appContext).apply {
          layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
          )
          setCornerRadius(cornerDp.toDouble())
          setBlurIntensity(18.0)
          setBlurReductionFactor(4.0)
          setInteractive(false)
          setPressFeedbackEnabled(false)
          setTint(if (isLightTheme) "light" else "dark")
          alpha = 0.92f
        }
        card.addView(glass)
      }
      return card
    }

    val overlayRoot = FrameLayout(context).apply {
      layoutParams = ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      )
      isClickable = true
      isFocusable = true
      isFocusableInTouchMode = true
      setBackgroundColor(Color.TRANSPARENT)
    }

    val backdropWrap = FrameLayout(context).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
      alpha = 0f
    }
    if (appContext != null) {
      backdropWrap.addView(
        LiquidGlassView(context, appContext).apply {
          layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
          )
          setCornerRadius(0.0)
          setBlurIntensity(22.0)
          setBlurReductionFactor(4.0)
          setInteractive(false)
          setPressFeedbackEnabled(false)
          setEffect("clear")
          setTint(if (isLightTheme) "light" else "dark")
          alpha = 0.36f
        },
      )
    }
    val scrimView = View(context).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
      background = ColorDrawable(scrimColor)
    }
    backdropWrap.addView(scrimView)
    overlayRoot.addView(backdropWrap)

    val sheetWrap = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      alpha = 0f
      translationY = dpF(40f)
      setPadding(dp(14), dp(14), dp(14), dp(14))
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.BOTTOM,
      )
      setOnClickListener { }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        isForceDarkAllowed = false
      }
    }
    overlayRoot.addView(sheetWrap)

    val reactionCard = makeCardContainer(20f)
    val reactionContent = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(10), dp(8), dp(10), dp(10))
    }
    reactionContent.addView(
      TextView(context).apply {
        text = "React"
        setTextColor(secondaryText)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setPadding(dp(4), dp(2), dp(4), dp(6))
      },
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    val reactionRow = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
    }
    reactionContent.addView(
      reactionRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    reactionCard.addView(
      reactionContent,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    sheetWrap.addView(
      reactionCard,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        gravity = Gravity.CENTER_HORIZONTAL
      },
    )

    val reactions = listOf("👍", "👎", "❤️", "🔥", "🎉", "💩")
    for ((index, emoji) in reactions.withIndex()) {
      val chip = TextView(context).apply {
        text = emoji
        gravity = Gravity.CENTER
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        setPadding(dp(9), dp(7), dp(9), dp(7))
        background = GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadius = dpF(14f)
          setColor(chipFill)
        }
        setOnClickListener {
          emitNativeEvent(
            mapOf(
              "type" to "contextMenuReaction",
              "emoji" to emoji,
              "messageId" to messageId,
              "sourceX" to reactionSourceX.toDouble(),
              "sourceY" to reactionSourceY.toDouble(),
            ),
          )
          dismissContextMenu()
        }
      }
      reactionRow.addView(
        chip,
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.WRAP_CONTENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
          if (index > 0) marginStart = dp(6)
        },
      )
    }

    val actionsCard = makeCardContainer(20f)
    val actionsContent = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(8), dp(8), dp(8), dp(8))
    }
    actionsContent.addView(
      TextView(context).apply {
        text = "Message"
        setTextColor(secondaryText)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setPadding(dp(8), dp(4), dp(8), dp(8))
      },
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    for ((i, action) in actions.withIndex()) {
      val (actionId, label) = action
      if (i > 0) {
        actionsContent.addView(
          View(context).apply { background = ColorDrawable(dividerColor) },
          LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            max(1, dp(1)),
          ).apply {
            marginStart = dp(8)
            marginEnd = dp(8)
          },
        )
      }
      val rowButton = TextView(context).apply {
        text = label
        gravity = Gravity.CENTER_VERTICAL
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        setTextColor(
          if (actionId == "delete") {
            if (isLightTheme) Color.argb(255, 217, 59, 59) else Color.argb(255, 255, 123, 123)
          } else textColor
        )
        setPadding(dp(12), dp(12), dp(12), dp(12))
        background = GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadius = dpF(14f)
          setColor(Color.TRANSPARENT)
        }
        setOnClickListener {
          emitNativeEvent(
            mapOf(
              "type" to "contextMenuAction",
              "action" to actionId,
              "messageId" to messageId,
            ),
          )
          dismissContextMenu()
        }
        setOnTouchListener { v, event ->
          when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> v.background = GradientDrawable().apply {
              shape = GradientDrawable.RECTANGLE
              cornerRadius = dpF(14f)
              setColor(rowFill)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> v.background = GradientDrawable().apply {
              shape = GradientDrawable.RECTANGLE
              cornerRadius = dpF(14f)
              setColor(Color.TRANSPARENT)
            }
          }
          false
        }
      }
      actionsContent.addView(
        rowButton,
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.MATCH_PARENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ),
      )
    }
    actionsCard.addView(
      actionsContent,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    sheetWrap.addView(
      actionsCard,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(10)
      },
    )

    val popup = PopupWindow(
      overlayRoot,
      ViewGroup.LayoutParams.MATCH_PARENT,
      ViewGroup.LayoutParams.MATCH_PARENT,
      true,
    ).apply {
      isOutsideTouchable = false
      isClippingEnabled = true
      setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
      elevation = dpF(20f)
      setOnDismissListener {
        if (activeContextMenu?.popup === this) {
          activeContextMenu = null
        }
      }
    }
    val activeOverlay = ActiveContextMenuOverlay(
      popup = popup,
      backdropView = backdropWrap,
      sheetWrap = sheetWrap,
    )
    activeContextMenu = activeOverlay

    overlayRoot.setOnClickListener { dismissContextMenu() }
    overlayRoot.setOnKeyListener { _, keyCode, event ->
      if (keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
        dismissContextMenu()
        true
      } else {
        false
      }
    }

    popup.showAtLocation(anchor.rootView, Gravity.NO_GRAVITY, 0, 0)
    overlayRoot.post {
      overlayRoot.requestFocus()
      backdropWrap.animate()
        .alpha(1f)
        .setDuration(220L)
        .setInterpolator(PathInterpolator(0.22f, 0f, 0f, 1f))
        .start()
      sheetWrap.animate()
        .alpha(1f)
        .translationY(0f)
        .setDuration(280L)
        .setInterpolator(PathInterpolator(0.16f, 1f, 0.3f, 1f))
        .start()
      reactionCard.scaleX = 0.985f
      reactionCard.scaleY = 0.985f
      reactionCard.animate()
        .scaleX(1f)
        .scaleY(1f)
        .setDuration(250L)
        .setInterpolator(PathInterpolator(0.16f, 1f, 0.3f, 1f))
        .start()
      actionsCard.scaleX = 0.985f
      actionsCard.scaleY = 0.985f
      actionsCard.animate()
        .scaleX(1f)
        .scaleY(1f)
        .setStartDelay(20L)
        .setDuration(260L)
        .setInterpolator(PathInterpolator(0.16f, 1f, 0.3f, 1f))
        .start()
    }
  }

  fun bubbleRectInParent(position: Int, parent: View): RectF? {
    val holder = (parent as? ChatListView)?.recyclerView?.findViewHolderForAdapterPosition(position) as? NativeRowViewHolder
      ?: return null
    val location = IntArray(2)
    holder.bubbleContainer.getLocationInWindow(location)
    val parentLocation = IntArray(2)
    parent.getLocationInWindow(parentLocation)
    val x = (location[0] - parentLocation[0]).toFloat()
    val y = (location[1] - parentLocation[1]).toFloat()
    return RectF(
      x,
      y,
      x + holder.bubbleContainer.width,
      y + holder.bubbleContainer.height,
    )
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

  private fun formatDuration(value: Double?): String {
    val totalSeconds = max(0, (value ?: 0.0).roundToInt())
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return String.format("%d:%02d", minutes, seconds)
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).toInt()
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }
}

private class NativeChatInputBar(
  context: Context,
) : FrameLayout(context) {
  interface Listener {
    fun onTextChanged(text: String)
    fun onAttachmentPressed()
    fun onSendText(text: String, messageId: String)
    fun onRecordingState(isRecording: Boolean, isLocked: Boolean)
    fun onRecordingVad(level: Float)
    fun onRecordingCanceled()
    fun onVoiceRecorded(uri: String, durationSeconds: Double, waveform: List<Float>)
  }

  var listener: Listener? = null

  private val row = LinearLayout(context)
  private val textPill = FrameLayout(context)
  private val input = EditText(context)
  private val attachmentButton = FrameLayout(context)
  private val attachmentIcon = ChatInputActionIconView(context)
  private val actionButton = FrameLayout(context)
  private val actionIcon = ChatInputActionIconView(context)
  
  private val recordingStatusContainer = LinearLayout(context)
  private val recordingDot = View(context)
  private val statusText = TextView(context)
  private val uiHandler = Handler(Looper.getMainLooper())
  private val longPressTimeoutMs = min(220, ViewConfiguration.getLongPressTimeout())

  private var surfaceColor = Color.argb(246, 20, 24, 30)
  private var inputTextColor = Color.WHITE
  private var inputHintColor = Color.argb(150, 255, 255, 255)
  private var passiveIconColor = Color.WHITE
  private var accentColor = Color.argb(255, 106, 79, 207)
  private var neutralButtonColor = Color.argb(36, 255, 255, 255)

  private var longPressArmed = false
  private var longPressStarted = false
  private var lockActivatedInGesture = false
  private var downX = 0f
  private var downY = 0f

  private var isRecording = false
  private var isLockedRecording = false
  private var recorder: MediaRecorder? = null
  private var recordingFile: File? = null
  private var recordingStartedAtMs = 0L
  private var vadTicker: Runnable? = null
  private val recordingAmplitudes = ArrayList<Int>(256)

  private val longPressRunnable = Runnable {
    longPressArmed = false
    if (startVoiceRecording()) {
      longPressStarted = true
      lockActivatedInGesture = false
      performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    }
  }

  init {
    clipChildren = false
    clipToPadding = false
    setPadding(dp(8), dp(6), dp(8), dp(6))

    row.orientation = LinearLayout.VERTICAL
    row.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
    addView(row)

    val containerRow = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.BOTTOM
      layoutParams = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LayoutParams.WRAP_CONTENT,
      )
    }
    row.addView(containerRow)

    attachmentButton.layoutParams = LinearLayout.LayoutParams(dp(42), dp(42)).apply {
      rightMargin = dp(8)
      bottomMargin = dp(2)
    }
    attachmentButton.background = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(Color.TRANSPARENT)
    }
    containerRow.addView(attachmentButton)

    attachmentIcon.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    attachmentIcon.icon = ChatInputActionIcon.ATTACH
    attachmentIcon.tintColor = passiveIconColor
    attachmentButton.addView(attachmentIcon)

    textPill.layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply {
      rightMargin = dp(8)
    }
    textPill.background = GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = dpF(21f)
      setColor(Color.argb(245, 20, 24, 30))
    }
    containerRow.addView(textPill)

    input.layoutParams = FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
       gravity = Gravity.CENTER_VERTICAL
    }
    input.setBackgroundColor(Color.TRANSPARENT)
    input.setTextColor(Color.WHITE)
    input.setHintTextColor(Color.argb(150, 255, 255, 255))
    input.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    input.maxLines = 4
    input.minLines = 1
    input.setPadding(dp(16), dp(10), dp(16), dp(10))
    textPill.addView(input)

    recordingStatusContainer.layoutParams = FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT).apply {
      gravity = Gravity.CENTER_VERTICAL
    }
    recordingStatusContainer.orientation = LinearLayout.HORIZONTAL
    recordingStatusContainer.gravity = Gravity.CENTER
    recordingStatusContainer.visibility = View.GONE
    
    recordingDot.layoutParams = LinearLayout.LayoutParams(dp(8), dp(8)).apply {
      rightMargin = dp(6)
    }
    recordingDot.background = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(Color.parseColor("#FF3B30"))
    }
    recordingStatusContainer.addView(recordingDot)

    statusText.layoutParams = LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
    statusText.setTextColor(Color.argb(220, 255, 255, 255))
    statusText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    recordingStatusContainer.addView(statusText)
    
    textPill.addView(recordingStatusContainer)

    actionButton.layoutParams = LinearLayout.LayoutParams(dp(42), dp(42)).apply {
      bottomMargin = dp(2)
    }
    actionButton.background = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(neutralButtonColor)
    }
    containerRow.addView(actionButton)

    actionIcon.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    actionIcon.icon = ChatInputActionIcon.MIC
    actionIcon.tintColor = passiveIconColor
    actionButton.addView(actionIcon)

    input.addTextChangedListener(object : TextWatcher {
      override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
      override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
        listener?.onTextChanged(s?.toString().orEmpty())
        refreshActionVisual()
      }

      override fun afterTextChanged(s: Editable?) = Unit
    })

    attachmentButton.setOnClickListener {
      if (!isRecording) listener?.onAttachmentPressed()
    }
    attachmentButton.setOnTouchListener { _, event -> handleAttachmentTouch(event) }
    actionButton.setOnTouchListener { _, event -> handleActionTouch(event) }
    refreshActionVisual()
  }

  fun setPlaceholder(value: String) {
    input.hint = value
  }

  fun applyAppearance(appearance: ChatListAppearance, isDark: Boolean, backgroundReferenceColor: Int) {
    val ref = backgroundReferenceColor
    val textBase = appearance.textColorThem
    val accentBase = appearance.bubbleMeGradient.lastOrNull() ?: appearance.textColorMe
    surfaceColor =
      if (isDark) {
        withAlpha(blend(ref, Color.BLACK, 0.42f), 0.95f)
      } else {
        withAlpha(blend(ref, Color.WHITE, 0.78f), 0.98f)
      }
    inputTextColor = textBase
    inputHintColor = withAlpha(textBase, if (isDark) 0.54f else 0.46f)
    passiveIconColor = withAlpha(textBase, if (isDark) 0.92f else 0.86f)
    accentColor = accentBase
    neutralButtonColor = surfaceColor

    textPill.background = GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = dpF(21f)
      setColor(surfaceColor)
    }
    input.setTextColor(inputTextColor)
    input.setHintTextColor(inputHintColor)
    statusText.setTextColor(withAlpha(textBase, if (isDark) 0.88f else 0.82f))
    refreshActionVisual()
  }

  private fun handleActionTouch(event: MotionEvent): Boolean {
    val hasText = input.text?.toString()?.trim()?.isNotEmpty() == true

    if (hasText && !isRecording) {
      when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
          pressVisual(true)
          return true
        }
        MotionEvent.ACTION_UP -> {
          pressVisual(false)
          sendCurrentText()
          return true
        }
        MotionEvent.ACTION_CANCEL -> {
          pressVisual(false)
          return true
        }
      }
    }

    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        downX = event.x
        downY = event.y
        longPressStarted = false
        lockActivatedInGesture = false
        if (isRecording && isLockedRecording) {
          pressVisual(true)
          return true
        }
        longPressArmed = true
        uiHandler.postDelayed(longPressRunnable, longPressTimeoutMs.toLong())
        pressVisual(true)
        return true
      }

      MotionEvent.ACTION_MOVE -> {
        if (isRecording) {
          val dx = event.x - downX
          val dy = event.y - downY
          if (!isLockedRecording && dy < -dp(44)) {
            isLockedRecording = true
            lockActivatedInGesture = true
            updateRecordingStatus("Locked • Tap to send")
            listener?.onRecordingState(true, true)
            performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
          }
          if (!isLockedRecording && dx < -dp(72)) {
            cancelVoiceRecording()
            pressVisual(false)
            return true
          }
        }
        return true
      }

      MotionEvent.ACTION_UP -> {
        uiHandler.removeCallbacks(longPressRunnable)
        longPressArmed = false
        pressVisual(false)
        if (isRecording) {
          if (isLockedRecording && lockActivatedInGesture) {
            return true
          }
          stopVoiceRecording(send = true)
          return true
        }
        if (isRecording && isLockedRecording) {
          stopVoiceRecording(send = true)
          return true
        }
        if (longPressStarted) return true
        if (isLockedRecording && isRecording) {
          stopVoiceRecording(send = true)
          return true
        }
        if (isRecording && !isLockedRecording) {
          stopVoiceRecording(send = true)
          return true
        }
        if (recordingStartedAtMs > 0L && isLockedRecording) {
          stopVoiceRecording(send = true)
          return true
        }
        if ((input.text?.toString()?.trim()?.isNotEmpty() == true)) {
          sendCurrentText()
        }
        return true
      }

      MotionEvent.ACTION_CANCEL -> {
        uiHandler.removeCallbacks(longPressRunnable)
        longPressArmed = false
        pressVisual(false)
        if (isRecording && !isLockedRecording) {
          stopVoiceRecording(send = true)
        }
        return true
      }
    }
    return false
  }

  private fun sendCurrentText() {
    val text = input.text?.toString()?.trim().orEmpty()
    if (text.isEmpty()) return
    val messageId = "android-native-${UUID.randomUUID()}"
    listener?.onSendText(text, messageId)
    input.setText("")
  }

  private fun refreshActionVisual() {
    val hasText = input.text?.toString()?.trim()?.isNotEmpty() == true
    actionIcon.icon =
      when {
        isRecording -> ChatInputActionIcon.RECORDING_DOT
        hasText -> ChatInputActionIcon.SEND
        else -> ChatInputActionIcon.MIC
      }
    val actionFillColor =
      when {
        isRecording -> withAlpha(accentColor, if (isLockedRecording) 0.94f else 0.86f)
        hasText -> withAlpha(accentColor, 0.94f)
        else -> surfaceColor
      }
    actionIcon.tintColor =
      when {
        isRecording || hasText -> Color.WHITE
        else -> passiveIconColor
      }
    actionButton.background = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(actionFillColor)
    }
    attachmentIcon.tintColor = passiveIconColor
    attachmentButton.alpha = if (isRecording) 0.45f else 1f
    attachmentButton.background = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(surfaceColor)
    }
    if (isRecording) {
      input.visibility = View.INVISIBLE
      recordingStatusContainer.visibility = View.VISIBLE
    } else {
      input.visibility = View.VISIBLE
      recordingStatusContainer.visibility = View.GONE
    }
  }

  private fun pressVisual(pressed: Boolean) {
    actionButton.animate()
      .scaleX(if (pressed) 0.96f else 1f)
      .scaleY(if (pressed) 0.96f else 1f)
      .alpha(if (pressed) 0.88f else 1f)
      .setDuration(if (pressed) 80L else 140L)
      .start()
  }

  private fun handleAttachmentTouch(event: MotionEvent): Boolean {
    if (isRecording) return true
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        attachmentButton.animate()
          .scaleX(0.96f)
          .scaleY(0.96f)
          .alpha(0.88f)
          .setDuration(70L)
          .start()
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        attachmentButton.animate()
          .scaleX(1f)
          .scaleY(1f)
          .alpha(1f)
          .setDuration(120L)
          .start()
      }
    }
    return false
  }

  private fun updateRecordingStatus(text: String) {
    statusText.text = text
    refreshActionVisual()
  }

  private fun startVoiceRecording(): Boolean {
    if (isRecording) return true
    val outputFile = File(context.cacheDir, "vibe-voice-${UUID.randomUUID()}.m4a")
    val mediaRecorder = MediaRecorder()
    return try {
      mediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
      mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
      mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
      mediaRecorder.setAudioEncodingBitRate(64000)
      mediaRecorder.setAudioSamplingRate(44100)
      mediaRecorder.setOutputFile(outputFile.absolutePath)
      mediaRecorder.prepare()
      mediaRecorder.start()

      recorder = mediaRecorder
      recordingFile = outputFile
      recordingStartedAtMs = SystemClock.elapsedRealtime()
      isRecording = true
      isLockedRecording = false
      recordingAmplitudes.clear()
      refreshActionVisual()
      listener?.onRecordingState(true, false)
      startVadTicker()
      true
    } catch (_: Throwable) {
      try {
        mediaRecorder.reset()
      } catch (_: Throwable) {
      }
      try {
        mediaRecorder.release()
      } catch (_: Throwable) {
      }
      recorder = null
      recordingFile = null
      recordingStartedAtMs = 0L
      isRecording = false
      isLockedRecording = false
      listener?.onRecordingCanceled()
      listener?.onRecordingState(false, false)
      false
    }
  }

  private fun startVadTicker() {
    vadTicker?.let { uiHandler.removeCallbacks(it) }
    val ticker = object : Runnable {
      override fun run() {
        if (!isRecording) return
        val recorderRef = recorder
        val amplitude =
          try {
            recorderRef?.maxAmplitude ?: 0
          } catch (_: Throwable) {
            0
          }
        recordingAmplitudes.add(amplitude)
        val normalized = (amplitude / 32767f).coerceIn(0f, 1f)
        listener?.onRecordingVad(normalized)
        
        val elapsedMs = max(0L, SystemClock.elapsedRealtime() - recordingStartedAtMs)
        val seconds = (elapsedMs / 1000L).toInt()
        val mins = seconds / 60
        val secs = seconds % 60
        val timeStr = String.format("%d:%02d", mins, secs)
        
        val instruction = if (isLockedRecording) "Locked • Tap to send" else "Slide left to cancel"
        statusText.text = "$timeStr  $instruction"
        
        val blinkOn = (elapsedMs / 500) % 2L == 0L
        recordingDot.alpha = if (blinkOn) 1f else 0.2f

        uiHandler.postDelayed(this, 70L)
      }
    }
    vadTicker = ticker
    uiHandler.post(ticker)
  }

  private fun stopVoiceRecording(send: Boolean) {
    if (!isRecording) return
    vadTicker?.let { uiHandler.removeCallbacks(it) }
    vadTicker = null

    val durationMs = max(0L, SystemClock.elapsedRealtime() - recordingStartedAtMs)
    val outputFile = recordingFile
    val recorderRef = recorder
    recorder = null
    recordingFile = null
    recordingStartedAtMs = 0L

    try {
      recorderRef?.stop()
    } catch (_: Throwable) {
      // ignored; malformed/too-short recording
    }
    try {
      recorderRef?.reset()
    } catch (_: Throwable) {
    }
    try {
      recorderRef?.release()
    } catch (_: Throwable) {
    }

    isRecording = false
    isLockedRecording = false
    refreshActionVisual()
    listener?.onRecordingState(false, false)
    listener?.onRecordingVad(0f)

    if (send && outputFile != null && outputFile.exists() && outputFile.length() > 0L) {
      val waveform = buildWaveform(recordingAmplitudes, 40)
      listener?.onVoiceRecorded(
        Uri.fromFile(outputFile).toString(),
        (durationMs.toDouble() / 1000.0).coerceAtLeast(0.1),
        waveform,
      )
    } else {
      outputFile?.delete()
      listener?.onRecordingCanceled()
    }
    recordingAmplitudes.clear()
    refreshActionVisual()
  }

  private fun cancelVoiceRecording() {
    stopVoiceRecording(send = false)
  }

  private fun buildWaveform(samples: List<Int>, bins: Int): List<Float> {
    if (samples.isEmpty() || bins <= 0) return emptyList()
    val out = ArrayList<Float>(bins)
    val chunk = max(1, samples.size / bins)
    var i = 0
    while (i < samples.size && out.size < bins) {
      var maxAmp = 0
      var j = i
      val end = min(samples.size, i + chunk)
      while (j < end) {
        maxAmp = max(maxAmp, samples[j])
        j++
      }
      out.add((maxAmp / 32767f).coerceIn(0f, 1f))
      i += chunk
    }
    while (out.size < bins) out.add(0f)
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

private class WallpaperPatternMaskView(context: Context) : View(context) {
  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
  private val maskPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    isFilterBitmap = true
    xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN)
  }
  private val drawRect = RectF()
  private var gradientColors: IntArray = intArrayOf()
  private var gradientLocations: FloatArray? = null
  private var gradientOpacity: Float = 0f
  private var maskBitmap: Bitmap? = null
  private var gradientShader: LinearGradient? = null

  init {
    setWillNotDraw(false)
    // PorterDuff DST_IN masking is more reliable in software on Android.
    setLayerType(LAYER_TYPE_SOFTWARE, null)
    visibility = GONE
  }

  fun applyPattern(
    colors: IntArray,
    locations: FloatArray?,
    opacity: Float,
    bitmap: Bitmap?,
  ) {
    gradientColors = colors
    gradientLocations = locations
    gradientOpacity = opacity.coerceIn(0f, 1f)
    maskBitmap = bitmap
    gradientShader = null
    visibility =
      if (bitmap != null && gradientColors.size >= 2 && gradientOpacity > 0.001f) VISIBLE else GONE
    invalidate()
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    gradientShader = null
  }

  private fun ensureShader() {
    if (gradientShader != null) return
    if (width <= 0 || height <= 0 || gradientColors.size < 2) return
    gradientShader =
      LinearGradient(
        0f,
        0f,
        width.toFloat(),
        height.toFloat(),
        gradientColors,
        gradientLocations,
        Shader.TileMode.CLAMP,
      )
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val bitmap = maskBitmap ?: return
    if (width <= 0 || height <= 0 || gradientColors.size < 2 || gradientOpacity <= 0.001f) return
    ensureShader()
    val shader = gradientShader ?: return

    drawRect.set(0f, 0f, width.toFloat(), height.toFloat())
    val saveCount = canvas.saveLayer(drawRect, null)
    fillPaint.shader = shader
    fillPaint.alpha = (gradientOpacity * 255f).toInt().coerceIn(0, 255)
    canvas.drawRect(drawRect, fillPaint)
    canvas.drawBitmap(bitmap, null, drawRect, maskPaint)
    canvas.restoreToCount(saveCount)
  }
}

private val diffExecutor = Executors.newSingleThreadExecutor { r ->
  Thread(r, "ChatListDiffThread").apply { isDaemon = true }
}
private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

class ChatListView(
  context: Context,
  appContext: AppContext,
) : ExpoView(context, appContext) {
  private val onViewportChanged by EventDispatcher<Map<String, Any>>()
  private val onNativeEvent by EventDispatcher<Map<String, Any>>()
  internal var nativeEventListener: ((Map<String, Any>) -> Unit)? = null
  internal var viewportChangedListener: ((Map<String, Any>) -> Unit)? = null
  private var isDispatchingViewportEvent = false

  private val contentFrame = FrameLayout(context)
  val recyclerView = RecyclerView(context)
  private val wallpaperView = View(context)
  private val wallpaperPatternView = WallpaperPatternMaskView(context)
  private val overlayHost = FrameLayout(context)
  private val inputBar = ChatNativeInputBar(context, appContext)
  private val layoutManager = LinearLayoutManager(context)
  private val adapter = NativeRowsAdapter(context, appContext) { payload -> emitNativeEvent(payload) }
  private var appearance = ChatListAppearance()
  private var queuedAppearanceAfterSendTransition: ChatListAppearance? = null
  private val baseHorizontalPadding = dp(16)
  private val baseTopPadding = dp(8)
  private val baseBottomPadding = dp(12)
  private var contentPaddingTop = baseTopPadding
  private var contentPaddingBottom = baseBottomPadding
  private var inputBarEnabled = false
  private var inputPlaceholder = "Message"
  private var nativeSendEnabled = false

  private val rows = mutableListOf<NativeRowItem>()
  private var shouldAutoScroll = true
  private var prevScrollOffset = 0
  private var skipNextTransitionScrollCorrection = false
  private var pendingSendTransition: SendTransitionPayload? = null
  private var activeTransition: ActiveTransition? = null

  private val peerTypingContainer = FrameLayout(context)
  private val peerTypingLabel = ShimmerTextView(context)
  private var isPeerTyping = false

  private var surfaceId: String = ""
  private var engineSurfaceId: String = ""
  private var engineChatId: String = ""
  private var engineMyUserId: String = ""
  private var enginePeerUserId: String = ""
  private var engineOpenedChatId: String = ""
  private var statusAuthorityEnabled: Boolean = false
  private val engineListenerId = "chat-list-view-${System.identityHashCode(this)}"
  private var sourceRowsPayload: List<Map<String, Any?>> = emptyList()
  private val nativeEngineRowsById = linkedMapOf<String, Map<String, Any?>>()
  private val nativeEngineOrder = mutableListOf<String>()
  private val nativeDeletedMessageIds = linkedSetOf<String>()

  companion object {
    private const val PREFS_NAME = "vibe_chat_native"
    private const val PREF_THEME_ID = "chat_native_theme_id_v1"
    private const val PREF_THEME_IS_DARK = "chat_native_theme_is_dark_v1"
    private val wallpaperMaskBitmapCache = mutableMapOf<String, Bitmap>()
  }

  private data class ActiveTransition(
    val payload: SendTransitionPayload,
    val overlay: SendTransitionOverlayView,
    var targetRect: RectF,
    var scrollCompensationY: Float = 0f,
    var progress: Float = 0f,
    val animator: ValueAnimator,
  )

  init {
    orientation = VERTICAL
    clipChildren = false
    clipToPadding = false
    setBackgroundColor(Color.TRANSPARENT)
    bootstrapCachedAppearance()?.let { appearance = it }

    layoutManager.orientation = RecyclerView.VERTICAL
    layoutManager.stackFromEnd = true
    recyclerView.layoutManager = layoutManager
    recyclerView.adapter = adapter
    recyclerView.clipChildren = false
    recyclerView.clipToPadding = false
    recyclerView.setBackgroundColor(Color.TRANSPARENT)
    recyclerView.setPadding(baseHorizontalPadding, contentPaddingTop, baseHorizontalPadding, contentPaddingBottom)
    recyclerView.overScrollMode = View.OVER_SCROLL_ALWAYS
    recyclerView.itemAnimator = null
    adapter.setAppearance(appearance)
    adapter.setStatusResolver { item -> resolveDisplayStatus(item) }
    applyAppearanceToView()

    recyclerView.addOnScrollListener(object : RecyclerView.OnScrollListener() {
      override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
        val offset = recyclerView.computeVerticalScrollOffset()
        val delta = (offset - prevScrollOffset).toFloat()
        prevScrollOffset = offset
        if (abs(delta) > 0.1f) {
          val running = activeTransition
          if (running != null) {
            if (skipNextTransitionScrollCorrection) {
              skipNextTransitionScrollCorrection = false
            } else {
              running.scrollCompensationY -= delta
              updateTransitionFrame(running)
            }
          }
        }
        shouldAutoScroll = currentDistanceFromBottom() <= LIST_BOTTOM_THRESHOLD
        emitViewport()
      }
    })

    recyclerView.addOnChildAttachStateChangeListener(object : RecyclerView.OnChildAttachStateChangeListener {
      override fun onChildViewAttachedToWindow(view: View) {
        maybeStartPendingTransition()
      }

      override fun onChildViewDetachedFromWindow(view: View) = Unit
    })

    contentFrame.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f)
    contentFrame.clipChildren = false
    contentFrame.clipToPadding = false
    contentFrame.setBackgroundColor(Color.TRANSPARENT)
    addView(contentFrame)

    contentFrame.addView(
      wallpaperView,
      FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

    contentFrame.addView(
      wallpaperPatternView,
      FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

    contentFrame.addView(
      recyclerView,
      FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

    overlayHost.isClickable = false
    overlayHost.isFocusable = false
    overlayHost.clipChildren = false
    overlayHost.clipToPadding = false
    overlayHost.setBackgroundColor(Color.TRANSPARENT)
    contentFrame.addView(
      overlayHost,
      FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )



    inputBar.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
    inputBar.visibility = View.GONE
    inputBar.setPlaceholder(inputPlaceholder)
    val initBg = appearance.wallpaperGradient.firstOrNull() ?: appearance.bubbleThemColor
    inputBar.applyAppearance(appearance, Color.luminance(initBg) < 0.42f, initBg)
    inputBar.listener = object : ChatNativeInputBar.Listener {
      override fun onTextChanged(text: String) {
        if (nativeSendEnabled) {
          val chatId = engineChatId.trim()
          if (chatId.isNotEmpty()) {
            val isTyping = text.trim().isNotEmpty()
            diffExecutor.execute {
              ChatEngine.sendTypingState(
                mapOf(
                  "chatId" to chatId,
                  "typing" to isTyping,
                ),
              )
            }
          }
        }
        emitNativeEvent(mapOf("type" to "textChanged", "text" to text))
      }

      override fun onAttachmentPressed() {
        emitNativeEvent(mapOf("type" to "attachmentPressed"))
      }

      override fun onSendText(text: String, messageId: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        Log.i(
          "ChatListView",
          "onSendText textLen=${trimmed.length} messageId=$messageId nativeSendEnabled=$nativeSendEnabled chatId=${engineChatId.trim()} surfaceId=$engineSurfaceId",
        )
        if (nativeSendEnabled) {
          val chatId = engineChatId.trim()
          val myUserId = engineMyUserId.trim()
          val peerUserId = enginePeerUserId.trim()
          if (chatId.isEmpty()) {
            Log.w(
              "ChatListView",
              "native ChatEngine send blocked: empty chatId messageId=$messageId myUserId=$myUserId peerUserId=$peerUserId",
            )
            return
          }
          diffExecutor.execute {
            val result = ChatEngine.sendMessage(
              mapOf(
                "chatId" to chatId,
                "messageId" to messageId,
                "type" to "text",
                "text" to trimmed,
                "myUserId" to myUserId,
                "peerUserId" to peerUserId,
              ),
            )
            val accepted = (result["accepted"] as? Boolean) == true
            val queued = (result["queued"] as? Boolean) == true
            val state = (result["state"] as? String)?.trim()?.lowercase()
            val reason = (result["reason"] as? String)?.trim()
            Log.i(
              "ChatListView",
              "native ChatEngine sendMessage result accepted=$accepted queued=$queued state=$state reason=$reason chatId=$chatId messageId=$messageId result=$result",
            )
            if (!accepted) {
              val statusSnapshot = ChatEngine.getStatus()
              val journalTail = ChatEngine.getJournal().takeLast(6)
              Log.w(
                "ChatListView",
                "native ChatEngine sendMessage rejected: result=$result status=$statusSnapshot journalTail=$journalTail",
              )
              return@execute
            }

            if (state == "pending" || state == "error") {
              val statusSnapshot = ChatEngine.getStatus()
              Log.i(
                "ChatListView",
                "native ChatEngine sendMessage state=$state messageId=$messageId chatId=$chatId status=$statusSnapshot",
              )
            }
          }
          return
        }
        Log.w(
          "ChatListView",
          "onSendText falling back to JS bridge nativeSendEnabled=false messageId=$messageId chatId=${engineChatId.trim()}",
        )
        emitNativeEvent(mapOf("type" to "sendMessage", "text" to trimmed, "messageId" to messageId))
      }

      override fun onRecordingState(isRecording: Boolean, isLocked: Boolean) {
        if (nativeSendEnabled) {
          val chatId = engineChatId.trim()
          if (chatId.isNotEmpty()) {
            diffExecutor.execute {
              ChatEngine.sendRecordingState(
                mapOf(
                  "chatId" to chatId,
                  "isRecording" to isRecording,
                  "isLocked" to isLocked,
                  "mode" to "voice",
                ),
              )
            }
          }
        }
        emitNativeEvent(
          mapOf(
            "type" to "recordingState",
            "isRecording" to isRecording,
            "isLocked" to isLocked,
            "mode" to "voice",
          ),
        )
      }

      override fun onRecordingVad(level: Float) {
        emitNativeEvent(
          mapOf(
            "type" to "recordingVad",
            "level" to level.toDouble(),
          ),
        )
      }

      override fun onRecordingCanceled() {
        if (nativeSendEnabled) {
          val chatId = engineChatId.trim()
          if (chatId.isNotEmpty()) {
            diffExecutor.execute {
              ChatEngine.sendRecordingState(
                mapOf(
                  "chatId" to chatId,
                  "isRecording" to false,
                  "isLocked" to false,
                  "mode" to "voice",
                ),
              )
            }
          }
        }
        emitNativeEvent(mapOf("type" to "recordingCanceled"))
      }

      override fun onVoiceRecorded(uri: String, durationSeconds: Double, waveform: List<Float>) {
        if (nativeSendEnabled) {
          val chatId = engineChatId.trim()
          val myUserId = engineMyUserId.trim()
          val peerUserId = enginePeerUserId.trim()
          if (chatId.isEmpty()) {
            Log.w(
              "ChatListView",
              "native voice send blocked: empty chatId uri=$uri duration=$durationSeconds",
            )
            return
          }
          diffExecutor.execute {
            val result = ChatEngine.sendMessage(
              mapOf(
                "chatId" to chatId,
                "type" to "voice",
                "text" to "",
                "myUserId" to myUserId,
                "peerUserId" to peerUserId,
                "metadata" to mapOf(
                  "mediaUrl" to uri,
                  "duration" to durationSeconds,
                  "waveform" to waveform.map { it.toDouble() },
                  "fileName" to "voice-message.m4a",
                ),
              ),
            )
            Log.i(
              "ChatListView",
              "native voice send result chatId=$chatId result=$result uri=$uri duration=$durationSeconds",
            )
          }
          return
        }
        emitNativeEvent(
          mapOf(
            "type" to "attachmentVoice",
            "uri" to uri,
            "duration" to durationSeconds,
            "waveform" to waveform.map { it.toDouble() },
          ),
        )
      }

    }
    addView(inputBar)

    addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
      val oldHeight = oldBottom - oldTop
      val newHeight = bottom - top
      if (oldHeight <= 0 || newHeight <= 0 || oldHeight == newHeight) {
        return@addOnLayoutChangeListener
      }
      applyBottomAnchorPadding()
      val distanceBeforeResize = (
        recyclerView.computeVerticalScrollRange().toDouble() -
          (prevScrollOffset.toDouble() + oldHeight.toDouble())
        ).coerceAtLeast(0.0)
      if (distanceBeforeResize <= LIST_BOTTOM_THRESHOLD || shouldAutoScroll) {
        scrollToBottom(false)
      } else {
        restoreStationaryDistance(distanceBeforeResize)
      }
      emitViewport()
      maybeStartPendingTransition()
    }
  }

  private fun emitNativeEvent(payload: Map<String, Any>) {
    if (nativeSendEnabled) {
      val type = (payload["type"] as? String)?.trim()?.lowercase()
      if (type == "contextmenuaction") {
        val action = (payload["action"] as? String)?.trim()?.lowercase()
        val messageId = (payload["messageId"] as? String)?.trim().orEmpty()
        val chatId = engineChatId.trim()
        if (chatId.isNotEmpty() && messageId.isNotEmpty() && (action == "resend" || action == "delete")) {
          diffExecutor.execute {
            val result =
              if (action == "resend") {
                ChatEngine.retryOutgoingMessage(
                  mapOf(
                    "chatId" to chatId,
                    "messageId" to messageId,
                  ),
                )
              } else {
                ChatEngine.deleteMessage(
                  mapOf(
                    "chatId" to chatId,
                    "messageId" to messageId,
                    "forEveryone" to true,
                  ),
                )
              }
            Log.i(
              "ChatListView",
              "native contextMenuAction handled action=$action chatId=$chatId messageId=$messageId result=$result",
            )
          }
          return
        }
      }
    }
    val forwarded = nativeEventListener
    if (forwarded != null) {
      forwarded.invoke(payload)
      return
    }
    onNativeEvent(payload)
  }

  private fun emitViewportChanged(payload: Map<String, Any>) {
    if (isDispatchingViewportEvent) return
    isDispatchingViewportEvent = true
    try {
      val forwarded = viewportChangedListener
      if (forwarded != null) {
        forwarded.invoke(payload)
      } else {
        onViewportChanged(payload)
      }
    } finally {
      isDispatchingViewportEvent = false
    }
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    updateChatEngineBinding()
    updateChatEngineChannelBinding()
    registerChatEngineListener()
  }

  override fun onDetachedFromWindow() {
    updateChatEngineChannelBinding(forceDetach = true)
    ChatEngine.setListener(engineListenerId, null)
    if (engineSurfaceId.isNotBlank()) {
      ChatEngine.unbindSurface(mapOf("surfaceId" to engineSurfaceId))
    }
    super.onDetachedFromWindow()
  }

  fun setSurfaceId(value: String) {
    surfaceId = value
    ChatListRegistry.register(surfaceId, this)
  }

  fun setEngineSurfaceId(value: String) {
    if (engineSurfaceId == value) return
    if (engineSurfaceId.isNotBlank()) {
      ChatEngine.unbindSurface(mapOf("surfaceId" to engineSurfaceId))
    }
    engineSurfaceId = value.trim()
    Log.i("ChatListView", "setEngineSurfaceId surfaceId=$engineSurfaceId")
    updateChatEngineBinding()
    registerChatEngineListener()
  }

  fun setEngineChatId(value: String) {
    val next = value.trim()
    if (engineChatId == next) return
    engineChatId = next
    Log.i("ChatListView", "setEngineChatId chatId=$engineChatId")
    nativeEngineRowsById.clear()
    nativeEngineOrder.clear()
    nativeDeletedMessageIds.clear()
    updateChatEngineBinding()
    updateChatEngineChannelBinding()
    refreshStatusDecorations("chatId")
  }

  fun setEngineMyUserId(value: String) {
    val next = value.trim()
    if (engineMyUserId == next) return
    engineMyUserId = next
    Log.i("ChatListView", "setEngineMyUserId myUserId=$engineMyUserId")
    updateChatEngineBinding()
  }

  fun setEnginePeerUserId(value: String) {
    val next = value.trim()
    if (enginePeerUserId == next) return
    enginePeerUserId = next
    Log.i("ChatListView", "setEnginePeerUserId peerUserId=$enginePeerUserId")
    updateChatEngineBinding()
    refreshStatusDecorations("peerUserId")
  }

  fun setStatusAuthorityEnabled(enabled: Boolean) {
    if (statusAuthorityEnabled == enabled) return
    statusAuthorityEnabled = enabled
    if (enabled) {
      registerChatEngineListener()
      hydrateRowsFromNativeHistoryIfReady("statusAuthorityEnabled")
    }
    refreshStatusDecorations("statusAuthorityEnabled")
  }

  private var parseGeneration = 0

  fun setRows(input: List<Map<String, Any?>>) {
    sourceRowsPayload = input
    val previousDistanceFromBottom = currentDistanceFromBottom()
    val wasNearBottom = previousDistanceFromBottom <= LIST_BOTTOM_THRESHOLD || shouldAutoScroll

    // Parse rows on background thread to avoid blocking the UI during navigation
    val generation = ++parseGeneration
    diffExecutor.execute {
      val next = parseRows(mergedRowsPayload(input))
      mainHandler.post {
        if (generation != parseGeneration) return@post // stale, skip
        rows.clear()
        rows.addAll(next)
        adapter.setRows(next)
        recyclerView.post {
          applyBottomAnchorPadding()
          if (wasNearBottom) {
            scrollToBottom(false)
          } else {
            restoreStationaryDistance(previousDistanceFromBottom)
          }
          prevScrollOffset = recyclerView.computeVerticalScrollOffset()
          emitViewport()
          maybeStartPendingTransition()
        }
      }
    }
  }

  private fun updateChatEngineBinding() {
    if (engineSurfaceId.isBlank()) return
    ChatEngine.bindSurface(
      mapOf(
        "surfaceId" to engineSurfaceId,
        "chatId" to engineChatId,
        "myUserId" to engineMyUserId,
        "peerUserId" to enginePeerUserId,
      ),
    )
  }

  private fun updateChatEngineChannelBinding(forceDetach: Boolean = false) {
    val desiredChatId = if (!forceDetach && isAttachedToWindow) {
      engineChatId.takeIf { it.isNotBlank() }
    } else {
      null
    }

    if (engineOpenedChatId.isNotBlank() && engineOpenedChatId != desiredChatId) {
      ChatEngine.closeChatChannel(mapOf("chatId" to engineOpenedChatId))
      engineOpenedChatId = ""
    }

    if (!desiredChatId.isNullOrBlank() && engineOpenedChatId != desiredChatId) {
      ChatEngine.openChatChannel(mapOf("chatId" to desiredChatId))
      engineOpenedChatId = desiredChatId
    }
  }

  private fun registerChatEngineListener() {
    if (engineSurfaceId.isBlank() || !isAttachedToWindow) return
    ChatEngine.setListener(engineListenerId) { reason, chatId, messageId ->
      if (!statusAuthorityEnabled) return@setListener
      if (chatId != null && chatId.isNotBlank() && engineChatId.isNotBlank() && chatId != engineChatId) {
        return@setListener
      }
      if (reason == "peerTyping") {
        post { setPeerTyping(messageId == "true") }
        return@setListener
      }
      if (
        reason == "chatMessageInserted" ||
          reason == "chatMessageEdited" ||
          reason == "chatMessageDeleted" ||
          reason == "chatMessageChanged"
      ) {
        post { syncNativeEngineMessageMutation(reason, messageId) }
        return@setListener
      }
      if (reason == "chatRowsReloaded") {
        post { setRows(sourceRowsPayload) }
        return@setListener
      }
      post { refreshStatusDecorations(reason) }
    }
    hydrateRowsFromNativeHistoryIfReady("listenerRegistered")
  }

  private fun hydrateRowsFromNativeHistoryIfReady(trigger: String) {
    if (!statusAuthorityEnabled) return
    val resolvedChatId = engineChatId.trim()
    if (resolvedChatId.isEmpty()) return
    val historyLoaded = ChatEngine.isChatHistoryLoaded(mapOf("chatId" to resolvedChatId))
    if (!historyLoaded) return
    Log.i(
      "ChatListView",
      "hydrateRowsFromNativeHistoryIfReady trigger=$trigger chatId=$resolvedChatId sourceRows=${sourceRowsPayload.size}",
    )
    setRows(sourceRowsPayload)
  }

  private fun refreshStatusDecorations(reason: String) {
    if (!statusAuthorityEnabled) return
    if (rows.isEmpty()) return
    adapter.refreshStatusDecorations()
    android.util.Log.d("ChatListView", "refreshStatusDecorations reason=$reason")
  }

  private fun resolveDisplayStatus(item: NativeRowItem): String? {
    if (!statusAuthorityEnabled) {
      return item.status?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
    }
    return ChatEngine.resolveDisplayStatus(
      chatId = engineChatId.takeIf { it.isNotBlank() },
      messageId = item.messageId,
      rawStatus = item.status,
      isMe = item.isMe,
      peerUserId = enginePeerUserId.takeIf { it.isNotBlank() },
    )
  }

  fun setAppearance(rawAppearance: Map<String, Any?>) {
    cacheNativeThemeSeed(rawAppearance)
    val next = ChatListAppearance.from(rawAppearance)
    if (appearance.visualEquals(next)) return
    val hasPendingOrActiveSendTransition = pendingSendTransition != null || activeTransition != null
    if (hasPendingOrActiveSendTransition) {
      queuedAppearanceAfterSendTransition = next
      return
    }
    queuedAppearanceAfterSendTransition = null
    applyResolvedAppearance(next)
  }

  private fun applyResolvedAppearance(next: ChatListAppearance) {
    appearance = next
    adapter.setAppearance(appearance)
    applyAppearanceToView()
  }

  private fun flushQueuedAppearanceAfterTransitionIfNeeded() {
    if (pendingSendTransition != null || activeTransition != null) return
    val queued = queuedAppearanceAfterSendTransition ?: return
    queuedAppearanceAfterSendTransition = null
    applyResolvedAppearance(queued)
  }

  fun setContentPaddingTop(value: Double) {
    val next = max(baseTopPadding, dp(value))
    if (next == contentPaddingTop) return
    contentPaddingTop = next
    applyBottomAnchorPadding()
    emitViewport()
  }

  fun setContentPaddingBottom(value: Double) {
    val next = max(baseBottomPadding, dp(value))
    if (next == contentPaddingBottom) return
    contentPaddingBottom = next
    applyBottomAnchorPadding()
    emitViewport()
  }

  fun setInputBarEnabled(enabled: Boolean) {
    if (inputBarEnabled == enabled) return
    inputBarEnabled = enabled
    inputBar.visibility = if (enabled) View.VISIBLE else View.GONE
    post {
      applyBottomAnchorPadding()
      if (shouldAutoScroll) {
        scrollToBottom(false)
      } else {
        emitViewport()
      }
    }
  }

  fun setInputPlaceholder(value: String) {
    if (inputPlaceholder == value) return
    inputPlaceholder = value
    inputBar.setPlaceholder(value)
  }

  fun setNativeSendEnabled(enabled: Boolean) {
    nativeSendEnabled = enabled
    Log.i(
      "ChatListView",
      "setNativeSendEnabled enabled=$nativeSendEnabled chatId=${engineChatId.trim()} surfaceId=$engineSurfaceId",
    )
  }

  fun setVoicePlayback(payload: Map<String, Any?>) {
    val messageId = payload["messageId"] as? String
    val isPlaying = (payload["isPlaying"] as? Boolean) ?: false
    val progressRaw =
      when (val value = payload["progress"]) {
        is Number -> value.toFloat()
        is String -> value.toFloatOrNull() ?: 0f
        else -> 0f
      }
    adapter.setVoicePlayback(messageId, isPlaying, progressRaw)
  }

  fun applyTransactions(transactions: List<Map<String, Any?>>) {
    emitNativeEvent(
      mapOf(
        "type" to "transactionsApplied",
        "count" to transactions.size,
      ),
    )
  }

  fun scrollToBottom(animated: Boolean) {
    if (rows.isEmpty()) return
    val target = rows.size - 1
    if (animated) {
      recyclerView.smoothScrollToPosition(target)
    } else {
      recyclerView.scrollToPosition(target)
    }
    recyclerView.post {
      prevScrollOffset = recyclerView.computeVerticalScrollOffset()
      shouldAutoScroll = true
      emitViewport()
      maybeStartPendingTransition()
    }
  }

  fun scrollToMessage(messageId: String, animated: Boolean, viewPosition: Double) {
    if (rows.isEmpty()) return
    val index = adapter.findMessageIndex(messageId)
    if (index < 0) return

    val clamped = viewPosition.coerceIn(0.0, 1.0)
    val estimatedRowHeight = dp(56)
    val offset = ((recyclerView.height - estimatedRowHeight) * clamped).toInt()

    if (animated) {
      recyclerView.smoothScrollToPosition(index)
      recyclerView.post {
        layoutManager.scrollToPositionWithOffset(index, offset)
        emitViewport()
      }
    } else {
      layoutManager.scrollToPositionWithOffset(index, offset)
      recyclerView.post { emitViewport() }
    }
    shouldAutoScroll = false
  }

  fun startSendTransition(payload: Map<String, Any?>) {
    val parsed = parseSendPayload(payload) ?: return
    pendingSendTransition = parsed
    maybeStartPendingTransition()
  }

  fun playReactionFx(payload: Map<String, Any?>) {
    val emoji = (payload["emoji"] as? String)?.trim().orEmpty()
    if (emoji.isEmpty()) return

    val sourceX = parseFloatValue(payload["x"]) ?: parseFloatValue(payload["sourceX"]) ?: return
    val sourceY = parseFloatValue(payload["y"]) ?: parseFloatValue(payload["sourceY"]) ?: return

    val selfLocation = IntArray(2)
    getLocationOnScreen(selfLocation)
    val localX = (sourceX - selfLocation[0]).coerceIn(-40f, width + 40f)
    val localY = (sourceY - selfLocation[1]).coerceIn(-40f, height + 40f)
    val color = resolveReactionFxColor(payload["color"])

    val burst = ReactionBurstOverlayView(context)
    overlayHost.addView(
      burst,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    burst.play(
      emoji = emoji,
      x = localX,
      y = localY,
      color = color,
    ) {
      overlayHost.removeView(burst)
    }
  }

  private fun messageIdFromRawRow(row: Map<String, Any?>): String? {
    val message = row["message"] as? Map<*, *> ?: return null
    val raw = message["id"] ?: message["messageId"] ?: message["message_id"] ?: return null
    return raw.toString().trim().takeIf { it.isNotEmpty() }
  }

  private fun mergeMessageRowPreservingShape(
    baseRow: Map<String, Any?>,
    overlayRow: Map<String, Any?>,
  ): Map<String, Any?> {
    val baseMessage = baseRow["message"] as? Map<*, *> ?: return overlayRow
    val overlayMessage = overlayRow["message"] as? Map<*, *> ?: return overlayRow
    val mergedMessage = linkedMapOf<String, Any?>()
    baseMessage.forEach { (k, v) -> if (k != null) mergedMessage[k.toString()] = v }
    overlayMessage.forEach { (k, v) -> if (k != null) mergedMessage[k.toString()] = v }
    if (baseMessage["bubbleShape"] != null) {
      mergedMessage["bubbleShape"] = baseMessage["bubbleShape"]
    }
    return linkedMapOf<String, Any?>().apply {
      baseRow.forEach { (k, v) -> this[k] = v }
      overlayRow.forEach { (k, v) -> this[k] = v }
      this["message"] = mergedMessage
    }
  }

  private fun mergedRowsPayload(baseRows: List<Map<String, Any?>>): List<Map<String, Any?>> {
    val effectiveBaseRows: List<Map<String, Any?>> = if (statusAuthorityEnabled && engineChatId.isNotBlank()) {
      val historyLoaded = ChatEngine.isChatHistoryLoaded(mapOf("chatId" to engineChatId))
      if (historyLoaded) {
        val nativeRows = ChatEngine.getChatRows(mapOf("chatId" to engineChatId))
        if ((nativeRows.isNotEmpty() && nativeRows.size >= baseRows.size) || baseRows.isEmpty()) {
          nativeRows
        } else {
          baseRows
        }
      } else {
        baseRows
      }
    } else {
      baseRows
    }

    if (nativeEngineRowsById.isEmpty() && nativeDeletedMessageIds.isEmpty()) {
      return effectiveBaseRows
    }

    val filteredBase = ArrayList<Map<String, Any?>>(effectiveBaseRows.size)
    val baseMessageIds = linkedSetOf<String>()
    for (row in effectiveBaseRows) {
      val messageId = messageIdFromRawRow(row)
      if (messageId != null && nativeDeletedMessageIds.contains(messageId)) {
        continue
      }
      if (messageId != null) baseMessageIds.add(messageId)
      filteredBase.add(row)
    }

    // Clear stale deletion markers once JS rows have caught up.
    nativeDeletedMessageIds.removeAll { deletedId -> deletedId !in baseMessageIds && nativeEngineRowsById[deletedId] == null }

    val merged = ArrayList<Map<String, Any?>>(filteredBase.size + nativeEngineRowsById.size)
    for (row in filteredBase) {
      val messageId = messageIdFromRawRow(row)
      if (messageId != null) {
        val overlay = nativeEngineRowsById[messageId]
        if (overlay != null) {
          merged.add(mergeMessageRowPreservingShape(row, overlay))
          continue
        }
      }
      merged.add(row)
    }

    // Pre-clean: remove native outgoing copies whose server-confirmed version
    // is already present in the base rows.
    val nextOrder = ArrayList<String>(nativeEngineOrder.size)
    for (messageId in nativeEngineOrder) {
      if (nativeEngineRowsById[messageId] == null) {
        continue
      }
      if (baseMessageIds.contains(messageId)) {
        nativeEngineRowsById.remove(messageId)
        continue
      }
      nextOrder.add(messageId)
    }
    nativeEngineOrder.clear()
    nativeEngineOrder.addAll(nextOrder)

    for (messageId in nativeEngineOrder) {
      val overlay = nativeEngineRowsById[messageId] ?: continue
      merged.add(overlay)
    }
    return merged
  }

  private fun syncNativeEngineMessageMutation(reason: String, messageId: String?) {
    val resolvedMessageId = messageId?.trim().orEmpty()
    val resolvedChatId = engineChatId.trim()
    if (resolvedChatId.isEmpty() || resolvedMessageId.isEmpty()) return

    when (reason) {
      "chatMessageDeleted" -> {
        nativeEngineRowsById.remove(resolvedMessageId)
        nativeDeletedMessageIds.add(resolvedMessageId)
      }
      "chatMessageInserted", "chatMessageEdited", "chatMessageChanged" -> {
        val row = ChatEngine.getLiveMessageRow(
          mapOf("chatId" to resolvedChatId, "messageId" to resolvedMessageId),
        )
        if (row != null) {
          nativeEngineRowsById[resolvedMessageId] = row
          nativeDeletedMessageIds.remove(resolvedMessageId)
          if (!nativeEngineOrder.contains(resolvedMessageId)) {
            nativeEngineOrder.add(resolvedMessageId)
          }
        }
      }
    }

    setRows(sourceRowsPayload)
  }

  private fun parseRows(input: List<Map<String, Any?>>): List<NativeRowItem> {
    val output = ArrayList<NativeRowItem>(input.size)

    for ((index, raw) in input.withIndex()) {
      val kind = (raw["kind"] as? String) ?: continue
      val fallbackKey = "row-$index"
      val key = ((raw["key"] as? String)?.takeIf { it.isNotBlank() }) ?: fallbackKey

      if (kind == "day") {
        val label = (raw["label"] as? String) ?: ""
        output.add(
          NativeRowItem(
            kind = "day",
            key = key,
            text = label,
            timestamp = "",
            status = null,
            isMe = false,
            messageId = null,
            shape = NativeBubbleShape(showTail = false, topLeft = 18f, topRight = 18f, bottomRight = 18f, bottomLeft = 18f),
            messageType = "text",
            mediaUrl = null,
            duration = null,
            waveform = null,
          ),
        )
        continue
      }

      val message = raw["message"] as? Map<*, *> ?: continue
      val text = (message["text"] as? String) ?: ""
      val timestamp = (message["timestamp"] as? String) ?: ""
      val status = (message["status"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
      val isMe = (message["isMe"] as? Boolean) ?: false
      val messageId = message["id"] as? String
      val messageType = ((message["type"] as? String) ?: "text").lowercase()
      val metadata = message["metadata"] as? Map<*, *>
      val localMediaUrl1 = message["localMediaUrl"] as? String
      val localMediaUrl2 = message["local_media_url"] as? String
      val metaLocalMediaUrl1 = metadata?.get("localMediaUrl") as? String
      val metaLocalMediaUrl2 = metadata?.get("local_media_url") as? String
      val mediaUrl =
        run {
          val isVoiceLike = messageType == "voice" || messageType == "music"
          val orderedCandidates = ArrayList<String?>(12)
          if (isVoiceLike) {
            orderedCandidates.add(localMediaUrl1)
            orderedCandidates.add(localMediaUrl2)
            orderedCandidates.add(metaLocalMediaUrl1)
            orderedCandidates.add(metaLocalMediaUrl2)
          }
          orderedCandidates.add(message["mediaUrl"] as? String)
          orderedCandidates.add(message["media_url"] as? String)
          orderedCandidates.add(message["uri"] as? String)
          orderedCandidates.add(message["audioUrl"] as? String)
          orderedCandidates.add(message["audio_url"] as? String)
          orderedCandidates.add(metadata?.get("mediaUrl") as? String)
          orderedCandidates.add(metadata?.get("media_url") as? String)
          orderedCandidates.add(metadata?.get("uri") as? String)
          orderedCandidates.add(metadata?.get("audioUrl") as? String)
          orderedCandidates.add(metadata?.get("audio_url") as? String)
          orderedCandidates.firstOrNull { candidate ->
            !candidate.isNullOrBlank()
          }
        }
      val duration =
        parseDouble(message["duration"])
          ?: parseDouble(metadata?.get("duration"))
      val waveform =
        parseWaveform(message["waveform"])
          ?: parseWaveform(metadata?.get("waveform"))
      val shapeMap = message["bubbleShape"] as? Map<*, *>
      val shape = NativeBubbleShape(
        showTail = (shapeMap?.get("showTail") as? Boolean) ?: true,
        topLeft = ((shapeMap?.get("borderTopLeftRadius") as? Number)?.toFloat() ?: 18f),
        topRight = ((shapeMap?.get("borderTopRightRadius") as? Number)?.toFloat() ?: 18f),
        bottomRight = ((shapeMap?.get("borderBottomRightRadius") as? Number)?.toFloat() ?: 18f),
        bottomLeft = ((shapeMap?.get("borderBottomLeftRadius") as? Number)?.toFloat() ?: 18f),
      )

      output.add(
        NativeRowItem(
          kind = "message",
          key = key,
          text = text,
          timestamp = timestamp,
          status = status,
          isMe = isMe,
          messageId = messageId,
          shape = shape,
          messageType = messageType,
          mediaUrl = mediaUrl,
          duration = duration,
          waveform = waveform,
        ),
      )

      if (messageType == "voice" || messageType == "music") {
        val isLocalMedia = mediaUrl?.let(::isLikelyLocalMediaUrl) == true
        if (mediaUrl.isNullOrBlank() || !isLocalMedia) {
          Log.d(
            "ChatListView",
            "voice row parse messageId=${messageId ?: "-"} status=${status ?: "-"} mediaUrl=${mediaUrl?.take(120) ?: "-"} localCandidate=$isLocalMedia",
          )
        }
      }
    }

    if (isPeerTyping) {
      output.add(
        NativeRowItem(
          kind = "message",
          key = "peer-typing-indicator",
          text = "Typing...",
          timestamp = "",
          status = null,
          isMe = false,
          messageId = "peer-typing-indicator",
          shape = NativeBubbleShape(false, 18f, 18f, 18f, 4f),
          messageType = "typing",
          mediaUrl = null,
          duration = null,
          waveform = null,
        )
      )
    }

    return output
  }

  private fun isLikelyLocalMediaUrl(raw: String): Boolean {
    return raw.startsWith("file://") || raw.startsWith("content://") || raw.startsWith("/")
  }

  private fun parseSendPayload(payload: Map<String, Any?>): SendTransitionPayload? {
    val messageId = payload["messageId"] as? String ?: return null
    if (messageId.isBlank()) return null
    val text = payload["text"] as? String ?: ""
    val timestamp = payload["timestamp"] as? String ?: ""

    fun number(key: String): Float? {
      val value = payload[key] as? Number ?: return null
      return value.toFloat()
    }

    fun rectFromPayload(
      xKey: String,
      yKey: String,
      widthKey: String,
      heightKey: String,
    ): RectF? {
      val x = number(xKey) ?: return null
      val y = number(yKey) ?: return null
      val width = number(widthKey) ?: return null
      val height = number(heightKey) ?: return null
      return RectF(x, y, x + width, y + height)
    }

    val startRectScreen =
      rectFromPayload("startX", "startY", "startWidth", "startHeight")
        ?: return null
    val startBackgroundRectScreen =
      rectFromPayload(
        "startBackgroundX",
        "startBackgroundY",
        "startBackgroundWidth",
        "startBackgroundHeight",
      )
    val startContentRectScreen =
      rectFromPayload(
        "startContentX",
        "startContentY",
        "startContentWidth",
        "startContentHeight",
      )
    val sourceScrollOffset = number("sourceScrollOffset") ?: 0f

    val selfLocation = IntArray(2)
    getLocationOnScreen(selfLocation)
    fun screenToSelf(rect: RectF): RectF {
      return RectF(
        rect.left - selfLocation[0],
        rect.top - selfLocation[1],
        rect.right - selfLocation[0],
        rect.bottom - selfLocation[1],
      )
    }

    val rect = screenToSelf(startRectScreen)
    val backgroundRect = startBackgroundRectScreen?.let(::screenToSelf)
    val contentRect = startContentRectScreen?.let(::screenToSelf)

    return SendTransitionPayload(
      messageId = messageId,
      text = text,
      timestamp = timestamp,
      startRect = rect,
      startBackgroundRect = backgroundRect,
      startContentRect = contentRect,
      sourceScrollOffset = sourceScrollOffset,
    )
  }

  private fun maybeStartPendingTransition() {
    if (activeTransition != null) return
    val payload = pendingSendTransition ?: return
    val index = adapter.findMessageIndex(payload.messageId)
    if (index < 0) return
    val targetRect = resolveTargetRect(index) ?: return
    val targetRow = adapter.rowAt(index)
    val motionStartRect = payload.motionStartRect()
    val sourceBackgroundRect = payload.startBackgroundRect ?: motionStartRect
    val sourceContentRect = payload.sourceContentRectResolved()

    pendingSendTransition = null
    adapter.setHiddenMessageId(payload.messageId)

    val overlay = SendTransitionOverlayView(context, appearance).apply {
      bind(
        text = payload.text,
        timestamp = payload.timestamp,
        isMe = targetRow?.isMe ?: true,
        shape = targetRow?.shape ?: NativeBubbleShape(
          showTail = true,
          topLeft = 18f,
          topRight = 18f,
          bottomRight = 18f,
          bottomLeft = 18f,
        ),
      )
      setTransitionGeometry(
        motionSourceRect = motionStartRect,
        targetRect = targetRect,
        sourceBackgroundRect = sourceBackgroundRect,
        sourceContentRect = sourceContentRect,
        sourceScrollOffset = payload.sourceScrollOffset,
      )
      updateProgress(0f, 0f, 0f)
      updateFrame(motionStartRect)
    }
    overlayHost.addView(
      overlay,
      FrameLayout.LayoutParams(
        motionStartRect.width().roundToInt().coerceAtLeast(1),
        motionStartRect.height().roundToInt().coerceAtLeast(1),
      ).apply {
        leftMargin = motionStartRect.left.roundToInt()
        topMargin = motionStartRect.top.roundToInt()
      },
    )

    val animator = ValueAnimator.ofFloat(0f, 1f).apply {
      duration = SEND_DURATION_MS
      addUpdateListener { valueAnimator ->
        val running = activeTransition ?: return@addUpdateListener
        running.progress = valueAnimator.animatedValue as Float
        updateTransitionFrame(running)
      }
      addListener(object : AnimatorListenerAdapter() {
        override fun onAnimationEnd(animation: Animator) {
          completeActiveTransition()
        }
      })
    }

    activeTransition = ActiveTransition(
      payload = payload,
      overlay = overlay,
      targetRect = targetRect,
      animator = animator,
    )

    emitNativeEvent(
      mapOf(
        "type" to "sendTransitionStarted",
        "messageId" to payload.messageId,
      ),
    )
    animator.start()
  }

  private fun resolveTargetRect(adapterPosition: Int): RectF? {
    return adapter.bubbleRectInParent(adapterPosition, this)
  }

  private fun updateTransitionFrame(transition: ActiveTransition) {
    val index = adapter.findMessageIndex(transition.payload.messageId)
    if (index >= 0) {
      resolveTargetRect(index)?.let { transition.targetRect = it }
    }
    val px = horizontalInterpolator.getInterpolation(transition.progress)
    val py = verticalInterpolator.getInterpolation(transition.progress)

    val start = transition.payload.motionStartRect()
    val target = transition.targetRect
    val x = lerp(start.left, target.left, px)
    val y = lerp(start.top, target.top, py) + transition.scrollCompensationY
    val w = lerp(start.width(), target.width(), px).coerceAtLeast(1f)
    val h = lerp(start.height(), target.height(), py).coerceAtLeast(1f)

    val currentRect = RectF(x, y, x + w, y + h)
    transition.overlay.updateFrame(currentRect)
    transition.overlay.setTransitionGeometry(
      motionSourceRect = start,
      targetRect = target,
      sourceBackgroundRect = transition.payload.startBackgroundRect ?: start,
      sourceContentRect = transition.payload.sourceContentRectResolved(),
      sourceScrollOffset = transition.payload.sourceScrollOffset,
    )
    transition.overlay.updateProgress(transition.progress, px, py)
  }

  private fun completeActiveTransition() {
    val running = activeTransition ?: return
    running.animator.removeAllListeners()
    running.animator.cancel()
    
    val overlay = running.overlay
    overlay.animate()
      .alpha(0f)
      .setDuration(150L)
      .setInterpolator(android.view.animation.DecelerateInterpolator())
      .withEndAction {
        overlayHost.removeView(overlay)
      }
      .start()

    activeTransition = null
    adapter.setHiddenMessageId(null)
    flushQueuedAppearanceAfterTransitionIfNeeded()

    emitNativeEvent(
      mapOf(
        "type" to "sendTransitionCompleted",
        "messageId" to running.payload.messageId,
      ),
    )
  }

  private fun restoreStationaryDistance(distanceFromBottom: Double) {
    val contentHeight = recyclerView.computeVerticalScrollRange().toDouble()
    val layoutHeight = recyclerView.height.toDouble().coerceAtLeast(0.0)
    val targetOffset = (contentHeight - layoutHeight - distanceFromBottom).coerceAtLeast(0.0)
    val currentOffset = recyclerView.computeVerticalScrollOffset().toDouble().coerceAtLeast(0.0)
    val delta = (targetOffset - currentOffset).toFloat()
    if (abs(delta) <= 0.1f) {
      return
    }
    val running = activeTransition
    if (running != null) {
      running.scrollCompensationY -= delta
      skipNextTransitionScrollCorrection = true
      updateTransitionFrame(running)
    }
    recyclerView.scrollBy(0, delta.roundToInt())
    shouldAutoScroll = false
  }

  private fun currentDistanceFromBottom(): Double {
    val contentHeight = recyclerView.computeVerticalScrollRange().toDouble()
    val layoutHeight = recyclerView.height.toDouble().coerceAtLeast(0.0)
    val offsetY = recyclerView.computeVerticalScrollOffset().toDouble().coerceAtLeast(0.0)
    return (contentHeight - (offsetY + layoutHeight)).coerceAtLeast(0.0)
  }

  private fun emitViewport() {
    val contentHeight = recyclerView.computeVerticalScrollRange().toDouble()
    val layoutHeight = recyclerView.height.toDouble().coerceAtLeast(0.0)
    val offsetY = recyclerView.computeVerticalScrollOffset().toDouble().coerceAtLeast(0.0)
    val distanceFromBottom = (contentHeight - (offsetY + layoutHeight)).coerceAtLeast(0.0)

    emitViewportChanged(
      mapOf(
        "contentHeight" to contentHeight,
        "layoutHeight" to layoutHeight,
        "offsetY" to offsetY,
        "distanceFromBottom" to distanceFromBottom,
        "atBottom" to (distanceFromBottom <= LIST_BOTTOM_THRESHOLD),
      ),
    )
    positionPeerTypingIndicator()
  }

  private fun positionPeerTypingIndicator() {
    // Typing overlay may be disabled in some builds; keep this a safe no-op.
  }

  private fun applyBottomAnchorPadding() {
    val targetBottom = contentPaddingBottom
    val targetTop = computeBottomAnchoredTopPadding(targetBottom)
    if (
      recyclerView.paddingTop == targetTop &&
      recyclerView.paddingBottom == targetBottom &&
      recyclerView.paddingLeft == baseHorizontalPadding &&
      recyclerView.paddingRight == baseHorizontalPadding
    ) {
      return
    }
    recyclerView.setPadding(baseHorizontalPadding, targetTop, baseHorizontalPadding, targetBottom)
  }

  private fun applyAppearanceToView() {
    wallpaperView.background = GradientDrawable(
      GradientDrawable.Orientation.TL_BR,
      appearance.wallpaperGradient,
    )
    wallpaperView.alpha = appearance.wallpaperOpacity
    wallpaperView.visibility = if (appearance.backgroundMode == "gradient") View.VISIBLE else View.GONE
    val patternBitmap =
      if (appearance.backgroundMode == "gradient") {
        resolveWallpaperMaskBitmap(appearance.wallpaperMaskKey)
      } else {
        null
      }
    wallpaperPatternView.applyPattern(
      colors = appearance.wallpaperPatternGradient,
      locations = appearance.wallpaperPatternLocations,
      opacity = appearance.wallpaperPatternOpacity,
      bitmap = patternBitmap,
    )
    val bgColor = appearance.wallpaperGradient.firstOrNull() ?: appearance.bubbleThemColor
    val isDarkTheme = Color.luminance(bgColor) < 0.42f
    inputBar.applyAppearance(appearance, isDarkTheme, bgColor)
  }

  private fun cacheNativeThemeSeed(rawAppearance: Map<String, Any?>) {
    val themeId = (rawAppearance["nativeThemeId"] as? String)?.trim()?.takeIf { it.isNotEmpty() } ?: return
    val isDark =
      when (val value = rawAppearance["nativeThemeIsDark"]) {
        is Boolean -> value
        is Number -> value.toInt() != 0
        is String -> value.trim().lowercase() in setOf("1", "true", "yes")
        else -> true
      }
    prefs().edit()
      .putString(PREF_THEME_ID, themeId)
      .putBoolean(PREF_THEME_IS_DARK, isDark)
      .apply()
  }

  private fun bootstrapCachedAppearance(): ChatListAppearance? {
    val prefs = prefs()
    val themeId = prefs.getString(PREF_THEME_ID, null)?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    return ChatListAppearance.from(
      mapOf(
        "backgroundMode" to "gradient",
        "nativeThemeId" to themeId,
        "nativeThemeIsDark" to prefs.getBoolean(PREF_THEME_IS_DARK, true),
      ),
    )
  }

  private fun prefs(): SharedPreferences =
    context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

  private fun resolveWallpaperMaskBitmap(maskKeyRaw: String?): Bitmap? {
    val maskKey = maskKeyRaw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
    wallpaperMaskBitmapCache[maskKey]?.let { return it }
    val baseName = wallpaperMaskBaseName(maskKey) ?: return null

    val drawableId = resources.getIdentifier(baseName, "drawable", context.packageName)
      .takeIf { it != 0 }
      ?: resources.getIdentifier(baseName, "mipmap", context.packageName).takeIf { it != 0 }
      ?: return null

    return runCatching {
      BitmapFactory.decodeResource(resources, drawableId)
    }.getOrNull()?.also { bitmap ->
      wallpaperMaskBitmapCache[maskKey] = bitmap
    }
  }

  private fun wallpaperMaskBaseName(key: String): String? {
    return when (key) {
      "doodles", "hearts" -> "doodle_transparent"
      "music" -> "music_transparent"
      "music2" -> "music2_transparent"
      "food" -> "food_transparent"
      "animals" -> "animals_transparent"
      else -> null
    }
  }

  private fun computeBottomAnchoredTopPadding(targetBottom: Int): Int {
    val itemCount = adapter.itemCount
    if (itemCount <= 0 || recyclerView.height <= 0) {
      return contentPaddingTop
    }
    val firstPos = layoutManager.findFirstVisibleItemPosition()
    val lastPos = layoutManager.findLastVisibleItemPosition()
    if (firstPos != 0 || lastPos != itemCount - 1) {
      return contentPaddingTop
    }
    val firstView = layoutManager.findViewByPosition(firstPos) ?: return contentPaddingTop
    val lastView = layoutManager.findViewByPosition(lastPos) ?: return contentPaddingTop
    val contentHeight = max(0, lastView.bottom - firstView.top)
    val available = recyclerView.height - targetBottom
    return max(contentPaddingTop, available - contentHeight)
  }

  private fun dp(value: Int): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()

  private fun dp(value: Double): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()

  private fun parseDouble(raw: Any?): Double? {
    return when (raw) {
      is Number -> raw.toDouble()
      is String -> raw.toDoubleOrNull()
      else -> null
    }
  }

  private fun parseFloatValue(raw: Any?): Float? {
    return when (raw) {
      is Number -> raw.toFloat()
      is String -> raw.toFloatOrNull()
      else -> null
    }
  }

  private fun resolveReactionFxColor(raw: Any?): Int {
    val fallback = appearance.bubbleMeGradient.lastOrNull() ?: Color.WHITE
    val value = raw as? String ?: return fallback
    return try {
      Color.parseColor(value)
    } catch (_: IllegalArgumentException) {
      fallback
    }
  }

  private fun parseWaveform(raw: Any?): List<Float>? {
    val list = raw as? List<*> ?: return null
    if (list.isEmpty()) return null
    val out =
      list.mapNotNull { item ->
        when (item) {
          is Number -> item.toFloat()
          is String -> item.toFloatOrNull()
          else -> null
        }
      }
        .filter { it.isFinite() }
        .map { it.coerceIn(0f, 1f) }
    return out.ifEmpty { null }
  }

  private fun setPeerTyping(typing: Boolean) {
    if (isPeerTyping == typing) return
    isPeerTyping = typing
    
    val previousDistanceFromBottom = currentDistanceFromBottom()
    val wasNearBottom = previousDistanceFromBottom <= LIST_BOTTOM_THRESHOLD || shouldAutoScroll
    
    val generation = ++parseGeneration
    diffExecutor.execute {
      val next = parseRows(mergedRowsPayload(sourceRowsPayload))
      mainHandler.post {
        if (generation != parseGeneration) return@post
        rows.clear()
        rows.addAll(next)
        adapter.setRows(next)
        recyclerView.post {
          applyBottomAnchorPadding()
          if (wasNearBottom) {
            scrollToBottom(false)
          } else {
            restoreStationaryDistance(previousDistanceFromBottom)
          }
        }
      }
    }
  }

  private fun lerp(a: Float, b: Float, t: Float): Float = a + ((b - a) * t)
}

private class ShimmerTextView(context: Context) : androidx.appcompat.widget.AppCompatTextView(context) {
  private var shimmerAnimator: ValueAnimator? = null
  private var shimmerFraction = -0.5f
  private val shimmerPaint = Paint(Paint.ANTI_ALIAS_FLAG)
  private var shimmerGradient: LinearGradient? = null
  private val gradientMatrix = Matrix()

  init {
    setTextColor(Color.parseColor("#99FFFFFF")) // Darker base color
    textSize = 13f
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    if (w > 0 && h > 0) {
      val baseColor = currentTextColor
      val highlightColor = Color.WHITE
      shimmerGradient = LinearGradient(
        0f, 0f, w.toFloat() * 0.5f, 0f, // Gradient is half the width
        intArrayOf(baseColor, highlightColor, baseColor),
        floatArrayOf(0f, 0.5f, 1f),
        Shader.TileMode.CLAMP
      )
      paint.shader = shimmerGradient
    }
  }

  override fun onDraw(canvas: Canvas) {
    if (shimmerAnimator?.isRunning == true && shimmerGradient != null) {
      // Move gradient from left (-width) to right (2*width) to ensure full sweep
      gradientMatrix.setTranslate(shimmerFraction * width * 2f - width / 2f, 0f)
      shimmerGradient?.setLocalMatrix(gradientMatrix)
    } else {
      paint.shader = null
    }
    super.onDraw(canvas)
  }

  fun startShimmer() {
    if (shimmerAnimator?.isRunning == true) return
    
    // Animate from 0.0 to 1.0 to move fraction
    shimmerAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
      duration = 1500L
      repeatCount = ValueAnimator.INFINITE
      interpolator = android.view.animation.LinearInterpolator()
      addUpdateListener { anim ->
        shimmerFraction = anim.animatedValue as Float
        invalidate()
      }
      start()
    }
  }

  fun stopShimmer() {
    shimmerAnimator?.cancel()
    shimmerAnimator = null
    paint.shader = null
    invalidate()
  }
}


private class ReactionBurstOverlayView(context: Context) : FrameLayout(context) {
  init {
    clipChildren = false
    clipToPadding = false
    isClickable = false
    isFocusable = false
  }

  fun play(
    emoji: String,
    x: Float,
    y: Float,
    color: Int,
    onDone: () -> Unit,
  ) {
    val emojiView =
      TextView(context).apply {
        text = emoji
        textSize = 30f
        alpha = 0f
        scaleX = 0.74f
        scaleY = 0.74f
      }
    addView(emojiView, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
    emojiView.measure(MeasureSpec.UNSPECIFIED, MeasureSpec.UNSPECIFIED)
    emojiView.x = x - (emojiView.measuredWidth * 0.5f)
    emojiView.y = y - (emojiView.measuredHeight * 0.5f)

    emojiView.animate()
      .alpha(1f)
      .scaleX(1.18f)
      .scaleY(1.18f)
      .setDuration(120L)
      .withEndAction {
        emojiView.animate()
          .translationYBy(-dpF(32f))
          .alpha(0f)
          .scaleX(0.9f)
          .scaleY(0.9f)
          .setDuration(340L)
          .start()
      }
      .start()

    val dotSize = dpF(10f)
    val pulseDot =
      View(context).apply {
        alpha = 0.85f
        background =
          GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(withAlpha(color, 0.92f))
          }
      }
    addView(
      pulseDot,
      LayoutParams(dotSize.roundToInt().coerceAtLeast(2), dotSize.roundToInt().coerceAtLeast(2)),
    )
    pulseDot.x = x - (dotSize * 0.5f)
    pulseDot.y = y - (dotSize * 0.5f)

    val ringSize = dpF(16f)
    val pulseRing =
      View(context).apply {
        alpha = 0.85f
        background =
          GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.TRANSPARENT)
            setStroke(dp(2), withAlpha(color, 0.9f))
          }
      }
    addView(
      pulseRing,
      LayoutParams(ringSize.roundToInt().coerceAtLeast(2), ringSize.roundToInt().coerceAtLeast(2)),
    )
    pulseRing.x = x - (ringSize * 0.5f)
    pulseRing.y = y - (ringSize * 0.5f)

    pulseDot.animate()
      .alpha(0f)
      .scaleX(1.9f)
      .scaleY(1.9f)
      .setDuration(460L)
      .setInterpolator(verticalInterpolator)
      .withEndAction { removeView(pulseDot) }
      .start()

    pulseRing.animate()
      .alpha(0f)
      .scaleX(2.6f)
      .scaleY(2.6f)
      .setDuration(460L)
      .setStartDelay(20L)
      .setInterpolator(verticalInterpolator)
      .withEndAction { removeView(pulseRing) }
      .start()

    postDelayed({
      onDone()
    }, 620L)
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).roundToInt()
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun dp(value: Int): Int = dpF(value.toFloat()).roundToInt()

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )

}

private class SendTransitionOverlayView(
  context: Context,
  private val appearance: ChatListAppearance,
) : FrameLayout(context) {
  private val clippingView = FrameLayout(context)
  private val bubbleBackground = View(context)
  private val bubbleTail = BubbleTailView(context)
  private val sourceText = TextView(context)
  private val targetText = TextView(context)
  private val targetTime = TextView(context)

  private var isMe = true
  private var shape = NativeBubbleShape(
    showTail = true,
    topLeft = 18f,
    topRight = 18f,
    bottomRight = 18f,
    bottomLeft = 18f,
  )
  private var sourceBackgroundFrame = RectF()
  private var targetBackgroundFrame = RectF()
  private var sourceContentFrame = RectF()
  private var targetContentFrame = RectF()
  private var sourceScrollOffset = 0f

  init {
    clipChildren = false
    clipToPadding = false

    clippingView.clipChildren = true
    clippingView.clipToPadding = true
    addView(clippingView)
    clippingView.addView(bubbleBackground)
    clippingView.addView(bubbleTail)

    sourceText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    sourceText.setTextColor(appearance.textColorMe)
    sourceText.setLineSpacing(0f, 1.1f)
    sourceText.maxLines = 4

    targetText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    targetText.setTextColor(appearance.textColorMe)
    targetText.setLineSpacing(0f, 1.1f)
    targetText.maxLines = 6

    targetTime.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    targetTime.setTextColor(appearance.timeColorMe)
    targetTime.gravity = Gravity.END

    addView(sourceText)
    addView(targetText)
    addView(targetTime)
  }

  fun bind(text: String, timestamp: String, isMe: Boolean, shape: NativeBubbleShape) {
    this.isMe = isMe
    this.shape = shape
    sourceText.text = text
    targetText.text = text
    targetTime.text = timestamp

    sourceText.setTextColor(if (isMe) appearance.textColorMe else appearance.textColorThem)
    targetText.setTextColor(if (isMe) appearance.textColorMe else appearance.textColorThem)
    targetTime.setTextColor(if (isMe) appearance.timeColorMe else appearance.timeColorThem)

    val drawable =
      if (isMe) {
        GradientDrawable(
          GradientDrawable.Orientation.TL_BR,
          appearance.bubbleMeGradient,
        )
      } else {
        GradientDrawable().apply {
          setColor(appearance.bubbleThemColor)
        }
      }
    drawable.cornerRadii = floatArrayOf(
      dpF(shape.topLeft), dpF(shape.topLeft),
      dpF(shape.topRight), dpF(shape.topRight),
      dpF(shape.bottomRight), dpF(shape.bottomRight),
      dpF(shape.bottomLeft), dpF(shape.bottomLeft),
    )
    bubbleBackground.background = drawable
    bubbleTail.configure(
      isMe = isMe,
      color = if (isMe) appearance.bubbleMeGradient.lastOrNull() ?: Color.WHITE else appearance.bubbleThemColor,
      visible = shape.showTail,
    )
  }

  fun setTransitionGeometry(
    motionSourceRect: RectF,
    targetRect: RectF,
    sourceBackgroundRect: RectF,
    sourceContentRect: RectF,
    sourceScrollOffset: Float,
  ) {
    this.sourceScrollOffset = sourceScrollOffset

    val startContainerOriginY = motionSourceRect.bottom - targetRect.height()
    fun mapRect(rect: RectF): RectF {
      return RectF(
        rect.left - motionSourceRect.left,
        rect.top - startContainerOriginY,
        rect.right - motionSourceRect.left,
        rect.bottom - startContainerOriginY,
      )
    }

    sourceBackgroundFrame = mapRect(sourceBackgroundRect)
    sourceContentFrame = mapRect(sourceContentRect)
    targetBackgroundFrame = RectF(0f, 0f, targetRect.width(), targetRect.height())

    val contentHorizontalPadding = dpF(10f)
    val contentTopPadding = dpF(7f)
    val contentBottomPadding = dpF(7f)
    val contentHeight = sourceContentFrame.height().coerceAtLeast(dpF(18f))
      .coerceAtMost((targetBackgroundFrame.height() - contentTopPadding - contentBottomPadding).coerceAtLeast(dpF(18f)))
    val contentWidth = (targetBackgroundFrame.width() - (contentHorizontalPadding * 2f)).coerceAtLeast(dpF(24f))
    targetContentFrame = RectF(
      contentHorizontalPadding,
      contentTopPadding,
      contentHorizontalPadding + contentWidth,
      contentTopPadding + contentHeight,
    )
  }

  fun updateProgress(progress: Float, horizontalProgress: Float, verticalProgress: Float) {
    val normalizedProgress = progress.coerceIn(0f, 1f)
    val px = horizontalProgress.coerceIn(0f, 1f)
    val py = verticalProgress.coerceIn(0f, 1f)
    val bgOpacity = (py / 0.27f).coerceIn(0f, 1f)
    val sourceOpacity = (1f - (normalizedProgress / 0.34f)).coerceIn(0f, 1f)
    val targetOpacity = (normalizedProgress / 0.27f).coerceIn(0f, 1f)

    val envelopeFrame = RectF(
      lerp(sourceBackgroundFrame.left, targetBackgroundFrame.left, px),
      lerp(sourceBackgroundFrame.top, targetBackgroundFrame.top, py),
      lerp(sourceBackgroundFrame.right, targetBackgroundFrame.right, px),
      lerp(sourceBackgroundFrame.bottom, targetBackgroundFrame.bottom, py),
    )
    updateViewFrame(clippingView, envelopeFrame)

    val backgroundFrameInEnvelope = RectF(
      targetBackgroundFrame.left - envelopeFrame.left,
      targetBackgroundFrame.top - envelopeFrame.top,
      targetBackgroundFrame.right - envelopeFrame.left,
      targetBackgroundFrame.bottom - envelopeFrame.top,
    )
    updateViewFrame(bubbleBackground, backgroundFrameInEnvelope)
    bubbleBackground.alpha = bgOpacity

    if (shape.showTail) {
      val tailSize = dpF(29f)
      val tailLeftInOverlay =
        if (isMe) {
          targetBackgroundFrame.right - dpF(1f)
        } else {
          targetBackgroundFrame.left - dpF(28f)
        }
      val tailTopInOverlay = targetBackgroundFrame.bottom - tailSize
      val tailFrameInEnvelope = RectF(
        tailLeftInOverlay - envelopeFrame.left,
        tailTopInOverlay - envelopeFrame.top,
        tailLeftInOverlay - envelopeFrame.left + tailSize,
        tailTopInOverlay - envelopeFrame.top + tailSize,
      )
      updateViewFrame(bubbleTail, tailFrameInEnvelope)
      bubbleTail.visibility = View.VISIBLE
    } else {
      bubbleTail.visibility = View.GONE
    }

    updateViewFrame(sourceText, sourceContentFrame)
    sourceText.alpha = sourceOpacity

    val widthDifference = targetBackgroundFrame.width() - sourceBackgroundFrame.width()
    val sourceContentStartX = sourceContentFrame.left - (widthDifference * 0.22f)
    val sourceContentStartY = sourceContentFrame.top - sourceScrollOffset
    val currentLeft = lerp(sourceContentStartX, targetContentFrame.left, px)
    val currentTop = lerp(sourceContentStartY, targetContentFrame.top, py)
    val currentWidth = lerp(sourceContentFrame.width(), targetContentFrame.width(), px)
    val currentHeight = lerp(sourceContentFrame.height(), targetContentFrame.height(), py)
    val destinationContentFrame = RectF(
      currentLeft,
      currentTop,
      currentLeft + currentWidth,
      currentTop + currentHeight,
    )

    updateViewFrame(targetText, destinationContentFrame)
    val timeWidth = dpF(46f)
    val timeHeight = dpF(14f)
    val timeFrame = RectF(
      destinationContentFrame.right - timeWidth,
      destinationContentFrame.bottom - timeHeight,
      destinationContentFrame.right,
      destinationContentFrame.bottom,
    )
    updateViewFrame(targetTime, timeFrame)
    targetText.alpha = targetOpacity
    targetTime.alpha = targetOpacity
  }

  private fun updateViewFrame(view: View, rect: RectF) {
    val lp = (view.layoutParams as? FrameLayout.LayoutParams) ?: FrameLayout.LayoutParams(1, 1)
    lp.leftMargin = rect.left.roundToInt()
    lp.topMargin = rect.top.roundToInt()
    lp.width = max(1, rect.width().roundToInt())
    lp.height = max(1, rect.height().roundToInt())
    view.layoutParams = lp
  }

  fun updateFrame(rect: RectF) {
    val lp = layoutParams as? FrameLayout.LayoutParams ?: return
    lp.leftMargin = rect.left.roundToInt()
    lp.topMargin = rect.top.roundToInt()
    lp.width = max(1, rect.width().roundToInt())
    lp.height = max(1, rect.height().roundToInt())
    layoutParams = lp
  }

  private fun dp(value: Int): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()

  private fun dpF(value: Int): Float = dp(value).toFloat()

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).roundToInt()
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun lerp(a: Float, b: Float, t: Float): Float = a + ((b - a) * t)
}
