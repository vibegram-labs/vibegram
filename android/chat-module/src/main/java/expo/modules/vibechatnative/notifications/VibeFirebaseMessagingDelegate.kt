package expo.modules.vibechatnative.notifications

import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.net.Uri
import android.os.Build
import android.os.Parcel
import android.os.Parcelable
import android.util.Log
import android.widget.RemoteViews
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.RemoteMessage
import expo.modules.notifications.notifications.RemoteMessageSerializer
import expo.modules.notifications.notifications.debug.DebugLogging
import expo.modules.notifications.notifications.enums.NotificationPriority
import expo.modules.notifications.notifications.interfaces.INotificationContent
import expo.modules.notifications.notifications.model.Notification
import expo.modules.notifications.notifications.model.RemoteNotificationContent
import expo.modules.notifications.notifications.model.triggers.FirebaseNotificationTrigger
import expo.modules.notifications.notifications.presentation.builders.downloadImage
import expo.modules.notifications.service.NotificationsService
import expo.modules.notifications.service.delegates.FirebaseMessagingDelegate
import expo.modules.vibechatnative.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import java.util.Date
import kotlin.concurrent.thread

private const val VIBE_NOTIF_TAG = "VibeNotif"
private const val EXPO_NOTIFY_ID = 0

class VibeFirebaseMessagingDelegate(context: Context) : FirebaseMessagingDelegate(context) {
  override fun onMessageReceived(remoteMessage: RemoteMessage) {
    DebugLogging.logRemoteMessage("VibeFirebaseMessagingDelegate.onMessageReceived: message", remoteMessage)
    logIncomingPayload(remoteMessage)
    if (VibeIncomingCallNotification.isIncomingCallPayload(remoteMessage.data)) {
      val payload = VibeIncomingCallNotification.normalizePayload(remoteMessage.data)
      Log.d(VIBE_NOTIF_TAG, "incoming call push intercepted callId=${payload["callId"]} caller=${payload["fromUserId"]}")
      VibeNativeCallStore.enqueueIncomingCall(context, payload)
      VibeIncomingCallNotification.showIncomingCall(context, payload)
      FirebaseMessagingDelegate.runTaskManagerTasks(
        context.applicationContext,
        RemoteMessageSerializer.toBundle(remoteMessage),
      )
      return
    }
    val prepared = createNotificationWithMediaGuard(remoteMessage)
    val notification = prepared.notification
    DebugLogging.logNotification("VibeFirebaseMessagingDelegate.onMessageReceived: notification", notification)
    NotificationsService.receive(context, notification)
    scheduleCustomChatNotificationReplacement(notification, prepared.content)
    FirebaseMessagingDelegate.runTaskManagerTasks(
      context.applicationContext,
      RemoteMessageSerializer.toBundle(remoteMessage),
    )
  }

  private fun createNotificationWithMediaGuard(remoteMessage: RemoteMessage): PreparedRemoteNotification {
    val identifier = getNotificationIdentifier(remoteMessage)
    val content = VibeRemoteNotificationContent(remoteMessage)
    content.logResolvedImageState(identifier)
    val request = createNotificationRequest(
      identifier,
      content,
      FirebaseNotificationTrigger(remoteMessage),
    )
    return PreparedRemoteNotification(
      notification = Notification(request, Date(remoteMessage.sentTime)),
      content = content,
    )
  }

  private fun scheduleCustomChatNotificationReplacement(
    notification: Notification,
    content: VibeRemoteNotificationContent,
  ) {
    if (!content.shouldUseCustomChatLayout()) {
      return
    }
    val identifier = notification.notificationRequest.identifier
    thread(name = "VibeNotifCustomLayout") {
      try {
        val activeNotification = waitForPresentedAndroidNotification(identifier)
        if (activeNotification == null) {
          Log.d(VIBE_NOTIF_TAG, "customLayout skip id=$identifier reason=no-active-notification")
          return@thread
        }

        val visuals = runBlocking(Dispatchers.IO) {
          val avatarDeferred = async { content.loadAvatarBitmap() }
          val mediaDeferred = async { content.loadMediaBitmap(context) }
          ChatNotificationVisuals(
            avatar = avatarDeferred.await(),
            media = mediaDeferred.await(),
          )
        }

        if (visuals.avatar == null && visuals.media == null) {
          Log.d(VIBE_NOTIF_TAG, "customLayout skip id=$identifier reason=no-bitmaps")
          return@thread
        }

        val replaced = applyCustomLayout(activeNotification, content, visuals)
        NotificationManagerCompat.from(context).notify(identifier, EXPO_NOTIFY_ID, replaced)
        Log.d(
          VIBE_NOTIF_TAG,
          "customLayout applied id=$identifier avatar=${visuals.avatar != null} media=${visuals.media != null}"
        )
      } catch (t: Throwable) {
        Log.w(VIBE_NOTIF_TAG, "customLayout failed id=$identifier ${t.message}", t)
      }
    }
  }

