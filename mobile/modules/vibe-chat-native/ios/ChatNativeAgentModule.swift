import ExpoModulesCore

public class ChatNativeAgentModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeAgent")

    Function("isSupported") {
      true
    }

    AsyncFunction("submitText") { (surfaceId: String, text: String) in
      DispatchQueue.main.async {
        ChatNativeAgentRegistry.shared.view(for: surfaceId)?.submitText(text)
      }
    }

    View(ChatNativeAgentView.self) {
      Prop("surfaceId") { (view: ChatNativeAgentView, value: String) in
        view.surfaceId = value
      }

      Prop("appearance") { (view: ChatNativeAgentView, value: [String: Any]?) in
        view.setAppearance(value ?? [:])
      }

      Events("onNativeEvent")
    }
  }
}
