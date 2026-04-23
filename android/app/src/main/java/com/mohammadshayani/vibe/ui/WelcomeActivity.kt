package com.mohammadshayani.vibe.ui

import android.animation.ValueAnimator
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.drawable.GradientDrawable
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.google.android.material.button.MaterialButton

class WelcomeActivity : AppCompatActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    val palette = WelcomeSurfacePalette.resolve(this)
    WindowCompat.setDecorFitsSystemWindows(window, false)
    window.statusBarColor = Color.TRANSPARENT
    window.navigationBarColor = palette.navigationBarColor
    WindowInsetsControllerCompat(window, window.decorView).apply {
      isAppearanceLightStatusBars = !palette.isDark
      isAppearanceLightNavigationBars = !palette.isDark
    }

    val root = FrameLayout(this).apply {
      setBackgroundColor(palette.backgroundColor)
    }

    val backdropView = WelcomeBackdropView(this)
    root.addView(
      backdropView,
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      )
    )

    val heroContent = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.START
    }

    val eyebrowView = TextView(this).apply {
      text = "Private by default"
      setTextColor(palette.eyebrowTextColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
      gravity = Gravity.START
    }
    heroContent.addView(
      eyebrowView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      )
    )

    val titleView = TextView(this).apply {
      text = "Vibe"
      setTextColor(palette.primaryTextColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 58f)
      typeface = android.graphics.Typeface.create("sans-serif-black", android.graphics.Typeface.NORMAL)
      gravity = Gravity.START
    }
    heroContent.addView(
      titleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      )
    )

    val subtitleView = TextView(this).apply {
      text = "Private chat, clear focus."
      setTextColor(palette.primaryTextColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
      typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
      gravity = Gravity.START
      setLineSpacing(0f, 1.06f)
    }
    heroContent.addView(
      subtitleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(8f)
      }
    )

    val detailsView = TextView(this).apply {
      text = "Use your secret key to return, or create a new identity in seconds."
      setTextColor(palette.secondaryTextColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
      typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
      gravity = Gravity.START
      setLineSpacing(0f, 1.12f)
    }
    heroContent.addView(
      detailsView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(10f)
      }
    )

    val footer = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      this.background = palette.footerDrawable(this@WelcomeActivity)
      elevation = dp(18f).toFloat()
      setPadding(dp(24f), dp(22f), dp(24f), dp(24f))
    }

    val signUpButton = makePrimaryButton("Create Account", palette).apply {
      setOnClickListener {
        presentAuth(AuthActivity.Mode.SIGN_UP)
      }
    }
    footer.addView(signUpButton, buttonLayoutParams(topMargin = 0))

    val signInButton = makeSecondaryButton("Sign In", palette).apply {
      setOnClickListener {
        presentAuth(AuthActivity.Mode.SIGN_IN)
      }
    }
    footer.addView(signInButton, buttonLayoutParams(topMargin = 12))

    root.addView(
      heroContent,
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
        Gravity.TOP or Gravity.START,
      )
    )
    root.addView(
      footer,
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
        Gravity.BOTTOM,
      )
    )

    ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
      heroContent.setPadding(
        dp(28f),
        bars.top + dp(54f),
        dp(28f),
        0,
      )
      footer.setPadding(
        dp(24f),
        dp(22f),
        dp(24f),
        bars.bottom + dp(24f),
      )
      insets
    }

    setContentView(root)
  }

  private fun presentAuth(mode: AuthActivity.Mode) {
    AuthSheetPresenter.show(
      activity = this,
      mode = mode,
      onAuthenticated = { launchHome() },
    )
  }

  private fun launchHome() {
    startActivity(
      Intent(this, ChatHomeActivity::class.java).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
      }
    )
    finish()
  }

  private fun makePrimaryButton(
    title: String,
    palette: WelcomeSurfacePalette,
  ): MaterialButton {
    return MaterialButton(this).apply {
      text = title
      isAllCaps = false
      setTextColor(palette.primaryButtonTextColor)
      textSize = 16f
      cornerRadius = dp(28f)
      strokeWidth = dp(1f)
      strokeColor = ColorStateList.valueOf(palette.primaryButtonBorderColor)
      backgroundTintList = ColorStateList.valueOf(palette.primaryButtonBackgroundColor)
      insetTop = 0
      insetBottom = 0
      minimumHeight = dp(56f)
    }
  }

  private fun makeSecondaryButton(
    title: String,
    palette: WelcomeSurfacePalette,
  ): MaterialButton {
    return MaterialButton(this).apply {
      text = title
      isAllCaps = false
      textSize = 16f
      setTextColor(palette.secondaryButtonTextColor)
      cornerRadius = dp(28f)
      strokeWidth = dp(1f)
      strokeColor = ColorStateList.valueOf(palette.secondaryButtonBorderColor)
      backgroundTintList = ColorStateList.valueOf(palette.secondaryButtonBackgroundColor)
      insetTop = 0
      insetBottom = 0
      minimumHeight = dp(56f)
    }
  }

  private fun buttonLayoutParams(topMargin: Int): LinearLayout.LayoutParams {
    return LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      this.topMargin = topMargin
    }
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
}

