package expo.modules.vibechatnative

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.graphics.Typeface
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.util.LruCache
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.TextureView
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URLConnection
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal data class ChatMediaPreviewRequest(
  val title: String,
  val caption: String,
  val sourceUrl: String?,
  val remoteUrl: String?,
  val localUrl: String?,
  val mediaKey: String?,
  val fileName: String?,
  val thumbnailBase64: String?,
  val isVideo: Boolean,
  val editable: Boolean = false,
  val mimeType: String? = null,
  val actionLabel: String? = null,
  val onCommit: ((ChatMediaEditResult) -> Unit)? = null,
)

internal data class ChatMediaEditResult(
  val mediaUrl: String,
  val caption: String?,
  val fileName: String?,
  val mimeType: String?,
  val isVideo: Boolean,
  val durationSeconds: Double?,
  val thumbnailBase64: String?,
)

internal object ChatMediaBitmapLoader {
  private const val TAG = "ChatMediaBitmap"
  private val bitmapCache = object : LruCache<String, Bitmap>(48) {}
  private val worker = Executors.newFixedThreadPool(2) { runnable ->
    Thread(runnable, "ChatMediaBitmapLoader").apply { isDaemon = true }
  }
  private val mainHandler = Handler(Looper.getMainLooper())

  fun loadInto(
    context: Context,
    imageView: ImageView,
    primaryUrl: String?,
    thumbnailBase64: String?,
    isVideo: Boolean,
    authorizationHeaderProvider: (() -> String?)? = null,
    onResolved: ((Bitmap?) -> Unit)? = null,
  ) {
    val trimmedPrimary = primaryUrl?.trim().orEmpty()
    val cacheKey =
      when {
        trimmedPrimary.isNotEmpty() -> (if (isVideo) "video:" else "image:") + trimmedPrimary
        !thumbnailBase64.isNullOrBlank() -> "thumb:${thumbnailBase64.hashCode()}"
        else -> null
      }

    cacheKey?.let { key ->
      bitmapCache.get(key)?.let { cached ->
        imageView.tag = key
        imageView.setImageBitmap(cached)
        onResolved?.invoke(cached)
        return
      }
    }

    val fallbackThumb = decodeBase64Thumbnail(thumbnailBase64)
    if (fallbackThumb != null) {
      imageView.setImageBitmap(fallbackThumb)
      onResolved?.invoke(fallbackThumb)
    } else {
      imageView.setImageDrawable(null)
      onResolved?.invoke(null)
    }
    imageView.tag = cacheKey

    if (trimmedPrimary.isEmpty()) {
      return
    }

    worker.execute {
      val resolved =
        try {
          if (isVideo) {
            decodeVideoFrame(context, trimmedPrimary)
          } else {
            decodeImageBitmap(context, trimmedPrimary, authorizationHeaderProvider)
          }
        } catch (error: Throwable) {
          Log.w(TAG, "loadInto failed url=${trimmedPrimary.take(160)} error=${error.message}")
          null
        }
      if (resolved != null && cacheKey != null) {
        bitmapCache.put(cacheKey, resolved)
      }
      mainHandler.post {
        if (imageView.tag != cacheKey) return@post
        if (resolved != null) {
          imageView.setImageBitmap(resolved)
        }
        onResolved?.invoke(resolved ?: fallbackThumb)
      }
    }
  }

  fun decodeBase64Thumbnail(raw: String?): Bitmap? {
    val trimmed = raw?.trim().orEmpty()
    if (trimmed.isEmpty()) return null
    return try {
      val bytes = Base64.decode(trimmed, Base64.DEFAULT)
      BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    } catch (_: Throwable) {
      null
    }
  }

  private fun decodeImageBitmap(
    context: Context,
    rawUrl: String,
    authorizationHeaderProvider: (() -> String?)?,
  ): Bitmap? {
    val uri = Uri.parse(rawUrl)
    val scheme = uri.scheme?.lowercase(Locale.ROOT)
    return when {
      scheme == "content" -> context.contentResolver.openInputStream(uri)?.use { stream ->
        BitmapFactory.decodeStream(stream)
      }
      scheme == "file" -> BitmapFactory.decodeFile(uri.path)
      rawUrl.startsWith("/") -> BitmapFactory.decodeFile(rawUrl)
      scheme == "http" || scheme == "https" -> {
        val request =
          okhttp3.Request.Builder()
            .url(rawUrl)
            .header("ngrok-skip-browser-warning", "true")
            .apply {
              authorizationHeaderProvider?.invoke()?.takeIf { it.isNotBlank() }?.let {
                header("Authorization", it)
              }
            }
            .build()
        ChatPhoenixClient.buildPinnedHttpClient().newCall(request).execute().use { response ->
          if (!response.isSuccessful) return null
          val bytes = response.body?.bytes() ?: return null
          BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }
      }
      else -> null
    }
  }

  private fun decodeVideoFrame(
    context: Context,
    rawUrl: String,
  ): Bitmap? {
    val retriever = MediaMetadataRetriever()
    try {
      val uri = Uri.parse(rawUrl)
      val scheme = uri.scheme?.lowercase(Locale.ROOT)
      when {
        scheme == "content" -> retriever.setDataSource(context, uri)
        scheme == "file" -> retriever.setDataSource(uri.path)
        rawUrl.startsWith("/") -> retriever.setDataSource(rawUrl)
        else -> return null
      }
      return retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
    } catch (_: Throwable) {
      return null
    } finally {
      try {
        retriever.release()
      } catch (_: Throwable) {
      }
    }
  }
}

