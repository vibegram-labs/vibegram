package expo.modules.vibechatnative

import android.content.Context
import android.util.Base64
import android.util.Log
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

private val chatEngineOaepSpec = OAEPParameterSpec(
  "SHA-256",
  "MGF1",
  MGF1ParameterSpec.SHA256,
  PSource.PSpecified.DEFAULT,
)

private fun chatEngineDecodePem(pem: String): ByteArray {
  val sanitized = pem
    .replace(Regex("-----BEGIN [A-Z ]+-----"), "")
    .replace(Regex("-----END [A-Z ]+-----"), "")
    .replace(Regex("\\\\n"), "\n")
    .replace(Regex("\\\\r"), "")
    .replace(Regex("\\s+"), "")
  return Base64.decode(sanitized, Base64.DEFAULT)
}

private fun chatEngineLoadPrivateKeyFromPem(privateKeyPem: String): PrivateKey {
  val keyFactory = KeyFactory.getInstance("RSA")
  return keyFactory.generatePrivate(PKCS8EncodedKeySpec(chatEngineDecodePem(privateKeyPem)))
}

private fun chatEngineRsaDecryptOAEP(privateKey: PrivateKey, encrypted: ByteArray): ByteArray? {
  return try {
    val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
    cipher.init(Cipher.DECRYPT_MODE, privateKey, chatEngineOaepSpec)
    cipher.doFinal(encrypted)
  } catch (_: Throwable) {
    null
  }
}

private fun chatEngineDecryptHybridMessage(
  privateKey: PrivateKey,
  ciphertext: String,
  isMyMessage: Boolean,
): String {
  val trimmed = ciphertext.trim()
  if (trimmed.isEmpty()) return ""
  if (!trimmed.startsWith("{")) return ""
  return try {
    val payload = JSONObject(trimmed)
    val ivB64 = payload.optString("iv", "")
    val cB64 = payload.optString("c", "")
    val kB64 = payload.optString("k", "")
    if (ivB64.isEmpty() || cB64.isEmpty() || kB64.isEmpty()) return ""

    val keyCandidates = ArrayList<String>(2)
    val senderKey = payload.optString("s", "")
    if (isMyMessage) {
      if (senderKey.isNotEmpty()) keyCandidates.add(senderKey)
      keyCandidates.add(kB64)
    } else {
      keyCandidates.add(kB64)
      if (senderKey.isNotEmpty()) keyCandidates.add(senderKey)
    }

    var aesKey: ByteArray? = null
    for (candidate in keyCandidates) {
      val encryptedKey = Base64.decode(candidate, Base64.DEFAULT)
      val decrypted = chatEngineRsaDecryptOAEP(privateKey, encryptedKey)
      if (decrypted != null) {
        aesKey = decrypted
        break
      }
    }
    val resolvedAesKey = aesKey ?: return ""
    val iv = Base64.decode(ivB64, Base64.DEFAULT)
    val encryptedWithTag = Base64.decode(cB64, Base64.DEFAULT)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(
      Cipher.DECRYPT_MODE,
      SecretKeySpec(resolvedAesKey, "AES"),
      GCMParameterSpec(128, iv),
    )
    val plaintextBytes = cipher.doFinal(encryptedWithTag)
    String(plaintextBytes, StandardCharsets.UTF_8)
  } catch (_: Throwable) {
    ""
  }
}

internal object ChatEngine {
  private data class SurfaceBinding(
    val surfaceId: String,
    val chatId: String?,
    val myUserId: String?,
    val peerUserId: String?,
  )

  @Volatile private var appContextRef: Context? = null
  private val lock = Any()
  private val state = ConcurrentHashMap<String, Any?>(
    mapOf(
      "state" to "idle",
      "connected" to false,
      "updatedAt" to 0L,
      "note" to "ChatEngine scaffold (shadow mode)",
    ),
  )
  private val onlineUsers = linkedSetOf<String>()
  private val surfaceBindings = linkedMapOf<String, SurfaceBinding>()
  private val openChatChannels = linkedMapOf<String, Int>()
  private val receiptIndex = linkedMapOf<String, MutableMap<String, String>>() // chatId -> messageId -> status
  private val localStatusIndex = linkedMapOf<String, MutableMap<String, String>>() // chatId -> messageId -> status
  private val listeners = linkedMapOf<String, (String, String?, String?) -> Unit>()
  private var phoenixClient: ChatPhoenixClient? = null
  private var nativePresenceActive = false
  private var nativeUserTopic: String? = null
  private var nativeUserJoinRef: String? = null
  private var nativeSocketSignature: String? = null
  private val nativeChatJoinRefsByRef = linkedMapOf<String, String>()
  private val nativeJoinedChatIds = linkedSetOf<String>()
  private val nativePendingMessagePushRefs = linkedMapOf<String, Pair<String, String>>() // ref -> (chatId,messageId)
  private val nativePendingEditPushRefs = linkedMapOf<String, Pair<String, String>>() // ref -> (chatId,messageId)
  private val nativePendingDeletePushRefs = linkedMapOf<String, Pair<String, String>>() // ref -> (chatId,messageId)
  private val historyRowsByChat = linkedMapOf<String, MutableList<Map<String, Any?>>>()
  private val historyLoadingChats = linkedSetOf<String>()
  private val liveMessageRowsByChat = linkedMapOf<String, MutableMap<String, Map<String, Any?>>>()
  private val deletedMessageIdsByChat = linkedMapOf<String, MutableSet<String>>()
  private var cachedDecryptPrivateKeyPem: String? = null
  private var cachedDecryptPrivateKey: PrivateKey? = null
  private val historyHttpClient by lazy { OkHttpClient() }

  fun configure(context: Context, payload: Map<String, Any?>): Map<String, Any?> {
    appContextRef = context.applicationContext
    ChatEngineStore.setConfig(context, payload)
    synchronized(lock) {
      state["state"] = "configured"
      state["updatedAt"] = System.currentTimeMillis()
      state["configuredAt"] = state["updatedAt"]
      state["configKeys"] = payload.keys.sorted()
      state["note"] = "ChatEngine configured (native Phoenix presence enabled, shadow fallback active)"
      state["presenceSource"] = if (nativePresenceActive) "native" else "shadow"
      appendJournalLocked("configure", mapOf("keys" to payload.keys.sorted()))
      val result = statusSnapshotLocked()
      emitChangeLocked("configure", null, null)
      return result
    }
  }

  fun getStatus(): Map<String, Any?> =
    synchronized(lock) { statusSnapshotLocked() }

