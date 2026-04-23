package com.mohammadshayani.vibe

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.mohammadshayani.vibe.session.AppSessionConfig
import com.mohammadshayani.vibe.ui.AuthActivity
import com.mohammadshayani.vibe.ui.ChatHomeActivity
import com.mohammadshayani.vibe.ui.WelcomeActivity

class MainActivity : AppCompatActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    com.mohammadshayani.vibe.ui.AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    val destination =
      if (AppSessionConfig.current(applicationContext) != null) {
        ChatHomeActivity::class.java
      } else {
        WelcomeActivity::class.java
      }
    startActivity(Intent(this, destination))
    finish()
  }
}
