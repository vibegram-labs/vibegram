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

    View(ChatMainView.self) {
      Prop("profileOnly") { (view: ChatMainView, value: Bool?) in
        view.setStandaloneProfileMode(value ?? true)
      }

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

      Prop("page") { (view: ChatMainView, value: String?) in
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
