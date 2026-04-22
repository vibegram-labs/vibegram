package expo.modules.vibechatnative

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PorterDuff
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import java.net.URL
import java.util.concurrent.ConcurrentHashMap

internal enum class ChatMainProfileTab {
  MEDIA,
  MUSIC,
  FILES,
  LINKS,
  PINNED,
}

internal class ChatMainProfileTabNode(
  context: Context,
) : FrameLayout(context) {
  private val titleLabel = TextView(context)
  private val pressedOverlay = FrameLayout(context)

  private var normalTextColor: Int = Color.LTGRAY
  private var activeTextColor: Int = Color.WHITE
  private var activeBackgroundColor: Int = Color.argb(31, 255, 255, 255)

  var isActive: Boolean = false
    set(value) {
      field = value
      applyState()
    }

  init {
    clipChildren = true
    clipToPadding = true
    background = roundedShape(Color.TRANSPARENT, dp(18))

    titleLabel.setTypeface(Typeface.DEFAULT, Typeface.NORMAL)
    titleLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    titleLabel.gravity = Gravity.CENTER
    addView(
      titleLabel,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

    pressedOverlay.alpha = 0f
    addView(
      pressedOverlay,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )
  }

  fun setTitle(title: String) {
    titleLabel.text = title
  }

  fun applyTheme(activeTextColor: Int, normalTextColor: Int, activeBackgroundColor: Int) {
    this.activeTextColor = activeTextColor
    this.normalTextColor = normalTextColor
    this.activeBackgroundColor = activeBackgroundColor
    applyState()
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        scaleX = 0.97f
        scaleY = 0.97f
        pressedOverlay.alpha = 1f
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_OUTSIDE -> {
        scaleX = 1f
        scaleY = 1f
        pressedOverlay.alpha = 0f
      }
    }
    return super.onTouchEvent(event)
  }

  private fun applyState() {
    setBackgroundColor(if (isActive) activeBackgroundColor else Color.TRANSPARENT)
    titleLabel.setTextColor(if (isActive) activeTextColor else normalTextColor)
    pressedOverlay.setBackgroundColor(withAlpha(activeTextColor, 0.08f))
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).toInt().coerceIn(0, 255)
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun roundedShape(color: Int, radiusPx: Int) = GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = radiusPx.toFloat()
    setColor(color)
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).toInt()
  }
}

