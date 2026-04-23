package com.mohammadshayani.vibe.ui

import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.materialswitch.MaterialSwitch
import com.mohammadshayani.vibe.home.ChatHomeCardView
import com.mohammadshayani.vibe.home.ChatHomeListRow
import com.mohammadshayani.vibe.home.ChatHomeService
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.session.AppSessionConfig
import com.mohammadshayani.vibe.storage.ChatEngineStore

class ChatHomeActivity : AppCompatActivity() {
  private enum class ShellTab(
    val menuId: Int,
    val title: String,
  ) {
    CONTACTS(1, "Contacts"),
    CALLS(2, "Calls"),
    CHATS(3, "Chats"),
    SETTINGS(4, "Settings");

    companion object {
      fun fromMenuId(value: Int): ShellTab {
        return entries.firstOrNull { it.menuId == value } ?: CHATS
      }
    }
  }

  private lateinit var contentHost: FrameLayout
  private lateinit var bottomNavigationView: BottomNavigationView
  private lateinit var headerTitleView: TextView
  private lateinit var headerSubtitleView: TextView
  private lateinit var headerActionButton: ImageView

  private lateinit var chatsPage: ChatListPageView
  private lateinit var contactsPage: ChatListPageView
  private lateinit var callsPage: PlaceholderPageView
  private lateinit var settingsPage: SettingsPageView

