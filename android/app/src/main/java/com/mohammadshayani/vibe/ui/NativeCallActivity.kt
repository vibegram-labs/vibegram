package com.mohammadshayani.vibe.ui

import android.app.Activity
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
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.mohammadshayani.vibe.chat.NativeCallEngine
import com.mohammadshayani.vibe.session.AppSessionConfig
import java.lang.ref.WeakReference
import java.util.UUID

class NativeCallActivity : AppCompatActivity() {
  companion object {
    private const val extraState = "state"
    private const val extraDirection = "direction"
    private const val extraCallId = "call_id"
    private const val extraCallType = "call_type"
    private const val extraToUserId = "to_user_id"
    private const val extraToUserName = "to_user_name"
    private const val extraToUserImage = "to_user_image"
    private const val extraFromUserId = "from_user_id"
    private const val extraFromUserName = "from_user_name"
    private const val extraFromUserImage = "from_user_image"
    private const val extraChatId = "chat_id"
    private const val extraNote = "note"
    private const val extraSignalingAccepted = "signaling_accepted"
    private const val extraSignalingQueued = "signaling_queued"
    private const val extraFailureReason = "failure_reason"

    private var activeRef: WeakReference<NativeCallActivity>? = null

    fun startOutgoing(context: Context, payload: Map<String, Any?>, status: Map<String, Any?>) {
      val state = linkedMapOf<String, Any?>()
      state.putAll(payload)
      state.putAll(status)
      if (stringValue(state["direction"]).isNullOrBlank()) state["direction"] = "outgoing"
      start(context, state)
    }

    fun startIncoming(context: Context, status: Map<String, Any?>) {
      val state = linkedMapOf<String, Any?>()
      state.putAll(status)
      if (stringValue(state["direction"]).isNullOrBlank()) state["direction"] = "incoming"
      start(context, state)
    }

    fun applyEngineState(status: Map<String, Any?>) {
      Handler(Looper.getMainLooper()).post {
        activeRef?.get()?.applyState(status, null)
      }
    }

    fun intent(context: Context, state: Map<String, Any?>): Intent {
      return Intent(context, NativeCallActivity::class.java).apply {
        putCallExtras(state)
        if (context !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
      }
    }

    private fun start(context: Context, state: Map<String, Any?>) {
      val intent = intent(context, state)
      context.startActivity(intent)
    }

    private fun Intent.putCallExtras(state: Map<String, Any?>) {
      putExtra(extraState, stringValue(state["state"]) ?: "ringing")
      putExtra(extraDirection, stringValue(state["direction"]) ?: "outgoing")
      putExtra(extraCallId, stringValue(state["callId"] ?: state["call_id"]).orEmpty())
      putExtra(extraCallType, stringValue(state["callType"] ?: state["call_type"]) ?: "voice")
      putExtra(extraToUserId, stringValue(state["toUserId"] ?: state["to_user_id"]).orEmpty())
      putExtra(extraToUserName, stringValue(state["toUserName"] ?: state["to_user_name"]).orEmpty())
      putExtra(extraToUserImage, stringValue(state["toUserImage"] ?: state["to_user_image"]).orEmpty())
      putExtra(extraFromUserId, stringValue(state["fromUserId"] ?: state["from_user_id"]).orEmpty())
      putExtra(extraFromUserName, stringValue(state["fromUserName"] ?: state["from_user_name"]).orEmpty())
      putExtra(extraFromUserImage, stringValue(state["fromUserImage"] ?: state["from_user_image"]).orEmpty())
      putExtra(extraChatId, stringValue(state["chatId"] ?: state["chat_id"]).orEmpty())
      putExtra(extraNote, stringValue(state["note"]).orEmpty())
      putExtra(extraFailureReason, stringValue(state["failureReason"]).orEmpty())
      putExtra(extraSignalingAccepted, boolValue(state["signalingAccepted"]))
      putExtra(extraSignalingQueued, boolValue(state["signalingQueued"]))
    }

    private fun stringValue(value: Any?): String? =
      value?.toString()?.trim()?.takeIf { it.isNotEmpty() }

    private fun boolValue(value: Any?): Boolean =
      when (value) {
        is Boolean -> value
        is Number -> value.toInt() != 0
        is String -> value.equals("true", ignoreCase = true) || value == "1" || value.equals("yes", ignoreCase = true)
        else -> false
      }
  }

  private val handler = Handler(Looper.getMainLooper())
  private val state = linkedMapOf<String, Any?>()
  private var retryPayload: MutableMap<String, Any?>? = null
  private var timeoutRunnable: Runnable? = null

  private lateinit var avatarView: TextView
  private lateinit var directionView: TextView
  private lateinit var nameView: TextView
  private lateinit var statusView: TextView
  private lateinit var controlsRow: LinearLayout

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    applyState(readState(intent), readRetryPayload(intent))
    setContentView(buildContentView())
    render()
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    applyState(readState(intent), readRetryPayload(intent))
  }

