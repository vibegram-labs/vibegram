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

    Function("sendEditMessage") { (payload: [String: Any]) in
      ChatEngine.shared.sendEditMessage(payload)
    }

    Function("sendDeleteMessage") { (payload: [String: Any]) in
      ChatEngine.shared.sendDeleteMessage(payload)
    }

    Function("getChatJournal") {
      ChatEngine.shared.getJournal()
    }

    Function("clearChatJournal") {
      ChatEngine.shared.clearJournal()
    }

    // Shadow-mode bridge until native Phoenix transport is enabled.
    Function("setPresenceSnapshot") { (payload: [String: Any]) in
      let userIds = (payload["userIds"] as? [String]) ?? []
      ChatEngine.shared.setPresenceSnapshot(userIds: userIds)
    }
  }
}
