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
