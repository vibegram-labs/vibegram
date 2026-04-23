package com.mohammadshayani.vibe.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.util.Base64
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.progressindicator.CircularProgressIndicator
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import com.mohammadshayani.vibe.network.fallbackApiBaseUrl
import com.mohammadshayani.vibe.network.resolveApiBaseUrl
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.session.AppSessionConfig
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.interfaces.RSAPrivateCrtKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.RSAPublicKeySpec
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

class AuthActivity : AppCompatActivity() {
  enum class Mode(val wireValue: String) {
    SIGN_IN("sign_in"),
    SIGN_UP("sign_up");

    val titleText: String
      get() =
        when (this) {
          SIGN_IN -> "Sign In"
          SIGN_UP -> "Create Account"
        }

    val fieldHint: String
      get() =
        when (this) {
          SIGN_IN -> "Secret Key"
          SIGN_UP -> "Username"
        }

    val buttonTitle: String
      get() =
        when (this) {
          SIGN_IN -> "Continue"
          SIGN_UP -> "Create Account"
        }

    companion object {
      fun from(value: String?): Mode {
        return entries.firstOrNull { it.wireValue == value } ?: SIGN_IN
      }
    }
  }

  private var dialog: BottomSheetDialog? = null

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    val isDark = isNightMode(applicationContext)
    WindowCompat.setDecorFitsSystemWindows(window, false)
    window.statusBarColor = Color.TRANSPARENT
    window.navigationBarColor = if (isDark) Color.BLACK else Color.WHITE
    WindowInsetsControllerCompat(window, window.decorView).apply {
      isAppearanceLightStatusBars = !isDark
      isAppearanceLightNavigationBars = !isDark
    }

    val root = FrameLayout(this).apply {
      setBackgroundColor(if (isDark) Color.rgb(8, 13, 22) else Color.rgb(241, 246, 255))
    }
    root.addView(
      WelcomeBackdropView(this),
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      )
    )
    setContentView(root)

    root.post {
      dialog =
        AuthSheetPresenter.show(
          activity = this,
          mode = Mode.from(intent.getStringExtra(EXTRA_MODE)),
          onAuthenticated = { launchHome() },
          onDismiss = { finish() },
        )
    }
  }

  override fun onDestroy() {
    dialog?.setOnDismissListener(null)
    dialog?.dismiss()
    dialog = null
    super.onDestroy()
  }

  private fun launchHome() {
    startActivity(
      Intent(this, ChatHomeActivity::class.java).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
      }
    )
    finish()
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()

  companion object {
    private const val EXTRA_MODE = "auth_mode"

    fun intent(context: Context, mode: Mode = Mode.SIGN_IN): Intent {
      return Intent(context, AuthActivity::class.java).putExtra(EXTRA_MODE, mode.wireValue)
    }
  }
}