  private var currentTab = ShellTab.CHATS
  private var themeSignature = ""
  private var rows: List<ChatHomeListRow> = emptyList()
  private var isLoading = false
  private var errorMessage: String? = null
  private var notificationsEnabled = true

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)

    if (AppSessionConfig.current(applicationContext) == null) {
      startActivity(Intent(this, WelcomeActivity::class.java))
      finish()
      return
    }

    themeSignature = appThemeSignature(this)
    notificationsEnabled =
      getSharedPreferences("vibe.settings", MODE_PRIVATE)
        .getBoolean("notificationsEnabled", true)
    currentTab =
      savedInstanceState?.getInt("selectedTab")?.let(ShellTab::fromMenuId)
        ?: ShellTab.CHATS

    buildViewHierarchy()
    loadChats()
  }

  override fun onResume() {
    super.onResume()
    val nextSignature = appThemeSignature(this)
    if (nextSignature != themeSignature) {
      recreate()
      return
    }
    renderShell()
  }

  override fun onSaveInstanceState(outState: Bundle) {
    super.onSaveInstanceState(outState)
    outState.putInt("selectedTab", currentTab.menuId)
  }

  private fun buildViewHierarchy() {
    val palette = resolveAppThemePalette(this)
    applyThemedSystemBars(this, palette)

    val root = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setBackgroundColor(palette.backgroundColor)
    }

    val header = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      setPadding(dp(18f), dp(10f), dp(12f), dp(10f))
      background =
        GradientDrawable().apply {
          setColor(adjustColor(palette.backgroundColor, if (palette.isDark) 0.04f else -0.01f))
        }
    }
    root.addView(
      header,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    val headerTextColumn = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
    }
    header.addView(
      headerTextColumn,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
    )

    headerTitleView =
      TextView(this).apply {
        setTextColor(palette.textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      }
    headerSubtitleView =
      TextView(this).apply {
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      }
    headerTextColumn.addView(headerTitleView)
    headerTextColumn.addView(headerSubtitleView)

    headerActionButton =
      ImageView(this).apply {
        setImageResource(android.R.drawable.ic_popup_sync)
        setColorFilter(palette.textColor)
        background = selectableItemBackground()
        setPadding(dp(10f), dp(10f), dp(10f), dp(10f))
        setOnClickListener { loadChats() }
      }
    header.addView(
      headerActionButton,
      LinearLayout.LayoutParams(dp(42f), dp(42f)),
    )

    contentHost = FrameLayout(this).apply {
      setBackgroundColor(palette.backgroundColor)
    }
    root.addView(
      contentHost,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )

    bottomNavigationView =
      BottomNavigationView(this).apply {
        setBackgroundColor(palette.cardColor)
        itemIconTintList = navigationTintList(palette)
        itemTextColor = navigationTintList(palette)
        itemRippleColor = ColorStateList.valueOf(palette.overlayColor)
        menu.add(0, ShellTab.CONTACTS.menuId, 0, ShellTab.CONTACTS.title)
          .setIcon(android.R.drawable.ic_menu_myplaces)
        menu.add(0, ShellTab.CALLS.menuId, 1, ShellTab.CALLS.title)
          .setIcon(android.R.drawable.ic_menu_call)
        menu.add(0, ShellTab.CHATS.menuId, 2, ShellTab.CHATS.title)
          .setIcon(android.R.drawable.ic_dialog_email)
        menu.add(0, ShellTab.SETTINGS.menuId, 3, ShellTab.SETTINGS.title)
          .setIcon(android.R.drawable.ic_menu_manage)
        setOnItemSelectedListener {
          currentTab = ShellTab.fromMenuId(it.itemId)
          renderShell()
          true
        }
      }
    root.addView(
      bottomNavigationView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    chatsPage =
      ChatListPageView(
        context = this,
        onRefresh = { loadChats() },
        onRowPress = { openConversation(it) },
      )
    contactsPage =
      ChatListPageView(
        context = this,
        onRefresh = { loadChats() },
        onRowPress = { openConversation(it) },
      )
    callsPage = PlaceholderPageView(this)
    settingsPage =
      SettingsPageView(
        context = this,
        onRowPress = { handleSettingsRowPress(it) },
        onToggleNotifications = { handleNotificationsToggle(it) },
        onSignOut = { handleSignOut() },
      )

    ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
      header.setPadding(dp(18f), bars.top + dp(10f), dp(12f), dp(10f))
      bottomNavigationView.setPadding(dp(8f), dp(4f), dp(8f), bars.bottom + dp(6f))
      insets
    }

    setContentView(root)
    renderShell()
  }

  private fun loadChats() {
    isLoading = true
    errorMessage = null
    renderPages()
    ChatHomeService.fetchChats(applicationContext) { result ->
      isLoading = false
      result.onSuccess { nextRows ->
        rows = nextRows
      }.onFailure { error ->
        rows = emptyList()
        errorMessage = error.localizedMessage ?: error.message ?: "Load failed."
      }
      renderPages()
    }
  }

  private fun renderShell() {
    val palette = resolveAppThemePalette(this)
    applyThemedSystemBars(this, palette)

    headerTitleView.text = currentTab.title
    headerSubtitleView.text = currentSubtitle()
    headerActionButton.visibility =
      if (currentTab == ShellTab.SETTINGS || currentTab == ShellTab.CALLS) View.GONE else View.VISIBLE
    bottomNavigationView.selectedItemId = currentTab.menuId
    bottomNavigationView.setBackgroundColor(palette.cardColor)
    bottomNavigationView.itemIconTintList = navigationTintList(palette)
    bottomNavigationView.itemTextColor = navigationTintList(palette)
    contentHost.setBackgroundColor(palette.backgroundColor)

    renderPages()

    val page =
      when (currentTab) {
        ShellTab.CONTACTS -> contactsPage
        ShellTab.CALLS -> callsPage
        ShellTab.CHATS -> chatsPage
        ShellTab.SETTINGS -> settingsPage
      }
    if (contentHost.childCount == 0 || contentHost.getChildAt(0) !== page) {
      contentHost.removeAllViews()
      contentHost.addView(
        page,
        FrameLayout.LayoutParams(
          FrameLayout.LayoutParams.MATCH_PARENT,
          FrameLayout.LayoutParams.MATCH_PARENT,
        ),
      )
    }
  }

  private fun renderPages() {
    val palette = resolveAppThemePalette(this)

    chatsPage.render(
      palette = palette,
      rows = rows,
      isLoading = isLoading,
      errorMessage = errorMessage,
      emptyTitle = "No Messages Yet",
      emptyMessage = errorMessage ?: "Start a conversation to see chats here.",
      emptyButtonTitle = "Refresh",
    )

    contactsPage.render(
      palette = palette,
      rows = rows.filter { !it.isSavedMessages && it.peerUserId != null },
      isLoading = isLoading,
      errorMessage = errorMessage,
      emptyTitle = "No Contacts Yet",
      emptyMessage = errorMessage ?: "Direct chats will appear here.",
      emptyButtonTitle = "Refresh",
    )

    callsPage.render(
      palette = palette,
      iconRes = android.R.drawable.ic_menu_call,
      title = "No Calls Yet",
      message = "Recent calls will appear here once the Android native call surface is wired.",
      buttonTitle = null,
      onButtonPress = null,
    )

    settingsPage.render(
      SettingsPageState(
        palette = palette,
        displayName = AppSessionConfig.current(applicationContext)?.username ?: "You",
        subtitle =
          listOfNotNull(
            AppSessionConfig.current(applicationContext)?.phoneNumber,
            AppSessionConfig.current(applicationContext)?.userId,
          ).joinToString(" • ").ifBlank { "Private account" },
        appearanceSummary = "${AppAppearanceController.current(this).title} • ${AppThemePlateController.current(this).title}",
        connectionModeTitle = connectionModeTitle(),
        notificationsEnabled = notificationsEnabled,
      ),
    )
  }

  private fun currentSubtitle(): String {
    return when (currentTab) {
      ShellTab.CONTACTS -> "People you already message"
      ShellTab.CALLS -> "Recent calls"
      ShellTab.CHATS -> "Connected"
      ShellTab.SETTINGS -> AppSessionConfig.current(applicationContext)?.username ?: "Account"
    }
  }

  private fun connectionModeTitle(): String {
    return when (AppSessionConfig.current(applicationContext)?.transportMode ?: PacketTransportMode.PACKET_MESH) {
      PacketTransportMode.PACKET_MESH -> "Automatic"
      PacketTransportMode.DIRECT -> "Direct"
      PacketTransportMode.OFFLINE -> "Offline"
      PacketTransportMode.BRIDGE_TEXT -> "Bridge Text"
    }
  }

  private fun openConversation(row: ChatHomeListRow) {
    startActivity(ConversationActivity.intent(this, row))
  }

  private fun handleSettingsRowPress(rowId: String) {
    when (rowId) {
      "saved_messages" -> {
        startActivity(ConversationActivity.savedMessagesIntent(this))
      }
      "appearance" -> {
        startActivity(Intent(this, AppearanceSettingsActivity::class.java))
      }
      "your_qr" -> {
        val config = AppSessionConfig.current(applicationContext)
        MaterialAlertDialogBuilder(this)
          .setTitle("Your QR")
          .setMessage(
            listOfNotNull(
              config?.username?.let { "@$it" },
              config?.userId?.let { "ID: $it" },
            ).joinToString("\n"),
          )
          .setPositiveButton("Close", null)
          .show()
      }
      "connection_manager" -> {
        MaterialAlertDialogBuilder(this)
          .setTitle("Connection Manager")
          .setMessage("Transport mode: ${connectionModeTitle()}")
          .setPositiveButton("Close", null)
          .show()
      }
    }
  }

  private fun handleNotificationsToggle(value: Boolean) {
    notificationsEnabled = value
    getSharedPreferences("vibe.settings", MODE_PRIVATE)
      .edit()
      .putBoolean("notificationsEnabled", value)
      .apply()
    renderPages()
  }

  private fun handleSignOut() {
    ChatEngineStore.clearConfig(applicationContext)
    startActivity(
      Intent(this, WelcomeActivity::class.java).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
      },
    )
    finish()
  }

  private fun navigationTintList(palette: AppThemePalette): ColorStateList {
    return ColorStateList(
      arrayOf(
        intArrayOf(android.R.attr.state_checked),
        intArrayOf(),
      ),
      intArrayOf(
        palette.accentColor,
        palette.secondaryTextColor,
      ),
    )
  }

  private fun selectableItemBackground() =
    obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).let { typedArray ->
      val drawable = getDrawable(typedArray.getResourceId(0, 0))
      typedArray.recycle()
      drawable
    }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
}

