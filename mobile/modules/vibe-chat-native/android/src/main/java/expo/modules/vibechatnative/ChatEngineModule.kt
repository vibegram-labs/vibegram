package expo.modules.vibechatnative

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ChatEngineModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ChatEngine")

    Function("isSupported") {
      true
    }

    Function("setChatEngineConfig") { payload: Map<String, Any?> ->
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext
      if (context == null) emptyMap<String, Any?>() else ChatEngine.configure(context, payload)
    }

    Function("getChatEngineStatus") {
      ChatEngine.getStatus()
    }

    Function("connectChatEngine") {
      ChatEngine.connect()
    }

    Function("disconnectChatEngine") {
      ChatEngine.disconnect()
    }

    Function("bindChatSurface") { payload: Map<String, Any?> ->
      ChatEngine.bindSurface(payload)
    }

    Function("unbindChatSurface") { payload: Map<String, Any?> ->
      ChatEngine.unbindSurface(payload)
    }

    Function("openChatChannel") { payload: Map<String, Any?> ->
      ChatEngine.openChatChannel(payload)
    }

    Function("closeChatChannel") { payload: Map<String, Any?> ->
      ChatEngine.closeChatChannel(payload)
    }

    Function("sendDeliveryReceipt") { payload: Map<String, Any?> ->
      ChatEngine.sendDeliveryReceipt(payload)
    }

    Function("sendReadReceipt") { payload: Map<String, Any?> ->
      ChatEngine.sendReadReceipt(payload)
    }

    Function("upsertLocalMessageStatus") { payload: Map<String, Any?> ->
      ChatEngine.upsertLocalMessageStatus(payload)
    }

    Function("sendEncryptedMessage") { payload: Map<String, Any?> ->
      ChatEngine.sendEncryptedMessage(payload)
    }

    Function("sendMessage") { payload: Map<String, Any?> ->
      ChatEngine.sendMessage(payload)
    }

    Function("retryOutgoingMessage") { payload: Map<String, Any?> ->
      ChatEngine.retryOutgoingMessage(payload)
    }

    Function("cancelOutgoingMessage") { payload: Map<String, Any?> ->
      ChatEngine.cancelOutgoingMessage(payload)
    }

    Function("editMessage") { payload: Map<String, Any?> ->
      ChatEngine.editMessage(payload)
    }

    Function("deleteMessage") { payload: Map<String, Any?> ->
      ChatEngine.deleteMessage(payload)
    }

    Function("sendTypingState") { payload: Map<String, Any?> ->
      ChatEngine.sendTypingState(payload)
    }

    Function("sendRecordingState") { payload: Map<String, Any?> ->
      ChatEngine.sendRecordingState(payload)
    }

    Function("sendEditMessage") { payload: Map<String, Any?> ->
      ChatEngine.sendEditMessage(payload)
    }

    Function("sendDeleteMessage") { payload: Map<String, Any?> ->
      ChatEngine.sendDeleteMessage(payload)
    }

    Function("setChatMuted") { payload: Map<String, Any?> ->
      ChatEngine.setChatMuted(payload)
    }

    Function("clearChat") { payload: Map<String, Any?> ->
      ChatEngine.clearChat(payload)
    }

    Function("blockUser") { payload: Map<String, Any?> ->
      ChatEngine.blockUser(payload)
    }

    Function("getChatProfileSummary") { payload: Map<String, Any?> ->
      ChatEngine.getChatProfileSummary(payload)
    }

    Function("getPinnedMessages") { payload: Map<String, Any?> ->
      ChatEngine.getPinnedMessages(payload)
    }

    Function("pinMessage") { payload: Map<String, Any?> ->
      ChatEngine.pinMessage(payload)
    }

    Function("getChatJournal") {
      ChatEngine.getJournal()
    }

    Function("clearChatJournal") {
      ChatEngine.clearJournal()
    }

    Function("isTyping") { payload: Map<String, Any?> ->
      ChatEngine.isTyping(payload)
    }

    AsyncFunction("fetchAgentConfig") { payload: Map<String, Any?> ->
      ChatEngine.fetchAgentConfig(payload)
    }

    AsyncFunction("saveAgentConfig") { payload: Map<String, Any?> ->
      ChatEngine.saveAgentConfig(payload)
    }

    AsyncFunction("deleteAgentConfig") { payload: Map<String, Any?> ->
      ChatEngine.deleteAgentConfig(payload)
    }

    AsyncFunction("generateAgentPrompt") { payload: Map<String, Any?> ->
      ChatEngine.generateAgentPrompt(payload)
    }

    // Shadow-mode bridge until native Phoenix transport is implemented.
    Function("setPresenceSnapshot") { payload: Map<String, Any?> ->
      val list = (payload["userIds"] as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
      ChatEngine.setPresenceSnapshot(list)
    }
  }
}
