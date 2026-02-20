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
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

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
)

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
  private val barCount = 28
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
      barEnvelope = normalized.toFloatArray()
      invalidate()
      return
    }
    val bucketSize = normalized.size.toFloat() / barCount.toFloat()
    val next = FloatArray(barCount)
    for (index in 0 until barCount) {
      val start = kotlin.math.floor(index * bucketSize).toInt()
      val end = min(normalized.size, kotlin.math.floor((index + 1) * bucketSize).toInt())
      if (start < end) {
        var sum = 0f
        for (i in start until end) sum += normalized[i]
        next[index] = sum / (end - start).toFloat()
      } else {
        val clamped = min(max(0, start), normalized.size - 1)
        next[index] = normalized[clamped]
      }
    }
    barEnvelope = next
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
          (kotlin.math.sin((phase + (index * 0.62f)).toDouble()) * 0.08 + 0.92).toFloat()
        } else {
          1.0f
        }
      val liveBoost = if (isPlaying) level * 0.18f else 0f
      val amplitude = ((base + liveBoost) * pulse).coerceIn(0.12f, 1f)
      val barHeight = minHeight + ((maxHeight - minHeight) * amplitude)
      val y = (height - barHeight) * 0.5f
      val paint = if (normalizedIndex < playbackProgress) activePaint else inactivePaint
      val r = barWidth * 0.5f
      canvas.drawRoundRect(x, y, x + barWidth, y + barHeight, r, r, paint)
      x += barWidth + spacing
    }
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
      holder.voiceButton.text = if (isPlaying) "❚❚" else "▶"
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
      voicePlayback.bind(this, item)
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

    val startX = number("startX") ?: return null
    val startY = number("startY") ?: return null
    val startWidth = number("startWidth") ?: return null
    val startHeight = number("startHeight") ?: return null

    val selfLocation = IntArray(2)
    getLocationOnScreen(selfLocation)
    val rect = RectF(
      startX - selfLocation[0],
      startY - selfLocation[1],
      startX - selfLocation[0] + startWidth,
      startY - selfLocation[1] + startHeight,
    )

    return SendTransitionPayload(
      messageId = messageId,
      text = text,
      timestamp = timestamp,
      startRect = rect,
    )
  }

  private fun maybeStartPendingTransition() {
    if (activeTransition != null) return
    val payload = pendingSendTransition ?: return
    val index = adapter.findMessageIndex(payload.messageId)
    if (index < 0) return
    val targetRect = resolveTargetRect(index) ?: return

    pendingSendTransition = null
    adapter.setHiddenMessageId(payload.messageId)

    val overlay = SendTransitionOverlayView(context, appearance).apply {
      bind(payload.text, payload.timestamp)
      updateProgress(0f)
      updateFrame(payload.startRect)
    }
    overlayHost.addView(
      overlay,
      FrameLayout.LayoutParams(
        payload.startRect.width().roundToInt().coerceAtLeast(1),
        payload.startRect.height().roundToInt().coerceAtLeast(1),
      ).apply {
        leftMargin = payload.startRect.left.roundToInt()
        topMargin = payload.startRect.top.roundToInt()
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

    val start = transition.payload.startRect
    val target = transition.targetRect
    val x = lerp(start.left, target.left, px)
    val y = lerp(start.top, target.top, py) + transition.scrollCompensationY
    val w = lerp(start.width(), target.width(), px).coerceAtLeast(1f)
    val h = lerp(start.height(), target.height(), py).coerceAtLeast(1f)

    transition.overlay.updateFrame(RectF(x, y, x + w, y + h))
    transition.overlay.updateProgress(py)
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

private class SendTransitionOverlayView(
  context: Context,
  private val appearance: ChatListAppearance,
) : FrameLayout(context) {
  private val background = View(context)
  private val inputText = TextView(context)
  private val bubbleText = TextView(context)
  private val timeText = TextView(context)

  init {
    clipChildren = false
    clipToPadding = false

    background.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    addView(background)

    inputText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    inputText.setTextColor(appearance.textColorMe)
    inputText.setLineSpacing(0f, 1.1f)

    bubbleText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    bubbleText.setTextColor(appearance.textColorMe)
    bubbleText.setLineSpacing(0f, 1.1f)

    timeText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    timeText.setTextColor(appearance.timeColorMe)
    timeText.gravity = Gravity.END

    addView(
      inputText,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
        leftMargin = dp(10)
        rightMargin = dp(10)
        topMargin = dp(7)
      },
    )
    addView(
      bubbleText,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
        leftMargin = dp(10)
        rightMargin = dp(10)
        topMargin = dp(7)
      },
    )
    addView(
      timeText,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
        leftMargin = dp(10)
        rightMargin = dp(10)
        bottomMargin = dp(5)
      },
    )

    background.background = GradientDrawable(
      GradientDrawable.Orientation.TL_BR,
      appearance.bubbleMeGradient,
    ).apply {
      cornerRadii = floatArrayOf(
        dpF(18), dpF(18),
        dpF(18), dpF(18),
        dpF(18), dpF(18),
        dpF(18), dpF(18),
      )
    }
  }

  fun bind(text: String, timestamp: String) {
    inputText.text = text
    bubbleText.text = text
    timeText.text = timestamp
  }

  fun updateProgress(progress: Float) {
    val p = progress.coerceIn(0f, 1f)
    val bgOpacity = ((p - 0.1f) / 0.3f).coerceIn(0f, 1f)
    val inputOpacity = (1f - (p / 0.24f)).coerceIn(0f, 1f)
    val bubbleOpacity = ((p - 0.06f) / 0.28f).coerceIn(0f, 1f)

    background.alpha = bgOpacity
    inputText.alpha = inputOpacity
    bubbleText.alpha = bubbleOpacity
    timeText.alpha = bubbleOpacity
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
}
