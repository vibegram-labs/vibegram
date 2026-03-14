package expo.modules.vibechatnative

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PorterDuff
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import java.net.URL
import java.util.Locale

class ChatProfileMainView(
  context: Context,
  appContext: AppContext,
) : ExpoView(context, appContext) {
  override val shouldUseAndroidLayout: Boolean = true

  companion object {
    private const val PROFILE_HEADER_COLLAPSE_DISTANCE_DP = 120f
    private val LINK_REGEX = Regex("""https?://\S+|www\.\S+""", RegexOption.IGNORE_CASE)
  }

  private val onViewportChanged by EventDispatcher<Map<String, Any>>()
  private val onNativeEvent by EventDispatcher<Map<String, Any>>()

  private val headerContainer = FrameLayout(context)
  private val headerGlass = LiquidGlassView(context, appContext)
  private val backButton = ImageView(context)
  private val headerTitleView = TextView(context)
  private val headerNameView = TextView(context)

  private val scrollView = ScrollView(context)
  private val contentView = LinearLayout(context)
  private val heroAvatar = FrameLayout(context)
  private val avatarImage = ImageView(context)
  private val avatarFallback = ImageView(context)
  private val nameView = TextView(context)
  private val handleView = TextView(context)
  private val bioView = TextView(context)

  private val actionsRow = LinearLayout(context)
  private val muteAction = ChatMainProfileActionNode(context)
  private val searchAction = ChatMainProfileActionNode(context)
  private val audioAction = ChatMainProfileActionNode(context)
  private val videoAction = ChatMainProfileActionNode(context)

  private val infoCard = LinearLayout(context)
  private val infoTitleView = TextView(context)
  private val membersRow = ChatMainProfileListRowNode(context)
  private val mediaRow = ChatMainProfileListRowNode(context)
  private val audioRow = ChatMainProfileListRowNode(context)
  private val filesRow = ChatMainProfileListRowNode(context)
  private val linksRow = ChatMainProfileListRowNode(context)
  private val pinnedRow = ChatMainProfileListRowNode(context)

  private var surfaceId = ""
  private var headerTitle = "Profile"
  private var headerSubtitle = ""
  private var profileName = "User"
  private var profileHandle = ""
  private var profileBio = ""
  private var avatarUri = ""
  private var isOnline = false
  private var isChatMuted = false
  private var isGroupOrChannel = false
  private var groupMemberCount: Int? = null
  private var groupMemberDisplayNameByUserId: LinkedHashMap<String, String> = linkedMapOf()
  private var groupMemberOrder: MutableList<String> = mutableListOf()
  private var engineChatId = ""
  private var enginePeerUserIdRaw = ""
  private var enginePeerUserId = ""
  private var avatarLoadToken = 0
  private val avatarHttpClient by lazy { ChatPhoenixClient.buildPinnedHttpClient() }
  private var avatarLoadCall: okhttp3.Call? = null

  private var sharedMediaCount = 0
  private var sharedAudioCount = 0
  private var sharedFileCount = 0
  private var sharedLinkCount = 0
  private var sharedPinnedCount = 0

  private var textColor: Int = Color.WHITE
  private var secondaryTextColor: Int = Color.argb(220, 220, 220, 220)
  private var surfaceColor: Int = Color.argb(235, 20, 22, 28)
  private var headerBackgroundColor: Int = Color.argb(242, 16, 18, 24)
  private var profileBackgroundColor: Int = Color.argb(255, 16, 18, 24)

  init {
    orientation = VERTICAL
    setBackgroundColor(profileBackgroundColor)
    configureView()
    applyTheme()
    updateProfileTexts()
    updateAvatarViews()
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    if (w <= 0 || h <= 0) return
    onViewportChanged(
      mapOf(
        "width" to w,
        "height" to h,
        "surfaceId" to surfaceId,
      ),
    )
  }

  fun setProfileOnly(value: Boolean) {
  }

  fun setSurfaceId(value: String) {
    surfaceId = value.trim()
  }

  fun setRows(rows: List<Map<String, Any?>>) {
    rebuildProfileSummaryFromRows(rows)
    updateProfileTexts()
  }

  fun setEngineSurfaceId(value: String) {
  }

  fun setEngineChatId(value: String) {
    engineChatId = value.trim()
  }

  fun setEngineMyUserId(value: String) {
  }

  fun setEnginePeerUserId(value: String) {
    enginePeerUserIdRaw = value.trim()
    enginePeerUserId = enginePeerUserIdRaw.uppercase(Locale.ROOT)
    updateProfileTexts()
    updateAvatarViews()
  }

  fun setStatusAuthorityEnabled(enabled: Boolean) {
  }

  fun setAppearance(rawAppearance: Map<String, Any?>) {
    parseAppearance(rawAppearance)
    applyTheme()
    updateProfileTexts()
  }

  fun setHeaderTitle(value: String) {
    headerTitle = value.trim().ifBlank { "Profile" }
    updateProfileTexts()
  }

  fun setHeaderSubtitle(value: String) {
    headerSubtitle = value.trim()
    updateProfileTexts()
  }

  fun setProfileName(value: String) {
    profileName = value.trim()
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
    isOnline = value
    applyTheme()
    updateProfileTexts()
  }

  fun setIsChatMuted(value: Boolean) {
    if (isChatMuted == value) return
    isChatMuted = value
    updateProfileActionState()
  }

  fun setIsGroupOrChannel(value: Boolean) {
    isGroupOrChannel = value
    applyTheme()
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
    updateProfileTexts()
  }

  fun setGroupMemberCount(value: Int?) {
    groupMemberCount = value?.coerceAtLeast(0)
    updateProfileTexts()
  }

  fun setAgentConfig(value: Map<String, Any?>?) {
  }

  fun setPage(value: String, animated: Boolean) {
  }

  private fun configureView() {
    val statusTop = statusBarHeightPx()

    headerContainer.layoutParams = LayoutParams(
      LayoutParams.MATCH_PARENT,
      statusTop + dp(56),
    )
    addView(headerContainer)

    headerGlass.alpha = 0f
    headerGlass.setCornerRadius(20.0)
    headerGlass.setBlurIntensity(14.0)
    headerGlass.setInteractive(false)
    headerGlass.setPressFeedbackEnabled(false)
    headerContainer.addView(
      headerGlass,
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

    backButton.scaleType = ImageView.ScaleType.CENTER_INSIDE
    backButton.setImageResource(R.drawable.ic_chevron_left)
    backButton.setPadding(dp(10), dp(10), dp(10), dp(10))
    backButton.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerBack"))
    }
    headerContainer.addView(
      backButton,
      FrameLayout.LayoutParams(dp(44), dp(44), Gravity.START or Gravity.BOTTOM).apply {
        marginStart = dp(12)
        bottomMargin = dp(6)
      },
    )

    headerTitleView.setTypeface(Typeface.DEFAULT_BOLD)
    headerTitleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    headerTitleView.text = "Profile"
    headerTitleView.gravity = Gravity.CENTER
    headerContainer.addView(
      headerTitleView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM,
      ).apply {
        bottomMargin = dp(18)
      },
    )

    headerNameView.setTypeface(Typeface.DEFAULT_BOLD)
    headerNameView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    headerNameView.gravity = Gravity.CENTER
    headerNameView.alpha = 0f
    headerContainer.addView(
      headerNameView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM,
      ).apply {
        bottomMargin = dp(18)
      },
    )

    scrollView.overScrollMode = View.OVER_SCROLL_ALWAYS
    scrollView.isFillViewport = true
    scrollView.setOnScrollChangeListener { _, _, scrollY, _, _ ->
      updateProfileHeaderChrome(scrollY)
    }
    addView(
      scrollView,
      LayoutParams(
        LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )

    contentView.orientation = LinearLayout.VERTICAL
    contentView.gravity = Gravity.CENTER_HORIZONTAL
    contentView.setPadding(dp(20), dp(24), dp(20), dp(32))
    scrollView.addView(
      contentView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    heroAvatar.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(59))
    heroAvatar.clipToOutline = true
    contentView.addView(
      heroAvatar,
      LinearLayout.LayoutParams(dp(118), dp(118)),
    )

    avatarImage.scaleType = ImageView.ScaleType.CENTER_CROP
    avatarImage.visibility = View.GONE
    heroAvatar.addView(
      avatarImage,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    avatarFallback.scaleType = ImageView.ScaleType.FIT_CENTER
    avatarFallback.setImageResource(R.drawable.ic_avatar_person)
    avatarFallback.setPadding(dp(32), dp(32), dp(32), dp(32))
    heroAvatar.addView(
      avatarFallback,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    nameView.setTypeface(Typeface.DEFAULT_BOLD)
    nameView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
    nameView.gravity = Gravity.CENTER
    nameView.setPadding(0, dp(14), 0, 0)
    contentView.addView(
      nameView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    handleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
    handleView.gravity = Gravity.CENTER
    handleView.setPadding(0, dp(2), 0, 0)
    contentView.addView(
      handleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    bioView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    bioView.gravity = Gravity.CENTER
    bioView.setLineSpacing(dpF(2f), 1f)
    bioView.setPadding(dp(8), dp(12), dp(8), 0)
    bioView.visibility = View.GONE
    contentView.addView(
      bioView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    actionsRow.orientation = LinearLayout.HORIZONTAL
    actionsRow.gravity = Gravity.CENTER
    actionsRow.setPadding(0, dp(18), 0, 0)
    contentView.addView(
      actionsRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    muteAction.configure(
      title = "Mute",
      iconRes = android.R.drawable.ic_lock_silent_mode,
    )
    muteAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerMenuAction", "action" to "muteToggle"))
    }
    actionsRow.addView(
      muteAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply { marginEnd = dp(6) },
    )

    searchAction.configure(
      title = "Search",
      iconRes = R.drawable.ic_search,
    )
    searchAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerSearchPressed"))
    }
    actionsRow.addView(
      searchAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply {
        marginStart = dp(2)
        marginEnd = dp(2)
      },
    )

    audioAction.configure(
      title = "Call",
      iconRes = R.drawable.ic_call_accept,
    )
    audioAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerAudioCallPressed"))
    }
    actionsRow.addView(
      audioAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply {
        marginStart = dp(2)
        marginEnd = dp(2)
      },
    )

    videoAction.configure(
      title = "Video",
      iconRes = R.drawable.ic_video,
    )
    videoAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerVideoCallPressed"))
    }
    actionsRow.addView(
      videoAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply { marginStart = dp(6) },
    )

    infoCard.orientation = LinearLayout.VERTICAL
    infoCard.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(24))
    infoCard.clipToOutline = true
    contentView.addView(
      infoCard,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(18)
      },
    )

    infoTitleView.setTypeface(Typeface.DEFAULT_BOLD)
    infoTitleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    infoTitleView.setPadding(dp(18), dp(16), dp(18), dp(8))
    infoCard.addView(
      infoTitleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    membersRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileMembersPressed", "chatId" to engineChatId))
    }
    infoCard.addView(
      membersRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    mediaRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "media", "chatId" to engineChatId))
    }
    infoCard.addView(
      mediaRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    audioRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "music", "chatId" to engineChatId))
    }
    infoCard.addView(
      audioRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    filesRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "files", "chatId" to engineChatId))
    }
    infoCard.addView(
      filesRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    linksRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "links", "chatId" to engineChatId))
    }
    infoCard.addView(
      linksRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    pinnedRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileContentSectionPressed", "section" to "pinned", "chatId" to engineChatId))
    }
    infoCard.addView(
      pinnedRow,
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
    setBackgroundColor(profileBackgroundColor)
    headerContainer.setBackgroundColor(Color.TRANSPARENT)
    headerGlass.setTintColor(withAlpha(surfaceColor, 0.88f))
    headerGlass.setBorderEnabled(true)
    headerGlass.setShadowEnabled(true)
    val isHeaderDark = contrastForegroundFor(profileBackgroundColor) == Color.WHITE
    val softRgba = if (isHeaderDark) Color.argb(20, 248, 246, 252) else Color.argb(13, 26, 26, 31)

    heroAvatar.background = roundedShape(softRgba, dp(59))
    infoCard.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(24))

    backButton.setColorFilter(textColor, PorterDuff.Mode.SRC_IN)
    headerTitleView.setTextColor(textColor)
    headerNameView.setTextColor(textColor)
    avatarFallback.setColorFilter(textColor, PorterDuff.Mode.SRC_IN)
    nameView.setTextColor(textColor)
    handleView.setTextColor(if (isOnline && !isGroupOrChannel) Color.parseColor("#53E08A") else secondaryTextColor)
    bioView.setTextColor(secondaryTextColor)
    infoTitleView.setTextColor(textColor)

    listOf(muteAction, searchAction, audioAction, videoAction).forEach { action ->
      action.applyTheme(
        foreground = textColor,
        background = withAlpha(surfaceColor, 0.92f),
      )
    }

    applyProfileRowTheme(membersRow, Color.parseColor("#3B82F6"))
    applyProfileRowTheme(mediaRow, Color.parseColor("#EC4899"))
    applyProfileRowTheme(audioRow, Color.parseColor("#10B981"))
    applyProfileRowTheme(filesRow, Color.parseColor("#6366F1"))
    applyProfileRowTheme(linksRow, Color.parseColor("#F59E0B"))
    applyProfileRowTheme(pinnedRow, Color.parseColor("#F97316"))
    updateProfileActionState()
    updateProfileHeaderChrome(scrollView.scrollY)
  }

  private fun updateProfileTexts() {
    val resolvedTitle = profileName.ifBlank { headerTitle.ifBlank { "User" } }
    val resolvedHandle = when {
      profileHandle.isNotBlank() -> profileHandle
      isGroupOrChannel -> {
        val count = resolvedGroupMemberCount()
        if (count > 0) "$count members" else "group chat"
      }
      isOnline -> "online"
      headerSubtitle.isNotBlank() -> headerSubtitle
      else -> if (enginePeerUserId.isNotBlank()) "offline" else ""
    }

    val resolvedBio = profileBio.takeIf { it.isNotBlank() }.orEmpty()
    headerNameView.text = resolvedTitle
    nameView.text = resolvedTitle
    handleView.text = resolvedHandle
    bioView.text = resolvedBio
    bioView.visibility = if (resolvedBio.isBlank()) View.GONE else View.VISIBLE

    infoTitleView.text = if (isGroupOrChannel) "Overview" else "Shared Content"
    configureProfileSummaryRows()
    updateProfileHeaderChrome(scrollView.scrollY)
  }

  private fun updateProfileHeaderChrome(scrollY: Int) {
    val progress = (scrollY / dpF(PROFILE_HEADER_COLLAPSE_DISTANCE_DP)).coerceIn(0f, 1f)
    headerGlass.alpha = progress
    headerGlass.translationY = dpF(6f) * (1f - progress)
    headerTitleView.alpha = 1f - progress
    headerTitleView.translationY = -dpF(8f) * progress
    headerNameView.alpha = progress
    headerNameView.translationY = dpF(8f) * (1f - progress)
    headerContainer.elevation = dpF(6f) * progress
  }

  private fun rebuildProfileSummaryFromRows(rows: List<Map<String, Any?>>) {
    var mediaCount = 0
    var audioCount = 0
    var fileCount = 0
    var linkCount = 0
    var pinnedCount = 0

    rows.forEach { row ->
      if (normalized(row["kind"]) != "message") return@forEach
      val message = row["message"] as? Map<*, *> ?: return@forEach
      val type = normalized(message["type"])?.lowercase(Locale.ROOT).orEmpty()
      val text = normalized(message["text"]).orEmpty()
      val mediaUrl = normalized(message["mediaUrl"]).orEmpty()
      val isPinned = (message["isPinned"] as? Boolean) == true

      if (type == "image" || type == "gif" || type == "video" || type == "sticker") {
        mediaCount += 1
      }
      if (type == "music") {
        audioCount += 1
      }
      if (type == "file") {
        fileCount += 1
      }
      if (containsProfileLink(text) || containsProfileLink(mediaUrl)) {
        linkCount += 1
      }
      if (isPinned) {
        pinnedCount += 1
      }
    }

    sharedMediaCount = mediaCount
    sharedAudioCount = audioCount
    sharedFileCount = fileCount
    sharedLinkCount = linkCount
    sharedPinnedCount = pinnedCount
  }

  private fun configureProfileSummaryRows() {
    val visibleRows = mutableListOf<ChatMainProfileListRowNode>()

    membersRow.visibility = if (isGroupOrChannel) View.VISIBLE else View.GONE
    if (membersRow.visibility == View.VISIBLE) {
      visibleRows.add(membersRow)
    }
    visibleRows.add(mediaRow)
    visibleRows.add(audioRow)
    visibleRows.add(filesRow)
    visibleRows.add(linksRow)
    visibleRows.add(pinnedRow)

    visibleRows.forEachIndexed { index, row ->
      val isLast = index == visibleRows.lastIndex
      row.configure(
        title = when (row) {
          membersRow -> "Members"
          mediaRow -> "Media"
          audioRow -> "Audio"
          filesRow -> "Files"
          linksRow -> "Links"
          else -> "Pinned"
        },
        value = when (row) {
          membersRow -> resolvedGroupMemberCount().toString()
          mediaRow -> sharedMediaCount.toString()
          audioRow -> sharedAudioCount.toString()
          filesRow -> sharedFileCount.toString()
          linksRow -> sharedLinkCount.toString()
          else -> sharedPinnedCount.toString()
        },
        iconRes = when (row) {
          membersRow -> R.drawable.ic_profile_members
          mediaRow -> R.drawable.ic_profile_media
          audioRow -> R.drawable.ic_profile_audio
          filesRow -> R.drawable.ic_profile_files
          linksRow -> R.drawable.ic_profile_links
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

  private fun resolveResolvedAvatarUri(): String {
    return resolveNativeAvatarUri(
      context = context,
      rawAvatar = avatarUri,
      peerUserId = enginePeerUserIdRaw,
      preferPushAvatar = !isGroupOrChannel,
    ).orEmpty()
  }

  private fun updateAvatarViews() {
    val resolvedUri = resolveResolvedAvatarUri()
    if (resolvedUri.isBlank()) {
      avatarLoadCall?.cancel()
      avatarLoadCall = null
      avatarImage.setImageDrawable(null)
      avatarImage.visibility = View.GONE
      avatarFallback.visibility = View.VISIBLE
      return
    }

    val token = ++avatarLoadToken
    avatarLoadCall?.cancel()

    // Note: Assuming ChatPhoenixClient has buildPinnedHttpClient(), otherwise fall back
    val request = okhttp3.Request.Builder()
      .url(resolvedUri)
      .get()
      .header("Accept", "image/*,*/*;q=0.8")
      .header("ngrok-skip-browser-warning", "true")
      .build()

    val call = avatarHttpClient.newCall(request)
    avatarLoadCall = call
    call.enqueue(object : okhttp3.Callback {
      override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
        post {
          if (token != avatarLoadToken) return@post
          avatarImage.setImageDrawable(null)
          avatarImage.visibility = View.GONE
          avatarFallback.visibility = View.VISIBLE
        }
      }
      override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
        response.use { res ->
          if (!res.isSuccessful) {
            post {
              if (token != avatarLoadToken) return@post
              avatarImage.setImageDrawable(null)
              avatarImage.visibility = View.GONE
              avatarFallback.visibility = View.VISIBLE
            }
            return
          }
          val bytes = try {
            res.body?.bytes()
          } catch (_: Throwable) {
            null
          } ?: return
          val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return
          post {
            if (token != avatarLoadToken) return@post
            avatarImage.setImageBitmap(bitmap)
            avatarImage.visibility = View.VISIBLE
            avatarFallback.visibility = View.GONE
          }
        }
      }
    })
  }

  private fun updateProfileActionState() {
    if (isChatMuted) {
      muteAction.setIcon(android.R.drawable.ic_lock_silent_mode_off)
      muteAction.setTitle("Unmute")
    } else {
      muteAction.setIcon(android.R.drawable.ic_lock_silent_mode)
      muteAction.setTitle("Mute")
    }
  }

  private fun resolvedGroupMemberCount(): Int {
    val explicit = groupMemberCount ?: 0
    return if (explicit > 0) explicit else groupMemberOrder.toSet().size
  }

  private fun normalized(value: Any?): String? {
    return when (value) {
      is String -> value
      is Number -> value.toString()
      is Boolean -> value.toString()
      else -> null
    }
  }

  private fun containsProfileLink(text: String): Boolean {
    if (text.isBlank()) return false
    return LINK_REGEX.containsMatchIn(text)
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

  private fun contrastForegroundFor(background: Int): Int {
    return if (calculateLuminance(background) > 0.5) Color.BLACK else Color.WHITE
  }

  private fun calculateLuminance(color: Int): Double {
    var r = Color.red(color) / 255.0
    var g = Color.green(color) / 255.0
    var b = Color.blue(color) / 255.0

    r = if (r <= 0.03928) r / 12.92 else Math.pow((r + 0.055) / 1.055, 2.4)
    g = if (g <= 0.03928) g / 12.92 else Math.pow((g + 0.055) / 1.055, 2.4)
    b = if (b <= 0.03928) b / 12.92 else Math.pow((b + 0.055) / 1.055, 2.4)

    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }
}
