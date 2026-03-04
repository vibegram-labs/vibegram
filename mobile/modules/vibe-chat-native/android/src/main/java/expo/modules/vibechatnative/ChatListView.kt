package expo.modules.vibechatnative

import android.content.Context
import android.content.Intent
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
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.Typeface
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
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
import okio.buffer
import okio.sink
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
  val fileName: String?,
  val duration: Double?,
  val waveform: List<Float>?,
  val isAgentMessage: Boolean = false,
  val agentName: String? = null,
  val plainContent: String? = null,
  val uploadProgress: Float? = null,
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

private class TypingRowViewHolder(val container: FrameLayout, val shimmerView: ShimmerTextView) : RecyclerView.ViewHolder(container)

private const val VIEW_TYPE_MESSAGE = 0
private const val VIEW_TYPE_TYPING = 1

private class NativeRowsAdapter(
  private val context: Context,
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
  private val contextMenuOverlay = ChatContextMenuOverlay(context)

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
    private var activeDownloadCall: okhttp3.Call? = null

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
        val player = mediaPlayer
        if (player == null) {
          if (activeDownloadCall != null) {
            Log.d("ChatListView", "voice cancel download messageId=$messageId")
            stop(resetProgress = true)
          }
          return
        }
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

      if (mediaUrl.startsWith("http://") || mediaUrl.startsWith("https://")) {
        playRemoteUrl(mediaUrl, messageId, holder)
        return
      }

      playLocalUrl(mediaUrl, messageId, holder)
    }

    private fun playRemoteUrl(rawUrl: String, messageId: String, holder: NativeRowViewHolder) {
      val cacheDir = java.io.File(context.cacheDir, "voice-cache")
      if (!cacheDir.exists()) {
        cacheDir.mkdirs()
      }

      // Hash the absolute URL string for filename to allow caching
      val filename = String.format("%016x", rawUrl.hashCode().toLong() and 0xFFFFFFFFL) + ".m4a"
      val localFile = java.io.File(cacheDir, filename)

      if (localFile.exists()) {
        playLocalUrl(localFile.absolutePath, messageId, holder)
        return
      }

      activeMessageId = messageId
      activeHolder = holder
      applyState(holder, false, 0f, 0f)

      val request = okhttp3.Request.Builder().url(rawUrl).build()
      val call = okhttp3.OkHttpClient().newCall(request)
      activeDownloadCall = call
      
      call.enqueue(object : okhttp3.Callback {
        override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
          Log.e("ChatListView", "voice download failed url=$rawUrl error=${e.message}", e)
          handler.post {
            if (activeMessageId == messageId) {
              stop(resetProgress = true)
            }
          }
        }

        override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
          if (!response.isSuccessful) {
            Log.e("ChatListView", "voice download failed url=$rawUrl code=${response.code}")
            handler.post {
              if (activeMessageId == messageId) {
                stop(resetProgress = true)
              }
            }
            return
          }
          try {
            val sink = localFile.sink().buffer()
            sink.writeAll(response.body!!.source())
            sink.close()
            handler.post {
              if (activeMessageId == messageId) {
                playLocalUrl(localFile.absolutePath, messageId, holder)
              }
            }
          } catch (e: Exception) {
            Log.e("ChatListView", "voice move failed error=${e.message}", e)
            handler.post {
              if (activeMessageId == messageId) {
                stop(resetProgress = true)
              }
            }
          }
        }
      })
    }

    private fun playLocalUrl(mediaUrl: String, messageId: String, holder: NativeRowViewHolder) {
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
      holder.voiceButton.setPlaybackState(isPlaying = isPlaying, progress = progress)
      holder.voiceWaveView.updatePlayback(progress, level, isPlaying)
    }

    private fun stop(resetProgress: Boolean) {
      activeDownloadCall?.cancel()
      activeDownloadCall = null
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

    return createNativeMessageRowViewHolder(context)
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
      holder.inlineAttachmentView.setOnClickListener(null)
      holder.inlineAttachmentView.visibility = View.GONE
      voicePlayback.detach(holder)
      holder.voiceWaveView.updatePlayback(0f, 0f, false)
      holder.voiceWaveView.setWaveform(null)
      holder.voiceButton.setPlaybackState(isPlaying = false, progress = 0f)
      holder.agentSenderLabel.visibility = View.GONE
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

  private fun resolveFileName(fileName: String?, mediaUrl: String?): String {
    if (!fileName.isNullOrBlank()) return fileName
    val parsed = mediaUrl?.trim().orEmpty()
    if (parsed.isEmpty()) return "Document"
    val clean = parsed.substringBefore('?').substringBefore('#')
    val candidate = clean.substringAfterLast('/', "").trim()
    return if (candidate.isNotEmpty()) candidate else "Document"
  }

  private fun openDocumentInApp(rawUrl: String) {
    val trimmed = sanitizeOpenUrl(rawUrl)
    if (trimmed.isEmpty()) return
    val uri = Uri.parse(trimmed)
    try {
      val intent = Intent(Intent.ACTION_VIEW).apply {
        setData(uri)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      }
      context.startActivity(intent)
    } catch (error: Throwable) {
      Log.w("ChatListView", "openDocumentInApp failed url=${trimmed.take(120)} error=${error.message}")
      emitNativeEvent(
        mapOf(
          "type" to "fileOpenFailed",
          "url" to trimmed,
        ),
      )
    }
  }

  private fun sanitizeOpenUrl(rawUrl: String): String {
    var value = rawUrl.trim()
    value = value.replace(
      Regex("^https?://\\[(https?://[^\\]]+)](/.*)?$", RegexOption.IGNORE_CASE),
      "$1$2",
    )
    value = value.replace(
      Regex("^\\[(https?://[^\\]]+)](/.*)?$", RegexOption.IGNORE_CASE),
      "$1$2",
    )
    value = value.replaceFirst("https://https://", "https://")
    value = value.replaceFirst("http://http://", "http://")
    return value
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
      agentSenderLabel.visibility = View.GONE
      inlineAttachmentView.visibility = View.GONE
      voiceWaveView.setWaveform(null)
      container.setOnLongClickListener(null)
      return
    }

    dayLabel.visibility = View.GONE
    bubbleContainer.visibility = View.VISIBLE
    bubbleContainer.alpha = if (hidden) 0f else 1f

    val isVoice = item.messageType == "voice" || item.messageType == "music"
    val hasInlineAttachment =
      item.isAgentMessage &&
        item.messageType == "file" &&
        !item.mediaUrl.isNullOrBlank()

    // Agent message rendering
    if (item.isAgentMessage) {
      agentSenderLabel.text = "✦ ${item.agentName ?: "Vibe AI"}"
      agentSenderLabel.visibility = if (hidden) View.GONE else View.VISIBLE
      textView.text = item.plainContent ?: item.text
    } else {
      agentSenderLabel.visibility = View.GONE
      textView.text = item.text
    }
    timeView.text = item.timestamp
    // Agent messages use "them" styling (not isMe)
    val effectiveIsMe = if (item.isAgentMessage) false else item.isMe
    textView.setTextColor(if (effectiveIsMe) appearance.textColorMe else appearance.textColorThem)
    inlineAttachmentTitleView.setTextColor(if (effectiveIsMe) appearance.textColorMe else appearance.textColorThem)
    inlineAttachmentSubtitleView.setTextColor(if (effectiveIsMe) withAlpha(appearance.textColorMe, 0.76f) else withAlpha(appearance.textColorThem, 0.70f))
    timeView.setTextColor(if (effectiveIsMe) appearance.timeColorMe else appearance.timeColorThem)
    voiceDurationView.text = formatDuration(item.duration)
    voiceWaveView.setWaveform(item.waveform)

    val lp = bubbleContainer.layoutParams as FrameLayout.LayoutParams
    lp.gravity = if (effectiveIsMe) Gravity.END else Gravity.START
    bubbleContainer.layoutParams = lp

    val wallpaperAnchor = appearance.wallpaperGradient.firstOrNull() ?: appearance.bubbleThemColor
    val isDarkPalette = Color.luminance(wallpaperAnchor) < 0.42f
    val bubbleMeGradient =
      appearance.bubbleMeGradient.map { base ->
        blend(base, wallpaperAnchor, if (isDarkPalette) 0.14f else 0.18f)
      }.toIntArray()
    val bubbleThemFill = withAlpha(
      blend(appearance.bubbleThemColor, wallpaperAnchor, if (isDarkPalette) 0.16f else 0.22f),
      if (isDarkPalette) 0.88f else 0.90f,
    )
    val metaBaseColor = if (effectiveIsMe) appearance.timeColorMe else appearance.timeColorThem
    val displayStatus = statusResolver?.invoke(item) ?: item.status
    statusView.bind(displayStatus, metaBaseColor)
    val showStatus = effectiveIsMe && when (displayStatus?.lowercase()) {
      "pending", "sent", "delivered", "read", "error" -> true
      else -> false
    }
    statusView.visibility = if (showStatus) View.VISIBLE else View.GONE

    val statusLp = statusView.layoutParams as FrameLayout.LayoutParams
    statusLp.gravity = Gravity.END or Gravity.BOTTOM
    statusLp.rightMargin = 0
    statusLp.bottomMargin = 0
    statusView.layoutParams = statusLp

    val baseStatusWidth = when(displayStatus?.lowercase()) {
      "sent" -> 16
      "delivered", "read" -> 22
      else -> 16
    }
    
    val timeLp = timeView.layoutParams as FrameLayout.LayoutParams
    timeLp.gravity = Gravity.END or Gravity.BOTTOM
    timeLp.rightMargin = if (showStatus) dp(baseStatusWidth + 3) else 0
    timeLp.bottomMargin = 0
    timeView.layoutParams = timeLp

    val drawable = if (effectiveIsMe) {
      GradientDrawable(
        GradientDrawable.Orientation.TL_BR,
        bubbleMeGradient,
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

    // Position agent sender label above the text content
    if (item.isAgentMessage && agentSenderLabel.visibility == View.VISIBLE) {
      val agentLp = agentSenderLabel.layoutParams as FrameLayout.LayoutParams
      agentLp.gravity = Gravity.START or Gravity.TOP
      agentLp.topMargin = 0
      agentSenderLabel.layoutParams = agentLp
      val textLpAgent = textView.layoutParams as FrameLayout.LayoutParams
      textLpAgent.topMargin = dp(18)
      textView.layoutParams = textLpAgent
    } else {
      val textLpAgent = textView.layoutParams as FrameLayout.LayoutParams
      textLpAgent.topMargin = 0
      textView.layoutParams = textLpAgent
    }

    if (isVoice) {
      bubbleContainer.setPadding(dp(8), dp(6), dp(10), dp(4))
      textView.visibility = View.GONE
      inlineAttachmentView.visibility = View.GONE
      inlineAttachmentView.setOnClickListener(null)
      voiceContainer.visibility = View.VISIBLE
      bubbleContainer.minimumWidth = dp(258)
      val voiceTextColor = if (effectiveIsMe) appearance.textColorMe else appearance.textColorThem
      val voiceFillColor = if (effectiveIsMe) Color.argb(245, 255, 255, 255) else Color.argb(230, 255, 255, 255)
      val voiceIconTint =
        if (effectiveIsMe) {
          bubbleMeGradient.firstOrNull() ?: Color.BLUE
        } else {
          withAlpha(voiceTextColor, 0.95f)
        }
      val voiceRingTint = withAlpha(voiceTextColor, 0.74f)
      voiceButton.applyStyle(
        fillColor = voiceFillColor,
        iconTint = voiceIconTint,
        ringTint = voiceRingTint,
      )
      voiceDurationView.setTextColor(if (effectiveIsMe) withAlpha(appearance.textColorMe, 0.78f) else withAlpha(appearance.textColorThem, 0.78f))
      voiceDurationView.gravity = Gravity.START or Gravity.CENTER_VERTICAL
      voiceWaveView.setColors(
        activeColor = withAlpha(voiceTextColor, 0.95f),
        inactiveColor = withAlpha(voiceTextColor, 0.34f),
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
        voiceButton.setPlaybackState(isPlaying = externalVoiceIsPlaying, progress = externalVoiceProgress)
      } else {
        voicePlayback.bind(this, item)
      }

      if (item.uploadProgress != null && item.uploadProgress > 0f && item.uploadProgress < 1f) {
        voiceUploadProgressView.visibility = View.VISIBLE
        voiceUploadProgressView.progress = item.uploadProgress
      } else {
        voiceUploadProgressView.visibility = View.GONE
      }
    } else {
      bubbleContainer.setPadding(dp(10), dp(7), dp(10), if (hasInlineAttachment) dp(7) else dp(7))
      textView.visibility = View.VISIBLE
      voiceContainer.visibility = View.GONE
      voiceUploadProgressView.visibility = View.GONE
      bubbleContainer.minimumWidth = dp(26)
      voiceButton.setOnClickListener(null)
      voiceButton.setPlaybackState(isPlaying = false, progress = 0f)
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
      textLp.rightMargin = if (hasInlineAttachment) 0 else metaReserve
      textLp.bottomMargin = if (hasInlineAttachment) dp(48 + 8 + 17) else 0
      textView.layoutParams = textLp

      if (hasInlineAttachment) {
        inlineAttachmentView.visibility = View.VISIBLE
        inlineAttachmentTitleView.text = resolveFileName(item.fileName, item.mediaUrl)
        val attachmentLp = inlineAttachmentView.layoutParams as FrameLayout.LayoutParams
        attachmentLp.gravity = Gravity.START or Gravity.BOTTOM
        attachmentLp.topMargin = 0
        attachmentLp.rightMargin = 0
        attachmentLp.leftMargin = 0
        attachmentLp.bottomMargin = dp(17)
        inlineAttachmentView.layoutParams = attachmentLp
        inlineAttachmentView.setOnClickListener {
          val url = item.mediaUrl ?: return@setOnClickListener
          openDocumentInApp(url)
        }
      } else {
        inlineAttachmentView.visibility = View.GONE
        inlineAttachmentView.setOnClickListener(null)
      }
    }

    container.setOnLongClickListener {
      if (hidden) return@setOnLongClickListener false
      val messageId = item.messageId?.takeIf { it.isNotBlank() } ?: return@setOnLongClickListener false
      container.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
      animateHoldAndOpenContextMenu(
        anchor = bubbleContainer,
        holdView = container,
        tailView = if (tailView.visibility == View.VISIBLE && tailView.width > 0 && tailView.height > 0) tailView else null,
        item = item,
        messageId = messageId,
      )
      true
    }

    if (!hidden && item.shape.showTail) {
      tailView.configure(
        isMe = effectiveIsMe,
        visible = true,
        color = if (effectiveIsMe) bubbleMeGradient.lastOrNull() ?: Color.WHITE else bubbleThemFill,
      )
      val tailLp = tailView.layoutParams as FrameLayout.LayoutParams
      tailLp.gravity = if (effectiveIsMe) Gravity.END or Gravity.BOTTOM else Gravity.START or Gravity.BOTTOM
      tailLp.marginStart = 0
      tailLp.marginEnd = 0
      tailLp.bottomMargin = 0
      if (effectiveIsMe) tailLp.marginEnd = dp(-27) else tailLp.marginStart = dp(-27)
      tailView.layoutParams = tailLp
    } else {
      tailView.visibility = View.GONE
    }
  }

  private fun dismissContextMenu(animated: Boolean = true) {
    contextMenuOverlay.dismiss(animated = animated)
  }

  private fun animateHoldAndOpenContextMenu(
    anchor: View,
    holdView: View,
    tailView: View?,
    item: NativeRowItem,
    messageId: String,
  ) {
    showContextMenu(
      anchor = anchor,
      holdView = holdView,
      tailView = tailView,
      item = item,
      messageId = messageId,
      animateHold = true,
    )
  }

  private fun showContextMenu(
    anchor: View,
    holdView: View = anchor,
    tailView: View? = null,
    item: NativeRowItem,
    messageId: String,
    animateHold: Boolean = false,
  ) {
    val actions = ArrayList<Pair<String, String>>()
    actions.add("reply" to "Reply")
    if (item.text.isNotBlank()) actions.add("copy" to "Copy")
    if (item.isMe && item.text.isNotBlank()) actions.add("edit" to "Edit")
    actions.add("pin" to "Pin")
    if (item.isMe && item.status?.lowercase() == "error") actions.add("resend" to "Resend")
    actions.add("delete" to "Delete")

    emitNativeEvent(
      mapOf(
        "type" to "contextMenuOpened",
        "messageId" to messageId,
      ),
    )

    contextMenuOverlay.show(
      anchor = anchor,
      config = ChatContextMenuOverlay.Config(
        appearance = appearance,
        isMe = item.isMe,
        actions = actions,
      ),
      animateHold = animateHold,
      holdView = holdView,
      tailView = tailView,
      onReaction = { emoji, sourceX, sourceY ->
        emitNativeEvent(
          mapOf(
            "type" to "contextMenuReaction",
            "emoji" to emoji,
            "messageId" to messageId,
            "sourceX" to sourceX,
            "sourceY" to sourceY,
          ),
        )
      },
      onAction = { actionId ->
        emitNativeEvent(
          mapOf(
            "type" to "contextMenuAction",
            "action" to actionId,
            "messageId" to messageId,
          ),
        )
      },
    )
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
  // Enable Android's native layout system so RecyclerView children are measured/laid out
  // even when React Native Fabric suppresses the standard requestLayout() traversal.
  override val shouldUseAndroidLayout: Boolean = true

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
  private val adapter = NativeRowsAdapter(context) { payload -> emitNativeEvent(payload) }
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
  private var engineIsGroupOrChannel: Boolean = false
  private var engineOpenedChatId: String = ""
  private var statusAuthorityEnabled: Boolean = false
  private val engineListenerId = "chat-list-view-${System.identityHashCode(this)}"
  private var sourceRowsPayload: List<Map<String, Any?>> = emptyList()
  private val nativeEngineRowsById = linkedMapOf<String, Map<String, Any?>>()
  private val nativeEngineOrder = mutableListOf<String>()
  private val nativeDeletedMessageIds = linkedSetOf<String>()
  private var mergedRowsLogCount = 0
  private var lastMergedRowsUseNative: Boolean? = null

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



    inputBar.layoutParams = FrameLayout.LayoutParams(
      LayoutParams.MATCH_PARENT,
      LayoutParams.WRAP_CONTENT,
      Gravity.BOTTOM,
    )
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

      override fun onAttachmentImage(uri: String, caption: String?) {
        val normalized = uri.trim()
        if (normalized.isEmpty()) return
        val payload = mutableMapOf<String, Any>(
          "type" to "attachmentImage",
          "uri" to normalized,
        )
        val captionText = caption?.trim().orEmpty()
        if (captionText.isNotEmpty()) {
          payload["caption"] = captionText
        }
        Log.i("ChatListView", "onAttachmentImage uri=$normalized captionLen=${captionText.length}")
        emitNativeEvent(payload)
      }

      override fun onAttachmentFile(uri: String, name: String, size: Long?, mimeType: String?, caption: String?) {
        val normalized = uri.trim()
        if (normalized.isEmpty()) return
        val resolvedName = name.trim().ifBlank { "File" }
        val captionText = caption?.trim().orEmpty()
        Log.i(
          "ChatListView",
          "onAttachmentFile uri=$normalized name=$resolvedName size=${size ?: -1L} mimeType=${mimeType.orEmpty()} captionLen=${captionText.length}",
        )
        val payload = mutableMapOf<String, Any>(
          "type" to "attachmentFile",
          "uri" to normalized,
          "name" to resolvedName,
        )
        size?.let { payload["size"] = it.toDouble() }
        if (!mimeType.isNullOrBlank()) {
          payload["mimeType"] = mimeType
        }
        if (captionText.isNotEmpty()) {
          payload["caption"] = captionText
        }
        emitNativeEvent(payload)
      }

      override fun onAttachmentLocation(latitude: Double, longitude: Double, caption: String?) {
        val payload = mutableMapOf<String, Any>(
          "type" to "attachmentLocation",
          "latitude" to latitude,
          "longitude" to longitude,
        )
        val captionText = caption?.trim().orEmpty()
        if (captionText.isNotEmpty()) {
          payload["caption"] = captionText
        }
        Log.i("ChatListView", "onAttachmentLocation latitude=$latitude longitude=$longitude captionLen=${captionText.length}")
        emitNativeEvent(payload)
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
            val statusSnapshot = ChatEngine.getStatus()
            Log.w(
              "ChatListView",
              "native ChatEngine send blocked: empty chatId messageId=$messageId myUserId=$myUserId peerUserId=$peerUserId surfaceId=$engineSurfaceId status=$statusSnapshot",
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
                "isGroup" to engineIsGroupOrChannel,
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
                "native ChatEngine sendMessage rejected: result=$result chatId=$chatId messageId=$messageId myUserId=$myUserId peerUserId=$peerUserId isGroup=$engineIsGroupOrChannel status=$statusSnapshot journalTail=$journalTail",
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

      override fun onSendTextWithAgentMention(text: String, agentText: String, messageId: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        Log.i(
          "ChatListView",
          "onSendTextWithAgentMention textLen=${trimmed.length} agentTextLen=${agentText.length} messageId=$messageId nativeSendEnabled=$nativeSendEnabled chatId=${engineChatId.trim()}",
        )
        if (nativeSendEnabled) {
          val chatId = engineChatId.trim()
          val myUserId = engineMyUserId.trim()
          val peerUserId = enginePeerUserId.trim()
          if (chatId.isEmpty()) {
            Log.w("ChatListView", "native ChatEngine agent send blocked: empty chatId messageId=$messageId")
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
                "isGroup" to engineIsGroupOrChannel,
                "agentMention" to true,
                "agentText" to agentText,
              ),
            )
            val accepted = (result["accepted"] as? Boolean) == true
            Log.i(
              "ChatListView",
              "native ChatEngine sendMessage(agentMention) accepted=$accepted chatId=$chatId messageId=$messageId",
            )
          }
          return
        }
        emitNativeEvent(
          mapOf(
            "type" to "sendMessage",
            "text" to trimmed,
            "messageId" to messageId,
            "agentMention" to true,
            "agentText" to agentText,
          ),
        )
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
    contentFrame.addView(inputBar)

    inputBar.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
      if (!inputBarEnabled) return@addOnLayoutChangeListener
      val oldHeight = oldBottom - oldTop
      val newHeight = bottom - top
      if (oldHeight == newHeight) return@addOnLayoutChangeListener
      applyBottomAnchorPadding()
      if (shouldAutoScroll) {
        scrollToBottom(false)
      } else {
        emitViewport()
      }
    }

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
    if (statusAuthorityEnabled) {
      registerChatEngineListener()
      hydrateRowsFromNativeHistoryIfReady("chatId")
    }
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

  fun setEngineIsGroupOrChannel(value: Boolean) {
    if (engineIsGroupOrChannel == value) return
    engineIsGroupOrChannel = value
    Log.i("ChatListView", "setEngineIsGroupOrChannel isGroupOrChannel=$engineIsGroupOrChannel")
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
      val mergedPayload = mergedRowsPayload(input)
      val next = parseRows(mergedPayload)
      if (next.isEmpty() && input.isNotEmpty()) {
        val firstInputKind = (input.firstOrNull()?.get("kind") as? String) ?: "-"
        val firstMergedKind = (mergedPayload.firstOrNull()?.get("kind") as? String) ?: "-"
        Log.w(
          "ChatListView",
          "setRows parsed-empty input=${input.size} merged=${mergedPayload.size} firstInputKind=$firstInputKind firstMergedKind=$firstMergedKind chatId=$engineChatId surfaceId=$engineSurfaceId",
        )
      }
      mainHandler.post {
        if (generation != parseGeneration) return@post // stale, skip
        rows.clear()
        rows.addAll(next)
        adapter.setRows(next)
        val shouldLog =
          input.isEmpty() ||
            next.isEmpty() ||
            generation <= 6 ||
            generation % 20 == 0
        if (shouldLog) {
          Log.i(
            "ChatListView",
            "setRows applied generation=$generation input=${input.size} merged=${mergedPayload.size} parsed=${next.size} attached=$isAttachedToWindow recycler=${recyclerView.width}x${recyclerView.height}",
          )
          logRowDiagnostics(
            generation = generation,
            input = input,
            mergedPayload = mergedPayload,
            parsedRows = next,
          )
        }
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
          if (shouldLog) {
            val firstVisible = layoutManager.findFirstVisibleItemPosition()
            val lastVisible = layoutManager.findLastVisibleItemPosition()
            Log.d(
              "ChatListView",
              "setRows viewport generation=$generation itemCount=${adapter.itemCount} childCount=${recyclerView.childCount} firstVisible=$firstVisible lastVisible=$lastVisible offset=${recyclerView.computeVerticalScrollOffset()} extent=${recyclerView.computeVerticalScrollExtent()} range=${recyclerView.computeVerticalScrollRange()}",
            )
          }
        }
      }
    }
  }

  private fun logRowDiagnostics(
    generation: Int,
    input: List<Map<String, Any?>>,
    mergedPayload: List<Map<String, Any?>>,
    parsedRows: List<NativeRowItem>,
  ) {
    if (parsedRows.isEmpty()) {
      val inputKinds = input.take(4).joinToString(",") { ((it["kind"] as? String) ?: "-") }
      val mergedKinds = mergedPayload.take(4).joinToString(",") { ((it["kind"] as? String) ?: "-") }
      Log.w(
        "ChatListView",
        "setRows diagnostics generation=$generation parsed=0 inputKinds=[$inputKinds] mergedKinds=[$mergedKinds]",
      )
      return
    }

    var dayCount = 0
    var messageCount = 0
    var typingCount = 0
    var nonEmptyTextCount = 0
    var mediaCount = 0
    var fileCount = 0
    var voiceCount = 0
    val typeCounts = linkedMapOf<String, Int>()

    for (row in parsedRows) {
      when (row.kind) {
        "day" -> dayCount += 1
        "message" -> messageCount += 1
      }
      if (row.messageType == "typing") typingCount += 1
      if (row.text.trim().isNotEmpty()) nonEmptyTextCount += 1
      if (!row.mediaUrl.isNullOrBlank()) mediaCount += 1
      if (!row.fileName.isNullOrBlank()) fileCount += 1
      if (row.messageType == "voice" || row.messageType == "music") voiceCount += 1
      val nextCount = (typeCounts[row.messageType] ?: 0) + 1
      typeCounts[row.messageType] = nextCount
    }

    val typeSummary = typeCounts.entries.joinToString(",") { (type, count) -> "$type=$count" }
    val preview = parsedRows.take(4).joinToString(" | ") { row ->
      val previewText = row.text.replace("\n", " ").take(32)
      val mediaTail = row.mediaUrl?.takeLast(28) ?: "-"
      "${row.kind}/${row.messageType} id=${row.messageId ?: "-"} textLen=${row.text.length} text='$previewText' media='$mediaTail'"
    }
    Log.d(
      "ChatListView",
      "setRows diagnostics generation=$generation rows=${parsedRows.size} day=$dayCount message=$messageCount typing=$typingCount nonEmptyText=$nonEmptyTextCount media=$mediaCount file=$fileCount voice=$voiceCount types=[$typeSummary] preview=$preview",
    )
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

    // Restore the native overlay from ChatEngine's live message index so that
    // messages sent/received while the view was detached appear immediately
    // without waiting for the JS store to push updated rows.
    if (nativeEngineRowsById.isEmpty()) {
      val liveRows = ChatEngine.getLiveMessageRows(mapOf("chatId" to resolvedChatId))
      if (liveRows.isNotEmpty()) {
        for ((messageId, row) in liveRows) {
          nativeEngineRowsById[messageId] = row
          if (!nativeEngineOrder.contains(messageId)) {
            nativeEngineOrder.add(messageId)
          }
        }
        Log.i(
          "ChatListView",
          "hydrateRowsFromNativeHistoryIfReady restored overlay from live rows trigger=$trigger chatId=$resolvedChatId count=${liveRows.size}",
        )
      }
    }

    val historyLoaded = ChatEngine.isChatHistoryLoaded(mapOf("chatId" to resolvedChatId))
    if (!historyLoaded && nativeEngineRowsById.isEmpty()) return
    Log.i(
      "ChatListView",
      "hydrateRowsFromNativeHistoryIfReady trigger=$trigger chatId=$resolvedChatId sourceRows=${sourceRowsPayload.size} overlay=${nativeEngineRowsById.size} historyLoaded=$historyLoaded",
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
    var usedNativeRows = false
    val effectiveBaseRows: List<Map<String, Any?>> =
      if (statusAuthorityEnabled && engineChatId.isNotBlank()) {
        val historyLoaded = ChatEngine.isChatHistoryLoaded(mapOf("chatId" to engineChatId))
        if (historyLoaded) {
          val nativeRows = ChatEngine.getChatRows(mapOf("chatId" to engineChatId))
          val shouldUseNative = (nativeRows.isNotEmpty() && nativeRows.size >= baseRows.size) || baseRows.isEmpty()
          usedNativeRows = shouldUseNative
          if (shouldUseNative) {
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

    if (statusAuthorityEnabled && engineChatId.isNotBlank()) {
      val shouldLog =
        mergedRowsLogCount < 12 ||
          lastMergedRowsUseNative != usedNativeRows ||
          (effectiveBaseRows.isEmpty() && baseRows.isNotEmpty())
      if (shouldLog) {
        Log.i(
          "ChatListView",
          "mergedRowsPayload chatId=$engineChatId useNative=$usedNativeRows baseRows=${baseRows.size} effectiveRows=${effectiveBaseRows.size} nativeOverlay=${nativeEngineRowsById.size} deleted=${nativeDeletedMessageIds.size}",
        )
      }
      mergedRowsLogCount += 1
      lastMergedRowsUseNative = usedNativeRows
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
            fileName = null,
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
      if (messageType == "typing") {
        continue
      }
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
      val fileName =
        (message["fileName"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
          ?: (message["file_name"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
          ?: (metadata?.get("fileName") as? String)?.trim()?.takeIf { it.isNotEmpty() }
          ?: (metadata?.get("file_name") as? String)?.trim()?.takeIf { it.isNotEmpty() }
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

      val rawIsAgentMessage = (message["isAgentMessage"] as? Boolean) ?: false
      val rawAgentName = (message["agentName"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
      val rawPlainContent = (message["plainContent"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
      val uploadProgress = (message["uploadProgress"] as? Number)?.toFloat()

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
          fileName = fileName,
          duration = duration,
          waveform = waveform,
          isAgentMessage = rawIsAgentMessage,
          agentName = rawAgentName,
          plainContent = rawPlainContent,
          uploadProgress = uploadProgress,
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
    val targetBottom = contentPaddingBottom + inputBarOverlayHeightPx()
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

  private fun inputBarOverlayHeightPx(): Int {
    if (!inputBarEnabled || inputBar.visibility != View.VISIBLE) return 0
    return max(0, max(inputBar.height, inputBar.measuredHeight))
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
    // Keep host backgrounds transparent so no extra block appears behind the input bar.
    setBackgroundColor(Color.TRANSPARENT)
    contentFrame.setBackgroundColor(Color.TRANSPARENT)
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
    textSize = 12f
    setPadding(0, 0, (context.resources.displayMetrics.density * 40).toInt(), 0)
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    if (w > 0 && h > 0) {
      val baseColor = currentTextColor
      val highlightColor = Color.WHITE
      shimmerGradient = LinearGradient(
        0f, 0f, w.toFloat() * 0.8f, 0f, // Wider gradient for smooth shimmer
        intArrayOf(baseColor, highlightColor, baseColor),
        floatArrayOf(0f, 0.5f, 1f),
        Shader.TileMode.CLAMP
      )
      paint.shader = shimmerGradient
    }
  }

  override fun onDraw(canvas: Canvas) {
    if (shimmerAnimator?.isRunning == true && shimmerGradient != null) {
      // Move gradient from deep left to deep right
      gradientMatrix.setTranslate(shimmerFraction * width * 3f - width, 0f)
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
