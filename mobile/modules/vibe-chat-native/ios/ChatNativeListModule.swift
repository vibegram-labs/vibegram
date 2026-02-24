import ExpoModulesCore

public class ChatNativeListModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeList")

    Function("isSupported") {
      true
    }

    Function("supportsNativeList") {
      true
    }

    AsyncFunction("applyTransactions") { (surfaceId: String, transactions: [[String: Any]]) in
      DispatchQueue.main.async {
        ChatListRegistry.shared.view(for: surfaceId)?.applyTransactions(transactions)
      }
    }

    AsyncFunction("scrollToBottom") { (surfaceId: String, animated: Bool) in
      DispatchQueue.main.async {
        ChatListRegistry.shared.view(for: surfaceId)?.scrollToBottom(animated: animated)
      }
    }

    AsyncFunction("scrollToMessage") {
      (surfaceId: String, messageId: String, animated: Bool, viewPosition: Double?) in
      DispatchQueue.main.async {
        ChatListRegistry.shared.view(for: surfaceId)?.scrollToMessage(
          messageId: messageId,
          animated: animated,
          viewPosition: viewPosition ?? 0.5
        )
      }
    }

    AsyncFunction("startSendTransition") { (surfaceId: String, payload: [String: Any]) in
      DispatchQueue.main.async {
        ChatListRegistry.shared.view(for: surfaceId)?.startSendTransition(payload)
      }
    }

    AsyncFunction("playReactionFx") { (surfaceId: String, payload: [String: Any]) in
      DispatchQueue.main.async {
        ChatListRegistry.shared.view(for: surfaceId)?.playReactionFx(payload)
      }
    }

    View(ChatListView.self) {
      Prop("surfaceId") { (view: ChatListView, surfaceId: String) in
        view.surfaceId = surfaceId
      }

      Prop("rows") { (view: ChatListView, rows: [[String: Any]]) in
        view.setRows(rows)
      }

      Prop("engineSurfaceId") { (view: ChatListView, value: String?) in
        view.setEngineSurfaceId(value ?? "")
      }

      Prop("chatId") { (view: ChatListView, value: String?) in
        view.setEngineChatId(value ?? "")
      }

      Prop("myUserId") { (view: ChatListView, value: String?) in
        view.setEngineMyUserId(value ?? "")
      }

      Prop("peerUserId") { (view: ChatListView, value: String?) in
        view.setEnginePeerUserId(value ?? "")
      }

      Prop("statusAuthorityEnabled") { (view: ChatListView, enabled: Bool) in
        view.setStatusAuthorityEnabled(enabled)
      }

      Prop("appearance") { (view: ChatListView, appearance: [String: Any]) in
        view.setAppearance(appearance)
      }

      Prop("contentPaddingBottom") { (view: ChatListView, value: Double) in
        view.setContentPaddingBottom(value)
      }

      Prop("voicePlayback") { (view: ChatListView, payload: [String: Any]) in
        view.setVoicePlayback(payload)
      }

      Prop("inputBarEnabled") { (view: ChatListView, enabled: Bool) in
        view.setInputBarEnabled(enabled)
      }

      Prop("inputPlaceholder") { (view: ChatListView, value: String) in
        view.setInputPlaceholder(value)
      }

      Prop("nativeSendEnabled") { (view: ChatListView, enabled: Bool) in
        view.setNativeSendEnabled(enabled)
      }

      Prop("debugAnimationPanel") { (view: ChatListView, enabled: Bool) in
        view.setDebugAnimationPanel(enabled)
      }

      Events("onViewportChanged", "onNativeEvent")
    }
  }
}