private class ChatListPageView(
  context: android.content.Context,
  private val onRefresh: () -> Unit,
  private val onRowPress: (ChatHomeListRow) -> Unit,
) : FrameLayout(context) {
  private val swipeRefreshLayout = SwipeRefreshLayout(context)
  private val recyclerView = RecyclerView(context)
  private val progressView = ProgressBar(context)
  private val emptyView = PlaceholderPageView(context)
  private val adapter = ChatRowsAdapter(onRowPress)

  init {
    setBackgroundColor(Color.TRANSPARENT)

    recyclerView.layoutManager = LinearLayoutManager(context)
    recyclerView.adapter = adapter
    recyclerView.clipToPadding = false
    recyclerView.setPadding(dp(context, 0f), dp(context, 8f), dp(context, 0f), dp(context, 8f))

    swipeRefreshLayout.setOnRefreshListener { onRefresh() }
    swipeRefreshLayout.addView(
      recyclerView,
      LayoutParams(
        LayoutParams.MATCH_PARENT,
        LayoutParams.MATCH_PARENT,
      ),
    )
    addView(
      swipeRefreshLayout,
      LayoutParams(
        LayoutParams.MATCH_PARENT,
        LayoutParams.MATCH_PARENT,
      ),
    )

    progressView.visibility = View.GONE
    addView(
      progressView,
      LayoutParams(
        LayoutParams.WRAP_CONTENT,
        LayoutParams.WRAP_CONTENT,
        Gravity.CENTER,
      ),
    )

    emptyView.visibility = View.GONE
    addView(
      emptyView,
      LayoutParams(
        LayoutParams.MATCH_PARENT,
        LayoutParams.MATCH_PARENT,
      ),
    )
  }

  fun render(
    palette: AppThemePalette,
    rows: List<ChatHomeListRow>,
    isLoading: Boolean,
    errorMessage: String?,
    emptyTitle: String,
    emptyMessage: String,
    emptyButtonTitle: String?,
  ) {
    setBackgroundColor(palette.backgroundColor)
    swipeRefreshLayout.setColorSchemeColors(palette.accentColor)
    adapter.setPalette(palette)
    adapter.submit(rows)
    swipeRefreshLayout.isRefreshing = isLoading && rows.isNotEmpty()
    progressView.visibility = if (isLoading && rows.isEmpty()) View.VISIBLE else View.GONE
    progressView.indeterminateDrawable?.setTint(palette.accentColor)
    recyclerView.visibility = if (rows.isEmpty()) View.INVISIBLE else View.VISIBLE
    emptyView.visibility = if (!isLoading && rows.isEmpty()) View.VISIBLE else View.GONE
    emptyView.render(
      palette = palette,
      iconRes = android.R.drawable.ic_dialog_email,
      title = emptyTitle,
      message = errorMessage ?: emptyMessage,
      buttonTitle = emptyButtonTitle,
      onButtonPress = if (emptyButtonTitle != null) onRefresh else null,
    )
  }
}

