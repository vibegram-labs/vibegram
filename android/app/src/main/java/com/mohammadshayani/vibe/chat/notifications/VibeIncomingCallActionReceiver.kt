package com.mohammadshayani.vibe.chat.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.mohammadshayani.vibe.chat.NativeCallEngine
import com.mohammadshayani.vibe.ui.NativeCallActivity

class VibeIncomingCallActionReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val action = intent.getStringExtra(VibeIncomingCallNotification.EXTRA_ACTION)?.trim().orEmpty()
    if (action.isEmpty()) return

    val payload = linkedMapOf<String, Any?>()
    intent.extras?.keySet()?.forEach { key ->
      payload[key] = intent.extras?.get(key)
    }
    val callId = payload["callId"]?.toString() ?: payload["call_id"]?.toString()
    VibeIncomingCallNotification.cancelIncomingCall(context, callId)

    val status =
      if (action == VibeIncomingCallNotification.ACTION_ANSWER) {
        NativeCallEngine.acceptIncoming(payload)
      } else {
        NativeCallEngine.endCall(payload)
      }
    if (action == VibeIncomingCallNotification.ACTION_ANSWER) {
      NativeCallActivity.startIncoming(context, status)
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
