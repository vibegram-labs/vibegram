package com.mohammadshayani.vibe.ui

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import com.google.android.material.button.MaterialButton
import com.mohammadshayani.vibe.home.ChatHomeListRow
import com.mohammadshayani.vibe.packet.PacketBootstrapService
import com.mohammadshayani.vibe.packet.PacketRuntime
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.session.AppSessionConfig
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.text.DateFormat
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

class ConversationActivity : AppCompatActivity() {
  companion object {
    private const val extraChatId = "chat_id"
    private const val extraTitle = "title"
    private const val extraPeerUserId = "peer_user_id"
    private const val extraIsSavedMessages = "is_saved_messages"

    internal fun intent(context: Context, row: ChatHomeListRow): Intent {
      return Intent(context, ConversationActivity::class.java).apply {
        putExtra(extraChatId, row.chatId)
        putExtra(extraTitle, row.title)
        putExtra(extraPeerUserId, row.peerUserId)
        putExtra(extraIsSavedMessages, row.isSavedMessages)
      }
    }

    fun savedMessagesIntent(context: Context): Intent {
      return Intent(context, ConversationActivity::class.java).apply {
        putExtra(extraChatId, "saved_messages")
        putExtra(extraTitle, "Saved Messages")
        putExtra(extraIsSavedMessages, true)
      }
    }
  }

  private val adapter = ConversationAdapter()

  private lateinit var swipeRefreshLayout: SwipeRefreshLayout
  private lateinit var recyclerView: RecyclerView
  private lateinit var progressView: ProgressBar
  private lateinit var emptyStateView: LinearLayout
  private lateinit var emptyTitleView: TextView
  private lateinit var emptyMessageView: TextView
  private lateinit var titleView: TextView
  private lateinit var subtitleView: TextView
  private lateinit var avatarView: FrameLayout
  private lateinit var avatarIconView: ImageView

  private var themeSignature = ""
  private var isLoading = false
  private var errorMessage: String? = null
  private var messages: List<ConversationMessage> = emptyList()

  private val chatId: String
    get() = intent.getStringExtra(extraChatId).orEmpty()

  private val chatTitle: String
    get() = intent.getStringExtra(extraTitle).orEmpty().ifBlank { "Chat" }

  private val peerUserId: String?
    get() = intent.getStringExtra(extraPeerUserId)?.trim()?.takeIf { it.isNotEmpty() }

