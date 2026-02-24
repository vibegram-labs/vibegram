package expo.modules.vibechatnative

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ChatNativeListModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ChatNativeList")

    Function("isSupported") {
      true
    }

    Function("supportsNativeList") {
      true
    }

    AsyncFunction("applyTransactions") { surfaceId: String, transactions: List<Map<String, Any?>> ->
      ChatListRegistry.view(surfaceId)?.applyTransactions(transactions)
    }

    AsyncFunction("scrollToBottom") { surfaceId: String, animated: Boolean ->
      ChatListRegistry.view(surfaceId)?.scrollToBottom(animated)
    }

    AsyncFunction("scrollToMessage") { surfaceId: String, messageId: String, animated: Boolean, viewPosition: Double? ->
      ChatListRegistry.view(surfaceId)?.scrollToMessage(
        messageId,
        animated,
        viewPosition ?: 0.5,
      )
    }

    AsyncFunction("startSendTransition") { surfaceId: String, payload: Map<String, Any?> ->
      ChatListRegistry.view(surfaceId)?.startSendTransition(payload)
    }

    AsyncFunction("playReactionFx") { surfaceId: String, payload: Map<String, Any?> ->
      ChatListRegistry.view(surfaceId)?.playReactionFx(payload)
    }

    View(ChatListView::class) {
      Events("onViewportChanged", "onNativeEvent")

      Prop("surfaceId") { view: ChatListView, surfaceId: String ->
        view.setSurfaceId(surfaceId)
      }

      Prop("rows") { view: ChatListView, rows: List<Map<String, Any?>> ->
        view.setRows(rows)
      }

      Prop("engineSurfaceId") { view: ChatListView, value: String? ->
        view.setEngineSurfaceId(value ?: "")
      }

      Prop("chatId") { view: ChatListView, value: String? ->
        view.setEngineChatId(value ?: "")
      }

      Prop("myUserId") { view: ChatListView, value: String? ->
        view.setEngineMyUserId(value ?: "")
      }

      Prop("peerUserId") { view: ChatListView, value: String? ->
        view.setEnginePeerUserId(value ?: "")
      }

      Prop("statusAuthorityEnabled") { view: ChatListView, enabled: Boolean ->
        view.setStatusAuthorityEnabled(enabled)
      }

      Prop("appearance") { view: ChatListView, appearance: Map<String, Any?> ->
        view.setAppearance(appearance)
      }

      Prop("contentPaddingTop") { view: ChatListView, value: Double ->
        view.setContentPaddingTop(value)
      }

      Prop("contentPaddingBottom") { view: ChatListView, value: Double ->
        view.setContentPaddingBottom(value)
      }

      Prop("voicePlayback") { view: ChatListView, payload: Map<String, Any?> ->
        view.setVoicePlayback(payload)
      }

      Prop("inputBarEnabled") { view: ChatListView, enabled: Boolean ->
        view.setInputBarEnabled(enabled)
      }

      Prop("inputPlaceholder") { view: ChatListView, placeholder: String? ->
        view.setInputPlaceholder(placeholder ?: "Message")
      }

      Prop("nativeSendEnabled") { view: ChatListView, enabled: Boolean ->
        view.setNativeSendEnabled(enabled)
      }
    }
  }
}
