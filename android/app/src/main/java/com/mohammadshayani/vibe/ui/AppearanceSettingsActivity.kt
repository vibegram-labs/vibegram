package com.mohammadshayani.vibe.ui

import android.app.Activity
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
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.button.MaterialButton

class AppearanceSettingsActivity : AppCompatActivity() {
  private var themeSignature = ""

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    themeSignature = appThemeSignature(this)
    render()
  }

  override fun onResume() {
    super.onResume()
    val nextSignature = appThemeSignature(this)
    if (nextSignature != themeSignature) {
      themeSignature = nextSignature
      render()
    }
  }

  private fun render() {
    val palette = resolveAppThemePalette(this)
    applyThemedSystemBars(this, palette)

    val root = FrameLayout(this).apply {
      setBackgroundColor(palette.backgroundColor)
    }

    val content = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
    }
    root.addView(
      content,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    val header = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      setPadding(dp(16f), dp(10f), dp(16f), dp(10f))
    }
    content.addView(
      header,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    val backButton = ImageView(this).apply {
      setImageResource(android.R.drawable.ic_media_previous)
      setColorFilter(palette.textColor)
      background = selectableItemBackground()
      setPadding(dp(10f), dp(10f), dp(10f), dp(10f))
      setOnClickListener { finish() }
    }
    header.addView(
      backButton,
      LinearLayout.LayoutParams(dp(40f), dp(40f)),
    )

    val titleColumn = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
    }
    header.addView(
      titleColumn,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
        marginStart = dp(8f)
      },
    )

    titleColumn.addView(sectionTitle("Appearance", palette, 20f, "sans-serif-medium"))
    titleColumn.addView(
      TextView(this).apply {
        text = "Mode and plate apply across the Android shell."
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      },
    )

    val scrollView = ScrollView(this).apply {
      isFillViewport = true
      clipToPadding = false
    }
    content.addView(
      scrollView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )

    val stack = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(16f), dp(10f), dp(16f), dp(24f))
    }
    scrollView.addView(
      stack,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    stack.addView(buildPreviewCard(palette))
    stack.addView(space(18f))
    stack.addView(sectionLabel("MODE", palette))
    stack.addView(space(10f))
    stack.addView(buildModeList(palette))
    stack.addView(space(22f))
    stack.addView(sectionLabel("COLOR PLATE", palette))
    stack.addView(space(12f))
    stack.addView(buildPlateGrid())
    stack.addView(space(18f))
    stack.addView(
      TextView(this).apply {
        text = "Chat wallpaper and shell tint stay tied to the same selected plate."
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setLineSpacing(0f, 1.1f)
      },
    )

    ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
      header.setPadding(dp(16f), bars.top + dp(10f), dp(16f), dp(10f))
      stack.setPadding(dp(16f), dp(10f), dp(16f), bars.bottom + dp(24f))
      insets
    }

    setContentView(root)
  }

  private fun buildPreviewCard(palette: AppThemePalette): View {
    val card = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      background =
        GradientDrawable(
          GradientDrawable.Orientation.TL_BR,
          intArrayOf(
            adjustColor(palette.backgroundColor, if (palette.isDark) 0.08f else 0.02f),
            adjustColor(palette.cardColor, if (palette.isDark) 0.02f else -0.02f),
          ),
        ).apply {
          cornerRadius = dp(26f).toFloat()
          setStroke(dp(1f), palette.borderColor)
        }
      setPadding(dp(18f), dp(18f), dp(18f), dp(18f))
    }

    card.addView(
      TextView(this).apply {
        text = "Live Preview"
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      },
    )

    val bubbleStack = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(0, dp(16f), 0, 0)
    }
    card.addView(bubbleStack)

    bubbleStack.addView(
      previewBubble("Soft background, native layout.", palette.bubbleThemColor, palette.textColor, Gravity.START),
    )
    bubbleStack.addView(space(8f))
    bubbleStack.addView(
      previewBubble("Accent stays on the bubble, not the whole screen.", palette.bubbleMeColor, palette.buttonTextColor, Gravity.END),
    )
    bubbleStack.addView(space(18f))

    val footer = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    bubbleStack.addView(footer)

    footer.addView(
      pillLabel(
        AppAppearanceController.current(this).title,
        palette,
        filled = false,
      ),
    )
    footer.addView(space(8f, horizontal = true))
    footer.addView(
      pillLabel(
        AppThemePlateController.current(this).title,
        palette,
        filled = true,
      ),
    )

    return card
  }

  private fun buildModeList(palette: AppThemePalette): View {
    val container = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      background = roundedRect(palette.cardColor, palette.borderColor, 24f)
    }
    val selected = AppAppearanceController.current(this)
    AppAppearanceOption.entries.forEachIndexed { index, option ->
      container.addView(
        selectionRow(
          title = option.title,
          detail = when (option) {
            AppAppearanceOption.SYSTEM -> "Follow device appearance"
            AppAppearanceOption.LIGHT -> "Always use the light shell"
            AppAppearanceOption.DARK -> "Always use the dark shell"
          },
          selected = option == selected,
          palette = palette,
        ) {
          if (option != AppAppearanceController.current(this)) {
            AppAppearanceController.setOption(this, option)
            setResult(Activity.RESULT_OK)
            themeSignature = appThemeSignature(this)
            render()
          }
        },
      )
      if (index != AppAppearanceOption.entries.lastIndex) {
        container.addView(divider(palette))
      }
    }
    return container
  }

  private fun buildPlateGrid(): View {
    val selected = AppThemePlateController.current(this)
    val grid = GridLayout(this).apply {
      columnCount = 2
      rowCount = (AppThemePlateOption.entries.size + 1) / 2
      useDefaultMargins = false
    }

    AppThemePlateOption.entries.forEach { option ->
      val optionPalette = resolveAppThemePalette(this, option)
      val card = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background =
          GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(22f).toFloat()
            colors = intArrayOf(
              adjustColor(optionPalette.backgroundColor, if (optionPalette.isDark) 0.08f else 0.03f),
              adjustColor(optionPalette.cardColor, if (optionPalette.isDark) 0.02f else -0.02f),
            )
            orientation = GradientDrawable.Orientation.TL_BR
            setStroke(
              dp(if (option == selected) 2f else 1f),
              if (option == selected) optionPalette.accentColor else optionPalette.borderColor,
            )
          }
        foreground = selectableItemBackground()
        setPadding(dp(14f), dp(14f), dp(14f), dp(14f))
        setOnClickListener {
          if (option != AppThemePlateController.current(this@AppearanceSettingsActivity)) {
            AppThemePlateController.setOption(this@AppearanceSettingsActivity, option)
            setResult(Activity.RESULT_OK)
            themeSignature = appThemeSignature(this@AppearanceSettingsActivity)
            render()
          }
        }
      }

      val swatch = View(this).apply {
        background =
          GradientDrawable(
            GradientDrawable.Orientation.LEFT_RIGHT,
            intArrayOf(optionPalette.bubbleThemColor, optionPalette.bubbleMeColor),
          ).apply {
            cornerRadius = dp(16f).toFloat()
          }
      }
      card.addView(
        swatch,
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.MATCH_PARENT,
          dp(84f),
        ),
      )
      card.addView(space(12f))
      card.addView(sectionTitle(option.title, optionPalette, 16f, "sans-serif-medium"))
      card.addView(
        TextView(this).apply {
          text = if (option == selected) "Selected" else "Tap to apply"
          setTextColor(optionPalette.secondaryTextColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        },
      )

      grid.addView(
        card,
        GridLayout.LayoutParams().apply {
          width = 0
          height = ViewGroup.LayoutParams.WRAP_CONTENT
          columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f)
          setMargins(dp(0f), dp(0f), dp(0f), dp(12f))
        },
      )
    }

    return grid
  }

  private fun previewBubble(
    text: String,
    backgroundColor: Int,
    textColor: Int,
    gravity: Int,
  ): View {
    val host = FrameLayout(this)
    host.addView(
      TextView(this).apply {
        this.text = text
        setTextColor(textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        background = roundedRect(backgroundColor, Color.TRANSPARENT, 18f)
        setPadding(dp(14f), dp(10f), dp(14f), dp(10f))
      },
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        gravity,
      ),
    )
    return host
  }

  private fun pillLabel(
    title: String,
    palette: AppThemePalette,
    filled: Boolean,
  ): View {
    return TextView(this).apply {
      text = title
      setTextColor(if (filled) palette.buttonTextColor else palette.textColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      background =
        roundedRect(
          if (filled) palette.accentColor else palette.cardColor,
          if (filled) palette.accentColor else palette.borderColor,
          999f,
        )
      setPadding(dp(12f), dp(7f), dp(12f), dp(7f))
    }
  }

  private fun selectionRow(
    title: String,
    detail: String,
    selected: Boolean,
    palette: AppThemePalette,
    onClick: () -> Unit,
  ): View {
    val row = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      foreground = selectableItemBackground()
      setPadding(dp(16f), dp(14f), dp(16f), dp(14f))
      setOnClickListener { onClick() }
    }

    val textColumn = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
    }
    row.addView(
      textColumn,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
    )
    textColumn.addView(sectionTitle(title, palette, 16f, "sans-serif-medium"))
    textColumn.addView(
      TextView(this).apply {
        text = detail
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      },
    )

    row.addView(
      ImageView(this).apply {
        setImageResource(if (selected) android.R.drawable.checkbox_on_background else android.R.drawable.checkbox_off_background)
        imageTintList = ColorStateList.valueOf(if (selected) palette.accentColor else palette.tertiaryTextColor)
      },
      LinearLayout.LayoutParams(dp(22f), dp(22f)),
    )

    return row
  }

  private fun sectionTitle(
    title: String,
    palette: AppThemePalette,
    sizeSp: Float,
    family: String,
  ): TextView {
    return TextView(this).apply {
      text = title
      setTextColor(palette.textColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
      typeface = Typeface.create(family, Typeface.NORMAL)
    }
  }

  private fun sectionLabel(
    title: String,
    palette: AppThemePalette,
  ): TextView {
    return TextView(this).apply {
      text = title
      setTextColor(palette.secondaryTextColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
  }

  private fun divider(palette: AppThemePalette): View {
    return View(this).apply {
      setBackgroundColor(palette.dividerColor)
    }.also {
      it.layoutParams = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        dp(1f),
      ).apply {
        marginStart = dp(16f)
      }
    }
  }

  private fun roundedRect(
    fillColor: Int,
    strokeColor: Int,
    radiusDp: Float,
  ): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = dp(radiusDp).toFloat()
      setColor(fillColor)
      if (strokeColor != Color.TRANSPARENT) {
        setStroke(dp(1f), strokeColor)
      }
    }
  }

  private fun selectableItemBackground() =
    obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).use { typedArray ->
      getDrawable(typedArray.getResourceId(0, 0))
    }

  private fun space(valueDp: Float, horizontal: Boolean = false): View {
    return View(this).apply {
      layoutParams =
        if (horizontal) {
          LinearLayout.LayoutParams(dp(valueDp), 1)
        } else {
          LinearLayout.LayoutParams(1, dp(valueDp))
        }
    }
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
}
