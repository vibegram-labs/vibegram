package expo.modules.vibechatnative

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ChatNativeMainModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ChatNativeMain")

    Function("isSupported") {
      true
    }

    Function("supportsNativeMain") {
      true
    }

    AsyncFunction("setPage") { surfaceId: String, page: String, animated: Boolean? ->
      ChatMainRegistry.view(surfaceId)?.setPage(page, animated ?: true)
    }

    AsyncFunction("applyTransactions") { surfaceId: String, transactions: List<Map<String, Any?>> ->
      ChatMainRegistry.view(surfaceId)?.applyTransactions(transactions)
    }

    AsyncFunction("scrollToBottom") { surfaceId: String, animated: Boolean ->
      ChatMainRegistry.view(surfaceId)?.scrollToBottom(animated)
    }

    AsyncFunction("scrollToMessage") {
        surfaceId: String,
        messageId: String,
        animated: Boolean,
        viewPosition: Double? ->
      ChatMainRegistry.view(surfaceId)?.scrollToMessage(
        messageId,
        animated,
        viewPosition ?: 0.5,
      )
    }

    AsyncFunction("startSendTransition") { surfaceId: String, payload: Map<String, Any?> ->
      ChatMainRegistry.view(surfaceId)?.startSendTransition(payload)
    }

    AsyncFunction("playReactionFx") { surfaceId: String, payload: Map<String, Any?> ->
      ChatMainRegistry.view(surfaceId)?.playReactionFx(payload)
    }

    View(ChatMainView::class) {
      Events("onViewportChanged", "onNativeEvent")

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

      Prop("contentPaddingTop") { view: ChatMainView, value: Double ->
        view.applyContentPaddingTop(value)
      }

      Prop("contentPaddingBottom") { view: ChatMainView, value: Double ->
        view.applyContentPaddingBottom(value)
      }

      Prop("voicePlayback") { view: ChatMainView, payload: Map<String, Any?> ->
        view.setVoicePlayback(payload)
      }

      Prop("inputBarEnabled") { view: ChatMainView, enabled: Boolean ->
        view.setInputBarEnabled(enabled)
      }

      Prop("inputPlaceholder") { view: ChatMainView, placeholder: String? ->
        view.setInputPlaceholder(placeholder ?: "Message")
      }

      Prop("nativeSendEnabled") { view: ChatMainView, enabled: Boolean ->
        view.setNativeSendEnabled(enabled)
      }

      Prop("headerMode") { view: ChatMainView, value: String? ->
        view.setHeaderMode(value ?: "default")
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
        // Do not coerce null/undefined to "chat". When JS omits the prop,
        // forcing "chat" here fights native page transitions (e.g. avatar -> profile).
        value?.let { view.setPage(it, true) }
      }
    }
  }
}