class WelcomeBackdropView(context: android.content.Context) : View(context) {
  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
  private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
  private var phase = 0f
  private val animator =
    ValueAnimator.ofFloat(0f, 1f).apply {
      duration = 18_000L
      repeatCount = ValueAnimator.INFINITE
      interpolator = LinearInterpolator()
      addUpdateListener {
        phase = it.animatedFraction
        invalidate()
      }
    }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    animator.start()
  }

  override fun onDetachedFromWindow() {
    animator.cancel()
    super.onDetachedFromWindow()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (width == 0 || height == 0) return
    val palette = WelcomeBackdropPalette.resolve(context)
    val maxDimension = kotlin.math.max(width, height).toFloat()

    fillPaint.shader =
      LinearGradient(
        width * 0.14f,
        0f,
        width * 0.94f,
        height.toFloat(),
        intArrayOf(
          palette.baseTopColor,
          palette.baseMidColor,
          palette.baseBottomColor,
        ),
        null,
        Shader.TileMode.CLAMP,
      )
    canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), fillPaint)

    drawGlow(
      canvas = canvas,
      centerX = width * (0.94f + 0.01f * kotlin.math.sin(phase * Math.PI * 2).toFloat()),
      centerY = height * (0.06f + 0.01f * kotlin.math.cos(phase * Math.PI * 2).toFloat()),
      radius = maxDimension * 0.42f,
      color = palette.sourceGlowColor,
    )
    drawGlow(
      canvas = canvas,
      centerX = width * (0.72f + 0.02f * kotlin.math.cos(phase * Math.PI * 2).toFloat()),
      centerY = height * (0.18f + 0.02f * kotlin.math.sin(phase * Math.PI * 2).toFloat()),
      radius = maxDimension * 0.56f,
      color = palette.beamGlowColor,
    )
    drawGlow(
      canvas = canvas,
      centerX = width * (0.44f + 0.02f * kotlin.math.sin(phase * Math.PI * 2).toFloat()),
      centerY = height * (0.29f + 0.02f * kotlin.math.cos(phase * Math.PI * 2).toFloat()),
      radius = maxDimension * 0.50f,
      color = palette.textGlowColor,
    )
    drawGlow(
      canvas = canvas,
      centerX = width * (0.18f + 0.04f * kotlin.math.cos(phase * Math.PI * 2).toFloat()),
      centerY = height * (0.78f + 0.03f * kotlin.math.sin(phase * Math.PI * 2).toFloat()),
      radius = maxDimension * 0.96f,
      color = palette.ambientGlowColor,
    )
  }

  private fun drawGlow(
    canvas: Canvas,
    centerX: Float,
    centerY: Float,
    radius: Float,
    color: Int,
  ) {
    glowPaint.shader =
      RadialGradient(
        centerX,
        centerY,
        radius,
        intArrayOf(color, Color.TRANSPARENT),
        floatArrayOf(0f, 1f),
        Shader.TileMode.CLAMP,
      )
    canvas.drawCircle(centerX, centerY, radius, glowPaint)
  }
}

