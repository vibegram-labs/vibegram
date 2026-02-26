package expo.modules.vibechatnative

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ChatNativeHomeListModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ChatNativeHomeList")

    View(ChatNativeHomeListView::class) {
      Prop("rows") { view: ChatNativeHomeListView, rows: List<Map<String, Any?>> ->
        view.setRows(rows)
      }

      Prop("refreshing") { view: ChatNativeHomeListView, refreshing: Boolean ->
        view.setRefreshing(refreshing)
      }

      Prop("isDark") { view: ChatNativeHomeListView, isDark: Boolean ->
        view.setIsDark(isDark)
      }

      Prop("previewAppearance") { view: ChatNativeHomeListView, appearance: Map<String, Any?> ->
        view.setPreviewAppearance(appearance)
      }

      Prop("contentTopInset") { view: ChatNativeHomeListView, value: Double ->
        view.setContentTopInset(value)
      }

      Prop("contentBottomInset") { view: ChatNativeHomeListView, value: Double ->
        view.setContentBottomInset(value)
      }

      Events("onNativeEvent")
    }
  }
}
