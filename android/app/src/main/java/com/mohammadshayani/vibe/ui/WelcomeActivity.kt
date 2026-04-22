package com.mohammadshayani.vibe.ui

import android.content.Intent
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class WelcomeActivity : AppCompatActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    title = "Welcome"

    val root = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      setPadding(dp(24f), dp(24f), dp(24f), dp(24f))
    }

    val titleView = TextView(this).apply {
      text = "Vibe"
      textSize = 34f
      gravity = Gravity.CENTER
    }
    root.addView(titleView)

    val bodyView = TextView(this).apply {
      text =
        "This is the extracted native shell. It boots without Expo, stores auth securely, and opens the native home list."
      textSize = 16f
      gravity = Gravity.CENTER
      setPadding(0, dp(12f), 0, dp(20f))
    }
    root.addView(bodyView)

    val continueButton = Button(this).apply {
      text = "Continue"
      setOnClickListener {
        startActivity(Intent(this@WelcomeActivity, AuthActivity::class.java))
      }
    }
    root.addView(
      continueButton,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      )
    )

    setContentView(root)
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
}