private data class WelcomeSurfacePalette(
  val isDark: Boolean,
  val backgroundColor: Int,
  val navigationBarColor: Int,
  val eyebrowTextColor: Int,
  val primaryTextColor: Int,
  val secondaryTextColor: Int,
  val footerTopColor: Int,
  val footerBottomColor: Int,
  val footerBorderColor: Int,
  val primaryButtonBackgroundColor: Int,
  val primaryButtonTextColor: Int,
  val primaryButtonBorderColor: Int,
  val secondaryButtonBackgroundColor: Int,
  val secondaryButtonTextColor: Int,
  val secondaryButtonBorderColor: Int,
) {
  fun footerDrawable(context: android.content.Context): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadii =
        floatArrayOf(
          dp(context, 34f).toFloat(),
          dp(context, 34f).toFloat(),
          dp(context, 34f).toFloat(),
          dp(context, 34f).toFloat(),
          0f,
          0f,
          0f,
          0f,
        )
      colors = intArrayOf(footerTopColor, footerBottomColor)
      setStroke(dp(context, 1f), footerBorderColor)
    }
  }

  companion object {
    fun resolve(context: android.content.Context): WelcomeSurfacePalette {
      val isDark = isNightMode(context)
      return if (isDark) {
        WelcomeSurfacePalette(
          isDark = true,
          backgroundColor = Color.rgb(8, 13, 22),
          navigationBarColor = Color.BLACK,
          eyebrowTextColor = Color.argb(194, 255, 255, 255),
          primaryTextColor = Color.WHITE,
          secondaryTextColor = Color.argb(210, 213, 224, 236),
          footerTopColor = Color.argb(238, 18, 24, 37),
          footerBottomColor = Color.argb(232, 10, 15, 25),
          footerBorderColor = Color.argb(44, 255, 255, 255),
          primaryButtonBackgroundColor = Color.rgb(228, 237, 252),
          primaryButtonTextColor = Color.rgb(16, 20, 29),
          primaryButtonBorderColor = Color.argb(40, 255, 255, 255),
          secondaryButtonBackgroundColor = Color.argb(18, 255, 255, 255),
          secondaryButtonTextColor = Color.WHITE,
          secondaryButtonBorderColor = Color.argb(44, 255, 255, 255),
        )
      } else {
        WelcomeSurfacePalette(
          isDark = false,
          backgroundColor = Color.rgb(241, 246, 255),
          navigationBarColor = Color.WHITE,
          eyebrowTextColor = Color.argb(186, 58, 74, 94),
          primaryTextColor = Color.rgb(23, 29, 37),
          secondaryTextColor = Color.argb(196, 67, 78, 94),
          footerTopColor = Color.argb(246, 255, 255, 255),
          footerBottomColor = Color.argb(240, 242, 247, 255),
          footerBorderColor = Color.argb(132, 255, 255, 255),
          primaryButtonBackgroundColor = Color.rgb(18, 24, 34),
          primaryButtonTextColor = Color.WHITE,
          primaryButtonBorderColor = Color.argb(22, 255, 255, 255),
          secondaryButtonBackgroundColor = Color.argb(214, 255, 255, 255),
          secondaryButtonTextColor = Color.rgb(23, 29, 37),
          secondaryButtonBorderColor = Color.rgb(212, 223, 237),
        )
      }
    }
  }
}

private data class WelcomeBackdropPalette(
  val baseTopColor: Int,
  val baseMidColor: Int,
  val baseBottomColor: Int,
  val sourceGlowColor: Int,
  val beamGlowColor: Int,
  val textGlowColor: Int,
  val ambientGlowColor: Int,
) {
  companion object {
    fun resolve(context: android.content.Context): WelcomeBackdropPalette {
      return if (isNightMode(context)) {
        WelcomeBackdropPalette(
          baseTopColor = Color.rgb(10, 16, 28),
          baseMidColor = Color.rgb(17, 24, 38),
          baseBottomColor = Color.rgb(6, 9, 17),
          sourceGlowColor = Color.argb(224, 250, 227, 148),
          beamGlowColor = Color.argb(110, 104, 194, 255),
          textGlowColor = Color.argb(54, 246, 250, 255),
          ambientGlowColor = Color.argb(88, 29, 58, 92),
        )
      } else {
        WelcomeBackdropPalette(
          baseTopColor = Color.rgb(244, 247, 255),
          baseMidColor = Color.rgb(230, 237, 250),
          baseBottomColor = Color.rgb(214, 225, 242),
          sourceGlowColor = Color.argb(146, 252, 205, 118),
          beamGlowColor = Color.argb(74, 91, 166, 255),
          textGlowColor = Color.argb(46, 255, 255, 255),
          ambientGlowColor = Color.argb(72, 137, 166, 214),
        )
      }
    }
  }
}

private fun dp(context: android.content.Context, value: Float): Int =
  TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, context.resources.displayMetrics).toInt()
