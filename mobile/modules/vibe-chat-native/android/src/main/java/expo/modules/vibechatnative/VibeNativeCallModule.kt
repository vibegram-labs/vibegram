package expo.modules.vibechatnative

import android.util.Log
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.vibechatnative.notifications.VibeIncomingCallNotification
import expo.modules.vibechatnative.notifications.VibeNativeCallStore
import expo.modules.vibechatnative.notifications.VibeNativeCallUiBridge

class VibeNativeCallModule : Module() {
  init {
    VibeNativeCallUiBridge.attachModule(this)
  }

  override fun definition() = ModuleDefinition {
    Name("VibeNativeCall")

    Events("onCallUiEvent")

    Function("isSupported") {
      true
    }

    Function("supportsInAppUi") {
      true
    }

    Function("setNativeEngineConfig") { payload: Map<String, Any?> ->
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function emptyMap<String, Any?>()
      NativeCallEngine.configure(context, payload)
    }

    Function("getNativeEngineConfig") {
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function emptyMap<String, Any?>()
      NativeCallEngine.getConfig(context)
    }

    Function("getNativeEngineStatus") {
      NativeCallEngine.getStatus()
    }

    Function("getNativeIceConfig") {
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function emptyMap<String, Any?>()
      NativeCallEngine.getIceConfig(context)
    }

    Function("getNativeSignalingJournal") {
      NativeCallEngine.getSignalingJournal()
    }

    Function("clearNativeSignalingJournal") {
      NativeCallEngine.clearSignalingJournal()
    }

    Function("nativeRefreshTurnConfig") {
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function emptyMap<String, Any?>()
      NativeCallEngine.refreshTurnConfig(context, force = true)
    }

    Function("nativeStartOutgoingCall") { payload: Map<String, Any?> ->
      NativeCallEngine.startOutgoing(payload)
    }

    Function("nativeAcceptIncomingCall") { payload: Map<String, Any?> ->
      NativeCallEngine.acceptIncoming(payload)
    }

    Function("nativeHandleSignal") { payload: Map<String, Any?> ->
      NativeCallEngine.handleSignal(payload)
    }

    Function("nativeEndCall") { payload: Map<String, Any?> ->
      NativeCallEngine.endCall(payload)
    }

    Function("drainPendingEvents") {
      VibeNativeCallStore.drainEvents(appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function emptyList<Map<String, Any?>>())
    }

    Function("getPushTokens") {
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext
      val fcm = context?.let { VibeNativeCallStore.getFcmToken(it) }
      mapOf(
        "platform" to "android",
        "fcm" to fcm,
      )
    }

    Function("clearIncomingCallUi") { payload: Map<String, Any?> ->
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function
      val callId = (payload["callId"] ?: payload["call_id"])?.toString()
      VibeIncomingCallNotification.cancelIncomingCall(context, callId)
    }

    Function("setCallUiState") { payload: Map<String, Any?> ->
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function
      val mode = (payload["mode"] as? String) ?: "hidden"
      val visible = (payload["visible"] as? Boolean)
        ?: (mode != "hidden")
      Log.d(
        "VibeNativeCall",
        "Module.setCallUiState mode=$mode visible=$visible callId=${payload["callId"] ?: payload["call_id"]} status=${payload["callStatus"]} hasActivity=${appContext.currentActivity != null}"
      )
      VibeNativeCallUiBridge.setState(payload)
      if (visible) {
        VibeNativeCallUiBridge.present(context)
      } else {
        VibeNativeCallUiBridge.hide()
      }
    }

    Function("hideCallUi") {
      Log.d("VibeNativeCall", "Module.hideCallUi")
      VibeNativeCallUiBridge.hide()
    }

    OnDestroy {
      VibeNativeCallUiBridge.detachModule(this@VibeNativeCallModule)
    }
  }

  internal fun emitCallUiEvent(payload: Map<String, Any?>) {
    Log.d("VibeNativeCall", "Module.emitCallUiEvent type=${payload["type"]} callId=${payload["callId"] ?: payload["call_id"]}")
    try {
      sendEvent("onCallUiEvent", payload)
    } catch (_: Throwable) {
      Log.w("VibeNativeCall", "Module.emitCallUiEvent failed listenerMissing=true")
    }
  }
}