internal object AuthSheetPresenter {
  fun show(
    activity: AppCompatActivity,
    mode: AuthActivity.Mode,
    onAuthenticated: (() -> Unit)? = null,
    onDismiss: (() -> Unit)? = null,
  ): BottomSheetDialog {
    val palette = AuthSheetPalette.resolve(activity)
    val content =
      ScrollView(activity).apply {
        isFillViewport = true
      }
    val stack =
      LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(activity, 24f), dp(activity, 24f), dp(activity, 24f), dp(activity, 28f))
      }
    content.addView(
      stack,
      ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
      ),
    )

    val titleView =
      TextView(activity).apply {
        text = mode.titleText
        textSize = 28f
        setTextColor(palette.primaryTextColor)
        typeface = android.graphics.Typeface.create("sans-serif-black", android.graphics.Typeface.NORMAL)
      }
    stack.addView(titleView)

    val subtitleView =
      TextView(activity).apply {
        text =
          if (mode == AuthActivity.Mode.SIGN_IN) {
            "Enter your secret key to unlock the identity you already trust."
          } else {
            "Choose a username and we will generate a private secret key for you."
          }
        textSize = 15f
        setTextColor(palette.secondaryTextColor)
        setLineSpacing(0f, 1.12f)
        setPadding(0, dp(activity, 8f), 0, 0)
      }
    stack.addView(subtitleView)

    val radius = dp(activity, 22f).toFloat()
    val inputLayout =
      TextInputLayout(activity).apply {
        hint = mode.fieldHint
        boxBackgroundMode = TextInputLayout.BOX_BACKGROUND_FILLED
        setBoxBackgroundColor(palette.fieldBackgroundColor)
        setBoxCornerRadii(radius, radius, radius, radius)
        setBoxStrokeColorStateList(ColorStateList.valueOf(palette.fieldBorderColor))
        defaultHintTextColor = ColorStateList.valueOf(palette.fieldPlaceholderColor)
        setHintTextColor(ColorStateList.valueOf(palette.fieldPlaceholderColor))
        setPadding(0, dp(activity, 20f), 0, 0)
      }
    val inputField =
      TextInputEditText(inputLayout.context).apply {
        setTextColor(palette.primaryTextColor)
        setHintTextColor(palette.fieldPlaceholderColor)
        isSingleLine = true
        imeOptions = EditorInfo.IME_ACTION_DONE
        inputType =
          if (mode == AuthActivity.Mode.SIGN_IN) {
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
          } else {
            InputType.TYPE_CLASS_TEXT
          }
      }
    inputLayout.addView(
      inputField,
      ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
      ),
    )
    stack.addView(inputLayout)

    val statusView =
      TextView(activity).apply {
        visibility = View.GONE
        setTextColor(palette.secondaryTextColor)
        textSize = 14f
        setPadding(0, dp(activity, 12f), 0, 0)
      }
    stack.addView(statusView)

    val progressView =
      CircularProgressIndicator(activity).apply {
        visibility = View.GONE
        isIndeterminate = true
        setIndicatorColor(palette.primaryButtonTextColor)
        trackColor = palette.progressTrackColor
      }
    stack.addView(
      progressView,
      LinearLayout.LayoutParams(dp(activity, 32f), dp(activity, 32f)).apply {
        topMargin = dp(activity, 14f)
        gravity = Gravity.CENTER_HORIZONTAL
      },
    )

    val actionButton =
      MaterialButton(activity).apply {
        text = mode.buttonTitle
        isAllCaps = false
        setTextColor(palette.primaryButtonTextColor)
        textSize = 16f
        cornerRadius = dp(activity, 27f)
        strokeWidth = dp(activity, 1f)
        strokeColor = ColorStateList.valueOf(palette.primaryButtonBorderColor)
        backgroundTintList = ColorStateList.valueOf(palette.primaryButtonBackgroundColor)
        insetTop = 0
        insetBottom = 0
        minimumHeight = dp(activity, 54f)
      }
    stack.addView(
      actionButton,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(activity, 20f)
      },
    )

    inputField.setOnEditorActionListener { _, actionId, _ ->
      if (actionId == EditorInfo.IME_ACTION_DONE) {
        actionButton.performClick()
        true
      } else {
        false
      }
    }

    val bottomSheetDialog = BottomSheetDialog(activity)
    var shouldNotifyDismiss = true
    var behavior: BottomSheetBehavior<View>? = null

    bottomSheetDialog.setContentView(content)
    bottomSheetDialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
    bottomSheetDialog.setOnDismissListener {
      if (shouldNotifyDismiss) {
        onDismiss?.invoke()
      }
    }

    fun setLoading(loading: Boolean, status: String?) {
      bottomSheetDialog.setCancelable(!loading)
      behavior?.isDraggable = !loading
      inputField.isEnabled = !loading
      actionButton.isEnabled = !loading
      progressView.visibility = if (loading) View.VISIBLE else View.GONE
      statusView.visibility = if (status.isNullOrBlank()) View.GONE else View.VISIBLE
      statusView.text = status
    }

    actionButton.setOnClickListener {
      if (mode == AuthActivity.Mode.SIGN_UP) {
        val username = NativeAuthCrypto.normalizeUsername(inputField.text?.toString())
        if (!NativeAuthCrypto.isValidUsername(username)) {
          inputLayout.error = "Use 3 to 30 letters, numbers, or underscores."
          return@setOnClickListener
        }
        inputLayout.error = null
        setLoading(true, "Generating key")
        Thread {
          runCatching {
            NativeAuthService.signUp(activity.applicationContext, username)
          }.onSuccess { result ->
            activity.runOnUiThread {
              AppSessionConfig.store(activity.applicationContext, result.config)
              shouldNotifyDismiss = false
              bottomSheetDialog.dismiss()
              showRecoveryDialog(activity, result.recoverySecret) {
                onAuthenticated?.invoke()
              }
            }
          }.onFailure { error ->
            activity.runOnUiThread {
              setLoading(false, null)
              MaterialAlertDialogBuilder(activity)
                .setTitle("Create Account Failed")
                .setMessage(error.localizedMessage ?: "Unknown error")
                .setPositiveButton("OK", null)
                .show()
            }
          }
        }.start()
      } else {
        val secret = NativeAuthCrypto.normalizeSecret(inputField.text?.toString())
        if (secret.isBlank()) {
          inputLayout.error = "Enter the Secret Key."
          return@setOnClickListener
        }
        inputLayout.error = null
        setLoading(true, "Unlocking")
        Thread {
          runCatching {
            NativeAuthService.signIn(activity.applicationContext, secret)
          }.onSuccess { result ->
            activity.runOnUiThread {
              AppSessionConfig.store(activity.applicationContext, result.config)
              shouldNotifyDismiss = false
              bottomSheetDialog.dismiss()
              onAuthenticated?.invoke()
            }
          }.onFailure { error ->
            activity.runOnUiThread {
              setLoading(false, null)
              MaterialAlertDialogBuilder(activity)
                .setTitle("Sign In Failed")
                .setMessage(error.localizedMessage ?: "Unknown error")
                .setPositiveButton("OK", null)
                .show()
            }
          }
        }.start()
      }
    }

    bottomSheetDialog.show()
    bottomSheetDialog.findViewById<View>(com.google.android.material.R.id.design_bottom_sheet)?.let { sheet ->
      behavior = BottomSheetBehavior.from(sheet)
      behavior?.skipCollapsed = true
      behavior?.state = BottomSheetBehavior.STATE_EXPANDED
      sheet.background =
        GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadii =
            floatArrayOf(
              dp(activity, 34f).toFloat(),
              dp(activity, 34f).toFloat(),
              dp(activity, 34f).toFloat(),
              dp(activity, 34f).toFloat(),
              0f,
              0f,
              0f,
              0f,
            )
          colors = intArrayOf(palette.sheetTopColor, palette.sheetBottomColor)
          setStroke(dp(activity, 1f), palette.sheetBorderColor)
        }
    }

    return bottomSheetDialog
  }

  private fun showRecoveryDialog(
    activity: AppCompatActivity,
    secret: String,
    onContinue: () -> Unit,
  ) {
    MaterialAlertDialogBuilder(activity)
      .setTitle("Secret Key")
      .setMessage(secret)
      .setPositiveButton("Copy & Continue") { _, _ ->
        val clipboard =
          activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Secret Key", secret))
        onContinue()
      }
      .setNegativeButton("Continue") { _, _ ->
        onContinue()
      }
      .setCancelable(false)
      .show()
  }

  private fun dp(context: Context, value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, context.resources.displayMetrics).toInt()
}

