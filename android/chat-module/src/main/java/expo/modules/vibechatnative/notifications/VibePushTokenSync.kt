package expo.modules.vibechatnative.notifications

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

internal object VibePushTokenSync {
  private val executor = Executors.newSingleThreadExecutor()
  @Volatile private var inFlight = false
  @Volatile private var needsRetry = false
  @Volatile private var lastSignature: String? = null

  fun syncStoredPushTokens(
    context: Context,
    configOverride: Map<String, Any?>? = null,
    reason: String,
  ) {
    val appContext = context.applicationContext
    executor.execute {
      syncStoredPushTokensLocked(appContext, configOverride, reason)
    }
  }

  private fun syncStoredPushTokensLocked(
    context: Context,
    configOverride: Map<String, Any?>?,
    reason: String,
  ) {
    if (inFlight) {
      needsRetry = true
      Log.d("VibePushTokenSync", "sync skipped reason=$reason state=inFlight")
      return
    }

    val fcm = VibeNativeCallStore.getFcmToken(context)
    if (fcm.isNullOrBlank()) {
      Log.d("VibePushTokenSync", "sync skipped reason=$reason missingFcm=true")
      return
    }

    val config = resolveConfig(context, configOverride) ?: run {
      Log.d("VibePushTokenSync", "sync skipped reason=$reason missingSession=true")
      return
    }
    val signature = "${config.userId}|${config.apiBaseUrl}|$fcm"
    if (lastSignature == signature) {
      Log.d("VibePushTokenSync", "sync skipped reason=$reason unchanged=true")
      return
    }

    inFlight = true
    var connection: HttpURLConnection? = null
    try {
      val body = JSONObject().apply {
        put("userId", config.userId)
        put("pushTokens", JSONObject().apply {
          put("fcm", fcm)
        })
      }.toString()
      connection = (URL("${config.apiBaseUrl}/api/user/profile").openConnection() as HttpURLConnection).apply {
        requestMethod = "POST"
        connectTimeout = 12_000
        readTimeout = 12_000
        doOutput = true
        setRequestProperty("Authorization", "Bearer ${config.authToken}")
        setRequestProperty("Content-Type", "application/json")
        outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
      }
      val status = connection.responseCode
      if (status in 200..299) {
        lastSignature = signature
        Log.d("VibePushTokenSync", "sync ok reason=$reason status=$status")
      } else {
        Log.w("VibePushTokenSync", "sync failed reason=$reason status=$status")
      }
    } catch (t: Throwable) {
      Log.w("VibePushTokenSync", "sync failed reason=$reason ${t.message}", t)
    } finally {
      connection?.disconnect()
      inFlight = false
      if (needsRetry) {
        needsRetry = false
        syncStoredPushTokensLocked(context, configOverride, "queued-after-$reason")
      }
    }
  }

  private fun resolveConfig(
    context: Context,
    configOverride: Map<String, Any?>?,
  ): PushSyncConfig? {
    val callConfig = VibeNativeCallStore.getNativeEngineConfig(context)
    val userId =
      normalized(configOverride?.get("userId"))
        ?: normalized(callConfig["userId"])
        ?: return null
    val authToken =
      normalized(configOverride?.get("authToken") ?: configOverride?.get("token"))
        ?: normalized(callConfig["authToken"] ?: callConfig["token"])
        ?: return null
    val apiBaseUrl =
      (normalized(configOverride?.get("apiBaseUrl") ?: configOverride?.get("baseUrl"))
        ?: normalized(callConfig["apiBaseUrl"] ?: callConfig["baseUrl"])
        ?: "https://api.vibegram.io")
        .trimEnd('/')
    return PushSyncConfig(apiBaseUrl, userId, authToken)
  }

  private fun normalized(value: Any?): String? =
    value?.toString()?.trim()?.takeIf { it.isNotEmpty() }

  private data class PushSyncConfig(
    val apiBaseUrl: String,
    val userId: String,
    val authToken: String,
  )
}
