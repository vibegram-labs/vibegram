package expo.modules.vibechatnative.notifications

import android.content.Context
import android.content.Intent
import android.util.Log
import java.lang.ref.WeakReference

internal object VibeNativeCallUiBridge {
  private var moduleRef: WeakReference<expo.modules.vibechatnative.VibeNativeCallModule>? = null
  private var activityRef: WeakReference<VibeNativeCallUiActivity>? = null
  @Volatile private var state: Map<String, Any?> = emptyMap()

  fun attachModule(module: expo.modules.vibechatnative.VibeNativeCallModule) {
    Log.d("VibeNativeCall", "UiBridge.attachModule")
    moduleRef = WeakReference(module)
  }

  fun detachModule(module: expo.modules.vibechatnative.VibeNativeCallModule) {
    if (moduleRef?.get() === module) {
      Log.d("VibeNativeCall", "UiBridge.detachModule")
      moduleRef = null
    }
  }

  fun attachActivity(activity: VibeNativeCallUiActivity) {
    Log.d("VibeNativeCall", "UiBridge.attachActivity hasState=${state.isNotEmpty()}")
    activityRef = WeakReference(activity)
    activity.applyUiState(state)
  }

  fun detachActivity(activity: VibeNativeCallUiActivity) {
    if (activityRef?.get() === activity) {
      Log.d("VibeNativeCall", "UiBridge.detachActivity")
      activityRef = null
    }
  }

  fun setState(next: Map<String, Any?>) {
    val mode = (next["mode"] as? String) ?: "hidden"
    val visible = (next["visible"] as? Boolean) ?: (mode != "hidden")
    Log.d(
      "VibeNativeCall",
      "UiBridge.setState mode=$mode visible=$visible callId=${next["callId"] ?: next["call_id"]} status=${next["callStatus"]} hasActivity=${activityRef?.get() != null}"
    )
    state = next
    activityRef?.get()?.applyUiState(next)
  }

  fun getState(): Map<String, Any?> = state

  fun present(context: Context) {
    val activity = activityRef?.get()
    if (activity != null && !activity.isFinishing) {
      Log.d("VibeNativeCall", "UiBridge.present reuseExisting=true")
      activity.applyUiState(state)
      return
    }
    Log.d(
      "VibeNativeCall",
      "UiBridge.present launch activityExisting=${activity != null} stateMode=${state["mode"]} stateVisible=${state["visible"]}"
    )
    val intent = Intent(context, VibeNativeCallUiActivity::class.java).apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }
    try {
      context.startActivity(intent)
    } catch (_: Throwable) {
      Log.w("VibeNativeCall", "UiBridge.present launchDenied backgroundOrRestricted=true")
      // Activity launches can be denied when the app is backgrounded.
      // Closed/background call surfaces are handled by OS-native call UI paths.
    }
  }

  fun hide() {
    Log.d("VibeNativeCall", "UiBridge.hide hasActivity=${activityRef?.get() != null}")
    activityRef?.get()?.finish()
  }

  fun emitUiEvent(type: String, payload: Map<String, Any?> = emptyMap()) {
    Log.d("VibeNativeCall", "UiBridge.emitUiEvent type=$type callId=${payload["callId"] ?: payload["call_id"]}")
    val body = LinkedHashMap<String, Any?>()
    body["type"] = type
    for ((key, value) in payload) {
      body[key] = value
    }
    moduleRef?.get()?.emitCallUiEvent(body)
  }
}
