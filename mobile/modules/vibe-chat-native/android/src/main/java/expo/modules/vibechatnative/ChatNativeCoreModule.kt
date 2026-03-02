package expo.modules.vibechatnative

import android.util.Base64
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

private val oaepSpec = OAEPParameterSpec(
  "SHA-256",
  "MGF1",
  MGF1ParameterSpec.SHA256,
  PSource.PSpecified.DEFAULT,
)

private fun decodePem(pem: String): ByteArray {
  val sanitized = pem
    .replace(Regex("-----BEGIN [A-Z ]+-----"), "")
    .replace(Regex("-----END [A-Z ]+-----"), "")
    .replace(Regex("\\s+"), "")
  return Base64.decode(sanitized, Base64.DEFAULT)
}

private fun loadPrivateKeyFromPem(privateKeyPem: String): PrivateKey {
  val keyFactory = KeyFactory.getInstance("RSA")
  return keyFactory.generatePrivate(PKCS8EncodedKeySpec(decodePem(privateKeyPem)))
}

private fun loadPublicKeyFromPem(publicKeyPem: String): PublicKey {
  val keyFactory = KeyFactory.getInstance("RSA")
  return keyFactory.generatePublic(X509EncodedKeySpec(decodePem(publicKeyPem)))
}

private fun rsaDecryptOAEP(privateKey: PrivateKey, encrypted: ByteArray): ByteArray? {
  return try {
    val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
    cipher.init(Cipher.DECRYPT_MODE, privateKey, oaepSpec)
    cipher.doFinal(encrypted)
  } catch (_: Throwable) {
    null
  }
}

private fun rsaEncryptOAEP(publicKey: PublicKey, plain: ByteArray): ByteArray {
  val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
  cipher.init(Cipher.ENCRYPT_MODE, publicKey, oaepSpec)
  return cipher.doFinal(plain)
}

private fun decryptHybridMessage(
  privateKey: PrivateKey,
  ciphertext: String,
  isMyMessage: Boolean,
): String {
  val trimmed = ciphertext.trim()
  if (trimmed.isEmpty()) return ""
  if (!trimmed.startsWith("{")) return "[Decryption Failed - Format]"

  return try {
    val payload = JSONObject(trimmed)
    val ivB64 = payload.optString("iv", "")
    val cB64 = payload.optString("c", "")
    val kB64 = payload.optString("k", "")
    // Group messages are plain JSON (e.g. {"text":"hello"}) — return as-is without decryption.
    if (ivB64.isEmpty() || cB64.isEmpty()) {
      return trimmed
    }

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
      val decrypted = rsaDecryptOAEP(privateKey, encryptedKey)
      if (decrypted != null) {
        aesKey = decrypted
        break
      }
    }
    if (aesKey == null) {
      return "[Decryption Failed]"
    }

    val iv = Base64.decode(ivB64, Base64.DEFAULT)
    val encryptedWithTag = Base64.decode(cB64, Base64.DEFAULT)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(
      Cipher.DECRYPT_MODE,
      SecretKeySpec(aesKey, "AES"),
      GCMParameterSpec(128, iv),
    )
    val plaintextBytes = cipher.doFinal(encryptedWithTag)
    String(plaintextBytes, StandardCharsets.UTF_8)
  } catch (_: Throwable) {
    "[Decryption Failed]"
  }
}

private fun encryptHybridMessage(
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

  val recipientPublicKey = loadPublicKeyFromPem(recipientPublicKeyPem)
  val encryptedRecipientKey = rsaEncryptOAEP(recipientPublicKey, aesKey)

  var senderEncryptedKeyB64: String? = null
  if (!myPublicKeyPem.isNullOrBlank()) {
    try {
      val senderPublicKey = loadPublicKeyFromPem(myPublicKeyPem)
      val senderEncryptedKey = rsaEncryptOAEP(senderPublicKey, aesKey)
      senderEncryptedKeyB64 = Base64.encodeToString(senderEncryptedKey, Base64.NO_WRAP)
    } catch (_: Throwable) {
      // Keep payload valid even if sender-key branch fails.
    }
  }

  val payload = JSONObject()
  payload.put("v", 1)
  payload.put("iv", Base64.encodeToString(iv, Base64.NO_WRAP))
  payload.put("c", Base64.encodeToString(encryptedWithTag, Base64.NO_WRAP))
  payload.put("k", Base64.encodeToString(encryptedRecipientKey, Base64.NO_WRAP))
  if (senderEncryptedKeyB64 != null) {
    payload.put("s", senderEncryptedKeyB64)
  }
  return payload.toString()
}

class ChatNativeCoreModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ChatNativeCore")

    Function("isSupported") {
      true
    }

    Function("supportsCryptoPipeline") {
      true
    }

    AsyncFunction("decryptMessagesBatch") { input: Map<String, Any?> ->
      val privateKey = input["privateKey"] as? String
      if (privateKey.isNullOrBlank()) {
        return@AsyncFunction mapOf("messages" to emptyMap<String, String>())
      }
      val parsedPrivateKey = loadPrivateKeyFromPem(privateKey)

      val messages = LinkedHashMap<String, String>()
      val items = input["items"] as? List<*> ?: emptyList<Any?>()
      for (raw in items) {
        val item = raw as? Map<*, *> ?: continue
        val id = item["id"] as? String ?: continue
        val encryptedContent = item["encryptedContent"] as? String ?: continue
        val isFromMe = item["isFromMe"] as? Boolean ?: false
        val decrypted = decryptHybridMessage(parsedPrivateKey, encryptedContent, isFromMe)
        if (decrypted.isNotEmpty()) {
          messages[id] = decrypted
        }
      }

      mapOf("messages" to messages)
    }

    AsyncFunction("encryptMessage") { input: Map<String, Any?> ->
      val recipientPublicKey = input["recipientPublicKey"] as? String
        ?: throw IllegalArgumentException("recipientPublicKey is required")
      val message = input["message"] as? String ?: ""
      val myPublicKey = input["myPublicKey"] as? String
      encryptHybridMessage(recipientPublicKey, message, myPublicKey)
    }

    AsyncFunction("normalizeRowsBatch") { input: Map<String, Any?> ->
      mapOf(
        "rows" to (input["rows"] ?: emptyList<Any>()),
        "changed" to false,
      )
    }

    // MARK: PBKDF2 Key Derivation

    AsyncFunction("deriveKey") { input: Map<String, Any?> ->
      val passphrase = input["passphrase"] as? String
        ?: throw IllegalArgumentException("passphrase is required")
      val salt = input["salt"] as? String
        ?: throw IllegalArgumentException("salt is required")
      val iterations = (input["iterations"] as? Number)?.toInt() ?: 600_000
      val keyLength = (input["keyLength"] as? Number)?.toInt() ?: 32

      val factory = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
      val spec = javax.crypto.spec.PBEKeySpec(
        passphrase.toCharArray(),
        salt.toByteArray(StandardCharsets.UTF_8),
        iterations,
        keyLength * 8,
      )
      val key = factory.generateSecret(spec)
      Base64.encodeToString(key.encoded, Base64.NO_WRAP)
    }

    // MARK: File-Level AES-256-GCM Encryption

    AsyncFunction("encryptFileData") { input: Map<String, Any?> ->
      val dataBase64 = input["data"] as? String
        ?: throw IllegalArgumentException("data is required")
      val fileData = Base64.decode(dataBase64, Base64.DEFAULT)

      val secureRandom = SecureRandom()
      val aesKey = ByteArray(32).also { secureRandom.nextBytes(it) }
      val iv = ByteArray(12).also { secureRandom.nextBytes(it) }

      val cipher = Cipher.getInstance("AES/GCM/NoPadding")
      cipher.init(
        Cipher.ENCRYPT_MODE,
        SecretKeySpec(aesKey, "AES"),
        GCMParameterSpec(128, iv),
      )
      val encryptedWithTag = cipher.doFinal(fileData)

      // Format: IV (12) + ciphertext + tag (appended by Java AES/GCM)
      val combined = ByteArray(12 + encryptedWithTag.size)
      System.arraycopy(iv, 0, combined, 0, 12)
      System.arraycopy(encryptedWithTag, 0, combined, 12, encryptedWithTag.size)

      mapOf(
        "encryptedBase64" to Base64.encodeToString(combined, Base64.NO_WRAP),
        "keyBase64" to Base64.encodeToString(aesKey, Base64.NO_WRAP),
      )
    }

    AsyncFunction("decryptFileData") { input: Map<String, Any?> ->
      val encryptedBase64 = input["encryptedBase64"] as? String
        ?: throw IllegalArgumentException("encryptedBase64 is required")
      val keyBase64 = input["keyBase64"] as? String
        ?: throw IllegalArgumentException("keyBase64 is required")

      val combined = Base64.decode(encryptedBase64, Base64.DEFAULT)
      val aesKey = Base64.decode(keyBase64, Base64.DEFAULT)

      val iv = combined.copyOfRange(0, 12)
      val encryptedWithTag = combined.copyOfRange(12, combined.size)

      val cipher = Cipher.getInstance("AES/GCM/NoPadding")
      cipher.init(
        Cipher.DECRYPT_MODE,
        SecretKeySpec(aesKey, "AES"),
        GCMParameterSpec(128, iv),
      )
      val plaintext = cipher.doFinal(encryptedWithTag)
      Base64.encodeToString(plaintext, Base64.NO_WRAP)
    }
  }
}