private class ChatRowsAdapter(
  private val onRowPress: (ChatHomeListRow) -> Unit,
) : RecyclerView.Adapter<ChatRowViewHolder>() {
  private val rows = ArrayList<ChatHomeListRow>()
  private var palette = resolveFallbackPalette()

  fun setPalette(value: AppThemePalette) {
    palette = value
    notifyDataSetChanged()
  }

  fun submit(nextRows: List<ChatHomeListRow>) {
    rows.clear()
    rows.addAll(nextRows)
    notifyDataSetChanged()
  }

  override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ChatRowViewHolder {
    val view = ChatHomeCardView(parent.context)
    view.layoutParams =
      RecyclerView.LayoutParams(
        RecyclerView.LayoutParams.MATCH_PARENT,
        RecyclerView.LayoutParams.WRAP_CONTENT,
      )
    return ChatRowViewHolder(view)
  }

  override fun onBindViewHolder(holder: ChatRowViewHolder, position: Int) {
    val row = rows[position]
    holder.view.bind(
      row = row,
      isDark = palette.isDark,
      avatarBackgroundColor = null,
      avatarGradientColors = resolveAvatarGradient(row, palette.isDark),
    )
    holder.view.setOnClickListener { onRowPress(row) }
  }

  override fun getItemCount(): Int = rows.size
}