  private val isSavedMessages: Boolean
    get() = intent.getBooleanExtra(extraIsSavedMessages, false)

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)

    if (AppSessionConfig.current(applicationContext) == null) {
      startActivity(Intent(this, WelcomeActivity::class.java))
      finish()
      return
    }

    themeSignature = appThemeSignature(this)
    buildViewHierarchy()
    loadMessages()
  }

  override fun onResume() {
    super.onResume()
    val nextSignature = appThemeSignature(this)
    if (nextSignature != themeSignature) {
      recreate()
    }
  }

  private fun buildViewHierarchy() {
    val palette = resolveAppThemePalette(this)
    applyThemedSystemBars(this, palette)
    adapter.setPalette(palette)

    val root = FrameLayout(this).apply {
      setBackgroundColor(palette.backgroundColor)
    }

    val content = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
    }
    root.addView(
      content,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    val header = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      setPadding(dp(12f), dp(10f), dp(16f), dp(10f))
      background =
        GradientDrawable().apply {
          setColor(adjustColor(palette.backgroundColor, if (palette.isDark) 0.04f else -0.01f))
        }
    }
    content.addView(
      header,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    header.addView(
      ImageView(this).apply {
        setImageResource(android.R.drawable.ic_media_previous)
        setColorFilter(palette.textColor)
        background = selectableItemBackground()
        setPadding(dp(10f), dp(10f), dp(10f), dp(10f))
        setOnClickListener { finish() }
      },
      LinearLayout.LayoutParams(dp(40f), dp(40f)),
    )

    avatarView = FrameLayout(this).apply {
      background =
        GradientDrawable(
          GradientDrawable.Orientation.TL_BR,
          intArrayOf(
            if (isSavedMessages) palette.warningColor else palette.accentColor,
            adjustColor(if (isSavedMessages) palette.warningColor else palette.accentColor, -0.16f),
          ),
        ).apply {
          shape = GradientDrawable.OVAL
        }
    }
    avatarIconView = ImageView(this).apply {
      setImageResource(if (isSavedMessages) android.R.drawable.ic_menu_save else android.R.drawable.ic_menu_myplaces)
      setColorFilter(Color.WHITE)
      scaleType = ImageView.ScaleType.CENTER_INSIDE
    }
    avatarView.addView(
      avatarIconView,
      FrameLayout.LayoutParams(dp(20f), dp(20f), Gravity.CENTER),
    )
    header.addView(
      avatarView,
      LinearLayout.LayoutParams(dp(40f), dp(40f)).apply {
        marginStart = dp(8f)
      },
    )

    val textColumn = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
    }
    header.addView(
      textColumn,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
        marginStart = dp(12f)
      },
    )

    titleView =
      TextView(this).apply {
        text = chatTitle
        setTextColor(palette.textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      }
    subtitleView =
      TextView(this).apply {
        text = if (isSavedMessages) "Private notes" else (peerUserId ?: "Messages")
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      }
    textColumn.addView(titleView)
    textColumn.addView(subtitleView)

    swipeRefreshLayout = SwipeRefreshLayout(this).apply {
      setOnRefreshListener { loadMessages() }
      setColorSchemeColors(palette.accentColor)
    }
    content.addView(
      swipeRefreshLayout,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )

    val bodyHost = FrameLayout(this)
    swipeRefreshLayout.addView(
      bodyHost,
      ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      ),
    )

    recyclerView = RecyclerView(this).apply {
      layoutManager = LinearLayoutManager(this@ConversationActivity)
      adapter = this@ConversationActivity.adapter
      clipToPadding = false
      setPadding(dp(14f), dp(18f), dp(14f), dp(18f))
    }
    bodyHost.addView(
      recyclerView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    progressView = ProgressBar(this).apply {
      visibility = View.GONE
      indeterminateDrawable?.setTint(palette.accentColor)
    }
    bodyHost.addView(
      progressView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER,
      ),
    )

    emptyStateView = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      visibility = View.GONE
      setPadding(dp(28f), dp(28f), dp(28f), dp(28f))
    }
    bodyHost.addView(
      emptyStateView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
        Gravity.CENTER,
      ),
    )
    emptyStateView.addView(
      ImageView(this).apply {
        setImageResource(if (isSavedMessages) android.R.drawable.ic_menu_save else android.R.drawable.ic_dialog_email)
        setColorFilter(palette.tertiaryTextColor)
      },
      LinearLayout.LayoutParams(dp(42f), dp(42f)),
    )
    emptyStateView.addView(space(12f))
    emptyTitleView =
      TextView(this).apply {
        setTextColor(palette.textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
      }
    emptyStateView.addView(emptyTitleView)
    emptyStateView.addView(space(8f))
    emptyMessageView =
      TextView(this).apply {
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        gravity = Gravity.CENTER
      }
    emptyStateView.addView(emptyMessageView)
    emptyStateView.addView(space(14f))
    emptyStateView.addView(
      MaterialButton(this).apply {
        text = "Refresh"
        isAllCaps = false
        setTextColor(palette.buttonTextColor)
        backgroundTintList = android.content.res.ColorStateList.valueOf(palette.buttonColor)
        cornerRadius = dp(24f)
        setOnClickListener { loadMessages() }
      },
    )

    ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
      header.setPadding(dp(12f), bars.top + dp(10f), dp(16f), dp(10f))
      recyclerView.setPadding(dp(14f), dp(18f), dp(14f), bars.bottom + dp(18f))
      emptyStateView.setPadding(dp(28f), dp(28f), dp(28f), bars.bottom + dp(28f))
      insets
    }

    setContentView(root)
    renderState()
  }

  private fun loadMessages() {
    isLoading = true
    errorMessage = null
    renderState()
    ConversationService.fetchMessages(
      context = applicationContext,
      chatId = chatId,
      isSavedMessages = isSavedMessages,
    ) { result ->
      swipeRefreshLayout.isRefreshing = false
      isLoading = false
      result.onSuccess { next ->
        messages = next
      }.onFailure { error ->
        messages = emptyList()
        errorMessage = error.localizedMessage ?: error.message ?: "Failed to load messages."
      }
      renderState()
      if (messages.isNotEmpty()) {
        recyclerView.scrollToPosition(messages.lastIndex)
      }
    }
  }

  private fun renderState() {
    adapter.submit(messages)
    progressView.visibility = if (isLoading && messages.isEmpty()) View.VISIBLE else View.GONE
    recyclerView.visibility = if (messages.isEmpty()) View.INVISIBLE else View.VISIBLE
    emptyStateView.visibility = if (!isLoading && messages.isEmpty()) View.VISIBLE else View.GONE
    emptyTitleView.text = if (errorMessage != null) "Unable to load chat" else if (isSavedMessages) "No saved messages" else "No messages yet"
    emptyMessageView.text =
      errorMessage
        ?: if (isSavedMessages) {
          "Saved notes and forwarded items will appear here."
        } else {
          "Pull to refresh once the conversation has activity."
        }
  }

  private fun selectableItemBackground() =
    obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).let { typedArray ->
      val drawable = getDrawable(typedArray.getResourceId(0, 0))
      typedArray.recycle()
      drawable
    }

  private fun space(valueDp: Float): View {
    return View(this).apply {
      layoutParams = LinearLayout.LayoutParams(1, dp(valueDp))
    }
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
}

