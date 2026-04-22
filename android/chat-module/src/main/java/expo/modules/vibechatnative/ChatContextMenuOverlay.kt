package expo.modules.vibechatnative

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.content.ContextWrapper
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.TextView
import android.os.SystemClock
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

internal class ChatContextMenuOverlay(
  private val context: android.content.Context,
) {
  companion object {
    private const val TAG = "ChatContextMenuOverlay"
    private const val HOLD_SCALE = 0.965f
    private const val HOLD_PULSE_MS = 180L
    private const val INTERACTION_GUARD_MS = 260L
  }

  internal data class Config(
    val appearance: ChatListAppearance,
    val isMe: Boolean,
    val actions: List<Pair<String, String>>,
  )

  private data class Layout(
    val bubbleRect: android.graphics.RectF,
    val reactionRect: android.graphics.RectF,
    val actionsRect: android.graphics.RectF,
  )

  private data class ActiveOverlay(
    val popup: PopupWindow,
    val backdrop: View,
    val bubbleSnapshot: View,
    val reactionCard: View,
    val actionsCard: View,
    val holdView: View,
    val hiddenViews: List<View>,
    val anchorStartRect: android.graphics.RectF,
    val bubbleRect: android.graphics.RectF,
    var closing: Boolean = false,
  )

  private var active: ActiveOverlay? = null
  private var showToken: Int = 0

  fun show(
    anchor: View,
    config: Config,
    animateHold: Boolean,
    holdView: View = anchor,
    tailView: View? = null,
    onReaction: (emoji: String, sourceX: Double, sourceY: Double) -> Unit,
    onAction: (actionId: String) -> Unit,
  ) {
    Log.d(
      TAG,
      "show animateHold=$animateHold anchor=${anchor.width}x${anchor.height} hold=${holdView.width}x${holdView.height} attached=${anchor.isAttachedToWindow}",
    )
    dismiss(animated = false)
    restoreHoldView(holdView)
    val token = ++showToken

    fun openIfLatest() {
      if (token != showToken) return
      openOverlay(
        anchor = anchor,
        config = config,
        animateHold = animateHold,
        holdView = holdView,
        tailView = tailView,
        onReaction = onReaction,
        onAction = onAction,
      )
    }

    if (!animateHold) {
      openIfLatest()
      return
    }

    // Match iOS long-press pulse timing:
    // 1) brief hold scale on live row, 2) restore to identity, 3) snapshot/open overlay.
    holdView.animate().cancel()
    holdView.animate()
      .scaleX(HOLD_SCALE)
      .scaleY(HOLD_SCALE)
      .setDuration(HOLD_PULSE_MS)
      .setInterpolator(PathInterpolator(0.16f, 1f, 0.3f, 1f))
      .withEndAction {
        holdView.scaleX = 1f
        holdView.scaleY = 1f
        openIfLatest()
      }
      .start()
  }

  fun dismiss(animated: Boolean = true) {
    val current = active ?: return
    if (current.closing) return
    Log.d(TAG, "dismiss animated=$animated")

    if (!animated) {
      current.popup.dismiss()
      return
    }

    current.closing = true
    val targetScale = HOLD_SCALE
    val returnTx = current.anchorStartRect.left - current.bubbleRect.left - ((1f - targetScale) * current.bubbleRect.width()) / 2f
    val returnTy = current.anchorStartRect.top - current.bubbleRect.top - ((1f - targetScale) * current.bubbleRect.height()) / 2f

    current.backdrop.animate()
      .alpha(0f)
      .setDuration(160L)
      .start()

    current.reactionCard.animate()
      .alpha(0f)
      .translationY(dpF(10f))
      .scaleX(0.96f)
      .scaleY(0.96f)
      .setDuration(170L)
      .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
      .start()

    current.actionsCard.animate()
      .alpha(0f)
      .translationY(dpF(14f))
      .scaleX(0.96f)
      .scaleY(0.96f)
      .setDuration(180L)
      .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
      .start()

    current.bubbleSnapshot.animate()
      .translationX(returnTx)
      .translationY(returnTy)
      .scaleX(0.965f)
      .scaleY(0.965f)
      .setDuration(190L)
      .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
      .withEndAction { current.popup.dismiss() }
      .start()
  }

  private fun openOverlay(
    anchor: View,
    config: Config,
    animateHold: Boolean,
    holdView: View,
    tailView: View?,
    onReaction: (emoji: String, sourceX: Double, sourceY: Double) -> Unit,
    onAction: (actionId: String) -> Unit,
  ) {
    if (!anchor.isAttachedToWindow || anchor.width <= 0 || anchor.height <= 0) {
      Log.w(TAG, "openOverlay skipped invalidAnchor attached=${anchor.isAttachedToWindow} size=${anchor.width}x${anchor.height}")
      restoreHoldView(holdView)
      return
    }

    val rootView = resolveOverlayRoot(anchor) ?: run {
      Log.w(TAG, "openOverlay skipped missingRootView")
      restoreHoldView(holdView)
      return
    }
    val rootWidth = rootView.width.toFloat()
    val rootHeight = rootView.height.toFloat()
    if (rootWidth <= 1f || rootHeight <= 1f) {
      Log.w(TAG, "openOverlay skipped invalidRootSize root=${rootWidth}x${rootHeight}")
      restoreHoldView(holdView)
      return
    }

    val anchorRect = viewRectInRoot(view = anchor, rootView = rootView) ?: run {
      Log.w(TAG, "openOverlay skipped missingAnchorRect")
      restoreHoldView(holdView)
      return
    }
    val captureRect = android.graphics.RectF(anchorRect)
    if (tailView != null && tailView.visibility == View.VISIBLE && tailView.width > 0 && tailView.height > 0) {
      viewRectInRoot(view = tailView, rootView = rootView)?.let { tailRect ->
        captureRect.union(tailRect)
      }
    }

    var controlsEnabledAtMs = 0L

    val bubbleSnapshot = buildBubbleSnapshot(
      captureHost = holdView,
      captureRectInRoot = captureRect,
      rootView = rootView,
    ) ?: run {
      Log.w(TAG, "openOverlay skipped bubbleSnapshotFailed")
      restoreHoldView(holdView)
      return
    }

    val isLightTheme = luminance(config.appearance.bubbleThemColor) > 0.45f
    val cardFill = if (isLightTheme) Color.argb(242, 248, 251, 255) else Color.argb(244, 18, 22, 29)
    val cardStroke = if (isLightTheme) Color.argb(56, 18, 28, 40) else Color.argb(44, 255, 255, 255)
    val textColor = if (isLightTheme) Color.argb(236, 22, 28, 36) else Color.argb(236, 255, 255, 255)
    val secondaryText = if (isLightTheme) Color.argb(188, 44, 52, 63) else Color.argb(188, 236, 242, 255)
    val dividerColor = if (isLightTheme) Color.argb(26, 20, 30, 42) else Color.argb(30, 255, 255, 255)
    val scrimColor = if (isLightTheme) Color.argb(70, 8, 12, 20) else Color.argb(98, 0, 0, 0)

    fun makeCard(cornerDp: Float): FrameLayout {
      return FrameLayout(context).apply {
        clipChildren = false
        clipToPadding = false
        elevation = dpF(10f)
        background = GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadius = dpF(cornerDp)
          setColor(cardFill)
          setStroke(max(1, dp(1)), cardStroke)
        }
      }
    }

    val overlayRoot = FrameLayout(context).apply {
      layoutParams = ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      )
      isClickable = true
      isFocusable = true
      isFocusableInTouchMode = true
      clipChildren = false
      clipToPadding = false
      setBackgroundColor(Color.TRANSPARENT)
    }

    val backdrop = View(context).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
      setBackgroundColor(scrimColor)
      alpha = 0f
    }
    overlayRoot.addView(backdrop)

    val reactionCard = makeCard(20f)
    val reactionContent = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(10), dp(6), dp(10), dp(6))
    }
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

    val reactions = listOf("👍", "👎", "❤️", "🔥", "🎉", "💩")
    for ((index, emoji) in reactions.withIndex()) {
      val chip = TextView(context).apply {
        text = emoji
        gravity = Gravity.CENTER
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
        setPadding(0, 0, 0, 0)
        background = null
        setOnClickListener { view ->
          if (SystemClock.uptimeMillis() < controlsEnabledAtMs) return@setOnClickListener
          val loc = IntArray(2)
          view.getLocationInWindow(loc)
          val sourceX = loc[0] + (view.width * 0.5f)
          val sourceY = loc[1] + (view.height * 0.5f)
          onReaction(emoji, sourceX.toDouble(), sourceY.toDouble())
          dismiss(animated = true)
        }
      }
      reactionRow.addView(
        chip,
        LinearLayout.LayoutParams(
          dp(44),
          dp(44),
        ).apply {
          if (index > 0) marginStart = dp(4)
        },
      )
    }

    val actionsCard = makeCard(20f)
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
    for ((index, pair) in config.actions.withIndex()) {
      val actionId = pair.first
      val label = pair.second
      if (index > 0) {
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
      val row = TextView(context).apply {
        text = label
        gravity = Gravity.CENTER_VERTICAL
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        setTextColor(
          if (actionId == "delete") {
            if (isLightTheme) Color.argb(255, 217, 59, 59) else Color.argb(255, 255, 123, 123)
          } else {
            textColor
          },
        )
        setPadding(dp(12), dp(12), dp(12), dp(12))
        background = GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadius = dpF(14f)
          setColor(Color.TRANSPARENT)
        }
        setOnClickListener {
          if (SystemClock.uptimeMillis() < controlsEnabledAtMs) return@setOnClickListener
          onAction(actionId)
          dismiss(animated = true)
        }
      }
      actionsContent.addView(
        row,
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

    reactionCard.measure(
      View.MeasureSpec.makeMeasureSpec((rootWidth - dpF(24f)).roundToInt(), View.MeasureSpec.AT_MOST),
      View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
    )
    val menuWidth = min(dp(236), (rootWidth - dpF(28f)).roundToInt().coerceAtLeast(dp(180)))
    actionsCard.measure(
      View.MeasureSpec.makeMeasureSpec(menuWidth, View.MeasureSpec.EXACTLY),
      View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
    )

    val layout = computeLayout(
      overlayWidth = rootWidth,
      overlayHeight = rootHeight,
      // Keep geometry anchored to the full bubble snapshot (bubble + tail),
      // same as iOS. This avoids extra drift from body/tail offset reconciliation.
      anchorRect = captureRect,
      reactionWidth = reactionCard.measuredWidth.toFloat(),
      reactionHeight = reactionCard.measuredHeight.toFloat(),
      actionsWidth = actionsCard.measuredWidth.toFloat(),
      actionsHeight = actionsCard.measuredHeight.toFloat(),
      isMe = config.isMe,
    )
    val bubbleSnapshotRect = android.graphics.RectF(layout.bubbleRect)
    Log.d(
      TAG,
      "layout anchor=$anchorRect capture=$captureRect bubble=${layout.bubbleRect} snapshot=$bubbleSnapshotRect reaction=${layout.reactionRect} actions=${layout.actionsRect} isMe=${config.isMe}",
    )

    setFrame(bubbleSnapshot, bubbleSnapshotRect)
    setFrame(reactionCard, layout.reactionRect)
    setFrame(actionsCard, layout.actionsRect)

    val startScale = if (animateHold) HOLD_SCALE else 1f
    // Compensate for center-based scaling so the visual content aligns with the
    // capture rect. When a view is scaled about its center the visible content
    // shifts by (1 - scale) * size / 2 — subtract that offset from the start
    // translation to keep the animation stable.
    val startTx = captureRect.left - bubbleSnapshotRect.left - ((1f - startScale) * bubbleSnapshotRect.width()) / 2f
    val startTy = captureRect.top - bubbleSnapshotRect.top - ((1f - startScale) * bubbleSnapshotRect.height()) / 2f
    // Use the computed snapshot rect for pivot so scaling occurs about center.
    bubbleSnapshot.pivotX = bubbleSnapshotRect.width() / 2f
    bubbleSnapshot.pivotY = bubbleSnapshotRect.height() / 2f
    bubbleSnapshot.translationX = startTx
    bubbleSnapshot.translationY = startTy
    bubbleSnapshot.scaleX = startScale
    bubbleSnapshot.scaleY = startScale
    bubbleSnapshot.alpha = 1f
    bubbleSnapshot.elevation = dpF(16f)

    reactionCard.alpha = 0f
    reactionCard.translationY = dpF(8f)
    reactionCard.scaleX = 0.96f
    reactionCard.scaleY = 0.96f

    actionsCard.alpha = 0f
    actionsCard.translationY = dpF(12f)
    actionsCard.scaleX = 0.96f
    actionsCard.scaleY = 0.96f

    overlayRoot.addView(bubbleSnapshot)
    overlayRoot.addView(reactionCard)
    overlayRoot.addView(actionsCard)

    val popup = PopupWindow(
      overlayRoot,
      ViewGroup.LayoutParams.MATCH_PARENT,
      ViewGroup.LayoutParams.MATCH_PARENT,
      true,
    ).apply {
      isOutsideTouchable = false
      isClippingEnabled = false
      setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
      elevation = dpF(18f)
      setOnDismissListener {
        val current = active
        if (current?.popup !== this) return@setOnDismissListener
        restoreHiddenViews(current.hiddenViews)
        restoreHoldView(current.holdView)
        active = null
      }
    }

    val hiddenViews = LinkedHashSet<View>().apply {
      // Hide the same host used for snapshot capture to prevent live/snapshot
      // mismatch flicker while the context overlay animates in.
      add(holdView)
      if (anchor !== holdView) add(anchor)
      if (tailView != null && tailView !== anchor && tailView !== holdView) add(tailView)
    }

    active = ActiveOverlay(
      popup = popup,
      backdrop = backdrop,
      bubbleSnapshot = bubbleSnapshot,
      reactionCard = reactionCard,
      actionsCard = actionsCard,
      holdView = holdView,
      hiddenViews = hiddenViews.toList(),
      anchorStartRect = captureRect,
      bubbleRect = bubbleSnapshotRect,
    )

    overlayRoot.setOnTouchListener { _, event ->
      if (event.actionMasked != MotionEvent.ACTION_UP) return@setOnTouchListener false
      if (SystemClock.uptimeMillis() < controlsEnabledAtMs) return@setOnTouchListener true
      val x = event.x
      val y = event.y
      if (containsPoint(bubbleSnapshot, x, y)) return@setOnTouchListener false
      if (containsPoint(reactionCard, x, y)) return@setOnTouchListener false
      if (containsPoint(actionsCard, x, y)) return@setOnTouchListener false
      dismiss(animated = true)
      true
    }
    overlayRoot.setOnKeyListener { _, keyCode, event ->
      if (keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
        dismiss(animated = true)
        true
      } else {
        false
      }
    }

    for (hiddenView in hiddenViews) {
      hiddenView.alpha = 0f
    }
    try {
      popup.showAtLocation(rootView, Gravity.NO_GRAVITY, 0, 0)
    } catch (error: Throwable) {
      Log.e(TAG, "openOverlay showAtLocation failed", error)
      restoreHiddenViews(hiddenViews.toList())
      restoreHoldView(holdView)
      active = null
      return
    }
    controlsEnabledAtMs = SystemClock.uptimeMillis() + INTERACTION_GUARD_MS

    overlayRoot.post {
      overlayRoot.requestFocus()
      backdrop.animate()
        .alpha(1f)
        .setDuration(180L)
        .setInterpolator(PathInterpolator(0.22f, 0f, 0f, 1f))
        .start()
      bubbleSnapshot.animate()
        .translationX(0f)
        .translationY(0f)
        .scaleX(1f)
        .scaleY(1f)
        .setDuration(230L)
        .setInterpolator(PathInterpolator(0.16f, 1f, 0.3f, 1f))
        .start()
      reactionCard.animate()
        .alpha(1f)
        .translationY(0f)
        .scaleX(1f)
        .scaleY(1f)
        .setDuration(220L)
        .setInterpolator(PathInterpolator(0.16f, 1f, 0.3f, 1f))
        .start()
      actionsCard.animate()
        .alpha(1f)
        .translationY(0f)
        .scaleX(1f)
        .scaleY(1f)
        .setStartDelay(16L)
        .setDuration(230L)
        .setInterpolator(PathInterpolator(0.16f, 1f, 0.3f, 1f))
        .start()
    }
  }

  private fun buildBubbleSnapshot(
    captureHost: View,
    captureRectInRoot: android.graphics.RectF,
    rootView: View,
  ): View? {
    if (captureHost.width <= 0 || captureHost.height <= 0) return null
    val hostRectInRoot = viewRectInRoot(view = captureHost, rootView = rootView) ?: return null
    val localLeft = floor(captureRectInRoot.left - hostRectInRoot.left).toInt()
    val localTop = floor(captureRectInRoot.top - hostRectInRoot.top).toInt()
    val localRight = ceil(captureRectInRoot.right - hostRectInRoot.left).toInt()
    val localBottom = ceil(captureRectInRoot.bottom - hostRectInRoot.top).toInt()

    val clippedLeft = max(0, min(captureHost.width, localLeft))
    val clippedTop = max(0, min(captureHost.height, localTop))
    val clippedRight = max(clippedLeft, min(captureHost.width, localRight))
    val clippedBottom = max(clippedTop, min(captureHost.height, localBottom))
    val snapshotWidth = clippedRight - clippedLeft
    val snapshotHeight = clippedBottom - clippedTop
    if (snapshotWidth <= 1 || snapshotHeight <= 1) return null

    val bitmap =
      try {
        Bitmap.createBitmap(snapshotWidth, snapshotHeight, Bitmap.Config.ARGB_8888)
      } catch (_: Throwable) {
        null
      } ?: return null
    val canvas = Canvas(bitmap)
    canvas.translate(-clippedLeft.toFloat(), -clippedTop.toFloat())
    captureHost.draw(canvas)
    return ImageView(context).apply {
      // Preserve original glyph/bubble proportions from the captured bitmap.
      scaleType = ImageView.ScaleType.CENTER
      setImageBitmap(bitmap)
    }
  }

  private fun resolveOverlayRoot(anchor: View): View? {
    fun rootFromContext(source: android.content.Context?): View? {
      var current = source
      while (current is ContextWrapper) {
        if (current is android.app.Activity) {
          return current.window?.decorView?.rootView
        }
        val next = current.baseContext
        if (next === current) break
        current = next
      }
      return null
    }

    rootFromContext(anchor.context)?.let { return it }
    rootFromContext(context)?.let { return it }
    return anchor.rootView
  }

  private fun computeLayout(
    overlayWidth: Float,
    overlayHeight: Float,
    anchorRect: android.graphics.RectF,
    reactionWidth: Float,
    reactionHeight: Float,
    actionsWidth: Float,
    actionsHeight: Float,
    isMe: Boolean,
  ): Layout {
    val safeMargin = dpF(14f)
    val safeLeft = safeMargin
    val safeRight = overlayWidth - safeMargin
    val safeTop = safeMargin + dpF(2f)
    val safeBottom = overlayHeight - safeMargin - dpF(4f)
    val pickerGap = dpF(8f)
    val menuGap = dpF(4f)
    val isRightAligned = isMe || anchorRect.centerX() > (overlayWidth * 0.5f)

    val bubbleLeft = anchorRect.left.coerceIn(
      safeLeft,
      (safeRight - anchorRect.width()).coerceAtLeast(safeLeft),
    )
    var bubbleTop = anchorRect.top
    var pickerTop = bubbleTop - reactionHeight - pickerGap
    var menuTop = bubbleTop + anchorRect.height() + menuGap

    val menuBottom = menuTop + actionsHeight
    if (menuBottom > safeBottom) {
      val shiftUp = menuBottom - safeBottom
      bubbleTop -= shiftUp
      pickerTop -= shiftUp
      menuTop -= shiftUp
    }

    if (pickerTop < safeTop) {
      val desiredShiftDown = safeTop - pickerTop
      val availableDown = max(0f, safeBottom - (menuTop + actionsHeight))
      val shiftDown = min(desiredShiftDown, availableDown)
      bubbleTop += shiftDown
      pickerTop += shiftDown
      menuTop += shiftDown
    }

    pickerTop = pickerTop.coerceIn(safeTop, (safeBottom - reactionHeight).coerceAtLeast(safeTop))
    menuTop = menuTop.coerceIn(safeTop, (safeBottom - actionsHeight).coerceAtLeast(safeTop))
    bubbleTop = bubbleTop.coerceIn(
      safeTop,
      (safeBottom - anchorRect.height()).coerceAtLeast(safeTop),
    )

    val bubbleRect = android.graphics.RectF(
      bubbleLeft,
      bubbleTop,
      bubbleLeft + anchorRect.width(),
      bubbleTop + anchorRect.height(),
    )

    val reactionXTarget = if (isRightAligned) bubbleRect.right - reactionWidth else bubbleRect.left
    val reactionX = reactionXTarget.coerceIn(
      safeLeft,
      (safeRight - reactionWidth).coerceAtLeast(safeLeft),
    )
    val reactionRect = android.graphics.RectF(
      reactionX,
      pickerTop,
      reactionX + reactionWidth,
      pickerTop + reactionHeight,
    )

    val actionsXTarget = if (isRightAligned) bubbleRect.right - actionsWidth else bubbleRect.left
    val actionsX = actionsXTarget.coerceIn(
      safeLeft,
      (safeRight - actionsWidth).coerceAtLeast(safeLeft),
    )
    val actionsRect = android.graphics.RectF(
      actionsX,
      menuTop,
      actionsX + actionsWidth,
      menuTop + actionsHeight,
    )

    return Layout(
      bubbleRect = bubbleRect,
      reactionRect = reactionRect,
      actionsRect = actionsRect,
    )
  }

  private fun setFrame(view: View, rect: android.graphics.RectF) {
    val width = max(1, rect.width().roundToInt())
    val height = max(1, rect.height().roundToInt())
    view.layoutParams = FrameLayout.LayoutParams(width, height).apply {
      leftMargin = rect.left.roundToInt()
      topMargin = rect.top.roundToInt()
    }
  }

  private fun containsPoint(view: View, x: Float, y: Float): Boolean {
    val left = view.x
    val top = view.y
    val right = left + view.width
    val bottom = top + view.height
    return x >= left && x <= right && y >= top && y <= bottom
  }

  private fun viewRectInRoot(view: View, rootView: View): android.graphics.RectF? {
    if (!view.isAttachedToWindow || view.width <= 0 || view.height <= 0) return null
    val rootGlobal = android.graphics.Rect()
    val viewGlobal = android.graphics.Rect()
    if (!rootView.getGlobalVisibleRect(rootGlobal)) return null
    if (!view.getGlobalVisibleRect(viewGlobal)) return null
    if (viewGlobal.width() <= 0 || viewGlobal.height() <= 0) return null
    return android.graphics.RectF(
      (viewGlobal.left - rootGlobal.left).toFloat(),
      (viewGlobal.top - rootGlobal.top).toFloat(),
      (viewGlobal.right - rootGlobal.left).toFloat(),
      (viewGlobal.bottom - rootGlobal.top).toFloat(),
    )
  }

  private fun restoreHiddenViews(hiddenViews: List<View>) {
    for (view in hiddenViews) {
      view.alpha = 1f
    }
  }

  private fun restoreHoldView(holdView: View) {
    holdView.animate().cancel()
    holdView.scaleX = 1f
    holdView.scaleY = 1f
    holdView.translationX = 0f
    holdView.translationY = 0f
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

  private fun luminance(color: Int): Float {
    fun channel(v: Int): Float {
      val s = (v / 255f)
      return if (s <= 0.03928f) s / 12.92f else ((s + 0.055f) / 1.055f).pow(2.4f)
    }
    return 0.2126f * channel(Color.red(color)) +
      0.7152f * channel(Color.green(color)) +
      0.0722f * channel(Color.blue(color))
  }
}