  private fun waitForPresentedAndroidNotification(identifier: String): android.app.Notification? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
      return null
    }
    val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return null
    repeat(8) { attempt ->
      val active = manager.activeNotifications.firstOrNull { sbn ->
        sbn.id == EXPO_NOTIFY_ID && sbn.tag == identifier
      }?.notification
      if (active != null) {
        if (attempt > 0) {
          Log.d(VIBE_NOTIF_TAG, "customLayout found active id=$identifier attempt=${attempt + 1}")
        }
        return active
      }
      Thread.sleep(140L)
    }
    return null
  }

  private fun applyCustomLayout(
    baseNotification: android.app.Notification,
    content: VibeRemoteNotificationContent,
    visuals: ChatNotificationVisuals,
  ): android.app.Notification {
    baseNotification.contentView = buildChatRemoteViews(
      layoutId = R.layout.vibe_notification_chat_compact,
      content = content,
      visuals = visuals,
      mediaSizeDp = 56f,
    )
    val expanded = buildChatRemoteViews(
      layoutId = R.layout.vibe_notification_chat_big,
      content = content,
      visuals = visuals,
      mediaSizeDp = 76f,
    )
    baseNotification.bigContentView = expanded
    baseNotification.headsUpContentView = expanded
    return baseNotification
  }

  private fun buildChatRemoteViews(
    layoutId: Int,
    content: VibeRemoteNotificationContent,
    visuals: ChatNotificationVisuals,
    mediaSizeDp: Float,
  ): RemoteViews {
    val views = RemoteViews(context.packageName, layoutId)
    val isDark = isNightMode(context)
    val titleColor = if (isDark) 0xFFFFFFFF.toInt() else 0xFF10131A.toInt()
    val bodyColor = if (isDark) 0xD8FFFFFF.toInt() else 0xCC1C2430.toInt()

    views.setTextViewText(R.id.vibeNotifTitle, content.title ?: "")
    views.setTextViewText(R.id.vibeNotifBody, content.text ?: "")
    views.setTextColor(R.id.vibeNotifTitle, titleColor)
    views.setTextColor(R.id.vibeNotifBody, bodyColor)

    visuals.avatar?.let { avatar ->
      views.setViewVisibility(R.id.vibeNotifAvatar, android.view.View.VISIBLE)
      views.setImageViewBitmap(R.id.vibeNotifAvatar, circularCropBitmap(avatar, dp(40f)))
    } ?: views.setViewVisibility(R.id.vibeNotifAvatar, android.view.View.GONE)

    visuals.media?.let { media ->
      views.setViewVisibility(R.id.vibeNotifMedia, android.view.View.VISIBLE)
      views.setImageViewBitmap(
        R.id.vibeNotifMedia,
        roundedCenterCropBitmap(media, dp(mediaSizeDp), dp(mediaSizeDp), dp(10f).toFloat()),
      )
    } ?: views.setViewVisibility(R.id.vibeNotifMedia, android.view.View.GONE)

    return views
  }

  private fun dp(value: Float): Int {
    return (value * context.resources.displayMetrics.density).toInt().coerceAtLeast(1)
  }

  private fun logIncomingPayload(remoteMessage: RemoteMessage) {
    val data = remoteMessage.data
    val dataKeys = data.keys.sorted().joinToString(",")
    Log.d(
      VIBE_NOTIF_TAG,
      "incoming id=${remoteMessage.messageId} from=${remoteMessage.from} " +
        "notifTitle=${remoteMessage.notification?.title != null} notifBody=${remoteMessage.notification?.body != null} " +
        "notifImage=${remoteMessage.notification?.imageUrl != null} dataKeys=[$dataKeys]"
    )
    if (data.isNotEmpty()) {
      Log.d(
        VIBE_NOTIF_TAG,
        "payload fields " +
          "messageType=${data["messageType"] ?: data["message_type"]} " +
          "fromUserImage=${preview(data["fromUserImage"])} senderImage=${preview(data["senderImage"])} " +
          "avatar=${preview(data["avatar"])} avatarUrl=${preview(data["avatarUrl"])} " +
          "image=${preview(data["image"])} imageUrl=${preview(data["imageUrl"])} mediaImage=${preview(data["mediaImage"])} mediaUrl=${preview(data["mediaUrl"])}"
      )
    }
  }
}

