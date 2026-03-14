package expo.modules.vibechatnative

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PorterDuff
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import java.text.DateFormat
import java.util.Calendar
import java.util.Date
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max

class ChatMainView(
  context: Context,
  appContext: AppContext,
) : ExpoView(context, appContext) {
  // Enable Android's native layout system so child views (RecyclerView, input bar, etc.)
  // are measured/laid out even when React Native Fabric suppresses requestLayout().
  override val shouldUseAndroidLayout: Boolean = true

  companion object {
    private const val TAG = "ChatMainView"
    private const val PAGE_ANIMATION_DURATION_MS = 260L
    private const val PAGE_STATE_WATCHDOG_DELAY_MS = 360L
    private const val PROFILE_HEADER_COLLAPSE_DISTANCE_DP = 120f
    private val LINK_REGEX = Regex("""https?://\S+|www\.\S+""", RegexOption.IGNORE_CASE)
  }

  private val onViewportChanged by EventDispatcher<Map<String, Any>>()
  private val onNativeEvent by EventDispatcher<Map<String, Any>>()

  private val chatListView = ChatListView(context, appContext)

  private val pagesHost = FrameLayout(context)
  private val chatPage = LinearLayout(context)
  private val pinnedBannerView = ChatPinnedBannerView(context)
  private val profilePage = LinearLayout(context)

  private val chatHeader = LinearLayout(context)
  private val chatHeaderLeft = LinearLayout(context)
  private val chatHeaderRight = LinearLayout(context)
  private val chatProfileGroup = LinearLayout(context)
  private val chatTextGroup = LinearLayout(context)
  private val chatTitleView = TextView(context)
  private val chatSubtitleView = TextView(context)
  private val chatBackButton = ImageView(context)
  private val chatAvatarButton = FrameLayout(context)
  private val chatAvatarImage = ImageView(context)
  private val chatAvatarFallback = ImageView(context)
  private val chatVideoButton = ImageView(context)
  private val chatPhoneButton = ImageView(context)
  private val chatSearchButton = ImageView(context)

  private val profileHeader = FrameLayout(context)
  private val profileHeaderGlass = LiquidGlassView(context, appContext)
  private val profileBackButton = ImageView(context)
  private val profileHeaderTitle = TextView(context)
  private val profileHeaderName = TextView(context)

  private val profileScroll = ScrollView(context)
  private val profileContent = LinearLayout(context)
  private val profileHeroAvatar = FrameLayout(context)
  private val profileAvatarImage = ImageView(context)
  private val profileAvatarFallback = ImageView(context)
  private val profileNameView = TextView(context)
  private val profileHandleView = TextView(context)
  private val profileBioView = TextView(context)
  private val profileActionsRow = LinearLayout(context)
  private val profileMuteAction = ChatMainProfileActionNode(context)
  private val profileSearchAction = ChatMainProfileActionNode(context)
  private val profileAudioAction = ChatMainProfileActionNode(context)
  private val profileVideoAction = ChatMainProfileActionNode(context)
  private val profileInfoCard = LinearLayout(context)
  private val profileInfoTitle = TextView(context)
  private val profileInfoSubtitle = TextView(context)
  private val profileMembersRow = ChatMainProfileListRowNode(context)
  private val profileMediaRow = ChatMainProfileListRowNode(context)
  private val profileAudioRow = ChatMainProfileListRowNode(context)
  private val profileFilesRow = ChatMainProfileListRowNode(context)
  private val profileLinksRow = ChatMainProfileListRowNode(context)
  private val profilePinnedRow = ChatMainProfileListRowNode(context)

  private var surfaceId: String = ""
  private var headerMode: String = "default"
  private var headerTitle: String = "Chat"
  private var headerSubtitle: String = ""
  private var profileName: String = "User"
  private var profileHandle: String = ""
  private var profileBio: String = ""
  private var isGroupOrChannel: Boolean = false
  private var groupMemberDisplayNameByUserId: LinkedHashMap<String, String> = linkedMapOf()
  private var groupMemberOrder: MutableList<String> = mutableListOf()
  private var groupMemberCount: Int? = null
  private var groupTypingUserIds: List<String> = emptyList()
  private var directPeerTypingActive: Boolean = false
  private var pinnedBannerMessageId: String? = null
  private var pinnedBannerBody: String? = null
  private var avatarUri: String = ""
  private var isOnline: Boolean = false
  private var isChatMuted: Boolean = false
  private var engineChatId: String = ""
  private var enginePeerUserIdRaw: String = ""
  private var enginePeerUserId: String = ""
  private var engineLastSeenTimestampMs: Long? = null
  private var profileRows: List<Map<String, Any?>> = emptyList()
  private var profileSummaryMessageCount = 0
  private var profileSummaryMediaCount = 0
  private var profileSummaryAudioCount = 0
  private var profileSummaryFileCount = 0
  private var profileSummaryLinkCount = 0
  private var profileSummaryPinnedCount = 0
  private var profileSummaryRecentFiles: List<String> = emptyList()
  private var profileSummaryHistoryLoaded = false
  private var currentPage: String = "chat"
  private var pendingNativePageTarget: String? = null
  private var pendingNativePageLockUntilMs: Long = 0L
  private var standaloneProfileMode = false
  private val avatarHttpClient by lazy { ChatPhoenixClient.buildPinnedHttpClient() }
  private var avatarLoadCall: Call? = null
  private var avatarLoadToken = 0
  private var rowsUpdateCount = 0
  private val engineListenerId = "chat-main-view-${System.identityHashCode(this)}"

  private var textColor: Int = Color.WHITE
  private var secondaryTextColor: Int = Color.argb(220, 220, 220, 220)
  private var surfaceColor: Int = Color.argb(235, 20, 22, 28)
  private var headerBackgroundColor: Int = Color.argb(242, 16, 18, 24)
  private var profileBackgroundColor: Int = Color.argb(255, 16, 18, 24)

  init {
    setupRoot()
    setupChatPage()
    setupProfilePage()
    setupForwarders()
    applyTheme()
    updateHeaderTexts()
    updateProfileTexts()
    updateAvatarViews()
    applyPageState(animated = false, emitEvent = false)
    Log.i(TAG, "init complete page=$currentPage attached=$isAttachedToWindow")
  }

  override fun onDetachedFromWindow() {
    Log.i(
      TAG,
      "onDetachedFromWindow surfaceId=$surfaceId chatId=$engineChatId peerUserId=$enginePeerUserId page=$currentPage",
    )
    ChatEngine.setListener(engineListenerId, null)
    if (surfaceId.isNotBlank()) {
      ChatMainRegistry.unregister(surfaceId)
    }
    super.onDetachedFromWindow()
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    Log.i(
      TAG,
      "onAttachedToWindow surfaceId=$surfaceId chatId=$engineChatId peerUserId=$enginePeerUserId page=$currentPage",
    )
    registerChatEngineListener()
    refreshPresenceFromEngine(force = true)
    refreshTypingStateFromEngine(force = true)
    refreshPinnedBannerFromEngine(force = true)
    post { ensureVisiblePageState("attach-post") }
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    Log.d(TAG, "onSizeChanged w=$w h=$h oldw=$oldw oldh=$oldh page=$currentPage")
    if (w > 0 && h > 0) {
      post { ensureVisiblePageState("size-changed") }
    }
  }

  fun setSurfaceId(value: String) {
    val next = value.trim()
    if (next == surfaceId) return
    if (surfaceId.isNotBlank()) {
      ChatMainRegistry.unregister(surfaceId)
    }
    surfaceId = next
    if (surfaceId.isNotBlank()) {
      ChatMainRegistry.register(surfaceId, this)
      chatListView.setSurfaceId("${surfaceId}#list")
    }
    Log.i(TAG, "setSurfaceId surfaceId=$surfaceId")
  }

  fun setRows(rows: List<Map<String, Any?>>) {
    rowsUpdateCount += 1
    profileRows = rows
    rebuildProfileSummaryFromRows(rows)
    val shouldLog = rowsUpdateCount <= 6 || rows.isEmpty() || rowsUpdateCount % 20 == 0
    if (shouldLog) {
      val firstKind = normalized(rows.firstOrNull()?.get("kind")) ?: "-"
      Log.i(
        TAG,
        "setRows count=${rows.size} update=$rowsUpdateCount firstKind=$firstKind chatId=$engineChatId surfaceId=$surfaceId",
      )
    }
    chatListView.setRows(rows)
    updateProfileTexts()
  }

  fun setEngineSurfaceId(value: String) {
    Log.i(TAG, "setEngineSurfaceId surfaceId=${value.trim()}")
    chatListView.setEngineSurfaceId(value)
  }

  fun setEngineChatId(value: String) {
    engineChatId = value.trim()
    Log.i(TAG, "setEngineChatId chatId=$engineChatId")
    chatListView.setEngineChatId(value)
    registerChatEngineListener()
    refreshTypingStateFromEngine(force = true)
    refreshPinnedBannerFromEngine(force = true)
    refreshProfileSummaryFromEngine(force = true)
  }

  fun setEngineMyUserId(value: String) {
    chatListView.setEngineMyUserId(value)
  }

  fun setEnginePeerUserId(value: String) {
    enginePeerUserIdRaw = value.trim()
    enginePeerUserId = enginePeerUserIdRaw.uppercase(Locale.ROOT)
    Log.i(TAG, "setEnginePeerUserId peerUserId=$enginePeerUserId")
    chatListView.setEnginePeerUserId(value)
    if (enginePeerUserId.isBlank()) {
      engineLastSeenTimestampMs = null
      updateHeaderTexts()
      updateProfileTexts()
      updateAvatarViews()
      return
    }
    registerChatEngineListener()
    refreshPresenceFromEngine(force = true)
    refreshTypingStateFromEngine(force = true)
    updateAvatarViews()
  }

  fun setStatusAuthorityEnabled(enabled: Boolean) {
    chatListView.setStatusAuthorityEnabled(enabled)
  }

  fun setAppearance(rawAppearance: Map<String, Any?>) {
    chatListView.setAppearance(rawAppearance)
    parseAppearance(rawAppearance)
    applyTheme()
    updateHeaderTexts()
    updateProfileTexts()
  }

  fun applyContentPaddingTop(value: Double) {
    chatListView.setContentPaddingTop(value)
  }

  fun applyContentPaddingBottom(value: Double) {
    chatListView.setContentPaddingBottom(value)
  }

  fun setVoicePlayback(payload: Map<String, Any?>) {
    chatListView.setVoicePlayback(payload)
  }

  fun setInputBarEnabled(enabled: Boolean) {
    chatListView.setInputBarEnabled(enabled)
  }

  fun setInputPlaceholder(value: String) {
    chatListView.setInputPlaceholder(value)
  }

  fun setNativeSendEnabled(enabled: Boolean) {
    chatListView.setNativeSendEnabled(enabled)
  }

  fun setHeaderMode(value: String) {
    val next = value.trim().lowercase(Locale.ROOT).ifBlank { "default" }
    if (headerMode == next) return
    headerMode = next
    updateChatHeaderControls()
    updateHeaderTexts()
    updateAvatarViews()
  }

  fun setHeaderTitle(value: String) {
    headerTitle = value.trim()
    if (profileName.isBlank()) {
      profileName = headerTitle
    }
    updateHeaderTexts()
    updateProfileTexts()
  }

  fun setHeaderSubtitle(value: String) {
    headerSubtitle = value.trim()
    updateHeaderTexts()
  }

  fun setProfileName(value: String) {
    profileName = value.trim()
    updateHeaderTexts()
    updateProfileTexts()
  }

  fun setProfileHandle(value: String) {
    profileHandle = value.trim()
    updateProfileTexts()
  }

  fun setProfileBio(value: String) {
    profileBio = value.trim()
    updateProfileTexts()
  }

  fun setIsGroupOrChannel(value: Boolean) {
    isGroupOrChannel = value
    chatListView.setEngineIsGroupOrChannel(value)
    refreshTypingStateFromEngine(force = true)
    updateHeaderTexts()
    updateProfileTexts()
    updateAvatarViews()
  }

  fun setGroupMembers(rawMembers: List<Map<String, Any?>>) {
    val nextNamesByUserId = linkedMapOf<String, String>()
    val nextOrder = mutableListOf<String>()
    rawMembers.forEach { raw ->
      val rawId =
        normalized(raw["userId"] ?: raw["id"] ?: raw["memberId"])
          ?.trim()
          ?.takeIf { it.isNotEmpty() }
          ?: return@forEach
      val normalizedId = rawId.uppercase(Locale.ROOT)
      val displayName =
        normalized(raw["name"] ?: raw["username"] ?: raw["label"])
          ?.trim()
          ?.takeIf { it.isNotEmpty() }
          ?: rawId
      if (!nextNamesByUserId.containsKey(normalizedId)) {
        nextOrder.add(normalizedId)
      }
      nextNamesByUserId[normalizedId] = displayName
    }
    groupMemberDisplayNameByUserId = nextNamesByUserId
    groupMemberOrder = nextOrder
    refreshTypingStateFromEngine(force = true)
    updateHeaderTexts()
    updateProfileTexts()
  }

  fun setGroupMemberCount(value: Int?) {
    groupMemberCount = value?.coerceAtLeast(0)
    updateHeaderTexts()
    updateProfileTexts()
  }

  fun setAvatarUri(value: String?) {
    avatarUri = (value ?: "").trim()
    updateAvatarViews()
  }

  fun setIsOnline(value: Boolean) {
    if (enginePeerUserId.isBlank()) {
      isOnline = value
      engineLastSeenTimestampMs = null
      updateHeaderTexts()
      updateProfileTexts()
      return
    }
    refreshPresenceFromEngine(force = true)
  }

  fun setIsChatMuted(value: Boolean) {
    if (isChatMuted == value) return
    isChatMuted = value
    updateProfileActionState()
  }

  fun setStandaloneProfileMode(value: Boolean) {
    if (standaloneProfileMode == value) return
    standaloneProfileMode = value
    Log.i(TAG, "setStandaloneProfileMode enabled=$value")
    if (value) {
      chatListView.setInputBarEnabled(false)
      chatListView.setNativeSendEnabled(false)
      currentPage = "profile"
      pendingNativePageTarget = null
      pendingNativePageLockUntilMs = 0L
      applyPageState(animated = false, emitEvent = false)
    }
  }

  fun setPage(value: String, animated: Boolean) {
    val normalized = value.trim().lowercase()
    Log.i(
      TAG,
      "setPage request=$normalized animated=$animated current=$currentPage standalone=$standaloneProfileMode pending=$pendingNativePageTarget",
    )
    if (normalized == "profile") {
      if (standaloneProfileMode) {
        if (currentPage != "profile") {
          currentPage = "profile"
          applyPageState(animated = animated, emitEvent = false)
        }
      } else {
        onNativeEvent(mapOf("type" to "headerAvatarPressed"))
      }
      return
    }
    if (normalized == "agent") {
      onNativeEvent(mapOf("type" to "headerAgentPressed"))
      return
    }
    if (standaloneProfileMode) {
      onNativeEvent(mapOf("type" to "headerBack"))
      return
    }
    val next = "chat"
    val now = System.currentTimeMillis()
    val pendingTarget = pendingNativePageTarget
    if (pendingTarget != null && now < pendingNativePageLockUntilMs && next != pendingTarget) {
      return
    }
    if (pendingTarget != null && next == pendingTarget) {
      pendingNativePageTarget = null
      pendingNativePageLockUntilMs = 0L
    }
    if (next == currentPage) return
    currentPage = next
    applyPageState(animated = animated, emitEvent = true)
  }

  fun applyTransactions(transactions: List<Map<String, Any?>>) {
    chatListView.applyTransactions(transactions)
  }

  fun scrollToBottom(animated: Boolean) {
    chatListView.scrollToBottom(animated)
  }

  fun scrollToMessage(messageId: String, animated: Boolean, viewPosition: Double) {
    chatListView.scrollToMessage(messageId, animated, viewPosition)
  }

  fun startSendTransition(payload: Map<String, Any?>) {
    chatListView.startSendTransition(payload)
  }

  fun playReactionFx(payload: Map<String, Any?>) {
    chatListView.playReactionFx(payload)
  }

  private fun setupRoot() {
    setBackgroundColor(Color.TRANSPARENT)
    addView(
      pagesHost,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )
  }

  private fun setupForwarders() {
    chatListView.nativeEventListener = { payload ->
      onNativeEvent(payload)
    }
    chatListView.viewportChangedListener = { payload ->
      onViewportChanged(payload)
    }
  }

  private fun registerChatEngineListener() {
    if (!isAttachedToWindow || (enginePeerUserId.isBlank() && engineChatId.isBlank())) {
      Log.d(
        TAG,
        "registerChatEngineListener detachedOrMissingIds attached=$isAttachedToWindow chatId=$engineChatId peerUserId=$enginePeerUserId",
      )
      ChatEngine.setListener(engineListenerId, null)
      return
    }
    Log.d(TAG, "registerChatEngineListener chatId=$engineChatId peerUserId=$enginePeerUserId")
    ChatEngine.setListener(engineListenerId) { _, changedChatId, _ ->
      post {
        refreshPresenceFromEngine()
        refreshTypingStateFromEngine()
        val normalizedChangedChatId = changedChatId?.trim().orEmpty()
        if (engineChatId.isBlank() || normalizedChangedChatId.isBlank() || normalizedChangedChatId == engineChatId) {
          refreshPinnedBannerFromEngine()
        }
        refreshProfileSummaryFromEngine()
      }
    }
  }

  private fun refreshPresenceFromEngine(force: Boolean = false) {
    if (enginePeerUserId.isBlank()) return
    val nextOnline = ChatEngine.isUserOnline(enginePeerUserId)
    val nextLastSeen = ChatEngine.lastSeenTimestampMs(enginePeerUserId)
    if (!force && nextOnline == isOnline && nextLastSeen == engineLastSeenTimestampMs) {
      return
    }
    isOnline = nextOnline
    engineLastSeenTimestampMs = nextLastSeen
    updateHeaderTexts()
    updateProfileTexts()
  }

  private fun refreshTypingStateFromEngine(force: Boolean = false) {
    if (!isGroupOrChannel) {
      val isPeerTyping = ChatEngine.typingUserIds(engineChatId).isNotEmpty()
      if (!force && directPeerTypingActive == isPeerTyping) return
      directPeerTypingActive = isPeerTyping
      updateHeaderTexts()
      updateProfileTexts()
      return
    }
    val chatId = engineChatId.trim()
    if (chatId.isBlank()) {
      if (!force && groupTypingUserIds.isEmpty()) return
      groupTypingUserIds = emptyList()
      updateHeaderTexts()
      updateProfileTexts()
      return
    }
    val next = ChatEngine.typingUserIds(chatId)
    if (!force && next == groupTypingUserIds) return
    groupTypingUserIds = next
    updateHeaderTexts()
    updateProfileTexts()
  }

  private fun refreshProfileSummaryFromEngine(force: Boolean = false) {
    val chatId = engineChatId.trim()
    if (chatId.isBlank()) {
      if (
        force
          || profileSummaryMessageCount != 0
          || profileSummaryMediaCount != 0
          || profileSummaryFileCount != 0
          || profileSummaryLinkCount != 0
          || profileSummaryHistoryLoaded
          || profileSummaryRecentFiles.isNotEmpty()
      ) {
        profileSummaryMessageCount = 0
        profileSummaryMediaCount = 0
        profileSummaryFileCount = 0
        profileSummaryLinkCount = 0
        profileSummaryRecentFiles = emptyList()
        profileSummaryHistoryLoaded = false
        updateProfileTexts()
      }
      return
    }

    val summary = ChatEngine.getChatProfileSummary(mapOf("chatId" to chatId))
    val nextMessageCount = (summary["totalMessages"] as? Number)?.toInt() ?: 0
    val nextMediaCount = (summary["mediaCount"] as? Number)?.toInt() ?: 0
    val nextFileCount = (summary["fileCount"] as? Number)?.toInt() ?: 0
    val nextLinkCount = (summary["linkCount"] as? Number)?.toInt() ?: 0
    val nextHistoryLoaded = summary["historyLoaded"] as? Boolean ?: false
    val nextRecentFiles =
      (summary["recentFiles"] as? List<*>)?.mapNotNull { it?.toString()?.trim()?.takeIf(String::isNotEmpty) }
        ?: emptyList()

    if (
      !force
        && nextMessageCount == profileSummaryMessageCount
        && nextMediaCount == profileSummaryMediaCount
        && nextFileCount == profileSummaryFileCount
        && nextLinkCount == profileSummaryLinkCount
        && nextHistoryLoaded == profileSummaryHistoryLoaded
        && nextRecentFiles == profileSummaryRecentFiles
    ) {
      return
    }

    profileSummaryMessageCount = nextMessageCount
    profileSummaryMediaCount = nextMediaCount
    profileSummaryFileCount = nextFileCount
    profileSummaryLinkCount = nextLinkCount
    profileSummaryRecentFiles = nextRecentFiles
    profileSummaryHistoryLoaded = nextHistoryLoaded
    updateProfileTexts()
  }

  private fun refreshPinnedBannerFromEngine(force: Boolean = false) {
    val chatId = engineChatId.trim()
    if (chatId.isBlank()) {
      if (
        force
          || pinnedBannerMessageId != null
          || pinnedBannerBody != null
          || pinnedBannerView.visibility != View.GONE
      ) {
        pinnedBannerMessageId = null
        pinnedBannerBody = null
        pinnedBannerView.alpha = 0f
        pinnedBannerView.visibility = View.GONE
      }
      return
    }

    val payload = ChatEngine.getPinnedMessages(mapOf("chatId" to chatId))
    val pins = (payload["data"] as? List<*>) ?: emptyList<Any?>()
    val topPin = pins.firstOrNull() as? Map<*, *>
    val nextMessageId = pinnedMessageId(topPin)
    val nextBody = resolvePinnedBody(chatId, topPin)
    val shouldHide = nextBody.isNullOrBlank()
    val changed =
      nextMessageId != pinnedBannerMessageId
        || nextBody != pinnedBannerBody
        || (pinnedBannerView.visibility == View.GONE) != shouldHide
    if (!force && !changed) return

    pinnedBannerMessageId = nextMessageId
    pinnedBannerBody = nextBody

    if (shouldHide) {
      if (pinnedBannerView.visibility == View.GONE) {
        pinnedBannerView.alpha = 0f
      } else {
        pinnedBannerView.animate().cancel()
        pinnedBannerView.animate()
          .alpha(0f)
          .setDuration(180L)
          .withEndAction {
            pinnedBannerView.visibility = View.GONE
          }
          .start()
      }
      return
    }

    pinnedBannerView.configure("Pinned Message", nextBody.orEmpty())
    if (pinnedBannerView.visibility != View.VISIBLE) {
      pinnedBannerView.visibility = View.VISIBLE
      pinnedBannerView.alpha = 0f
      pinnedBannerView.animate().cancel()
      pinnedBannerView.animate().alpha(1f).setDuration(200L).start()
    } else {
      pinnedBannerView.alpha = 1f
    }
  }

  private fun pinnedMessageId(pin: Map<*, *>?): String? {
    val raw = pin?.get("messageId") ?: pin?.get("message_id") ?: pin?.get("id")
    return normalized(raw)
  }

  private fun resolvePinnedBody(chatId: String, pin: Map<*, *>?): String? {
    if (pin == null) return null
    val pinText = normalized(pin["text"] ?: pin["plainContent"] ?: pin["plain_content"])
    if (!pinText.isNullOrBlank()) return pinText
    val fileName = normalized(pin["fileName"] ?: pin["file_name"])
    if (!fileName.isNullOrBlank()) return "File: $fileName"

    val targetMessageId = pinnedMessageId(pin) ?: return "Pinned message"
    val rows = ChatEngine.getChatRows(mapOf("chatId" to chatId))
    for (index in rows.size - 1 downTo 0) {
      val row = rows[index]
      if (normalized(row["kind"]) != "message") continue
      val message = row["message"] as? Map<*, *> ?: continue
      if (normalized(message["id"]) != targetMessageId) continue

      val text = normalized(message["text"] ?: message["plainContent"] ?: message["plain_content"])
      if (!text.isNullOrBlank()) return text
      val caption = normalized(message["caption"])
      if (!caption.isNullOrBlank()) return caption
      val type = normalized(message["type"])?.lowercase(Locale.ROOT) ?: "text"
      if (type == "file") {
        val name = normalized(message["fileName"] ?: message["file_name"])
        return if (!name.isNullOrBlank()) "File: $name" else "Pinned file"
      }
      val mediaUrl = normalized(message["mediaUrl"] ?: message["media_url"])
      if (!mediaUrl.isNullOrBlank()) return mediaUrl
      return "Pinned message"
    }
    return "Pinned message"
  }

  private fun handlePinnedBannerPressed() {
    val messageId = pinnedBannerMessageId ?: return
    if (messageId.isBlank()) return
    if (currentPage != "chat") return
    chatListView.scrollToMessage(messageId, animated = true, viewPosition = 0.2)
    onNativeEvent(
      mapOf(
        "type" to "pinnedBannerPressed",
        "messageId" to messageId,
      ),
    )
  }

  private fun setupChatPage() {
    chatPage.orientation = LinearLayout.VERTICAL
    chatPage.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    pagesHost.addView(chatPage)

    val statusTop = statusBarHeightPx()
    chatHeader.orientation = LinearLayout.HORIZONTAL
    chatHeader.gravity = Gravity.CENTER_VERTICAL
    chatHeader.layoutParams = LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      statusTop + dp(60),
    )
    chatHeader.setPadding(dp(8), statusTop, dp(8), 0)
    chatPage.addView(chatHeader)

    chatHeaderLeft.orientation = LinearLayout.HORIZONTAL
    chatHeaderLeft.gravity = Gravity.CENTER_VERTICAL
    chatHeader.addView(
      chatHeaderLeft,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f),
    )

    chatHeaderRight.orientation = LinearLayout.HORIZONTAL
    chatHeaderRight.gravity = Gravity.CENTER_VERTICAL
    chatHeader.addView(
      chatHeaderRight,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    chatBackButton.setImageResource(R.drawable.ic_chevron_left)
    chatBackButton.scaleType = ImageView.ScaleType.CENTER_INSIDE
    chatBackButton.setPadding(dp(8), dp(8), dp(8), dp(8))
    chatBackButton.setOnClickListener {
      if (currentPage == "profile") {
        markPendingNativePageChange("chat")
        currentPage = "chat"
        applyPageState(animated = true, emitEvent = true)
        return@setOnClickListener
      }
      onNativeEvent(mapOf("type" to "headerBack"))
    }
    setTouchAlphaPress(chatBackButton)
    chatHeaderLeft.addView(
      chatBackButton,
      LinearLayout.LayoutParams(dp(44), dp(44)).apply {
        marginEnd = dp(4)
      },
    )

    chatProfileGroup.orientation = LinearLayout.HORIZONTAL
    chatProfileGroup.gravity = Gravity.CENTER_VERTICAL
    chatProfileGroup.setOnClickListener {
      if (isSavedMessagesHeaderMode()) return@setOnClickListener
      if (currentPage != "chat") return@setOnClickListener
      onNativeEvent(mapOf("type" to "headerAvatarPressed"))
    }
    setTouchAlphaPress(chatProfileGroup)
    chatHeaderLeft.addView(
      chatProfileGroup,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
    )

    chatAvatarButton.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(19))
    chatAvatarButton.addView(
      chatAvatarImage,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    chatAvatarImage.scaleType = ImageView.ScaleType.CENTER_CROP
    chatAvatarImage.visibility = View.GONE

    chatAvatarFallback.scaleType = ImageView.ScaleType.FIT_CENTER
    chatAvatarFallback.setImageResource(R.drawable.ic_avatar_person)
    chatAvatarFallback.setPadding(dp(11), dp(11), dp(11), dp(11))
    chatAvatarButton.addView(
      chatAvatarFallback,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    chatProfileGroup.addView(
      chatAvatarButton,
      LinearLayout.LayoutParams(dp(38), dp(38)).apply {
        marginEnd = dp(12)
      },
    )

    chatTextGroup.orientation = LinearLayout.VERTICAL
    chatTextGroup.gravity = Gravity.CENTER_VERTICAL
    chatProfileGroup.addView(
      chatTextGroup,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
    )

    chatTitleView.setTypeface(Typeface.DEFAULT_BOLD)
    chatTitleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
    chatTitleView.gravity = Gravity.START or Gravity.CENTER_VERTICAL
    chatTitleView.maxLines = 1
    chatTitleView.includeFontPadding = false
    chatTextGroup.addView(
      chatTitleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    chatSubtitleView.setTypeface(Typeface.DEFAULT, Typeface.NORMAL)
    chatSubtitleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    chatSubtitleView.gravity = Gravity.START or Gravity.CENTER_VERTICAL
    chatSubtitleView.maxLines = 1
    chatSubtitleView.includeFontPadding = false
    chatTextGroup.addView(
      chatSubtitleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    styleHeaderActionButton(chatVideoButton, R.drawable.ic_video)
    chatVideoButton.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerVideoCallPressed"))
    }

    styleHeaderActionButton(chatPhoneButton, R.drawable.ic_call_accept)
    chatPhoneButton.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerAudioCallPressed"))
    }

    styleHeaderActionButton(chatSearchButton, R.drawable.ic_search)
    chatSearchButton.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerSearchPressed"))
    }

    chatHeaderRight.addView(
      chatVideoButton,
      LinearLayout.LayoutParams(dp(40), dp(40)),
    )
    chatHeaderRight.addView(
      chatPhoneButton,
      LinearLayout.LayoutParams(dp(40), dp(40)),
    )
    chatHeaderRight.addView(
      chatSearchButton,
      LinearLayout.LayoutParams(dp(40), dp(40)),
    )
    updateChatHeaderControls()

    pinnedBannerView.visibility = View.GONE
    pinnedBannerView.alpha = 0f
    pinnedBannerView.setOnClickListener { handlePinnedBannerPressed() }
    chatPage.addView(
      pinnedBannerView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        dp(ChatPinnedBannerView.PREFERRED_HEIGHT_DP),
      ).apply {
        marginStart = dp(16)
        marginEnd = dp(16)
        topMargin = dp(6)
        bottomMargin = dp(6)
      },
    )

    chatPage.addView(
      chatListView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )
  }

  private fun setupProfilePage() {
    profilePage.orientation = LinearLayout.VERTICAL
    profilePage.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    profilePage.visibility = View.GONE
    profilePage.alpha = 0f
    pagesHost.addView(profilePage)

    val statusTop = statusBarHeightPx()
    profileHeader.layoutParams = LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      statusTop + dp(56),
    )
    profilePage.addView(profileHeader)

    profileHeaderGlass.alpha = 0f
    profileHeaderGlass.setCornerRadius(20.0)
    profileHeaderGlass.setBlurIntensity(14.0)
    profileHeaderGlass.setInteractive(false)
    profileHeaderGlass.setPressFeedbackEnabled(false)
    profileHeader.addView(
      profileHeaderGlass,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        dp(44),
        Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
      ).apply {
        marginStart = dp(12)
        marginEnd = dp(12)
        bottomMargin = dp(6)
      },
    )

    profileBackButton.setImageResource(R.drawable.ic_chevron_left)
    profileBackButton.scaleType = ImageView.ScaleType.CENTER_INSIDE
    profileBackButton.setPadding(dp(8), dp(8), dp(8), dp(8))
    profileBackButton.setOnClickListener {
      if (standaloneProfileMode) {
        onNativeEvent(mapOf("type" to "headerBack"))
      } else {
        markPendingNativePageChange("chat")
        currentPage = "chat"
        applyPageState(animated = true, emitEvent = true)
      }
    }
    profileHeader.addView(
      profileBackButton,
      FrameLayout.LayoutParams(dp(44), dp(44), Gravity.START or Gravity.BOTTOM).apply {
        marginStart = dp(12)
        bottomMargin = dp(6)
      },
    )

    profileHeaderTitle.setTypeface(Typeface.DEFAULT_BOLD)
    profileHeaderTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    profileHeaderTitle.text = "Profile"
    profileHeaderTitle.gravity = Gravity.CENTER
    profileHeader.addView(
      profileHeaderTitle,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM,
      ).apply {
        bottomMargin = dp(18)
      },
    )

    profileHeaderName.setTypeface(Typeface.DEFAULT_BOLD)
    profileHeaderName.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    profileHeaderName.gravity = Gravity.CENTER
    profileHeaderName.alpha = 0f
    profileHeader.addView(
      profileHeaderName,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM,
      ).apply {
        bottomMargin = dp(18)
      },
    )

    profileScroll.overScrollMode = View.OVER_SCROLL_ALWAYS
    profileScroll.isFillViewport = true
    profileScroll.setOnScrollChangeListener { _, _, scrollY, _, _ ->
      updateProfileHeaderChrome(scrollY)
    }
    profilePage.addView(
      profileScroll,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )

    profileContent.orientation = LinearLayout.VERTICAL
    profileContent.gravity = Gravity.CENTER_HORIZONTAL
    profileContent.setPadding(dp(20), dp(24), dp(20), dp(32))
    profileScroll.addView(
      profileContent,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileHeroAvatar.background = roundedShape(surfaceColor, dp(59))
    profileContent.addView(
      profileHeroAvatar,
      LinearLayout.LayoutParams(dp(118), dp(118)),
    )

    profileAvatarImage.scaleType = ImageView.ScaleType.CENTER_CROP
    profileAvatarImage.visibility = View.GONE
    profileHeroAvatar.addView(
      profileAvatarImage,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    profileAvatarFallback.scaleType = ImageView.ScaleType.FIT_CENTER
    profileAvatarFallback.setImageResource(R.drawable.ic_avatar_person)
    profileAvatarFallback.setPadding(dp(32), dp(32), dp(32), dp(32))
    profileHeroAvatar.addView(
      profileAvatarFallback,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    profileNameView.setTypeface(Typeface.DEFAULT_BOLD)
    profileNameView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
    profileNameView.gravity = Gravity.CENTER
    profileNameView.setPadding(0, dp(14), 0, 0)
    profileContent.addView(
      profileNameView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileHandleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
    profileHandleView.gravity = Gravity.CENTER
    profileHandleView.setPadding(0, dp(2), 0, 0)
    profileContent.addView(
      profileHandleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileBioView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    profileBioView.gravity = Gravity.CENTER
    profileBioView.setLineSpacing(dpF(2f), 1f)
    profileBioView.setPadding(dp(8), dp(12), dp(8), 0)
    profileBioView.visibility = View.GONE
    profileContent.addView(
      profileBioView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileActionsRow.orientation = LinearLayout.HORIZONTAL
    profileActionsRow.gravity = Gravity.CENTER
    profileActionsRow.setPadding(0, dp(18), 0, 0)
    profileContent.addView(
      profileActionsRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileMuteAction.configure(
      title = "Mute",
      iconRes = android.R.drawable.ic_lock_silent_mode,
    )
    profileMuteAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerMenuAction", "action" to "muteToggle"))
    }
    profileActionsRow.addView(
      profileMuteAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply { marginEnd = dp(6) },
    )

    profileSearchAction.configure(
      title = "Search",
      iconRes = R.drawable.ic_search,
    )
    profileSearchAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerSearchPressed"))
    }
    profileActionsRow.addView(
      profileSearchAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply {
        marginStart = dp(2)
        marginEnd = dp(2)
      },
    )

    profileAudioAction.configure(
      title = "Call",
      iconRes = R.drawable.ic_call_accept,
    )
    profileAudioAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerAudioCallPressed"))
    }
    profileActionsRow.addView(
      profileAudioAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply {
        marginStart = dp(2)
        marginEnd = dp(2)
      },
    )

    profileVideoAction.configure(
      title = "Video",
      iconRes = R.drawable.ic_video,
    )
    profileVideoAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerVideoCallPressed"))
    }
    profileActionsRow.addView(
      profileVideoAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply { marginStart = dp(6) },
    )

    profileInfoCard.orientation = LinearLayout.VERTICAL
    profileInfoCard.background = roundedShape(surfaceColor, dp(24))
    val cardParams = LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      LinearLayout.LayoutParams.WRAP_CONTENT,
    )
    cardParams.topMargin = dp(18)
    profileContent.addView(profileInfoCard, cardParams)

    profileInfoTitle.setTypeface(Typeface.DEFAULT_BOLD)
    profileInfoTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    profileInfoTitle.text = "Shared Content"
    profileInfoTitle.setPadding(dp(18), dp(16), dp(18), dp(8))
    profileInfoCard.addView(
      profileInfoTitle,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileInfoSubtitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    profileInfoSubtitle.visibility = View.GONE
    profileInfoCard.addView(
      profileInfoSubtitle,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileMembersRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileMembersPressed", "chatId" to engineChatId))
    }
    profileInfoCard.addView(
      profileMembersRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileMediaRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "media", "chatId" to engineChatId))
    }
    profileInfoCard.addView(
      profileMediaRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileAudioRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "music", "chatId" to engineChatId))
    }
    profileInfoCard.addView(
      profileAudioRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileFilesRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "files", "chatId" to engineChatId))
    }
    profileInfoCard.addView(
      profileFilesRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileLinksRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "links", "chatId" to engineChatId))
    }
    profileInfoCard.addView(
      profileLinksRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profilePinnedRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "pinned", "chatId" to engineChatId))
    }
    profileInfoCard.addView(
      profilePinnedRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    updateProfileHeaderChrome(0)
  }

  private fun parseAppearance(raw: Map<String, Any?>) {
    val textCandidate = colorFromAny(raw["textColorThem"])
    val timeCandidate = colorFromAny(raw["timeColorThem"])
    val bubbleCandidate = colorFromAny(raw["bubbleThemColor"])
    val bgCandidate = (raw["wallpaperGradient"] as? List<*>)?.firstOrNull()?.let { colorFromAny(it) }

    if (textCandidate != null) textColor = textCandidate
    if (timeCandidate != null) secondaryTextColor = timeCandidate
    if (bubbleCandidate != null) surfaceColor = withAlpha(bubbleCandidate, 0.52f)
    if (bgCandidate != null) {
      headerBackgroundColor = bgCandidate
      profileBackgroundColor = withAlpha(bgCandidate, 0.94f)
    }
  }

  private fun applyTheme() {
    val hasGroupTyping = isGroupOrChannel && groupTypingUserIds.isNotEmpty()
    val shouldHighlightStatus = hasGroupTyping || isOnline
    val headerActionColor = resolveHeaderActionColor()
    chatHeader.setBackgroundColor(withAlpha(headerBackgroundColor, 0.95f))
    profileHeader.setBackgroundColor(Color.TRANSPARENT)
    profileHeaderGlass.setTintColor(withAlpha(surfaceColor, 0.88f))
    profileHeaderGlass.setBorderEnabled(true)
    profileHeaderGlass.setShadowEnabled(true)
    profilePage.setBackgroundColor(profileBackgroundColor)
    val isHeaderDark = contrastForegroundFor(headerBackgroundColor) == Color.WHITE
    val softRgba = if (isHeaderDark) Color.argb(20, 248, 246, 252) else Color.argb(13, 26, 26, 31)

    profileInfoCard.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(24))
    profileHeroAvatar.background = roundedShape(softRgba, dp(59))
    chatAvatarButton.background = roundedShape(softRgba, dp(19))
    listOf(profileMuteAction, profileSearchAction, profileAudioAction, profileVideoAction).forEach { action ->
      action.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(16))
    }

    chatBackButton.setColorFilter(headerActionColor, PorterDuff.Mode.SRC_IN)
    chatVideoButton.setColorFilter(headerActionColor, PorterDuff.Mode.SRC_IN)
    chatPhoneButton.setColorFilter(headerActionColor, PorterDuff.Mode.SRC_IN)
    chatSearchButton.setColorFilter(headerActionColor, PorterDuff.Mode.SRC_IN)
    chatTitleView.setTextColor(textColor)
    chatSubtitleView.setTextColor(if (shouldHighlightStatus) Color.parseColor("#53E08A") else secondaryTextColor)
    pinnedBannerView.applyTheme(
      textColor = textColor,
      surfaceColor = headerBackgroundColor,
      isDark = contrastForegroundFor(headerBackgroundColor) == Color.WHITE,
    )
    profileHeaderTitle.setTextColor(textColor)
    profileHeaderName.setTextColor(textColor)
    profileBackButton.setColorFilter(textColor, PorterDuff.Mode.SRC_IN)
    chatAvatarFallback.setColorFilter(textColor, PorterDuff.Mode.SRC_IN)
    profileAvatarFallback.setColorFilter(textColor, PorterDuff.Mode.SRC_IN)
    profileNameView.setTextColor(textColor)
    profileHandleView.setTextColor(
      if (hasGroupTyping || (!isGroupOrChannel && isOnline)) Color.parseColor("#53E08A")
      else secondaryTextColor)
    profileBioView.setTextColor(secondaryTextColor)
    profileInfoTitle.setTextColor(textColor)
    profileInfoSubtitle.setTextColor(secondaryTextColor)
    listOf(profileMuteAction, profileSearchAction, profileAudioAction, profileVideoAction).forEach { action ->
      action.applyTheme(
        foreground = textColor,
        background = withAlpha(surfaceColor, 0.92f),
      )
    }
    applyProfileRowTheme(profileMembersRow, Color.parseColor("#3B82F6"))
    applyProfileRowTheme(profileMediaRow, Color.parseColor("#EC4899"))
    applyProfileRowTheme(profileAudioRow, Color.parseColor("#10B981"))
    applyProfileRowTheme(profileFilesRow, Color.parseColor("#6366F1"))
    applyProfileRowTheme(profileLinksRow, Color.parseColor("#F59E0B"))
    applyProfileRowTheme(profilePinnedRow, Color.parseColor("#F97316"))
    updateChatHeaderControls()
    updateProfileActionState()
    updateProfileHeaderChrome(profileScroll.scrollY)
  }

  private fun updateHeaderTexts() {
    val resolvedTitle =
      if (isSavedMessagesHeaderMode()) {
        if (headerTitle.isBlank()) "Saved Messages" else headerTitle
      } else {
        if (headerTitle.isBlank()) "Chat" else headerTitle
      }
    val groupTypingSubtitle = resolvedGroupTypingSubtitle()
    val engineSubtitle = resolveEnginePresenceSubtitle()
    val jsSubtitle = headerSubtitle.trim()
    val jsSubtitleLower = jsSubtitle.lowercase(Locale.ROOT)
    val groupFallbackSubtitle =
      if (isGroupOrChannel && jsSubtitle.isBlank()) {
        val count = resolvedGroupMemberCount()
        if (count > 0) "$count members" else "group chat"
      } else {
        jsSubtitle
      }
    val resolvedSubtitle =
      if (isSavedMessagesHeaderMode()) {
        ""
      } else {
        groupTypingSubtitle
          ?: engineSubtitle
          ?: if (isOnline && (jsSubtitle.isBlank() || jsSubtitleLower.startsWith("last seen") || jsSubtitleLower == "offline")) {
            "online"
          } else {
            groupFallbackSubtitle
          }
      }
    chatTitleView.text = resolvedTitle
    chatSubtitleView.text = resolvedSubtitle
    chatSubtitleView.visibility = if (resolvedSubtitle.isBlank()) View.GONE else View.VISIBLE
    applyTheme()
  }

  private fun updateProfileTexts() {
    val resolvedTitle = if (profileName.isBlank()) if (headerTitle.isBlank()) "User" else headerTitle else profileName
    profileNameView.text = resolvedTitle
    profileHeaderName.text = resolvedTitle
    if (isGroupOrChannel) {
      val count = resolvedGroupMemberCount()
      val fallbackHandle = if (count > 0) "$count members" else "group chat"
      profileHandleView.text = if (profileHandle.isBlank()) fallbackHandle else profileHandle
    } else {
      val fallbackHandle = resolveEnginePresenceSubtitle() ?: if (isOnline) "online" else "offline"
      profileHandleView.text = if (profileHandle.isBlank()) fallbackHandle else profileHandle
    }
    val resolvedBio = profileBio.takeIf { it.isNotBlank() }.orEmpty()
    profileBioView.text = resolvedBio
    profileBioView.visibility = if (resolvedBio.isBlank()) View.GONE else View.VISIBLE
    profileInfoTitle.text = if (isGroupOrChannel) "Overview" else "Shared Content"
    profileInfoSubtitle.visibility = View.GONE
    configureProfileSummaryRows()
    updateProfileActionState()
    updateProfileHeaderChrome(profileScroll.scrollY)
  }

  private fun updateProfileHeaderChrome(scrollY: Int) {
    val progress = (scrollY / dpF(PROFILE_HEADER_COLLAPSE_DISTANCE_DP)).coerceIn(0f, 1f)
    profileHeaderGlass.alpha = progress
    profileHeaderGlass.translationY = dpF(6f) * (1f - progress)
    profileHeaderTitle.alpha = 1f - progress
    profileHeaderTitle.translationY = -dpF(8f) * progress
    profileHeaderName.alpha = progress
    profileHeaderName.translationY = dpF(8f) * (1f - progress)
    profileHeader.elevation = dpF(6f) * progress
  }

  private fun rebuildProfileSummaryFromRows(rows: List<Map<String, Any?>>) {
    var totalMessages = 0
    var mediaCount = 0
    var audioCount = 0
    var fileCount = 0
    var linkCount = 0
    var pinnedCount = 0
    val recentFiles = mutableListOf<String>()

    rows.forEach { row ->
      if (normalized(row["kind"]) != "message") return@forEach
      val message = row["message"] as? Map<*, *> ?: return@forEach
      totalMessages += 1

      val type = normalized(message["type"])?.lowercase(Locale.ROOT).orEmpty()
      val text = normalized(message["text"]).orEmpty()
      val mediaUrl = normalized(message["mediaUrl"]).orEmpty()
      val fileName = normalized(message["fileName"]).orEmpty()
      val isPinned = (message["isPinned"] as? Boolean) == true

      if (type == "image" || type == "gif" || type == "video" || type == "sticker") {
        mediaCount += 1
      }
      if (type == "music") {
        audioCount += 1
      }
      if (type == "file") {
        fileCount += 1
        if (fileName.isNotBlank() && recentFiles.size < 3) {
          recentFiles.add(fileName)
        }
      }
      if (isPinned) {
        pinnedCount += 1
      }
      if (containsProfileLink(text) || containsProfileLink(mediaUrl)) {
        linkCount += 1
      }
    }

    profileSummaryHistoryLoaded = profileSummaryHistoryLoaded || rows.isNotEmpty()
    profileSummaryMessageCount = totalMessages
    profileSummaryMediaCount = mediaCount
    profileSummaryAudioCount = audioCount
    profileSummaryFileCount = fileCount
    profileSummaryLinkCount = linkCount
    profileSummaryPinnedCount = pinnedCount
    profileSummaryRecentFiles = recentFiles
  }

  private fun configureProfileSummaryRows() {
    profileMembersRow.visibility = if (isGroupOrChannel) View.VISIBLE else View.GONE
    if (isGroupOrChannel) {
      profileMembersRow.configure(
        title = "Members",
        value = resolvedGroupMemberCount().toString(),
        iconRes = R.drawable.ic_profile_members,
        showsSeparator = true,
      )
    }

    val visibleRows = mutableListOf<ChatMainProfileListRowNode>()
    if (profileMembersRow.visibility == View.VISIBLE) visibleRows.add(profileMembersRow)
    visibleRows.add(profileMediaRow)
    visibleRows.add(profileAudioRow)
    visibleRows.add(profileFilesRow)
    visibleRows.add(profileLinksRow)
    visibleRows.add(profilePinnedRow)

    profileMediaRow.configure(
      title = "Media",
      value = profileSummaryMediaCount.toString(),
      iconRes = R.drawable.ic_profile_media,
      showsSeparator = true,
    )
    profileAudioRow.configure(
      title = "Audio",
      value = profileSummaryAudioCount.toString(),
      iconRes = R.drawable.ic_profile_audio,
      showsSeparator = true,
    )
    profileFilesRow.configure(
      title = "Files",
      value = profileSummaryFileCount.toString(),
      iconRes = R.drawable.ic_profile_files,
      showsSeparator = true,
    )
    profileLinksRow.configure(
      title = "Links",
      value = profileSummaryLinkCount.toString(),
      iconRes = R.drawable.ic_profile_links,
      showsSeparator = true,
    )
    profilePinnedRow.configure(
      title = "Pinned",
      value = profileSummaryPinnedCount.toString(),
      iconRes = R.drawable.ic_profile_pinned,
      showsSeparator = false,
    )

    visibleRows.forEachIndexed { index, row ->
      val isLast = index == visibleRows.lastIndex
      row.configure(
        title = when (row) {
          profileMembersRow -> "Members"
          profileMediaRow -> "Media"
          profileAudioRow -> "Audio"
          profileFilesRow -> "Files"
          profileLinksRow -> "Links"
          else -> "Pinned"
        },
        value = when (row) {
          profileMembersRow -> resolvedGroupMemberCount().toString()
          profileMediaRow -> profileSummaryMediaCount.toString()
          profileAudioRow -> profileSummaryAudioCount.toString()
          profileFilesRow -> profileSummaryFileCount.toString()
          profileLinksRow -> profileSummaryLinkCount.toString()
          else -> profileSummaryPinnedCount.toString()
        },
        iconRes = when (row) {
          profileMembersRow -> R.drawable.ic_profile_members
          profileMediaRow -> R.drawable.ic_profile_media
          profileAudioRow -> R.drawable.ic_profile_audio
          profileFilesRow -> R.drawable.ic_profile_files
          profileLinksRow -> R.drawable.ic_profile_links
          else -> R.drawable.ic_profile_pinned
        },
        showsSeparator = !isLast,
      )
    }
  }

  private fun applyProfileRowTheme(row: ChatMainProfileListRowNode, accentColor: Int) {
    row.applyTheme(
      titleColor = textColor,
      subtitleColor = secondaryTextColor,
      valueColor = secondaryTextColor,
      separatorColor = withAlpha(textColor, 0.08f),
      highlightedColor = withAlpha(textColor, 0.06f),
      iconTintColor = accentColor,
      iconBackgroundColor = withAlpha(accentColor, 0.12f),
    )
  }

  private fun containsProfileLink(text: String): Boolean {
    if (text.isBlank()) return false
    return LINK_REGEX.containsMatchIn(text)
  }

  private fun resolvedGroupMemberCount(): Int {
    val explicit = groupMemberCount ?: 0
    return if (explicit > 0) explicit else groupMemberOrder.toSet().size
  }

  private fun resolvedGroupMemberDisplayName(normalizedUserId: String): String {
    val explicit = groupMemberDisplayNameByUserId[normalizedUserId]
      ?.trim()
      ?.takeIf { it.isNotEmpty() }
    if (explicit != null) return explicit
    if (enginePeerUserId.isNotBlank() && enginePeerUserId == normalizedUserId && profileName.isNotBlank()) {
      return profileName
    }
    return if (normalizedUserId.length > 8) normalizedUserId.take(8) else normalizedUserId
  }

  private fun resolvedGroupTypingSubtitle(): String? {
    val normalizedUsers =
      groupTypingUserIds
        .map { it.uppercase(Locale.ROOT) }
        .distinct()
    if (normalizedUsers.isEmpty()) return null
    val names = normalizedUsers.map { resolvedGroupMemberDisplayName(it) }
    return when (names.size) {
      1 -> "${names[0]} typing..."
      2 -> "${names[0]} and ${names[1]} typing..."
      else -> "${names[0]}, ${names[1]} +${names.size - 2} typing..."
    }
  }

  private fun resolvedGroupMembersSubtitle(): String {
    val seen = linkedSetOf<String>()
    val orderedUserIds = mutableListOf<String>()
    groupMemberOrder.forEach { rawId ->
      val normalized = rawId.uppercase(Locale.ROOT)
      if (seen.add(normalized)) {
        orderedUserIds.add(normalized)
      }
    }
    val labels =
      orderedUserIds
        .map { resolvedGroupMemberDisplayName(it) }
        .filter { it.isNotBlank() }
    val totalCount = max(resolvedGroupMemberCount(), labels.size)
    if (labels.isEmpty()) {
      return if (totalCount > 0) "$totalCount members" else "No members"
    }
    val shown = labels.take(5)
    val suffix = if (labels.size > shown.size) " +${labels.size - shown.size}" else ""
    return "$totalCount members: ${shown.joinToString(", ")}$suffix"
  }

  private fun normalized(value: Any?): String? {
    return when (value) {
      is String -> value
      is Number -> value.toString()
      is Boolean -> value.toString()
      else -> null
    }
  }

  private fun resolveEnginePresenceSubtitle(): String? {
    if (enginePeerUserId.isBlank()) return null
    if (isOnline) return "online"
    val lastSeen = engineLastSeenTimestampMs ?: return "last seen recently"
    return formatLastSeenSubtitle(lastSeen)
  }

  private fun formatLastSeenSubtitle(timestampMs: Long): String {
    val then = Date(timestampMs)
    val timePart = DateFormat.getTimeInstance(DateFormat.SHORT).format(then)
    return if (isSameDay(then, Date())) {
      "last seen today at $timePart"
    } else {
      val datePart = DateFormat.getDateInstance(DateFormat.SHORT).format(then)
      "last seen $datePart $timePart"
    }
  }

  private fun isSameDay(a: Date, b: Date): Boolean {
    val ca = Calendar.getInstance().apply { time = a }
    val cb = Calendar.getInstance().apply { time = b }
    return ca.get(Calendar.ERA) == cb.get(Calendar.ERA)
      && ca.get(Calendar.YEAR) == cb.get(Calendar.YEAR)
      && ca.get(Calendar.DAY_OF_YEAR) == cb.get(Calendar.DAY_OF_YEAR)
  }

  private fun resolveResolvedAvatarUri(): String {
    if (headerMode == "saved_messages") return ""
    return resolveNativeAvatarUri(
      context = context,
      rawAvatar = avatarUri,
      peerUserId = enginePeerUserIdRaw,
      preferPushAvatar = !isGroupOrChannel,
    ).orEmpty()
  }

  private fun updateAvatarViews() {
    updateProfileTexts()
    val resolvedUri = resolveResolvedAvatarUri()
    if (resolvedUri.isBlank()) {
      Log.d(TAG, "updateAvatarViews avatarUri empty -> fallback")
      avatarLoadCall?.cancel()
      avatarLoadCall = null
      chatAvatarImage.setImageDrawable(null)
      profileAvatarImage.setImageDrawable(null)
      chatAvatarImage.visibility = View.GONE
      profileAvatarImage.visibility = View.GONE
      chatAvatarFallback.visibility = View.VISIBLE
      profileAvatarFallback.visibility = View.VISIBLE
      return
    }

    val token = ++avatarLoadToken
    avatarLoadCall?.cancel()

    // Note: Assuming ChatPhoenixClient has buildPinnedHttpClient(), otherwise fall back
    val request = Request.Builder()
      .url(resolvedUri)
      .get()
      .header("Accept", "image/*,*/*;q=0.8")
      .header("ngrok-skip-browser-warning", "true")
      .build()

    val call = avatarHttpClient.newCall(request)
    avatarLoadCall = call
    call.enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        // Fallback already visible
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
            chatAvatarImage.setImageBitmap(bitmap)
            profileAvatarImage.setImageBitmap(bitmap)
            chatAvatarImage.visibility = View.VISIBLE
            profileAvatarImage.visibility = View.VISIBLE
            chatAvatarFallback.visibility = View.GONE
            profileAvatarFallback.visibility = View.GONE
          }
        }
      }
    })
  }

  private fun applyPageState(animated: Boolean, emitEvent: Boolean) {
    val widthF = max(width.toFloat(), resources.displayMetrics.widthPixels.toFloat())
    val goingProfile = currentPage == "profile"
    Log.i(
      TAG,
      "applyPageState page=$currentPage animated=$animated width=$width height=$height resolvedWidth=$widthF",
    )
    val chatTargetX = if (goingProfile) -widthF * 0.18f else 0f
    val chatTargetAlpha = if (goingProfile) 0f else 1f
    val profileTargetX = 0f
    val profileStartX = widthF * 0.22f
    val profileTargetAlpha = if (goingProfile) 1f else 0f

    chatPage.visibility = View.VISIBLE
    profilePage.visibility = View.VISIBLE
    if (goingProfile && profilePage.alpha < 0.01f) {
      profilePage.translationX = profileStartX
    }

    val applyFinalState = {
      chatPage.translationX = chatTargetX
      chatPage.alpha = chatTargetAlpha
      profilePage.translationX = profileTargetX
      profilePage.alpha = profileTargetAlpha
    }

    if (animated) {
      chatPage.animate().cancel()
      profilePage.animate().cancel()
      chatPage.animate()
        .translationX(chatTargetX)
        .alpha(chatTargetAlpha)
        .setDuration(PAGE_ANIMATION_DURATION_MS)
        .start()
      profilePage.animate()
        .translationX(profileTargetX)
        .alpha(profileTargetAlpha)
        .setDuration(PAGE_ANIMATION_DURATION_MS)
        .withEndAction {
          if (currentPage == "chat") {
            profilePage.visibility = View.GONE
            chatPage.visibility = View.VISIBLE
          } else {
            chatPage.visibility = View.INVISIBLE
            profilePage.visibility = View.VISIBLE
          }
          ensureVisiblePageState("animation-end")
        }
        .start()
      postDelayed({ ensureVisiblePageState("animation-watchdog") }, PAGE_STATE_WATCHDOG_DELAY_MS)
    } else {
      applyFinalState()
      if (currentPage == "chat") {
        profilePage.visibility = View.GONE
        chatPage.visibility = View.VISIBLE
      } else {
        chatPage.visibility = View.INVISIBLE
        profilePage.visibility = View.VISIBLE
      }
      ensureVisiblePageState("no-animation")
    }

    if (emitEvent) {
      onNativeEvent(
        mapOf(
          "type" to "mainPageChanged",
          "page" to currentPage,
        ),
      )
    }
  }

  private fun ensureVisiblePageState(reason: String) {
    val shouldShowProfile = currentPage == "profile"
    val expectedChatVisibility = if (shouldShowProfile) View.INVISIBLE else View.VISIBLE
    val expectedProfileVisibility = if (shouldShowProfile) View.VISIBLE else View.GONE
    val expectedChatAlpha = if (shouldShowProfile) 0f else 1f
    val expectedProfileAlpha = if (shouldShowProfile) 1f else 0f
    val expectedChatTranslationX = if (shouldShowProfile) -max(width.toFloat(), resources.displayMetrics.widthPixels.toFloat()) * 0.18f else 0f
    val expectedProfileTranslationX = 0f

    var repaired = false

    if (chatPage.visibility != expectedChatVisibility) {
      chatPage.visibility = expectedChatVisibility
      repaired = true
    }
    if (profilePage.visibility != expectedProfileVisibility) {
      profilePage.visibility = expectedProfileVisibility
      repaired = true
    }
    if (abs(chatPage.alpha - expectedChatAlpha) > 0.02f) {
      chatPage.alpha = expectedChatAlpha
      repaired = true
    }
    if (abs(profilePage.alpha - expectedProfileAlpha) > 0.02f) {
      profilePage.alpha = expectedProfileAlpha
      repaired = true
    }
    if (abs(chatPage.translationX - expectedChatTranslationX) > 1f) {
      chatPage.translationX = expectedChatTranslationX
      repaired = true
    }
    if (abs(profilePage.translationX - expectedProfileTranslationX) > 1f) {
      profilePage.translationX = expectedProfileTranslationX
      repaired = true
    }

    if (repaired) {
      Log.w(
        TAG,
        "ensureVisiblePageState repaired reason=$reason page=$currentPage chatVisible=${chatPage.visibility} chatAlpha=${"%.2f".format(chatPage.alpha)} profileVisible=${profilePage.visibility} profileAlpha=${"%.2f".format(profilePage.alpha)}",
      )
      return
    }

    if (reason == "attach-post" || reason == "animation-watchdog") {
      Log.d(
        TAG,
        "ensureVisiblePageState ok reason=$reason page=$currentPage chatVisible=${chatPage.visibility} profileVisible=${profilePage.visibility}",
      )
    }
  }

  private fun styleHeaderActionButton(view: ImageView, drawableRes: Int) {
    view.scaleType = ImageView.ScaleType.CENTER_INSIDE
    view.setImageResource(drawableRes)
    view.setPadding(dp(9), dp(9), dp(9), dp(9))
    setTouchAlphaPress(view)
  }

  private fun updateProfileActionState() {
    if (isChatMuted) {
      profileMuteAction.setIcon(android.R.drawable.ic_lock_silent_mode_off)
      profileMuteAction.setTitle("Unmute")
    } else {
      profileMuteAction.setIcon(android.R.drawable.ic_lock_silent_mode)
      profileMuteAction.setTitle("Mute")
    }
  }

  private fun isSavedMessagesHeaderMode(): Boolean {
    return headerMode == "savedmessages"
  }

  private fun updateChatHeaderControls() {
    val savedMessagesMode = isSavedMessagesHeaderMode()
    chatVideoButton.visibility = if (savedMessagesMode) View.GONE else View.VISIBLE
    chatPhoneButton.visibility = if (savedMessagesMode) View.GONE else View.VISIBLE
    chatSearchButton.visibility = if (savedMessagesMode) View.VISIBLE else View.GONE
    chatAvatarButton.visibility = if (savedMessagesMode) View.GONE else View.VISIBLE
    chatProfileGroup.isClickable = !savedMessagesMode
    chatProfileGroup.isFocusable = !savedMessagesMode
    chatProfileGroup.alpha = if (savedMessagesMode) 1f else 1f
  }

  private fun setTouchAlphaPress(view: View) {
    view.setOnTouchListener { v, event ->
      when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> v.alpha = 0.72f
        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_OUTSIDE -> v.alpha = 1f
      }
      false
    }
  }

  private fun markPendingNativePageChange(page: String) {
    pendingNativePageTarget = page
    pendingNativePageLockUntilMs = System.currentTimeMillis() + 2000L
  }

  private fun colorFromAny(raw: Any?): Int? {
    return when (raw) {
      is Int -> raw
      is Number -> raw.toInt()
      is String -> {
        val trimmed = raw.trim()
        if (trimmed.isBlank()) return null
        val hexFormat = if (trimmed.startsWith("#") && trimmed.length == 4) {
          "#" + trimmed[1] + trimmed[1] + trimmed[2] + trimmed[2] + trimmed[3] + trimmed[3]
        } else {
          trimmed
        }
        try {
          Color.parseColor(hexFormat)
        } catch (_: Throwable) {
          null
        }
      }
      else -> null
    }
  }

  private fun contrastForegroundFor(background: Int): Int {
    val luminance =
      (0.299 * Color.red(background) + 0.587 * Color.green(background) + 0.114 * Color.blue(background)) / 255.0
    return if (luminance > 0.62) Color.BLACK else Color.WHITE
  }

  private fun resolveHeaderActionColor(): Int {
    return textColor
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

  private fun statusBarHeightPx(): Int {
    val id = resources.getIdentifier("status_bar_height", "dimen", "android")
    return if (id > 0) resources.getDimensionPixelSize(id) else 0
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).toInt()
  }

  private fun dpF(value: Float): Float {
    return value * resources.displayMetrics.density
  }
}
