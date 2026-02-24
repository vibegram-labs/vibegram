package expo.modules.vibechatnative.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class VibeIncomingCallActionReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val action = intent.getStringExtra(VibeIncomingCallNotification.EXTRA_ACTION)?.trim().orEmpty()
    if (action.isEmpty()) return

    val payload = linkedMapOf<String, String>()
    intent.extras?.keySet()?.forEach { key ->
      val value = intent.extras?.get(key)?.toString() ?: return@forEach
      payload[key] = value
    }

    val callId = payload["callId"] ?: payload["call_id"]
    VibeIncomingCallNotification.cancelIncomingCall(context, callId)
    VibeNativeCallStore.enqueueAction(context, action, payload)

    if (action == VibeIncomingCallNotification.ACTION_ANSWER) {
      val callType = (payload["callType"] ?: payload["call_type"] ?: "voice").lowercase().let {
        if (it == "video") "video" else "voice"
      }
      val callerName = payload["fromUserName"] ?: payload["from_user_name"] ?: payload["fromUserId"] ?: "Incoming call"
      val callerImage = payload["fromUserImage"] ?: payload["from_user_image"]
      try {
        val uiState = linkedMapOf<String, Any?>(
          "visible" to true,
          "mode" to "active",
          "callStatus" to "connecting",
          "callId" to (payload["callId"] ?: payload["call_id"]),
          "callType" to callType,
          "remoteUserName" to callerName,
          "remoteUserImage" to callerImage,
          "isMuted" to false,
          "isSpeakerOn" to false,
          "isVideoEnabled" to (callType == "video"),
          "canFlipCamera" to (callType == "video"),
          "callDuration" to 0L,
        )
        Log.d("VibeIncomingCall", "Answer action presenting native call UI callId=${uiState["callId"]} callType=$callType")
        VibeNativeCallUiBridge.setState(uiState)
        VibeNativeCallUiBridge.present(context)
      } catch (t: Throwable) {
        Log.w("VibeIncomingCall", "Failed to present native call UI on answer ${t.message}", t)
      }
      try {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        launchIntent?.putExtra("vibeNativeCallAction", action)
        payload.forEach { (key, value) -> launchIntent?.putExtra(key, value) }
        if (launchIntent != null) {
          context.startActivity(launchIntent)
        }
      } catch (t: Throwable) {
        Log.w("VibeIncomingCall", "Failed to launch app for answer action ${t.message}", t)
      }
    }
  }

  companion object {
    fun intent(context: Context, action: String, payload: Map<String, String>): Intent {
      return Intent(context, VibeIncomingCallActionReceiver::class.java).apply {
        putExtra(VibeIncomingCallNotification.EXTRA_ACTION, action)
        payload.forEach { (key, value) -> putExtra(key, value) }
      }
    }
  }
}
