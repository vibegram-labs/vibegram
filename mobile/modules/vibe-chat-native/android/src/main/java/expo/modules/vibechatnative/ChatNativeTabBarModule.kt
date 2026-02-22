package expo.modules.vibechatnative

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import kotlin.math.max

private data class AndroidNativeTabItem(
  val key: String,
  val title: String,
  val sfSymbol: String? = null,
  val iconUri: String? = null,
  val badge: String? = null,
  val isVibe: Boolean = false,
)

@SuppressLint("ViewConstructor")
class ChatNativeTabsView(
  context: Context,
  appContext: AppContext,
) : ExpoView(context, appContext) {
  private val onIndexChange by EventDispatcher<Map<String, Any>>()

  private val rootRow = LinearLayout(context)
  private val mainPill = LinearLayout(context)
  private val vibeHost = FrameLayout(context)

  private var tabs: List<AndroidNativeTabItem> = emptyList()
  private var currentIndex: Int = 0
  private var activeTintColor: Int? = null
  private var inactiveTintColor: Int? = null
  private var isDark: Boolean = false

  init {
    orientation = VERTICAL
    clipChildren = false
    clipToPadding = false

    rootRow.orientation = LinearLayout.HORIZONTAL
    rootRow.gravity = Gravity.CENTER_VERTICAL
    rootRow.clipChildren = false
    rootRow.clipToPadding = false

    mainPill.orientation = LinearLayout.HORIZONTAL
    mainPill.gravity = Gravity.CENTER_VERTICAL
    mainPill.clipChildren = false
    mainPill.clipToPadding = false
    mainPill.setPadding(dp(6), dp(5), dp(6), dp(5))

    vibeHost.clipChildren = false
    vibeHost.clipToPadding = false

    rootRow.addView(
      mainPill,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply {
        marginEnd = dp(8)
      },
    )
    rootRow.addView(
      vibeHost,
      LinearLayout.LayoutParams(dp(64), dp(64)),
    )

    addView(
      rootRow,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
        setMargins(dp(14), dp(2), dp(14), dp(10))
      },
    )

    applyChrome()
    rebuildTabs()
  }

  fun setTabs(rawTabs: List<Map<String, Any?>>) {
    tabs = rawTabs.mapNotNull { payload ->
      val key = payload["key"] as? String ?: return@mapNotNull null
      val title = (payload["title"] as? String)?.takeIf { it.isNotBlank() } ?: key
      AndroidNativeTabItem(
        key = key,
        title = title,
        sfSymbol = payload["sfSymbol"] as? String,
        iconUri = payload["iconUri"] as? String,
        badge = (payload["badge"] as? String)?.takeIf { it.isNotBlank() },
        isVibe = (payload["isVibe"] as? Boolean) == true,
      )
    }
    rebuildTabs()
  }

  fun setCurrentIndex(index: Int) {
    currentIndex = index
    rebuildTabs()
  }

  fun setActiveTintColor(color: Int?) {
    activeTintColor = color
    rebuildTabs()
  }

  fun setInactiveTintColor(color: Int?) {
    inactiveTintColor = color
    rebuildTabs()
  }

  fun setIsDark(value: Boolean) {
    isDark = value
    applyChrome()
    rebuildTabs()
  }

  private fun applyChrome() {
    mainPill.background = roundedDrawable(
      radiusDp = 32f,
      fill = if (isDark) Color.argb(220, 18, 22, 30) else Color.argb(235, 247, 250, 255),
      strokeWidthDp = 1f,
      stroke = if (isDark) Color.argb(26, 255, 255, 255) else Color.argb(20, 17, 24, 39),
    )
  }

  private fun rebuildTabs() {
    mainPill.removeAllViews()
    vibeHost.removeAllViews()

    if (tabs.isEmpty()) {
      vibeHost.visibility = GONE
      return
    }

    val vibeIndex = tabs.indexOfFirst { it.isVibe }
    val mainTabs = if (vibeIndex >= 0) tabs.filterIndexed { index, _ -> index != vibeIndex } else tabs
    val selectedMainIndex = when {
      vibeIndex >= 0 && currentIndex > vibeIndex -> currentIndex - 1
      else -> currentIndex
    }

    mainTabs.forEachIndexed { localIndex, tab ->
      val actualIndex = if (vibeIndex >= 0 && localIndex >= vibeIndex) localIndex + 1 else localIndex
      mainPill.addView(
        createTabButton(
          tab = tab,
          isSelected = selectedMainIndex == localIndex && currentIndex != vibeIndex,
          onClickIndex = actualIndex,
        ),
        LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f),
      )
    }

    if (vibeIndex >= 0) {
      vibeHost.visibility = VISIBLE
      val vibeTab = tabs[vibeIndex]
      vibeHost.addView(
        createVibeButton(vibeTab, currentIndex == vibeIndex, vibeIndex),
        FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
      )
    } else {
      vibeHost.visibility = GONE
    }
  }

  private fun createTabButton(
    tab: AndroidNativeTabItem,
    isSelected: Boolean,
    onClickIndex: Int,
  ): FrameLayout {
    val container = FrameLayout(context).apply {
      isClickable = true
      isFocusable = true
      foregroundGravity = Gravity.CENTER
      setOnClickListener {
        onIndexChange(mapOf("index" to onClickIndex))
      }
      setPadding(dp(2), dp(2), dp(2), dp(2))
    }

    val inner = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      clipToPadding = false
      clipChildren = false
      setPadding(dp(6), dp(4), dp(6), dp(4))
      background = roundedDrawable(
        radiusDp = 27f,
        fill = if (isSelected) {
          if (isDark) Color.argb(34, 255, 255, 255) else Color.argb(230, 255, 255, 255)
        } else {
          Color.TRANSPARENT
        },
        strokeWidthDp = if (isSelected) 1f else 0f,
        stroke = if (isDark) Color.argb(24, 255, 255, 255) else Color.argb(16, 255, 255, 255),
      )
    }

    val iconColor = if (isSelected) {
      activeTintColor ?: if (isDark) Color.rgb(245, 248, 255) else Color.rgb(18, 24, 38)
    } else {
      inactiveTintColor ?: if (isDark) Color.rgb(142, 142, 147) else Color.rgb(113, 118, 130)
    }

    val iconHolder = FrameLayout(context).apply {
      layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
    }
    val iconView = ImageView(context).apply {
      layoutParams = FrameLayout.LayoutParams(dp(22), dp(22), Gravity.CENTER)
      scaleType = ImageView.ScaleType.CENTER_INSIDE
      setColorFilter(iconColor)
    }
    val fallbackGlyph = TextView(context).apply {
      layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
      setTextColor(iconColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      typeface = Typeface.DEFAULT_BOLD
      text = resolveGlyph(tab)
    }
    val iconLoaded = applyIconUri(iconView, tab.iconUri)
    if (iconLoaded) {
      iconHolder.addView(iconView)
    } else {
      iconHolder.addView(fallbackGlyph)
    }

    val labelView = TextView(context).apply {
      setTextColor(iconColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
      typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
      text = tab.title
      maxLines = 1
      ellipsize = TextUtils.TruncateAt.END
      includeFontPadding = false
      gravity = Gravity.CENTER
      layoutParams = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(2)
      }
    }

    inner.addView(iconHolder)
    inner.addView(labelView)

    tab.badge?.let { badgeValue ->
      val badgeView = TextView(context).apply {
        text = badgeValue
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
        typeface = Typeface.DEFAULT_BOLD
        gravity = Gravity.CENTER
        minWidth = dp(18)
        setPadding(dp(5), dp(1), dp(5), dp(1))
        background = roundedDrawable(
          radiusDp = 10f,
          fill = Color.rgb(239, 68, 68),
          strokeWidthDp = 1f,
          stroke = if (isDark) Color.argb(242, 24, 28, 36) else Color.WHITE,
        )
      }
      val badgeParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.TOP or Gravity.END,
      ).apply {
        topMargin = -dp(1)
        marginEnd = -dp(2)
      }
      iconHolder.addView(badgeView, badgeParams)
    }

    container.addView(
      inner,
      FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
    )
    return container
  }

  private fun createVibeButton(tab: AndroidNativeTabItem, isSelected: Boolean, onClickIndex: Int): FrameLayout {
    val container = FrameLayout(context).apply {
      isClickable = true
      isFocusable = true
      setOnClickListener {
        onIndexChange(mapOf("index" to onClickIndex))
      }
      background = roundedDrawable(
        radiusDp = 32f,
        fill = if (isDark) Color.argb(236, 20, 24, 32) else Color.argb(242, 248, 251, 255),
        strokeWidthDp = 1f,
        stroke = if (isDark) Color.argb(30, 255, 255, 255) else Color.argb(22, 22, 30, 46),
      )
      alpha = if (isSelected) 1f else 0.98f
    }

    val iconColor = if (isSelected) {
      activeTintColor ?: if (isDark) Color.WHITE else Color.rgb(18, 24, 38)
    } else {
      if (isDark) Color.rgb(246, 248, 255) else Color.rgb(18, 24, 38)
    }

    val iconView = TextView(context).apply {
      gravity = Gravity.CENTER
      setTextColor(iconColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
      typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
      includeFontPadding = false
      text = resolveGlyph(tab, fallback = "V")
    }

    container.addView(
      iconView,
      FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER),
    )
    return container
  }

  private fun resolveGlyph(tab: AndroidNativeTabItem, fallback: String? = null): String {
    val titleGlyph = tab.title.trim().firstOrNull()?.uppercaseChar()?.toString()
    val symbolGlyph = tab.sfSymbol?.trim()?.firstOrNull()?.uppercaseChar()?.toString()
    return fallback ?: titleGlyph ?: symbolGlyph ?: "•"
  }

  private fun applyIconUri(imageView: ImageView, iconUri: String?): Boolean {
    if (iconUri.isNullOrBlank()) return false
    return try {
      imageView.setImageURI(Uri.parse(iconUri))
      imageView.drawable != null
    } catch (_: Throwable) {
      false
    }
  }

  private fun roundedDrawable(
    radiusDp: Float,
    fill: Int,
    strokeWidthDp: Float = 0f,
    stroke: Int = Color.TRANSPARENT,
  ): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = dpF(radiusDp)
      setColor(fill)
      if (strokeWidthDp > 0f) {
        setStroke(max(1, dp(strokeWidthDp)), stroke)
      }
    }
  }

  private fun dp(value: Float): Int = dpF(value).toInt()
  private fun dp(value: Int): Int = dp(value.toFloat())
  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics)
}

class ChatNativeTabBarModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ChatNativeTabs")

    View(ChatNativeTabsView::class) {
      Events("onIndexChange")

      Prop("tabs") { view: ChatNativeTabsView, tabs: List<Map<String, Any?>> ->
        view.setTabs(tabs)
      }

      Prop("currentIndex") { view: ChatNativeTabsView, index: Int ->
        view.setCurrentIndex(index)
      }

      Prop("activeTintColor") { view: ChatNativeTabsView, color: Int? ->
        view.setActiveTintColor(color)
      }

      Prop("inactiveTintColor") { view: ChatNativeTabsView, color: Int? ->
        view.setInactiveTintColor(color)
      }

      Prop("isDark") { view: ChatNativeTabsView, isDark: Boolean ->
        view.setIsDark(isDark)
      }
    }
  }
}
