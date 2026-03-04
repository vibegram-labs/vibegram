package expo.modules.vibechatnative

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import android.util.TypedValue
import java.util.UUID

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

  private val swipeRefreshLayout = SwipeRefreshLayout(context)
  private val recyclerView = RecyclerView(context)
  private val adapter = HomeListAdapter(
    onPress = { row ->
      onNativeEvent(mapOf("type" to "press", "chatId" to row.chatId))
    },
    onLongPress = { row, sourceView ->
      sourceView.animate().scaleX(0.985f).scaleY(0.985f).setDuration(110).withEndAction {
        sourceView.animate().scaleX(1f).scaleY(1f).setDuration(110).start()
      }.start()
      showNativePreview(row)
      true
    },
  )

  private var isDark: Boolean = false

  init {
    clipChildren = true
    clipToPadding = true

    recyclerView.layoutManager = LinearLayoutManager(context)
    recyclerView.adapter = adapter
    recyclerView.overScrollMode = OVER_SCROLL_IF_CONTENT_SCROLLS
    recyclerView.setHasFixedSize(true)

    swipeRefreshLayout.setOnRefreshListener {
      onNativeEvent(mapOf("type" to "refresh"))
    }
    swipeRefreshLayout.addView(
      recyclerView,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )
    addView(
      swipeRefreshLayout,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
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

    ItemTouchHelper(object : ItemTouchHelper.SimpleCallback(0, ItemTouchHelper.LEFT or ItemTouchHelper.RIGHT) {
      override fun onMove(
        recyclerView: RecyclerView,
        viewHolder: RecyclerView.ViewHolder,
        target: RecyclerView.ViewHolder,
      ): Boolean = false

      override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
        val position = viewHolder.bindingAdapterPosition
        if (position == RecyclerView.NO_POSITION) return
        val row = adapter.getRow(position)
        if (row == null) {
          adapter.notifyItemChanged(position)
          return
        }
        if (direction == ItemTouchHelper.RIGHT) {
          onNativeEvent(mapOf("type" to "swipePin", "chatId" to row.chatId))
        } else {
          onNativeEvent(mapOf("type" to "swipeMute", "chatId" to row.chatId))
        }
        adapter.notifyItemChanged(position)
      }
    }).attachToRecyclerView(recyclerView)
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

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      resources.displayMetrics,
    ).toInt()

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
      // Group/channel rows should not show single-user typing/online.
      return row.withPresence(isTyping = false, isOnline = false)
    }
    val isTyping = ChatEngine.isTyping(mapOf("chatId" to row.chatId))
    val isOnline = ChatEngine.isUserOnline(peerUserId)
    return row.withPresence(isTyping = isTyping, isOnline = isOnline)
  }

  private fun showNativePreview(row: ChatNativeHomeListRow) {
    if (isShowingNativePreview) return
    isShowingNativePreview = true

    val options = arrayOf(
      "Open",
      if (row.pinned) "Unpin" else "Pin",
      if (row.muted) "Unmute" else "Mute",
    )
    val previewText = if (row.isTyping) "typing..." else row.preview

    val builder = AlertDialog.Builder(context)
      .setTitle(row.title)
      .setItems(options) { dialog, index ->
        when (index) {
          0 -> onNativeEvent(mapOf("type" to "press", "chatId" to row.chatId))
          1 -> onNativeEvent(mapOf("type" to "swipePin", "chatId" to row.chatId))
          2 -> onNativeEvent(mapOf("type" to "swipeMute", "chatId" to row.chatId))
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