internal class ChatMainProfileListRowNode(
  context: Context,
) : FrameLayout(context) {
  private val contentRow = LinearLayout(context)
  private val iconContainer = FrameLayout(context)
  private val iconView = ImageView(context)
  private val textStack = LinearLayout(context)
  private val titleLabel = TextView(context)
  private val subtitleLabel = TextView(context)
  private val trailingRow = LinearLayout(context)
  private val valueLabel = TextView(context)
  private val chevronView = ImageView(context)
  private val separatorView = FrameLayout(context)
  private val pressedOverlay = FrameLayout(context)

  private var defaultTitleColor: Int = Color.WHITE
  private var subtitleColor: Int = Color.LTGRAY
  private var valueColor: Int = Color.LTGRAY
  private var separatorColor: Int = Color.argb(26, 255, 255, 255)
  private var highlightedColor: Int = Color.argb(10, 255, 255, 255)
  private var iconTintColor: Int = Color.WHITE
  private var iconBackgroundColor: Int = Color.argb(16, 255, 255, 255)
  private var titleColorOverride: Int? = null

  init {
    minimumHeight = dp(62)

    contentRow.orientation = LinearLayout.HORIZONTAL
    contentRow.gravity = Gravity.CENTER_VERTICAL
    contentRow.setPadding(dp(18), dp(12), dp(18), dp(12))
    addView(
      contentRow,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT),
    )

    iconContainer.background = roundedShape(iconBackgroundColor, dp(14))
    contentRow.addView(
      iconContainer,
      LinearLayout.LayoutParams(dp(36), dp(36)),
    )

    iconView.scaleType = ImageView.ScaleType.CENTER_INSIDE
    iconContainer.addView(
      iconView,
      LayoutParams(dp(18), dp(18), Gravity.CENTER),
    )

    textStack.orientation = LinearLayout.VERTICAL
    contentRow.addView(
      textStack,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
        marginStart = dp(12)
      },
    )

    titleLabel.setTypeface(Typeface.DEFAULT, Typeface.NORMAL)
    titleLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    titleLabel.maxLines = 1
    textStack.addView(
      titleLabel,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    subtitleLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    subtitleLabel.setPadding(0, dp(2), 0, 0)
    textStack.addView(
      subtitleLabel,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    trailingRow.orientation = LinearLayout.HORIZONTAL
    trailingRow.gravity = Gravity.CENTER_VERTICAL
    contentRow.addView(
      trailingRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    valueLabel.setTypeface(Typeface.DEFAULT, Typeface.NORMAL)
    valueLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
    trailingRow.addView(
      valueLabel,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    chevronView.scaleType = ImageView.ScaleType.CENTER_INSIDE
    chevronView.setImageResource(R.drawable.ic_chevron_right_small)
    trailingRow.addView(
      chevronView,
      LinearLayout.LayoutParams(dp(14), dp(14)).apply {
        marginStart = dp(8)
      },
    )

    addView(separatorView)

    pressedOverlay.alpha = 0f
    addView(
      pressedOverlay,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )
  }

  fun configure(
    title: String,
    subtitle: String = "",
    value: String = "",
    iconRes: Int = 0,
    titleColor: Int? = null,
    showsSeparator: Boolean,
    showsChevron: Boolean = true,
  ) {
    titleLabel.text = title
    val resolvedSubtitle = subtitle.trim()
    subtitleLabel.text = resolvedSubtitle
    subtitleLabel.visibility = if (resolvedSubtitle.isEmpty()) GONE else VISIBLE
    valueLabel.text = value
    valueLabel.visibility = if (value.isBlank()) GONE else VISIBLE
    if (iconRes != 0) {
      iconView.setImageResource(iconRes)
      iconContainer.visibility = VISIBLE
    } else {
      iconContainer.visibility = GONE
    }
    chevronView.visibility = if (showsChevron) VISIBLE else GONE
    titleColorOverride = titleColor
    separatorView.visibility = if (showsSeparator) VISIBLE else GONE
    titleLabel.setTextColor(titleColor ?: defaultTitleColor)
    subtitleLabel.setTextColor(subtitleColor)
    valueLabel.setTextColor(valueColor)
  }

  fun applyTheme(
    titleColor: Int,
    subtitleColor: Int,
    valueColor: Int,
    separatorColor: Int,
    highlightedColor: Int,
    iconTintColor: Int,
    iconBackgroundColor: Int,
  ) {
    defaultTitleColor = titleColor
    this.subtitleColor = subtitleColor
    this.valueColor = valueColor
    this.separatorColor = separatorColor
    this.highlightedColor = highlightedColor
    this.iconTintColor = iconTintColor
    this.iconBackgroundColor = iconBackgroundColor
    titleLabel.setTextColor(titleColorOverride ?: titleColor)
    subtitleLabel.setTextColor(subtitleColor)
    valueLabel.setTextColor(valueColor)
    iconView.setColorFilter(iconTintColor, PorterDuff.Mode.SRC_IN)
    chevronView.setColorFilter(valueColor, PorterDuff.Mode.SRC_IN)
    iconContainer.background = roundedShape(iconBackgroundColor, dp(14))
    separatorView.setBackgroundColor(separatorColor)
    pressedOverlay.setBackgroundColor(highlightedColor)
  }

  override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
    super.onLayout(changed, left, top, right, bottom)
    val height = bottom - top
    val lineHeight = 1
    separatorView.layout(dp(18), height - lineHeight, right - left - dp(18), height)
    pressedOverlay.layout(0, 0, right - left, height)
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> pressedOverlay.alpha = 1f
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_OUTSIDE -> pressedOverlay.alpha = 0f
    }
    return super.onTouchEvent(event)
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).toInt()
  }

  private fun roundedShape(color: Int, radiusPx: Int) = GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = radiusPx.toFloat()
    setColor(color)
  }
}