  fun connect(): Map<String, Any?> {
    val ctx = appContextRef
    if (ctx == null) {
      synchronized(lock) {
        state["state"] = "native-config-missing"
        state["connected"] = false
        state["updatedAt"] = System.currentTimeMillis()
        state["note"] = "ChatEngine missing app context for native connect"
        appendJournalLocked("connect-native-missing-context", emptyMap())
        val result = statusSnapshotLocked()
        emitChangeLocked("connectionStateChanged", null, null)
        return result
      }
    }
    val config = ChatEngineStore.getConfig(ctx)
    val socketUrl = normalized(config["socketUrl"] ?: config["url"])
    val authToken = normalized(config["authToken"] ?: config["token"])
    val userId = normalized(config["userId"])
    val userTopic = normalized(config["userChannelTopic"]) ?: userId?.let { "user:$it" }
    if (socketUrl == null || userTopic == null) {
      synchronized(lock) {
        state["state"] = "native-config-missing"
        state["connected"] = false
        state["updatedAt"] = System.currentTimeMillis()
        state["note"] = "ChatEngine native presence missing socketUrl/userTopic config"
        appendJournalLocked(
          "connect-native-missing-config",
          mapOf(
            "hasSocketUrl" to (socketUrl != null),
            "hasUserTopic" to (userTopic != null),
            "hasAuthToken" to (authToken != null),
          ),
        )
        val result = statusSnapshotLocked()
        emitChangeLocked("connectionStateChanged", null, null)
        return result
      }
    }

    val signature = "$socketUrl|${authToken ?: ""}|$userTopic"
    var clientToDisconnect: ChatPhoenixClient? = null
    var clientToConnect: ChatPhoenixClient? = null
    synchronized(lock) {
      if (phoenixClient != null && nativeSocketSignature != signature) {
        clientToDisconnect = phoenixClient
        phoenixClient = null
        nativePresenceActive = false
        nativeUserJoinRef = null
        nativeUserTopic = null
        nativeChatJoinRefsByRef.clear()
        nativeJoinedChatIds.clear()
        nativePendingMessagePushRefs.clear()
        nativePendingEditPushRefs.clear()
        nativePendingDeletePushRefs.clear()
        historyLoadingChats.clear()
        liveMessageRowsByChat.clear()
        deletedMessageIdsByChat.clear()
      }
      if (phoenixClient == null) {
        val params = linkedMapOf<String, String>()
        if (!authToken.isNullOrBlank()) params["token"] = authToken
        phoenixClient = ChatPhoenixClient(
          socketUrl = socketUrl,
          params = params,
          callbacks = object : ChatPhoenixClient.Callbacks {
            override fun onOpen() = onNativeSocketOpen(userTopic)
            override fun onClosed(code: Int, reason: String?) = onNativeSocketClosed(code, reason)
            override fun onError(error: String) = onNativeSocketError(error)
            override fun onEvent(
              topic: String,
              event: String,
              payload: Map<String, Any?>,
              ref: String?,
              joinRef: String?,
            ) = onNativeSocketEvent(topic, event, payload, ref, joinRef)
          },
        )
        nativeSocketSignature = signature
      }
      nativeUserTopic = userTopic
      state["connected"] = false
      state["state"] = "connecting-native-presence"
      state["updatedAt"] = System.currentTimeMillis()
      state["note"] = "ChatEngine native Phoenix presence connecting"
      state["presenceSource"] = if (nativePresenceActive) "native" else "shadow"
      appendJournalLocked("connect-native", mapOf("topic" to userTopic))
      val result = statusSnapshotLocked()
      emitChangeLocked("connectionStateChanged", null, null)
      clientToConnect = phoenixClient
      clientToDisconnect?.disconnect()
      clientToConnect?.connect()
      return result
    }
  }

  fun disconnect(): Map<String, Any?> {
    val clientToDisconnect: ChatPhoenixClient?
    val result = synchronized(lock) {
      clientToDisconnect = phoenixClient
      phoenixClient = null
      nativePresenceActive = false
      nativeUserJoinRef = null
      nativeUserTopic = null
      nativeChatJoinRefsByRef.clear()
      nativeJoinedChatIds.clear()
      nativePendingMessagePushRefs.clear()
      nativePendingEditPushRefs.clear()
      nativePendingDeletePushRefs.clear()
      historyRowsByChat.clear()
      historyLoadingChats.clear()
      liveMessageRowsByChat.clear()
      deletedMessageIdsByChat.clear()
      state["connected"] = false
      state["state"] = "disconnected"
      state["updatedAt"] = System.currentTimeMillis()
      state["presenceSource"] = "shadow"
      appendJournalLocked("disconnect", emptyMap())
      val snapshot = statusSnapshotLocked()
      emitChangeLocked("connectionStateChanged", null, null)
      snapshot
    }
    clientToDisconnect?.disconnect()
    return result
  }

  fun bindSurface(payload: Map<String, Any?>): Map<String, Any?> {
    val surfaceId = normalized(payload["surfaceId"] ?: payload["engineSurfaceId"]) ?: return getStatus()
    synchronized(lock) {
      surfaceBindings[surfaceId] = SurfaceBinding(
        surfaceId = surfaceId,
        chatId = normalized(payload["chatId"]),
        myUserId = normalizedUpper(payload["myUserId"]),
        peerUserId = normalizedUpper(payload["peerUserId"]),
      )
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked("bind-surface", payload)
      val result = statusSnapshotLocked()
      emitChangeLocked("surfaceBindingChanged", surfaceBindings[surfaceId]?.chatId, null)
      return result
    }
  }

  fun unbindSurface(payload: Map<String, Any?>): Map<String, Any?> {
    val surfaceId = normalized(payload["surfaceId"] ?: payload["engineSurfaceId"]) ?: return getStatus()
    synchronized(lock) {
      surfaceBindings.remove(surfaceId)
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked("unbind-surface", mapOf("surfaceId" to surfaceId))
      val result = statusSnapshotLocked()
      emitChangeLocked("surfaceBindingChanged", null, null)
      return result
    }
  }

  fun openChatChannel(payload: Map<String, Any?>): Map<String, Any?> =
    synchronized(lock) {
      val resolvedChatId = normalized(payload["chatId"] ?: payload["chat_id"])
      resolvedChatId?.let { chatId ->
        openChatChannels[chatId] = (openChatChannels[chatId] ?: 0) + 1
        joinNativeChatTopicIfNeededLocked(chatId)
      }
      appendJournalLocked("open-chat-channel", payload)
      state["updatedAt"] = System.currentTimeMillis()
      val result = statusSnapshotLocked()
      emitChangeLocked("chatChannelStateChanged", resolvedChatId, null)
      result
    }

