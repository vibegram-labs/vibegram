package expo.modules.vibechatnative

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.TextPaint
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

private data class ChatNativeHomeUndoBannerPayload(
  val title: String,
  val body: String,
  val actionLabel: String,
  val timerLabel: String,
  val destructive: Boolean,
) {
  companion object {
    fun parse(raw: Map<String, Any?>?): ChatNativeHomeUndoBannerPayload? {
      if (raw == null) return null
      val visible = raw["visible"] as? Boolean ?: true
      if (!visible) return null
      val title = raw["title"]?.toString()?.trim().orEmpty()
      val body = raw["body"]?.toString()?.trim().orEmpty()
      if (title.isEmpty() && body.isEmpty()) return null
      return ChatNativeHomeUndoBannerPayload(
        title = if (title.isEmpty()) "Pending action" else title,
        body = if (body.isEmpty()) "Tap undo to restore" else body,
        actionLabel = raw["actionLabel"]?.toString()?.trim().takeUnless { it.isNullOrEmpty() } ?: "Undo",
        timerLabel = raw["timerLabel"]?.toString()?.trim().orEmpty(),
        destructive = raw["destructive"] as? Boolean ?: true,
      )
    }
  }
}

private data class ChatNativeHomeSwipeSpec(
  val eventType: String,
  val title: String,
  val icon: String,
  val backgroundColor: Int,
  val isFullSwipeTarget: Boolean,
)

