package expo.modules.vibechatnative.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.RingtoneManager
import android.media.AudioAttributes
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import expo.modules.vibechatnative.R

internal object VibeIncomingCallNotification {
  const val CHANNEL_ID = "vibe_incoming_calls"
  const val CHANNEL_NAME = "Incoming calls"
  const val EXTRA_ACTION = "vibe_call_action"
  const val EXTRA_CALL_ID = "vibe_call_id"
  const val ACTION_ANSWER = "answer"
  const val ACTION_DECLINE = "decline"

  fun isIncomingCallPayload(data: Map<String, String>): Boolean {
    val type = (data["type"] ?: data["event"] ?: data["messageType"] ?: "").trim().lowercase()
    val hasCallId = !(data["callId"] ?: data["call_id"]).isNullOrBlank()
    val hasCaller = !(data["fromUserId"] ?: data["from_user_id"] ?: data["callerId"] ?: data["caller_id"]).isNullOrBlank()
    val typeLooksLikeCall = type in setOf("call-start", "call_start", "incoming-call", "incoming_call", "call")
    return hasCallId && hasCaller && (typeLooksLikeCall || !data["callType"].isNullOrBlank() || !data["call_type"].isNullOrBlank())
  }

  fun showIncomingCall(context: Context, rawData: Map<String, String>) {
    ensureChannel(context)
    val payload = normalizePayload(rawData)
    val callId = payload["callId"].orEmpty()
    val callerName = payload["fromUserName"]?.takeIf { it.isNotBlank() }
      ?: payload["fromUserId"]
      ?: "Incoming call"
    val callType = (payload["callType"] ?: "voice").lowercase()
    val notifId = notificationIdFor(callId)

    val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
      putExtra("vibeNativeCall", true)
      payload.forEach { (key, value) -> putExtra(key, value) }
    }

    val fullScreenIntent = launchIntent?.let { intent ->
      PendingIntent.getActivity(
        context,
        notifId,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or pendingIntentImmutableFlag(),
      )
    }

    val answerIntent = PendingIntent.getBroadcast(
      context,
      notifId + 1,
      VibeIncomingCallActionReceiver.intent(context, ACTION_ANSWER, payload),
      PendingIntent.FLAG_UPDATE_CURRENT or pendingIntentImmutableFlag(),
    )
    val declineIntent = PendingIntent.getBroadcast(
      context,
      notifId + 2,
      VibeIncomingCallActionReceiver.intent(context, ACTION_DECLINE, payload),
      PendingIntent.FLAG_UPDATE_CURRENT or pendingIntentImmutableFlag(),
    )

    val builder = NotificationCompat.Builder(context, CHANNEL_ID)
      .setSmallIcon(resolveSmallIcon(context))
      .setContentTitle(callerName)
      .setContentText("Incoming ${if (callType == "video") "video" else "voice"} call")
      .setCategory(NotificationCompat.CATEGORY_CALL)
      .setPriority(NotificationCompat.PRIORITY_MAX)
      .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
      .setOngoing(true)
      .setAutoCancel(false)
      .setOnlyAlertOnce(false)
      .setTimeoutAfter(60_000L)
      .setContentIntent(fullScreenIntent)
      .setFullScreenIntent(fullScreenIntent, true)
      .addAction(0, "Decline", declineIntent)
      .addAction(0, "Answer", answerIntent)

    NotificationManagerCompat.from(context).notify(notifId, builder.build())
  }

  fun cancelIncomingCall(context: Context, callId: String?) {
    if (callId.isNullOrBlank()) return
    NotificationManagerCompat.from(context).cancel(notificationIdFor(callId))
  }

  fun normalizePayload(rawData: Map<String, String>): Map<String, String> {
    val callId = rawData["callId"] ?: rawData["call_id"] ?: ""
    val fromUserId = rawData["fromUserId"] ?: rawData["from_user_id"] ?: rawData["callerId"] ?: rawData["caller_id"] ?: ""
    val fromUserName = rawData["fromUserName"] ?: rawData["from_user_name"] ?: rawData["callerName"] ?: rawData["caller_name"] ?: fromUserId
    val fromUserImage = rawData["fromUserImage"] ?: rawData["from_user_image"] ?: rawData["callerImage"] ?: rawData["caller_image"] ?: ""
    val callType = ((rawData["callType"] ?: rawData["call_type"] ?: "voice").lowercase().let { if (it == "video") "video" else "voice" })
    return linkedMapOf(
      "event" to "call-start",
      "type" to "call-start",
      "callId" to callId,
      "fromUserId" to fromUserId,
      "fromUserName" to fromUserName,
      "callType" to callType,
    ).let { base ->
      if (fromUserImage.isNotBlank()) base + ("fromUserImage" to fromUserImage) else base
    }
  }

  private fun notificationIdFor(callId: String): Int {
    return ("vibe_call_" + callId).hashCode()
  }

  private fun pendingIntentImmutableFlag(): Int {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
  }

  private fun resolveSmallIcon(context: Context): Int {
    return context.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.sym_call_incoming
  }

  private fun ensureChannel(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
    val existing = manager.getNotificationChannel(CHANNEL_ID)
    if (existing != null) return
    val channel = NotificationChannel(
      CHANNEL_ID,
      CHANNEL_NAME,
      NotificationManager.IMPORTANCE_HIGH,
    ).apply {
      description = "Incoming call notifications"
      lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
      setBypassDnd(true)
      enableVibration(true)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        setSound(
          RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
          AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build(),
        )
      }
    }
    manager.createNotificationChannel(channel)
  }
}
