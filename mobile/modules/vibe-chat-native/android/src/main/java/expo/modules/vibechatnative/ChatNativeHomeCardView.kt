package expo.modules.vibechatnative

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.LruCache
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

internal class ChatNativeHomeCardView(context: Context) : FrameLayout(context) {
  companion object {
    private val avatarHttpClient by lazy { ChatPhoenixClient.buildPinnedHttpClient() }
    private val avatarBitmapCache = object : LruCache<String, android.graphics.Bitmap>(64) {}
  }

  private val pressOverlay = FrameLayout(context)
  private val divider = FrameLayout(context)
  private val avatarContainer = FrameLayout(context)
  private val avatarImage = ImageView(context)
  private val avatarFallbackIcon = ImageView(context)
  private val onlineDot = ViewFactory.dot(context)

  private val textColumn = LinearLayout(context)
  private val titleView = TextView(context)
  private val previewView = TextView(context)

  private val metaColumn = LinearLayout(context)
  private val timeView = TextView(context)
  private val badgeView = TextView(context)
  private val iconsView = TextView(context)
  private var isPressedVisual = false
  private var avatarLoadToken = 0
  private var avatarLoadCall: Call? = null

  init {
    layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, dp(84f))
    minimumHeight = dp(84f)
    setPadding(dp(16f), dp(12f), dp(16f), dp(12f))
    isClickable = true
    isFocusable = true
    setBackgroundColor(Color.TRANSPARENT)

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      val outValue = TypedValue()
      if (context.theme.resolveAttribute(android.R.attr.selectableItemBackground, outValue, true)) {
        foreground = context.getDrawable(outValue.resourceId)
      }
    }

    pressOverlay.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    pressOverlay.alpha = 0f
    pressOverlay.isClickable = false
    pressOverlay.isFocusable = false
    addView(pressOverlay)

    avatarContainer.layoutParams = LayoutParams(dp(60f), dp(60f)).apply {
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
    }
    avatarContainer.background = circleDrawable(Color.argb(255, 222, 230, 243))
    avatarContainer.clipToOutline = true
    avatarContainer.outlineProvider = ViewOutlineProvider.BACKGROUND
    addView(avatarContainer)

    avatarImage.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    avatarImage.scaleType = ImageView.ScaleType.CENTER_CROP
    avatarImage.visibility = GONE
    avatarContainer.addView(avatarImage)

    avatarFallbackIcon.layoutParams = LayoutParams(dp(24f), dp(24f)).apply {
      gravity = Gravity.CENTER
    }
    avatarFallbackIcon.scaleType = ImageView.ScaleType.FIT_CENTER
    avatarFallbackIcon.setImageResource(R.drawable.ic_avatar_person)
    avatarContainer.addView(avatarFallbackIcon)

    onlineDot.layoutParams = LayoutParams(dp(12f), dp(12f)).apply {
      gravity = Gravity.END or Gravity.BOTTOM
      marginEnd = dp(2f)
      bottomMargin = dp(2f)
    }
    avatarContainer.addView(onlineDot)

    textColumn.orientation = LinearLayout.VERTICAL
    textColumn.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
      marginStart = dp(74f)
      marginEnd = dp(88f)
    }
    textColumn.gravity = Gravity.CENTER_VERTICAL
    addView(textColumn)

    titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
    titleView.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    titleView.maxLines = 1
    titleView.ellipsize = android.text.TextUtils.TruncateAt.END
    textColumn.addView(titleView)

    previewView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
    previewView.maxLines = 1
    previewView.ellipsize = android.text.TextUtils.TruncateAt.END
    previewView.layoutParams = LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.WRAP_CONTENT,
      LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      topMargin = dp(2f)
    }
    textColumn.addView(previewView)

    metaColumn.orientation = LinearLayout.VERTICAL
    metaColumn.gravity = Gravity.END or Gravity.CENTER_VERTICAL
    metaColumn.layoutParams = LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
      gravity = Gravity.END or Gravity.CENTER_VERTICAL
    }
    addView(metaColumn)

    timeView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    timeView.typeface = Typeface.DEFAULT
    timeView.gravity = Gravity.END
    metaColumn.addView(timeView)

    badgeView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    badgeView.typeface = Typeface.DEFAULT_BOLD
    badgeView.gravity = Gravity.CENTER
    badgeView.setPadding(dp(6f), dp(2f), dp(6f), dp(2f))
    badgeView.minWidth = dp(20f)
    badgeView.layoutParams = LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.WRAP_CONTENT,
      dp(20f),
    ).apply {
      topMargin = dp(4f)
      gravity = Gravity.END
    }
    badgeView.background = circleDrawable(Color.argb(255, 23, 132, 209))
    metaColumn.addView(badgeView)

    iconsView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    iconsView.gravity = Gravity.END
    iconsView.layoutParams = LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.WRAP_CONTENT,
      LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      topMargin = dp(4f)
      gravity = Gravity.END
    }
    metaColumn.addView(iconsView)

    divider.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, 1).apply {
      gravity = Gravity.BOTTOM
    }
    divider.isClickable = false
    divider.isFocusable = false
    addView(divider)
  }

  fun bind(row: ChatNativeHomeListRow, isDark: Boolean, avatarBackgroundColor: Int?) {
    val primary = if (isDark) Color.WHITE else Color.rgb(22, 28, 36)
    val secondary = if (isDark) Color.rgb(190, 196, 207) else Color.rgb(114, 123, 138)
    val typing = if (isDark) Color.rgb(138, 202, 255) else Color.rgb(43, 135, 210)

    titleView.text = row.title
    titleView.setTextColor(primary)

    previewView.text = if (row.isTyping) "typing..." else row.preview
    previewView.setTextColor(if (row.isTyping) typing else secondary)

    timeView.text = row.timeLabel
    timeView.setTextColor(secondary)

    avatarFallbackIcon.setImageResource(
      if (row.isSavedMessages) R.drawable.ic_avatar_bookmark else R.drawable.ic_avatar_person,
    )
    avatarFallbackIcon.setColorFilter(if (isDark) Color.WHITE else Color.DKGRAY)
    avatarContainer.background = circleDrawable(
      avatarBackgroundColor ?: if (isDark) Color.argb(20, 248, 246, 252) else Color.argb(13, 26, 26, 31),
    )
    loadAvatar(row.avatarUri)

    onlineDot.visibility = if (row.isOnline) VISIBLE else GONE
    if (row.isOnline) {
      onlineDot.background = circleDrawable(Color.rgb(61, 208, 102), strokeColor = Color.WHITE, strokeWidthPx = dp(2f))
    }

    val showBadge = row.unreadCount > 0 || row.markedUnread
    badgeView.visibility = if (showBadge) VISIBLE else GONE
    badgeView.text = if (row.unreadCount > 0) row.unreadCount.toString() else ""
    badgeView.setTextColor(if (isDark) Color.BLACK else Color.WHITE)
    badgeView.background = circleDrawable(
      if (isDark) Color.rgb(157, 216, 255) else Color.rgb(23, 132, 209),
    )

    val icons = buildString {
      if (row.muted) append("🔇")
      if (row.muted && row.pinned) append(" ")
      if (row.pinned) append("📌")
    }
    iconsView.text = icons
    iconsView.visibility = if (icons.isNotEmpty()) VISIBLE else GONE
    iconsView.setTextColor(secondary)
    pressOverlay.setBackgroundColor(if (isDark) Color.argb(20, 255, 255, 255) else Color.argb(13, 0, 0, 0))
    divider.setBackgroundColor(if (isDark) Color.argb(15, 255, 255, 255) else Color.argb(8, 0, 0, 0))
    setPressedVisual(false)
  }

  private fun loadAvatar(avatarUri: String?) {
    val transportStatus = ChatEngine.getTransportStatus()
    val transportMode = (transportStatus["transportMode"] as? String) ?: "direct"
    val disableRemoteAvatars = (transportStatus["disableRemoteAvatars"] as? Boolean) ?: false
    if (transportMode == "bridge_text" || disableRemoteAvatars) {
      avatarLoadCall?.cancel()
      avatarLoadCall = null
      avatarImage.setImageDrawable(null)
      avatarImage.visibility = GONE
      avatarFallbackIcon.visibility = VISIBLE
      return
    }
    avatarLoadCall?.cancel()
    avatarLoadCall = null
    avatarLoadToken += 1
    val token = avatarLoadToken
    avatarImage.setImageDrawable(null)
    avatarImage.visibility = GONE
    avatarFallbackIcon.visibility = VISIBLE

    val uri = avatarUri?.trim().orEmpty()
    if (uri.isEmpty()) return
    if (!(uri.startsWith("https://", ignoreCase = true) || uri.startsWith("http://", ignoreCase = true))) {
      return
    }
    avatarBitmapCache.get(uri)?.let { cached ->
      avatarImage.setImageBitmap(cached)
      avatarImage.visibility = VISIBLE
      avatarFallbackIcon.visibility = GONE
      return
    }

    val request = Request.Builder()
      .url(uri)
      .get()
      .header("Accept", "image/*,*/*;q=0.8")
      .header("ngrok-skip-browser-warning", "true")
      .build()

    val call = avatarHttpClient.newCall(request)
    avatarLoadCall = call
    call.enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        // Keep fallback icon.
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          if (!res.isSuccessful) return
          val bytes = try {
            res.body?.bytes()
          } catch (_: Throwable) {
            null
          } ?: return
          val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return
          post {
            if (token != avatarLoadToken) return@post
            avatarBitmapCache.put(uri, bitmap)
            avatarImage.setImageBitmap(bitmap)
            avatarImage.visibility = VISIBLE
            avatarFallbackIcon.visibility = GONE
          }
        }
      }
    })
  }

  fun setPressedVisual(pressed: Boolean) {
    if (isPressedVisual == pressed) return
    isPressedVisual = pressed
    pressOverlay.animate().alpha(if (pressed) 1f else 0f).setDuration(120).start()
    animate().scaleX(if (pressed) 0.995f else 1f).scaleY(if (pressed) 0.995f else 1f).setDuration(120).start()
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    avatarLoadCall?.cancel()
    avatarLoadCall = null
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      resources.displayMetrics,
    ).toInt()

  private fun circleDrawable(fillColor: Int, strokeColor: Int = Color.TRANSPARENT, strokeWidthPx: Int = 0): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = 9999f
      setColor(fillColor)
      if (strokeWidthPx > 0) {
        setStroke(strokeWidthPx, strokeColor)
      }
    }
  }

  private object ViewFactory {
    fun dot(context: Context): FrameLayout {
      return FrameLayout(context)
    }
  }
}
