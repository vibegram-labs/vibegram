package expo.modules.vibechatnative

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.PathInterpolator
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.media.MediaPlayer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.widget.FrameLayout
import android.widget.TextView
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
    canvas.drawPath(path, paint)
    canvas.restore()
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
}

private class NativeRowsAdapter(
  private val context: Context,
) : RecyclerView.Adapter<NativeRowViewHolder>() {
  private val rows = mutableListOf<NativeRowItem>()
  private var hiddenMessageId: String? = null
  private var appearance = ChatListAppearance()
  private val voicePlayback = VoicePlaybackCoordinator()
  private var externalVoiceMessageId: String? = null
  private var externalVoiceIsPlaying = false
  private var externalVoiceProgress = 0f

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
      val messageId = item.messageId?.takeIf { it.isNotBlank() } ?: return
      val mediaUrl = item.mediaUrl?.takeIf { it.isNotBlank() } ?: return

      if (activeMessageId == messageId) {
        val player = mediaPlayer ?: return
        if (!isPrepared) {
          return
        }
        if (player.isPlaying) {
          player.pause()
          isPlaying = false
          applyState(holder, false, progress, level)
        } else {
          player.start()
          isPlaying = true
        }
        return
      }

      stop(resetProgress = true)

      val player = MediaPlayer()
      try {
        if (mediaUrl.startsWith("content://")) {
          val uri = Uri.parse(mediaUrl)
          player.setDataSource(context, uri)
        } else {
          player.setDataSource(mediaUrl)
        }
      } catch (_: Throwable) {
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
        it.start()
        isPlaying = true
        startTicker()
      }
      player.setOnCompletionListener {
        stop(resetProgress = true)
      }
      player.setOnErrorListener { _, _, _ ->
        stop(resetProgress = true)
        true
      }
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
  }

  fun setRows(next: List<NativeRowItem>) {
    val previous = rows.toList()
    rows.clear()
    rows.addAll(next)
    if (previous.isEmpty()) {
      notifyDataSetChanged()
      return
    }
    val diffResult = DiffUtil.calculateDiff(object : DiffUtil.Callback() {
      override fun getOldListSize(): Int = previous.size

      override fun getNewListSize(): Int = rows.size

      override fun areItemsTheSame(oldItemPosition: Int, newItemPosition: Int): Boolean {
        return previous[oldItemPosition].key == rows[newItemPosition].key
      }

      override fun areContentsTheSame(oldItemPosition: Int, newItemPosition: Int): Boolean {
        return previous[oldItemPosition] == rows[newItemPosition]
      }
    })
    diffResult.dispatchUpdatesTo(this)
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

  override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): NativeRowViewHolder {
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
      setPadding(dp(10), dp(7), dp(10), dp(17))
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
      maxWidth = (context.resources.displayMetrics.widthPixels * 0.85f).toInt()
    }

    val voiceContainer = FrameLayout(context).apply {
      visibility = View.GONE
      alpha = 1f
    }

    val voiceButton = TextView(context).apply {
      text = "▶"
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
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
      setTextColor(Color.argb(184, 255, 255, 255))
      gravity = Gravity.END
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

    return NativeRowViewHolder(root, bubble, tail, text, voiceContainer, voiceButton, voiceWave, voiceDuration, time, day)
  }

  override fun onBindViewHolder(holder: NativeRowViewHolder, position: Int) {
    val item = rows[position]
    holder.bind(item, hiddenMessageId == item.messageId)
  }

  override fun getItemCount(): Int = rows.size

  override fun onViewRecycled(holder: NativeRowViewHolder) {
    super.onViewRecycled(holder)
    voicePlayback.detach(holder)
    holder.voiceWaveView.updatePlayback(0f, 0f, false)
    holder.voiceWaveView.setWaveform(null)
    holder.voiceButton.text = "▶"
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
      voiceWaveView.setWaveform(null)
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

    val drawable = if (item.isMe) {
      GradientDrawable(
        GradientDrawable.Orientation.TL_BR,
        appearance.bubbleMeGradient,
      )
    } else {
      GradientDrawable().apply { setColor(appearance.bubbleThemColor) }
    }
    drawable.cornerRadii = floatArrayOf(
      dpF(item.shape.topLeft), dpF(item.shape.topLeft),
      dpF(item.shape.topRight), dpF(item.shape.topRight),
      dpF(item.shape.bottomRight), dpF(item.shape.bottomRight),
      dpF(item.shape.bottomLeft), dpF(item.shape.bottomLeft),
    )
    bubbleContainer.background = drawable

    if (isVoice) {
      textView.visibility = View.GONE
      voiceContainer.visibility = View.VISIBLE
      bubbleContainer.minimumWidth = dp(220)
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
      textView.visibility = View.VISIBLE
      voiceContainer.visibility = View.GONE
      bubbleContainer.minimumWidth = dp(26)
      voiceButton.setOnClickListener(null)
      voicePlayback.detach(this)
      voiceWaveView.updatePlayback(0f, 0f, false)
      voiceWaveView.setWaveform(null)
    }

    if (!hidden && item.shape.showTail) {
      tailView.configure(
        isMe = item.isMe,
        visible = true,
        color = if (item.isMe) appearance.bubbleMeGradient.lastOrNull() ?: Color.WHITE else appearance.bubbleThemColor,
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
}

class ChatListView(
  context: Context,
  appContext: AppContext,
) : ExpoView(context, appContext) {
  private val onViewportChanged by EventDispatcher<Map<String, Any>>()
  private val onNativeEvent by EventDispatcher<Map<String, Any>>()

  val recyclerView = RecyclerView(context)
  private val wallpaperView = View(context)
  private val overlayHost = FrameLayout(context)
  private val layoutManager = LinearLayoutManager(context)
  private val adapter = NativeRowsAdapter(context)
  private var appearance = ChatListAppearance()
  private val baseHorizontalPadding = dp(16)
  private val baseTopPadding = dp(8)
  private val baseBottomPadding = dp(12)
  private var contentPaddingBottom = baseBottomPadding

  private val rows = mutableListOf<NativeRowItem>()
  private var shouldAutoScroll = true
  private var prevScrollOffset = 0
  private var skipNextTransitionScrollCorrection = false
  private var pendingSendTransition: SendTransitionPayload? = null
  private var activeTransition: ActiveTransition? = null

  private var surfaceId: String = ""

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

    layoutManager.orientation = RecyclerView.VERTICAL
    recyclerView.layoutManager = layoutManager
    recyclerView.adapter = adapter
    recyclerView.clipChildren = false
    recyclerView.clipToPadding = false
    recyclerView.setPadding(baseHorizontalPadding, baseTopPadding, baseHorizontalPadding, contentPaddingBottom)
    recyclerView.overScrollMode = View.OVER_SCROLL_ALWAYS
    recyclerView.itemAnimator = null
    adapter.setAppearance(appearance)
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

    addView(
      wallpaperView,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

    addView(
      recyclerView,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

    overlayHost.isClickable = false
    overlayHost.isFocusable = false
    overlayHost.clipChildren = false
    overlayHost.clipToPadding = false
    addView(
      overlayHost,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

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

  fun setSurfaceId(value: String) {
    surfaceId = value
    ChatListRegistry.register(surfaceId, this)
  }

  fun setRows(input: List<Map<String, Any?>>) {
    val previousDistanceFromBottom = currentDistanceFromBottom()
    val wasNearBottom = previousDistanceFromBottom <= LIST_BOTTOM_THRESHOLD || shouldAutoScroll

    val next = parseRows(input)
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

  fun setAppearance(rawAppearance: Map<String, Any?>) {
    val next = ChatListAppearance.from(rawAppearance)
    if (appearance.visualEquals(next)) return
    appearance = next
    adapter.setAppearance(appearance)
    applyAppearanceToView()
  }

  fun setContentPaddingBottom(value: Double) {
    val next = max(baseBottomPadding, dp(value))
    if (next == contentPaddingBottom) return
    contentPaddingBottom = next
    applyBottomAnchorPadding()
    emitViewport()
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
    onNativeEvent(
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
      val isMe = (message["isMe"] as? Boolean) ?: false
      val messageId = message["id"] as? String
      val messageType = ((message["type"] as? String) ?: "text").lowercase()
      val metadata = message["metadata"] as? Map<*, *>
      val mediaUrl =
        (message["mediaUrl"] as? String)
          ?: (message["media_url"] as? String)
          ?: (message["uri"] as? String)
          ?: (message["audioUrl"] as? String)
          ?: (message["audio_url"] as? String)
          ?: (metadata?.get("mediaUrl") as? String)
          ?: (metadata?.get("media_url") as? String)
          ?: (metadata?.get("uri") as? String)
          ?: (metadata?.get("audioUrl") as? String)
          ?: (metadata?.get("audio_url") as? String)
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
          isMe = isMe,
          messageId = messageId,
          shape = shape,
          messageType = messageType,
          mediaUrl = mediaUrl,
          duration = duration,
          waveform = waveform,
        ),
      )
    }

    return output
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

    onNativeEvent(
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
    overlayHost.removeView(running.overlay)
    activeTransition = null
    adapter.setHiddenMessageId(null)

    onNativeEvent(
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

    onViewportChanged(
      mapOf(
        "contentHeight" to contentHeight,
        "layoutHeight" to layoutHeight,
        "offsetY" to offsetY,
        "distanceFromBottom" to distanceFromBottom,
        "atBottom" to (distanceFromBottom <= LIST_BOTTOM_THRESHOLD),
      ),
    )
  }

  private fun applyBottomAnchorPadding() {
    val targetTop = computeBottomAnchoredTopPadding()
    if (
      recyclerView.paddingTop == targetTop &&
      recyclerView.paddingBottom == contentPaddingBottom &&
      recyclerView.paddingLeft == baseHorizontalPadding &&
      recyclerView.paddingRight == baseHorizontalPadding
    ) {
      return
    }
    recyclerView.setPadding(baseHorizontalPadding, targetTop, baseHorizontalPadding, contentPaddingBottom)
  }

  private fun applyAppearanceToView() {
    wallpaperView.background = GradientDrawable(
      GradientDrawable.Orientation.TOP_BOTTOM,
      appearance.wallpaperGradient,
    )
    wallpaperView.alpha = appearance.wallpaperOpacity
    wallpaperView.visibility = if (appearance.backgroundMode == "gradient") View.VISIBLE else View.GONE
  }

  private fun computeBottomAnchoredTopPadding(): Int {
    val itemCount = adapter.itemCount
    if (itemCount <= 0 || recyclerView.height <= 0) {
      return baseTopPadding
    }
    val firstPos = layoutManager.findFirstVisibleItemPosition()
    val lastPos = layoutManager.findLastVisibleItemPosition()
    if (firstPos != 0 || lastPos != itemCount - 1) {
      return baseTopPadding
    }
    val firstView = layoutManager.findViewByPosition(firstPos) ?: return baseTopPadding
    val lastView = layoutManager.findViewByPosition(lastPos) ?: return baseTopPadding
    val contentHeight = max(0, lastView.bottom - firstView.top)
    val available = recyclerView.height - contentPaddingBottom
    return max(baseTopPadding, available - contentHeight)
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

  private fun lerp(a: Float, b: Float, t: Float): Float = a + ((b - a) * t)
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

    val particleCount = 11
    for (index in 0 until particleCount) {
      val size = dpF(3.2f + ((index % 4) * 0.9f))
      val dot =
        View(context).apply {
          alpha = 0.94f
          background =
            GradientDrawable().apply {
              shape = GradientDrawable.OVAL
              setColor(withAlpha(color, 0.94f - ((index % 3) * 0.08f)))
            }
        }
      addView(dot, LayoutParams(size.roundToInt().coerceAtLeast(2), size.roundToInt().coerceAtLeast(2)))
      dot.x = x - (size * 0.5f)
      dot.y = y - (size * 0.5f)

      val angle = ((Math.PI * 2.0 * index) / particleCount.toDouble()).toFloat()
      val radial = dpF(24f + ((index % 5) * 6f))
      val dx = (cos(angle.toDouble()) * radial).toFloat()
      val dy = ((sin(angle.toDouble()) * radial * 0.72) - dpF(14f + ((index % 4) * 3f))).toFloat()

      dot.animate()
        .translationXBy(dx)
        .translationYBy(dy)
        .alpha(0f)
        .scaleX(0.35f)
        .scaleY(0.35f)
        .setStartDelay((index % 4) * 14L)
        .setDuration(430L)
        .setInterpolator(verticalInterpolator)
        .withEndAction { removeView(dot) }
        .start()
    }

    postDelayed({
      onDone()
    }, 620L)
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).roundToInt()
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

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

  private fun lerp(a: Float, b: Float, t: Float): Float = a + ((b - a) * t)
}