private data class AuthSheetPalette(
  val sheetTopColor: Int,
  val sheetBottomColor: Int,
  val sheetBorderColor: Int,
  val primaryTextColor: Int,
  val secondaryTextColor: Int,
  val fieldBackgroundColor: Int,
  val fieldBorderColor: Int,
  val fieldPlaceholderColor: Int,
  val primaryButtonBackgroundColor: Int,
  val primaryButtonTextColor: Int,
  val primaryButtonBorderColor: Int,
  val progressTrackColor: Int,
) {
  companion object {
    fun resolve(context: Context): AuthSheetPalette {
      val isDark = isNightMode(context)
      return if (isDark) {
        AuthSheetPalette(
          sheetTopColor = Color.argb(244, 19, 26, 39),
          sheetBottomColor = Color.argb(244, 11, 16, 26),
          sheetBorderColor = Color.argb(48, 255, 255, 255),
          primaryTextColor = Color.WHITE,
          secondaryTextColor = Color.argb(208, 213, 224, 236),
          fieldBackgroundColor = Color.argb(18, 255, 255, 255),
          fieldBorderColor = Color.argb(36, 255, 255, 255),
          fieldPlaceholderColor = Color.argb(132, 255, 255, 255),
          primaryButtonBackgroundColor = Color.rgb(228, 237, 252),
          primaryButtonTextColor = Color.rgb(16, 20, 29),
          primaryButtonBorderColor = Color.argb(40, 255, 255, 255),
          progressTrackColor = Color.argb(32, 255, 255, 255),
        )
      } else {
        AuthSheetPalette(
          sheetTopColor = Color.argb(248, 255, 255, 255),
          sheetBottomColor = Color.argb(246, 241, 246, 255),
          sheetBorderColor = Color.argb(120, 255, 255, 255),
          primaryTextColor = Color.rgb(23, 29, 37),
          secondaryTextColor = Color.argb(196, 67, 78, 94),
          fieldBackgroundColor = Color.argb(220, 255, 255, 255),
          fieldBorderColor = Color.rgb(213, 224, 238),
          fieldPlaceholderColor = Color.argb(154, 79, 91, 107),
          primaryButtonBackgroundColor = Color.rgb(18, 24, 34),
          primaryButtonTextColor = Color.WHITE,
          primaryButtonBorderColor = Color.argb(28, 255, 255, 255),
          progressTrackColor = Color.argb(22, 18, 24, 34),
        )
      }
    }
  }
}

