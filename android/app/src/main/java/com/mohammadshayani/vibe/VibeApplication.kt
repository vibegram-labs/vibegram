package com.mohammadshayani.vibe

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.mohammadshayani.vibe.chat.notifications.VibePushTokenSync

class VibeApplication : Application(), Application.ActivityLifecycleCallbacks {
  override fun onCreate() {
    super.onCreate()
    registerActivityLifecycleCallbacks(this)
    VibePushTokenSync.refreshFirebaseTokenIfAvailable(this, "application-start")
    VibePushTokenSync.syncStoredPushTokens(this, reason = "application-start")
  }

  override fun onActivityResumed(activity: Activity) {
    resumedActivities += 1
  }

  override fun onActivityPaused(activity: Activity) {
    resumedActivities = (resumedActivities - 1).coerceAtLeast(0)
  }

  override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
  override fun onActivityStarted(activity: Activity) = Unit
  override fun onActivityStopped(activity: Activity) = Unit
  override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
  override fun onActivityDestroyed(activity: Activity) = Unit

  companion object {
    @Volatile private var resumedActivities = 0

    fun isForeground(): Boolean = resumedActivities > 0
  }
}