  override fun onResume() {
    super.onResume()
    activeRef = WeakReference(this)
  }

  override fun onDestroy() {
    if (activeRef?.get() === this) activeRef = null
    timeoutRunnable?.let(handler::removeCallbacks)
    super.onDestroy()
  }

  private fun buildContentView(): View {
    val root = FrameLayout(this).apply {
      setBackgroundColor(Color.rgb(12, 13, 16))
      foregroundGravity = Gravity.CENTER
    }

    val content = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      setPadding(dp(28), 0, dp(28), 0)
    }
    root.addView(
      content,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    avatarView = TextView(this).apply {
      gravity = Gravity.CENTER
      setTextColor(Color.WHITE)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 34f)
      typeface = Typeface.DEFAULT_BOLD
      background = ovalDrawable(Color.argb(44, 255, 255, 255))
    }
    content.addView(avatarView, LinearLayout.LayoutParams(dp(104), dp(104)).apply {
      bottomMargin = dp(24)
    })

    directionView = TextView(this).apply {
      gravity = Gravity.CENTER
      setTextColor(Color.argb(178, 255, 255, 255))
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      typeface = Typeface.DEFAULT_BOLD
    }
    content.addView(directionView)

    nameView = TextView(this).apply {
      gravity = Gravity.CENTER
      setTextColor(Color.WHITE)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
      typeface = Typeface.DEFAULT_BOLD
      maxLines = 2
    }
    content.addView(nameView, LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      topMargin = dp(8)
    })

    statusView = TextView(this).apply {
      gravity = Gravity.CENTER
      setTextColor(Color.argb(204, 255, 255, 255))
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
      maxLines = 3
    }
    content.addView(statusView, LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      topMargin = dp(8)
    })

    controlsRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
    }
    root.addView(
      controlsRow,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
      ).apply {
        bottomMargin = dp(56)
      },
    )

    return root
  }

  private fun applyState(next: Map<String, Any?>, nextRetryPayload: Map<String, Any?>?) {
    state.putAll(next)
    nextRetryPayload?.let { retryPayload = LinkedHashMap(it) }
    if (retryPayload == null && stringValue(state["direction"]) == "outgoing") {
      outgoingPayload()?.let { retryPayload = it }
    }
    if (::nameView.isInitialized) render()
  }

  private fun render() {
    val name = displayName()
    avatarView.text = name.firstOrNull()?.uppercaseChar()?.toString() ?: "V"
    directionView.text = directionTitle()
    nameView.text = name
    statusView.text = statusText()
    configureControls()
    scheduleTimeoutIfNeeded()
  }

  private fun configureControls() {
    controlsRow.removeAllViews()
    val stateValue = stringValue(state["state"]) ?: "ringing"
    val direction = stringValue(state["direction"]) ?: ""

    if (stateValue == "failed") {
      controlsRow.addView(actionButton("Close", Color.argb(42, 255, 255, 255)) { finish() })
      controlsRow.addView(actionButton("Retry", Color.rgb(35, 176, 86)) { retryCall() })
      return
    }

    if (stateValue == "ended") {
      handler.postDelayed({ finish() }, 500)
      return
    }

    if (direction == "incoming" && stateValue == "ringing") {
      controlsRow.addView(actionButton("Decline", Color.rgb(220, 53, 69)) { endCall() })
      controlsRow.addView(actionButton("Accept", Color.rgb(35, 176, 86)) { acceptCall() })
      return
    }

    controlsRow.addView(actionButton("End", Color.rgb(220, 53, 69)) { endCall() })
  }

  private fun actionButton(title: String, color: Int, onClick: () -> Unit): TextView {
    return TextView(this).apply {
      text = title
      gravity = Gravity.CENTER
      setTextColor(Color.WHITE)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      typeface = Typeface.DEFAULT_BOLD
      background = roundedDrawable(color, dp(30).toFloat())
      setOnClickListener { onClick() }
      layoutParams = LinearLayout.LayoutParams(dp(92), dp(60)).apply {
        marginStart = dp(8)
        marginEnd = dp(8)
      }
    }
  }

  private fun acceptCall() {
    applyState(NativeCallEngine.acceptIncoming(currentPayload()), null)
  }

  private fun endCall() {
    applyState(NativeCallEngine.endCall(currentPayload()), null)
  }

  private fun retryCall() {
    val payload = retryPayload ?: outgoingPayload()
    if (payload == null) {
      statusView.text = "Call could not start. Open the chat and try again."
      return
    }
    val config = AppSessionConfig.current(applicationContext)
    if (config == null) {
      statusView.text = "Call could not start. Sign in again and retry."
      return
    }
    NativeCallEngine.configure(applicationContext, config.toPayload())
    val nextPayload = LinkedHashMap(payload)
    nextPayload["event"] = "call-start"
    nextPayload["callId"] = "call_${System.currentTimeMillis()}_${UUID.randomUUID().toString().take(8)}"
    nextPayload["direction"] = "outbound"
    retryPayload = nextPayload
    applyState(NativeCallEngine.startOutgoing(nextPayload), nextPayload)
  }

  private fun scheduleTimeoutIfNeeded() {
    timeoutRunnable?.let(handler::removeCallbacks)
    timeoutRunnable = null
    val stateValue = stringValue(state["state"]) ?: ""
    val direction = stringValue(state["direction"]) ?: ""
    val callId = stringValue(state["callId"] ?: state["call_id"]) ?: return
    if (direction != "outgoing" || stateValue !in setOf("ringing", "starting")) return

    val runnable = Runnable {
      val currentCallId = stringValue(state["callId"] ?: state["call_id"])
      val currentState = stringValue(state["state"]) ?: ""
      if (currentCallId == callId && currentState in setOf("ringing", "starting")) {
        applyState(
          NativeCallEngine.failCall(currentPayload(), "No answer. You can retry the call."),
          retryPayload ?: outgoingPayload(),
        )
      }
    }
    timeoutRunnable = runnable
    handler.postDelayed(runnable, 40_000L)
  }

  private fun currentPayload(): MutableMap<String, Any?> {
    val payload = LinkedHashMap(state)
    if (stringValue(payload["toUserId"] ?: payload["to_user_id"]).isNullOrBlank()) {
      stringValue(payload["fromUserId"] ?: payload["from_user_id"])?.let { payload["toUserId"] = it }
    }
    return payload
  }

  private fun outgoingPayload(): MutableMap<String, Any?>? {
    val toUserId = stringValue(state["toUserId"] ?: state["to_user_id"]) ?: return null
    return linkedMapOf<String, Any?>(
      "event" to "call-start",
      "callType" to (stringValue(state["callType"] ?: state["call_type"]) ?: "voice"),
      "toUserId" to toUserId,
      "toUserName" to displayName(),
      "toUserImage" to stringValue(state["toUserImage"] ?: state["to_user_image"]).orEmpty(),
      "chatId" to stringValue(state["chatId"] ?: state["chat_id"]).orEmpty(),
    )
  }

  private fun statusText(): String {
    return when (stringValue(state["state"]) ?: "ringing") {
      "ringing", "starting" -> "Ringing..."
      "connecting" -> "Connecting..."
      "active" -> "Connected"
      "failed" -> friendlyFailureText()
      "ended" -> "Call ended"
      else -> "Connecting..."
    }
  }

  private fun friendlyFailureText(): String {
    stringValue(state["failureReason"])?.let { return it }
    if (boolValue(state["signalingQueued"])) {
      return "Still waiting for the connection. You can retry the call."
    }
    return "Call could not start. Check the connection and try again."
  }

  private fun directionTitle(): String {
    val type = if (stringValue(state["callType"] ?: state["call_type"]) == "video") "Video" else "Voice"
    return when (stringValue(state["direction"])) {
      "incoming" -> "Incoming $type Call"
      "outgoing" -> "Outgoing $type Call"
      else -> "$type Call"
    }
  }

  private fun displayName(): String =
    stringValue(state["toUserName"] ?: state["to_user_name"])
      ?: stringValue(state["fromUserName"] ?: state["from_user_name"])
      ?: "Vibe Call"

  private fun readState(intent: Intent): Map<String, Any?> =
    linkedMapOf<String, Any?>(
      "state" to intent.getStringExtra(extraState).orEmpty().ifBlank { "ringing" },
      "direction" to intent.getStringExtra(extraDirection).orEmpty().ifBlank { "outgoing" },
      "callId" to intent.getStringExtra(extraCallId).orEmpty(),
      "callType" to intent.getStringExtra(extraCallType).orEmpty().ifBlank { "voice" },
      "toUserId" to intent.getStringExtra(extraToUserId).orEmpty(),
      "toUserName" to intent.getStringExtra(extraToUserName).orEmpty(),
      "toUserImage" to intent.getStringExtra(extraToUserImage).orEmpty(),
      "fromUserId" to intent.getStringExtra(extraFromUserId).orEmpty(),
      "fromUserName" to intent.getStringExtra(extraFromUserName).orEmpty(),
      "fromUserImage" to intent.getStringExtra(extraFromUserImage).orEmpty(),
      "chatId" to intent.getStringExtra(extraChatId).orEmpty(),
      "note" to intent.getStringExtra(extraNote).orEmpty(),
      "failureReason" to intent.getStringExtra(extraFailureReason).orEmpty(),
      "signalingAccepted" to intent.getBooleanExtra(extraSignalingAccepted, true),
      "signalingQueued" to intent.getBooleanExtra(extraSignalingQueued, false),
    )

  private fun readRetryPayload(intent: Intent): Map<String, Any?> =
    linkedMapOf<String, Any?>(
      "event" to "call-start",
      "callId" to intent.getStringExtra(extraCallId).orEmpty(),
      "callType" to intent.getStringExtra(extraCallType).orEmpty().ifBlank { "voice" },
      "toUserId" to intent.getStringExtra(extraToUserId).orEmpty(),
      "toUserName" to intent.getStringExtra(extraToUserName).orEmpty(),
      "toUserImage" to intent.getStringExtra(extraToUserImage).orEmpty(),
      "chatId" to intent.getStringExtra(extraChatId).orEmpty(),
    )

  private fun stringValue(value: Any?): String? =
    value?.toString()?.trim()?.takeIf { it.isNotEmpty() }

  private fun boolValue(value: Any?): Boolean =
    when (value) {
      is Boolean -> value
      is Number -> value.toInt() != 0
      is String -> value.equals("true", ignoreCase = true) || value == "1" || value.equals("yes", ignoreCase = true)
      else -> false
    }

  private fun dp(value: Int): Int =
    (value * resources.displayMetrics.density).toInt()

  private fun ovalDrawable(color: Int): GradientDrawable =
    GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(color)
    }

  private fun roundedDrawable(color: Int, radius: Float): GradientDrawable =
    GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = radius
      setColor(color)
    }
}
