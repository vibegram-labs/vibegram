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

    View(ChatMainView::class) {
      Events("onViewportChanged", "onNativeEvent")

      Prop("profileOnly") { view: ChatMainView, value: Boolean? ->
        view.setStandaloneProfileMode(value ?: true)
      }

      Prop("surfaceId") { view: ChatMainView, value: String ->
        view.setSurfaceId(value)
      }

      Prop("rows") { view: ChatMainView, rows: List<Map<String, Any?>> ->
        view.setRows(rows)
      }

      Prop("engineSurfaceId") { view: ChatMainView, value: String? ->
        view.setEngineSurfaceId(value ?: "")
      }

      Prop("chatId") { view: ChatMainView, value: String? ->
        view.setEngineChatId(value ?: "")
      }

      Prop("myUserId") { view: ChatMainView, value: String? ->
        view.setEngineMyUserId(value ?: "")
      }

      Prop("peerUserId") { view: ChatMainView, value: String? ->
        view.setEnginePeerUserId(value ?: "")
      }

      Prop("statusAuthorityEnabled") { view: ChatMainView, enabled: Boolean ->
        view.setStatusAuthorityEnabled(enabled)
      }

      Prop("appearance") { view: ChatMainView, appearance: Map<String, Any?> ->
        view.setAppearance(appearance)
      }

      Prop("headerTitle") { view: ChatMainView, value: String? ->
        view.setHeaderTitle(value ?: "")
      }

      Prop("headerSubtitle") { view: ChatMainView, value: String? ->
        view.setHeaderSubtitle(value ?: "")
      }

      Prop("profileName") { view: ChatMainView, value: String? ->
        view.setProfileName(value ?: "")
      }

      Prop("profileHandle") { view: ChatMainView, value: String? ->
        view.setProfileHandle(value ?: "")
      }

      Prop("profileBio") { view: ChatMainView, value: String? ->
        view.setProfileBio(value ?: "")
      }

      Prop("avatarUri") { view: ChatMainView, value: String? ->
        view.setAvatarUri(value)
      }

      Prop("isOnline") { view: ChatMainView, value: Boolean? ->
        view.setIsOnline(value ?: false)
      }

      Prop("isChatMuted") { view: ChatMainView, value: Boolean? ->
        view.setIsChatMuted(value ?: false)
      }

      Prop("isGroupOrChannel") { view: ChatMainView, value: Boolean? ->
        view.setIsGroupOrChannel(value ?: false)
      }

      Prop("groupMembers") { view: ChatMainView, value: List<Map<String, Any?>>? ->
        view.setGroupMembers(value ?: emptyList())
      }

      Prop("groupMemberCount") { view: ChatMainView, value: Int? ->
        view.setGroupMemberCount(value)
      }

      Prop("page") { view: ChatMainView, value: String? ->
        value?.let { view.setPage(it, true) }
      }
    }
  }
}
