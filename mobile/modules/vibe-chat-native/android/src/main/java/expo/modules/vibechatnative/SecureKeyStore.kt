package expo.modules.vibechatnative

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/// Thread-safe encrypted storage wrapper for sensitive values (private keys, auth tokens).
/// Uses AndroidKeyStore-backed MasterKey with AES256-GCM encryption.
internal object SecureKeyStore {
  private const val PREFS_NAME = "vibe_secure_keys"
  const val SENTINEL = "__SECURE__"

  val sensitiveKeys = setOf("privateKeyPem", "privateKey", "authToken", "token")

  @Volatile
  private var cachedPrefs: SharedPreferences? = null

  private fun getPrefs(context: Context): SharedPreferences {
    cachedPrefs?.let { return it }
    synchronized(this) {
      cachedPrefs?.let { return it }
      val masterKey = MasterKey.Builder(context.applicationContext)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()
      val prefs = EncryptedSharedPreferences.create(
        context.applicationContext,
        PREFS_NAME,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
      )
      cachedPrefs = prefs
      return prefs
    }
  }

  fun storeSecret(context: Context, key: String, value: String) {
    getPrefs(context).edit().putString(key, value).apply()
  }

  fun retrieveSecret(context: Context, key: String): String? {
    return getPrefs(context).getString(key, null)
  }

  fun deleteSecret(context: Context, key: String) {
    getPrefs(context).edit().remove(key).apply()
  }

  /// Migrate secrets from a plaintext config map into encrypted storage.
  /// Returns a sanitized copy with secrets replaced by sentinels.
  fun migrateAndSanitize(context: Context, config: Map<String, Any?>): Map<String, Any?> {
    val sanitized = config.toMutableMap()
    for (key in sensitiveKeys) {
      val value = config[key] as? String
      if (!value.isNullOrBlank() && value != SENTINEL) {
        storeSecret(context, key, value)
        sanitized[key] = SENTINEL
      }
    }
    return sanitized
  }

  /// Reassemble a config by replacing sentinels with values from secure storage.
  fun reassemble(context: Context, config: Map<String, Any?>): Map<String, Any?> {
    val assembled = config.toMutableMap()
    for (key in sensitiveKeys) {
      val stored = config[key] as? String
      if (stored == SENTINEL) {
        val secret = retrieveSecret(context, key)
        if (secret != null) {
          assembled[key] = secret
        }
      }
    }
    return assembled
  }
}
