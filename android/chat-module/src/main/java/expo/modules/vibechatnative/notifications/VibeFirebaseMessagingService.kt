package expo.modules.vibechatnative.notifications

import android.util.Log
import expo.modules.notifications.service.ExpoFirebaseMessagingService
import expo.modules.notifications.service.interfaces.FirebaseMessagingDelegate

class VibeFirebaseMessagingService : ExpoFirebaseMessagingService() {
  override val firebaseMessagingDelegate: FirebaseMessagingDelegate by lazy {
    VibeFirebaseMessagingDelegate(this)
  }

  override fun onNewToken(token: String) {
    super.onNewToken(token)
    VibeNativeCallStore.setFcmToken(this, token)
    Log.d("VibeNativeCall", "FCM onNewToken len=${token.length}")
    VibePushTokenSync.syncStoredPushTokens(this, reason = "fcm-new-token")
  }

  override fun onMessageReceived(remoteMessage: com.google.firebase.messaging.RemoteMessage) {
    Log.d(
      "VibeNativeCall",
      "FCM service onMessageReceived id=${remoteMessage.messageId} dataKeys=${remoteMessage.data.keys.sorted()}"
    )
    super.onMessageReceived(remoteMessage)
  }
}
