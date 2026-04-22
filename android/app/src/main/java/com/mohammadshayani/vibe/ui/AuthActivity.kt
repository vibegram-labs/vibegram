package com.mohammadshayani.vibe.ui

import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.mohammadshayani.vibe.packet.PacketBootstrapService
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.session.AppSessionConfig
import com.mohammadshayani.vibe.storage.ChatEngineStore

class AuthActivity : AppCompatActivity() {
  private lateinit var apiField: EditText
  private lateinit var socketField: EditText
  private lateinit var userField: EditText
  private lateinit var tokenField: EditText
  private lateinit var transportField: EditText

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    title = "Native Auth"

    val current = AppSessionConfig.current(applicationContext)

    apiField = makeField("API Base URL", current?.apiBaseUrl ?: "https://api.vibegram.io")
    socketField = makeField("Socket URL", current?.socketUrl)
    userField = makeField("User ID", current?.userId)
    tokenField = makeField("Auth Token", current?.authToken).apply {
      inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
    }
    transportField = makeField("Transport Mode", current?.transportMode?.wireValue ?: PacketTransportMode.DIRECT.wireValue)

    val root = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.TOP
      setPadding(dp(20f), dp(24f), dp(20f), dp(20f))
    }

    root.addView(apiField)
    root.addView(socketField)
    root.addView(userField)
    root.addView(tokenField)
    root.addView(transportField)

    val saveButton = Button(this).apply {
      text = "Save and Open Home"
      setOnClickListener { saveAndContinue() }
    }
    root.addView(saveButton)

    val footer = TextView(this).apply {
      text =
        "The token is stored through the extracted secure store and the home list uses the same chat API shape as the previous native module."
      textSize = 13f
      setPadding(0, dp(12f), 0, 0)
    }
    root.addView(footer)

    setContentView(root)
  }

  private fun makeField(hint: String, value: String?): EditText {
    return EditText(this).apply {
      this.hint = hint
      setText(value.orEmpty())
      setSingleLine()
      layoutParams = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        bottomMargin = dp(12f)
      }
    }
  }

  private fun saveAndContinue() {
    val apiBaseUrl = apiField.text.toString().trim()
    val userId = userField.text.toString().trim()
    val authToken = tokenField.text.toString().trim()
    val transportMode = PacketTransportMode.from(transportField.text?.toString())
    if (apiBaseUrl.isEmpty() || userId.isEmpty() || authToken.isEmpty()) {
      Toast.makeText(this, "API base URL, user ID, and token are required.", Toast.LENGTH_SHORT).show()
      return
    }

    val current = ChatEngineStore.getConfig(applicationContext).toMutableMap()
    val config = AppSessionConfig(
      apiBaseUrl = apiBaseUrl,
      socketUrl = socketField.text.toString().trim().ifEmpty { AppSessionConfig.current(applicationContext)?.socketUrl ?: "" },
      userId = userId,
      authToken = authToken,
      transportMode = transportMode,
    )
    current.putAll(config.toPayload())
    ChatEngineStore.setConfig(applicationContext, current)
    Thread {
      AppSessionConfig.current(applicationContext)?.let {
        PacketBootstrapService.prefetchIfNeeded(applicationContext, it)
      }
    }.start()
    startActivity(Intent(this, ChatHomeActivity::class.java))
    finish()
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
}
