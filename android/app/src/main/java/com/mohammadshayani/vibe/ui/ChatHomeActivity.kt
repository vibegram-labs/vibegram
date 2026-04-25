package com.mohammadshayani.vibe.ui

import android.content.Intent
import android.widget.Toast
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.button.MaterialButton
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.navigation.NavigationBarView
import com.mohammadshayani.vibe.R
import com.mohammadshayani.vibe.chat.ChatNativeHomeListView
import com.mohammadshayani.vibe.chat.NativeChatContext
import com.mohammadshayani.vibe.chat.ChatEngineApi
import com.mohammadshayani.vibe.home.ChatHomeListRow
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.session.AppSessionConfig
import com.mohammadshayani.vibe.storage.ChatEngineStore
import com.mohammadshayani.vibe.storage.SecureKeyStore

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
  private lateinit var headerContainer: LinearLayout
  private lateinit var navigationContainer: FrameLayout
  private lateinit var bottomNavigationView: BottomNavigationView
  private lateinit var headerTitleView: TextView
  private lateinit var storyActionButton: ImageView
  private lateinit var newChatActionButton: ImageView

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
  private var isSyncingBottomNavigation = false

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
    window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
    val palette = resolveAppThemePalette(this)
    applyThemedSystemBars(this, palette)

    val root = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setBackgroundColor(palette.backgroundColor)
    }

    val header = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      setPadding(dp(12f), dp(8f), dp(12f), dp(8f))
      background =
        GradientDrawable().apply {
          setColor(palette.backgroundColor)
        }
    }
    headerContainer = header
    root.addView(
      header,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    header.addView(
      View(this),
      LinearLayout.LayoutParams(dp(88f), dp(40f)),
    )

    headerTitleView =
      TextView(this).apply {
        setTextColor(palette.textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        maxLines = 1
      }
    header.addView(
      headerTitleView,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
    )

    val headerActions = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL or Gravity.END
    }
    header.addView(
      headerActions,
      LinearLayout.LayoutParams(dp(88f), LinearLayout.LayoutParams.WRAP_CONTENT),
    )

    storyActionButton =
      ImageView(this).apply {
        setImageResource(R.drawable.ic_vibe_story_add)
        setColorFilter(palette.textColor)
        background = selectableItemBackground()
        setPadding(dp(8f), dp(8f), dp(8f), dp(8f))
        setOnClickListener {
          startActivity(Intent(this@ChatHomeActivity, StoryActivity::class.java))
        }
      }
    headerActions.addView(
      storyActionButton,
      LinearLayout.LayoutParams(dp(40f), dp(40f)),
    )

    newChatActionButton =
      ImageView(this).apply {
        setImageResource(R.drawable.ic_vibe_new_chat)
        setColorFilter(palette.textColor)
        background = selectableItemBackground()
        setPadding(dp(8f), dp(8f), dp(8f), dp(8f))
        setOnClickListener {
          currentTab = ShellTab.CHATS
          renderShell()
          showNewChatDialog()
        }
      }
    headerActions.addView(
      newChatActionButton,
      LinearLayout.LayoutParams(dp(40f), dp(40f)).apply {
        marginStart = dp(4f)
      },
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

    navigationContainer = FrameLayout(this).apply {
      layoutParams = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      )
      background = GradientDrawable().apply {
        setColor(colorRgba(
          Color.red(palette.backgroundColor),
          Color.green(palette.backgroundColor),
          Color.blue(palette.backgroundColor),
          1f
        ))
      }
    }
    root.addView(navigationContainer)

    bottomNavigationView =
      BottomNavigationView(this).apply {
        setBackgroundColor(palette.backgroundColor)
        elevation = 0f
        labelVisibilityMode = NavigationBarView.LABEL_VISIBILITY_LABELED
        itemActiveIndicatorColor = ColorStateList.valueOf(palette.overlayColor)
        itemIconTintList = navigationTintList(palette)
        itemTextColor = navigationTintList(palette)
        itemRippleColor = ColorStateList.valueOf(palette.overlayColor)

        // Ensure clean and modern SVG icons are used
        menu.add(0, ShellTab.CONTACTS.menuId, 0, ShellTab.CONTACTS.title)
          .setIcon(R.drawable.ic_vibe_tab_contacts)
        menu.add(0, ShellTab.CALLS.menuId, 1, ShellTab.CALLS.title)
          .setIcon(R.drawable.ic_vibe_tab_calls)
        menu.add(0, ShellTab.CHATS.menuId, 2, ShellTab.CHATS.title)
          .setIcon(R.drawable.ic_vibe_tab_chats)

        // Settings Tab with Avatar Fallback
        val settingsMenuItem = menu.add(0, ShellTab.SETTINGS.menuId, 3, ShellTab.SETTINGS.title)
        settingsMenuItem.setIcon(R.drawable.ic_vibe_tab_settings)

        setOnItemSelectedListener {
          if (isSyncingBottomNavigation) {
            return@setOnItemSelectedListener true
          }
          currentTab = ShellTab.fromMenuId(it.itemId)
          renderShell()
          true
        }
      }
    navigationContainer.addView(
      bottomNavigationView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    chatsPage =
      ChatListPageView(
        context = this,
        onRefresh = { loadChats() },
        onRowPress = { openConversation(it) },
        onSearchFocusChanged = { updateSearchPresentation(it) },
      )
    contactsPage =
      ChatListPageView(
        context = this,
        onRefresh = { loadChats() },
        onRowPress = { openConversation(it) },
        onSearchFocusChanged = {},
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
      header.setPadding(dp(12f), bars.top + dp(8f), dp(12f), dp(8f))
      navigationContainer.setPadding(dp(8f), dp(4f), dp(8f), dp(6f))
      insets
    }

    setContentView(root)
    renderShell()
  }

  private fun loadChats() {
    if (rows.isEmpty()) {
      rows = ensureSavedMessagesRow(ChatEngineApi.cachedRows(applicationContext) ?: emptyList())
    }
    isLoading = true
    errorMessage = null
    renderShell()
    ChatEngineApi.fetchChats(applicationContext) { result ->
      isLoading = false
      result.onSuccess { nextRows ->
        rows = ensureSavedMessagesRow(nextRows)
      }.onFailure { error ->
        rows = listOf(savedMessagesRow())
        errorMessage = error.localizedMessage ?: error.message ?: "Load failed."
      }
      renderShell()
    }
  }

  private fun renderShell() {
    val palette = resolveAppThemePalette(this)
    applyThemedSystemBars(this, palette)

    headerTitleView.text = currentHeaderTitle()
    headerTitleView.setTextColor(palette.textColor)
    val showHeaderActions = currentTab == ShellTab.CHATS
    storyActionButton.visibility = if (showHeaderActions) View.VISIBLE else View.INVISIBLE
    newChatActionButton.visibility = if (showHeaderActions) View.VISIBLE else View.INVISIBLE
    storyActionButton.setColorFilter(palette.textColor)
    newChatActionButton.setColorFilter(palette.textColor)
    if (bottomNavigationView.selectedItemId != currentTab.menuId) {
      isSyncingBottomNavigation = true
      bottomNavigationView.selectedItemId = currentTab.menuId
      isSyncingBottomNavigation = false
    }
    bottomNavigationView.setBackgroundColor(palette.backgroundColor)
    bottomNavigationView.labelVisibilityMode = NavigationBarView.LABEL_VISIBILITY_LABELED
    bottomNavigationView.itemActiveIndicatorColor = ColorStateList.valueOf(palette.overlayColor)
    bottomNavigationView.itemIconTintList = navigationTintList(palette)
    bottomNavigationView.itemTextColor = navigationTintList(palette)
    contentHost.setBackgroundColor(palette.backgroundColor)
    if (currentTab != ShellTab.CHATS) {
      updateSearchPresentation(false)
    }

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

  private fun updateSearchPresentation(focused: Boolean) {
    if (!::headerContainer.isInitialized || !::navigationContainer.isInitialized) return
    val shouldCoverHeader = focused && currentTab == ShellTab.CHATS
    headerContainer.visibility = if (shouldCoverHeader) View.GONE else View.VISIBLE
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
        secretKeySummary =
          if (SecureKeyStore.retrieveSecret(applicationContext, "loginSecret").isNullOrBlank()) {
            "Unavailable"
          } else {
            "Stored"
          },
        notificationsEnabled = notificationsEnabled,
      ),
    )
  }

  private fun currentHeaderTitle(): String {
    return when (currentTab) {
      ShellTab.CONTACTS -> "Contacts"
      ShellTab.CALLS -> "Calls"
      ShellTab.CHATS -> {
        when {
          isLoading && rows.isEmpty() -> "Updating..."
          errorMessage != null && rows.size <= 1 -> "Connection issue"
          else -> "Chats"
        }
      }
      ShellTab.SETTINGS -> "Settings"
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
    startActivity(
      if (row.isSavedMessages) {
        ConversationActivity.savedMessagesIntent(this)
      } else {
        ConversationActivity.intent(this, row)
      },
    )
  }

  private fun showNewChatDialog() {
    val palette = resolveAppThemePalette(this)
    val bottomSheet = com.google.android.material.bottomsheet.BottomSheetDialog(this, R.style.ThemeOverlay_Vibe_BottomSheetDialog)
    val displayMetrics = resources.displayMetrics
    val targetHeight = (displayMetrics.heightPixels * 0.90f).toInt()

    val container = FrameLayout(this).apply {
      layoutParams = android.view.ViewGroup.LayoutParams(
        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
        targetHeight
      )
    }

    val searchView = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(24f), dp(24f), dp(24f), dp(28f))
      layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
    }

    val title = TextView(this).apply {
      text = "New Chat"
      setTextColor(palette.textColor)
      textSize = 28f
      typeface = Typeface.create("sans-serif-black", Typeface.NORMAL)
      setPadding(0, 0, 0, dp(16f))
    }
    searchView.addView(title)

    val input = EditText(this).apply {
      hint = "Username, phone, or user id"
      inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
      isSingleLine = true
      setTextColor(palette.textColor)
      setHintTextColor(palette.tertiaryTextColor)
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dp(22f).toFloat()
        setColor(palette.inputColor)
      }
      setPadding(dp(20f), dp(16f), dp(20f), dp(16f))
    }
    searchView.addView(input, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
      bottomMargin = dp(16f)
    })

    val startButton = MaterialButton(this).apply {
      text = "Search"
      isAllCaps = false
      setBackgroundColor(palette.accentColor)
      setTextColor(Color.WHITE)
      cornerRadius = dp(27f)
      minimumHeight = dp(54f)
    }
    searchView.addView(startButton, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

    val resultView = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(24f), dp(24f), dp(24f), dp(28f))
      layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
      visibility = View.GONE
      gravity = Gravity.CENTER_HORIZONTAL
    }

    val resultAvatar = FrameLayout(this).apply {
      background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(palette.inputColor)
      }
      layoutParams = LinearLayout.LayoutParams(dp(90f), dp(90f)).apply {
        topMargin = dp(40f)
        bottomMargin = dp(16f)
      }
    }
    val resultAvatarLabel = TextView(this).apply {
      setTextColor(palette.accentColor)
      textSize = 28f
      typeface = Typeface.create("sans-serif-bold", Typeface.NORMAL)
      gravity = Gravity.CENTER
    }
    resultAvatar.addView(
      resultAvatarLabel,
      FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
    )
    resultView.addView(resultAvatar)

    val resultName = TextView(this).apply {
      setTextColor(palette.textColor)
      textSize = 24f
      typeface = Typeface.create("sans-serif-bold", Typeface.NORMAL)
      gravity = Gravity.CENTER
    }
    resultView.addView(resultName)

    val resultId = TextView(this).apply {
      setTextColor(palette.secondaryTextColor)
      textSize = 16f
      gravity = Gravity.CENTER
      setPadding(0, dp(4f), 0, dp(32f))
    }
    resultView.addView(resultId)

    val actionsRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
      weightSum = 3f
    }
    val messageBtn = MaterialButton(this).apply {
      text = "Message"
      isAllCaps = false
      setBackgroundColor(palette.accentColor)
      setTextColor(Color.WHITE)
      cornerRadius = dp(20f)
      layoutParams = LinearLayout.LayoutParams(0, dp(54f), 1f).apply { marginEnd = dp(6f) }
    }
    val callBtn = MaterialButton(this).apply {
      text = "Call"
      isAllCaps = false
      setBackgroundColor(palette.inputColor)
      setTextColor(palette.textColor)
      cornerRadius = dp(20f)
      layoutParams = LinearLayout.LayoutParams(0, dp(54f), 1f).apply {
        marginStart = dp(6f)
        marginEnd = dp(6f)
      }
    }
    val addContactBtn = MaterialButton(this).apply {
      text = "Add Contact"
      isAllCaps = false
      setBackgroundColor(palette.inputColor)
      setTextColor(palette.textColor)
      cornerRadius = dp(20f)
      layoutParams = LinearLayout.LayoutParams(0, dp(54f), 1f).apply { marginStart = dp(6f) }
    }
    actionsRow.addView(messageBtn)
    actionsRow.addView(callBtn)
    actionsRow.addView(addContactBtn)
    resultView.addView(actionsRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

    container.addView(searchView)
    container.addView(resultView)

    var foundPeer: ChatEngineApi.PeerLookupResult? = null
    var resolvedRow: ChatHomeListRow? = null

    fun addResolvedRow(row: ChatHomeListRow) {
      rows = ensureSavedMessagesRow(listOf(row) + rows.filter { it.chatId != row.chatId })
      renderShell()
    }

    fun openResolvedChat(row: ChatHomeListRow) {
      addResolvedRow(row)
      bottomSheet.dismiss()
      openConversation(row)
    }

    fun startChatForFoundPeer(onSuccess: (ChatHomeListRow) -> Unit) {
      val cachedRow = resolvedRow
      if (cachedRow != null) {
        onSuccess(cachedRow)
        return
      }
      val peer = foundPeer ?: return
      messageBtn.isEnabled = false
      addContactBtn.isEnabled = false
      callBtn.isEnabled = false
      ChatEngineApi.startDirectChat(this@ChatHomeActivity, peer) { result ->
        messageBtn.isEnabled = true
        addContactBtn.isEnabled = true
        callBtn.isEnabled = true
        result.onSuccess { row ->
          resolvedRow = row
          onSuccess(row)
        }.onFailure { error ->
          Toast.makeText(
            this@ChatHomeActivity,
            error.localizedMessage ?: error.message ?: "Could not open chat",
            Toast.LENGTH_SHORT,
          ).show()
        }
      }
    }

    startButton.setOnClickListener {
      val lookup = input.text?.toString().orEmpty().trim()
      if (lookup.isBlank()) {
        input.error = "Enter a username, phone, or user id"
        return@setOnClickListener
      }
      startButton.isEnabled = false
      startButton.text = "Searching..."
      ChatEngineApi.findUser(this@ChatHomeActivity, lookup) { result ->
        startButton.isEnabled = true
        startButton.text = "Search"
        result.onSuccess { peer ->
          foundPeer = peer
          resolvedRow = null
          searchView.visibility = View.GONE
          resultView.visibility = View.VISIBLE
          resultName.text = peer.displayName
          resultId.text = peer.subtitle
          resultAvatarLabel.text = peer.displayName.take(1).uppercase().ifBlank { "V" }
          addContactBtn.text = "Add Contact"
          addContactBtn.isEnabled = true
          
          messageBtn.setOnClickListener {
            startChatForFoundPeer { row ->
              openResolvedChat(row)
            }
          }
          callBtn.setOnClickListener {
            startChatForFoundPeer { row ->
              openResolvedChat(row)
              Toast.makeText(this@ChatHomeActivity, "Use the call button in chat", Toast.LENGTH_SHORT).show()
            }
          }
          addContactBtn.setOnClickListener {
            startChatForFoundPeer { row ->
              addResolvedRow(row)
              Toast.makeText(this@ChatHomeActivity, "Contact added", Toast.LENGTH_SHORT).show()
              addContactBtn.text = "Added"
              addContactBtn.isEnabled = false
            }
          }
        }.onFailure { error ->
          input.error = error.localizedMessage ?: error.message ?: "Could not find user"
        }
      }
    }

    bottomSheet.setContentView(container)
    bottomSheet.window?.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))

    bottomSheet.findViewById<View>(com.google.android.material.R.id.design_bottom_sheet)?.let { sheet ->
      sheet.layoutParams = sheet.layoutParams.apply { height = targetHeight }
      sheet.minimumHeight = targetHeight
      val behavior = com.google.android.material.bottomsheet.BottomSheetBehavior.from(sheet)
      behavior.isFitToContents = false
      behavior.expandedOffset = (displayMetrics.heightPixels - targetHeight).coerceAtLeast(0)
      behavior.peekHeight = targetHeight
      behavior.skipCollapsed = true
      behavior.state = com.google.android.material.bottomsheet.BottomSheetBehavior.STATE_EXPANDED
      
      sheet.background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        val r = dp(34f).toFloat()
        cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
        setColor(palette.backgroundColor)
      }
    }

    bottomSheet.show()
    input.requestFocus()
    input.post {
      (getSystemService(INPUT_METHOD_SERVICE) as? android.view.inputmethod.InputMethodManager)
        ?.showSoftInput(input, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
    }
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
        startActivity(Intent(this, UserQRDetailActivity::class.java))
      }
      "connection_manager" -> {
        startActivity(Intent(this, ConnectionDetailActivity::class.java))
      }
      "secret_key" -> {
        startActivity(Intent(this, SecretKeyDetailActivity::class.java))
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
        palette.textColor,
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

  private fun ensureSavedMessagesRow(nextRows: List<ChatHomeListRow>): List<ChatHomeListRow> {
    if (nextRows.any { it.isSavedMessages || it.chatId == "saved_messages" }) return nextRows
    return listOf(savedMessagesRow()) + nextRows
  }

  private fun savedMessagesRow(): ChatHomeListRow {
    return ChatHomeListRow(
      chatId = "saved_messages",
      title = "Saved Messages",
      preview = "",
      timeLabel = "",
      unreadCount = 0,
      markedUnread = false,
      muted = false,
      pinned = false,
      isTyping = false,
      isOnline = false,
      peerUserId = null,
      avatarUri = null,
      avatarFallback = "S",
      avatarGradientStartLight = "#7ADCE6",
      avatarGradientEndLight = "#1B8E99",
      avatarGradientStartDark = "#174A50",
      avatarGradientEndDark = "#2AA6B5",
      isSavedMessages = true,
    )
  }
}

