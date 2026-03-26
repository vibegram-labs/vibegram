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

    AsyncFunction("stopStreaming") { (surfaceId: String) in
      DispatchQueue.main.async {
        ChatNativeAgentRegistry.shared.view(for: surfaceId)?.stopStreaming()
      }
    }

    View(ChatNativeAgentView.self) {
      Prop("surfaceId") { (view: ChatNativeAgentView, value: String) in
        view.surfaceId = value
      }

      Prop("appearance") { (view: ChatNativeAgentView, value: [String: Any]?) in
        view.setAppearance(value ?? [:])
      }

      Prop("activeAgentId") { (view: ChatNativeAgentView, value: String?) in
        view.setBuilderActiveAgentId(value)
      }

      Prop("latestSecret") { (view: ChatNativeAgentView, value: String?) in
        view.setBuilderLatestSecret(value)
      }

      Events("onNativeEvent")
    }
  }
}
