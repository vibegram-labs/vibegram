package expo.modules.vibechatnative.notifications

import expo.modules.notifications.service.ExpoFirebaseMessagingService
import expo.modules.notifications.service.interfaces.FirebaseMessagingDelegate

class VibeFirebaseMessagingService : ExpoFirebaseMessagingService() {
  override val firebaseMessagingDelegate: FirebaseMessagingDelegate by lazy {
    VibeFirebaseMessagingDelegate(this)
  }
}
