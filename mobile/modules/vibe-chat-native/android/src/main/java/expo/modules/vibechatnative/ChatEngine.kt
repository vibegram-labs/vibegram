package expo.modules.vibechatnative

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import expo.modules.vibechatnative.notifications.VibeNativeCallStore
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.buffer
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
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
  val der = chatEngineDecodePem(privateKeyPem)

  // Try PKCS#8 first ("BEGIN PRIVATE KEY")
  try {
    return keyFactory.generatePrivate(PKCS8EncodedKeySpec(der))
  } catch (_: Throwable) { /* fall through */ }

  // Wrap PKCS#1 ("BEGIN RSA PRIVATE KEY") DER inside a PKCS#8 envelope.
  // PKCS#8 = SEQUENCE { version(0), AlgorithmIdentifier(rsaEncryption, NULL), OCTET STRING(pkcs1) }
  val rsaOidHeader = byteArrayOf(
    0x30, 0x0d,                             // SEQUENCE (13 bytes) — AlgorithmIdentifier
    0x06, 0x09, 0x2a, 0x86.toByte(), 0x48, 0x86.toByte(),
    0xf7.toByte(), 0x0d, 0x01, 0x01, 0x01, // OID 1.2.840.113549.1.1.1 (rsaEncryption)
    0x05, 0x00                              // NULL
  )
  val versionBytes = byteArrayOf(0x02, 0x01, 0x00) // INTEGER 0
  val octetTag = byteArrayOf(0x04)
  val octetLen = derEncodeLength(der.size)
  val innerLen = versionBytes.size + rsaOidHeader.size + octetTag.size + octetLen.size + der.size
  val seqTag = byteArrayOf(0x30)
  val seqLen = derEncodeLength(innerLen)
  val pkcs8 = seqTag + seqLen + versionBytes + rsaOidHeader + octetTag + octetLen + der
  try {
    return keyFactory.generatePrivate(PKCS8EncodedKeySpec(pkcs8))
  } catch (e: Throwable) {
    Log.e("ChatEngine", "chatEngineLoadPrivateKeyFromPem FAILED derLen=${der.size}", e)
    throw e
  }
}

/** Encode an ASN.1 DER length field. */
private fun derEncodeLength(length: Int): ByteArray {
  if (length < 0x80) return byteArrayOf(length.toByte())
  val lenBytes = mutableListOf<Byte>()
  var remaining = length
  while (remaining > 0) {
    lenBytes.add(0, (remaining and 0xFF).toByte())
    remaining = remaining shr 8
  }
  return byteArrayOf((0x80 or lenBytes.size).toByte()) + lenBytes.toByteArray()
}

