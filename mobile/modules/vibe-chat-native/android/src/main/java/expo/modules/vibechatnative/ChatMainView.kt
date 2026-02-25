package expo.modules.vibechatnative

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ScrollView
import android.widget.TextView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import java.text.DateFormat
import java.net.URL
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.max

class ChatMainView(
  context: Context,
  appContext: AppContext,
) : ExpoView(context, appContext) {
  private val onViewportChanged by EventDispatcher<Map<String, Any>>()
  private val onNativeEvent by EventDispatcher<Map<String, Any>>()

  private val chatListView = ChatListView(context, appContext)

  private val pagesHost = FrameLayout(context)
  private val chatPage = LinearLayout(context)
  private val profilePage = LinearLayout(context)

  private val chatHeader = LinearLayout(context)
  private val chatHeaderLeft = LinearLayout(context)
  private val chatHeaderRight = LinearLayout(context)
  private val chatProfileGroup = LinearLayout(context)
  private val chatTextGroup = LinearLayout(context)
  private val chatTitleView = TextView(context)
  private val chatSubtitleView = TextView(context)
  private val chatBackButton = TextView(context)
  private val chatAvatarButton = FrameLayout(context)
  private val chatAvatarImage = ImageView(context)
  private val chatAvatarFallback = TextView(context)
  private val chatVideoButton = ImageView(context)
  private val chatPhoneButton = ImageView(context)
  private val chatSearchButton = ImageView(context)
  private val chatMenuButton = ImageView(context)

  private val profileHeader = FrameLayout(context)
  private val profileBackButton = TextView(context)
  private val profileHeaderTitle = TextView(context)

  private val profileScroll = ScrollView(context)
  private val profileContent = LinearLayout(context)
  private val profileHeroAvatar = FrameLayout(context)
  private val profileAvatarImage = ImageView(context)
  private val profileAvatarFallback = TextView(context)
  private val profileNameView = TextView(context)
  private val profileHandleView = TextView(context)
  private val profileBioView = TextView(context)
  private val profileInfoCard = LinearLayout(context)
  private val profileInfoTitle = TextView(context)
  private val profileInfoSubtitle = TextView(context)

  private var surfaceId: String = ""
  private var headerTitle: String = "Chat"
  private var headerSubtitle: String = ""
  private var profileName: String = "User"
  private var profileHandle: String = ""
  private var profileBio: String = ""
  private var avatarUri: String = ""
  private var isOnline: Boolean = false
  private var isChatMuted: Boolean = false
  private var engineChatId: String = ""
  private var enginePeerUserId: String = ""
  private var engineLastSeenTimestampMs: Long? = null
  private var profileSummaryMessageCount = 0
  private var profileSummaryMediaCount = 0
  private var profileSummaryFileCount = 0
  private var profileSummaryLinkCount = 0
  private var profileSummaryRecentFiles: List<String> = emptyList()
  private var profileSummaryHistoryLoaded = false
  private var currentPage: String = "chat"
  private var pendingNativePageTarget: String? = null
  private var pendingNativePageLockUntilMs: Long = 0L
  private var avatarLoadToken = 0
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
  }

  override fun onDetachedFromWindow() {
    ChatEngine.setListener(engineListenerId, null)
    if (surfaceId.isNotBlank()) {
      ChatMainRegistry.unregister(surfaceId)
    }
    super.onDetachedFromWindow()
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    registerChatEngineListener()
    refreshPresenceFromEngine(force = true)
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
  }

  fun setRows(rows: List<Map<String, Any?>>) {
    chatListView.setRows(rows)
  }

  fun setEngineSurfaceId(value: String) {
    chatListView.setEngineSurfaceId(value)
  }

  fun setEngineChatId(value: String) {
    engineChatId = value.trim()
    chatListView.setEngineChatId(value)
    registerChatEngineListener()
    refreshProfileSummaryFromEngine(force = true)
  }

  fun setEngineMyUserId(value: String) {
    chatListView.setEngineMyUserId(value)
  }

  fun setEnginePeerUserId(value: String) {
    enginePeerUserId = value.trim().uppercase(Locale.ROOT)
    chatListView.setEnginePeerUserId(value)
    if (enginePeerUserId.isBlank()) {
      engineLastSeenTimestampMs = null
      updateHeaderTexts()
      updateProfileTexts()
      return
    }
    registerChatEngineListener()
    refreshPresenceFromEngine(force = true)
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
  }

  fun setPage(value: String, animated: Boolean) {
    val next = if (value.trim().lowercase() == "profile") "profile" else "chat"
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
      ChatEngine.setListener(engineListenerId, null)
      return
    }
    ChatEngine.setListener(engineListenerId) { _, _, _ ->
      post {
        refreshPresenceFromEngine()
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

    chatBackButton.text = "‹"
    chatBackButton.gravity = Gravity.CENTER
    chatBackButton.textSize = 27f
    chatBackButton.typeface = Typeface.DEFAULT_BOLD
    chatBackButton.setPadding(0, 0, dp(1), 0)
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
      if (currentPage != "chat") return@setOnClickListener
      markPendingNativePageChange("profile")
      currentPage = "profile"
      applyPageState(animated = true, emitEvent = true)
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

    chatAvatarFallback.gravity = Gravity.CENTER
    chatAvatarFallback.setTypeface(Typeface.DEFAULT_BOLD)
    chatAvatarFallback.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
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

    styleHeaderActionButton(chatSearchButton, android.R.drawable.ic_menu_search)
    chatSearchButton.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerSearchPressed"))
    }

    styleHeaderActionButton(chatMenuButton, android.R.drawable.ic_menu_more)
    chatMenuButton.setOnClickListener {
      showHeaderMenu()
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
    chatHeaderRight.addView(
      chatMenuButton,
      LinearLayout.LayoutParams(dp(40), dp(40)),
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
    profileHeader.setPadding(dp(12), statusTop, dp(12), 0)
    profilePage.addView(profileHeader)

    profileBackButton.text = "‹"
    profileBackButton.gravity = Gravity.CENTER
    profileBackButton.textSize = 30f
    profileBackButton.typeface = Typeface.DEFAULT_BOLD
    profileBackButton.setOnClickListener {
      markPendingNativePageChange("chat")
      currentPage = "chat"
      applyPageState(animated = true, emitEvent = true)
    }
    profileHeader.addView(
      profileBackButton,
      FrameLayout.LayoutParams(dp(44), dp(44), Gravity.START or Gravity.CENTER_VERTICAL),
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
        Gravity.CENTER,
      ),
    )

    profileScroll.overScrollMode = View.OVER_SCROLL_ALWAYS
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

    profileAvatarFallback.gravity = Gravity.CENTER
    profileAvatarFallback.setTypeface(Typeface.DEFAULT_BOLD)
    profileAvatarFallback.setTextSize(TypedValue.COMPLEX_UNIT_SP, 36f)
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
    profileContent.addView(
      profileBioView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileInfoCard.orientation = LinearLayout.VERTICAL
    profileInfoCard.background = roundedShape(surfaceColor, dp(20))
    profileInfoCard.setPadding(dp(16), dp(14), dp(16), dp(14))
    val cardParams = LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      LinearLayout.LayoutParams.WRAP_CONTENT,
    )
    cardParams.topMargin = dp(22)
    profileContent.addView(profileInfoCard, cardParams)

    profileInfoTitle.setTypeface(Typeface.DEFAULT_BOLD)
    profileInfoTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
    profileInfoTitle.text = "Profile"
    profileInfoCard.addView(
      profileInfoTitle,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    profileInfoSubtitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    profileInfoSubtitle.text = "Native profile page hosted with native chat for instant transitions."
    profileInfoSubtitle.setPadding(0, dp(6), 0, 0)
    profileInfoCard.addView(
      profileInfoSubtitle,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
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
    chatHeader.setBackgroundColor(withAlpha(headerBackgroundColor, 0.95f))
    profileHeader.background = roundedShape(withAlpha(surfaceColor, 0.84f), dp(20))
    profilePage.setBackgroundColor(profileBackgroundColor)
    profileInfoCard.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(20))
    profileHeroAvatar.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(59))
    chatAvatarButton.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(19))

    chatBackButton.setTextColor(textColor)
    chatVideoButton.setColorFilter(textColor)
    chatPhoneButton.setColorFilter(textColor)
    chatSearchButton.setColorFilter(textColor)
    chatMenuButton.setColorFilter(textColor)
    profileBackButton.setTextColor(textColor)
    chatTitleView.setTextColor(textColor)
    chatSubtitleView.setTextColor(if (isOnline) Color.parseColor("#53E08A") else secondaryTextColor)
    profileHeaderTitle.setTextColor(textColor)
    chatAvatarFallback.setTextColor(textColor)
    profileAvatarFallback.setTextColor(textColor)
    profileNameView.setTextColor(textColor)
    profileHandleView.setTextColor(if (isOnline) Color.parseColor("#53E08A") else secondaryTextColor)
    profileBioView.setTextColor(secondaryTextColor)
    profileInfoTitle.setTextColor(textColor)
    profileInfoSubtitle.setTextColor(secondaryTextColor)
  }

  private fun updateHeaderTexts() {
    val resolvedTitle = if (headerTitle.isBlank()) "Chat" else headerTitle
    val engineSubtitle = resolveEnginePresenceSubtitle()
    val jsSubtitle = headerSubtitle.trim()
    val jsSubtitleLower = jsSubtitle.lowercase(Locale.ROOT)
    val resolvedSubtitle =
      engineSubtitle
        ?: if (isOnline && (jsSubtitle.isBlank() || jsSubtitleLower.startsWith("last seen") || jsSubtitleLower == "offline")) {
          "online"
        } else {
          jsSubtitle
        }
    chatTitleView.text = resolvedTitle
    chatSubtitleView.text = resolvedSubtitle
    applyTheme()
  }

  private fun updateProfileTexts() {
    val resolvedTitle = if (profileName.isBlank()) if (headerTitle.isBlank()) "User" else headerTitle else profileName
    profileNameView.text = resolvedTitle
    val fallbackHandle = resolveEnginePresenceSubtitle() ?: if (isOnline) "online" else "offline"
    profileHandleView.text = if (profileHandle.isBlank()) fallbackHandle else profileHandle
    profileBioView.text =
      if (profileBio.isBlank()) "Shared media, links and pinned messages will appear here." else profileBio
    val initial = resolvedTitle.trim().firstOrNull()?.uppercase() ?: "U"
    chatAvatarFallback.text = initial
    profileAvatarFallback.text = initial
    profileInfoTitle.text = "Shared Content"
    profileInfoSubtitle.text =
      if (profileSummaryHistoryLoaded) {
        val base =
          "Media $profileSummaryMediaCount • Files $profileSummaryFileCount • Links $profileSummaryLinkCount\n$profileSummaryMessageCount cached messages available natively."
        if (profileSummaryRecentFiles.isNotEmpty()) {
          "$base\nRecent files: ${profileSummaryRecentFiles.joinToString(", ")}"
        } else {
          base
        }
      } else {
        "Loading shared media and files from native encrypted cache..."
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

  private fun updateAvatarViews() {
    updateProfileTexts()
    if (avatarUri.isBlank()) {
      chatAvatarImage.setImageDrawable(null)
      profileAvatarImage.setImageDrawable(null)
      chatAvatarImage.visibility = View.GONE
      profileAvatarImage.visibility = View.GONE
      chatAvatarFallback.visibility = View.VISIBLE
      profileAvatarFallback.visibility = View.VISIBLE
      return
    }

    val parsed = try {
      Uri.parse(avatarUri)
    } catch (_: Throwable) {
      null
    }
    if (parsed == null || parsed.toString().isBlank()) {
      return
    }

    val token = ++avatarLoadToken
    Thread {
      try {
        val bmp = URL(parsed.toString()).openStream().use { BitmapFactory.decodeStream(it) } ?: return@Thread
        post {
          if (token != avatarLoadToken) return@post
          chatAvatarImage.setImageBitmap(bmp)
          profileAvatarImage.setImageBitmap(bmp)
          chatAvatarImage.visibility = View.VISIBLE
          profileAvatarImage.visibility = View.VISIBLE
          chatAvatarFallback.visibility = View.GONE
          profileAvatarFallback.visibility = View.GONE
        }
      } catch (_: Throwable) {
        // Fallback already visible.
      }
    }.start()
  }

  private fun applyPageState(animated: Boolean, emitEvent: Boolean) {
    val widthF = max(width.toFloat(), resources.displayMetrics.widthPixels.toFloat())
    val goingProfile = currentPage == "profile"
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
        .setDuration(260L)
        .start()
      profilePage.animate()
        .translationX(profileTargetX)
        .alpha(profileTargetAlpha)
        .setDuration(260L)
        .withEndAction {
          if (currentPage == "chat") {
            profilePage.visibility = View.GONE
            chatPage.visibility = View.VISIBLE
          } else {
            chatPage.visibility = View.INVISIBLE
            profilePage.visibility = View.VISIBLE
          }
        }
        .start()
    } else {
      applyFinalState()
      if (currentPage == "chat") {
        profilePage.visibility = View.GONE
        chatPage.visibility = View.VISIBLE
      } else {
        chatPage.visibility = View.INVISIBLE
        profilePage.visibility = View.VISIBLE
      }
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

  private fun showHeaderMenu() {
    if (currentPage != "chat") return
    val popup = PopupMenu(context, chatMenuButton)
    val muteTitle = if (isChatMuted) "Unmute" else "Mute"
    popup.menu.add(0, 1, 0, muteTitle)
    popup.menu.add(0, 2, 1, "Clear Chat")
    popup.menu.add(0, 3, 2, "Block User")
    popup.setOnMenuItemClickListener { item ->
      when (item.itemId) {
        1 -> onNativeEvent(mapOf("type" to "headerMenuAction", "action" to "muteToggle"))
        2 -> onNativeEvent(mapOf("type" to "headerMenuAction", "action" to "clearChat"))
        3 -> onNativeEvent(mapOf("type" to "headerMenuAction", "action" to "blockUser"))
      }
      true
    }
    popup.show()
  }

  private fun styleHeaderActionButton(view: ImageView, drawableRes: Int) {
    view.scaleType = ImageView.ScaleType.CENTER_INSIDE
    view.setImageResource(drawableRes)
    view.setPadding(dp(9), dp(9), dp(9), dp(9))
    setTouchAlphaPress(view)
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
        try {
          Color.parseColor(trimmed)
        } catch (_: Throwable) {
          null
        }
      }
      else -> null
    }
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