private data class ConversationMessage(
  val id: String,
  val body: String,
  val timestampMs: Long,
  val timeLabel: String,
  val isOutgoing: Boolean,
)

private class ConversationAdapter : RecyclerView.Adapter<ConversationMessageViewHolder>() {
  private var palette = AppThemePalette(
    isDark = true,
    backgroundColor = Color.BLACK,
    secondaryBackgroundColor = Color.BLACK,
    cardColor = Color.BLACK,
    inputColor = Color.BLACK,
    elevatedColor = Color.BLACK,
    textColor = Color.WHITE,
    secondaryTextColor = Color.LTGRAY,
    tertiaryTextColor = Color.GRAY,
    accentColor = Color.CYAN,
    accentMutedColor = Color.CYAN,
    buttonColor = Color.CYAN,
    buttonTextColor = Color.WHITE,
    bubbleMeColor = Color.CYAN,
    bubbleThemColor = Color.DKGRAY,
    borderColor = Color.TRANSPARENT,
    dividerColor = Color.TRANSPARENT,
    overlayColor = Color.TRANSPARENT,
    successColor = Color.GREEN,
    warningColor = Color.YELLOW,
    dangerColor = Color.RED,
  )
  private val rows = ArrayList<ConversationMessage>()

  fun setPalette(value: AppThemePalette) {
    palette = value
    notifyDataSetChanged()
  }

  fun submit(nextRows: List<ConversationMessage>) {
    rows.clear()
    rows.addAll(nextRows)
    notifyDataSetChanged()
  }

  override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ConversationMessageViewHolder {
    return ConversationMessageViewHolder(parent.context)
  }

  override fun onBindViewHolder(holder: ConversationMessageViewHolder, position: Int) {
    holder.bind(rows[position], palette)
  }

  override fun getItemCount(): Int = rows.size
}

private class ConversationMessageViewHolder(
  context: Context,
) : RecyclerView.ViewHolder(FrameLayout(context)) {
  private val root = itemView as FrameLayout
  private val bubble = LinearLayout(context)
  private val bodyView = TextView(context)
  private val timeView = TextView(context)

  init {
    root.layoutParams = RecyclerView.LayoutParams(
      RecyclerView.LayoutParams.MATCH_PARENT,
      RecyclerView.LayoutParams.WRAP_CONTENT,
    ).apply {
      topMargin = dp(context, 4f)
      bottomMargin = dp(context, 4f)
    }

    bubble.orientation = LinearLayout.VERTICAL
    bubble.setPadding(dp(context, 14f), dp(context, 10f), dp(context, 14f), dp(context, 10f))

    bodyView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
    bodyView.setLineSpacing(0f, 1.08f)
    bodyView.maxWidth = dp(context, 280f)

    timeView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    timeView.gravity = Gravity.END

    bubble.addView(
      bodyView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    bubble.addView(
      timeView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(context, 6f)
        gravity = Gravity.END
      },
    )

    root.addView(
      bubble,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.START,
      ),
    )
  }

  fun bind(row: ConversationMessage, palette: AppThemePalette) {
    (bubble.layoutParams as FrameLayout.LayoutParams).gravity =
      if (row.isOutgoing) Gravity.END else Gravity.START
    bodyView.text = row.body
    timeView.text = row.timeLabel
    bubble.background =
      GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dp(root.context, 19f).toFloat()
        setColor(if (row.isOutgoing) palette.bubbleMeColor else palette.bubbleThemColor)
      }
    bodyView.setTextColor(if (row.isOutgoing) palette.buttonTextColor else palette.textColor)
    timeView.setTextColor(
      if (row.isOutgoing) colorRgba(255, 255, 255, 0.72f) else palette.secondaryTextColor,
    )
  }
}