private class ChatRowViewHolder(
  val view: ChatHomeCardView,
) : RecyclerView.ViewHolder(view)

private class PlaceholderPageView(
  context: android.content.Context,
) : FrameLayout(context) {
  private val iconView = ImageView(context)
  private val titleView = TextView(context)
  private val messageView = TextView(context)
  private val button = MaterialButton(context)

  init {
    val stack =
      LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(dp(context, 28f), dp(context, 28f), dp(context, 28f), dp(context, 28f))
      }
    addView(
      stack,
      LayoutParams(
        LayoutParams.MATCH_PARENT,
        LayoutParams.MATCH_PARENT,
        Gravity.CENTER,
      ),
    )

    stack.addView(iconView, LinearLayout.LayoutParams(dp(context, 40f), dp(context, 40f)))
    stack.addView(space(context, 12f))

    titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
    titleView.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    titleView.gravity = Gravity.CENTER
    stack.addView(titleView)

    stack.addView(space(context, 8f))

    messageView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    messageView.gravity = Gravity.CENTER
    stack.addView(messageView)

    stack.addView(space(context, 14f))

    button.isAllCaps = false
    button.cornerRadius = dp(context, 24f)
    stack.addView(button)
  }

  fun render(
    palette: AppThemePalette,
    iconRes: Int,
    title: String,
    message: String,
    buttonTitle: String?,
    onButtonPress: (() -> Unit)?,
  ) {
    setBackgroundColor(palette.backgroundColor)
    iconView.setImageResource(iconRes)
    iconView.setColorFilter(palette.tertiaryTextColor)
    titleView.text = title
    titleView.setTextColor(palette.textColor)
    messageView.text = message
    messageView.setTextColor(palette.secondaryTextColor)
    if (buttonTitle.isNullOrBlank() || onButtonPress == null) {
      button.visibility = View.GONE
    } else {
      button.visibility = View.VISIBLE
      button.text = buttonTitle
      button.setTextColor(palette.buttonTextColor)
      button.backgroundTintList = ColorStateList.valueOf(palette.buttonColor)
      button.setOnClickListener { onButtonPress() }
    }
  }
}

private data class SettingsPageState(
  val palette: AppThemePalette,
  val displayName: String,
  val subtitle: String,
  val appearanceSummary: String,
  val connectionModeTitle: String,
  val notificationsEnabled: Boolean,
)

