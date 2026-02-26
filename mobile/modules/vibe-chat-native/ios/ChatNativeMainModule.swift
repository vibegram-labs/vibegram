import ExpoModulesCore

public class ChatNativeMainModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeMain")

    Function("isSupported") {
      true
    }

    Function("supportsNativeMain") {
      true
    }

    AsyncFunction("setPage") { (surfaceId: String, page: String, animated: Bool?) in
      DispatchQueue.main.async {
        ChatNativeMainRegistry.shared.view(for: surfaceId)?.setPage(page, animated: animated ?? true)
      }
    }

    AsyncFunction("applyTransactions") { (surfaceId: String, transactions: [[String: Any]]) in
      DispatchQueue.main.async {
        ChatNativeMainRegistry.shared.view(for: surfaceId)?.applyTransactions(transactions)
      }
    }

    AsyncFunction("scrollToBottom") { (surfaceId: String, animated: Bool) in
      DispatchQueue.main.async {
        ChatNativeMainRegistry.shared.view(for: surfaceId)?.scrollToBottom(animated: animated)
      }
    }

    AsyncFunction("scrollToMessage") {
      (surfaceId: String, messageId: String, animated: Bool, viewPosition: Double?) in
      DispatchQueue.main.async {
        ChatNativeMainRegistry.shared.view(for: surfaceId)?.scrollToMessage(
          messageId: messageId,
          animated: animated,
          viewPosition: viewPosition ?? 0.5
        )
      }
    }

    AsyncFunction("startSendTransition") { (surfaceId: String, payload: [String: Any]) in
      DispatchQueue.main.async {
        ChatNativeMainRegistry.shared.view(for: surfaceId)?.startSendTransition(payload)
      }
    }

    AsyncFunction("playReactionFx") { (surfaceId: String, payload: [String: Any]) in
      DispatchQueue.main.async {
        ChatNativeMainRegistry.shared.view(for: surfaceId)?.playReactionFx(payload)
      }
    }

    View(ChatMainView.self) {
      Prop("surfaceId") { (view: ChatMainView, value: String) in
        view.surfaceId = value
      }

      Prop("rows") { (view: ChatMainView, rows: [[String: Any]]) in
        view.setRows(rows)
      }

      Prop("engineSurfaceId") { (view: ChatMainView, value: String?) in
        view.setEngineSurfaceId(value ?? "")
      }

      Prop("chatId") { (view: ChatMainView, value: String?) in
        view.setEngineChatId(value ?? "")
      }

      Prop("myUserId") { (view: ChatMainView, value: String?) in
        view.setEngineMyUserId(value ?? "")
      }

      Prop("peerUserId") { (view: ChatMainView, value: String?) in
        view.setEnginePeerUserId(value ?? "")
      }

      Prop("statusAuthorityEnabled") { (view: ChatMainView, enabled: Bool) in
        view.setStatusAuthorityEnabled(enabled)
      }

      Prop("appearance") { (view: ChatMainView, appearance: [String: Any]) in
        view.setAppearance(appearance)
      }

      Prop("contentPaddingBottom") { (view: ChatMainView, value: Double) in
        view.setContentPaddingBottom(value)
      }

      Prop("voicePlayback") { (view: ChatMainView, payload: [String: Any]) in
        view.setVoicePlayback(payload)
      }

      Prop("inputBarEnabled") { (view: ChatMainView, enabled: Bool) in
        view.setInputBarEnabled(enabled)
      }

      Prop("inputPlaceholder") { (view: ChatMainView, value: String) in
        view.setInputPlaceholder(value)
      }

      Prop("nativeSendEnabled") { (view: ChatMainView, enabled: Bool) in
        view.setNativeSendEnabled(enabled)
      }

      Prop("debugAnimationPanel") { (view: ChatMainView, enabled: Bool) in
        view.setDebugAnimationPanel(enabled)
      }

      Prop("headerTitle") { (view: ChatMainView, value: String?) in
        view.setHeaderTitle(value ?? "")
      }

      Prop("headerSubtitle") { (view: ChatMainView, value: String?) in
        view.setHeaderSubtitle(value ?? "")
      }

      Prop("profileName") { (view: ChatMainView, value: String?) in
        view.setProfileName(value ?? "")
      }

      Prop("profileHandle") { (view: ChatMainView, value: String?) in
        view.setProfileHandle(value ?? "")
      }

      Prop("profileBio") { (view: ChatMainView, value: String?) in
        view.setProfileBio(value ?? "")
      }

      Prop("avatarUri") { (view: ChatMainView, value: String?) in
        view.setAvatarUri(value)
      }

      Prop("isOnline") { (view: ChatMainView, value: Bool?) in
        view.setIsOnline(value ?? false)
      }

      Prop("isChatMuted") { (view: ChatMainView, value: Bool?) in
        view.setIsChatMuted(value ?? false)
      }

      Prop("page") { (view: ChatMainView, value: String?) in
        guard
          let value,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        view.setPage(value, animated: true)
      }

      Prop("isGroupOrChannel") { (view: ChatMainView, value: Bool?) in
        view.setIsGroupOrChannel(value ?? false)
      }

      Prop("groupMembers") { (view: ChatMainView, value: [[String: Any]]?) in
        view.setGroupMembers(value ?? [])
      }

      Prop("groupMemberCount") { (view: ChatMainView, value: Int?) in
        view.setGroupMemberCount(value)
      }

      Prop("agentConfig") { (view: ChatMainView, value: [String: Any]?) in
        view.setAgentConfig(value)
      }

      Events("onViewportChanged", "onNativeEvent")
    }
  }
}