private data class NativeAuthResponse(
  val userId: String,
  val username: String,
  val secureId: String,
  val token: String,
  val tokenExpiresAt: String?,
  val encryptedPrivateKey: String?,
  val phoneNumber: String?,
)

private data class NativeAuthResult(
  val config: AppSessionConfig,
  val recoverySecret: String,
)

private data class NativeAuthKeyPair(
  val publicKeyPem: String,
  val privateKeyPem: String,
)

private object NativeAuthService {
  private val jsonMediaType = "application/json".toMediaType()
  private val client =
    OkHttpClient.Builder()
      .connectTimeout(15, TimeUnit.SECONDS)
      .readTimeout(20, TimeUnit.SECONDS)
      .writeTimeout(20, TimeUnit.SECONDS)
      .callTimeout(22, TimeUnit.SECONDS)
      .build()

  fun signUp(context: Context, username: String): NativeAuthResult {
    val apiBaseUrl = AppSessionConfig.current(context)?.apiBaseUrl ?: resolveApiBaseUrl(context) ?: fallbackApiBaseUrl
    val transportMode = AppSessionConfig.current(context)?.transportMode ?: PacketTransportMode.PACKET_MESH
    val recoverySecret = NativeAuthCrypto.generateRecoverySecret()
    val keyPair = NativeAuthCrypto.generateKeyPair()
    val derivedKey = NativeAuthCrypto.deriveKey(recoverySecret, username)
    val encryptedPrivateKey = NativeAuthCrypto.encryptPrivateKey(keyPair.privateKeyPem, derivedKey)
    val response =
      request(
        apiBaseUrl = apiBaseUrl,
        path = "register",
        body =
          JSONObject()
            .put("username", username)
            .put("password", recoverySecret)
            .put("deviceId", UUID.randomUUID().toString())
            .put("identityKey", "v2")
            .put("publicKey", keyPair.publicKeyPem)
            .put("encryptedPrivateKey", encryptedPrivateKey),
      )

    return NativeAuthResult(
      config =
        AppSessionConfig(
          apiBaseUrl = apiBaseUrl,
          socketUrl = deriveSocketUrl(apiBaseUrl),
          userId = response.userId,
          authToken = response.token,
          transportMode = transportMode,
          username = response.username,
          secureId = response.secureId,
          publicKeyPem = keyPair.publicKeyPem,
          privateKeyPem = keyPair.privateKeyPem,
          encryptedPrivateKey = encryptedPrivateKey,
          tokenExpiresAt = response.tokenExpiresAt,
          identityKey = "v2",
          phoneNumber = response.phoneNumber,
        ),
      recoverySecret = recoverySecret,
    )
  }