private object ConversationService {
  private val httpClient by lazy {
    OkHttpClient.Builder()
      .connectTimeout(15, TimeUnit.SECONDS)
      .readTimeout(20, TimeUnit.SECONDS)
      .writeTimeout(20, TimeUnit.SECONDS)
      .callTimeout(22, TimeUnit.SECONDS)
      .build()
  }
  private val mainHandler = Handler(Looper.getMainLooper())

  fun fetchMessages(
    context: Context,
    chatId: String,
    isSavedMessages: Boolean,
    callback: (Result<List<ConversationMessage>>) -> Unit,
  ) {
    val config = AppSessionConfig.current(context)
    if (config == null) {
      callback(Result.failure(IllegalStateException("Missing native auth config.")))
      return
    }

    Thread {
      val result = runCatching {
        val request = buildRequest(config, chatId, isSavedMessages)
        when (config.transportMode) {
          PacketTransportMode.OFFLINE ->
            throw IOException("Transport mode offline is not available in the standalone native app.")
          PacketTransportMode.BRIDGE_TEXT ->
            throw IOException("Transport mode bridge_text is not available in the standalone native app.")
          PacketTransportMode.PACKET_MESH -> {
            val snapshot = PacketRuntime.ensureStarted(context, config)
            execute(PacketRuntime.buildHttpClient(snapshot), request, config, isSavedMessages)
          }
          PacketTransportMode.DIRECT -> {
            try {
              val rows = execute(httpClient, request, config, isSavedMessages)
              PacketRuntime.stop(context, resetToDirect = true)
              PacketBootstrapService.prefetchIfNeeded(context, config)
              rows
            } catch (_: Throwable) {
              val snapshot = PacketRuntime.ensureStarted(context, config)
              execute(PacketRuntime.buildHttpClient(snapshot), request, config, isSavedMessages)
            }
          }
        }
      }
      mainHandler.post { callback(result) }
    }.start()
  }

  private fun buildRequest(
    config: AppSessionConfig,
    chatId: String,
    isSavedMessages: Boolean,
  ): Request {
    val base = config.apiBaseUrl.trim().trimEnd('/')
    val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
    val url =
      if (isSavedMessages) {
        "$pathBase/saved_messages/${config.userId}"
      } else {
        "$pathBase/chat/$chatId/messages?limit=60"
      }
    return Request.Builder()
      .url(url)
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
      .header("Authorization", "Bearer ${config.authToken}")
      .build()
  }

  private fun execute(
    client: OkHttpClient,
    request: Request,
    config: AppSessionConfig,
    isSavedMessages: Boolean,
  ): List<ConversationMessage> {
    client.newCall(request).execute().use { response ->
      if (!response.isSuccessful) {
        throw IOException(
          "Request failed with status ${response.code}: ${response.body?.string().orEmpty().take(160)}",
        )
      }
      val body = response.body?.string().orEmpty()
      return parseConversationMessages(parsePayload(body), config.userId, isSavedMessages)
    }
  }

  private fun parsePayload(body: String): List<Map<String, Any?>> {
    val trimmed = body.trim()
    if (trimmed.startsWith("{")) {
      val obj = JSONObject(trimmed)
      val nested = obj.optJSONArray("messages") ?: obj.optJSONArray("data") ?: JSONArray()
      return parseArray(nested)
    }
    return parseArray(JSONArray(trimmed))
  }

