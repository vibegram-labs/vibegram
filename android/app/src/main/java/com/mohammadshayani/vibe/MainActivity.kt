package com.mohammadshayani.vibe

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.mohammadshayani.vibe.session.AppSessionConfig
import com.mohammadshayani.vibe.ui.ChatHomeActivity
import com.mohammadshayani.vibe.ui.NativeCallActivity
import com.mohammadshayani.vibe.ui.WelcomeActivity

class MainActivity : AppCompatActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    com.mohammadshayani.vibe.ui.AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    if (openNativeCallFromIntent(intent)) {
      finish()
      return
    }
    val destination =
      if (AppSessionConfig.current(applicationContext) != null) {
        ChatHomeActivity::class.java
      } else {
        WelcomeActivity::class.java
      }
    startActivity(Intent(this, destination))
    finish()
  }

  private fun openNativeCallFromIntent(source: Intent?): Boolean {
    val extras = source?.extras ?: return false
    val hasCall =
      source.getBooleanExtra("vibeNativeCall", false) ||
        !source.getStringExtra("callId").isNullOrBlank() ||
        !source.getStringExtra("call_id").isNullOrBlank()
    if (!hasCall) return false
    val state = linkedMapOf<String, Any?>()
    extras.keySet().forEach { key ->
      state[key] = extras.get(key)
    }
    if (state["state"] == null) state["state"] = "ringing"
    if (state["direction"] == null) state["direction"] = "incoming"
    startActivity(NativeCallActivity.intent(this, state))
    return true
  }
}