  fun signIn(context: Context, secret: String): NativeAuthResult {
    val apiBaseUrl = AppSessionConfig.current(context)?.apiBaseUrl ?: resolveApiBaseUrl(context) ?: fallbackApiBaseUrl
    val transportMode = AppSessionConfig.current(context)?.transportMode ?: PacketTransportMode.PACKET_MESH
    val response =
      request(
        apiBaseUrl = apiBaseUrl,
        path = "login",
        body =
          JSONObject()
            .put("credential", secret)
            .put("password", secret)
            .put("deviceId", UUID.randomUUID().toString()),
      )
    val encryptedPrivateKey =
      response.encryptedPrivateKey?.takeIf { it.isNotBlank() }
        ?: throw IllegalStateException("Key sync unavailable for this account.")
    val derivedKey = NativeAuthCrypto.deriveKey(secret, response.username)
    val privateKeyPem = NativeAuthCrypto.decryptPrivateKey(encryptedPrivateKey, derivedKey)
    val publicKeyPem = NativeAuthCrypto.derivePublicKeyPem(privateKeyPem)

    return NativeAuthResult(
      config =
        AppSessionConfig(
          apiBaseUrl = apiBaseUrl,
          socketUrl = deriveSocketUrl(apiBaseUrl),
          userId = response.userId,
          authToken = response.token,
          transportMode = transportMode,
          username = response.username,
          secureId = response.secureId,
          publicKeyPem = publicKeyPem,
          privateKeyPem = privateKeyPem,
          encryptedPrivateKey = encryptedPrivateKey,
          tokenExpiresAt = response.tokenExpiresAt,
          identityKey = "v2",
          phoneNumber = response.phoneNumber,
        ),
      recoverySecret = "",
    )
  }

  private fun request(apiBaseUrl: String, path: String, body: JSONObject): NativeAuthResponse {
    val base = apiBaseUrl.trim().trimEnd('/')
    val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
    val request =
      Request.Builder()
        .url("$pathBase/$path")
        .post(body.toString().toRequestBody(jsonMediaType))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .header("ngrok-skip-browser-warning", "true")
        .build()

    client.newCall(request).execute().use { response ->
      val rawBody = response.body?.string().orEmpty()
      if (!response.isSuccessful) {
        throw IllegalStateException(parseServerError(rawBody, response.code))
      }
      val json = JSONObject(rawBody)
      return NativeAuthResponse(
        userId = json.optString("userId"),
        username = json.optString("username"),
        secureId = json.optString("secureId"),
        token = json.optString("token"),
        tokenExpiresAt = json.optString("tokenExpiresAt").takeIf { it.isNotBlank() },
        encryptedPrivateKey = json.optString("encryptedPrivateKey").takeIf { it.isNotBlank() },
        phoneNumber = json.optString("phoneNumber").takeIf { it.isNotBlank() },
      )
    }
  }

