package com.mohammadshayani.vibe.chat.notifications

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.mohammadshayani.vibe.R
import com.mohammadshayani.vibe.ui.NativeCallActivity

internal object VibeIncomingCallNotification {
  const val CHANNEL_ID = "vibe_incoming_calls"
  const val EXTRA_ACTION = "vibe_call_action"
  const val ACTION_ANSWER = "answer"
  const val ACTION_DECLINE = "decline"

  fun showIncomingCall(context: Context, state: Map<String, Any?>) {
    ensureChannel(context)
    val payload = normalizePayload(state)
    val callId = payload["callId"].orEmpty()
    val callerName = payload["fromUserName"]?.takeIf { it.isNotBlank() }
      ?: payload["fromUserId"]
      ?: "Incoming call"
    val callType = (payload["callType"] ?: "voice").lowercase()
    val notifId = notificationIdFor(callId)

    val fullScreenIntent = PendingIntent.getActivity(
      context,
      notifId,
      NativeCallActivity.intent(context, payload),
      PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag(),
    )
    val declineIntent = PendingIntent.getBroadcast(
      context,
      notifId + 1,
      VibeIncomingCallActionReceiver.intent(context, ACTION_DECLINE, payload),
      PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag(),
    )
    val answerIntent = PendingIntent.getBroadcast(
      context,
      notifId + 2,
      VibeIncomingCallActionReceiver.intent(context, ACTION_ANSWER, payload),
      PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag(),
    )

    val notification = NotificationCompat.Builder(context, CHANNEL_ID)
      .setSmallIcon(resolveSmallIcon(context))
      .setContentTitle(callerName)
      .setContentText("Incoming ${if (callType == "video") "video" else "voice"} call")
      .setCategory(NotificationCompat.CATEGORY_CALL)
      .setPriority(NotificationCompat.PRIORITY_MAX)
      .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
      .setOngoing(true)
      .setAutoCancel(false)
      .setTimeoutAfter(60_000L)
      .setContentIntent(fullScreenIntent)
      .setFullScreenIntent(fullScreenIntent, true)
      .addAction(R.drawable.ic_call_end, "Decline", declineIntent)
      .addAction(R.drawable.ic_call_accept, "Answer", answerIntent)
      .build()

    NotificationManagerCompat.from(context).notify(notifId, notification)
  }

  fun cancelIncomingCall(context: Context, callId: String?) {
    if (callId.isNullOrBlank()) return
    NotificationManagerCompat.from(context).cancel(notificationIdFor(callId))
  }

  fun normalizePayload(state: Map<String, Any?>): Map<String, String> {
    fun string(vararg keys: String): String {
      for (key in keys) {
        val value = state[key]?.toString()?.trim().orEmpty()
        if (value.isNotEmpty()) return value
      }
      return ""
    }

    val fromUserId = string("fromUserId", "from_user_id", "callerId", "caller_id")
    val fromUserName = string("fromUserName", "from_user_name", "callerName", "caller_name").ifBlank { fromUserId }
    val callType = string("callType", "call_type").lowercase().let { if (it == "video") "video" else "voice" }
    return linkedMapOf(
      "event" to "call-start",
      "type" to "call-start",
      "state" to (string("state").ifBlank { "ringing" }),
      "direction" to "incoming",
      "callId" to string("callId", "call_id"),
      "callType" to callType,
      "fromUserId" to fromUserId,
      "fromUserName" to fromUserName,
      "fromUserImage" to string("fromUserImage", "from_user_image", "callerImage", "caller_image"),
      "chatId" to string("chatId", "chat_id"),
    )
  }

  private fun ensureChannel(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
    if (manager.getNotificationChannel(CHANNEL_ID) != null) return
    val channel = NotificationChannel(CHANNEL_ID, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
      description = "Incoming call alerts"
      lockscreenVisibility = Notification.VISIBILITY_PUBLIC
      enableVibration(true)
      setSound(
        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
        AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
          .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
          .build(),
      )
    }
    manager.createNotificationChannel(channel)
  }

  private fun notificationIdFor(callId: String): Int =
    ("vibe_call_$callId").hashCode()

  private fun immutableFlag(): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

  private fun resolveSmallIcon(context: Context): Int =
    context.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.sym_call_incoming
}