  fun closeChatChannel(payload: Map<String, Any?>): Map<String, Any?> =
    synchronized(lock) {
      val resolvedChatId = normalized(payload["chatId"] ?: payload["chat_id"])
      resolvedChatId?.let { chatId ->
        val current = openChatChannels[chatId] ?: 0
        when {
          current <= 1 -> {
            openChatChannels.remove(chatId)
            nativeJoinedChatIds.remove(chatId)
            phoenixClient?.leave(chatTopic(chatId))
          }
          else -> openChatChannels[chatId] = current - 1
        }
      }
      appendJournalLocked("close-chat-channel", payload)
      state["updatedAt"] = System.currentTimeMillis()
      val result = statusSnapshotLocked()
      emitChangeLocked("chatChannelStateChanged", resolvedChatId, null)
      result
    }

  fun sendDeliveryReceipt(payload: Map<String, Any?>): Map<String, Any?> =
    sendReceipt(payload, "delivered", "delivery-receipt", "delivery-receipt")

  fun sendReadReceipt(payload: Map<String, Any?>): Map<String, Any?> =
    sendReceipt(payload, "read", "read-receipt", "read-receipt")

  fun upsertLocalMessageStatus(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return getStatus()
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return getStatus()
    val status = normalized(payload["status"])?.lowercase() ?: return getStatus()
    return if (status == "delivered" || status == "read") {
      markReceipt(payload, status, "upsert-local-status")
    } else {
      synchronized(lock) {
        upsertLocalStatusLocked(chatId, messageId, status)
        appendJournalLocked("upsert-local-status", payload)
        state["updatedAt"] = System.currentTimeMillis()
        val result = statusSnapshotLocked()
        emitChangeLocked("messageStatusChanged", chatId, messageId)
        result
      }
    }
  }