private class SettingsPageView(
  context: android.content.Context,
  private val onRowPress: (String) -> Unit,
  private val onToggleNotifications: (Boolean) -> Unit,
  private val onSignOut: () -> Unit,
) : ScrollView(context) {
  private val stack = LinearLayout(context)

  init {
    isFillViewport = true
    clipToPadding = false
    stack.orientation = LinearLayout.VERTICAL
    addView(
      stack,
      LayoutParams(
        LayoutParams.MATCH_PARENT,
        LayoutParams.WRAP_CONTENT,
      ),
    )
  }

  fun render(state: SettingsPageState) {
    setBackgroundColor(state.palette.backgroundColor)
    stack.removeAllViews()
    stack.setPadding(dp(context, 16f), dp(context, 16f), dp(context, 16f), dp(context, 24f))

    stack.addView(profileCard(state))
    stack.addView(space(context, 18f))
    stack.addView(sectionLabel("ACCOUNT", state.palette))
    stack.addView(space(context, 10f))
    stack.addView(
      sectionGroup(
        state.palette,
        listOf(
          settingsRow(
            state.palette,
            "saved_messages",
            android.R.drawable.ic_menu_save,
            "Saved Messages",
            null,
          ),
          settingsRow(
            state.palette,
            "your_qr",
            android.R.drawable.ic_menu_share,
            "Your QR",
            "Show",
          ),
          settingsRow(
            state.palette,
            "connection_manager",
            android.R.drawable.ic_menu_upload,
            "Connection Manager",
            state.connectionModeTitle,
          ),
        ),
      ),
    )
    stack.addView(space(context, 18f))
    stack.addView(sectionLabel("APPEARANCE", state.palette))
    stack.addView(space(context, 10f))
    stack.addView(
      sectionGroup(
        state.palette,
        listOf(
          settingsRow(
            state.palette,
            "appearance",
            android.R.drawable.ic_menu_gallery,
            "Appearance",
            state.appearanceSummary,
          ),
        ),
      ),
    )
    stack.addView(space(context, 18f))
    stack.addView(sectionLabel("NOTIFICATIONS", state.palette))
    stack.addView(space(context, 10f))
    stack.addView(notificationGroup(state))
    stack.addView(space(context, 18f))
    stack.addView(sectionLabel("ACCOUNT ACTIONS", state.palette))
    stack.addView(space(context, 10f))
    stack.addView(signOutGroup(state.palette))
  }

  private fun profileCard(state: SettingsPageState): View {
    val palette = state.palette
    val card =
      LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = roundedRect(palette.cardColor, palette.borderColor, 24f)
        setPadding(dp(context, 18f), dp(context, 18f), dp(context, 18f), dp(context, 18f))
      }

    val avatar =
      FrameLayout(context).apply {
        background =
          GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(palette.accentColor, adjustColor(palette.accentColor, -0.15f)),
          ).apply { shape = GradientDrawable.OVAL }
      }
    avatar.addView(
      TextView(context).apply {
        text = state.displayName.take(1).uppercase()
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
      },
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    card.addView(
      avatar,
      LinearLayout.LayoutParams(dp(context, 64f), dp(context, 64f)),
    )

    val textColumn =
      LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
      }
    card.addView(
      textColumn,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
        marginStart = dp(context, 14f)
      },
    )
    textColumn.addView(
      TextView(context).apply {
        text = state.displayName
        setTextColor(palette.textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      },
    )
    textColumn.addView(
      TextView(context).apply {
        text = state.subtitle
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      },
    )
    return card
  }

  private fun notificationGroup(state: SettingsPageState): View {
    val palette = state.palette
    val group = sectionGroup(palette, emptyList())
    val row =
      LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(context, 16f), dp(context, 14f), dp(context, 16f), dp(context, 14f))
      }
    group.addView(row)
    row.addView(
      ImageView(context).apply {
        setImageResource(android.R.drawable.ic_lock_idle_alarm)
        setColorFilter(palette.accentColor)
      },
      LinearLayout.LayoutParams(dp(context, 22f), dp(context, 22f)),
    )
    val textColumn = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    row.addView(
      textColumn,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
        marginStart = dp(context, 14f)
      },
    )
    textColumn.addView(
      TextView(context).apply {
        text = "Push Notifications"
        setTextColor(palette.textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      },
    )
    textColumn.addView(
      TextView(context).apply {
        text = "Enable alerts for new activity"
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      },
    )
    row.addView(
      MaterialSwitch(context).apply {
        isChecked = state.notificationsEnabled
        thumbTintList = ColorStateList.valueOf(if (state.notificationsEnabled) palette.accentColor else palette.tertiaryTextColor)
        trackTintList = ColorStateList.valueOf(colorRgba(0, 0, 0, if (palette.isDark) 0.3f else 0.12f))
        setOnCheckedChangeListener { _, checked ->
          onToggleNotifications(checked)
        }
      },
    )
    return group
  }

  private fun signOutGroup(palette: AppThemePalette): View {
    val group = sectionGroup(palette, emptyList())
    val row =
      TextView(context).apply {
        text = "Sign Out"
        setTextColor(palette.dangerColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        foreground = selectableItemBackground()
        setPadding(dp(context, 16f), dp(context, 16f), dp(context, 16f), dp(context, 16f))
        setOnClickListener { onSignOut() }
      }
    group.addView(
      row,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    return group
  }

  private fun sectionGroup(
    palette: AppThemePalette,
    rows: List<View>,
  ): LinearLayout {
    val container =
      LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = roundedRect(palette.cardColor, palette.borderColor, 24f)
      }
    rows.forEachIndexed { index, row ->
      container.addView(row)
      if (index != rows.lastIndex) {
        container.addView(divider(palette))
      }
    }
    return container
  }

  private fun settingsRow(
    palette: AppThemePalette,
    rowId: String,
    iconRes: Int,
    title: String,
    detail: String?,
  ): View {
    val row =
      LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        foreground = selectableItemBackground()
        setPadding(dp(context, 16f), dp(context, 14f), dp(context, 16f), dp(context, 14f))
        setOnClickListener { onRowPress(rowId) }
      }
    row.addView(
      ImageView(context).apply {
        setImageResource(iconRes)
        setColorFilter(palette.accentColor)
      },
      LinearLayout.LayoutParams(dp(context, 22f), dp(context, 22f)),
    )
    row.addView(
      TextView(context).apply {
        text = title
        setTextColor(palette.textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      },
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
        marginStart = dp(context, 14f)
      },
    )
    if (!detail.isNullOrBlank()) {
      row.addView(
        TextView(context).apply {
          text = detail
          setTextColor(palette.secondaryTextColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        },
      )
    }
    row.addView(
      ImageView(context).apply {
        setImageResource(android.R.drawable.ic_media_next)
        setColorFilter(palette.tertiaryTextColor)
      },
      LinearLayout.LayoutParams(dp(context, 16f), dp(context, 16f)).apply {
        marginStart = dp(context, 10f)
      },
    )
    return row
  }

  private fun sectionLabel(
    title: String,
    palette: AppThemePalette,
  ): TextView {
    return TextView(context).apply {
      text = title
      setTextColor(palette.secondaryTextColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
  }

  private fun divider(palette: AppThemePalette): View {
    return View(context).apply {
      setBackgroundColor(palette.dividerColor)
      layoutParams = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        dp(context, 1f),
      ).apply {
        marginStart = dp(context, 16f)
      }
    }
  }

  private fun roundedRect(fillColor: Int, strokeColor: Int, radiusDp: Float): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = dp(context, radiusDp).toFloat()
      setColor(fillColor)
      setStroke(dp(context, 1f), strokeColor)
    }
  }

  private fun selectableItemBackground() =
    context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).let { typedArray ->
      val drawable = context.getDrawable(typedArray.getResourceId(0, 0))
      typedArray.recycle()
      drawable
    }
}

private fun resolveAvatarGradient(row: ChatHomeListRow, isDark: Boolean): IntArray? {
  val start = if (isDark) row.avatarGradientStartDark else row.avatarGradientStartLight
  val end = if (isDark) row.avatarGradientEndDark else row.avatarGradientEndLight
  val resolvedStart = parseColorCompat(start)
  val resolvedEnd = parseColorCompat(end)
  return if (resolvedStart != null && resolvedEnd != null) intArrayOf(resolvedStart, resolvedEnd) else null
}

private fun parseColorCompat(value: String?): Int? {
  val text = value?.trim().orEmpty()
  if (text.isEmpty()) return null
  return runCatching { Color.parseColor(text) }.getOrNull()
}

private fun resolveFallbackPalette(): AppThemePalette {
  return AppThemePalette(
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
}

private fun space(context: android.content.Context, valueDp: Float): View {
  return View(context).apply {
    layoutParams = LinearLayout.LayoutParams(1, dp(context, valueDp))
  }
}

private fun dp(context: android.content.Context, value: Float): Int =
  TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, context.resources.displayMetrics).toInt()