@SuppressLint("ViewConstructor")
class ChatNativeHomeListView(
  context: Context,
  appContext: AppContext,
) : ExpoView(context, appContext) {
  override val shouldUseAndroidLayout: Boolean = true

  private val onNativeEvent by EventDispatcher<Map<String, Any>>()
  private var isShowingNativePreview = false
  private var previewAppearance: Map<String, Any?> = emptyMap()
  private var contentTopInsetPx: Int = 0
  private var contentBottomInsetPx: Int = 0
  private val baseTopInsetPx: Int = dp(12f)
  private var rows: List<ChatNativeHomeListRow> = emptyList()
  private val engineListenerId = "native-home-list-${UUID.randomUUID()}"

  private val rootContainer = FrameLayout(context)
  private val swipeRefreshLayout = SwipeRefreshLayout(context)
  private val recyclerView = RecyclerView(context)
  private val undoBannerView = ChatNativeHomeUndoBannerView(context)
  private val adapter = HomeListAdapter(
    onPress = { row ->
      onNativeEvent(mapOf("type" to "press", "chatId" to row.chatId))
    },
    onLongPress = { row, sourceView ->
      sourceView.animate().scaleX(0.988f).scaleY(0.988f).setDuration(110).withEndAction {
        sourceView.animate().scaleX(1f).scaleY(1f).setDuration(110).start()
      }.start()
      showNativePreview(row)
      true
    },
  )

  private val swipeTilePaint = Paint(Paint.ANTI_ALIAS_FLAG)
  private val swipeIconPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    textAlign = Paint.Align.CENTER
    textSize = sp(18f)
    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
  }
  private val swipeLabelPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    textAlign = Paint.Align.CENTER
    textSize = sp(12f)
    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
  }

  private var isDark: Boolean = false
  private var currentUndoBanner: ChatNativeHomeUndoBannerPayload? = null
  private var swipeHapticPosition: Int = RecyclerView.NO_POSITION

  private val swipeHelper = ItemTouchHelper(object :
    ItemTouchHelper.SimpleCallback(0, ItemTouchHelper.LEFT or ItemTouchHelper.RIGHT) {
    override fun onMove(
      recyclerView: RecyclerView,
      viewHolder: RecyclerView.ViewHolder,
      target: RecyclerView.ViewHolder,
    ): Boolean = false

    override fun onSelectedChanged(viewHolder: RecyclerView.ViewHolder?, actionState: Int) {
      super.onSelectedChanged(viewHolder, actionState)
      if (actionState == ItemTouchHelper.ACTION_STATE_IDLE) {
        swipeHapticPosition = RecyclerView.NO_POSITION
      }
    }

    override fun clearView(recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder) {
      super.clearView(recyclerView, viewHolder)
      swipeHapticPosition = RecyclerView.NO_POSITION
    }

    override fun getSwipeThreshold(viewHolder: RecyclerView.ViewHolder): Float = 0.58f

    override fun getSwipeEscapeVelocity(defaultValue: Float): Float = defaultValue * 1.15f

    override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
      val position = viewHolder.bindingAdapterPosition
      if (position == RecyclerView.NO_POSITION) return
      val row = adapter.getRow(position)
      if (row == null) {
        adapter.notifyItemChanged(position)
        return
      }
      viewHolder.itemView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
      val eventType = if (direction == ItemTouchHelper.RIGHT) "swipePin" else "swipeDelete"
      onNativeEvent(mapOf("type" to eventType, "chatId" to row.chatId))
      adapter.notifyItemChanged(position)
      swipeHapticPosition = RecyclerView.NO_POSITION
    }

    override fun onChildDraw(
      c: Canvas,
      recyclerView: RecyclerView,
      viewHolder: RecyclerView.ViewHolder,
      dX: Float,
      dY: Float,
      actionState: Int,
      isCurrentlyActive: Boolean,
    ) {
      if (actionState != ItemTouchHelper.ACTION_STATE_SWIPE) {
        super.onChildDraw(c, recyclerView, viewHolder, dX, dY, actionState, isCurrentlyActive)
        return
      }

      val position = viewHolder.bindingAdapterPosition
      val row = adapter.getRow(position)
      if (position == RecyclerView.NO_POSITION || row == null) {
        super.onChildDraw(c, recyclerView, viewHolder, dX, dY, actionState, isCurrentlyActive)
        return
      }

      val itemView = viewHolder.itemView
      val clampedDx = clampSwipeDx(dX, itemView, row)
      maybeEmitSwipeHaptic(position, itemView, clampedDx, row)
      drawSwipeActions(c, itemView, clampedDx, row)
      super.onChildDraw(c, recyclerView, viewHolder, clampedDx, dY, actionState, isCurrentlyActive)
    }
  })

  init {
    clipChildren = true
    clipToPadding = true

    rootContainer.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    rootContainer.clipChildren = false
    rootContainer.clipToPadding = false
    addView(rootContainer)

    recyclerView.layoutManager = LinearLayoutManager(context)
    recyclerView.adapter = adapter
    recyclerView.overScrollMode = OVER_SCROLL_IF_CONTENT_SCROLLS
    recyclerView.setHasFixedSize(true)

    swipeRefreshLayout.setOnRefreshListener {
      onNativeEvent(mapOf("type" to "refresh"))
    }
    swipeRefreshLayout.addView(
      recyclerView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    rootContainer.addView(
      swipeRefreshLayout,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    undoBannerView.alpha = 0f
    undoBannerView.visibility = View.GONE
    undoBannerView.translationY = dp(18f).toFloat()
    undoBannerView.setOnClickListener {
      onNativeEvent(mapOf("type" to "undoPendingHomeAction"))
    }
    rootContainer.addView(
      undoBannerView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        dp(ChatNativeHomeUndoBannerView.PREFERRED_HEIGHT_DP),
      ).apply {
        gravity = Gravity.BOTTOM
        marginStart = dp(14f)
        marginEnd = dp(14f)
        bottomMargin = dp(14f)
      },
    )

    recyclerView.addOnScrollListener(object : RecyclerView.OnScrollListener() {
      override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
        super.onScrolled(recyclerView, dx, dy)
        onNativeEvent(
          mapOf(
            "type" to "scroll",
            "offsetY" to recyclerView.computeVerticalScrollOffset().toDouble(),
          ),
        )
      }
    })

    swipeHelper.attachToRecyclerView(recyclerView)
    applyContentInsets()
  }

  fun setRows(rawRows: List<Map<String, Any?>>) {
    rows = parseChatNativeHomeRows(rawRows, context)
    renderRowsWithNativePresence()
  }

  fun setRefreshing(refreshing: Boolean) {
    swipeRefreshLayout.isRefreshing = refreshing
  }

  fun setIsDark(value: Boolean) {
    if (isDark == value) return
    isDark = value
    adapter.setIsDark(value)
    updateUndoBanner(animated = false)
  }

  fun setPreviewAppearance(value: Map<String, Any?>) {
    previewAppearance = value
    adapter.setPreviewAppearance(value)
  }

  fun setContentTopInset(value: Double) {
    contentTopInsetPx = value.coerceAtLeast(0.0).toInt()
    applyContentInsets()
  }

  fun setContentBottomInset(value: Double) {
    contentBottomInsetPx = value.coerceAtLeast(0.0).toInt()
    applyContentInsets()
    updateUndoBannerLayout()
  }

  fun setUndoBanner(value: Map<String, Any?>?) {
    currentUndoBanner = ChatNativeHomeUndoBannerPayload.parse(value)
    updateUndoBanner(animated = true)
  }

  private fun applyContentInsets() {
    val topInset = contentTopInsetPx + baseTopInsetPx
    recyclerView.setPadding(
      recyclerView.paddingLeft,
      topInset,
      recyclerView.paddingRight,
      contentBottomInsetPx,
    )
    recyclerView.clipToPadding = false
  }

  private fun updateUndoBannerLayout() {
    val params = undoBannerView.layoutParams as? FrameLayout.LayoutParams ?: return
    params.bottomMargin = max(dp(14f), contentBottomInsetPx - dp(66f))
    undoBannerView.layoutParams = params
  }

  private fun updateUndoBanner(animated: Boolean) {
    val payload = currentUndoBanner
    val shouldShow = payload != null
    if (payload != null) {
      undoBannerView.bind(
        title = payload.title,
        body = payload.body,
        actionTitle = payload.actionLabel,
        timerText = payload.timerLabel,
        destructive = payload.destructive,
        isDark = isDark,
      )
      updateUndoBannerLayout()
    }
    if (shouldShow) {
      undoBannerView.visibility = View.VISIBLE
      undoBannerView.bringToFront()
    }
    if (animated) {
      undoBannerView.animate()
        .alpha(if (shouldShow) 1f else 0f)
        .translationY(if (shouldShow) 0f else dp(18f).toFloat())
        .setDuration(220)
        .withEndAction {
          if (!shouldShow) {
            undoBannerView.visibility = View.GONE
          }
        }
        .start()
    } else {
      undoBannerView.alpha = if (shouldShow) 1f else 0f
      undoBannerView.translationY = if (shouldShow) 0f else dp(18f).toFloat()
      undoBannerView.visibility = if (shouldShow) View.VISIBLE else View.GONE
    }
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      resources.displayMetrics,
    ).toInt()

  private fun sp(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_SP,
      value,
      resources.displayMetrics,
    )

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    registerChatEngineListener()
    renderRowsWithNativePresence()
  }

  override fun onDetachedFromWindow() {
    ChatEngine.setListener(engineListenerId, null)
    super.onDetachedFromWindow()
  }

  private fun registerChatEngineListener() {
    if (!isAttachedToWindow) {
      ChatEngine.setListener(engineListenerId, null)
      return
    }
    ChatEngine.setListener(engineListenerId) { reason, _, _ ->
      if (reason != "peerTyping" && reason != "presenceChanged") return@setListener
      post { renderRowsWithNativePresence() }
    }
  }

  private fun renderRowsWithNativePresence() {
    if (rows.isEmpty()) {
      adapter.submitRows(emptyList())
      return
    }
    adapter.submitRows(rows.map(::resolvedPresenceRow))
  }

  private fun resolvedPresenceRow(row: ChatNativeHomeListRow): ChatNativeHomeListRow {
    if (row.isSavedMessages) {
      return row.withPresence(isTyping = false, isOnline = false)
    }
    val peerUserId = row.peerUserId?.trim()
    if (peerUserId.isNullOrEmpty()) {
      return row.withPresence(isTyping = false, isOnline = false)
    }
    val isTyping = ChatEngine.isTyping(mapOf("chatId" to row.chatId))
    val isOnline = ChatEngine.isUserOnline(peerUserId)
    return row.withPresence(isTyping = isTyping, isOnline = isOnline)
  }

  private fun showNativePreview(row: ChatNativeHomeListRow) {
    if (isShowingNativePreview) return
    isShowingNativePreview = true

    val hasUnread = row.unreadCount > 0 || row.markedUnread
    val options = arrayOf(
      "Open",
      if (hasUnread) "Mark as Read" else "Mark as Unread",
      if (row.pinned) "Unpin" else "Pin",
      if (row.muted) "Unmute" else "Mute",
      "Archive",
      "Clear Chat",
      "Delete",
    )
    val previewText = if (row.isTyping) "typing..." else row.preview

    val builder = AlertDialog.Builder(context)
      .setTitle(row.title)
      .setItems(options) { dialog, index ->
        when (index) {
          0 -> onNativeEvent(mapOf("type" to "press", "chatId" to row.chatId))
          1 -> onNativeEvent(mapOf("type" to "swipeMarkRead", "chatId" to row.chatId))
          2 -> onNativeEvent(mapOf("type" to "swipePin", "chatId" to row.chatId))
          3 -> onNativeEvent(mapOf("type" to "swipeMute", "chatId" to row.chatId))
          4 -> onNativeEvent(mapOf("type" to "swipeArchive", "chatId" to row.chatId))
          5 -> onNativeEvent(mapOf("type" to "clearChat", "chatId" to row.chatId))
          6 -> onNativeEvent(mapOf("type" to "swipeDelete", "chatId" to row.chatId))
        }
        isShowingNativePreview = false
        dialog.dismiss()
      }
      .setNegativeButton("Cancel") { dialog, _ ->
        isShowingNativePreview = false
        dialog.dismiss()
      }
      .setOnDismissListener {
        isShowingNativePreview = false
      }

    if (previewText.isNotBlank()) {
      builder.setMessage(previewText)
    }

    try {
      builder.show()
    } catch (_: Throwable) {
      isShowingNativePreview = false
    }
  }

  private fun leadingSwipeSpecs(row: ChatNativeHomeListRow): List<ChatNativeHomeSwipeSpec> {
    val hasUnread = row.unreadCount > 0 || row.markedUnread
    return listOf(
      ChatNativeHomeSwipeSpec(
        eventType = "swipeMarkRead",
        title = if (hasUnread) "Read" else "Unread",
        icon = "\u2713",
        backgroundColor = Color.rgb(61, 143, 210),
        isFullSwipeTarget = false,
      ),
      ChatNativeHomeSwipeSpec(
        eventType = "swipePin",
        title = if (row.pinned) "Unpin" else "Pin",
        icon = "\uD83D\uDCCC",
        backgroundColor = Color.rgb(55, 119, 227),
        isFullSwipeTarget = true,
      ),
    )
  }

  private fun trailingSwipeSpecs(row: ChatNativeHomeListRow): List<ChatNativeHomeSwipeSpec> {
    return listOf(
      ChatNativeHomeSwipeSpec(
        eventType = "swipeMute",
        title = if (row.muted) "Unmute" else "Mute",
        icon = "\uD83D\uDD07",
        backgroundColor = Color.rgb(214, 133, 0),
        isFullSwipeTarget = false,
      ),
      ChatNativeHomeSwipeSpec(
        eventType = "swipeDelete",
        title = "Delete",
        icon = "\uD83D\uDDD1",
        backgroundColor = Color.rgb(223, 16, 16),
        isFullSwipeTarget = true,
      ),
      ChatNativeHomeSwipeSpec(
        eventType = "swipeArchive",
        title = "Archive",
        icon = "\uD83D\uDCE6",
        backgroundColor = Color.rgb(124, 124, 130),
        isFullSwipeTarget = false,
      ),
    )
  }

  private fun clampSwipeDx(dX: Float, itemView: View, row: ChatNativeHomeListRow): Float {
    return if (dX > 0f) {
      min(dX, max(leadingOpenWidthPx(row), itemView.width * 0.72f))
    } else if (dX < 0f) {
      max(dX, -max(trailingOpenWidthPx(row), itemView.width * 0.72f))
    } else {
      0f
    }
  }

  private fun maybeEmitSwipeHaptic(position: Int, itemView: View, dX: Float, row: ChatNativeHomeListRow) {
    val threshold = if (dX > 0f) {
      max(leadingOpenWidthPx(row) + dp(18f), itemView.width * 0.58f)
    } else {
      max(trailingOpenWidthPx(row) + dp(18f), itemView.width * 0.58f)
    }
    if (abs(dX) >= threshold && swipeHapticPosition != position) {
      itemView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
      swipeHapticPosition = position
    } else if (abs(dX) < threshold && swipeHapticPosition == position) {
      swipeHapticPosition = RecyclerView.NO_POSITION
    }
  }

  private fun drawSwipeActions(canvas: Canvas, itemView: View, dX: Float, row: ChatNativeHomeListRow) {
    if (dX > 0f) {
      drawLeadingSwipeActions(canvas, itemView, dX, row)
    } else if (dX < 0f) {
      drawTrailingSwipeActions(canvas, itemView, dX, row)
    }
  }

  private fun drawLeadingSwipeActions(canvas: Canvas, itemView: View, dX: Float, row: ChatNativeHomeListRow) {
    val specs = leadingSwipeSpecs(row)
    if (specs.isEmpty()) return

    val revealWidth = dX.coerceAtLeast(0f)
    val openWidth = leadingOpenWidthPx(row)
    val targetIndex = specs.indexOfFirst { it.isFullSwipeTarget }.takeIf { it >= 0 } ?: specs.lastIndex
    val extraWidth = max(0f, revealWidth - openWidth)

    canvas.save()
    canvas.clipRect(itemView.left.toFloat(), itemView.top.toFloat(), itemView.left + revealWidth, itemView.bottom.toFloat())
    var currentLeft = itemView.left.toFloat()
    specs.forEachIndexed { index, spec ->
      val tileWidth = leadingActionWidthPx() + if (index == targetIndex) extraWidth else 0f
      val rect = RectF(currentLeft, itemView.top.toFloat(), currentLeft + tileWidth, itemView.bottom.toFloat())
      val visibleWidth = (min(rect.right, itemView.left + revealWidth) - rect.left).coerceAtLeast(0f)
      drawSwipeTile(canvas, rect, visibleWidth, spec, leading = true)
      currentLeft += tileWidth
    }
    canvas.restore()
  }

  private fun drawTrailingSwipeActions(canvas: Canvas, itemView: View, dX: Float, row: ChatNativeHomeListRow) {
    val specs = trailingSwipeSpecs(row)
    if (specs.isEmpty()) return

    val revealWidth = abs(dX)
    val openWidth = trailingOpenWidthPx(row)
    val targetIndex = specs.indexOfFirst { it.isFullSwipeTarget }.takeIf { it >= 0 } ?: 0
    val extraWidth = max(0f, revealWidth - openWidth)
    val widths = specs.mapIndexed { index, _ ->
      trailingActionWidthPx() + if (index == targetIndex) extraWidth else 0f
    }

    canvas.save()
    canvas.clipRect(itemView.right - revealWidth, itemView.top.toFloat(), itemView.right.toFloat(), itemView.bottom.toFloat())
    var currentRight = itemView.right.toFloat()
    for (index in specs.indices.reversed()) {
      val tileWidth = widths[index]
      val rect = RectF(currentRight - tileWidth, itemView.top.toFloat(), currentRight, itemView.bottom.toFloat())
      val visibleWidth = (rect.right - max(rect.left, itemView.right - revealWidth)).coerceAtLeast(0f)
      drawSwipeTile(canvas, rect, visibleWidth, specs[index], leading = false)
      currentRight -= tileWidth
    }
    canvas.restore()
  }

  private fun drawSwipeTile(
    canvas: Canvas,
    rect: RectF,
    visibleWidth: Float,
    spec: ChatNativeHomeSwipeSpec,
    leading: Boolean,
  ) {
    swipeTilePaint.color = spec.backgroundColor
    canvas.drawRect(rect, swipeTilePaint)

    val revealProgress = clamp((visibleWidth - dp(20f)) / dp(34f))
    val titleProgress = clamp((visibleWidth - dp(40f)) / dp(18f))
    val direction = if (leading) -1f else 1f
    val iconCenterY = rect.centerY() - dp(12f) + ((1f - revealProgress) * dp(5f))
    val labelCenterY = rect.centerY() + dp(17f)

    swipeIconPaint.alpha = (72 + (183f * revealProgress)).toInt()
    swipeLabelPaint.alpha = (255f * titleProgress).toInt()

    drawCenteredText(canvas, spec.icon, rect.centerX(), iconCenterY, swipeIconPaint)
    drawCenteredText(
      canvas,
      spec.title,
      rect.centerX() + (direction * (1f - titleProgress) * dp(6f)),
      labelCenterY,
      swipeLabelPaint,
    )
  }

  private fun drawCenteredText(
    canvas: Canvas,
    text: String,
    centerX: Float,
    centerY: Float,
    paint: TextPaint,
  ) {
    val baseline = centerY - ((paint.descent() + paint.ascent()) * 0.5f)
    canvas.drawText(text, centerX, baseline, paint)
  }

  private fun leadingActionWidthPx(): Float = dp(72f).toFloat()

  private fun trailingActionWidthPx(): Float = dp(74f).toFloat()

  private fun leadingOpenWidthPx(row: ChatNativeHomeListRow): Float =
    leadingSwipeSpecs(row).size * leadingActionWidthPx()

  private fun trailingOpenWidthPx(row: ChatNativeHomeListRow): Float =
    trailingSwipeSpecs(row).size * trailingActionWidthPx()

  private fun clamp(value: Float): Float = value.coerceIn(0f, 1f)

  private class HomeListAdapter(
    private val onPress: (ChatNativeHomeListRow) -> Unit,
    private val onLongPress: (ChatNativeHomeListRow, View) -> Boolean,
  ) : RecyclerView.Adapter<HomeListAdapter.ViewHolder>() {
    private val rows = ArrayList<ChatNativeHomeListRow>()
    private var isDark: Boolean = false
    private var previewAppearance: Map<String, Any?> = emptyMap()

    fun submitRows(nextRows: List<ChatNativeHomeListRow>) {
      rows.clear()
      rows.addAll(nextRows)
      notifyDataSetChanged()
    }

    fun setIsDark(value: Boolean) {
      isDark = value
      notifyDataSetChanged()
    }

    fun setPreviewAppearance(value: Map<String, Any?>) {
      previewAppearance = value
      notifyDataSetChanged()
    }

    fun getRow(index: Int): ChatNativeHomeListRow? = rows.getOrNull(index)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
      return ViewHolder(ChatNativeHomeCardView(parent.context))
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
      val row = rows[position]
      holder.card.bind(row, isDark, resolveAvatarBackgroundColor())
      holder.itemView.setOnTouchListener { _, event ->
        when (event.actionMasked) {
          MotionEvent.ACTION_DOWN -> holder.card.setPressedVisual(true)
          MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> holder.card.setPressedVisual(false)
        }
        false
      }
      holder.itemView.setOnClickListener { onPress(row) }
      holder.itemView.setOnLongClickListener { onLongPress(row, holder.itemView) }
    }

    override fun onViewRecycled(holder: ViewHolder) {
      super.onViewRecycled(holder)
      holder.card.setPressedVisual(false)
      holder.itemView.setOnTouchListener(null)
      holder.itemView.setOnClickListener(null)
      holder.itemView.setOnLongClickListener(null)
      holder.itemView.translationX = 0f
    }

    override fun getItemCount(): Int = rows.size

    private fun resolveAvatarBackgroundColor(): Int? {
      val key = if (isDark) "avatarBackgroundColorDark" else "avatarBackgroundColorLight"
      val raw = previewAppearance[key] as? String ?: return null
      return try {
        Color.parseColor(raw.trim())
      } catch (_: IllegalArgumentException) {
        null
      }
    }

    class ViewHolder(val card: ChatNativeHomeCardView) : RecyclerView.ViewHolder(card)
  }
}
