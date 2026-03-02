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

    View(ChatNativeProfileView.self) {
      Prop("profileOnly") { (view: ChatNativeProfileView, value: Bool?) in
        view.setProfileOnly(value ?? true)
      }

      Prop("surfaceId") { (view: ChatNativeProfileView, value: String) in
        view.surfaceId = value
      }

      Prop("rows") { (view: ChatNativeProfileView, rows: [[String: Any]]) in
        view.setRows(rows)
      }

      Prop("engineSurfaceId") { (view: ChatNativeProfileView, value: String?) in
        view.setEngineSurfaceId(value ?? "")
      }

      Prop("chatId") { (view: ChatNativeProfileView, value: String?) in
        view.setEngineChatId(value ?? "")
      }

      Prop("myUserId") { (view: ChatNativeProfileView, value: String?) in
        view.setEngineMyUserId(value ?? "")
      }

      Prop("peerUserId") { (view: ChatNativeProfileView, value: String?) in
        view.setEnginePeerUserId(value ?? "")
      }

      Prop("statusAuthorityEnabled") { (view: ChatNativeProfileView, enabled: Bool) in
        view.setStatusAuthorityEnabled(enabled)
      }

      Prop("appearance") { (view: ChatNativeProfileView, appearance: [String: Any]) in
        view.setAppearance(appearance)
      }

      Prop("headerTitle") { (view: ChatNativeProfileView, value: String?) in
        view.setHeaderTitle(value ?? "")
      }

      Prop("headerSubtitle") { (view: ChatNativeProfileView, value: String?) in
        view.setHeaderSubtitle(value ?? "")
      }

      Prop("profileName") { (view: ChatNativeProfileView, value: String?) in
        view.setProfileName(value ?? "")
      }

      Prop("profileHandle") { (view: ChatNativeProfileView, value: String?) in
        view.setProfileHandle(value ?? "")
      }

      Prop("profileBio") { (view: ChatNativeProfileView, value: String?) in
        view.setProfileBio(value ?? "")
      }

      Prop("avatarUri") { (view: ChatNativeProfileView, value: String?) in
        view.setAvatarUri(value)
      }

      Prop("isOnline") { (view: ChatNativeProfileView, value: Bool?) in
        view.setIsOnline(value ?? false)
      }

      Prop("isChatMuted") { (view: ChatNativeProfileView, value: Bool?) in
        view.setIsChatMuted(value ?? false)
      }

      Prop("isGroupOrChannel") { (view: ChatNativeProfileView, value: Bool?) in
        view.setIsGroupOrChannel(value ?? false)
      }

      Prop("groupMembers") { (view: ChatNativeProfileView, value: [[String: Any]]?) in
        view.setGroupMembers(value ?? [])
      }

      Prop("groupMemberCount") { (view: ChatNativeProfileView, value: Int?) in
        view.setGroupMemberCount(value)
      }

      Prop("agentConfig") { (view: ChatNativeProfileView, value: [String: Any]?) in
        view.setAgentConfig(value)
      }

      Prop("page") { (view: ChatNativeProfileView, value: String?) in
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