private fun chatEngineLoadPublicKeyFromPem(publicKeyPem: String): PublicKey {
  val keyFactory = KeyFactory.getInstance("RSA")
  return keyFactory.generatePublic(X509EncodedKeySpec(chatEngineDecodePem(publicKeyPem)))
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

private fun chatEngineRsaEncryptOAEP(publicKey: PublicKey, plain: ByteArray): ByteArray {
  val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
  cipher.init(Cipher.ENCRYPT_MODE, publicKey, chatEngineOaepSpec)
  return cipher.doFinal(plain)
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

private fun chatEngineEncryptHybridMessage(
  recipientPublicKeyPem: String,
  message: String,
  myPublicKeyPem: String?,
): String {
  val secureRandom = SecureRandom()
  val aesKey = ByteArray(32).also { secureRandom.nextBytes(it) }
  val iv = ByteArray(12).also { secureRandom.nextBytes(it) }

  val aesCipher = Cipher.getInstance("AES/GCM/NoPadding")
  aesCipher.init(
    Cipher.ENCRYPT_MODE,
    SecretKeySpec(aesKey, "AES"),
    GCMParameterSpec(128, iv),
  )
  val encryptedWithTag = aesCipher.doFinal(message.toByteArray(StandardCharsets.UTF_8))

  val recipientPublicKey = chatEngineLoadPublicKeyFromPem(recipientPublicKeyPem)
  val encryptedRecipientKey = chatEngineRsaEncryptOAEP(recipientPublicKey, aesKey)

  var senderEncryptedKeyB64: String? = null
  if (!myPublicKeyPem.isNullOrBlank()) {
    try {
      val senderPublicKey = chatEngineLoadPublicKeyFromPem(myPublicKeyPem)
      senderEncryptedKeyB64 = Base64.encodeToString(
        chatEngineRsaEncryptOAEP(senderPublicKey, aesKey),
        Base64.NO_WRAP,
      )
    } catch (_: Throwable) {
      // Keep payload valid if sender-key branch fails.
    }
  }

  return JSONObject().apply {
    put("v", 1)
    put("iv", Base64.encodeToString(iv, Base64.NO_WRAP))
    put("c", Base64.encodeToString(encryptedWithTag, Base64.NO_WRAP))
    put("k", Base64.encodeToString(encryptedRecipientKey, Base64.NO_WRAP))
    if (senderEncryptedKeyB64 != null) put("s", senderEncryptedKeyB64)
  }.toString()
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
  private val lastSeenByUserId = linkedMapOf<String, Long>()
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
  private val pendingOutboundDraftsByMessageId = linkedMapOf<String, Map<String, Any?>>()
  private val pendingOutboundQueueByChat = linkedMapOf<String, MutableList<String>>()
  private val nativeTypingStateByChatId = linkedMapOf<String, Boolean>()
  private val peerTypingUserIdsByChatId = linkedMapOf<String, MutableSet<String>>()
  private val nativeRecordingStateByChatId = linkedMapOf<String, Boolean>()
  private val pinnedMessagesByChatId = linkedMapOf<String, MutableList<Map<String, Any?>>>()
  private val pinnedFetchInFlightChatIds = linkedSetOf<String>()
  private val historyRowsByChat = linkedMapOf<String, MutableList<Map<String, Any?>>>()
  private val historyLoadingChats = linkedSetOf<String>()
  private val liveMessageRowsByChat = linkedMapOf<String, MutableMap<String, Map<String, Any?>>>()
  private val deletedMessageIdsByChat = linkedMapOf<String, MutableSet<String>>()
  private val chatPeerUserIdsByChatId = linkedMapOf<String, String>()
  private val friendPublicKeysByUserId = linkedMapOf<String, String>()
  private var cachedDecryptPrivateKeyPem: String? = null
  private var cachedDecryptPrivateKey: PrivateKey? = null
  private var cachedDecryptKeyTimestampMs: Long = 0L
  /// Time-to-live for the cached private key in memory (milliseconds).
  /// After this period of inactivity the key is cleared and re-derived from secure storage.
  private val keyTTLMs: Long = 300_000L
  // Use the same pinned OkHttpClient with cert pinning + TLS enforcement
  // for history HTTP requests as the WebSocket connection uses.
  private val historyHttpClient by lazy { ChatPhoenixClient.buildPinnedHttpClient() }
  private const val fallbackApiBaseURL = "https://modest-recreation-production-8329.up.railway.app"
  private const val AGENT_USER_ID = "00000000-0000-0000-0000-000000000001"

  private fun hasNativeSocketConfigLocked(): Boolean {
    val ctx = appContextRef ?: return false
    val config = ChatEngineStore.getConfig(ctx)
    val socketUrl = normalized(config["socketUrl"] ?: config["url"])
    val userId = normalized(config["userId"])
    val token = normalized(config["authToken"] ?: config["token"])
    return socketUrl != null && userId != null && token != null
  }

  private fun deriveSocketUrlFromApiBase(apiBaseUrl: String): String? {
    val trimmed = apiBaseUrl.trim().trimEnd('/')
    if (trimmed.isBlank()) return null
    return trimmed.replaceFirst(Regex("^http", RegexOption.IGNORE_CASE), "ws") + "/socket"
  }

  @Suppress("LongMethod")
  private fun bootstrapConfigFromNativeSessionIfNeededLocked(trigger: String): Boolean {
    if (hasNativeSocketConfigLocked()) return true
    val ctx = appContextRef ?: run {
      appendJournalLocked(
        "native-config-bootstrap-skip",
        mapOf("trigger" to trigger, "reason" to "missing_context"),
      )
      return false
    }

    val existing = ChatEngineStore.getConfig(ctx)
    val nativeCallConfig = try {
      VibeNativeCallStore.getNativeEngineConfig(ctx)
    } catch (_: Throwable) {
      emptyMap()
    }

    val userId = normalized(existing["userId"] ?: nativeCallConfig["userId"])
      ?: run {
        appendJournalLocked(
          "native-config-bootstrap-skip",
          mapOf("trigger" to trigger, "reason" to "missing_user_id"),
        )
        return false
      }

    val apiBase =
      normalized(
        existing["apiBaseUrl"] ?: existing["baseUrl"] ?: nativeCallConfig["baseUrl"]
          ?: nativeCallConfig["apiBaseUrl"],
      )
        ?: fallbackApiBaseURL
    val socketUrl =
      normalized(
        existing["socketUrl"] ?: existing["url"] ?: nativeCallConfig["socketUrl"]
          ?: nativeCallConfig["signalingUrl"],
      )
        ?: deriveSocketUrlFromApiBase(apiBase)
        ?: run {
          appendJournalLocked(
            "native-config-bootstrap-skip",
            mapOf("trigger" to trigger, "reason" to "missing_socket_url"),
          )
          return false
        }
    val token =
      normalized(
        existing["authToken"] ?: existing["token"] ?: nativeCallConfig["authToken"]
          ?: nativeCallConfig["token"],
      ) ?: userId

    val merged = LinkedHashMap(existing)
    merged["apiBaseUrl"] = apiBase
    merged["socketUrl"] = socketUrl
    merged["authToken"] = token
    merged["userId"] = userId
    if (normalized(existing["userChannelTopic"]) == null) {
      merged["userChannelTopic"] = "user:$userId"
    }
    if (normalized(existing["privateKeyPem"] ?: existing["privateKey"]) == null) {
      val privateKeyPem = normalized(nativeCallConfig["privateKeyPem"] ?: nativeCallConfig["privateKey"])
      if (!privateKeyPem.isNullOrBlank()) {
        merged["privateKeyPem"] = privateKeyPem
      }
    }
    if (normalized(existing["publicKeyPem"] ?: existing["publicKey"]) == null) {
      val publicKeyPem = normalized(nativeCallConfig["publicKeyPem"] ?: nativeCallConfig["publicKey"])
      if (!publicKeyPem.isNullOrBlank()) {
        merged["publicKeyPem"] = publicKeyPem
      }
    }

    ChatEngineStore.setConfig(ctx, merged)
    state["state"] = "configured-native-bootstrap"
    state["updatedAt"] = System.currentTimeMillis()
    state["configuredAt"] = state["updatedAt"]
    state["configKeys"] = merged.keys.sorted()
    state["note"] = "ChatEngine configured from native session"
    state["presenceSource"] = if (nativePresenceActive) "native" else "shadow"
    appendJournalLocked(
      "native-config-bootstrap",
      mapOf(
        "trigger" to trigger,
        "hasSocketUrl" to (normalized(merged["socketUrl"] ?: merged["url"]) != null),
        "hasUserId" to (normalized(merged["userId"]) != null),
        "hasToken" to (normalized(merged["authToken"] ?: merged["token"]) != null),
        "hasPrivateKey" to (normalized(merged["privateKeyPem"] ?: merged["privateKey"]) != null),
        "hasPublicKey" to (normalized(merged["publicKeyPem"] ?: merged["publicKey"]) != null),
      ),
    )
    return true
  }

  private fun ensureNativeTransport(trigger: String) {
    val shouldConnect = synchronized(lock) {
      val connected = state["connected"] == true
      val currentState = normalized(state["state"])?.lowercase().orEmpty()
      if (connected || currentState == "connecting-native-presence" || currentState == "native-socket-open") {
        false
      } else {
        bootstrapConfigFromNativeSessionIfNeededLocked(trigger)
      }
    }
    if (shouldConnect) {
      connect()
    }
  }

  private fun ensureNativeTransportAsync(trigger: String) {
    Thread {
      try {
        ensureNativeTransport(trigger)
      } catch (_: Throwable) {
      }
    }.apply { isDaemon = true }.start()
  }

  fun configure(context: Context, payload: Map<String, Any?>): Map<String, Any?> {
    appContextRef = context.applicationContext
    ChatEngineStore.setConfig(context, payload)
    val snapshot = synchronized(lock) {
      state["state"] = "configured"
      state["updatedAt"] = System.currentTimeMillis()
      state["configuredAt"] = state["updatedAt"]
      state["configKeys"] = payload.keys.sorted()
      state["note"] = "ChatEngine configured (native Phoenix presence enabled, shadow fallback active)"
      state["presenceSource"] = if (nativePresenceActive) "native" else "shadow"
      appendJournalLocked("configure", mapOf("keys" to payload.keys.sorted()))
      openChatChannels.keys.forEach { joinNativeChatTopicIfNeededLocked(it) }
      val result = statusSnapshotLocked()
      emitChangeLocked("configure", null, null)
      result
    }
    ensureNativeTransport("configure")
    return snapshot
  }

  fun getStatus(): Map<String, Any?> =
    synchronized(lock) { statusSnapshotLocked() }

  fun isUserOnline(userId: String?): Boolean =
    synchronized(lock) {
      val normalized = normalizedUpper(userId) ?: return@synchronized false
      onlineUsers.contains(normalized)
    }

  fun lastSeenTimestampMs(userId: String?): Long? =
    synchronized(lock) {
      val normalized = normalizedUpper(userId) ?: return@synchronized null
      lastSeenByUserId[normalized]
    }

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
    synchronized(lock) {
      bootstrapConfigFromNativeSessionIfNeededLocked("connect_native_presence")
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
        pendingOutboundDraftsByMessageId.clear()
        pendingOutboundQueueByChat.clear()
        nativeTypingStateByChatId.clear()
        peerTypingUserIdsByChatId.clear()
        nativeRecordingStateByChatId.clear()
        pinnedMessagesByChatId.clear()
        pinnedFetchInFlightChatIds.clear()
        historyLoadingChats.clear()
        liveMessageRowsByChat.clear()
        deletedMessageIdsByChat.clear()
      }
      if (phoenixClient == null) {
        // Pass auth token separately so it goes in the Authorization header,
        // not as a URL query parameter (prevents token leakage in logs/proxies).
        phoenixClient = ChatPhoenixClient(
          socketUrl = socketUrl,
          params = emptyMap(),
          authToken = authToken,
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
      pendingOutboundDraftsByMessageId.clear()
      pendingOutboundQueueByChat.clear()
      nativeTypingStateByChatId.clear()
      peerTypingUserIdsByChatId.clear()
      nativeRecordingStateByChatId.clear()
      pinnedMessagesByChatId.clear()
      pinnedFetchInFlightChatIds.clear()
      historyRowsByChat.clear()
      historyLoadingChats.clear()
      liveMessageRowsByChat.clear()
      deletedMessageIdsByChat.clear()
      // Clear cached private key on disconnect to reduce memory exposure.
      cachedDecryptPrivateKey = null
      cachedDecryptPrivateKeyPem = null
      cachedDecryptKeyTimestampMs = 0L
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
    val snapshot = synchronized(lock) {
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
      result
    }
    ensureNativeTransport("bind_surface")
    return snapshot
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
    }.also {
      ensureNativeTransport("open_chat_channel")
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
            peerTypingUserIdsByChatId.remove(chatId)
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

  fun sendTypingState(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val typing = when (val raw = payload["typing"]) {
      is Boolean -> raw
      is Number -> raw.toInt() != 0
      is String -> raw.equals("true", ignoreCase = true) || raw == "1" || raw.equals("yes", ignoreCase = true) || raw.equals("on", ignoreCase = true)
      else -> false
    }
    return synchronized(lock) {
      if (nativeTypingStateByChatId[chatId] == typing) {
        return@synchronized mapOf("accepted" to true, "transport" to "native", "deduped" to true, "typing" to typing)
      }
      nativeTypingStateByChatId[chatId] = typing
      val client = phoenixClient ?: run {
        ensureNativeTransportAsync("typing_no_socket")
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket", "typing" to typing)
      }
      if (!nativeJoinedChatIds.contains(chatId) || state["connected"] != true) {
        joinNativeChatTopicIfNeededLocked(chatId)
        ensureNativeTransportAsync("typing_chat_not_joined")
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined", "typing" to typing)
      }
      val userId = normalized(getConfigValueLocked("userId")) ?: "me"
      val event = if (typing) "typing" else "stop-typing"
      val ref = client.push(chatTopic(chatId), event, mapOf("userId" to userId))
      appendJournalLocked("native-$event", mapOf("chatId" to chatId, "ref" to ref, "typing" to typing))
      state["updatedAt"] = System.currentTimeMillis()
      emitChangeLocked("typingStateSent", chatId, null)
      mapOf("accepted" to true, "transport" to "native", "ref" to ref, "typing" to typing)
    }
  }

  fun sendRecordingState(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val isRecording = when (val raw = payload["isRecording"] ?: payload["recording"]) {
      is Boolean -> raw
      is Number -> raw.toInt() != 0
      is String -> raw.equals("true", ignoreCase = true) || raw == "1" || raw.equals("yes", ignoreCase = true) || raw.equals("on", ignoreCase = true)
      else -> false
    }
    val isLocked = when (val raw = payload["isLocked"] ?: payload["locked"]) {
      is Boolean -> raw
      is Number -> raw.toInt() != 0
      is String -> raw.equals("true", ignoreCase = true) || raw == "1" || raw.equals("yes", ignoreCase = true) || raw.equals("on", ignoreCase = true)
      else -> false
    }
    val mode = normalized(payload["mode"]) ?: "voice"
    return synchronized(lock) {
      if (nativeRecordingStateByChatId[chatId] == isRecording) {
        return@synchronized mapOf("accepted" to true, "transport" to "native", "deduped" to true, "isRecording" to isRecording)
      }
      nativeRecordingStateByChatId[chatId] = isRecording
      val client = phoenixClient ?: run {
        ensureNativeTransportAsync("recording_no_socket")
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket", "isRecording" to isRecording)
      }
      if (!nativeJoinedChatIds.contains(chatId) || state["connected"] != true) {
        joinNativeChatTopicIfNeededLocked(chatId)
        ensureNativeTransportAsync("recording_chat_not_joined")
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined", "isRecording" to isRecording)
      }
      val userId = normalized(getConfigValueLocked("userId")) ?: "me"
      val event = if (isRecording) "recording" else "stop-recording"
      val wirePayload = linkedMapOf<String, Any?>("userId" to userId)
      if (isRecording) {
        wirePayload["mode"] = mode
        wirePayload["isLocked"] = isLocked
        if (payload["vad"] != null) wirePayload["vad"] = payload["vad"]
      }
      val ref = client.push(chatTopic(chatId), event, wirePayload)
      appendJournalLocked(
        "native-$event",
        mapOf("chatId" to chatId, "ref" to ref, "isRecording" to isRecording, "isLocked" to isLocked, "mode" to mode),
      )
      state["updatedAt"] = System.currentTimeMillis()
      emitChangeLocked("recordingStateSent", chatId, null)
      mapOf("accepted" to true, "transport" to "native", "ref" to ref, "isRecording" to isRecording)
    }
  }

  fun retryOutgoingMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    return synchronized(lock) {
      val draft = pendingOutboundDraftsByMessageId[messageId]
        ?: return@synchronized mapOf("accepted" to false, "reason" to "missing_draft", "messageId" to messageId)
      val chatId =
        normalized(payload["chatId"] ?: payload["chat_id"])
          ?: normalized(draft["chatId"] ?: draft["chat_id"])
          ?: return@synchronized mapOf("accepted" to false, "reason" to "invalid_chat", "messageId" to messageId)
      queueOutboundDraftLocked(chatId, messageId, draft, "manual_retry")
      scheduleReplayQueuedOutboundLocked(chatId, "manual_retry")
      mapOf("accepted" to true, "queued" to true, "messageId" to messageId, "state" to "pending")
    }
  }

  fun cancelOutgoingMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    return synchronized(lock) {
      val draft = pendingOutboundDraftsByMessageId[messageId]
      val chatId =
        normalized(payload["chatId"] ?: payload["chat_id"])
          ?: normalized(draft?.get("chatId") ?: draft?.get("chat_id"))
          ?: return@synchronized mapOf("accepted" to false, "reason" to "invalid_chat", "messageId" to messageId)
      removeQueuedOutboundDraftLocked(chatId, messageId, dropDraft = true)
      upsertLocalStatusLocked(chatId, messageId, "error")
      appendJournalLocked("native-outgoing-cancel", mapOf("chatId" to chatId, "messageId" to messageId))
      emitChangeLocked("outgoingMessageCanceled", chatId, messageId)
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      mapOf("accepted" to true, "messageId" to messageId, "state" to "canceled")
    }
  }

  fun sendMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: run {
        Log.w("ChatEngine", "sendMessage rejected reason=invalid_chat payloadKeys=${payload.keys}")
        return mapOf("accepted" to false, "reason" to "invalid_chat")
      }
    val type = (normalized(payload["type"]) ?: "text").lowercase()
    val text = normalized(payload["text"]) ?: ""
    val supportedTypes = setOf("text", "image", "gif", "file", "voice", "video", "music", "location", "contact")
    if (!supportedTypes.contains(type)) {
      Log.w("ChatEngine", "sendMessage rejected reason=unsupported_type chatId=$chatId type=$type")
      return mapOf("accepted" to false, "reason" to "unsupported_type", "type" to type)
    }
    val metadata = payload["metadata"] as? Map<*, *> ?: emptyMap<String, Any?>()
    fun meta(key: String, vararg aliases: String): Any? {
      payload[key]?.let { return it }
      aliases.forEach { alias -> payload[alias]?.let { return it } }
      metadata[key]?.let { return it }
      aliases.forEach { alias -> metadata[alias]?.let { return it } }
      return null
    }
    var mediaUrl = normalized(meta("mediaUrl", "media_url", "previewUrl", "preview_url"))
    val localPlaybackMediaUrl = mediaUrl?.takeIf { isLocalMediaUri(it) }
    var fileName = normalized(meta("fileName", "file_name"))
    var fileSize = parseLongValue(meta("fileSize", "file_size"))
    val latitude = parseDoubleValue(meta("latitude"))
    val longitude = parseDoubleValue(meta("longitude"))
    val duration = parseDoubleValue(meta("duration"))
    val width = parseLongValue(meta("width"))
    val height = parseLongValue(meta("height"))
    val caption = normalized(meta("caption"))
    val thumbnailBase64 = normalized(meta("thumbnailBase64", "thumbnail_base64"))
    val mediaKey = normalized(meta("mediaKey", "media_key"))
    val contact = meta("contact")
    val viewOnce = meta("viewOnce", "view_once")
    val isVideoNote = meta("isVideoNote", "is_video_note")
    val waveform = meta("waveform")
    if (type == "text" && text.isBlank()) {
      Log.w("ChatEngine", "sendMessage rejected reason=empty_text chatId=$chatId")
      return mapOf("accepted" to false, "reason" to "empty_text")
    }
    if (setOf("image", "gif", "file", "voice", "video", "music").contains(type)) {
      if (mediaUrl.isNullOrBlank()) {
        Log.w(
          "ChatEngine",
          "sendMessage rejected reason=missing_media_url chatId=$chatId type=$type",
        )
        return mapOf("accepted" to false, "reason" to "missing_media_url", "type" to type)
      }
    }
    if (type == "location" && (latitude == null || longitude == null)) {
      Log.w("ChatEngine", "sendMessage rejected reason=invalid_location chatId=$chatId")
      return mapOf("accepted" to false, "reason" to "invalid_location")
    }
    if (type == "contact" && contact == null) {
      Log.w("ChatEngine", "sendMessage rejected reason=missing_contact chatId=$chatId")
      return mapOf("accepted" to false, "reason" to "missing_contact")
    }
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: java.util.UUID.randomUUID().toString().lowercase()
    val timestampMs =
      parseLongValue(payload["timestampMs"] ?: payload["timestamp"] ?: payload["timestamp_ms"])
        ?: System.currentTimeMillis()
    val replyToId =
      normalized(payload["replyToId"] ?: payload["reply_to_id"])
        ?: normalized(metadata["replyToId"] ?: metadata["reply_to_id"])
    val peerUserIdHint = normalizedUpper(payload["peerUserId"] ?: payload["peer_user_id"])
    Log.i(
      "ChatEngine",
      "sendMessage start chatId=$chatId messageId=$messageId type=$type textLen=${text.length} hasPeerHint=${peerUserIdHint != null} mediaLocal=${mediaUrl?.let { isLocalMediaUri(it) } ?: false}",
    )

    return synchronized(lock) {
      val effectivePayload = LinkedHashMap(payload)
      val isGroup = (payload["isGroup"] as? Boolean == true) || (payload["isGroupOrChannel"] as? Boolean == true)
      Log.i("ChatEngine", "sendMessage START chatId=$chatId messageId=$messageId isGroup=$isGroup")

      if (!peerUserIdHint.isNullOrBlank()) {
        chatPeerUserIdsByChatId[chatId] = peerUserIdHint
      }
      val peerUserId = peerUserIdHint ?: chatPeerUserIdsByChatId[chatId]

      // ── Build + emit optimistic row FIRST so message bubble appears instantly ──
      val optimisticStartMs = System.currentTimeMillis()
      val decryptedFields = linkedMapOf<String, Any?>("text" to text)
      if (!mediaUrl.isNullOrBlank()) decryptedFields["mediaUrl"] = mediaUrl
      if (!localPlaybackMediaUrl.isNullOrBlank()) {
        decryptedFields["localMediaUrl"] = localPlaybackMediaUrl
      }
      if (!fileName.isNullOrBlank()) decryptedFields["fileName"] = fileName
      if (fileSize != null) decryptedFields["fileSize"] = fileSize
      if (latitude != null) decryptedFields["latitude"] = latitude
      if (longitude != null) decryptedFields["longitude"] = longitude
      if (duration != null) decryptedFields["duration"] = duration
      if (width != null) decryptedFields["width"] = width
      if (height != null) decryptedFields["height"] = height
      if (!replyToId.isNullOrBlank()) decryptedFields["replyToId"] = replyToId
      if (contact != null) decryptedFields["contact"] = contact
      if (!caption.isNullOrBlank()) decryptedFields["caption"] = caption
      if (!thumbnailBase64.isNullOrBlank()) decryptedFields["thumbnailBase64"] = thumbnailBase64
      if (viewOnce != null) decryptedFields["viewOnce"] = viewOnce
      if (isVideoNote != null) decryptedFields["isVideoNote"] = isVideoNote
      if (waveform != null) decryptedFields["waveform"] = waveform
      val optimisticRow = buildLiveRowPayloadLocked(
        chatId = chatId,
        messageId = messageId,
        fromId = normalized(getConfigValueLocked("userId")),
        type = type,
        timestampMs = timestampMs,
        encryptedContent = null,
        decryptedFields = decryptedFields,
      ).toMutableMap()
      val optimisticMessage = (optimisticRow["message"] as? Map<String, Any?>)?.toMutableMap() ?: linkedMapOf()
      optimisticMessage["status"] = "sending"
      if (!replyToId.isNullOrBlank()) optimisticMessage["replyToId"] = replyToId
      optimisticRow["message"] = optimisticMessage
      upsertLiveMessageRowLocked(chatId, messageId, optimisticRow)
      upsertLocalStatusLocked(chatId, messageId, "sending")
      emitChangeLocked("chatMessageInserted", chatId, messageId)
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      Log.i("ChatEngine", "sendMessage optimistic row emitted in ${System.currentTimeMillis() - optimisticStartMs}ms chatId=$chatId messageId=$messageId")

      val apiBaseUrl = apiBaseUrlLocked()
      val token = authHeaderTokenLocked()
      val userId = normalized(getConfigValueLocked("userId"))
      val myPublicKeyPem = normalized(getConfigValueLocked("publicKeyPem") ?: getConfigValueLocked("publicKey"))

      Thread {
        // ── Now resolve friend public key (may do synchronous HTTP — no longer blocks UI) ──
        val keyResolveStartMs = System.currentTimeMillis()
        val friendPublicKey = if (isGroup) null else {
          synchronized(lock) { resolveFriendPublicKeyLocked(chatId, peerUserId) }
            ?: run {
              Log.w(
                "ChatEngine",
                "sendMessage queued reason=missing_friend_key chatId=$chatId messageId=$messageId peerUserId=$peerUserId keyResolveMs=${System.currentTimeMillis() - keyResolveStartMs}",
              )
              synchronized(lock) {
                pendingOutboundDraftsByMessageId[messageId] = LinkedHashMap(effectivePayload)
                upsertLocalStatusLocked(chatId, messageId, "pending")
                queueOutboundDraftLocked(chatId, messageId, effectivePayload, "missing_friend_key")
                emitChangeLocked("messageStatusChanged", chatId, messageId)
                loadChatHistoryIfNeededLocked(chatId, force = true)
                ensureNativeTransportAsync("send_missing_friend_key")
              }
              return@Thread
            }
        }
        Log.i("ChatEngine", "sendMessage keyResolved in ${System.currentTimeMillis() - keyResolveStartMs}ms chatId=$chatId messageId=$messageId hasKey=${friendPublicKey != null}")

        val needsUpload =
          setOf("image", "gif", "file", "voice", "video", "music").contains(type) &&
            !mediaUrl.isNullOrBlank() &&
            isLocalMediaUri(mediaUrl!!)

        var finalMediaUrl = mediaUrl
        var finalFileName = fileName
        var finalFileSize = fileSize

        if (needsUpload) {
          if (apiBaseUrl.isNullOrBlank() || token.isNullOrBlank() || userId.isNullOrBlank()) {
            synchronized(lock) {
              upsertLocalStatusLocked(chatId, messageId, "pending")
              queueOutboundDraftLocked(chatId, messageId, effectivePayload, "missing_upload_config")
              appendJournalLocked(
                "native-media-upload-error",
                mapOf("chatId" to chatId, "messageId" to messageId, "reason" to "missing_upload_config"),
              )
              emitChangeLocked("messageStatusChanged", chatId, messageId)
            }
            return@Thread
          }
          synchronized(lock) {
            appendJournalLocked(
              "native-media-upload-start",
              mapOf("chatId" to chatId, "messageId" to messageId, "type" to type),
            )
          }

          val uploadResult = uploadLocalMediaLocked(mediaUrl!!, type, fileName, userId, token, apiBaseUrl) { p ->
            synchronized(lock) {
              setLiveMessageUploadProgressLocked(chatId, messageId, p * 0.90f)
            }
          }

          synchronized(lock) {
            when (uploadResult) {
              is LocalMediaUploadOutcome.Success -> {
                finalMediaUrl = uploadResult.value.remoteUrl
                if (finalFileName.isNullOrBlank()) finalFileName = uploadResult.value.fileName
                if (finalFileSize == null) finalFileSize = uploadResult.value.fileSize
                val nextMetadata = linkedMapOf<String, Any?>()
                val existingMetadata = payload["metadata"] as? Map<*, *> ?: emptyMap<String, Any?>()
                existingMetadata.forEach { (k, v) -> if (k != null) nextMetadata[k.toString()] = v }
                nextMetadata["mediaUrl"] = finalMediaUrl
                if (!localPlaybackMediaUrl.isNullOrBlank()) {
                  nextMetadata["localMediaUrl"] = localPlaybackMediaUrl
                }
                if (!finalFileName.isNullOrBlank()) nextMetadata["fileName"] = finalFileName
                if (finalFileSize != null) nextMetadata["fileSize"] = finalFileSize
                effectivePayload["metadata"] = nextMetadata
                effectivePayload["chatId"] = chatId
                effectivePayload["messageId"] = messageId
                effectivePayload["type"] = type
                effectivePayload["text"] = text
                optimisticMessage["mediaUrl"] = finalMediaUrl
                if (!localPlaybackMediaUrl.isNullOrBlank()) {
                  optimisticMessage["localMediaUrl"] = localPlaybackMediaUrl
                }
                if (!finalFileName.isNullOrBlank()) optimisticMessage["fileName"] = finalFileName
                if (finalFileSize != null) optimisticMessage["fileSize"] = finalFileSize
                optimisticRow["message"] = optimisticMessage
                upsertLiveMessageRowLocked(chatId, messageId, optimisticRow)
                appendJournalLocked(
                  "native-media-upload-ok",
                  mapOf("chatId" to chatId, "messageId" to messageId, "url" to finalMediaUrl),
                )
                Log.d(
                  "ChatEngine",
                  "voice upload complete chatId=$chatId messageId=$messageId remoteUrl=${finalMediaUrl?.take(120)} localPlayback=${localPlaybackMediaUrl?.take(120)} type=$type",
                )
              }
              is LocalMediaUploadOutcome.Failure -> {
                val reason = uploadResult.reason
                val shouldQueue = setOf("upload_failed", "upload_timeout", "missing_upload_config").contains(reason)
                upsertLocalStatusLocked(chatId, messageId, if (shouldQueue) "pending" else "error")
                appendJournalLocked(
                  "native-media-upload-error",
                  mapOf("chatId" to chatId, "messageId" to messageId, "reason" to reason),
                )
                emitChangeLocked("messageStatusChanged", chatId, messageId)
                if (shouldQueue) {
                  queueOutboundDraftLocked(chatId, messageId, effectivePayload, reason)
                }
                return@Thread
              }
            }
          }
        }

        val encryptStartMs = System.currentTimeMillis()
        val fullPayload = linkedMapOf<String, Any?>("text" to text)
        if (!finalMediaUrl.isNullOrBlank()) fullPayload["mediaUrl"] = finalMediaUrl
        if (!mediaKey.isNullOrBlank()) fullPayload["mediaKey"] = mediaKey
        if (!finalFileName.isNullOrBlank()) fullPayload["fileName"] = finalFileName
        if (finalFileSize != null) fullPayload["fileSize"] = finalFileSize
        if (latitude != null) fullPayload["latitude"] = latitude
        if (longitude != null) fullPayload["longitude"] = longitude
        if (duration != null) fullPayload["duration"] = duration
        if (width != null) fullPayload["width"] = width
        if (height != null) fullPayload["height"] = height
        if (!replyToId.isNullOrBlank()) fullPayload["replyToId"] = replyToId
        if (contact != null) fullPayload["contact"] = contact
        if (!caption.isNullOrBlank()) fullPayload["caption"] = caption
        if (!thumbnailBase64.isNullOrBlank()) fullPayload["thumbnailBase64"] = thumbnailBase64
        if (viewOnce != null) fullPayload["viewOnce"] = viewOnce
        if (isVideoNote != null) fullPayload["isVideoNote"] = isVideoNote
        if (waveform != null) fullPayload["waveform"] = waveform
        val fullPayloadString = JSONObject(fullPayload).toString()

        val recipientPublicKey = if (!isGroup) {
          friendPublicKey ?: run {
             synchronized(lock) {
                upsertLocalStatusLocked(chatId, messageId, "error")
                emitChangeLocked("messageStatusChanged", chatId, messageId)
             }
             return@Thread
          }
        } else {
          null
        }

        val encryptedContent = if (isGroup) fullPayloadString else {
          val directRecipientPublicKey = recipientPublicKey ?: run {
            synchronized(lock) {
              upsertLocalStatusLocked(chatId, messageId, "error")
              emitChangeLocked("messageStatusChanged", chatId, messageId)
            }
            return@Thread
          }
          try {
            chatEngineEncryptHybridMessage(directRecipientPublicKey, fullPayloadString, myPublicKeyPem ?: "")
          } catch (e: Throwable) {
            synchronized(lock) {
              upsertLocalStatusLocked(chatId, messageId, "error")
              appendJournalLocked(
                "native-send-message-error",
                mapOf("chatId" to chatId, "messageId" to messageId, "reason" to "encrypt_failed", "error" to (e.message ?: "encrypt_failed")),
              )
              emitChangeLocked("messageStatusChanged", chatId, messageId)
            }
            return@Thread
          }
        }

        val pushPreview = text.trim().let { trimmed ->
          if (trimmed.isNotEmpty()) {
            if (trimmed.length <= 160) trimmed else trimmed.take(159) + "…"
          } else {
            when (type) {
              "image" -> "Photo"
              "video" -> "Video"
              "voice" -> "Voice message"
              "music" -> "Audio"
              "file" -> "File"
              "location" -> "Location"
              "contact" -> "Contact"
              "gif" -> "GIF"
              else -> ""
            }
          }
        }

        val wirePayload = linkedMapOf<String, Any?>(
          "id" to messageId,
          "fromId" to userId,
          "encryptedContent" to encryptedContent,
          "timestamp" to timestampMs,
          "type" to type,
          "pushPreview" to pushPreview,
          "mediaUrl" to null,
          "fileName" to null,
          "latitude" to null,
          "longitude" to null,
        )

        synchronized(lock) {
          optimisticMessage["encryptedContent"] = encryptedContent
          optimisticRow["message"] = optimisticMessage
          upsertLiveMessageRowLocked(chatId, messageId, optimisticRow)
          pendingOutboundDraftsByMessageId[messageId] = LinkedHashMap(effectivePayload)

          val client = phoenixClient
          if (client == null) {
            upsertLocalStatusLocked(chatId, messageId, "pending")
            queueOutboundDraftLocked(chatId, messageId, effectivePayload, "no_native_socket")
            emitChangeLocked("messageStatusChanged", chatId, messageId)
            ensureNativeTransportAsync("send_no_socket")
            return@Thread
          }
          if (!nativeJoinedChatIds.contains(chatId)) {
            joinNativeChatTopicIfNeededLocked(chatId)
            upsertLocalStatusLocked(chatId, messageId, "pending")
            queueOutboundDraftLocked(chatId, messageId, effectivePayload, "chat_not_joined")
            emitChangeLocked("messageStatusChanged", chatId, messageId)
            ensureNativeTransportAsync("send_chat_not_joined")
            return@Thread
          }

          val ref = client.push(chatTopic(chatId), "message", wirePayload)
          nativePendingMessagePushRefs[ref] = chatId to messageId
          
          Handler(Looper.getMainLooper()).postDelayed({
            synchronized(lock) {
              val pending = nativePendingMessagePushRefs.remove(ref)
              if (pending != null) {
                appendJournalLocked("native-send-timeout", mapOf("chatId" to pending.first, "messageId" to pending.second, "ref" to ref))
                upsertLocalStatusLocked(pending.first, pending.second, "error")
                emitChangeLocked("messageStatusChanged", pending.first, pending.second)
              }
            }
          }, 15000L)
          
          val totalSendMs = System.currentTimeMillis() - optimisticStartMs
          appendJournalLocked("native-send-message", mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref))
          Log.i("ChatEngine", "sendMessage pushed chatId=$chatId messageId=$messageId ref=$ref encryptMs=${System.currentTimeMillis() - encryptStartMs} totalMs=$totalSendMs")
          emitChangeLocked("messageStatusChanged", chatId, messageId)
        }
      }.start()

      mapOf(
        "accepted" to true, 
        "queued" to true, 
        "messageId" to messageId, 
        "state" to "sending"
      )
    }
  }

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
      
      Handler(Looper.getMainLooper()).postDelayed({
        synchronized(lock) {
          val pending = nativePendingMessagePushRefs.remove(ref)
          if (pending != null) {
            appendJournalLocked("native-send-timeout", mapOf("chatId" to pending.first, "messageId" to pending.second, "ref" to ref))
            upsertLocalStatusLocked(pending.first, pending.second, "error")
            emitChangeLocked("messageStatusChanged", pending.first, pending.second)
          }
        }
      }, 15000L)
      
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

  fun editMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val nextText = normalized(payload["text"])?.trim()
      ?: return mapOf("accepted" to false, "reason" to "invalid_payload")
    if (nextText.isEmpty()) return mapOf("accepted" to false, "reason" to "empty_text")

    return synchronized(lock) {
      val existingMessage = findMessagePayloadLocked(chatId, messageId)
        ?: return@synchronized mapOf("accepted" to false, "reason" to "message_not_found")
      val peerUserId = normalizedUpper(payload["peerUserId"] ?: payload["peer_user_id"]) ?: chatPeerUserIdsByChatId[chatId]
      val friendPublicKey = resolveFriendPublicKeyLocked(chatId, peerUserId)
        ?: return@synchronized mapOf("accepted" to false, "reason" to "missing_friend_key")

      val editedAt = System.currentTimeMillis()
      val fullPayload = linkedMapOf<String, Any?>(
        "text" to nextText,
        "isEdited" to true,
        "editedAt" to editedAt,
      )
      normalized(existingMessage["mediaUrl"])?.let { fullPayload["mediaUrl"] = it }
      normalized(existingMessage["fileName"])?.let { fullPayload["fileName"] = it }
      parseDoubleValue(existingMessage["duration"])?.let { fullPayload["duration"] = it }
      normalized(existingMessage["replyToId"])?.let { fullPayload["replyToId"] = it }
      ((existingMessage["metadata"] as? Map<*, *>) ?: emptyMap<Any?, Any?>()).let { metadata ->
        metadata["width"]?.let { fullPayload["width"] = it }
        metadata["height"]?.let { fullPayload["height"] = it }
        metadata["thumbnailBase64"]?.let { fullPayload["thumbnailBase64"] = it }
        metadata["isVideoNote"]?.let { fullPayload["isVideoNote"] = it }
        metadata["waveform"]?.let { fullPayload["waveform"] = it }
      }

      val payloadString = try {
        JSONObject(fullPayload).toString()
      } catch (_: Throwable) {
        return@synchronized mapOf("accepted" to false, "reason" to "payload_encode_failed")
      }
      val myPublicKeyPem = normalized(getConfigValueLocked("publicKeyPem") ?: getConfigValueLocked("publicKey"))
      val encryptedContent = try {
        chatEngineEncryptHybridMessage(friendPublicKey, payloadString, myPublicKeyPem)
      } catch (e: Throwable) {
        appendJournalLocked(
          "native-edit-message-error",
          mapOf("chatId" to chatId, "messageId" to messageId, "reason" to "encrypt_failed", "error" to (e.message ?: "encrypt_failed")),
        )
        return@synchronized mapOf("accepted" to false, "reason" to "encrypt_failed")
      }

      val client = phoenixClient
        ?: return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket")
      if (!nativeJoinedChatIds.contains(chatId)) {
        joinNativeChatTopicIfNeededLocked(chatId)
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined")
      }
      val ref = client.push(
        chatTopic(chatId),
        "edit-message",
        linkedMapOf<String, Any?>(
          "messageId" to messageId,
          "encryptedContent" to encryptedContent,
          "editedAt" to editedAt,
        ),
      )
      nativePendingEditPushRefs[ref] = chatId to messageId
      appendJournalLocked("native-send-edit-message", mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref))
      applyNativeChatMutationEventLocked(
        chatId,
        "message-edited",
        mapOf("messageId" to messageId, "encryptedContent" to encryptedContent, "editedAt" to editedAt),
      )
      emitChangeLocked("chatMessageEdited", chatId, messageId)
      mapOf("accepted" to true, "transport" to "native", "ref" to ref)
    }
  }

  fun deleteMessage(payload: Map<String, Any?>): Map<String, Any?> =
    sendDeleteMessage(payload)

  fun setChatMuted(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val muted = parseBooleanValue(payload["muted"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_muted")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      val userId = normalized(payload["userId"] ?: payload["user_id"] ?: getConfigValueLocked("userId"))
      if (apiBaseUrl.isNullOrBlank() || userId.isNullOrBlank()) {
        null
      } else {
        val token = authHeaderTokenLocked()
        appendJournalLocked(
          "native-chat-mute-request",
          mapOf("chatId" to chatId, "muted" to muted, "userId" to userId),
        )
        state["updatedAt"] = System.currentTimeMillis()
        Triple(apiBaseUrl, token, userId)
      }
    } ?: return mapOf("accepted" to false, "reason" to "missing_config", "chatId" to chatId)

    val body =
      JSONObject(mapOf("userId" to preflight.third, "muted" to muted)).toString().toRequestBody(
        "application/json".toMediaTypeOrNull(),
      )
    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/chat/$chatId/mute")
      .post(body)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }
    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          appendJournalLocked(
            "native-chat-mute-error",
            mapOf("chatId" to chatId, "muted" to muted, "error" to (e.message ?: "network_error")),
          )
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            if (res.isSuccessful) {
              appendJournalLocked(
                "native-chat-mute-ok",
                mapOf("chatId" to chatId, "muted" to muted, "status" to res.code),
              )
              emitChangeLocked("chatMuteChanged", chatId, null)
            } else {
              appendJournalLocked(
                "native-chat-mute-error",
                mapOf("chatId" to chatId, "muted" to muted, "status" to res.code),
              )
            }
          }
        }
      }
    })

    return mapOf("accepted" to true, "queued" to true, "chatId" to chatId, "muted" to muted)
  }

  fun clearChat(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        val token = authHeaderTokenLocked()

        historyRowsByChat.remove(chatId)
        historyLoadingChats.remove(chatId)
        liveMessageRowsByChat.remove(chatId)
        deletedMessageIdsByChat.remove(chatId)
        receiptIndex.remove(chatId)
        localStatusIndex.remove(chatId)
        pendingOutboundQueueByChat.remove(chatId)
        nativeTypingStateByChatId.remove(chatId)
        peerTypingUserIdsByChatId.remove(chatId)
        nativeRecordingStateByChatId.remove(chatId)
        pinnedMessagesByChatId.remove(chatId)
        pinnedFetchInFlightChatIds.remove(chatId)
        chatPeerUserIdsByChatId.remove(chatId)
        openChatChannels.remove(chatId)

        val draftIdsToRemove = pendingOutboundDraftsByMessageId
          .filterValues { draft ->
            normalized(draft["chatId"] ?: draft["chat_id"]) == chatId
          }
          .keys
          .toList()
        draftIdsToRemove.forEach { pendingOutboundDraftsByMessageId.remove(it) }

        if (nativeJoinedChatIds.remove(chatId)) {
          phoenixClient?.leave(chatTopic(chatId))
        }

        appendJournalLocked("native-chat-clear-local", mapOf("chatId" to chatId))
        state["updatedAt"] = System.currentTimeMillis()
        emitChangeLocked("chatRowsReloaded", chatId, null)
        emitChangeLocked("chatCleared", chatId, null)
        Pair(apiBaseUrl, token)
      }
    } ?: return mapOf("accepted" to false, "reason" to "missing_config", "chatId" to chatId)

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/chats/$chatId")
      .delete()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }
    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          appendJournalLocked(
            "native-chat-clear-error",
            mapOf("chatId" to chatId, "error" to (e.message ?: "network_error")),
          )
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            if (res.isSuccessful) {
              appendJournalLocked(
                "native-chat-clear-ok",
                mapOf("chatId" to chatId, "status" to res.code),
              )
            } else {
              appendJournalLocked(
                "native-chat-clear-error",
                mapOf("chatId" to chatId, "status" to res.code),
              )
            }
          }
        }
      }
    })

    return mapOf("accepted" to true, "queued" to true, "chatId" to chatId)
  }

  fun blockUser(payload: Map<String, Any?>): Map<String, Any?> {
    val blockedUserId =
      normalized(payload["blockedUserId"] ?: payload["blocked_user_id"] ?: payload["peerUserId"] ?: payload["peer_user_id"])
        ?: return mapOf("accepted" to false, "reason" to "invalid_user")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        val token = authHeaderTokenLocked()
        appendJournalLocked(
          "native-user-block-request",
          mapOf("blockedUserId" to blockedUserId),
        )
        state["updatedAt"] = System.currentTimeMillis()
        Pair(apiBaseUrl, token)
      }
    } ?: return mapOf("accepted" to false, "reason" to "missing_config")

    val body =
      JSONObject(mapOf("blocked_user_id" to blockedUserId)).toString().toRequestBody(
        "application/json".toMediaTypeOrNull(),
      )
    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/user/block")
      .post(body)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }
    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          appendJournalLocked(
            "native-user-block-error",
            mapOf("blockedUserId" to blockedUserId, "error" to (e.message ?: "network_error")),
          )
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            if (res.isSuccessful) {
              appendJournalLocked(
                "native-user-block-ok",
                mapOf("blockedUserId" to blockedUserId, "status" to res.code),
              )
              emitChangeLocked("userBlocked", null, null)
            } else {
              appendJournalLocked(
                "native-user-block-error",
                mapOf("blockedUserId" to blockedUserId, "status" to res.code),
              )
            }
          }
        }
      }
    })

    return mapOf("accepted" to true, "queued" to true, "blockedUserId" to blockedUserId)
  }

  // MARK: - Agent Config (Native HTTP)

  fun fetchAgentConfig(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("success" to false, "reason" to "invalid_chat")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/group/$chatId/agent")
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    return try {
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        val body = res.body?.string().orEmpty()
        if (!res.isSuccessful) {
          mapOf("success" to false, "status" to res.code, "reason" to "http_${res.code}")
        } else {
          val parsed = parseJsonToMap(body)
          mapOf("success" to true, "status" to res.code, "config" to parsed)
        }
      }
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
      )
    }
  }

  fun saveAgentConfig(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("success" to false, "reason" to "invalid_chat")
    val config = payload["config"] as? Map<*, *>
      ?: return mapOf("success" to false, "reason" to "invalid_config")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val hasPersistedId =
      normalized(config["id"])
        ?.trim()
        ?.isNotEmpty() == true
    val initialMethod = if (hasPersistedId) "PUT" else "POST"
    val bodyJson = JSONObject(config).toString().toRequestBody("application/json".toMediaTypeOrNull())

    fun execute(method: String): Pair<Int, Map<String, Any?>> {
      val requestBuilder = Request.Builder()
        .url("${preflight.first}/api/group/$chatId/agent")
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("ngrok-skip-browser-warning", "true")
      preflight.second?.takeIf { it.isNotBlank() }?.let {
        requestBuilder.header("Authorization", "Bearer $it")
      }
      when (method) {
        "PUT" -> requestBuilder.put(bodyJson)
        else -> requestBuilder.post(bodyJson)
      }
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        val responseBody = res.body?.string().orEmpty()
        return Pair(res.code, parseJsonToMap(responseBody))
      }
    }

    return try {
      val (initialStatus, initialPayload) = execute(initialMethod)
      if (initialMethod == "POST" && initialStatus == 409) {
        val (retryStatus, retryPayload) = execute("PUT")
        return mapOf(
          "success" to (retryStatus in 200..299),
          "status" to retryStatus,
          "payload" to retryPayload,
        )
      }

      mapOf(
        "success" to (initialStatus in 200..299),
        "status" to initialStatus,
        "payload" to initialPayload,
      )
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
      )
    }
  }

  fun deleteAgentConfig(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("success" to false, "reason" to "invalid_chat")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/group/$chatId/agent")
      .delete()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    return try {
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        mapOf("success" to res.isSuccessful, "status" to res.code)
      }
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
      )
    }
  }

  fun generateAgentPrompt(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("success" to false, "reason" to "invalid_chat")
    val input = normalized(payload["input"] ?: payload["description"] ?: payload["prompt"]).orEmpty().trim()
    if (input.isBlank()) {
      return mapOf("success" to false, "reason" to "empty_input")
    }

    val enabledTools =
      (payload["enabledTools"] as? List<*>
        ?: payload["enabled_tools"] as? List<*>)
        ?.mapNotNull { normalized(it)?.trim()?.takeIf { value -> value.isNotEmpty() } }
        ?: emptyList()

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val requestBody = JSONObject(
      mapOf(
        "input" to input,
        "enabled_tools" to enabledTools,
      ),
    ).toString().toRequestBody("application/json".toMediaTypeOrNull())

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/group/$chatId/agent/generate_prompt")
      .post(requestBody)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    return try {
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        val body = res.body?.string().orEmpty()
        val parsed = parseJsonToMap(body)
        mapOf(
          "success" to res.isSuccessful,
          "status" to res.code,
          "payload" to parsed,
        )
      }
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
      )
    }
  }

  fun getPinnedMessages(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]).orEmpty()
    val shouldRefresh = parseBooleanValue(payload["refresh"]) == true
    if (chatId.isBlank()) {
      return mapOf("chatId" to "", "loading" to false, "data" to emptyList<Map<String, Any?>>())
    }

    return synchronized(lock) {
      val hasCache = pinnedMessagesByChatId.containsKey(chatId)
      if (!hasCache) {
        pinnedMessagesByChatId[chatId] = mutableListOf()
      }
      if ((shouldRefresh || !hasCache) && !pinnedFetchInFlightChatIds.contains(chatId)) {
        fetchPinnedMessagesLocked(chatId, "on_demand")
      }
      mapOf(
        "chatId" to chatId,
        "loading" to pinnedFetchInFlightChatIds.contains(chatId),
        "data" to pinnedMessagesByChatId[chatId].orEmpty(),
      )
    }
  }

  fun pinMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val pinned = parseBooleanValue(payload["pinned"]) ?: true

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        applyPinnedUpdateLocked(
          chatId = chatId,
          messageId = messageId,
          pinned = pinned,
          payload = mapOf(
            "messageId" to messageId,
            "chatId" to chatId,
            "timestamp" to System.currentTimeMillis(),
          ),
          trigger = "local_pin_request",
          refreshRemote = false,
        )
        state["updatedAt"] = System.currentTimeMillis()
        emitChangeLocked("chatPinnedUpdated", chatId, messageId)
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("accepted" to false, "reason" to "missing_config", "chatId" to chatId)

    val body =
      JSONObject(mapOf("pinned" to pinned)).toString().toRequestBody(
        "application/json".toMediaTypeOrNull(),
      )
    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/chat/$chatId/messages/$messageId/pin")
      .post(body)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          appendJournalLocked(
            "native-pin-message-error",
            mapOf(
              "chatId" to chatId,
              "messageId" to messageId,
              "pinned" to pinned,
              "error" to (e.message ?: "network_error"),
            ),
          )
          fetchPinnedMessagesLocked(chatId, "pin_error_reconcile")
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            if (res.isSuccessful) {
              appendJournalLocked(
                "native-pin-message-ok",
                mapOf(
                  "chatId" to chatId,
                  "messageId" to messageId,
                  "pinned" to pinned,
                  "status" to res.code,
                ),
              )
            } else {
              appendJournalLocked(
                "native-pin-message-error",
                mapOf(
                  "chatId" to chatId,
                  "messageId" to messageId,
                  "pinned" to pinned,
                  "status" to res.code,
                ),
              )
            }
            fetchPinnedMessagesLocked(chatId, "pin_request_complete")
          }
        }
      }
    })

    return mapOf(
      "accepted" to true,
      "queued" to true,
      "chatId" to chatId,
      "messageId" to messageId,
      "pinned" to pinned,
    )
  }

  fun getChatProfileSummary(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]).orEmpty()
    if (chatId.isBlank()) {
      return mapOf(
        "chatId" to "",
        "historyLoaded" to false,
        "totalMessages" to 0,
        "mediaCount" to 0,
        "fileCount" to 0,
        "linkCount" to 0,
        "recentFiles" to emptyList<String>(),
      )
    }
    return synchronized(lock) {
      val rows = historyRowsByChat[chatId].orEmpty()
      var totalMessages = 0
      var mediaCount = 0
      var fileCount = 0
      var linkCount = 0
      val recentFiles = mutableListOf<String>()

      rows.forEach { row ->
        if (normalized(row["kind"]) != "message") return@forEach
        val message = row["message"] as? Map<*, *> ?: return@forEach
        totalMessages += 1

        val type = normalized(message["type"])?.lowercase() ?: "text"
        val text = normalized(message["text"]).orEmpty()
        val caption = normalized(message["caption"]).orEmpty()
        val mediaUrl = normalized(message["mediaUrl"]).orEmpty()
        val fileName = normalized(message["fileName"]).orEmpty()

        val isMediaType = setOf("image", "gif", "video", "voice", "music").contains(type)
        if (isMediaType) mediaCount += 1

        val isFileType = type == "file" || (!isMediaType && fileName.isNotBlank())
        if (isFileType) {
          fileCount += 1
          if (fileName.isNotBlank() && recentFiles.size < 3) {
            recentFiles.add(fileName)
          }
        }

        if (containsLinkCandidate(text) || containsLinkCandidate(caption) || containsLinkCandidate(mediaUrl)) {
          linkCount += 1
        }
      }

      mapOf(
        "chatId" to chatId,
        "historyLoaded" to historyRowsByChat.containsKey(chatId),
        "totalMessages" to totalMessages,
        "mediaCount" to mediaCount,
        "fileCount" to fileCount,
        "linkCount" to linkCount,
        "recentFiles" to recentFiles,
      )
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

  fun getLiveMessageRows(payload: Map<String, Any?>): Map<String, Map<String, Any?>> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return emptyMap()
    synchronized(lock) {
      return liveMessageRowsByChat[chatId]?.toMap() ?: emptyMap()
    }
  }

  fun isChatHistoryLoaded(payload: Map<String, Any?>): Boolean {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return false
    synchronized(lock) {
      return historyRowsByChat.containsKey(chatId)
    }
  }

  fun typingUserIds(chatId: String?): List<String> {
    val normalizedChatId = normalized(chatId) ?: return emptyList()
    synchronized(lock) {
      return peerTypingUserIdsByChatId[normalizedChatId]?.toList()?.sorted() ?: emptyList()
    }
  }

  fun isTyping(payload: Map<String, Any?>): Boolean {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return false
    synchronized(lock) {
      return peerTypingUserIdsByChatId[chatId]?.isNotEmpty() == true
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
      onlineUsers.forEach { userId -> lastSeenByUserId.remove(userId) }
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

  fun isJsEmergencyFallbackEnabled(): Boolean =
    synchronized(lock) {
      when (val raw = getConfigValueLocked("chatNativeJsFallbackEnabled")) {
        is Boolean -> raw
        is Number -> raw.toInt() != 0
        is String -> raw.trim().lowercase() in setOf("1", "true", "yes", "on")
        else -> false
      }
    }

  private fun extractPublicKeyValue(map: Map<String, Any?>): String? =
    normalized(map["publicKey"] ?: map["friendKey"] ?: map["friendPublicKey"] ?: map["public_key"])

  private fun cacheChatPeerInfoLocked(chatId: String, chat: JSONObject) {
    val friendId = normalizedUpper(chat.opt("friendId") ?: chat.opt("friend_id"))
    if (!friendId.isNullOrBlank()) {
      chatPeerUserIdsByChatId[chatId] = friendId
      val key = normalized(chat.opt("publicKey") ?: chat.opt("friendKey") ?: chat.opt("friendPublicKey") ?: chat.opt("public_key"))
      if (!key.isNullOrBlank()) {
        friendPublicKeysByUserId[friendId] = key
      }
    }
  }

  private fun resolveFriendPublicKeyLocked(chatId: String, peerUserIdHint: String?): String? {
    val peerId = (peerUserIdHint ?: chatPeerUserIdsByChatId[chatId])?.trim()?.uppercase() ?: return null
    friendPublicKeysByUserId[peerId]?.let { return it }
    val apiBaseUrl = apiBaseUrlLocked() ?: return null
    val token = authHeaderTokenLocked() ?: return null
    val request = Request.Builder()
      .url("$apiBaseUrl/api/user/$peerId")
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
      .header("Authorization", "Bearer $token")
      .build()
    val response = try {
      historyHttpClient.newCall(request).execute()
    } catch (_: Throwable) {
      return null
    }
    response.use { res ->
      if (!res.isSuccessful) return null
      val body = try { res.body?.string() } catch (_: Throwable) { null } ?: return null
      return try {
        val json = JSONObject(body)
        val map = linkedMapOf<String, Any?>()
        json.keys().forEach { key -> map[key] = json.opt(key) }
        val key = extractPublicKeyValue(map)
        if (!key.isNullOrBlank()) {
          friendPublicKeysByUserId[peerId] = key
          chatPeerUserIdsByChatId[chatId] = peerId
        }
        key
      } catch (_: Throwable) {
        null
      }
    }
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
    // Check TTL: clear cached key if it has expired to limit in-memory exposure.
    val now = System.currentTimeMillis()
    if (cachedDecryptKeyTimestampMs > 0 && (now - cachedDecryptKeyTimestampMs) >= keyTTLMs) {
      cachedDecryptPrivateKey = null
      cachedDecryptPrivateKeyPem = null
      cachedDecryptKeyTimestampMs = 0L
    }
    if (cachedDecryptPrivateKey != null && cachedDecryptPrivateKeyPem == pem) {
      cachedDecryptKeyTimestampMs = now
      return cachedDecryptPrivateKey
    }
    return try {
      val key = chatEngineLoadPrivateKeyFromPem(pem)
      cachedDecryptPrivateKeyPem = pem
      cachedDecryptPrivateKey = key
      cachedDecryptKeyTimestampMs = now
      key
    } catch (_: Throwable) {
      cachedDecryptPrivateKeyPem = pem
      cachedDecryptPrivateKey = null
      cachedDecryptKeyTimestampMs = 0L
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

  private fun parseBooleanValue(value: Any?): Boolean? =
    when (value) {
      is Boolean -> value
      is Number -> value.toInt() != 0
      is String -> {
        when (value.trim().lowercase()) {
          "1", "true", "yes", "on" -> true
          "0", "false", "no", "off" -> false
          else -> null
        }
      }
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
      if (json.has("mediaKey")) out["mediaKey"] = json.opt("mediaKey")
      if (json.has("fileName")) out["fileName"] = json.opt("fileName")
      if (json.has("fileSize")) out["fileSize"] = json.opt("fileSize")
      if (json.has("latitude")) out["latitude"] = json.opt("latitude")
      if (json.has("longitude")) out["longitude"] = json.opt("longitude")
      if (json.has("duration")) out["duration"] = json.opt("duration")
      if (json.has("replyToId")) out["replyToId"] = json.opt("replyToId")
      if (json.has("contact")) out["contact"] = json.opt("contact")
      if (json.has("caption")) out["caption"] = json.opt("caption")
      if (json.has("viewOnce")) out["viewOnce"] = json.opt("viewOnce")
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

  private fun isLikelyHybridCiphertext(raw: String?): Boolean {
    val trimmed = raw?.trim() ?: return false
    if (!trimmed.startsWith("{")) return false
    return try {
      val json = JSONObject(trimmed)
      json.has("iv") && json.has("c") && json.has("k")
    } catch (_: Throwable) {
      false
    }
  }

  private fun parseJsonToMap(raw: String): Map<String, Any?> {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return emptyMap()
    return try {
      jsonObjectToMap(JSONObject(trimmed))
    } catch (_: Throwable) {
      emptyMap()
    }
  }

  private fun jsonObjectToMap(json: JSONObject): Map<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    val iterator = json.keys()
    while (iterator.hasNext()) {
      val key = iterator.next()
      out[key] = jsonValueToKotlin(json.opt(key))
    }
    return out
  }

  private fun jsonArrayToList(array: JSONArray): List<Any?> {
    val out = mutableListOf<Any?>()
    for (index in 0 until array.length()) {
      out.add(jsonValueToKotlin(array.opt(index)))
    }
    return out
  }

  private fun jsonValueToKotlin(value: Any?): Any? {
    return when (value) {
      null, JSONObject.NULL -> null
      is JSONObject -> jsonObjectToMap(value)
      is JSONArray -> jsonArrayToList(value)
      else -> value
    }
  }

  private fun containsLinkCandidate(value: String?): Boolean {
    val normalizedValue = value?.trim()?.lowercase().orEmpty()
    if (normalizedValue.isBlank()) return false
    return normalizedValue.contains("http://")
      || normalizedValue.contains("https://")
      || normalizedValue.contains("www.")
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

  private fun setLiveMessageUploadProgressLocked(chatId: String, messageId: String, progress: Float) {
    val row = liveMessageRowsByChat[chatId]?.get(messageId) ?: return
    val nextRow = LinkedHashMap(row)
    val msg = (nextRow["message"] as? Map<*, *>)?.let { LinkedHashMap(it) } ?: return
    msg["uploadProgress"] = progress
    nextRow["message"] = msg
    liveMessageRowsByChat[chatId]?.put(messageId, nextRow)
    emitChangeLocked("chatMessageChanged", chatId, messageId)
  }

  private fun markLiveMessageDeletedLocked(chatId: String, messageId: String) {
    liveMessageRowsByChat[chatId]?.let { perChat ->
      perChat.remove(messageId)
      if (perChat.isEmpty()) liveMessageRowsByChat.remove(chatId)
    }
    deletedMessageIdsByChat.getOrPut(chatId) { linkedSetOf() }.add(messageId)
  }

  private fun findMessagePayloadLocked(chatId: String, messageId: String): Map<String, Any?>? {
    liveMessageRowsByChat[chatId]?.get(messageId)?.get("message")?.let { message ->
      @Suppress("UNCHECKED_CAST")
      return message as? Map<String, Any?>
    }
    val historyRows = historyRowsByChat[chatId] ?: return null
    for (row in historyRows) {
      if (normalized(row["kind"]) != "message") continue
      val message = row["message"] as? Map<*, *> ?: continue
      if (normalized(message["id"]) == messageId) {
        @Suppress("UNCHECKED_CAST")
        return message as? Map<String, Any?>
      }
    }
    return null
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
    val localMediaUrl =
      normalized(decryptedFields["localMediaUrl"] ?: decryptedFields["local_media_url"])
    val fileName = normalized(decryptedFields["fileName"])
    val fileSize = parseLongValue(decryptedFields["fileSize"])
    val latitude = parseDoubleValue(decryptedFields["latitude"])
    val longitude = parseDoubleValue(decryptedFields["longitude"])
    val duration = parseDoubleValue(decryptedFields["duration"])
    val replyToId = normalized(decryptedFields["replyToId"])
    val caption = normalized(decryptedFields["caption"])
    val waveform = parseWaveformArray(decryptedFields["waveform"])
    val isEdited = forceEdited || ((decryptedFields["isEdited"] as? Boolean) == true)
    val editedAt = forceEditedAt ?: decryptedFields["editedAt"]

    val metadata = linkedMapOf<String, Any?>()
    waveform?.let { metadata["waveform"] = it }
    if (decryptedFields["width"] != null) metadata["width"] = decryptedFields["width"]
    if (decryptedFields["height"] != null) metadata["height"] = decryptedFields["height"]
    if (decryptedFields["thumbnailBase64"] != null) metadata["thumbnailBase64"] = decryptedFields["thumbnailBase64"]
    if (decryptedFields["isVideoNote"] != null) metadata["isVideoNote"] = decryptedFields["isVideoNote"]
    if (fileSize != null) metadata["fileSize"] = fileSize
    if (latitude != null) metadata["latitude"] = latitude
    if (longitude != null) metadata["longitude"] = longitude
    if (decryptedFields["viewOnce"] != null) metadata["viewOnce"] = decryptedFields["viewOnce"]
    if (decryptedFields["contact"] != null) metadata["contact"] = decryptedFields["contact"]
    if (caption != null) metadata["caption"] = caption
    if (decryptedFields["mediaKey"] != null) metadata["mediaKey"] = decryptedFields["mediaKey"]
    if (!localMediaUrl.isNullOrBlank()) metadata["localMediaUrl"] = localMediaUrl

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
      "localMediaUrl" to localMediaUrl,
      "fileName" to fileName,
      "duration" to duration,
      "replyToId" to replyToId,
      "caption" to caption,
      "contact" to decryptedFields["contact"],
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
    val rawMediaUrl = normalized(payload["mediaUrl"] ?: payload["media_url"])
    val rawFileName = normalized(payload["fileName"] ?: payload["file_name"])
    val derivedFileName =
      rawMediaUrl
        ?.substringBefore('?')
        ?.substringAfterLast('/')
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
    val encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)

    // Detect agent messages by fromId or explicit flag
    val isAgentMessage = (payload["isAgentMessage"] as? Boolean == true)
      || (normalized(fromId)?.lowercase() == AGENT_USER_ID)
      || (rawMediaUrl?.lowercase()?.contains("/uploads/agent-docs/") == true)
      || (rawMediaUrl?.lowercase()?.contains("/api/agent/document/") == true)
    val plainContent = normalized(payload["plainContent"] ?: payload["plain_content"])
    val agentName = normalized(payload["agentName"] ?: payload["agent_name"])

    val hadEncryptedContent = !encryptedContent.isNullOrBlank()
    val decryptedText = if (isAgentMessage && !plainContent.isNullOrBlank()) {
      // Agent messages use plainContent instead of encryption
      plainContent
    } else if (hadEncryptedContent) {
      if (!encryptedLooksHybrid) {
        encryptedContent!!
      } else {
        decryptPrivateKeyLocked()?.let { chatEngineDecryptHybridMessage(it, encryptedContent!!, isMe) }.orEmpty()
      }
    } else {
      ""
    }
    val decryptionFailed = !isAgentMessage && hadEncryptedContent && encryptedLooksHybrid && decryptedText.isEmpty()
    val decryptedFields = LinkedHashMap<String, Any?>(parseDecryptedMessagePayload(decryptedText))
    if (!rawMediaUrl.isNullOrBlank() && normalized(decryptedFields["mediaUrl"]).isNullOrBlank()) {
      decryptedFields["mediaUrl"] = rawMediaUrl
    }
    val fileNameForRow = rawFileName ?: if (type.equals("file", ignoreCase = true)) derivedFileName else null
    if (!fileNameForRow.isNullOrBlank() && normalized(decryptedFields["fileName"]).isNullOrBlank()) {
      decryptedFields["fileName"] = fileNameForRow
    }
    var row = buildLiveRowPayloadLocked(
      chatId = chatId,
      messageId = messageId,
      fromId = fromId,
      type = type,
      timestampMs = timestampMs,
      encryptedContent = encryptedContent,
      decryptedFields = decryptedFields,
    )
    // Inject agent-specific fields into the message payload for the UI layer
    if (isAgentMessage) {
      val message = ((row["message"] as? MutableMap<String, Any?>) ?: mutableMapOf())
      message["isAgentMessage"] = true
      message["isMe"] = false
      if (!agentName.isNullOrBlank()) message["agentName"] = agentName
      if (!plainContent.isNullOrBlank()) {
        message["plainContent"] = plainContent
        message["text"] = plainContent
      }
      (row as? MutableMap<String, Any?>)?.put("message", message)
    }
    // Signal decryption failure to the UI layer so it can show an appropriate indicator
    // instead of a blank bubble.
    if (decryptionFailed) {
      val message = (row["message"] as? MutableMap<String, Any?>) ?: mutableMapOf()
      message["decryptionFailed"] = true
      (row as? MutableMap<String, Any?>)?.put("message", message)
    }
    if ((type.equals("voice", ignoreCase = true) || type.equals("music", ignoreCase = true)) && isMe) {
      val existingMessage = findMessagePayloadLocked(chatId, messageId)
      val localPlaybackUrl = extractLocalPlaybackMediaUrlFromMessage(existingMessage)
      if (!localPlaybackUrl.isNullOrBlank()) {
        Log.d(
          "ChatEngine",
          "preserve local voice url on incoming echo chatId=$chatId messageId=$messageId local=${localPlaybackUrl.take(120)}",
        )
        row = mergeLocalPlaybackMediaUrlIntoRow(row, localPlaybackUrl)
      }
    }
    upsertLiveMessageRowLocked(chatId, messageId, row)
    appendJournalLocked("native-message-row-upsert", mapOf("chatId" to chatId, "messageId" to messageId, "type" to type))
    state["updatedAt"] = System.currentTimeMillis()
    return messageId
  }

  private fun joinNativeChatTopicIfNeededLocked(chatId: String) {
    if (chatId.isBlank()) return
    loadChatHistoryIfNeededLocked(chatId)
    val client = phoenixClient ?: run {
      ensureNativeTransportAsync("join_chat_no_socket")
      return
    }
    if ((state["connected"] as? Boolean) != true) {
      ensureNativeTransportAsync("join_chat_not_connected")
      return
    }
    if (nativeJoinedChatIds.contains(chatId)) return
    if (nativeChatJoinRefsByRef.values.contains(chatId)) return
    val ref = client.join(chatTopic(chatId), emptyMap())
    nativeChatJoinRefsByRef[ref] = chatId
    appendJournalLocked("native-chat-join-start", mapOf("chatId" to chatId, "ref" to ref))
  }

  private fun queueOutboundDraftLocked(
    chatId: String,
    messageId: String,
    payload: Map<String, Any?>,
    reason: String,
  ) {
    pendingOutboundDraftsByMessageId[messageId] = LinkedHashMap(payload)
    val ids = pendingOutboundQueueByChat.getOrPut(chatId) { mutableListOf() }
    if (ids.contains(messageId)) return
    ids.add(messageId)
    appendJournalLocked("native-outgoing-queued", mapOf("chatId" to chatId, "messageId" to messageId, "reason" to reason))
    emitChangeLocked("outgoingMessageQueued", chatId, messageId)
  }

  private fun removeQueuedOutboundDraftLocked(chatId: String, messageId: String, dropDraft: Boolean) {
    pendingOutboundQueueByChat[chatId]?.let { ids ->
      ids.removeAll { it == messageId }
      if (ids.isEmpty()) pendingOutboundQueueByChat.remove(chatId)
    }
    if (dropDraft) pendingOutboundDraftsByMessageId.remove(messageId)
  }

  private fun scheduleReplayQueuedOutboundLocked(chatId: String, trigger: String) {
    val ids = pendingOutboundQueueByChat[chatId]?.toList().orEmpty()
    if (ids.isEmpty()) return
    val inFlight = nativePendingMessagePushRefs.values.toSet()
    val drafts = ids.mapNotNull { messageId ->
      if (inFlight.contains(chatId to messageId)) return@mapNotNull null
      pendingOutboundDraftsByMessageId[messageId]
    }
    if (drafts.isEmpty()) return
    appendJournalLocked("native-outgoing-replay-scheduled", mapOf("chatId" to chatId, "count" to drafts.size, "trigger" to trigger))
    Thread {
      drafts.forEach { draft ->
        try {
          sendMessage(draft)
        } catch (_: Throwable) {
        }
      }
    }.start()
  }

  private fun chatTopic(chatId: String): String = "chat:$chatId"

  private data class LocalMediaUploadResult(
    val remoteUrl: String,
    val fileName: String?,
    val fileSize: Long?,
  )

  private sealed class LocalMediaUploadOutcome {
    data class Success(val value: LocalMediaUploadResult) : LocalMediaUploadOutcome()
    data class Failure(val reason: String) : LocalMediaUploadOutcome()
  }

  private data class LocalMediaSource(
    val body: RequestBody,
    val fileName: String,
    val fileSize: Long?,
  )

  private fun isLocalMediaUri(uri: String): Boolean =
    uri.startsWith("file://") || uri.startsWith("/") || uri.startsWith("content://")

  private fun extractLocalPlaybackMediaUrlFromMessage(message: Map<*, *>?): String? {
    if (message == null) return null
    val metadata = message["metadata"] as? Map<*, *>
    val candidates = listOf(
      message["localMediaUrl"],
      message["local_media_url"],
      metadata?.get("localMediaUrl"),
      metadata?.get("local_media_url"),
      message["mediaUrl"],
      message["media_url"],
      metadata?.get("mediaUrl"),
      metadata?.get("media_url"),
      message["uri"],
      metadata?.get("uri"),
      message["audioUrl"],
      message["audio_url"],
      metadata?.get("audioUrl"),
      metadata?.get("audio_url"),
    )
    for (raw in candidates) {
      val value = normalized(raw) ?: continue
      if (isLocalMediaUri(value)) return value
    }
    return null
  }

  private fun mergeLocalPlaybackMediaUrlIntoRow(
    row: Map<String, Any?>,
    localUrl: String,
  ): Map<String, Any?> {
    val mutableRow = LinkedHashMap(row)
    val messageRaw = mutableRow["message"] as? Map<*, *> ?: return mutableRow
    val mutableMessage = linkedMapOf<String, Any?>()
    messageRaw.forEach { (k, v) -> if (k != null) mutableMessage[k.toString()] = v }
    mutableMessage["localMediaUrl"] = localUrl
    val metadataRaw = mutableMessage["metadata"] as? Map<*, *>
    val mutableMetadata = linkedMapOf<String, Any?>()
    metadataRaw?.forEach { (k, v) -> if (k != null) mutableMetadata[k.toString()] = v }
    mutableMetadata["localMediaUrl"] = localUrl
    mutableMessage["metadata"] = mutableMetadata
    mutableRow["message"] = mutableMessage
    return mutableRow
  }

  private fun uploadCategoryForMessageType(messageType: String): String =
    when (messageType) {
      "image", "gif" -> "image"
      "voice", "music" -> "audio"
      "video" -> "video"
      else -> "file"
    }

  private fun resolveUploadUrl(apiBaseUrl: String): String? {
    val trimmed = apiBaseUrl.trim().trimEnd('/')
    if (trimmed.isBlank()) return null
    val serverBase = if (trimmed.endsWith("/api", ignoreCase = true)) {
      trimmed.dropLast(4).trimEnd('/')
    } else {
      trimmed
    }
    return if (serverBase.isBlank()) null else "$serverBase/api/media/upload"
  }

  private fun inferMimeType(fileName: String, fallbackType: String): String {
    val ext = fileName.substringAfterLast('.', "").lowercase()
    if (ext.isNotBlank()) {
      return when (ext) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "heic" -> "image/heic"
        "m4a" -> "audio/mp4"
        "mp3" -> "audio/mpeg"
        "wav" -> "audio/wav"
        "aac" -> "audio/aac"
        "mp4" -> "video/mp4"
        "mov" -> "video/quicktime"
        else -> "application/octet-stream"
      }
    }
    return when (fallbackType) {
      "image", "gif" -> "image/jpeg"
      "voice", "music" -> "audio/mp4"
      "video" -> "video/mp4"
      else -> "application/octet-stream"
    }
  }

  private fun displayNameForContentUri(uri: Uri): String? {
    val ctx = appContextRef ?: return null
    return try {
      ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
      }
    } catch (_: Throwable) {
      null
    }
  }

  private fun fileSizeForContentUri(uri: Uri): Long? {
    val ctx = appContextRef ?: return null
    return try {
      ctx.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        val index = cursor.getColumnIndex(OpenableColumns.SIZE)
        if (index >= 0 && cursor.moveToFirst()) cursor.getLong(index) else null
      }
    } catch (_: Throwable) {
      null
    }
  }

  private fun resolveLocalMediaSource(
    localUri: String,
    fileNameHint: String?,
    messageType: String,
  ): LocalMediaSource? {
    val ctx = appContextRef ?: return null
    val parsed = try { Uri.parse(localUri) } catch (_: Throwable) { null }
    if (parsed != null && parsed.scheme.equals("content", ignoreCase = true)) {
      val input = try { ctx.contentResolver.openInputStream(parsed) } catch (_: Throwable) { null } ?: return null
      input.use { stream ->
        val bytes = try { stream.readBytes() } catch (_: Throwable) { return null }
        val resolvedName = fileNameHint
          ?: displayNameForContentUri(parsed)
          ?: "upload_${System.currentTimeMillis()}"
        val resolvedMime = ctx.contentResolver.getType(parsed)
          ?: inferMimeType(resolvedName, messageType)
        val body = bytes.toRequestBody(resolvedMime.toMediaTypeOrNull())
        val size = fileSizeForContentUri(parsed) ?: bytes.size.toLong()
        return LocalMediaSource(body = body, fileName = resolvedName, fileSize = size)
      }
    }

    val file = try {
      when {
        localUri.startsWith("file://") -> File(Uri.parse(localUri).path ?: "")
        localUri.startsWith("/") -> File(localUri)
        else -> File(localUri)
      }
    } catch (_: Throwable) {
      return null
    }
    if (!file.exists() || !file.isFile) return null
    val resolvedName = fileNameHint
      ?: file.name.takeIf { it.isNotBlank() }
      ?: "upload_${System.currentTimeMillis()}"
    val resolvedMime = inferMimeType(resolvedName, messageType)
    val body = file.asRequestBody(resolvedMime.toMediaTypeOrNull())
    return LocalMediaSource(body = body, fileName = resolvedName, fileSize = file.length())
  }

  private fun uploadLocalMediaLocked(
    localUri: String,
    messageType: String,
    fileNameHint: String?,
    userId: String,
    token: String,
    apiBaseUrl: String,
    onProgress: ((Float) -> Unit)? = null,
  ): LocalMediaUploadOutcome {
    val uploadUrl = resolveUploadUrl(apiBaseUrl) ?: return LocalMediaUploadOutcome.Failure("invalid_upload_url")
    val source = resolveLocalMediaSource(localUri, fileNameHint, messageType)
      ?: return LocalMediaUploadOutcome.Failure("media_file_missing")
    val multipart = MultipartBody.Builder()
      .setType(MultipartBody.FORM)
      .addFormDataPart("file", source.fileName, source.body)
      .addFormDataPart("user_id", userId)
      .addFormDataPart("type", uploadCategoryForMessageType(messageType))
      .build()
      
    val progressBody = object : RequestBody() {
      override fun contentType() = multipart.contentType()
      override fun contentLength() = multipart.contentLength()
      override fun writeTo(sink: okio.BufferedSink) {
        val countingSink = object : okio.ForwardingSink(sink) {
          private var bytesWritten = 0L
          private val totalLength = contentLength()
          private var lastEmitMs = 0L
          override fun write(source: okio.Buffer, byteCount: Long) {
            super.write(source, byteCount)
            bytesWritten += byteCount
            val now = System.currentTimeMillis()
            if (totalLength > 0 && now - lastEmitMs > 50) {
              lastEmitMs = now
              onProgress?.invoke(bytesWritten.toFloat() / totalLength.toFloat())
            }
          }
        }
        val bufferedSink = countingSink.buffer()
        multipart.writeTo(bufferedSink)
        bufferedSink.flush()
      }
    }

    val request = Request.Builder()
      .url(uploadUrl)
      .post(progressBody)
      .header("ngrok-skip-browser-warning", "true")
      .header("Authorization", "Bearer $token")
      .build()
    val response = try {
      historyHttpClient.newCall(request).execute()
    } catch (_: Throwable) {
      return LocalMediaUploadOutcome.Failure("upload_failed")
    }
    response.use { res ->
      if (!res.isSuccessful) return LocalMediaUploadOutcome.Failure("upload_failed")
      val body = try { res.body?.string() } catch (_: Throwable) { null } ?: return LocalMediaUploadOutcome.Failure("upload_failed")
      val remoteUrl = try {
        val json = JSONObject(body)
        normalized(json.opt("url") ?: json.opt("mediaUrl") ?: json.opt("media_url"))
      } catch (_: Throwable) {
        null
      } ?: return LocalMediaUploadOutcome.Failure("invalid_upload_response")
      return LocalMediaUploadOutcome.Success(
        LocalMediaUploadResult(
          remoteUrl = remoteUrl,
          fileName = source.fileName,
          fileSize = source.fileSize,
        ),
      )
    }
  }

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
      .url("$apiBaseUrl/api/chat/$chatId/messages")
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
      val messages = JSONArray(bodyString)
      val rows = buildHistoryRowsLocked(chatId, messages)
      historyRowsByChat[chatId] = rows.toMutableList()
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked(
        "native-chat-history-load-ok",
        mapOf("chatId" to chatId, "rows" to rows.size, "messages" to messages.length()),
      )
      scheduleReplayQueuedOutboundLocked(chatId, "history_loaded")
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
      val rawMediaUrl = normalized(raw.opt("mediaUrl") ?: raw.opt("media_url"))
      val rawFileName = normalized(raw.opt("fileName") ?: raw.opt("file_name"))
      val derivedFileName =
        rawMediaUrl
          ?.substringBefore('?')
          ?.substringAfterLast('/')
          ?.trim()
          ?.takeIf { it.isNotEmpty() }
      val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserIdLocked()
      val encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)
      val historyIsAgent = (raw.opt("isAgentMessage") as? Boolean == true)
        || (normalized(fromId)?.lowercase() == AGENT_USER_ID)
        || (rawMediaUrl?.lowercase()?.contains("/uploads/agent-docs/") == true)
        || (rawMediaUrl?.lowercase()?.contains("/api/agent/document/") == true)
      val agentPlainContent = normalized(raw.opt("plainContent") ?: raw.opt("plain_content"))
        ?: normalized(encryptedContent)

      val hadEncryptedContent = !encryptedContent.isNullOrBlank()
      var historyDecryptionFailed = false
      val decryptedFields = if (historyIsAgent) {
        if (!agentPlainContent.isNullOrBlank()) {
          mapOf("text" to agentPlainContent)
        } else {
          emptyMap()
        }
      } else if (hadEncryptedContent) {
        if (!encryptedLooksHybrid) {
          parseDecryptedMessagePayload(encryptedContent!!)
        } else {
          val privateKey = decryptPrivateKeyLocked()
          val decrypted = privateKey?.let { chatEngineDecryptHybridMessage(it, encryptedContent!!, isMe) }.orEmpty()
          if (decrypted.trim().isEmpty() && plaintextFallback.isNotBlank()) {
            historyDecryptionFailed = true
            mapOf("text" to plaintextFallback)
          } else if (decrypted.trim().isEmpty()) {
            historyDecryptionFailed = true
            emptyMap()
          } else {
            val parsed = parseDecryptedMessagePayload(decrypted)
            if (parsed.isEmpty() && plaintextFallback.isNotBlank()) {
              historyDecryptionFailed = true
              mapOf("text" to plaintextFallback)
            } else if (parsed.isEmpty()) {
              historyDecryptionFailed = true
              emptyMap()
            } else {
              parsed
            }
          }
        }
      } else if (plaintextFallback.isNotBlank()) {
        mapOf("text" to plaintextFallback)
      } else {
        emptyMap()
      }

      val enrichedFields = LinkedHashMap<String, Any?>(decryptedFields)
      if (!rawMediaUrl.isNullOrBlank() && normalized(enrichedFields["mediaUrl"]).isNullOrBlank()) {
        enrichedFields["mediaUrl"] = rawMediaUrl
      }
      val fileNameForRow = rawFileName ?: if (type.equals("file", ignoreCase = true)) derivedFileName else null
      if (!fileNameForRow.isNullOrBlank() && normalized(enrichedFields["fileName"]).isNullOrBlank()) {
        enrichedFields["fileName"] = fileNameForRow
      }

      val row = (buildLiveRowPayloadLocked(
        chatId = chatId,
        messageId = messageId,
        fromId = fromId,
        type = type,
        timestampMs = timestampMs,
        encryptedContent = encryptedContent,
        decryptedFields = enrichedFields,
        forceEdited = isEdited,
        forceEditedAt = editedAt,
      ).toMutableMap())
      val message = (row["message"] as? Map<String, Any?>)?.toMutableMap() ?: mutableMapOf()
      if (historyIsAgent) {
        message["isAgentMessage"] = true
        message["isMe"] = false
        val name = normalized(raw.opt("agentName") ?: raw.opt("agent_name"))
        if (!name.isNullOrBlank()) message["agentName"] = name
        if (!agentPlainContent.isNullOrBlank() && agentPlainContent.isNotBlank()) {
          message["plainContent"] = agentPlainContent
          message["text"] = agentPlainContent
        }
      }
      if (!serverStatus.isNullOrBlank()) message["status"] = serverStatus
      val reactionEmoji = normalized(raw.opt("reactionEmoji") ?: raw.opt("reaction_emoji"))
      if (!reactionEmoji.isNullOrBlank()) message["reactionEmoji"] = reactionEmoji
      if (!historyIsAgent && hadEncryptedContent && encryptedLooksHybrid && historyDecryptionFailed) {
        message["decryptionFailed"] = true
      }
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
      nativeTypingStateByChatId.clear()
      peerTypingUserIdsByChatId.clear()
      nativeRecordingStateByChatId.clear()
      pinnedMessagesByChatId.clear()
      pinnedFetchInFlightChatIds.clear()
      historyLoadingChats.clear()
      liveMessageRowsByChat.clear()
      deletedMessageIdsByChat.clear()
      openChatChannels.keys.forEach { joinNativeChatTopicIfNeededLocked(it) }
      emitChangeLocked("connectionStateChanged", null, null)
    }
  }

  private fun onNativeSocketClosed(code: Int, reason: String?) {
    synchronized(lock) {
      val inFlightMessages = nativePendingMessagePushRefs.values.toList()
      inFlightMessages.forEach { (chatId, messageId) ->
        upsertLocalStatusLocked(chatId, messageId, "pending")
        pendingOutboundDraftsByMessageId[messageId]?.let { draft ->
          queueOutboundDraftLocked(chatId, messageId, draft, "socket_closed")
        }
      }
      nativePresenceActive = false
      nativeUserJoinRef = null
      nativeChatJoinRefsByRef.clear()
      nativeJoinedChatIds.clear()
      nativePendingMessagePushRefs.clear()
      nativePendingEditPushRefs.clear()
      nativePendingDeletePushRefs.clear()
      nativeTypingStateByChatId.clear()
      peerTypingUserIdsByChatId.clear()
      nativeRecordingStateByChatId.clear()
      pinnedMessagesByChatId.clear()
      pinnedFetchInFlightChatIds.clear()
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
            scheduleReplayQueuedOutboundLocked(joinedChatId, "chat_joined")
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
          if (status == "ok") {
            removeQueuedOutboundDraftLocked(chatId, messageId, dropDraft = true)
          }
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
        if (event == "typing" || event == "stop-typing") {
          val isTypingEvent = event == "typing"
          val payloadUserId = normalizedUpper(payload["userId"] ?: payload["user_id"] ?: payload["id"])
          val myUserId = normalizedUpper(getConfigValueLocked("userId"))
          if (payloadUserId != null && payloadUserId != myUserId) {
            val typingUsers = peerTypingUserIdsByChatId.getOrPut(chatId) { linkedSetOf() }
            if (isTypingEvent) {
              typingUsers.add(payloadUserId)
            } else {
              typingUsers.remove(payloadUserId)
            }
            if (typingUsers.isEmpty()) {
              peerTypingUserIdsByChatId.remove(chatId)
            }
          } else if (!isTypingEvent) {
            peerTypingUserIdsByChatId.remove(chatId)
          }
          val isAnyTyping =
            peerTypingUserIdsByChatId[chatId]?.isNotEmpty() == true || (isTypingEvent && payloadUserId == null)
          emitChangeLocked("peerTyping", chatId, if (isAnyTyping) "true" else "false")
          return
        }
        if (event == "pinned-updated") {
          val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return
          val pinned = parseBooleanValue(payload["pinned"]) ?: true
          applyPinnedUpdateLocked(
            chatId = chatId,
            messageId = messageId,
            pinned = pinned,
            payload = payload,
            trigger = "socket_pinned_updated",
            refreshRemote = true,
          )
          emitChangeLocked("chatPinnedUpdated", chatId, messageId)
          return
        }
        if (event == "message") {
          val insertedMessageId = applyNativeIncomingMessageEventLocked(chatId, payload)
          if (!insertedMessageId.isNullOrBlank()) {
            val fromId = normalized(payload["fromId"] ?: payload["from_id"])
            val myUserId = normalizedUpper(getConfigValueLocked("userId"))
            val isMe = normalizedUpper(fromId) == myUserId
            if (!isMe) {
              sendDeliveryReceipt(mapOf("chatId" to chatId, "messageId" to insertedMessageId))
            }

            if (peerTypingUserIdsByChatId[chatId] != null) {
              peerTypingUserIdsByChatId.remove(chatId)
              emitChangeLocked("peerTyping", chatId, "false")
            }
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
        onlineUsers.forEach { userId -> lastSeenByUserId.remove(userId) }
        appendJournalLocked("native-presence-initial", mapOf("count" to onlineUsers.size))
        true
      }

      "friend-online" -> {
        val userId = normalizedUpper(payload["userId"] ?: payload["user_id"] ?: payload["id"]) ?: return false
        onlineUsers.add(userId)
        lastSeenByUserId.remove(userId)
        appendJournalLocked("native-presence-online", mapOf("userId" to userId))
        true
      }

      "friend-offline" -> {
        val userId = normalizedUpper(payload["userId"] ?: payload["user_id"] ?: payload["id"]) ?: return false
        onlineUsers.remove(userId)
        val lastSeen =
          parseLongValue(
            payload["lastSeenMs"] ?: payload["last_seen_ms"] ?: payload["lastSeen"] ?: payload["last_seen"],
          ) ?: System.currentTimeMillis()
        lastSeenByUserId[userId] = lastSeen
        appendJournalLocked("native-presence-offline", mapOf("userId" to userId, "lastSeenMs" to lastSeen))
        true
      }

      "presence_state" -> {
        onlineUsers.clear()
        payload.keys.mapNotNullTo(onlineUsers) { normalizedUpper(it) }
        onlineUsers.forEach { userId -> lastSeenByUserId.remove(userId) }
        appendJournalLocked("native-presence-state", mapOf("count" to onlineUsers.size))
        true
      }

      "presence_diff", "presence-diff" -> {
        val joins = (payload["joins"] as? Map<*, *>) ?: emptyMap<String, Any?>()
        val leaves = (payload["leaves"] as? Map<*, *>) ?: emptyMap<String, Any?>()
        joins.keys.forEach { key ->
          normalizedUpper(key)?.let {
            onlineUsers.add(it)
            lastSeenByUserId.remove(it)
          }
        }
        leaves.keys.forEach { key ->
          normalizedUpper(key)?.let {
            onlineUsers.remove(it)
            lastSeenByUserId[it] = System.currentTimeMillis()
          }
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
          if (!isLikelyHybridCiphertext(encryptedContent)) {
            parseDecryptedMessagePayload(encryptedContent)
          } else {
            val decrypted = decryptPrivateKeyLocked()?.let { chatEngineDecryptHybridMessage(it, encryptedContent, isMe) }.orEmpty()
            parseDecryptedMessagePayload(decrypted)
          }
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
        applyPinnedUpdateLocked(
          chatId = chatId,
          messageId = messageId,
          pinned = false,
          payload = emptyMap(),
          trigger = "message_deleted",
          refreshRemote = false,
        )
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

  private fun fetchPinnedMessagesLocked(chatId: String, trigger: String) {
    if (chatId.isBlank()) return
    if (pinnedFetchInFlightChatIds.contains(chatId)) return
    val apiBaseUrl = apiBaseUrlLocked() ?: return
    val token = authHeaderTokenLocked()

    pinnedFetchInFlightChatIds.add(chatId)
    appendJournalLocked(
      "native-pinned-load-start",
      mapOf("chatId" to chatId, "trigger" to trigger),
    )

    val requestBuilder = Request.Builder()
      .url("$apiBaseUrl/api/chat/$chatId/pinned_messages")
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    token?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          pinnedFetchInFlightChatIds.remove(chatId)
          appendJournalLocked(
            "native-pinned-load-error",
            mapOf(
              "chatId" to chatId,
              "trigger" to trigger,
              "error" to (e.message ?: "network_error"),
            ),
          )
          emitChangeLocked("chatPinnedUpdated", chatId, null)
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            pinnedFetchInFlightChatIds.remove(chatId)
            val body = res.body?.string().orEmpty()
            if (!res.isSuccessful) {
              appendJournalLocked(
                "native-pinned-load-error",
                mapOf(
                  "chatId" to chatId,
                  "trigger" to trigger,
                  "status" to res.code,
                ),
              )
              emitChangeLocked("chatPinnedUpdated", chatId, null)
              return@synchronized
            }

            val nextPins = parsePinnedEntriesFromBody(body, chatId)
            val previousPins = pinnedMessagesByChatId[chatId].orEmpty()
            val previousIds = previousPins.mapNotNull {
              normalized(it["messageId"] ?: it["message_id"])
            }.toSet()
            val nextIds = nextPins.mapNotNull {
              normalized(it["messageId"] ?: it["message_id"])
            }.toSet()
            previousIds.union(nextIds).forEach { messageId ->
              setMessagePinnedStateLocked(
                chatId = chatId,
                messageId = messageId,
                pinned = nextIds.contains(messageId),
              )
            }
            pinnedMessagesByChatId[chatId] = nextPins.toMutableList()
            state["updatedAt"] = System.currentTimeMillis()
            appendJournalLocked(
              "native-pinned-load-ok",
              mapOf(
                "chatId" to chatId,
                "trigger" to trigger,
                "count" to nextPins.size,
                "status" to res.code,
              ),
            )
            emitChangeLocked("chatPinnedUpdated", chatId, null)
          }
        }
      }
    })
  }

  private fun parsePinnedEntriesFromBody(body: String, chatId: String): List<Map<String, Any?>> {
    val parsed = parseJsonToMap(body)
    val data = parsed["data"] as? List<*> ?: return emptyList()
    return data.mapNotNull { raw ->
      val map =
        (raw as? Map<*, *>)?.entries?.associate { (key, value) -> key.toString() to value }
          ?: return@mapNotNull null
      normalizePinnedEntry(map, chatId, fallbackMessageId = null)
    }
  }

  private fun normalizePinnedEntry(
    raw: Map<String, Any?>,
    chatId: String,
    fallbackMessageId: String?,
  ): Map<String, Any?>? {
    val messageId = normalized(raw["messageId"] ?: raw["message_id"] ?: raw["id"] ?: fallbackMessageId)
      ?: return null
    val entry = linkedMapOf<String, Any?>(
      "messageId" to messageId,
      "chatId" to chatId,
      "pinnedAt" to (raw["pinnedAt"] ?: raw["pinned_at"] ?: System.currentTimeMillis()),
    )
    raw["timestamp"]?.let { entry["timestamp"] = it }
    normalized(raw["type"] ?: raw["messageType"] ?: raw["message_type"])?.let { entry["type"] = it }
    normalized(raw["mediaUrl"] ?: raw["media_url"])?.let { entry["mediaUrl"] = it }
    normalized(raw["fileName"] ?: raw["file_name"])?.let { entry["fileName"] = it }
    normalized(raw["text"] ?: raw["plainContent"] ?: raw["plain_content"])?.let { entry["text"] = it }
    return entry
  }

  private fun applyPinnedUpdateLocked(
    chatId: String,
    messageId: String,
    pinned: Boolean,
    payload: Map<String, Any?>,
    trigger: String,
    refreshRemote: Boolean,
  ) {
    setMessagePinnedStateLocked(chatId, messageId, pinned)

    val pins = pinnedMessagesByChatId.getOrPut(chatId) { mutableListOf() }
    pins.removeAll {
      normalized(it["messageId"] ?: it["message_id"]) == messageId
    }
    if (pinned) {
      val nextEntry =
        normalizePinnedEntry(payload, chatId, fallbackMessageId = messageId)
          ?: mapOf(
            "messageId" to messageId,
            "chatId" to chatId,
            "pinnedAt" to System.currentTimeMillis(),
          )
      pins.add(0, nextEntry)
    }
    state["updatedAt"] = System.currentTimeMillis()
    appendJournalLocked(
      "native-pinned-updated",
      mapOf(
        "chatId" to chatId,
        "messageId" to messageId,
        "pinned" to pinned,
        "trigger" to trigger,
      ),
    )
    if (refreshRemote) {
      fetchPinnedMessagesLocked(chatId, trigger)
    }
  }

  private fun setMessagePinnedStateLocked(chatId: String, messageId: String, pinned: Boolean) {
    liveMessageRowsByChat[chatId]?.let { perChat ->
      val row = perChat[messageId] ?: return@let
      val message = (row["message"] as? Map<*, *>)?.entries?.associate { (key, value) ->
        key.toString() to value
      }?.toMutableMap() ?: return@let
      message["isPinned"] = pinned
      message["pinned"] = pinned
      val updatedRow = row.toMutableMap()
      updatedRow["message"] = message
      perChat[messageId] = updatedRow
    }

    historyRowsByChat[chatId]?.let { rows ->
      var changed = false
      for (index in rows.indices) {
        val row = rows[index].toMutableMap()
        if (normalized(row["kind"]) != "message") continue
        val message =
          (row["message"] as? Map<*, *>)?.entries?.associate { (key, value) ->
            key.toString() to value
          }?.toMutableMap() ?: continue
        if (normalized(message["id"]) != messageId) continue
        message["isPinned"] = pinned
        message["pinned"] = pinned
        row["message"] = message
        rows[index] = row
        changed = true
      }
      if (changed) {
        historyRowsByChat[chatId] = rows
      }
    }
  }

  private fun statusSnapshotLocked(): Map<String, Any?> {
    val ctx = appContextRef
    val out = LinkedHashMap<String, Any?>(state)
    out["onlineUserCount"] = onlineUsers.size
    out["onlineUserIds"] = onlineUsers.toList().sorted()
    out["lastSeenUserCount"] = lastSeenByUserId.size
    out["boundSurfaceCount"] = surfaceBindings.size
    out["boundChatCount"] = surfaceBindings.values.mapNotNull { it.chatId }.toSet().size
    out["openChatChannelCount"] = openChatChannels.size
    out["openChatChannels"] = LinkedHashMap(openChatChannels)
    out["receiptCount"] = receiptIndex.values.sumOf { it.size }
    out["localStatusCount"] = localStatusIndex.values.sumOf { it.size }
    out["nativeJoinedChatCount"] = nativeJoinedChatIds.size
    out["outboundDraftCount"] = pendingOutboundDraftsByMessageId.size
    out["outboundQueuedCount"] = pendingOutboundQueueByChat.values.sumOf { it.size }
    out["typingChatCount"] = peerTypingUserIdsByChatId.size
    out["typingUserCount"] = peerTypingUserIdsByChatId.values.sumOf { it.size }
    out["pinnedChatCount"] = pinnedMessagesByChatId.size
    out["pinnedMessageCount"] = pinnedMessagesByChatId.values.sumOf { it.size }
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
      "payload" to sanitizeJournalPayload(payload),
    )
    ChatEngineStore.appendJournal(ctx, entry)
  }

  /// Truncate sensitive identifiers in journal payloads to prevent
  /// leaking full chat/message/user IDs in plaintext storage.
  private fun sanitizeJournalPayload(payload: Map<String, Any?>): Map<String, Any?> {
    val sensitiveKeys = setOf("chatId", "messageId", "userId", "peerUserId", "fromId")
    val out = payload.toMutableMap()
    for (key in sensitiveKeys) {
      val value = out[key] as? String
      if (value != null && value.length > 8) {
        out[key] = value.take(8) + "..."
      }
    }
    return out
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