private class ChatUnifiedMediaProgressView(
  context: Context,
) : View(context) {
  private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(48, 255, 255, 255)
  }
  private val bufferedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(102, 103, 178, 255)
  }
  private val playedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.WHITE
  }
  private val trackRect = RectF()
  private var playedFraction: Float = 0f
  private var bufferedFraction: Float = 0f

  fun updateProgress(played: Float, buffered: Float, downloading: Boolean) {
    val nextPlayed = played.coerceIn(0f, 1f)
    val nextBuffered = max(nextPlayed, buffered.coerceIn(0f, 1f))
    val nextBufferedColor = if (downloading) Color.argb(184, 66, 144, 255) else Color.argb(96, 255, 255, 255)
    if (
      abs(playedFraction - nextPlayed) < 0.003f &&
        abs(bufferedFraction - nextBuffered) < 0.003f &&
        bufferedPaint.color == nextBufferedColor
    ) {
      return
    }
    playedFraction = nextPlayed
    bufferedFraction = nextBuffered
    bufferedPaint.color = nextBufferedColor
    invalidate()
  }

  override fun onDraw(canvas: android.graphics.Canvas) {
    super.onDraw(canvas)
    if (width <= 0 || height <= 0) return
    val radius = height * 0.5f
    trackRect.set(0f, 0f, width.toFloat(), height.toFloat())
    canvas.drawRoundRect(trackRect, radius, radius, trackPaint)
    if (bufferedFraction > 0f) {
      trackRect.right = width * bufferedFraction
      canvas.drawRoundRect(trackRect, radius, radius, bufferedPaint)
    }
    if (playedFraction > 0f) {
      trackRect.right = width * playedFraction
      canvas.drawRoundRect(trackRect, radius, radius, playedPaint)
    }
  }
}