private data class PreparedRemoteNotification(
  val notification: Notification,
  val content: VibeRemoteNotificationContent,
)

private data class ChatNotificationVisuals(
  val avatar: Bitmap?,
  val media: Bitmap?,
)

private class VibeRemoteNotificationContent(private val remoteMessage: RemoteMessage) : INotificationContent {
  private val base = RemoteNotificationContent(remoteMessage)
  private val remoteNotificationImageUri: Uri? by lazy { remoteMessage.notification?.imageUrl }
  private val fallbackImageUri: Uri? by lazy { extractImageUri(remoteMessage) }
  private val avatarImageUri: Uri? by lazy { extractAvatarUri(remoteMessage) }
  private val messageTypeRaw: String? by lazy { extractMessageType(remoteMessage) }
  private val shouldDisplayMediaImage: Boolean by lazy {
    val candidate = remoteNotificationImageUri ?: fallbackImageUri
    shouldAttachMediaImage(messageTypeRaw, candidate, avatarImageUri)
  }

  constructor(parcel: Parcel) : this(
    parcel.readParcelable<RemoteMessage>(RemoteMessage::class.java.classLoader)!!
  )

  override val title: String?
    get() = base.title

  override val text: String?
    get() = base.text

  override val subText: String?
    get() = base.subText

  override val badgeCount: Number?
    get() = base.badgeCount

  override val shouldPlayDefaultSound: Boolean
    get() = base.shouldPlayDefaultSound

  override val soundName: String?
    get() = base.soundName

  override val shouldUseDefaultVibrationPattern: Boolean
    get() = base.shouldUseDefaultVibrationPattern

  override val vibrationPattern: LongArray?
    get() = base.vibrationPattern

  override val body: JSONObject?
    get() = base.body

  override val priority: NotificationPriority?
    get() = base.priority

  override val color: Number?
    get() = base.color

  override val isAutoDismiss: Boolean
    get() = base.isAutoDismiss

  override val categoryId: String?
    get() = base.categoryId

  override val isSticky: Boolean
    get() = base.isSticky

  override fun containsImage(): Boolean {
    if (avatarImageUri != null) {
      return true
    }
    if (!shouldDisplayMediaImage) {
      return false
    }
    return remoteNotificationImageUri != null || fallbackImageUri != null
  }

  fun shouldUseCustomChatLayout(): Boolean {
    return avatarImageUri != null
  }

  suspend fun loadAvatarBitmap(): Bitmap? {
    val avatarUri = avatarImageUri ?: return null
    Log.d(VIBE_NOTIF_TAG, "customLayout avatar fetch uri=${previewUri(avatarUri)}")
    return downloadImage(avatarUri)
  }

  suspend fun loadMediaBitmap(context: Context): Bitmap? {
    if (!shouldDisplayMediaImage) return null
    remoteNotificationImageUri?.let {
      Log.d(VIBE_NOTIF_TAG, "customLayout media fetch via FCM uri=${previewUri(it)}")
      return base.getImage(context)
    }
    fallbackImageUri?.let {
      Log.d(VIBE_NOTIF_TAG, "customLayout media fetch fallback uri=${previewUri(it)}")
      return downloadImage(it)
    }
    return null
  }

