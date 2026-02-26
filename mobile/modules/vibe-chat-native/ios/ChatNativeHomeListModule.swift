import ExpoModulesCore

public class ChatNativeHomeListModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeHomeList")

    View(ChatNativeHomeListView.self) {
      Prop("rows") { (view: ChatNativeHomeListView, rows: [[String: Any]]) in
        view.setRows(rows)
      }

      Prop("refreshing") { (view: ChatNativeHomeListView, refreshing: Bool) in
        view.setRefreshing(refreshing)
      }

      Prop("isDark") { (view: ChatNativeHomeListView, isDark: Bool) in
        view.setIsDark(isDark)
      }

      Prop("previewAppearance") { (view: ChatNativeHomeListView, appearance: [String: Any]) in
        view.setPreviewAppearance(appearance)
      }

      Prop("contentTopInset") { (view: ChatNativeHomeListView, value: Double) in
        view.setContentTopInset(value)
      }

      Prop("contentBottomInset") { (view: ChatNativeHomeListView, value: Double) in
        view.setContentBottomInset(value)
      }

      Events("onNativeEvent")
    }
  }
}
