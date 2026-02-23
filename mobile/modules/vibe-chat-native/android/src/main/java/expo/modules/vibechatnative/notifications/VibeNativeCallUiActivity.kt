package expo.modules.vibechatnative.notifications

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.ShapeDrawable
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity

class VibeNativeCallUiActivity : ComponentActivity() {
  private lateinit var root: FrameLayout
  private lateinit var chip: TextView
  private lateinit var avatar: FrameLayout
  private lateinit var initials: TextView
  private lateinit var nameText: TextView
  private lateinit var statusText: TextView
  private lateinit var utilityRow: LinearLayout
  private lateinit var incomingRow: LinearLayout
  private lateinit var activeRow: LinearLayout
  private val buttons = LinkedHashMap<String, ImageButton>()

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    Log.d("VibeNativeCall", "UiActivity.onCreate savedState=${savedInstanceState != null}")
    buildUi()
    VibeNativeCallUiBridge.attachActivity(this)
  }

  override fun onDestroy() {
    Log.d("VibeNativeCall", "UiActivity.onDestroy finishing=$isFinishing")
    super.onDestroy()
    VibeNativeCallUiBridge.detachActivity(this)
  }

  @Deprecated("Native call screen is controlled by call state")
  override fun onBackPressed() {
    Log.d("VibeNativeCall", "UiActivity.onBackPressed ignored=true")
    // Keep the call UI visible until JS/native call state explicitly hides it.
  }

  fun applyUiState(state: Map<String, Any?>) {
    runOnUiThread {
      val mode = state.stringValue("mode") ?: "hidden"
      Log.d(
        "VibeNativeCall",
        "UiActivity.applyUiState mode=$mode visible=${state.boolValue("visible")} callId=${state["callId"] ?: state["call_id"]} status=${state.stringValue("callStatus")}"
      )
      if (mode == "hidden") {
        Log.d("VibeNativeCall", "UiActivity.applyUiState finish reason=hidden")
        finish()
        return@runOnUiThread
      }
      val isDark = state.boolValue("isDark") ?: true
      val palette = if (isDark) darkPalette else lightPalette
      root.setBackgroundColor(palette.background)
      chip.background = rounded(palette.surface, dp(999))
      chip.setTextColor(palette.subtle)
      avatar.background = rounded(palette.avatar, dp(80))
      initials.setTextColor(palette.text)
      nameText.setTextColor(palette.text)
      statusText.setTextColor(palette.subtle)

      val remoteName = state.stringValue("remoteUserName") ?: "Unknown"
      initials.text = remoteName.firstOrNull()?.uppercase() ?: "?"
      nameText.text = remoteName

      val callType = state.stringValue("callType") ?: "voice"
      chip.text = when (mode) {
        "incoming" -> if (callType == "video") "Incoming video call" else "Incoming voice call"
        else -> if (callType == "video") "Vibe Video" else "Vibe Audio"
      }

      statusText.text = if (mode == "incoming") {
        "Tap accept to answer"
      } else {
        activeStatus(state)
      }

      utilityRow.visibility = if (mode == "incoming") View.VISIBLE else View.GONE
      incomingRow.visibility = if (mode == "incoming") View.VISIBLE else View.GONE
      activeRow.visibility = if (mode == "active") View.VISIBLE else View.GONE

      styleButton("incomingDecline", palette.red, Color.WHITE)
      styleButton("incomingAccept", palette.blue, Color.WHITE)
      styleButton("msg", palette.surface, palette.text)
      styleButton("remind", palette.surface, palette.text)

      val isMuted = state.boolValue("isMuted") ?: false
      val isSpeaker = state.boolValue("isSpeakerOn") ?: false
      val isVideo = state.boolValue("isVideoEnabled") ?: false
      styleToggle("mute", isMuted, palette)
      styleToggle("speaker", isSpeaker, palette)
      styleToggle("video", isVideo, palette)
      styleButton("flip", palette.surface, palette.text)
      styleButton("end", palette.red, Color.WHITE)
      buttons["flip"]?.visibility = if ((state.boolValue("canFlipCamera") ?: false) && isVideo) View.VISIBLE else View.GONE
    }
  }

  private fun activeStatus(state: Map<String, Any?>): String {
    return when (state.stringValue("callStatus")) {
      "connecting" -> "Connecting..."
      "reconnecting" -> "Reconnecting..."
      "ringing" -> "Ringing..."
      "active" -> formatDuration(state.longValue("callDuration") ?: 0L)
      else -> state.stringValue("callStatus") ?: "In call"
    }
  }

  private fun formatDuration(total: Long): String {
    val m = total / 60
    val s = total % 60
    return "$m:${s.toString().padStart(2, '0')}"
  }

  private fun buildUi() {
    root = FrameLayout(this).apply {
      setPadding(dp(20), dp(28), dp(20), dp(20))
    }
    setContentView(root)

    val content = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
    }
    root.addView(content)

    chip = TextView(this).apply {
      textSize = 14f
      setTypeface(Typeface.DEFAULT_BOLD)
      setPadding(dp(14), dp(8), dp(14), dp(8))
    }
    content.addView(chip)

    avatar = FrameLayout(this)
    initials = TextView(this).apply {
      textSize = 52f
      gravity = Gravity.CENTER
      setTypeface(Typeface.DEFAULT_BOLD)
    }
    avatar.addView(initials, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
    content.addView(avatar, LinearLayout.LayoutParams(dp(156), dp(156)).apply { topMargin = dp(40) })

    nameText = TextView(this).apply {
      textSize = 28f
      gravity = Gravity.CENTER
      setTypeface(Typeface.DEFAULT_BOLD)
    }
    content.addView(nameText, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(14) })

    statusText = TextView(this).apply {
      textSize = 15f
      gravity = Gravity.CENTER
    }
    content.addView(statusText, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })

    content.addView(View(this), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

    utilityRow = row(14)
    utilityRow.addView(buttonStack("msg", "\u2709", "Message", 52))
    utilityRow.addView(buttonStack("remind", "\u23F0", "Remind", 52))
    content.addView(utilityRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(20) })

    incomingRow = row(20)
    incomingRow.addView(buttonStack("incomingDecline", "\u2715", "Decline", 76))
    incomingRow.addView(buttonStack("incomingAccept", "\u2713", "Accept", 76))
    content.addView(incomingRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(18) })

    activeRow = row(8)
    activeRow.addView(buttonStack("mute", "\uD83C\uDFA4", "Mic", 48))
    activeRow.addView(buttonStack("video", "\u25B6", "Video", 48))
    activeRow.addView(buttonStack("flip", "\u21C4", "Flip", 48))
    activeRow.addView(buttonStack("speaker", "\uD83D\uDD0A", "Audio", 48))
    activeRow.addView(buttonStack("end", "\u2715", "End", 56))
    content.addView(activeRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(16) })
  }

  private fun row(spacingDp: Int): LinearLayout {
    return LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
      dividerDrawable = ShapeDrawable().apply {
        intrinsicWidth = dp(spacingDp)
        intrinsicHeight = 1
        paint.color = Color.TRANSPARENT
      }
      showDividers = LinearLayout.SHOW_DIVIDER_MIDDLE
    }
  }

  private fun buttonStack(key: String, glyph: String, label: String, sizeDp: Int): LinearLayout {
    val wrap = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
    }
    val btn = ImageButton(this).apply {
      background = rounded(darkPalette.surface, dp(sizeDp / 2))
      setImageDrawable(null)
      setOnClickListener {
        val eventType =
          when (key) {
            "incomingAccept" -> "accept"
            "incomingDecline" -> "decline"
            "msg" -> "message"
            "remind" -> "remind"
            "mute" -> "toggleMute"
            "speaker" -> "toggleSpeaker"
            "video" -> "toggleVideo"
            "flip" -> "flipCamera"
            "end" -> "end"
            else -> "noop"
          }
        Log.d("VibeNativeCall", "UiActivity.buttonTap key=$key event=$eventType")
        VibeNativeCallUiBridge.emitUiEvent(eventType)
      }
    }
    val overlay = TextView(this).apply {
      text = glyph
      gravity = Gravity.CENTER
      textSize = if (sizeDp >= 70) 26f else 18f
      setTypeface(Typeface.DEFAULT_BOLD)
      setTextColor(Color.WHITE)
    }
    val holder = FrameLayout(this).apply {
      addView(btn, FrameLayout.LayoutParams(dp(sizeDp), dp(sizeDp)))
      addView(overlay, FrameLayout.LayoutParams(dp(sizeDp), dp(sizeDp)))
    }
    val name = TextView(this).apply {
      text = label
      textSize = if (sizeDp >= 70) 13f else 10f
      setTypeface(Typeface.DEFAULT_BOLD)
      gravity = Gravity.CENTER
      setTextColor(Color.WHITE)
    }
    wrap.addView(holder)
    wrap.addView(name, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
      topMargin = dp(if (sizeDp >= 70) 8 else 5)
    })
    buttons[key] = btn
    return wrap
  }

  private fun styleToggle(key: String, active: Boolean, palette: Palette) {
    styleButton(key, if (active) palette.text else palette.surface, if (active) palette.background else palette.text)
  }

  private fun styleButton(key: String, background: Int, tint: Int) {
    buttons[key]?.let { btn ->
      btn.background = rounded(background, btn.width.takeIf { it > 0 }?.div(2) ?: dp(24))
      val parent = btn.parent as? FrameLayout
      val labelView = (parent?.parent as? LinearLayout)?.getChildAt(1) as? TextView
      labelView?.setTextColor(tint)
      val glyphOverlay = parent?.getChildAt(1) as? TextView
      glyphOverlay?.setTextColor(tint)
    }
  }

  private fun rounded(color: Int, radius: Int): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = radius.toFloat()
      setColor(color)
      setStroke(dp(1), Color.argb(26, 255, 255, 255))
    }
  }

  private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

  private data class Palette(
    val background: Int, val text: Int, val subtle: Int, val surface: Int, val avatar: Int, val blue: Int, val red: Int
  )

  private val darkPalette = Palette(
    background = Color.parseColor("#0F1116"),
    text = Color.WHITE,
    subtle = Color.parseColor("#B7BDD0"),
    surface = Color.parseColor("#232A36"),
    avatar = Color.parseColor("#1B2030"),
    blue = Color.parseColor("#2B70FF"),
    red = Color.parseColor("#E74C5B"),
  )
  private val lightPalette = Palette(
    background = Color.parseColor("#F4F7FB"),
    text = Color.parseColor("#111722"),
    subtle = Color.parseColor("#5A6478"),
    surface = Color.parseColor("#E7EDF8"),
    avatar = Color.parseColor("#DEE7F6"),
    blue = Color.parseColor("#2B70FF"),
    red = Color.parseColor("#E74C5B"),
  )
}

private fun Map<String, Any?>.stringValue(key: String): String? = this[key]?.toString()?.takeIf { it.isNotBlank() }
private fun Map<String, Any?>.boolValue(key: String): Boolean? = when (val v = this[key]) {
  is Boolean -> v
  is String -> v.equals("true", true)
  is Number -> v.toInt() != 0
  else -> null
}
private fun Map<String, Any?>.longValue(key: String): Long? = when (val v = this[key]) {
  is Number -> v.toLong()
  is String -> v.toLongOrNull()
  else -> null
}