internal class ChatMainProfileMediaCellNode(
  context: Context,
) : FrameLayout(context) {
  companion object {
    private val imageCache = ConcurrentHashMap<String, android.graphics.Bitmap>()
  }

  private val imageView = ImageView(context)
  private val placeholderIcon = ImageView(context)
  private val videoBadge = TextView(context)
  private var imageURLString: String? = null

  init {
    clipChildren = true
    clipToPadding = true
    background = roundedShape(Color.TRANSPARENT, dp(3))

    imageView.scaleType = ImageView.ScaleType.CENTER_CROP
    imageView.visibility = GONE
    addView(
      imageView,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )

    placeholderIcon.scaleType = ImageView.ScaleType.CENTER_INSIDE
    placeholderIcon.setImageResource(android.R.drawable.ic_menu_gallery)
    addView(
      placeholderIcon,
      LayoutParams(dp(28), dp(28), Gravity.CENTER),
    )

    videoBadge.text = "VIDEO"
    videoBadge.setTypeface(Typeface.DEFAULT_BOLD)
    videoBadge.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
    videoBadge.setTextColor(Color.WHITE)
    videoBadge.setPadding(dp(6), dp(2), dp(6), dp(2))
    videoBadge.background = roundedShape(Color.argb(148, 0, 0, 0), dp(7))
    videoBadge.visibility = GONE
    addView(
      videoBadge,
      LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.END or Gravity.BOTTOM).apply {
        marginEnd = dp(6)
        bottomMargin = dp(6)
      },
    )
  }

  fun configure(urlString: String?, isVideo: Boolean) {
    videoBadge.visibility = if (isVideo) VISIBLE else GONE
    imageView.setImageDrawable(null)
    imageView.visibility = GONE
    placeholderIcon.visibility = VISIBLE
    imageURLString = null

    val resolvedUrl = urlString?.trim().takeIf { !it.isNullOrEmpty() } ?: return
    imageURLString = resolvedUrl

    imageCache[resolvedUrl]?.let { cached ->
      imageView.setImageBitmap(cached)
      imageView.visibility = VISIBLE
      placeholderIcon.visibility = GONE
      return
    }

    val parsed = try {
      Uri.parse(resolvedUrl)
    } catch (_: Throwable) {
      null
    } ?: return

    if ("file".equals(parsed.scheme, ignoreCase = true)) {
      val bmp = BitmapFactory.decodeFile(parsed.path)
      if (bmp != null) {
        imageCache[resolvedUrl] = bmp
        imageView.setImageBitmap(bmp)
        imageView.visibility = VISIBLE
        placeholderIcon.visibility = GONE
      }
      return
    }

    Thread {
      try {
        val bmp = URL(resolvedUrl).openStream().use { BitmapFactory.decodeStream(it) } ?: return@Thread
        imageCache[resolvedUrl] = bmp
        post {
          if (imageURLString != resolvedUrl) return@post
          imageView.setImageBitmap(bmp)
          imageView.visibility = VISIBLE
          placeholderIcon.visibility = GONE
        }
      } catch (_: Throwable) {
      }
    }.start()
  }

  fun applyTheme(placeholderTintColor: Int, placeholderBackgroundColor: Int) {
    setBackgroundColor(placeholderBackgroundColor)
    placeholderIcon.setColorFilter(placeholderTintColor, PorterDuff.Mode.SRC_IN)
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        scaleX = 0.98f
        scaleY = 0.98f
        alpha = 0.86f
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_OUTSIDE -> {
        scaleX = 1f
        scaleY = 1f
        alpha = 1f
      }
    }
    return super.onTouchEvent(event)
  }

  private fun roundedShape(color: Int, radiusPx: Int) = GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = radiusPx.toFloat()
    setColor(color)
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).toInt()
  }
}

internal interface ChatMainProfileAgentPromptNodeDelegate {
  fun agentPromptNodeDidUpdateConfig(node: ChatMainProfileAgentPromptNode, config: Map<String, Any?>)
  fun agentPromptNodeDidRequestDelete(node: ChatMainProfileAgentPromptNode)
  fun agentPromptNodeDidRequestFullEditor(node: ChatMainProfileAgentPromptNode)
}

internal class ChatMainProfileAgentPromptNode(
  context: Context,
) : FrameLayout(context) {
  var delegate: ChatMainProfileAgentPromptNodeDelegate? = null

  private val titleView = TextView(context)
  private val subtitleView = TextView(context)
  private var currentConfig: Map<String, Any?>? = null

  init {
    background = roundedShape(Color.argb(18, 255, 255, 255), dp(22))
    setPadding(dp(16), dp(14), dp(16), dp(14))

    val stack = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
    }
    addView(
      stack,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT),
    )

    titleView.text = "AI Agent"
    titleView.setTypeface(Typeface.DEFAULT_BOLD)
    titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    stack.addView(
      titleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    subtitleView.text = "Single native model backend"
    subtitleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    subtitleView.setPadding(0, dp(4), 0, 0)
    stack.addView(
      subtitleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
  }

  fun configure(chatId: String, config: Map<String, Any?>?) {
    currentConfig = config
    val mode = config?.get("mode")?.toString()?.trim()
    subtitleView.text = if (mode.isNullOrEmpty()) "Single native model backend" else "Mode: $mode"
  }

  fun preferredHeight(forWidth: Float): Float {
    val base = dp(110).toFloat()
    return if (forWidth < dp(300)) base + dp(12) else base
  }

  fun applyTheme(textColor: Int, secondaryTextColor: Int, surfaceColor: Int, accentColor: Int) {
    titleView.setTextColor(textColor)
    subtitleView.setTextColor(secondaryTextColor)
    background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(22))
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).toInt().coerceIn(0, 255)
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun roundedShape(color: Int, radiusPx: Int) = GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = radiusPx.toFloat()
    setColor(color)
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).toInt()
  }
}