  override suspend fun getImage(context: Context): Bitmap? {
    avatarImageUri?.let { avatarUri ->
      Log.d(VIBE_NOTIF_TAG, "getImage: trying avatar uri=${previewUri(avatarUri)}")
      val avatarBitmap = downloadImage(avatarUri)
      if (avatarBitmap != null) {
        Log.d(VIBE_NOTIF_TAG, "getImage: avatar loaded ${avatarBitmap.width}x${avatarBitmap.height}")
        return avatarBitmap
      }
      Log.w(VIBE_NOTIF_TAG, "getImage: avatar download failed uri=${previewUri(avatarUri)}")
    }

    if (shouldDisplayMediaImage) {
      if (remoteNotificationImageUri != null) {
        Log.d(VIBE_NOTIF_TAG, "getImage: trying FCM notification image uri=${previewUri(remoteNotificationImageUri)}")
        val expoImage = base.getImage(context)
        if (expoImage != null) {
          Log.d(VIBE_NOTIF_TAG, "getImage: FCM image loaded ${expoImage.width}x${expoImage.height}")
          return expoImage
        }
        Log.w(VIBE_NOTIF_TAG, "getImage: FCM image load failed uri=${previewUri(remoteNotificationImageUri)}")
      }

      fallbackImageUri?.let {
        Log.d(VIBE_NOTIF_TAG, "getImage: trying fallback media uri=${previewUri(it)}")
        val bitmap = downloadImage(it)
        if (bitmap != null) {
          Log.d(VIBE_NOTIF_TAG, "getImage: fallback media loaded ${bitmap.width}x${bitmap.height}")
        } else {
          Log.w(VIBE_NOTIF_TAG, "getImage: fallback media load failed uri=${previewUri(it)}")
        }
        return bitmap
      }
    }

    Log.d(VIBE_NOTIF_TAG, "getImage: no image selected (avatar/media unavailable)")
    return null
  }

  fun logResolvedImageState(identifier: String) {
    val data = remoteMessage.data
    Log.d(
      VIBE_NOTIF_TAG,
      "resolved id=$identifier " +
        "messageType=${messageTypeRaw ?: "-"} " +
        "avatar=${previewUri(avatarImageUri)} " +
        "remoteNotifImage=${previewUri(remoteNotificationImageUri)} " +
        "fallbackMedia=${previewUri(fallbackImageUri)} " +
        "shouldDisplayMedia=$shouldDisplayMediaImage " +
        "containsImage=${containsImage()} " +
        "bodyJson=${!data["body"].isNullOrBlank()} nestedDataJson=${!data["data"].isNullOrBlank()}"
    )
  }

  override fun describeContents(): Int = 0

  override fun writeToParcel(dest: Parcel, flags: Int) {
    dest.writeParcelable(remoteMessage, flags)
  }

  companion object CREATOR : Parcelable.Creator<VibeRemoteNotificationContent> {
    override fun createFromParcel(parcel: Parcel): VibeRemoteNotificationContent {
      return VibeRemoteNotificationContent(parcel)
    }

    override fun newArray(size: Int): Array<VibeRemoteNotificationContent?> {
      return arrayOfNulls(size)
    }
  }
}

private fun extractImageUri(remoteMessage: RemoteMessage): Uri? {
  val data = remoteMessage.data

  val directImage = firstValidHttpUrl(
    data["mediaImage"],
    data["mediaUrl"],
    data["image"],
    data["imageUrl"],
    extractFieldFromJson(data["body"], "image", "imageUrl", "mediaImage", "mediaUrl"),
    extractFieldFromJson(data["data"], "image", "imageUrl", "mediaImage", "mediaUrl"),
  )
  if (directImage != null) {
    return Uri.parse(directImage)
  }

  val richImage = extractImageFromJson(data["richContent"])
    ?: extractImageFromJson(data["_richContent"])
    ?: extractRichImageFromEnvelope(data["body"])
    ?: extractRichImageFromEnvelope(data["data"])

  return richImage?.let { Uri.parse(it) }
}

private fun extractAvatarUri(remoteMessage: RemoteMessage): Uri? {
  val data = remoteMessage.data
  val avatar = firstValidHttpUrl(
    data["fromUserImage"],
    data["senderImage"],
    data["avatar"],
    data["avatarUrl"],
    extractFieldFromJson(data["body"], "fromUserImage", "senderImage", "avatar", "avatarUrl"),
    extractFieldFromJson(data["data"], "fromUserImage", "senderImage", "avatar", "avatarUrl"),
  )
  return avatar?.let { Uri.parse(it) }
}

private fun extractMessageType(remoteMessage: RemoteMessage): String? {
  val data = remoteMessage.data
  return firstNonBlank(data["messageType"], data["message_type"])
}

