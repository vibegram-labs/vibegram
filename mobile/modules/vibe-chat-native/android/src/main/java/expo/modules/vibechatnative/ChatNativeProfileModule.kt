package expo.modules.vibechatnative

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ChatNativeProfileModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ChatNativeProfile")

    Function("isSupported") {
      true
    }

    Function("supportsNativeProfile") {
      true
    }

    View(ChatProfileMainView::class) {
      Events("onViewportChanged", "onNativeEvent")

      Prop("profileOnly") { view: ChatProfileMainView, value: Boolean? ->
        view.setProfileOnly(value ?: true)
      }

      Prop("surfaceId") { view: ChatProfileMainView, value: String ->
        view.setSurfaceId(value)
      }

      Prop("rows") { view: ChatProfileMainView, rows: List<Map<String, Any?>> ->
        view.setRows(rows)
      }

      Prop("engineSurfaceId") { view: ChatProfileMainView, value: String? ->
        view.setEngineSurfaceId(value ?: "")
      }

      Prop("chatId") { view: ChatProfileMainView, value: String? ->
        view.setEngineChatId(value ?: "")
      }

      Prop("myUserId") { view: ChatProfileMainView, value: String? ->
        view.setEngineMyUserId(value ?: "")
      }

      Prop("peerUserId") { view: ChatProfileMainView, value: String? ->
        view.setEnginePeerUserId(value ?: "")
      }

      Prop("statusAuthorityEnabled") { view: ChatProfileMainView, enabled: Boolean ->
        view.setStatusAuthorityEnabled(enabled)
      }

      Prop("appearance") { view: ChatProfileMainView, appearance: Map<String, Any?> ->
        view.setAppearance(appearance)
      }

      Prop("headerTitle") { view: ChatProfileMainView, value: String? ->
        view.setHeaderTitle(value ?: "")
      }

      Prop("headerSubtitle") { view: ChatProfileMainView, value: String? ->
        view.setHeaderSubtitle(value ?: "")
      }

      Prop("profileName") { view: ChatProfileMainView, value: String? ->
        view.setProfileName(value ?: "")
      }

      Prop("profileHandle") { view: ChatProfileMainView, value: String? ->
        view.setProfileHandle(value ?: "")
      }

      Prop("profileBio") { view: ChatProfileMainView, value: String? ->
        view.setProfileBio(value ?: "")
      }

      Prop("avatarUri") { view: ChatProfileMainView, value: String? ->
        view.setAvatarUri(value)
      }

      Prop("isOnline") { view: ChatProfileMainView, value: Boolean? ->
        view.setIsOnline(value ?: false)
      }

      Prop("isChatMuted") { view: ChatProfileMainView, value: Boolean? ->
        view.setIsChatMuted(value ?: false)
      }

      Prop("isGroupOrChannel") { view: ChatProfileMainView, value: Boolean? ->
        view.setIsGroupOrChannel(value ?: false)
      }

      Prop("groupMembers") { view: ChatProfileMainView, value: List<Map<String, Any?>>? ->
        view.setGroupMembers(value ?: emptyList())
      }

      Prop("groupMemberCount") { view: ChatProfileMainView, value: Int? ->
        view.setGroupMemberCount(value)
      }

      Prop("agentConfig") { view: ChatProfileMainView, value: Map<String, Any?>? ->
        view.setAgentConfig(value)
      }

      Prop("page") { view: ChatProfileMainView, value: String? ->
        value?.let { view.setPage(it, true) }
      }
    }
  }
}