  fun sendEncryptedMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val messagePayload = payload["message"] as? Map<String, Any?> ?: return mapOf("accepted" to false, "reason" to "invalid_payload")
    return synchronized(lock) {
      val client = phoenixClient
      if (client == null) {
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket")
      }
      if (!nativeJoinedChatIds.contains(chatId)) {
        joinNativeChatTopicIfNeededLocked(chatId)
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined")
      }
      upsertLocalStatusLocked(chatId, messageId, "sending")
      val ref = client.push(chatTopic(chatId), "message", messagePayload)
      nativePendingMessagePushRefs[ref] = chatId to messageId
      appendJournalLocked("native-send-message", mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref))
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      mapOf("accepted" to true, "transport" to "native", "ref" to ref)
    }
  }

  fun sendEditMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val encryptedContent = normalized(payload["encryptedContent"] ?: payload["encrypted_content"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_payload")
    val editedAt = payload["editedAt"] ?: payload["edited_at"]
    return synchronized(lock) {
      val client = phoenixClient
      if (client == null) {
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket")
      }
      if (!nativeJoinedChatIds.contains(chatId)) {
        joinNativeChatTopicIfNeededLocked(chatId)
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined")
      }
      val wirePayload = linkedMapOf<String, Any?>(
        "messageId" to messageId,
        "encryptedContent" to encryptedContent,
      )
      if (editedAt != null) wirePayload["editedAt"] = editedAt
      val ref = client.push(chatTopic(chatId), "edit-message", wirePayload)
      nativePendingEditPushRefs[ref] = chatId to messageId
      appendJournalLocked(
        "native-send-edit-message",
        mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref),
      )
      mapOf("accepted" to true, "transport" to "native", "ref" to ref)
    }
  }

  fun sendDeleteMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val forEveryone = when (val raw = payload["forEveryone"] ?: payload["for_everyone"]) {
      is Boolean -> raw
      is Number -> raw.toInt() != 0
      is String -> raw.equals("true", ignoreCase = true) || raw == "1" || raw.equals("yes", ignoreCase = true)
      else -> true
    }
    return synchronized(lock) {
      val client = phoenixClient
      if (client == null) {
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket")
      }
      if (!nativeJoinedChatIds.contains(chatId)) {
        joinNativeChatTopicIfNeededLocked(chatId)
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined")
      }
      val ref = client.push(
        chatTopic(chatId),
        "delete-message",
        mapOf("messageId" to messageId, "forEveryone" to forEveryone),
      )
      nativePendingDeletePushRefs[ref] = chatId to messageId
      appendJournalLocked(
        "native-send-delete-message",
        mapOf("chatId" to chatId, "messageId" to messageId, "forEveryone" to forEveryone, "ref" to ref),
      )
      mapOf("accepted" to true, "transport" to "native", "ref" to ref)
    }
  }

  fun getJournal(): List<Map<String, Any?>> {
    val ctx = appContextRef ?: return emptyList()
    return ChatEngineStore.getJournal(ctx)
  }

  fun clearJournal(): Map<String, Any?> {
    appContextRef?.let { ChatEngineStore.clearJournal(it) }
    synchronized(lock) {
      state["updatedAt"] = System.currentTimeMillis()
      state["journalCount"] = 0
      return statusSnapshotLocked()
    }
  }

  fun getLiveMessageRow(payload: Map<String, Any?>): Map<String, Any?>? {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return null
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return null
    synchronized(lock) {
      return liveMessageRowsByChat[chatId]?.get(messageId)
    }
  }

  fun getChatRows(payload: Map<String, Any?>): List<Map<String, Any?>> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return emptyList()
    synchronized(lock) {
      return historyRowsByChat[chatId]?.toList() ?: emptyList()
    }
  }

  fun isLiveMessageDeleted(payload: Map<String, Any?>): Boolean {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return false
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return false
    synchronized(lock) {
      return deletedMessageIdsByChat[chatId]?.contains(messageId) == true
    }
  }

  // Shadow-mode bridge until native Phoenix transport is implemented.
  fun setPresenceSnapshot(userIds: List<String>): Map<String, Any?> =
    synchronized(lock) {
      if (nativePresenceActive) {
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("set-presence-snapshot-ignored", mapOf("count" to userIds.size))
        return statusSnapshotLocked()
      }
      onlineUsers.clear()
      userIds.mapNotNullTo(onlineUsers) { normalizedUpper(it) }
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked("set-presence-snapshot", mapOf("count" to onlineUsers.size))
      state["presenceSource"] = "shadow"
      val result = statusSnapshotLocked()
      emitChangeLocked("presenceChanged", null, null)
      result
    }

  fun resolveDisplayStatus(
    chatId: String?,
    messageId: String?,
    rawStatus: String?,
    isMe: Boolean,
    peerUserId: String?,
  ): String? {
    val normalizedRaw = rawStatus?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
    if (!isMe) return normalizedRaw
    if (normalizedRaw == "read") return "read"
    synchronized(lock) {
      val receipt = if (!chatId.isNullOrBlank() && !messageId.isNullOrBlank()) {
        receiptIndex[chatId]?.get(messageId)
      } else {
        null
      }
      val localStatus = if (!chatId.isNullOrBlank() && !messageId.isNullOrBlank()) {
        localStatusIndex[chatId]?.get(messageId)
      } else {
        null
      }
      if (receipt == "read") return "read"
      if (receipt == "delivered") return "delivered"
      if (normalizedRaw == "delivered") return "delivered"
      when (localStatus) {
        "error" -> return "error"
        "sent" -> {
          if (!peerUserId.isNullOrBlank() && onlineUsers.contains(peerUserId.trim().uppercase())) {
            return "delivered"
          }
          return "sent"
        }
        "pending", "sending" -> {
          if (normalizedRaw == null || normalizedRaw == "pending" || normalizedRaw == "sending") {
            return localStatus
          }
        }
      }
      if (normalizedRaw == "sent" && !peerUserId.isNullOrBlank() && onlineUsers.contains(peerUserId.trim().uppercase())) {
        return "delivered"
      }
      return normalizedRaw
    }
  }

  private fun markReceipt(payload: Map<String, Any?>, status: String, eventName: String): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return getStatus()
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return getStatus()
    synchronized(lock) {
      val chatMap = receiptIndex.getOrPut(chatId) { linkedMapOf() }
      chatMap[messageId] = strongerStatus(chatMap[messageId], status)
      upsertLocalStatusLocked(chatId, messageId, status)
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked(eventName, payload)
      val result = statusSnapshotLocked()
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      return result
    }
  }

  private fun sendReceipt(
    payload: Map<String, Any?>,
    status: String,
    eventName: String,
    wireEvent: String,
  ): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return getStatus()
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return getStatus()
    synchronized(lock) {
      val chatMap = receiptIndex.getOrPut(chatId) { linkedMapOf() }
      chatMap[messageId] = strongerStatus(chatMap[messageId], status)
      upsertLocalStatusLocked(chatId, messageId, status)

      var accepted = false
      var ref: String? = null
      if (nativeJoinedChatIds.contains(chatId) && (state["connected"] as? Boolean) == true) {
        val client = phoenixClient
        if (client != null) {
          ref = client.push(chatTopic(chatId), wireEvent, mapOf("messageId" to messageId))
          accepted = true
          appendJournalLocked(
            "native-$eventName-push",
            mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref),
          )
        }
      }

      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked(eventName, payload)
      val result = LinkedHashMap(statusSnapshotLocked())
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      result["accepted"] = accepted
      result["transport"] = if (accepted) "native" else "shadow"
      if (ref != null) result["ref"] = ref
      return result
    }
  }

  fun setListener(listenerId: String, listener: ((String, String?, String?) -> Unit)?) {
    synchronized(lock) {
      if (listener == null) {
        listeners.remove(listenerId)
      } else {
        listeners[listenerId] = listener
      }
    }
  }

  private fun strongerStatus(current: String?, incoming: String): String {
    fun rank(v: String?): Int = when (v) {
      "read" -> 2
      "delivered" -> 1
      else -> 0
    }
    return if (rank(incoming) >= rank(current)) incoming else (current ?: incoming)
  }

  private fun strongerDisplayStatus(current: String?, incoming: String): String {
    fun rank(v: String?): Int = when (v) {
      "error" -> 6
      "read" -> 5
      "delivered" -> 4
      "sent" -> 3
      "sending" -> 2
      "pending" -> 1
      else -> 0
    }
    return if (rank(incoming) >= rank(current)) incoming else (current ?: incoming)
  }

  private fun upsertLocalStatusLocked(chatId: String, messageId: String, status: String) {
    val chatMap = localStatusIndex.getOrPut(chatId) { linkedMapOf() }
    chatMap[messageId] = strongerDisplayStatus(chatMap[messageId], status)
    state["localStatusCount"] = localStatusIndex.values.sumOf { it.size }
    state["updatedAt"] = System.currentTimeMillis()
  }

  private fun removeMessageIndicesLocked(chatId: String, messageId: String) {
    receiptIndex[chatId]?.let { chatMap ->
      chatMap.remove(messageId)
      if (chatMap.isEmpty()) receiptIndex.remove(chatId)
    }
    localStatusIndex[chatId]?.let { chatMap ->
      chatMap.remove(messageId)
      if (chatMap.isEmpty()) localStatusIndex.remove(chatId)
    }
    state["receiptCount"] = receiptIndex.values.sumOf { it.size }
    state["localStatusCount"] = localStatusIndex.values.sumOf { it.size }
    state["updatedAt"] = System.currentTimeMillis()
  }

  private fun getConfigValueLocked(key: String): Any? {
    val ctx = appContextRef ?: return null
    return ChatEngineStore.getConfig(ctx)[key]
  }

  private fun apiBaseUrlLocked(): String? {
    val explicit = normalized(getConfigValueLocked("apiBaseUrl") ?: getConfigValueLocked("baseUrl"))
    if (!explicit.isNullOrBlank()) return explicit
    val socketUrl = normalized(getConfigValueLocked("socketUrl") ?: getConfigValueLocked("url")) ?: return null
    val parsed = socketUrl.toHttpUrlOrNull() ?: return null
    val scheme = when (parsed.scheme) {
      "wss" -> "https"
      "ws" -> "http"
      else -> parsed.scheme
    }
    val pathSegments = parsed.pathSegments.toMutableList()
    if (pathSegments.isNotEmpty() && pathSegments.last().equals("socket", ignoreCase = true)) {
      pathSegments.removeAt(pathSegments.size - 1)
    }
    val rebuilt = parsed.newBuilder().scheme(scheme).encodedPath("/" + pathSegments.joinToString("/")).build()
    return rebuilt.toString().trimEnd('/')
  }

  private fun authHeaderTokenLocked(): String? =
    normalized(getConfigValueLocked("authToken") ?: getConfigValueLocked("token"))

  private fun currentUserIdLocked(): String? =
    normalizedUpper(getConfigValueLocked("userId"))

  private fun decryptPrivateKeyLocked(): PrivateKey? {
    val pem = normalized(getConfigValueLocked("privateKeyPem") ?: getConfigValueLocked("privateKey")) ?: return null
    if (cachedDecryptPrivateKey != null && cachedDecryptPrivateKeyPem == pem) {
      return cachedDecryptPrivateKey
    }
    return try {
      val key = chatEngineLoadPrivateKeyFromPem(pem)
      cachedDecryptPrivateKeyPem = pem
      cachedDecryptPrivateKey = key
      key
    } catch (_: Throwable) {
      cachedDecryptPrivateKeyPem = pem
      cachedDecryptPrivateKey = null
      null
    }
  }

  private fun parseLongValue(value: Any?): Long? =
    when (value) {
      is Number -> value.toLong()
      is String -> value.toLongOrNull()
      else -> null
    }

  private fun parseDoubleValue(value: Any?): Double? =
    when (value) {
      is Number -> value.toDouble()
      is String -> value.toDoubleOrNull()
      else -> null
    }

  private fun parseWaveformArray(value: Any?): List<Double>? {
    val rawList: List<*> = when (value) {
      is JSONArray -> (0 until value.length()).map { value.opt(it) }
      is List<*> -> value
      else -> return null
    }
    val mapped = rawList.mapNotNull { parseDoubleValue(it) }
      .map { it.coerceIn(0.0, 1.0) }
    return mapped.ifEmpty { null }
  }

  private fun parseDecryptedMessagePayload(raw: String): Map<String, Any?> {
    val trimmed = raw.trim()
    if (!trimmed.startsWith("{")) return mapOf("text" to raw)
    return try {
      val json = JSONObject(trimmed)
      val out = linkedMapOf<String, Any?>()
      if (json.has("text")) out["text"] = json.optString("text", "")
      if (json.has("mediaUrl")) out["mediaUrl"] = json.opt("mediaUrl")
      if (json.has("duration")) out["duration"] = json.opt("duration")
      if (json.has("isEdited")) out["isEdited"] = json.optBoolean("isEdited", false)
      if (json.has("editedAt")) out["editedAt"] = json.opt("editedAt")
      if (json.has("waveform")) out["waveform"] = json.opt("waveform")
      if (json.has("isVideoNote")) out["isVideoNote"] = json.optBoolean("isVideoNote", false)
      if (json.has("width")) out["width"] = json.opt("width")
      if (json.has("height")) out["height"] = json.opt("height")
      if (json.has("thumbnailBase64")) out["thumbnailBase64"] = json.opt("thumbnailBase64")
      out
    } catch (_: Throwable) {
      mapOf("text" to raw)
    }
  }

  private fun formatMessageTimeLabel(timestampMs: Long): String {
    val formatter = SimpleDateFormat("HH:mm", Locale.getDefault())
    return formatter.format(Date(timestampMs))
  }

  private fun upsertLiveMessageRowLocked(chatId: String, messageId: String, row: Map<String, Any?>) {
    val perChat = liveMessageRowsByChat.getOrPut(chatId) { linkedMapOf() }
    perChat[messageId] = row
    deletedMessageIdsByChat[chatId]?.remove(messageId)
    if (deletedMessageIdsByChat[chatId]?.isEmpty() == true) {
      deletedMessageIdsByChat.remove(chatId)
    }
  }

  private fun markLiveMessageDeletedLocked(chatId: String, messageId: String) {
    liveMessageRowsByChat[chatId]?.let { perChat ->
      perChat.remove(messageId)
      if (perChat.isEmpty()) liveMessageRowsByChat.remove(chatId)
    }
    deletedMessageIdsByChat.getOrPut(chatId) { linkedSetOf() }.add(messageId)
  }

  private fun buildLiveRowPayloadLocked(
    chatId: String,
    messageId: String,
    fromId: String?,
    type: String?,
    timestampMs: Long,
    encryptedContent: String?,
    decryptedFields: Map<String, Any?>,
    forceEdited: Boolean = false,
    forceEditedAt: Any? = null,
  ): Map<String, Any?> {
    val normalizedType = normalized(type)?.lowercase() ?: "text"
    val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserIdLocked()
    val text = normalized(decryptedFields["text"]) ?: ""
    val mediaUrl = normalized(decryptedFields["mediaUrl"])
    val duration = parseDoubleValue(decryptedFields["duration"])
    val waveform = parseWaveformArray(decryptedFields["waveform"])
    val isEdited = forceEdited || ((decryptedFields["isEdited"] as? Boolean) == true)
    val editedAt = forceEditedAt ?: decryptedFields["editedAt"]

    val metadata = linkedMapOf<String, Any?>()
    waveform?.let { metadata["waveform"] = it }
    if (decryptedFields["width"] != null) metadata["width"] = decryptedFields["width"]
    if (decryptedFields["height"] != null) metadata["height"] = decryptedFields["height"]
    if (decryptedFields["thumbnailBase64"] != null) metadata["thumbnailBase64"] = decryptedFields["thumbnailBase64"]
    if (decryptedFields["isVideoNote"] != null) metadata["isVideoNote"] = decryptedFields["isVideoNote"]

    val message = linkedMapOf<String, Any?>(
      "id" to messageId,
      "chatId" to chatId,
      "fromId" to fromId,
      "timestampMs" to timestampMs.toDouble(),
      "timestamp" to formatMessageTimeLabel(timestampMs),
      "text" to text,
      "type" to normalizedType,
      "status" to (if (isMe) "sent" else null),
      "isMe" to isMe,
      "isEdited" to isEdited,
      "editedAt" to editedAt,
      "encryptedContent" to encryptedContent,
      "mediaUrl" to mediaUrl,
      "duration" to duration,
      "metadata" to metadata.takeIf { it.isNotEmpty() },
      "bubbleShape" to mapOf(
        "showTail" to true,
        "borderTopLeftRadius" to 18,
        "borderTopRightRadius" to 18,
        "borderBottomRightRadius" to 18,
        "borderBottomLeftRadius" to 18,
      ),
    )
    return linkedMapOf<String, Any?>(
      "kind" to "message",
      "key" to "m-$messageId",
      "message" to message,
    )
  }

  private fun applyNativeIncomingMessageEventLocked(
    chatId: String,
    payload: Map<String, Any?>,
  ): String? {
    val messageId = normalized(payload["id"] ?: payload["message_id"]) ?: return null
    val fromId = normalized(payload["fromId"] ?: payload["from_id"])
    val encryptedContent = normalized(payload["encryptedContent"] ?: payload["encrypted_content"])
    val type = normalized(payload["type"]) ?: "text"
    val timestampMs = parseLongValue(payload["timestamp"]) ?: System.currentTimeMillis()
    val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserIdLocked()

    val decryptedText = if (!encryptedContent.isNullOrBlank()) {
      decryptPrivateKeyLocked()?.let { chatEngineDecryptHybridMessage(it, encryptedContent, isMe) }.orEmpty()
    } else {
      ""
    }
    val decryptedFields = parseDecryptedMessagePayload(decryptedText)
    val row = buildLiveRowPayloadLocked(
      chatId = chatId,
      messageId = messageId,
      fromId = fromId,
      type = type,
      timestampMs = timestampMs,
      encryptedContent = encryptedContent,
      decryptedFields = decryptedFields,
    )
    upsertLiveMessageRowLocked(chatId, messageId, row)
    appendJournalLocked("native-message-row-upsert", mapOf("chatId" to chatId, "messageId" to messageId, "type" to type))
    state["updatedAt"] = System.currentTimeMillis()
    return messageId
  }

  private fun joinNativeChatTopicIfNeededLocked(chatId: String) {
    if (chatId.isBlank()) return
    loadChatHistoryIfNeededLocked(chatId)
    val client = phoenixClient ?: return
    if ((state["connected"] as? Boolean) != true) return
    if (nativeJoinedChatIds.contains(chatId)) return
    if (nativeChatJoinRefsByRef.values.contains(chatId)) return
    val ref = client.join(chatTopic(chatId), emptyMap())
    nativeChatJoinRefsByRef[ref] = chatId
    appendJournalLocked("native-chat-join-start", mapOf("chatId" to chatId, "ref" to ref))
  }

  private fun chatTopic(chatId: String): String = "chat:$chatId"

  private fun loadChatHistoryIfNeededLocked(chatId: String, force: Boolean = false) {
    if (chatId.isBlank()) return
    if (historyLoadingChats.contains(chatId)) return
    if (!force && historyRowsByChat.containsKey(chatId)) return
    val apiBaseUrl = apiBaseUrlLocked()
    val userId = normalized(getConfigValueLocked("userId"))
    if (apiBaseUrl.isNullOrBlank() || userId.isNullOrBlank()) {
      appendJournalLocked(
        "native-chat-history-skip",
        mapOf("chatId" to chatId, "reason" to "missing_config"),
      )
      return
    }
    historyLoadingChats.add(chatId)
    appendJournalLocked("native-chat-history-load-start", mapOf("chatId" to chatId))

    val requestBuilder = Request.Builder()
      .url("$apiBaseUrl/chats/$userId")
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    authHeaderTokenLocked()?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }
    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          historyLoadingChats.remove(chatId)
          appendJournalLocked(
            "native-chat-history-load-error",
            mapOf("chatId" to chatId, "error" to (e.message ?: "network_error")),
          )
          emitChangeLocked("engineError", chatId, null)
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          val bodyString = try { res.body?.string() } catch (_: Throwable) { null }
          synchronized(lock) {
            historyLoadingChats.remove(chatId)
            if (!res.isSuccessful || bodyString == null) {
              appendJournalLocked(
                "native-chat-history-load-error",
                mapOf("chatId" to chatId, "status" to res.code),
              )
              return
            }
            applyChatHistoryResponseLocked(chatId, bodyString)
          }
        }
      }
    })
  }

  private fun applyChatHistoryResponseLocked(chatId: String, bodyString: String) {
    try {
      val root = JSONArray(bodyString)
      var targetChat: JSONObject? = null
      for (i in 0 until root.length()) {
        val chat = root.optJSONObject(i) ?: continue
        val id = normalized(chat.opt("chatId") ?: chat.opt("chat_id"))
        if (id == chatId) {
          targetChat = chat
          break
        }
      }
      val messages = targetChat?.optJSONArray("messages") ?: JSONArray()
      val rows = buildHistoryRowsLocked(chatId, messages)
      historyRowsByChat[chatId] = rows.toMutableList()
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked(
        "native-chat-history-load-ok",
        mapOf("chatId" to chatId, "rows" to rows.size, "messages" to messages.length()),
      )
      emitChangeLocked("chatRowsReloaded", chatId, null)
    } catch (e: Throwable) {
      appendJournalLocked(
        "native-chat-history-load-error",
        mapOf("chatId" to chatId, "error" to (e.message ?: "invalid_json")),
      )
    }
  }

  private fun buildHistoryRowsLocked(chatId: String, messages: JSONArray): List<Map<String, Any?>> {
    val rawMessages = ArrayList<JSONObject>(messages.length())
    for (i in 0 until messages.length()) {
      messages.optJSONObject(i)?.let { rawMessages.add(it) }
    }
    rawMessages.sortBy {
      parseLongValue(it.opt("timestamp") ?: it.opt("timestampMs") ?: it.opt("timestamp_ms")) ?: 0L
    }
    val rows = ArrayList<Map<String, Any?>>(rawMessages.size)
    for (raw in rawMessages) {
      val messageId = normalized(raw.opt("id") ?: raw.opt("message_id")) ?: continue
      val fromId = normalized(raw.opt("fromId") ?: raw.opt("from_id"))
      val type = normalized(raw.opt("type")) ?: "text"
      val timestampMs =
        parseLongValue(raw.opt("timestamp") ?: raw.opt("timestampMs") ?: raw.opt("timestamp_ms"))
          ?: System.currentTimeMillis()
      val encryptedContent = normalized(raw.opt("encryptedContent") ?: raw.opt("encrypted_content"))
      val plaintextFallback = normalized(raw.opt("plaintext") ?: raw.opt("text")).orEmpty()
      val serverStatus = normalized(raw.opt("status"))?.lowercase()
      val isEdited = raw.opt("isEdited") as? Boolean ?: false
      val editedAt = raw.opt("editedAt") ?: raw.opt("edited_at")
      val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserIdLocked()

      val decryptedFields = if (!encryptedContent.isNullOrBlank()) {
        val privateKey = decryptPrivateKeyLocked()
        val decrypted = privateKey?.let { chatEngineDecryptHybridMessage(it, encryptedContent, isMe) }.orEmpty()
        val parsed = parseDecryptedMessagePayload(decrypted)
        if (parsed.isEmpty() && plaintextFallback.isNotBlank()) mapOf("text" to plaintextFallback) else parsed
      } else if (plaintextFallback.isNotBlank()) {
        mapOf("text" to plaintextFallback)
      } else {
        emptyMap()
      }

      val row = (buildLiveRowPayloadLocked(
        chatId = chatId,
        messageId = messageId,
        fromId = fromId,
        type = type,
        timestampMs = timestampMs,
        encryptedContent = encryptedContent,
        decryptedFields = decryptedFields,
        forceEdited = isEdited,
        forceEditedAt = editedAt,
      ).toMutableMap())
      val message = (row["message"] as? Map<String, Any?>)?.toMutableMap() ?: mutableMapOf()
      if (!serverStatus.isNullOrBlank()) message["status"] = serverStatus
      val reactionEmoji = normalized(raw.opt("reactionEmoji") ?: raw.opt("reaction_emoji"))
      if (!reactionEmoji.isNullOrBlank()) message["reactionEmoji"] = reactionEmoji
      row["message"] = message
      rows.add(row)
    }
    return rows
  }

  private fun onNativeSocketOpen(userTopic: String) {
    synchronized(lock) {
      val client = phoenixClient ?: return
      state["connected"] = true
      state["state"] = "native-socket-open"
      state["updatedAt"] = System.currentTimeMillis()
      state["note"] = "ChatEngine native Phoenix socket open"
      appendJournalLocked("native-socket-open", emptyMap())
      nativeUserTopic = userTopic
      nativeUserJoinRef = client.join(userTopic, emptyMap())
      nativeChatJoinRefsByRef.clear()
      nativeJoinedChatIds.clear()
      nativePendingMessagePushRefs.clear()
      nativePendingEditPushRefs.clear()
      nativePendingDeletePushRefs.clear()
      historyLoadingChats.clear()
      liveMessageRowsByChat.clear()
      deletedMessageIdsByChat.clear()
      openChatChannels.keys.forEach { joinNativeChatTopicIfNeededLocked(it) }
      emitChangeLocked("connectionStateChanged", null, null)
    }
  }

  private fun onNativeSocketClosed(code: Int, reason: String?) {
    synchronized(lock) {
      nativePresenceActive = false
      nativeUserJoinRef = null
      nativeChatJoinRefsByRef.clear()
      nativeJoinedChatIds.clear()
      nativePendingMessagePushRefs.clear()
      nativePendingEditPushRefs.clear()
      nativePendingDeletePushRefs.clear()
      historyLoadingChats.clear()
      liveMessageRowsByChat.clear()
      deletedMessageIdsByChat.clear()
      state["connected"] = false
      state["state"] = "native-socket-closed"
      state["updatedAt"] = System.currentTimeMillis()
      state["presenceSource"] = "shadow"
      appendJournalLocked(
        "native-socket-closed",
        mapOf("code" to code, "reason" to reason),
      )
      emitChangeLocked("connectionStateChanged", null, null)
    }
  }

  private fun onNativeSocketError(error: String) {
    synchronized(lock) {
      state["updatedAt"] = System.currentTimeMillis()
      state["lastNativeSocketError"] = error
      appendJournalLocked("native-socket-error", mapOf("error" to error))
      emitChangeLocked("engineError", null, null)
    }
  }

  private fun onNativeSocketEvent(
    topic: String,
    event: String,
    payload: Map<String, Any?>,
    ref: String?,
    joinRef: String?,
  ) {
    synchronized(lock) {
      if (
        event == "phx_reply" &&
          topic == nativeUserTopic &&
          !ref.isNullOrBlank() &&
          ref == nativeUserJoinRef &&
          normalized(payload["status"]) == "ok"
      ) {
        nativePresenceActive = true
        state["presenceSource"] = "native"
        state["userChannelState"] = "joined"
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("native-user-joined", mapOf("topic" to topic))
        emitChangeLocked("connectionStateChanged", null, null)
        return
      }
      if (event == "phx_reply" && !ref.isNullOrBlank()) {
        val joinedChatId = nativeChatJoinRefsByRef.remove(ref)
        if (!joinedChatId.isNullOrBlank()) {
          val status = normalized(payload["status"])?.lowercase().orEmpty()
          if (status == "ok") {
            nativeJoinedChatIds.add(joinedChatId)
            appendJournalLocked("native-chat-joined", mapOf("chatId" to joinedChatId))
          } else {
            appendJournalLocked("native-chat-join-error", mapOf("chatId" to joinedChatId, "status" to status))
          }
          state["updatedAt"] = System.currentTimeMillis()
          emitChangeLocked("chatChannelStateChanged", joinedChatId, null)
          return
        }

        val pending = nativePendingMessagePushRefs.remove(ref)
        if (pending != null) {
          val (chatId, messageId) = pending
          val status = normalized(payload["status"])?.lowercase().orEmpty()
          val nextStatus = if (status == "ok") "sent" else "error"
          upsertLocalStatusLocked(chatId, messageId, nextStatus)
          appendJournalLocked(
            "native-message-push-reply",
            mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref, "status" to status),
          )
          emitChangeLocked("messageStatusChanged", chatId, messageId)
          return
        }

        val pendingEdit = nativePendingEditPushRefs.remove(ref)
        if (pendingEdit != null) {
          val (chatId, messageId) = pendingEdit
          val status = normalized(payload["status"])?.lowercase().orEmpty()
          appendJournalLocked(
            "native-edit-message-push-reply",
            mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref, "status" to status),
          )
          emitChangeLocked("chatMessageEdited", chatId, messageId)
          return
        }

        val pendingDelete = nativePendingDeletePushRefs.remove(ref)
        if (pendingDelete != null) {
          val (chatId, messageId) = pendingDelete
          val status = normalized(payload["status"])?.lowercase().orEmpty()
          if (status == "ok") {
            removeMessageIndicesLocked(chatId, messageId)
          }
          appendJournalLocked(
            "native-delete-message-push-reply",
            mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref, "status" to status),
          )
          emitChangeLocked("chatMessageDeleted", chatId, messageId)
          return
        }
      }
      if (topic.startsWith("chat:")) {
        val chatId = topic.removePrefix("chat:")
        if (event == "message") {
          val insertedMessageId = applyNativeIncomingMessageEventLocked(chatId, payload)
          if (!insertedMessageId.isNullOrBlank()) {
            emitChangeLocked("chatMessageInserted", chatId, insertedMessageId)
            return
          }
        }
        val mutationUpdate = applyNativeChatMutationEventLocked(chatId, event, payload)
        if (mutationUpdate != null) {
          val reason = when (mutationUpdate.second) {
            "edited" -> "chatMessageEdited"
            "deleted" -> "chatMessageDeleted"
            else -> "chatMessageChanged"
          }
          emitChangeLocked(reason, chatId, mutationUpdate.first)
          return
        }
        val receiptUpdate = applyNativeChatEventLocked(chatId, event, payload)
        if (receiptUpdate != null) {
          emitChangeLocked("messageStatusChanged", chatId, receiptUpdate.first)
          return
        }
      }
      if (topic != nativeUserTopic) return
      if (applyPresenceEventLocked(event, payload)) {
        state["presenceSource"] = "native"
        state["updatedAt"] = System.currentTimeMillis()
        emitChangeLocked("presenceChanged", null, null)
      }
    }
  }

  private fun applyPresenceEventLocked(event: String, payload: Map<String, Any?>): Boolean =
    when (event) {
      "initial-presence" -> {
        onlineUsers.clear()
        ((payload["onlineFriendIds"] as? List<*>) ?: emptyList<Any?>())
          .mapNotNullTo(onlineUsers) { normalizedUpper(it) }
        appendJournalLocked("native-presence-initial", mapOf("count" to onlineUsers.size))
        true
      }

      "friend-online" -> {
        val userId = normalizedUpper(payload["userId"] ?: payload["user_id"] ?: payload["id"]) ?: return false
        onlineUsers.add(userId)
        appendJournalLocked("native-presence-online", mapOf("userId" to userId))
        true
      }

      "friend-offline" -> {
        val userId = normalizedUpper(payload["userId"] ?: payload["user_id"] ?: payload["id"]) ?: return false
        onlineUsers.remove(userId)
        appendJournalLocked("native-presence-offline", mapOf("userId" to userId))
        true
      }

      "presence_state" -> {
        onlineUsers.clear()
        payload.keys.mapNotNullTo(onlineUsers) { normalizedUpper(it) }
        appendJournalLocked("native-presence-state", mapOf("count" to onlineUsers.size))
        true
      }

      "presence_diff", "presence-diff" -> {
        val joins = (payload["joins"] as? Map<*, *>) ?: emptyMap<String, Any?>()
        val leaves = (payload["leaves"] as? Map<*, *>) ?: emptyMap<String, Any?>()
        joins.keys.forEach { key ->
          normalizedUpper(key)?.let { onlineUsers.add(it) }
        }
        leaves.keys.forEach { key ->
          normalizedUpper(key)?.let { onlineUsers.remove(it) }
        }
        appendJournalLocked(
          "native-presence-diff",
          mapOf("joins" to joins.size, "leaves" to leaves.size),
        )
        true
      }

      else -> false
    }

  private fun applyNativeChatMutationEventLocked(
    chatId: String,
    event: String,
    payload: Map<String, Any?>,
  ): Pair<String, String>? {
    if (chatId.isBlank()) return null
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return null
    return when (event) {
      "message-edited" -> {
        val encryptedContent = normalized(payload["encryptedContent"] ?: payload["encrypted_content"])
        val editedAt = payload["editedAt"] ?: payload["edited_at"]
        val existingRow = liveMessageRowsByChat[chatId]?.get(messageId)
        val existingMessage = existingRow?.get("message") as? Map<*, *>
        val fromId = normalized(existingMessage?.get("fromId"))
        val type = normalized(existingMessage?.get("type")) ?: "text"
        val timestampMs =
          parseLongValue(existingMessage?.get("timestampMs"))
            ?: parseLongValue(existingMessage?.get("timestamp"))
            ?: System.currentTimeMillis()
        val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserIdLocked()
        val decryptedFields = if (!encryptedContent.isNullOrBlank()) {
          val decrypted = decryptPrivateKeyLocked()?.let { chatEngineDecryptHybridMessage(it, encryptedContent, isMe) }.orEmpty()
          parseDecryptedMessagePayload(decrypted)
        } else {
          emptyMap()
        }
        val row = buildLiveRowPayloadLocked(
          chatId = chatId,
          messageId = messageId,
          fromId = fromId,
          type = type,
          timestampMs = timestampMs,
          encryptedContent = encryptedContent ?: normalized(existingMessage?.get("encryptedContent")),
          decryptedFields = decryptedFields,
          forceEdited = true,
          forceEditedAt = editedAt,
        )
        upsertLiveMessageRowLocked(chatId, messageId, row)
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked(
          "native-message-edited",
          mapOf(
            "chatId" to chatId,
            "messageId" to messageId,
            "editedAt" to editedAt,
          ),
        )
        messageId to "edited"
      }

      "message-deleted" -> {
        removeMessageIndicesLocked(chatId, messageId)
        markLiveMessageDeletedLocked(chatId, messageId)
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("native-message-deleted", mapOf("chatId" to chatId, "messageId" to messageId))
        messageId to "deleted"
      }

      else -> null
    }
  }

  private fun applyNativeChatEventLocked(
    chatId: String,
    event: String,
    payload: Map<String, Any?>,
  ): Pair<String, String>? {
    if (chatId.isBlank()) return null
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return null
    return when (event) {
      "message-delivered" -> {
        val chatMap = receiptIndex.getOrPut(chatId) { linkedMapOf() }
        chatMap[messageId] = strongerStatus(chatMap[messageId], "delivered")
        upsertLocalStatusLocked(chatId, messageId, "delivered")
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("native-message-delivered", mapOf("chatId" to chatId, "messageId" to messageId))
        messageId to "delivered"
      }

      "message-read" -> {
        val chatMap = receiptIndex.getOrPut(chatId) { linkedMapOf() }
        chatMap[messageId] = strongerStatus(chatMap[messageId], "read")
        upsertLocalStatusLocked(chatId, messageId, "read")
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("native-message-read", mapOf("chatId" to chatId, "messageId" to messageId))
        messageId to "read"
      }

      else -> null
    }
  }

  private fun statusSnapshotLocked(): Map<String, Any?> {
    val ctx = appContextRef
    val out = LinkedHashMap<String, Any?>(state)
    out["onlineUserCount"] = onlineUsers.size
    out["boundSurfaceCount"] = surfaceBindings.size
    out["boundChatCount"] = surfaceBindings.values.mapNotNull { it.chatId }.toSet().size
    out["openChatChannelCount"] = openChatChannels.size
    out["openChatChannels"] = LinkedHashMap(openChatChannels)
    out["receiptCount"] = receiptIndex.values.sumOf { it.size }
    out["localStatusCount"] = localStatusIndex.values.sumOf { it.size }
    out["nativeJoinedChatCount"] = nativeJoinedChatIds.size
    out["journalCount"] = if (ctx != null) ChatEngineStore.getJournal(ctx).size else 0
    return out
  }

  private fun appendJournalLocked(event: String, payload: Map<String, Any?>) {
    val ctx = appContextRef
    if (ctx == null) {
      Log.d("ChatEngine", "journal skipped missingContext event=$event")
      return
    }
    val entry = linkedMapOf<String, Any?>(
      "event" to event,
      "timestamp" to System.currentTimeMillis(),
      "payload" to payload,
    )
    ChatEngineStore.appendJournal(ctx, entry)
  }

  private fun emitChangeLocked(reason: String, chatId: String?, messageId: String?) {
    if (listeners.isEmpty()) return
    val callbacks = listeners.values.toList()
    callbacks.forEach { callback ->
      try {
        callback(reason, chatId, messageId)
      } catch (_: Throwable) {
      }
    }
  }

  private fun normalized(value: Any?): String? {
    val raw = value?.toString()?.trim().orEmpty()
    return raw.ifEmpty { null }
  }

  private fun normalizedUpper(value: Any?): String? =
    normalized(value)?.uppercase()
}