private class ChatListPageView(
  context: android.content.Context,
  private val onRefresh: () -> Unit,
  private val onRowPress: (ChatHomeListRow) -> Unit,
  private val onSearchFocusChanged: (Boolean) -> Unit,
) : FrameLayout(context) {
  private val listColumn = LinearLayout(context)
  private val searchShell = LinearLayout(context)
  private val searchInput = EditText(context)
  private val searchClearButton = ImageView(context)
  private val nativeHomeListView =
    ChatNativeHomeListView(context, NativeChatContext(context as? android.app.Activity))
  private val progressView = ProgressBar(context)
  private val emptyView = PlaceholderPageView(context)
  private var allRows: List<ChatHomeListRow> = emptyList()
  private var query = ""
  private var searchFocused = false

  private val storyStrip = android.widget.HorizontalScrollView(context).apply {
    isHorizontalScrollBarEnabled = false
    setPadding(0, dp(context, 4f), 0, dp(context, 8f))
  }
  private val storyContainer = LinearLayout(context).apply {
    orientation = LinearLayout.HORIZONTAL
    setPadding(dp(context, 16f), 0, dp(context, 16f), 0)
  }
  private val addStoryItem = LinearLayout(context).apply {
    orientation = LinearLayout.VERTICAL
    gravity = Gravity.CENTER
    setOnClickListener {
      context.startActivity(android.content.Intent(context, com.mohammadshayani.vibe.ui.StoryActivity::class.java))
    }
  }
  private val addStoryAvatarContainer = FrameLayout(context).apply {
    setPadding(dp(context, 4f), dp(context, 4f), dp(context, 4f), dp(context, 4f))
  }
  private val addStoryIcon = ImageView(context).apply {
    setImageResource(R.drawable.ic_vibe_story_add)
    setPadding(dp(context, 12f), dp(context, 12f), dp(context, 12f), dp(context, 12f))
  }
  private val addStoryLabel = TextView(context).apply {
    text = "Your Story"
    textSize = 12f
    maxLines = 1
    setPadding(0, dp(context, 4f), 0, 0)
  }

  init {
    setBackgroundColor(Color.TRANSPARENT)

    listColumn.orientation = LinearLayout.VERTICAL

    searchShell.orientation = LinearLayout.HORIZONTAL
    searchShell.gravity = Gravity.CENTER_VERTICAL
    searchShell.setPadding(dp(context, 14f), 0, dp(context, 14f), 0)
    searchShell.addView(
      ImageView(context).apply {
        setImageResource(R.drawable.ic_vibe_search)
      },
      LinearLayout.LayoutParams(dp(context, 20f), dp(context, 20f)),
    )
    searchInput.apply {
      background = null
      hint = "Search"
      inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
      isSingleLine = true
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
      setPadding(dp(context, 8f), 0, 0, 0)
      addTextChangedListener(object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
          query = s?.toString().orEmpty()
          applyFilteredRows()
          updateSearchChrome()
        }
        override fun afterTextChanged(s: Editable?) = Unit
      })
      setOnFocusChangeListener { _, focused ->
        searchFocused = focused
        onSearchFocusChanged(focused)
        updateSearchChrome()
      }
    }
    searchShell.addView(
      searchInput,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f),
    )
    searchClearButton.apply {
      setImageResource(R.drawable.ic_close)
      background = selectableItemBackground()
      setPadding(dp(context, 8f), dp(context, 8f), dp(context, 8f), dp(context, 8f))
      visibility = View.GONE
      setOnClickListener {
        searchInput.setText("")
        searchInput.requestFocus()
      }
    }
    searchShell.addView(
      searchClearButton,
      LinearLayout.LayoutParams(dp(context, 40f), dp(context, 40f)),
    )
    listColumn.addView(
      searchShell,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        dp(context, 44f),
      ).apply {
        setMargins(dp(context, 16f), dp(context, 12f), dp(context, 16f), dp(context, 8f))
      },
    )

    addStoryAvatarContainer.addView(addStoryIcon, FrameLayout.LayoutParams(dp(context, 56f), dp(context, 56f)))
    addStoryItem.addView(addStoryAvatarContainer, LinearLayout.LayoutParams(dp(context, 64f), dp(context, 64f)))
    addStoryItem.addView(addStoryLabel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    storyContainer.addView(addStoryItem)
    storyStrip.addView(storyContainer)
    listColumn.addView(storyStrip, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

    nativeHomeListView.nativeEventSink = { payload ->
      when (payload["type"]) {
        "press" -> {
          val chatId = payload["chatId"]?.toString().orEmpty()
          allRows.firstOrNull { it.chatId == chatId }?.let(onRowPress)
        }
        "refresh" -> onRefresh()
      }
    }
    listColumn.addView(
      nativeHomeListView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )

    addView(
      listColumn,
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

  fun focusSearch() {
    searchInput.requestFocus()
    (context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as? InputMethodManager)
      ?.showSoftInput(searchInput, InputMethodManager.SHOW_IMPLICIT)
    searchInput.post {
      searchShell.requestRectangleOnScreen(
        android.graphics.Rect(0, 0, searchShell.width, searchShell.height),
        true,
      )
    }
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
    searchShell.background =
      GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dp(context, 22f).toFloat()
        setColor(palette.inputColor)
    }
    (searchShell.getChildAt(0) as? ImageView)?.setColorFilter(palette.tertiaryTextColor)
    searchClearButton.setColorFilter(palette.tertiaryTextColor)
    searchInput.setTextColor(palette.textColor)
    searchInput.setHintTextColor(palette.tertiaryTextColor)

    addStoryAvatarContainer.background = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setStroke(dp(context, 2f), Color.parseColor("#807ADCE6"))
    }
    addStoryIcon.background = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(Color.parseColor(if (palette.isDark) "#174A50" else "#E9EEF5"))
    }
    addStoryIcon.setColorFilter(palette.textColor)
    addStoryLabel.setTextColor(palette.secondaryTextColor)
    storyStrip.visibility = if (query.isEmpty() && storyContainer.childCount > 1) View.VISIBLE else View.GONE
    allRows = rows
    nativeHomeListView.setIsDark(palette.isDark)
    nativeHomeListView.setPreviewAppearance(
      mapOf(
        "avatarBackgroundColorLight" to "#E9EEF5",
        "avatarBackgroundColorDark" to "#2A2C34",
      ),
    )
    applyFilteredRows()
    nativeHomeListView.setRefreshing(isLoading && rows.isNotEmpty())
    progressView.visibility = View.GONE
    progressView.indeterminateDrawable?.setTint(palette.accentColor)
    val visibleRows = filteredRows()
    listColumn.visibility = View.VISIBLE
    nativeHomeListView.visibility = if (visibleRows.isEmpty()) View.INVISIBLE else View.VISIBLE
    emptyView.visibility = if (!isLoading && visibleRows.isEmpty()) View.VISIBLE else View.GONE
    updateSearchChrome()
    emptyView.render(
      palette = palette,
      iconRes = R.drawable.ic_vibe_tab_chats,
      title = if (query.isBlank()) emptyTitle else "No results",
      message = if (query.isBlank()) errorMessage ?: emptyMessage else "Try a different search.",
      buttonTitle = emptyButtonTitle,
      onButtonPress = if (emptyButtonTitle != null) onRefresh else null,
    )
  }

  private fun filteredRows(): List<ChatHomeListRow> {
    val needle = query.trim().lowercase()
    if (needle.isBlank()) return allRows
    return allRows.filter {
      it.title.lowercase().contains(needle) ||
        it.preview.lowercase().contains(needle) ||
        it.chatId.lowercase().contains(needle) ||
        it.peerUserId.orEmpty().lowercase().contains(needle) ||
        it.avatarFallback.lowercase().contains(needle)
    }
  }

  private fun applyFilteredRows() {
    nativeHomeListView.setRows(filteredRows().map(::rowPayload))
  }

  private fun updateSearchChrome() {
    searchClearButton.visibility = if (query.isBlank()) View.GONE else View.VISIBLE
    val lp = searchShell.layoutParams as? LinearLayout.LayoutParams ?: return
    val targetTop = if (searchFocused) dp(context, 4f) else dp(context, 12f)
    if (lp.topMargin != targetTop) {
      lp.topMargin = targetTop
      searchShell.layoutParams = lp
    }
    nativeHomeListView.translationY = if (searchFocused) -dp(context, 6f).toFloat() else 0f
    storyStrip.visibility = if (query.isEmpty() && storyContainer.childCount > 1) View.VISIBLE else View.GONE
  }

  private fun selectableItemBackground() =
    context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).let { typedArray ->
      val drawable = typedArray.getDrawable(0)
      typedArray.recycle()
      drawable
    }

  private fun rowPayload(row: ChatHomeListRow): Map<String, Any?> {
    return mapOf(
      "chatId" to row.chatId,
      "chatType" to if (row.peerUserId == null && !row.isSavedMessages) "group" else "dm",
      "name" to row.title,
      "preview" to row.preview,
      "timeLabel" to row.timeLabel,
      "unreadCount" to row.unreadCount,
      "markedUnread" to row.markedUnread,
      "muted" to row.muted,
      "pinned" to row.pinned,
      "isTyping" to row.isTyping,
      "isOnline" to row.isOnline,
      "friendId" to row.peerUserId,
      "avatarUri" to row.avatarUri,
      "avatarFallback" to row.avatarFallback,
      "avatarGradientStartLight" to row.avatarGradientStartLight,
      "avatarGradientEndLight" to row.avatarGradientEndLight,
      "avatarGradientStartDark" to row.avatarGradientStartDark,
      "avatarGradientEndDark" to row.avatarGradientEndDark,
    )
  }
}

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
  val secretKeySummary: String,
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
            R.drawable.ic_vibe_saved,
            "Saved Messages",
            null,
          ),
          settingsRow(
            state.palette,
            "your_qr",
            R.drawable.ic_vibe_qr,
            "Your QR",
            "Show",
          ),
          settingsRow(
            state.palette,
            "connection_manager",
            R.drawable.ic_vibe_connection,
            "Connection Manager",
            state.connectionModeTitle,
          ),
        ),
      ),
    )
    stack.addView(space(context, 18f))
    stack.addView(sectionLabel("PRIVACY & SECURITY", state.palette))
    stack.addView(space(context, 10f))
    stack.addView(
      sectionGroup(
        state.palette,
        listOf(
          settingsRow(
            state.palette,
            "secret_key",
            R.drawable.ic_vibe_key,
            "Secret Key",
            state.secretKeySummary,
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
            R.drawable.ic_vibe_palette,
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
	        setImageResource(R.drawable.ic_vibe_bell)
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
	        setImageResource(R.drawable.ic_vibe_chevron_right)
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

private fun space(context: android.content.Context, valueDp: Float): View {
  return View(context).apply {
    layoutParams = LinearLayout.LayoutParams(1, dp(context, valueDp))
  }
}

private fun dp(context: android.content.Context, value: Float): Int =
  TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, context.resources.displayMetrics).toInt()
