import ExpoModulesCore

public final class ChatEngineModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatEngine")

    Function("isSupported") {
      true
    }

    Function("setChatEngineConfig") { (payload: [String: Any]) in
      ChatEngine.shared.configure(payload)
    }

    Function("getChatEngineStatus") {
      ChatEngine.shared.getStatus()
    }

    Function("connectChatEngine") {
      ChatEngine.shared.connect()
    }

    Function("disconnectChatEngine") {
      ChatEngine.shared.disconnect()
    }

    Function("bindChatSurface") { (payload: [String: Any]) in
      ChatEngine.shared.bindSurface(payload)
    }

    Function("unbindChatSurface") { (payload: [String: Any]) in
      ChatEngine.shared.unbindSurface(payload)
    }

    Function("openChatChannel") { (payload: [String: Any]) in
      ChatEngine.shared.openChatChannel(payload)
    }

    Function("closeChatChannel") { (payload: [String: Any]) in
      ChatEngine.shared.closeChatChannel(payload)
    }

    Function("sendDeliveryReceipt") { (payload: [String: Any]) in
      ChatEngine.shared.sendDeliveryReceipt(payload)
    }

    Function("sendReadReceipt") { (payload: [String: Any]) in
      ChatEngine.shared.sendReadReceipt(payload)
    }

    Function("upsertLocalMessageStatus") { (payload: [String: Any]) in
      ChatEngine.shared.upsertLocalMessageStatus(payload)
    }

    Function("sendEncryptedMessage") { (payload: [String: Any]) in
      ChatEngine.shared.sendEncryptedMessage(payload)
    }

    Function("sendMessage") { (payload: [String: Any]) in
      ChatEngine.shared.sendMessage(payload)
    }

    Function("retryOutgoingMessage") { (payload: [String: Any]) in
      ChatEngine.shared.retryOutgoingMessage(payload)
    }

    Function("cancelOutgoingMessage") { (payload: [String: Any]) in
      ChatEngine.shared.cancelOutgoingMessage(payload)
    }

    Function("editMessage") { (payload: [String: Any]) in
      ChatEngine.shared.editMessage(payload)
    }

    Function("deleteMessage") { (payload: [String: Any]) in
      ChatEngine.shared.deleteMessage(payload)
    }

    Function("sendTypingState") { (payload: [String: Any]) in
      ChatEngine.shared.sendTypingState(payload)
    }

    Function("sendRecordingState") { (payload: [String: Any]) in
      ChatEngine.shared.sendRecordingState(payload)
    }

    Function("sendEditMessage") { (payload: [String: Any]) in
      ChatEngine.shared.sendEditMessage(payload)
    }

    Function("sendDeleteMessage") { (payload: [String: Any]) in
      ChatEngine.shared.sendDeleteMessage(payload)
    }

    Function("setChatMuted") { (payload: [String: Any]) in
      ChatEngine.shared.setChatMuted(payload)
    }

    Function("clearChat") { (payload: [String: Any]) in
      ChatEngine.shared.clearChat(payload)
    }

    Function("blockUser") { (payload: [String: Any]) in
      ChatEngine.shared.blockUser(payload)
    }

    Function("getChatProfileSummary") { (payload: [String: Any]) in
      ChatEngine.shared.getChatProfileSummary(payload)
    }

    Function("getPinnedMessages") { (payload: [String: Any]) in
      ChatEngine.shared.getPinnedMessages(payload)
    }

    Function("pinMessage") { (payload: [String: Any]) in
      ChatEngine.shared.pinMessage(payload)
    }

    Function("getChatJournal") {
      ChatEngine.shared.getJournal()
    }

    Function("clearChatJournal") {
      ChatEngine.shared.clearJournal()
    }

    Function("isTyping") { (payload: [String: Any]) in
      ChatEngine.shared.isTyping(payload)
    }

    AsyncFunction("fetchAgentConfig") { (chatId: String, promise: Promise) in
      ChatEngine.shared.fetchAgentConfig(chatId: chatId) { config in
        promise.resolve(config ?? [:])
      }
    }

    AsyncFunction("saveAgentConfig") { (chatId: String, config: [String: Any], promise: Promise) in
      ChatEngine.shared.saveAgentConfig(chatId: chatId, config: config) { success in
        promise.resolve(["success": success])
      }
    }

    AsyncFunction("deleteAgentConfig") { (chatId: String, promise: Promise) in
      ChatEngine.shared.deleteAgentConfig(chatId: chatId) { success in
        promise.resolve(["success": success])
      }
    }

    AsyncFunction("generateAgentPrompt") {
      (chatId: String, input: String, enabledTools: [String], promise: Promise) in
      ChatEngine.shared.generateAgentPrompt(
        chatId: chatId,
        input: input,
        enabledTools: enabledTools
      ) { payload in
        promise.resolve(payload ?? [:])
      }
    }

    // Shadow-mode bridge until native Phoenix transport is enabled.
    Function("setPresenceSnapshot") { (payload: [String: Any]) in
      let userIds = (payload["userIds"] as? [String]) ?? []
      _ = ChatEngine.shared.setPresenceSnapshot(userIds: userIds)
    }
  }
}