  private fun parseServerError(rawBody: String, statusCode: Int): String {
    return runCatching {
      JSONObject(rawBody).optString("error").takeIf { it.isNotBlank() }
    }.getOrNull() ?: rawBody.ifBlank { "Request failed with status $statusCode." }
  }

  private fun deriveSocketUrl(apiBaseUrl: String): String {
    val trimmed = apiBaseUrl.trim().trimEnd('/')
    val withoutApi = if (trimmed.lowercase().endsWith("/api")) trimmed.dropLast(4) else trimmed
    return when {
      withoutApi.startsWith("https://") -> withoutApi.replaceFirst("https://", "wss://") + "/socket"
      withoutApi.startsWith("http://") -> withoutApi.replaceFirst("http://", "ws://") + "/socket"
      else -> "wss://api.vibegram.io/socket"
    }
  }
}

  private object NativeAuthCrypto {
  private val secureRandom = SecureRandom()
  private val rsaAlgorithmIdentifier =
    byteArrayOf(
      0x30.toByte(), 0x0d.toByte(),
      0x06.toByte(), 0x09.toByte(), 0x2a.toByte(), 0x86.toByte(), 0x48.toByte(), 0x86.toByte(),
      0xf7.toByte(), 0x0d.toByte(), 0x01.toByte(), 0x01.toByte(), 0x01.toByte(),
      0x05.toByte(), 0x00.toByte(),
    )

  fun normalizeUsername(value: String?): String {
    return value?.trim()?.lowercase().orEmpty()
  }

  fun normalizeSecret(value: String?): String {
    return value
      ?.trim()
      ?.uppercase()
      ?.filter { it in "0123456789ABCDEF-" }
      .orEmpty()
  }

  fun isValidUsername(username: String): Boolean {
    return username.length in 3..30 && username.matches(Regex("^[A-Za-z0-9_]+$"))
  }

  fun generateRecoverySecret(): String {
    val bytes = ByteArray(24)
    secureRandom.nextBytes(bytes)
    val hex = bytes.joinToString(separator = "") { "%02X".format(it.toInt() and 0xFF) }
    return hex.chunked(4).joinToString("-")
  }

  fun generateKeyPair(): NativeAuthKeyPair {
    val generator = KeyPairGenerator.getInstance("RSA")
    generator.initialize(2048, secureRandom)
    val keyPair = generator.generateKeyPair()
    return NativeAuthKeyPair(
      publicKeyPem = makePem("PUBLIC KEY", keyPair.public.encoded),
      privateKeyPem = makePem("PRIVATE KEY", keyPair.private.encoded),
    )
  }

  fun deriveKey(passphrase: String, salt: String): ByteArray {
    val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
    val spec =
      PBEKeySpec(
        passphrase.toCharArray(),
        normalizeUsername(salt).toByteArray(StandardCharsets.UTF_8),
        600_000,
        256,
      )
    return factory.generateSecret(spec).encoded
  }

  fun encryptPrivateKey(privateKeyPem: String, derivedKey: ByteArray): String {
    val keyData = decodePem(privateKeyPem)
    val iv = ByteArray(12).also { secureRandom.nextBytes(it) }
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(derivedKey, "AES"), GCMParameterSpec(128, iv))
    val encrypted = cipher.doFinal(keyData)
    val combined = ByteArray(iv.size + encrypted.size)
    System.arraycopy(iv, 0, combined, 0, iv.size)
    System.arraycopy(encrypted, 0, combined, iv.size, encrypted.size)
    return Base64.encodeToString(combined, Base64.NO_WRAP)
  }

  fun decryptPrivateKey(encryptedBase64: String, derivedKey: ByteArray): String {
    val combined = Base64.decode(encryptedBase64, Base64.DEFAULT)
    require(combined.size > 28) { "Encrypted key payload is invalid." }
    val iv = combined.copyOfRange(0, 12)
    val encrypted = combined.copyOfRange(12, combined.size)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(derivedKey, "AES"), GCMParameterSpec(128, iv))
    val decrypted = cipher.doFinal(encrypted)
    val asText = runCatching { String(decrypted, StandardCharsets.UTF_8) }.getOrNull()
    if (!asText.isNullOrBlank() && asText.contains("BEGIN")) {
      return asText
    }
    val label = if (containsRsaAlgorithmIdentifier(decrypted)) "PRIVATE KEY" else "RSA PRIVATE KEY"
    return makePem(label, decrypted)
  }

  fun derivePublicKeyPem(privateKeyPem: String): String {
    val privateKey = loadPrivateKeyFromPem(privateKeyPem)
    val privateCrt = privateKey as? RSAPrivateCrtKey
      ?: throw IllegalStateException("Unsupported private key format.")
    val keyFactory = KeyFactory.getInstance("RSA")
    val publicKey = keyFactory.generatePublic(RSAPublicKeySpec(privateCrt.modulus, privateCrt.publicExponent))
    return makePem("PUBLIC KEY", publicKey.encoded)
  }

  private fun loadPrivateKeyFromPem(privateKeyPem: String): PrivateKey {
    val keyFactory = KeyFactory.getInstance("RSA")
    val der = decodePem(privateKeyPem)
    return try {
      keyFactory.generatePrivate(PKCS8EncodedKeySpec(der))
    } catch (_: Throwable) {
      keyFactory.generatePrivate(PKCS8EncodedKeySpec(wrapPkcs1InPkcs8(der)))
    }
  }

  private fun decodePem(pem: String): ByteArray {
    val sanitized =
      pem
        .replace(Regex("-----BEGIN [A-Z ]+-----"), "")
        .replace(Regex("-----END [A-Z ]+-----"), "")
        .replace(Regex("\\\\n"), "\n")
        .replace(Regex("\\\\r"), "")
        .replace(Regex("\\s+"), "")
    return Base64.decode(sanitized, Base64.DEFAULT)
  }

  private fun makePem(label: String, data: ByteArray): String {
    val base64 = Base64.encodeToString(data, Base64.NO_WRAP)
    return buildString {
      append("-----BEGIN ").append(label).append("-----\n")
      base64.chunked(64).forEachIndexed { index, chunk ->
        append(chunk)
        if (index != base64.chunked(64).lastIndex) {
          append('\n')
        }
      }
      append("\n-----END ").append(label).append("-----")
    }
  }

  private fun containsRsaAlgorithmIdentifier(data: ByteArray): Boolean {
    if (data.size < rsaAlgorithmIdentifier.size) return false
    for (index in 0..data.size - rsaAlgorithmIdentifier.size) {
      var matches = true
      for (offset in rsaAlgorithmIdentifier.indices) {
        if (data[index + offset] != rsaAlgorithmIdentifier[offset]) {
          matches = false
          break
        }
      }
      if (matches) return true
    }
    return false
  }

  private fun wrapPkcs1InPkcs8(pkcs1: ByteArray): ByteArray {
    val version = byteArrayOf(0x02.toByte(), 0x01.toByte(), 0x00.toByte())
    val octetLength = derEncodeLength(pkcs1.size)
    val octet = byteArrayOf(0x04.toByte()) + octetLength + pkcs1
    val body = version + rsaAlgorithmIdentifier + octet
    return byteArrayOf(0x30.toByte()) + derEncodeLength(body.size) + body
  }

  private fun derEncodeLength(length: Int): ByteArray {
    if (length < 0x80) return byteArrayOf(length.toByte())
    val bytes = ArrayList<Byte>()
    var remaining = length
    while (remaining > 0) {
      bytes.add(0, (remaining and 0xFF).toByte())
      remaining = remaining shr 8
    }
    return byteArrayOf((0x80 or bytes.size).toByte()) + bytes.toByteArray()
  }
}