  private fun parseArray(array: JSONArray): List<Map<String, Any?>> {
    val items = ArrayList<Map<String, Any?>>(array.length())
    for (index in 0 until array.length()) {
      val item = array.opt(index)
      if (item is JSONObject) {
        items.add(jsonObjectToMap(item))
      }
    }
    return items
  }

  private fun jsonObjectToMap(json: JSONObject): Map<String, Any?> {
    val map = linkedMapOf<String, Any?>()
    val keys = json.keys()
    while (keys.hasNext()) {
      val key = keys.next()
      map[key] = jsonValueToAny(json.opt(key))
    }
    return map
  }

  private fun jsonArrayToList(json: JSONArray): List<Any?> {
    val list = ArrayList<Any?>(json.length())
    for (index in 0 until json.length()) {
      list.add(jsonValueToAny(json.opt(index)))
    }
    return list
  }

  private fun jsonValueToAny(value: Any?): Any? {
    return when (value) {
      null, JSONObject.NULL -> null
      is JSONObject -> jsonObjectToMap(value)
      is JSONArray -> jsonArrayToList(value)
      else -> value
    }
  }
}

private fun parseConversationMessages(
  rawRows: List<Map<String, Any?>>,
  currentUserId: String,
  isSavedMessages: Boolean,
): List<ConversationMessage> {
  return rawRows.mapIndexedNotNull { index, raw ->
    val body = resolveConversationBody(raw)
    val timestampMs = resolveTimestampMs(raw) ?: index.toLong()
    val fromId =
      normalized(raw["fromId"] ?: raw["from_id"] ?: raw["senderId"] ?: raw["sender_id"] ?: raw["userId"] ?: raw["user_id"])
    ConversationMessage(
      id = normalized(raw["id"] ?: raw["messageId"] ?: raw["message_id"]) ?: "row-$index",
      body = body,
      timestampMs = timestampMs,
      timeLabel = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(timestampMs)),
      isOutgoing = isSavedMessages || fromId == null || fromId == currentUserId,
    )
  }.sortedBy { it.timestampMs }
}

private fun resolveConversationBody(raw: Map<String, Any?>): String {
  val explicit =
    normalized(
      raw["body"] ?: raw["content"] ?: raw["text"] ?: raw["plainContent"] ?: raw["plain_content"] ?: raw["decryptedContent"] ?: raw["decrypted_content"],
    )
  if (!explicit.isNullOrBlank()) return explicit

  val fileName = normalized(raw["fileName"] ?: raw["file_name"])
  return when (normalized(raw["type"])?.lowercase(Locale.ROOT)) {
    "image", "gif" -> "Photo"
    "video" -> "Video"
    "voice" -> "Voice message"
    "music" -> "Audio"
    "file" -> fileName ?: "File"
    else -> fileName ?: "Unsupported message"
  }
}

private fun resolveTimestampMs(raw: Map<String, Any?>): Long? {
  val direct =
    parseLong(raw["timestamp"])
      ?: parseLong(raw["timestampMs"] ?: raw["timestamp_ms"])
      ?: parseLong(raw["createdAtMs"] ?: raw["created_at_ms"])
  if (direct != null) {
    return if (direct < 100000000000L) direct * 1000L else direct
  }

  val text =
    normalized(raw["insertedAt"] ?: raw["inserted_at"] ?: raw["createdAt"] ?: raw["created_at"])
      ?: return null
  return runCatching { Instant.parse(text).toEpochMilli() }.getOrNull()
    ?: runCatching { OffsetDateTime.parse(text, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant().toEpochMilli() }.getOrNull()
    ?: runCatching { ZonedDateTime.parse(text, DateTimeFormatter.ISO_ZONED_DATE_TIME).toInstant().toEpochMilli() }.getOrNull()
}

private fun parseLong(value: Any?): Long? {
  return when (value) {
    is Number -> value.toLong()
    is String -> value.trim().toLongOrNull()
    else -> null
  }
}

private fun normalized(value: Any?): String? {
  val text = value?.toString()?.trim().orEmpty()
  return text.takeIf { it.isNotEmpty() }
}

private fun dp(context: Context, value: Float): Int =
  TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, context.resources.displayMetrics).toInt()