private fun shouldAttachMediaImage(
  messageTypeRaw: String?,
  mediaImageUri: Uri?,
  avatarImageUri: Uri?
): Boolean {
  if (mediaImageUri == null) {
    return false
  }
  if (isSameResource(mediaImageUri, avatarImageUri)) {
    return false
  }
  val normalizedType = messageTypeRaw?.trim()?.lowercase().orEmpty()
  return normalizedType == "image" || normalizedType == "video" || normalizedType == "gif"
}

private fun isSameResource(first: Uri?, second: Uri?): Boolean {
  if (first == null || second == null) {
    return false
  }
  return normalizeUriForComparison(first) == normalizeUriForComparison(second)
}

private fun normalizeUriForComparison(uri: Uri): String {
  val scheme = uri.scheme?.lowercase().orEmpty()
  val host = uri.host?.lowercase().orEmpty()
  val path = uri.path?.lowercase().orEmpty()
  val query = uri.query?.lowercase().orEmpty()
  return "$scheme://$host$path?$query"
}

private fun extractImageFromJson(raw: String?): String? {
  if (raw.isNullOrBlank()) {
    return null
  }
  return try {
    val json = JSONObject(raw)
    firstValidHttpUrl(json.optString("image").takeIf { it.isNotBlank() })
  } catch (_: Throwable) {
    null
  }
}

private fun extractRichImageFromEnvelope(raw: String?): String? {
  if (raw.isNullOrBlank()) {
    return null
  }
  return try {
    val json = JSONObject(raw)
    extractImageFromJson(json.optString("richContent").takeIf { it.isNotBlank() })
      ?: extractImageFromJson(json.optString("_richContent").takeIf { it.isNotBlank() })
  } catch (_: Throwable) {
    null
  }
}

private fun extractFieldFromJson(raw: String?, vararg keys: String): String? {
  if (raw.isNullOrBlank()) {
    return null
  }
  return try {
    val json = JSONObject(raw)
    for (key in keys) {
      val value = json.optString(key).trim()
      if (value.isNotEmpty()) {
        return value
      }
    }
    null
  } catch (_: Throwable) {
    null
  }
}

private fun firstNonBlank(vararg values: String?): String? {
  for (value in values) {
    val trimmed = value?.trim().orEmpty()
    if (trimmed.isNotEmpty()) {
      return trimmed
    }
  }
  return null
}

private fun firstValidHttpUrl(vararg candidates: String?): String? {
  for (candidate in candidates) {
    val trimmed = candidate?.trim().orEmpty()
    if (trimmed.isEmpty()) {
      continue
    }
    val normalized = trimmed.lowercase()
    if (normalized.startsWith("http://") || normalized.startsWith("https://")) {
      return trimmed
    }
  }
  return null
}

private fun preview(value: String?): String {
  if (value.isNullOrBlank()) return "-"
  return if (value.length <= 96) value else value.take(96) + "..."
}

private fun previewUri(uri: Uri?): String {
  return preview(uri?.toString())
}

private fun isNightMode(context: Context): Boolean {
  val mode = context.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK
  return mode == android.content.res.Configuration.UI_MODE_NIGHT_YES
}

private fun circularCropBitmap(source: Bitmap, sizePx: Int): Bitmap {
  val size = sizePx.coerceAtLeast(1)
  val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
  val canvas = Canvas(output)
  val shader = BitmapShader(source, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
  val matrix = Matrix()
  val scale = maxOf(size / source.width.toFloat(), size / source.height.toFloat())
  val dx = (size - source.width * scale) / 2f
  val dy = (size - source.height * scale) / 2f
  matrix.setScale(scale, scale)
  matrix.postTranslate(dx, dy)
  shader.setLocalMatrix(matrix)
  val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = shader }
  canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
  return output
}

private fun roundedCenterCropBitmap(
  source: Bitmap,
  widthPx: Int,
  heightPx: Int,
  radiusPx: Float,
): Bitmap {
  val width = widthPx.coerceAtLeast(1)
  val height = heightPx.coerceAtLeast(1)
  val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
  val canvas = Canvas(output)
  val shader = BitmapShader(source, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
  val matrix = Matrix()
  val scale = maxOf(width / source.width.toFloat(), height / source.height.toFloat())
  val dx = (width - source.width * scale) / 2f
  val dy = (height - source.height * scale) / 2f
  matrix.setScale(scale, scale)
  matrix.postTranslate(dx, dy)
  shader.setLocalMatrix(matrix)
  val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = shader }
  canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), radiusPx, radiusPx, paint)
  return output
}