internal class ChatMediaPreviewOverlay(
  private val context: Context,
  private val hostView: ViewGroup,
  private val authorizationHeaderProvider: () -> String?,
) {
  private companion object {
    private const val TAG = "ChatMediaPreview"
  }

  private val mainHandler = Handler(Looper.getMainLooper())
  private val worker = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "ChatMediaPreviewWorker").apply { isDaemon = true }
  }
  private val progressTicker =
    object : Runnable {
      override fun run() {
        updatePlaybackProgress()
        if (isShowing && currentRequest?.isVideo == true) {
          mainHandler.postDelayed(this, 180L)
        }
      }
    }

  private var rootView: FrameLayout? = null
  private var mountedHostView: ViewGroup? = null
  private var scrimView: View? = null
  private var headerCard: View? = null
  private var bottomContainer: View? = null
  private var mediaContainer: FrameLayout? = null
  private var mediaPosterView: ImageView? = null
  private var mediaImageView: ImageView? = null
  private var videoTextureView: TextureView? = null
  private var playPauseBadge: TextView? = null
  private var loadingView: ProgressBar? = null
  private var titleView: TextView? = null
  private var actionButton: TextView? = null
  private var captionView: TextView? = null
  private var captionInput: EditText? = null
  private var leftTimeView: TextView? = null
  private var rightTimeView: TextView? = null
  private var progressView: ChatUnifiedMediaProgressView? = null

  private var currentRequest: ChatMediaPreviewRequest? = null
  private var isShowing = false
  private var isPrepared = false
  private var isDownloadingForPreview = false
  private var bufferedFraction = 0f
  private var durationMs = 0
  private var activeVideoSource: String? = null
  private var pendingVideoUri: Uri? = null
  private var localTempFile: File? = null
  private var activeCall: okhttp3.Call? = null
  private var activeMediaPlayer: MediaPlayer? = null
  private var activeSurface: Surface? = null
  private var activeVideoWidth = 0
  private var activeVideoHeight = 0
  private var lastPlaybackFraction = 0f

  private var velocityTracker: VelocityTracker? = null
  private var dragStarted = false
  private var gestureDownY = 0f
  private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop

  fun show(request: ChatMediaPreviewRequest) {
    dismiss(animated = false)
    currentRequest = request
    isShowing = true
    isPrepared = false
    isDownloadingForPreview = false
    bufferedFraction = 0f
    durationMs = 0
    activeVideoSource = null
    activeVideoWidth = 0
    activeVideoHeight = 0
    localTempFile = null
    dragStarted = false
    buildOverlay()
    bindRequest(request)
  }

  fun dismiss(animated: Boolean = true) {
    if (!isShowing) {
      cleanupPlayback()
      return
    }
    isShowing = false
    mainHandler.removeCallbacks(progressTicker)
    activeCall?.cancel()
    activeCall = null

    val root = rootView
    val scrim = scrimView
    val media = mediaContainer
    val header = headerCard
    val bottom = bottomContainer

    if (root == null) {
      removeOverlayView()
      return
    }

    if (!animated) {
      removeOverlayView()
      return
    }

    runCatching {
      activeMediaPlayer?.pause()
    }

    scrim?.animate()?.alpha(0f)?.setDuration(160L)?.start()
    header?.animate()?.translationY((-dp(24)).toFloat())?.alpha(0f)?.setDuration(170L)?.start()
    bottom?.animate()?.translationY(dp(24).toFloat())?.alpha(0f)?.setDuration(170L)?.start()
    media
      ?.animate()
      ?.translationY(max(root.height.toFloat(), currentHostHeight()) * 0.24f)
      ?.alpha(0f)
      ?.setDuration(180L)
      ?.withEndAction { removeOverlayView() }
      ?.start()
  }

  private fun buildOverlay() {
    val mountHost = resolveMountHost()
    val root =
      FrameLayout(context).apply {
        layoutParams =
          FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
          )
        isClickable = true
        isFocusable = true
        setBackgroundColor(Color.TRANSPARENT)
      }
    val scrim =
      View(context).apply {
        layoutParams =
          FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
          )
        setBackgroundColor(Color.argb(238, 6, 8, 13))
        alpha = 0f
        setOnClickListener { dismiss(animated = true) }
      }
    root.addView(scrim)

    val header = createGlassCard().apply { alpha = 0f }
    val headerRow =
      LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(14), dp(12), dp(14), dp(12))
      }
    val closeButton =
      createHeaderButton("Close").apply {
        setOnClickListener { dismiss(animated = true) }
      }
    val title =
      TextView(context).apply {
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        setTypeface(Typeface.DEFAULT_BOLD)
        gravity = Gravity.CENTER
        includeFontPadding = false
        maxLines = 1
      }
    val action =
      createHeaderButton("Save").apply {
        setOnClickListener {
          if (currentRequest?.editable == true) {
            commitCurrentMedia()
          } else {
            saveCurrentMedia()
          }
        }
      }
    headerRow.addView(
      closeButton,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
    )
    headerRow.addView(
      title,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 2f),
    )
    headerRow.addView(
      action,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
    )
    (header as ViewGroup).addView(headerRow)
    root.addView(
      header,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.TOP,
      ).apply {
        leftMargin = dp(14)
        rightMargin = dp(14)
        topMargin = dp(18) + statusBarInset()
      },
    )

    val mediaFrame =
      FrameLayout(context).apply {
        clipChildren = true
        clipToPadding = true
        background =
          GradientDrawable().apply {
            cornerRadius = dp(24).toFloat()
            setColor(Color.argb(36, 255, 255, 255))
          }
        alpha = 0f
      }
    val imageView =
      ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_CENTER
        adjustViewBounds = true
        visibility = View.GONE
        setOnTouchListener(::handleMediaTouch)
      }
    val posterView =
      ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_CENTER
        adjustViewBounds = true
        visibility = View.GONE
        setOnTouchListener(::handleMediaTouch)
      }
    val video =
      TextureView(context).apply {
        visibility = View.GONE
        isOpaque = false
        setOnTouchListener(::handleMediaTouch)
        addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
          applyVideoTextureTransform(activeVideoWidth, activeVideoHeight)
        }
        surfaceTextureListener =
          object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
              activeSurface?.release()
              activeSurface = Surface(surface)
              applyVideoTextureTransform(activeVideoWidth, activeVideoHeight)
              prepareTexturePlayerIfPossible()
            }

            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit

            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
              cleanupPlayback()
              activeSurface?.release()
              activeSurface = null
              return true
            }

            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
          }
      }
    val playBadge =
      TextView(context).apply {
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
        gravity = Gravity.CENTER
        text = "▶"
        background =
          GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.argb(108, 16, 20, 26))
            setStroke(max(1, dp(1)), Color.argb(62, 255, 255, 255))
          }
        visibility = View.GONE
      }
    val spinner =
      ProgressBar(context).apply {
        isIndeterminate = true
        visibility = View.GONE
      }
    mediaFrame.addView(
      imageView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
        Gravity.CENTER,
      ),
    )
    mediaFrame.addView(
      video,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
        Gravity.CENTER,
      ),
    )
    mediaFrame.addView(
      posterView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
        Gravity.CENTER,
      ),
    )
    mediaFrame.addView(
      playBadge,
      FrameLayout.LayoutParams(dp(72), dp(72), Gravity.CENTER),
    )
    mediaFrame.addView(
      spinner,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER,
      ),
    )
    mediaFrame.setOnTouchListener(::handleMediaTouch)
    val mediaFrameHeight =
      (context.resources.displayMetrics.heightPixels * 0.56f).roundToInt().coerceAtLeast(dp(240))
    root.addView(
      mediaFrame,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        mediaFrameHeight,
        Gravity.CENTER,
      ).apply {
        leftMargin = dp(12)
        rightMargin = dp(12)
        topMargin = dp(88) + statusBarInset()
        bottomMargin = dp(132) + navigationBarInset()
      },
    )

    val bottom = FrameLayout(context).apply { alpha = 0f }
    val captionCard = createGlassCard().apply { visibility = View.GONE }
    val caption =
      TextView(context).apply {
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        setLineSpacing(0f, 1.1f)
        includeFontPadding = false
        maxLines = 4
        setPadding(dp(16), dp(12), dp(16), dp(12))
      }
    val captionEditor =
      EditText(context).apply {
        setTextColor(Color.WHITE)
        setHintTextColor(Color.argb(132, 255, 255, 255))
        hint = "Add a caption..."
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        typeface = Typeface.DEFAULT
        includeFontPadding = false
        background = null
        setPadding(dp(16), dp(12), dp(16), dp(12))
        minLines = 1
        maxLines = 4
      }
    (captionCard as ViewGroup).addView(
      caption,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    (captionCard as ViewGroup).addView(
      captionEditor,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    val controlsCard = createGlassCard().apply { visibility = View.GONE }
    val controlsRow =
      LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(14), dp(12), dp(14), dp(12))
      }
    val leftTime = createTimerLabel().apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL }
    val progress = ChatUnifiedMediaProgressView(context)
    val rightTime = createTimerLabel().apply { gravity = Gravity.END or Gravity.CENTER_VERTICAL }
    controlsRow.addView(
      leftTime,
      LinearLayout.LayoutParams(dp(48), LinearLayout.LayoutParams.WRAP_CONTENT),
    )
    controlsRow.addView(
      progress,
      LinearLayout.LayoutParams(0, dp(4), 1f).apply {
        leftMargin = dp(12)
        rightMargin = dp(12)
      },
    )
    controlsRow.addView(
      rightTime,
      LinearLayout.LayoutParams(dp(48), LinearLayout.LayoutParams.WRAP_CONTENT),
    )
    (controlsCard as ViewGroup).addView(controlsRow)
    progress.setOnTouchListener { _, event ->
      if (event.actionMasked == MotionEvent.ACTION_UP) {
        val player = activeMediaPlayer ?: return@setOnTouchListener true
        if (!isPrepared || durationMs <= 0) return@setOnTouchListener true
        val fraction = (event.x / max(1f, progress.width.toFloat())).coerceIn(0f, 1f)
        player.seekTo((durationMs * fraction).roundToInt())
        updatePlaybackProgress()
      }
      true
    }
    bottom.addView(
      captionCard,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.TOP,
      ),
    )
    bottom.addView(
      controlsCard,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.BOTTOM,
      ),
    )
    root.addView(
      bottom,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.BOTTOM,
      ).apply {
        leftMargin = dp(14)
        rightMargin = dp(14)
        bottomMargin = dp(18) + navigationBarInset()
      },
    )

    mountHost.addView(
      root,
      ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      ),
    )
    mountHost.bringChildToFront(root)
    mountedHostView = mountHost
    rootView = root
    scrimView = scrim
    headerCard = header
    bottomContainer = bottom
    mediaContainer = mediaFrame
    mediaImageView = imageView
    mediaPosterView = posterView
    videoTextureView = video
    playPauseBadge = playBadge
    loadingView = spinner
    titleView = title
    actionButton = action
    captionView = caption
    captionInput = captionEditor
    leftTimeView = leftTime
    rightTimeView = rightTime
    progressView = progress

    scrim.animate().alpha(1f).setDuration(160L).start()
    header.animate().alpha(1f).translationY(0f).setDuration(190L).start()
    bottom.animate().alpha(1f).translationY(0f).setDuration(190L).start()
    mediaFrame.animate().alpha(1f).translationY(0f).setDuration(210L).start()
  }

  private fun bindRequest(request: ChatMediaPreviewRequest) {
    titleView?.text = request.title.trim().ifBlank { if (request.isVideo) "Video" else "Photo" }
    actionButton?.text =
      if (request.editable) {
        request.actionLabel?.trim().takeUnless { it.isNullOrEmpty() } ?: "Send"
      } else {
        "Save"
      }
    val captionText = request.caption.trim()
    captionView?.text = captionText
    captionInput?.setText(captionText)
    captionInput?.setSelection(captionInput?.text?.length ?: 0)
    captionView?.visibility = if (request.editable) View.GONE else View.VISIBLE
    captionInput?.visibility = if (request.editable) View.VISIBLE else View.GONE
    (captionView?.parent as? View)?.visibility =
      if (request.editable || captionText.isNotEmpty()) View.VISIBLE else View.GONE
    progressView?.updateProgress(0f, 0f, downloading = request.isVideo)
    leftTimeView?.text = "0:00"
    rightTimeView?.text = if (request.isVideo) "--:--" else ""
    (progressView?.parent?.parent as? View)?.visibility = if (request.isVideo) View.VISIBLE else View.GONE

    val bestVisualUrl = request.localUrl?.takeIf { it.isNotBlank() } ?: request.sourceUrl
    mediaPosterView?.visibility = if (request.thumbnailBase64.isNullOrBlank() && bestVisualUrl.isNullOrBlank()) View.GONE else View.VISIBLE
    ChatMediaBitmapLoader.loadInto(
      context = context,
      imageView = mediaPosterView ?: return,
      primaryUrl = if (request.isVideo) request.localUrl else bestVisualUrl,
      thumbnailBase64 = request.thumbnailBase64,
      isVideo = request.isVideo,
      authorizationHeaderProvider = authorizationHeaderProvider,
    )

    if (request.isVideo) {
      bindVideoRequest(request)
    } else {
      bindImageRequest(request)
    }
  }

  private fun bindImageRequest(request: ChatMediaPreviewRequest) {
    mediaImageView?.visibility = View.VISIBLE
    videoTextureView?.visibility = View.GONE
    playPauseBadge?.visibility = View.GONE
    loadingView?.visibility = View.GONE

    val imageTarget = mediaImageView ?: return
    val localUrl = request.localUrl?.trim().orEmpty()
    val remoteUrl = request.remoteUrl?.trim().orEmpty()
    if (localUrl.isNotEmpty()) {
      ChatMediaBitmapLoader.loadInto(
        context = context,
        imageView = imageTarget,
        primaryUrl = localUrl,
        thumbnailBase64 = request.thumbnailBase64,
        isVideo = false,
        authorizationHeaderProvider = authorizationHeaderProvider,
      )
      return
    }
    if (remoteUrl.isNotEmpty() && request.mediaKey.isNullOrBlank()) {
      ChatMediaBitmapLoader.loadInto(
        context = context,
        imageView = imageTarget,
        primaryUrl = remoteUrl,
        thumbnailBase64 = request.thumbnailBase64,
        isVideo = false,
        authorizationHeaderProvider = authorizationHeaderProvider,
      )
      return
    }
    if (remoteUrl.isNotEmpty() && !request.mediaKey.isNullOrBlank()) {
      loadingView?.visibility = View.VISIBLE
      downloadEncryptedMedia(
        request = request,
        onProgress = { progress ->
          progressView?.updateProgress(0f, progress, downloading = true)
        },
        onReady = { localFile ->
          loadingView?.visibility = View.GONE
          ChatMediaBitmapLoader.loadInto(
            context = context,
            imageView = imageTarget,
            primaryUrl = localFile.absolutePath,
            thumbnailBase64 = request.thumbnailBase64,
            isVideo = false,
            authorizationHeaderProvider = authorizationHeaderProvider,
          )
        },
      )
    }
  }

  private fun bindVideoRequest(request: ChatMediaPreviewRequest) {
    mediaImageView?.visibility = View.GONE
    videoTextureView?.visibility = View.VISIBLE
    playPauseBadge?.visibility = View.VISIBLE
    updatePlayBadge(isPlaying = false)

    val localUrl = request.localUrl?.trim().orEmpty()
    val remoteUrl = request.remoteUrl?.trim().orEmpty()
    when {
      localUrl.isNotEmpty() -> prepareVideoSource(localUrl)
      remoteUrl.isNotEmpty() && request.mediaKey.isNullOrBlank() -> prepareVideoSource(remoteUrl)
      remoteUrl.isNotEmpty() && !request.mediaKey.isNullOrBlank() -> {
        loadingView?.visibility = View.VISIBLE
        progressView?.updateProgress(0f, 0f, downloading = true)
        downloadEncryptedMedia(
          request = request,
          onProgress = { progress ->
            progressView?.updateProgress(lastPlaybackFraction, progress, downloading = true)
          },
          onReady = { localFile ->
            loadingView?.visibility = View.GONE
            prepareVideoSource(localFile.absolutePath)
          },
        )
      }
      else -> {
        videoTextureView?.visibility = View.GONE
        loadingView?.visibility = View.GONE
      }
    }
  }

  private fun prepareVideoSource(rawSource: String) {
    val sourceUri =
      try {
        when {
          rawSource.startsWith("content://") || rawSource.startsWith("file://") -> Uri.parse(rawSource)
          rawSource.startsWith("/") -> Uri.fromFile(File(rawSource))
          else -> Uri.parse(rawSource)
        }
      } catch (_: Throwable) {
        return
      }
    activeVideoSource = rawSource
    pendingVideoUri = sourceUri
    isPrepared = false
    durationMs = 0
    bufferedFraction = 0f
    lastPlaybackFraction = 0f
    activeVideoWidth = 0
    activeVideoHeight = 0
    progressView?.updateProgress(0f, 0f, downloading = false)
    leftTimeView?.text = "0:00"
    rightTimeView?.text = "--:--"
    loadingView?.visibility = View.VISIBLE
    mediaPosterView?.visibility = View.VISIBLE
    prepareTexturePlayerIfPossible()
  }

  private fun prepareTexturePlayerIfPossible() {
    val sourceUri = pendingVideoUri ?: return
    val surface = activeSurface ?: return
    val sourceKey = activeVideoSource ?: sourceUri.toString()
    if (activeMediaPlayer != null && isPrepared && sourceKey == activeVideoSource) {
      return
    }

    cleanupPlayback()
    val player =
      MediaPlayer().apply {
        setSurface(surface)
        setScreenOnWhilePlaying(true)
        setOnPreparedListener { preparedPlayer ->
          activeMediaPlayer = preparedPlayer
          isPrepared = true
          loadingView?.visibility = View.GONE
          durationMs = max(0, preparedPlayer.duration)
          rightTimeView?.text = formatDuration(durationMs)
          preparedPlayer.start()
          updatePlayBadge(isPlaying = true)
          mediaPosterView?.visibility = View.GONE
          mainHandler.removeCallbacks(progressTicker)
          mainHandler.post(progressTicker)
        }
        setOnVideoSizeChangedListener { _, videoWidth, videoHeight ->
          activeVideoWidth = videoWidth
          activeVideoHeight = videoHeight
          applyVideoTextureTransform(videoWidth, videoHeight)
        }
        setOnBufferingUpdateListener { _, percent ->
          bufferedFraction = (percent / 100f).coerceIn(lastPlaybackFraction, 1f)
          progressView?.updateProgress(lastPlaybackFraction, bufferedFraction, downloading = false)
        }
        setOnInfoListener { _, what, _ ->
          when (what) {
            MediaPlayer.MEDIA_INFO_BUFFERING_START -> loadingView?.visibility = View.VISIBLE
            MediaPlayer.MEDIA_INFO_BUFFERING_END -> loadingView?.visibility = View.GONE
          }
          false
        }
        setOnCompletionListener {
          updatePlaybackProgress(forceEnded = true)
          updatePlayBadge(isPlaying = false)
          loadingView?.visibility = View.GONE
        }
      }
    activeMediaPlayer = player
    runCatching {
      player.setDataSource(context, sourceUri)
      player.prepareAsync()
    }.onFailure { error ->
      Log.w(TAG, "prepareTexturePlayerIfPossible failed uri=${sourceUri} error=${error.message}")
      cleanupPlayback()
      loadingView?.visibility = View.GONE
    }
  }

  private fun applyVideoTextureTransform(videoWidth: Int, videoHeight: Int) {
    val textureView = videoTextureView ?: return
    if (videoWidth <= 0 || videoHeight <= 0 || textureView.width <= 0 || textureView.height <= 0) {
      textureView.setTransform(null)
      return
    }
    val viewWidth = textureView.width.toFloat()
    val viewHeight = textureView.height.toFloat()
    val contentWidth = videoWidth.toFloat()
    val contentHeight = videoHeight.toFloat()
    val scale = min(viewWidth / contentWidth, viewHeight / contentHeight)
    val scaledWidth = contentWidth * scale
    val scaledHeight = contentHeight * scale
    val dx = (viewWidth - scaledWidth) * 0.5f
    val dy = (viewHeight - scaledHeight) * 0.5f
    val matrix = Matrix()
    matrix.setScale(scale, scale)
    matrix.postTranslate(dx, dy)
    textureView.setTransform(matrix)
  }

  private fun updatePlaybackProgress(forceEnded: Boolean = false) {
    val player = activeMediaPlayer ?: return
    if (!isPrepared || durationMs <= 0) return
    val current = if (forceEnded) durationMs else max(0, player.currentPosition)
    val fraction = (current / max(1f, durationMs.toFloat())).coerceIn(0f, 1f)
    lastPlaybackFraction = fraction
    leftTimeView?.text = formatDuration(current)
    rightTimeView?.text = formatDuration(durationMs)
    progressView?.updateProgress(fraction, max(bufferedFraction, fraction), downloading = isDownloadingForPreview)
    if (forceEnded) {
      player.pause()
      mediaPosterView?.visibility = View.VISIBLE
      progressView?.updateProgress(1f, 1f, downloading = false)
    }
  }

  private fun togglePlayback() {
    val player = activeMediaPlayer ?: return
    if (!isPrepared) return
    if (player.isPlaying) {
      player.pause()
      updatePlayBadge(isPlaying = false)
    } else {
      if (player.currentPosition >= max(0, durationMs - 180)) {
        player.seekTo(0)
      }
      player.start()
      mediaPosterView?.visibility = View.GONE
      updatePlayBadge(isPlaying = true)
      mainHandler.removeCallbacks(progressTicker)
      mainHandler.post(progressTicker)
    }
  }

  private fun updatePlayBadge(isPlaying: Boolean) {
    playPauseBadge?.text = if (isPlaying) "Ⅱ" else "▶"
  }

  private fun handleMediaTouch(view: View, event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        velocityTracker?.recycle()
        velocityTracker = VelocityTracker.obtain()
        velocityTracker?.addMovement(event)
        dragStarted = false
        gestureDownY = event.rawY
        return true
      }
      MotionEvent.ACTION_MOVE -> {
        velocityTracker?.addMovement(event)
        val deltaY = max(0f, event.rawY - gestureDownY)
        if (!dragStarted && deltaY > touchSlop) {
          dragStarted = true
        }
        if (dragStarted) {
          applyDragOffset(deltaY)
          return true
        }
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        velocityTracker?.addMovement(event)
        velocityTracker?.computeCurrentVelocity(1000)
        val velocityY = velocityTracker?.yVelocity ?: 0f
        val deltaY = max(0f, event.rawY - gestureDownY)
        val shouldDismiss =
          dragStarted && (deltaY > max(currentHostHeight() * 0.18f, dp(96).toFloat()) || velocityY > 1400f)
        velocityTracker?.recycle()
        velocityTracker = null
        if (shouldDismiss) {
          dismiss(animated = true)
          return true
        }
        if (dragStarted) {
          resetDraggedViews()
          return true
        }
        if (currentRequest?.isVideo == true) {
          togglePlayback()
          return true
        }
      }
    }
    return false
  }

  private fun applyDragOffset(offsetY: Float) {
    mediaContainer?.translationY = offsetY
    headerCard?.translationY = offsetY
    bottomContainer?.translationY = offsetY
    val fade = 1f - min(0.72f, offsetY / max(1f, currentHostHeight()))
    scrimView?.alpha = fade
  }

  private fun resetDraggedViews() {
    mediaContainer?.animate()?.translationY(0f)?.setDuration(180L)?.start()
    headerCard?.animate()?.translationY(0f)?.setDuration(180L)?.start()
    bottomContainer?.animate()?.translationY(0f)?.setDuration(180L)?.start()
    scrimView?.animate()?.alpha(1f)?.setDuration(160L)?.start()
  }

  private fun downloadEncryptedMedia(
    request: ChatMediaPreviewRequest,
    onProgress: (Float) -> Unit,
    onReady: (File) -> Unit,
  ) {
    val remoteUrl = request.remoteUrl?.trim().orEmpty()
    val mediaKey = request.mediaKey?.trim().orEmpty()
    if (remoteUrl.isEmpty() || mediaKey.isEmpty()) return
    isDownloadingForPreview = true
    val httpRequest =
      okhttp3.Request.Builder()
        .url(remoteUrl)
        .header("ngrok-skip-browser-warning", "true")
        .apply {
          authorizationHeaderProvider().takeIf { !it.isNullOrBlank() }?.let {
            header("Authorization", it)
          }
        }
        .build()
    val call = ChatPhoenixClient.buildPinnedHttpClient().newCall(httpRequest)
    activeCall = call
    worker.execute {
      try {
        call.execute().use { response ->
          if (!response.isSuccessful) {
            throw java.io.IOException("http ${response.code}")
          }
          val body = response.body ?: throw java.io.IOException("missing body")
          val totalLength = body.contentLength().takeIf { it > 0 } ?: -1L
          val source = body.source()
          val buffer = okio.Buffer()
          var downloaded = 0L
          val encryptedOutput = ByteArrayOutputStream()
          while (true) {
            val read = source.read(buffer, 16_384L)
            if (read <= 0L) break
            val chunk = buffer.readByteArray(read)
            downloaded += chunk.size
            encryptedOutput.write(chunk)
            val progress =
              if (totalLength > 0) {
                (downloaded.toFloat() / totalLength.toFloat()).coerceIn(0f, 1f)
              } else {
                0.027f
              }
            mainHandler.post {
              if (!isShowing) return@post
              onProgress(progress)
            }
          }
          val encrypted = encryptedOutput.toByteArray()
          val decrypted =
            chatEngineDecryptMediaBytes(encrypted, mediaKey)
              ?: throw java.io.IOException("decrypt failed")
          val tempFile = persistPreviewTempFile(request, decrypted)
          localTempFile = tempFile
          mainHandler.post {
            if (!isShowing) return@post
            isDownloadingForPreview = false
            progressView?.updateProgress(lastPlaybackFraction, 1f, downloading = false)
            onReady(tempFile)
          }
        }
      } catch (error: Throwable) {
        Log.w(TAG, "downloadEncryptedMedia failed url=${remoteUrl.take(160)} error=${error.message}")
        mainHandler.post {
          if (!isShowing) return@post
          isDownloadingForPreview = false
          loadingView?.visibility = View.GONE
          Toast.makeText(context, "Couldn't load media", Toast.LENGTH_SHORT).show()
        }
      }
    }
  }

  private fun saveCurrentMedia() {
    val request = currentRequest ?: return
    val localPath = localTempFile?.absolutePath ?: request.localUrl?.trim().orEmpty()
    if (localPath.isNotEmpty()) {
      worker.execute {
        val success =
          runCatching {
            saveFileToGallery(
              source = localPath,
              fileName = request.fileName,
              isVideo = request.isVideo,
            )
          }.getOrElse { false }
        mainHandler.post {
          Toast.makeText(
            context,
            if (success) "Saved to Photos" else "Couldn't save media",
            Toast.LENGTH_SHORT,
          ).show()
        }
      }
      return
    }

    val remoteUrl = request.remoteUrl?.trim().orEmpty()
    if (remoteUrl.isEmpty()) return

    loadingView?.visibility = View.VISIBLE
    worker.execute {
      val saved =
        try {
          if (!request.mediaKey.isNullOrBlank()) {
            val localFile = localTempFile ?: downloadEncryptedMediaForSave(request)
            if (localFile != null) {
              saveFileToGallery(localFile.absolutePath, request.fileName, request.isVideo)
            } else {
              false
            }
          } else {
            saveRemoteMediaToGallery(remoteUrl, request.fileName, request.isVideo)
          }
        } catch (_: Throwable) {
          false
        }
      mainHandler.post {
        loadingView?.visibility = if (currentRequest?.isVideo == true && !isPrepared) View.VISIBLE else View.GONE
        Toast.makeText(
          context,
          if (saved) "Saved to Photos" else "Couldn't save media",
          Toast.LENGTH_SHORT,
        ).show()
      }
    }
  }

  private fun commitCurrentMedia() {
    val request = currentRequest ?: return
    val resolvedMediaUrl =
      localTempFile?.absolutePath
        ?: request.localUrl?.trim().takeIf { !it.isNullOrEmpty() }
        ?: request.sourceUrl?.trim().takeIf { !it.isNullOrEmpty() }
        ?: return
    val captionText = captionInput?.text?.toString()?.trim().orEmpty()
    val durationSeconds =
      if (request.isVideo) {
        when {
          durationMs > 0 -> durationMs / 1000.0
          else -> resolveMediaDurationSeconds(resolvedMediaUrl)
        }
      } else {
        null
      }
    request.onCommit?.invoke(
      ChatMediaEditResult(
        mediaUrl = resolvedMediaUrl,
        caption = captionText.ifEmpty { null },
        fileName = request.fileName,
        mimeType = request.mimeType,
        isVideo = request.isVideo,
        durationSeconds = durationSeconds,
        thumbnailBase64 = resolveCommittedThumbnailBase64(),
      ),
    )
    dismiss(animated = true)
  }

  private fun downloadEncryptedMediaForSave(request: ChatMediaPreviewRequest): File? {
    val remoteUrl = request.remoteUrl?.trim().orEmpty()
    val mediaKey = request.mediaKey?.trim().orEmpty()
    if (remoteUrl.isEmpty() || mediaKey.isEmpty()) return null
    val httpRequest =
      okhttp3.Request.Builder()
        .url(remoteUrl)
        .header("ngrok-skip-browser-warning", "true")
        .apply {
          authorizationHeaderProvider().takeIf { !it.isNullOrBlank() }?.let {
            header("Authorization", it)
          }
        }
        .build()
    ChatPhoenixClient.buildPinnedHttpClient().newCall(httpRequest).execute().use { response ->
      if (!response.isSuccessful) return null
      val encryptedBytes = response.body?.bytes() ?: return null
      val decrypted = chatEngineDecryptMediaBytes(encryptedBytes, mediaKey) ?: return null
      return persistPreviewTempFile(request, decrypted)
    }
  }

  private fun saveRemoteMediaToGallery(remoteUrl: String, fileName: String?, isVideo: Boolean): Boolean {
    val httpRequest =
      okhttp3.Request.Builder()
        .url(remoteUrl)
        .header("ngrok-skip-browser-warning", "true")
        .apply {
          authorizationHeaderProvider().takeIf { !it.isNullOrBlank() }?.let {
            header("Authorization", it)
          }
        }
        .build()
    ChatPhoenixClient.buildPinnedHttpClient().newCall(httpRequest).execute().use { response ->
      if (!response.isSuccessful) return false
      val bytes = response.body?.bytes() ?: return false
      return saveBytesToGallery(bytes, fileName, remoteUrl, isVideo)
    }
  }

  private fun saveFileToGallery(source: String, fileName: String?, isVideo: Boolean): Boolean {
    val uri = Uri.parse(source)
    val scheme = uri.scheme?.lowercase(Locale.ROOT)
    val bytes =
      when {
        scheme == "content" -> context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        scheme == "file" -> uri.path?.let { File(it).takeIf(File::exists)?.readBytes() }
        source.startsWith("/") -> File(source).takeIf(File::exists)?.readBytes()
        else -> null
      } ?: return false
    return saveBytesToGallery(bytes, fileName, source, isVideo)
  }

  private fun saveBytesToGallery(
    bytes: ByteArray,
    fileName: String?,
    source: String,
    isVideo: Boolean,
  ): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      return false
    }
    val extension =
      fileName?.substringAfterLast('.', "")?.trim()?.lowercase(Locale.ROOT)
        ?.takeIf { it.isNotEmpty() }
        ?: source.substringBefore('?').substringAfterLast('.', "").trim().lowercase(Locale.ROOT)
          .takeIf { it.isNotEmpty() }
        ?: if (isVideo) "mp4" else "jpg"
    val displayName =
      fileName?.trim()?.takeIf { it.isNotEmpty() }
        ?: "vibe_${System.currentTimeMillis()}.$extension"
    val mimeType =
      URLConnection.guessContentTypeFromName(displayName)
        ?: if (isVideo) "video/mp4" else "image/jpeg"
    val collection =
      if (isVideo) {
        MediaStore.Video.Media.EXTERNAL_CONTENT_URI
      } else {
        MediaStore.Images.Media.EXTERNAL_CONTENT_URI
      }
    val relativePath = if (isVideo) "Movies/Vibe" else "Pictures/Vibe"
    val values =
      ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
        put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
        put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
        put(MediaStore.MediaColumns.IS_PENDING, 1)
      }
    val resolver = context.contentResolver
    val targetUri = resolver.insert(collection, values) ?: return false
    return try {
      resolver.openOutputStream(targetUri)?.use { output ->
        output.write(bytes)
        output.flush()
      } ?: return false
      values.clear()
      values.put(MediaStore.MediaColumns.IS_PENDING, 0)
      resolver.update(targetUri, values, null, null)
      true
    } catch (_: Throwable) {
      resolver.delete(targetUri, null, null)
      false
    }
  }

  private fun persistPreviewTempFile(
    request: ChatMediaPreviewRequest,
    bytes: ByteArray,
  ): File {
    val extension =
      request.fileName?.substringAfterLast('.', "")?.trim()?.lowercase(Locale.ROOT)
        ?.takeIf { it.isNotEmpty() }
        ?: if (request.isVideo) "mp4" else "jpg"
    val baseName =
      request.fileName?.substringBeforeLast('.', request.fileName)?.trim()?.ifBlank { "media" }
        ?: "media"
    val safeName = baseName.replace(Regex("[^A-Za-z0-9_-]+"), "-")
    val file =
      File(context.cacheDir, "${safeName}_${System.currentTimeMillis()}.$extension")
    file.outputStream().use { output ->
      output.write(bytes)
      output.flush()
    }
    return file
  }

  private fun resolveCommittedThumbnailBase64(): String? {
    currentRequest?.thumbnailBase64?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    val drawable =
      mediaPosterView?.drawable
        ?: mediaImageView?.drawable
        ?: return null
    val bitmap = drawableToBitmap(drawable) ?: return null
    return encodeBitmapToBase64(bitmap)
  }

  private fun drawableToBitmap(drawable: Drawable): Bitmap? {
    if (drawable is BitmapDrawable) {
      return drawable.bitmap
    }
    val width = drawable.intrinsicWidth.takeIf { it > 0 } ?: mediaContainer?.width ?: 0
    val height = drawable.intrinsicHeight.takeIf { it > 0 } ?: mediaContainer?.height ?: 0
    if (width <= 0 || height <= 0) return null
    return runCatching {
      Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { bitmap ->
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
      }
    }.getOrNull()
  }

  private fun encodeBitmapToBase64(bitmap: Bitmap): String? {
    return runCatching {
      val output = ByteArrayOutputStream()
      bitmap.compress(Bitmap.CompressFormat.JPEG, 82, output)
      Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
    }.getOrNull()
  }

  private fun resolveMediaDurationSeconds(rawSource: String): Double? {
    val retriever = MediaMetadataRetriever()
    return try {
      val uri = Uri.parse(rawSource)
      val scheme = uri.scheme?.lowercase(Locale.ROOT)
      when {
        scheme == "content" -> retriever.setDataSource(context, uri)
        scheme == "file" -> retriever.setDataSource(uri.path)
        rawSource.startsWith("/") -> retriever.setDataSource(rawSource)
        else -> return null
      }
      val durationString = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
      durationString?.toLongOrNull()?.let { value -> value / 1000.0 }
    } catch (_: Throwable) {
      null
    } finally {
      try {
        retriever.release()
      } catch (_: Throwable) {
      }
    }
  }

  private fun cleanupPlayback() {
    try {
      activeMediaPlayer?.stop()
    } catch (_: Throwable) {
    }
    try {
      activeMediaPlayer?.reset()
    } catch (_: Throwable) {
    }
    try {
      activeMediaPlayer?.release()
    } catch (_: Throwable) {
    }
    activeMediaPlayer = null
    isPrepared = false
    durationMs = 0
    bufferedFraction = 0f
    lastPlaybackFraction = 0f
    activeVideoWidth = 0
    activeVideoHeight = 0
  }

  private fun removeOverlayView() {
    cleanupPlayback()
    val root = rootView
    rootView = null
    scrimView = null
    headerCard = null
    bottomContainer = null
    mediaContainer = null
    mediaPosterView = null
    mediaImageView = null
    videoTextureView = null
    playPauseBadge = null
    loadingView = null
    titleView = null
    actionButton = null
    captionView = null
    captionInput = null
    leftTimeView = null
    rightTimeView = null
    progressView = null
    currentRequest = null
    localTempFile = null
    pendingVideoUri = null
    activeVideoSource = null
    activeVideoWidth = 0
    activeVideoHeight = 0
    activeSurface?.release()
    activeSurface = null
    if (root != null) {
      mountedHostView?.removeView(root)
    }
    mountedHostView = null
  }

  private fun createGlassCard(): View {
    return FrameLayout(context).apply {
      background =
        GradientDrawable().apply {
          cornerRadius = dp(24).toFloat()
          setColor(Color.argb(86, 14, 18, 24))
          setStroke(max(1, dp(1)), Color.argb(52, 255, 255, 255))
        }
      elevation = dp(6).toFloat()
    }
  }

  private fun createHeaderButton(label: String): TextView {
    return TextView(context).apply {
      text = label
      setTextColor(Color.WHITE)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
      setTypeface(Typeface.DEFAULT_BOLD)
      includeFontPadding = false
      gravity = Gravity.CENTER_VERTICAL
      setPadding(dp(4), 0, dp(4), 0)
    }
  }

  private fun createTimerLabel(): TextView {
    return TextView(context).apply {
      setTextColor(Color.argb(224, 255, 255, 255))
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
      includeFontPadding = false
      text = "0:00"
    }
  }

  private fun statusBarInset(): Int {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      (mountedHostView ?: hostView).rootWindowInsets
        ?.getInsets(android.view.WindowInsets.Type.statusBars())
        ?.top ?: 0
    } else {
      0
    }
  }

  private fun navigationBarInset(): Int {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      (mountedHostView ?: hostView).rootWindowInsets
        ?.getInsets(android.view.WindowInsets.Type.navigationBars())
        ?.bottom ?: 0
    } else {
      0
    }
  }

  private fun resolveMountHost(): ViewGroup {
    val rootCandidate = hostView.rootView
    return when {
      rootCandidate is ViewGroup -> rootCandidate
      hostView.parent is ViewGroup -> hostView.parent as ViewGroup
      else -> hostView
    }
  }

  private fun currentHostHeight(): Float {
    val mounted = mountedHostView
    if (mounted != null && mounted.height > 0) {
      return mounted.height.toFloat()
    }
    val hostHeight = hostView.height.toFloat()
    return if (hostHeight > 0f) hostHeight else context.resources.displayMetrics.heightPixels.toFloat()
  }

  private fun formatDuration(durationMs: Int): String {
    val totalSeconds = max(0, durationMs / 1000)
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return String.format(Locale.US, "%d:%02d", minutes, seconds)
  }

  private fun dp(value: Int): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).roundToInt()
}
