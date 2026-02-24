import ExpoModulesCore

public class VibeNativeCallModule: Module {
  deinit {
    VibeNativeCallUiCoordinator.shared.detach(module: self)
  }

  public func definition() -> ModuleDefinition {
    Name("VibeNativeCall")

    OnCreate {
      NSLog("[VibeNativeCall][UiModule] OnCreate attach")
      VibeNativeCallUiCoordinator.shared.attach(module: self)
    }

    Events("onCallUiEvent")

    Function("isSupported") {
      true
    }

    Function("supportsInAppUi") {
      true
    }

    Function("setNativeEngineConfig") { (payload: [String: Any]) in
      VibeNativeCallEngine.shared.configure(payload)
    }

    Function("getNativeEngineConfig") {
      VibeNativeCallEngine.shared.getConfig()
    }

    Function("getNativeEngineStatus") {
      VibeNativeCallEngine.shared.getStatus()
    }

    Function("getNativeIceConfig") {
      VibeNativeCallEngine.shared.getIceConfig()
    }

    Function("getNativeSignalingJournal") {
      VibeNativeCallEngine.shared.getSignalingJournal()
    }

    Function("clearNativeSignalingJournal") {
      VibeNativeCallEngine.shared.clearSignalingJournal()
    }

    Function("nativeRefreshTurnConfig") {
      VibeNativeCallEngine.shared.refreshTurnConfig(force: true)
    }

    Function("nativeStartOutgoingCall") { (payload: [String: Any]) in
      VibeNativeCallEngine.shared.startOutgoing(payload)
    }

    Function("nativeAcceptIncomingCall") { (payload: [String: Any]) in
      VibeNativeCallEngine.shared.acceptIncoming(payload)
    }

    Function("nativeHandleSignal") { (payload: [String: Any]) in
      VibeNativeCallEngine.shared.handleSignal(payload)
    }

    Function("nativeEndCall") { (payload: [String: Any]) in
      VibeNativeCallEngine.shared.endCall(payload)
    }

    Function("drainPendingEvents") {
      let events = VibeNativeCallStore.shared.drainEvents()
      NSLog("[VibeNativeCall][Module] drainPendingEvents count=%d", events.count)
      return events
    }

    Function("getPushTokens") {
      let tokens = VibeNativeCallStore.shared.getPushTokens()
      let hasVoip = ((tokens["voip"] as? String)?.isEmpty == false)
      let hasApns = ((tokens["apns"] as? String)?.isEmpty == false)
      NSLog("[VibeNativeCall][Module] getPushTokens hasVoip=%@ hasApns=%@", hasVoip ? "true" : "false", hasApns ? "true" : "false")
      return tokens
    }

    Function("clearIncomingCallUi") { (payload: [String: Any]) in
      let callId = (payload["callId"] as? String) ?? (payload["call_id"] as? String)
      VibeNativeCallManager.shared.clearIncomingCallUi(callId: callId)
    }

    Function("setCallUiState") { (payload: [String: Any]) in
      VibeNativeCallUiCoordinator.shared.captureReactBridgeObject(self.appContext?.reactBridge)
      if let legacyProxy = self.appContext?.legacyModulesProxy as? NSObject {
        let legacyBridge = legacyProxy.value(forKey: "bridge") as AnyObject?
        VibeNativeCallUiCoordinator.shared.captureReactBridgeObject(legacyBridge)
      }
      let mode = (payload["mode"] as? String) ?? "hidden"
      let visible = (payload["visible"] as? Bool) ?? (mode != "hidden")
      let callId = (payload["callId"] as? String) ?? (payload["call_id"] as? String) ?? "-"
      let status = (payload["callStatus"] as? String) ?? "-"
      NSLog(
        "[VibeNativeCall][UiModule] setCallUiState mode=%@ visible=%@ callId=%@ status=%@",
        mode, visible ? "true" : "false", callId, status
      )
      VibeNativeCallUiCoordinator.shared.setState(payload)
    }

    Function("hideCallUi") {
      NSLog("[VibeNativeCall][UiModule] hideCallUi")
      VibeNativeCallUiCoordinator.shared.hide()
    }

    OnDestroy {
      NSLog("[VibeNativeCall][UiModule] OnDestroy detach")
      VibeNativeCallUiCoordinator.shared.detach(module: self)
    }
  }

  func emitCallUiEvent(_ payload: [String: Any]) {
    NSLog(
      "[VibeNativeCall][UiModule] emitCallUiEvent type=%@",
      (payload["type"] as? String) ?? "-"
    )
    sendEvent("onCallUiEvent", payload)
  }
}
