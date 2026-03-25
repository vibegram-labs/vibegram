import ExpoModulesCore

public class ChatNativeGifModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeGif")

    Function("isSupported") {
      true
    }

    Function("supportsNativeGifPanel") {
      true
    }

    Function("setApiKey") { (apiKey: String) in
      let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      print("[NativeGif][iOS] setApiKey length=\(trimmed.count)")
      ChatGifPanelConfig.shared.apiKey = trimmed
    }

    Function("getApiKey") {
      print("[NativeGif][iOS] getApiKey length=\(ChatGifPanelConfig.shared.apiKey.count)")
      return ChatGifPanelConfig.shared.apiKey
    }
  }
}
