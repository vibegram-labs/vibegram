import ExpoModulesCore

public class ChatNativeProfileModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeProfile")

    Function("isSupported") {
      true
    }

    Function("supportsNativeProfile") {
      true
    }

    View(ChatProfileMainView.self) {
      Prop("profileOnly") { (view: ChatProfileMainView, value: Bool?) in
        view.setProfileOnly(value ?? true)
      }

      Prop("surfaceId") { (view: ChatProfileMainView, value: String) in
        view.surfaceId = value
      }

      Prop("rows") { (view: ChatProfileMainView, rows: [[String: Any]]) in
        view.setRows(rows)
      }

      Prop("engineSurfaceId") { (view: ChatProfileMainView, value: String?) in
        view.setEngineSurfaceId(value ?? "")
      }

      Prop("chatId") { (view: ChatProfileMainView, value: String?) in
        view.setEngineChatId(value ?? "")
      }

      Prop("myUserId") { (view: ChatProfileMainView, value: String?) in
        view.setEngineMyUserId(value ?? "")
      }

      Prop("peerUserId") { (view: ChatProfileMainView, value: String?) in
        view.setEnginePeerUserId(value ?? "")
      }

      Prop("statusAuthorityEnabled") { (view: ChatProfileMainView, enabled: Bool) in
        view.setStatusAuthorityEnabled(enabled)
      }

      Prop("appearance") { (view: ChatProfileMainView, appearance: [String: Any]) in
        view.setAppearance(appearance)
      }

      Prop("headerTitle") { (view: ChatProfileMainView, value: String?) in
        view.setHeaderTitle(value ?? "")
      }

      Prop("headerSubtitle") { (view: ChatProfileMainView, value: String?) in
        view.setHeaderSubtitle(value ?? "")
      }

      Prop("profileName") { (view: ChatProfileMainView, value: String?) in
        view.setProfileName(value ?? "")
      }

      Prop("profileHandle") { (view: ChatProfileMainView, value: String?) in
        view.setProfileHandle(value ?? "")
      }

      Prop("profileBio") { (view: ChatProfileMainView, value: String?) in
        view.setProfileBio(value ?? "")
      }

      Prop("avatarUri") { (view: ChatProfileMainView, value: String?) in
        view.setAvatarUri(value)
      }

      Prop("isOnline") { (view: ChatProfileMainView, value: Bool?) in
        view.setIsOnline(value ?? false)
      }

      Prop("isChatMuted") { (view: ChatProfileMainView, value: Bool?) in
        view.setIsChatMuted(value ?? false)
      }

      Prop("isGroupOrChannel") { (view: ChatProfileMainView, value: Bool?) in
        view.setIsGroupOrChannel(value ?? false)
      }

      Prop("groupMembers") { (view: ChatProfileMainView, value: [[String: Any]]?) in
        view.setGroupMembers(value ?? [])
      }

      Prop("groupMemberCount") { (view: ChatProfileMainView, value: Int?) in
        view.setGroupMemberCount(value)
      }

      Prop("agentConfig") { (view: ChatProfileMainView, value: [String: Any]?) in
        view.setAgentConfig(value)
      }

      Prop("page") { (view: ChatProfileMainView, value: String?) in
        guard
          let value,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        view.setPage(value, animated: true)
      }

      Events("onViewportChanged", "onNativeEvent")
    }
  }
}
