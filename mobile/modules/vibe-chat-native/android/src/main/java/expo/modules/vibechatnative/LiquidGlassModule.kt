package expo.modules.vibechatnative

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class LiquidGlassModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("LiquidGlass")

    View(LiquidGlassView::class) {
      Prop("blurIntensity") { view: LiquidGlassView, intensity: Double ->
        view.setBlurIntensity(intensity)
      }

      Prop("blurReductionFactor") { view: LiquidGlassView, factor: Double? ->
        view.setBlurReductionFactor(factor)
      }

      Prop("tint") { view: LiquidGlassView, tint: String? ->
        view.setTint(tint)
      }

      Prop("interactive") { view: LiquidGlassView, interactive: Boolean? ->
        view.setInteractive(interactive)
      }

      Prop("pressFeedbackEnabled") { view: LiquidGlassView, enabled: Boolean? ->
        view.setPressFeedbackEnabled(enabled)
      }

      Prop("effect") { view: LiquidGlassView, effect: String? ->
        view.setEffect(effect)
      }

      Prop("tintColor") { view: LiquidGlassView, tintColor: Int? ->
        view.setTintColor(tintColor)
      }

      Prop("cornerRadius") { view: LiquidGlassView, cornerRadius: Double? ->
        view.setCornerRadius(cornerRadius)
      }
    }
  }
}
