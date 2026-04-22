package expo.modules.vibechatnative

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.inputmethod.EditorInfo
import android.widget.Toast
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import expo.modules.kotlin.AppContext
import expo.modules.vibechatnative.R
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

internal class ChatNativeInputBar(
  context: Context,
  private val appContext: AppContext? = null,
) : FrameLayout(context) {
  interface Listener {
    fun onTextChanged(text: String)
    fun onAttachmentPressed()
    fun onAttachmentImage(uri: String, caption: String?)
    fun onAttachmentFile(uri: String, name: String, size: Long?, mimeType: String?, caption: String?)
    fun onAttachmentLocation(latitude: Double, longitude: Double, caption: String?)
    fun onSendText(text: String, messageId: String)
    fun onSendTextWithAgentMention(text: String, agentText: String, messageId: String)
    fun onSendTextWithStandaloneAgentMention(
      text: String,
      agentText: String,
      agentUsername: String,
      messageId: String,
    )
    fun onRequestVibeAgentBuilder()
    fun onRecordingState(isRecording: Boolean, isLocked: Boolean)
    fun onRecordingVad(level: Float)
    fun onRecordingCanceled()
    fun onVoiceRecorded(uri: String, durationSeconds: Double, waveform: List<Float>)
  }

  var listener: Listener? = null

  private val rootColumn = LinearLayout(context)
  private val row = LinearLayout(context)
  private val attachmentButton = FrameLayout(context)
  private val attachmentIcon = ImageView(context)
  private val textSurface = FrameLayout(context)
  private val textSurfaceGlass = appContext?.let { LiquidGlassView(context, it) }
  private val textContainer = LinearLayout(context)
  private val input = EditText(context)
  private val mentionBanner = LinearLayout(context)
  private val mentionAccentBar = View(context)
  private val mentionNameLabel = TextView(context)
  private val mentionDescLabel = TextView(context)
  private val recordingOverlay = LinearLayout(context)
  private val recordingDot = View(context)
  private val recordingTimerLabel = TextView(context)
  private val recordingSlideChevron = TextView(context)
  private val recordingSlideLabel = TextView(context)
  private val lockHintPill = FrameLayout(context)
  private val lockHintArrow = TextView(context)
  private val lockHintIcon = ImageView(context)
  private val actionButton = FrameLayout(context)
  private val actionIcon = ImageView(context)

  private val uiHandler = Handler(Looper.getMainLooper())
  private val longPressTimeoutMs = min(200, ViewConfiguration.getLongPressTimeout())
  private val lockThresholdPx = dp(60)
  private val cancelThresholdPx = dp(100)
  private val minRecordSendDurationMs = 600L

  private var surfaceColor = Color.argb(246, 20, 24, 30)
  private var textColor = Color.WHITE
  private var hintColor = Color.argb(150, 255, 255, 255)
  private var passiveIconColor = Color.WHITE
  private var accentColor = Color.argb(255, 106, 79, 207)
  private var dangerColor = Color.argb(255, 255, 59, 48)
  private var lastActionRes = R.drawable.ic_mic
  private var currentAppearance = ChatListAppearance()
  private var attachmentMenu: ChatAttachmentMenuController? = null

  private var longPressArmed = false
  private var longPressStarted = false
  private var lockActivatedInGesture = false
  private var micTouchActive = false
  private var downRawX = 0f
  private var downRawY = 0f

  private var isRecording = false
  private var isLockedRecording = false
  private var recorder: MediaRecorder? = null
  private var recordingFile: File? = null
  private var recordingStartedAtMs = 0L
  private var vadTicker: Runnable? = null
  private val recordingAmplitudes = ArrayList<Int>(256)
  private var lockHintArrowAnimator: ObjectAnimator? = null
  private var slideHintChevronAnimator: ObjectAnimator? = null
  private var slideHintLabelAnimator: ObjectAnimator? = null
  private var lastTimerPulseSecond = -1
  private var vadVisualLevel = 0f
  private var readyBannerAction: ReadyBannerAction = ReadyBannerAction.None

  private data class ReadyCommandSuggestion(
    val command: String,
    val insertion: String,
    val description: String,
  )

  private sealed class ReadyBannerAction {
    object None : ReadyBannerAction()
    object Mention : ReadyBannerAction()
    data class Slash(val suggestion: ReadyCommandSuggestion) : ReadyBannerAction()
  }

  companion object {
    private val builderSlashSuggestions =
      listOf(
        ReadyCommandSuggestion("/newagent", "/newagent ", "Create a new agent"),
        ReadyCommandSuggestion("/agents", "/agents", "List your agents"),
        ReadyCommandSuggestion("/select", "/select ", "Select an existing draft"),
        ReadyCommandSuggestion("/prompt", "/prompt ", "Set the system prompt"),
        ReadyCommandSuggestion("/webhook", "/webhook ", "Set the callback URL"),
        ReadyCommandSuggestion("/publish", "/publish", "Publish the active agent"),
        ReadyCommandSuggestion("/secret", "/secret rotate", "Rotate the invoke secret"),
        ReadyCommandSuggestion("/help", "/help", "Show builder help"),
      )
  }

  private val longPressRunnable = Runnable {
    longPressArmed = false
    ensureMicrophonePermission { granted ->
      if (!granted || !micTouchActive) {
        listener?.onRecordingCanceled()
        return@ensureMicrophonePermission
      }
      if (startVoiceRecording()) {
        longPressStarted = true
        lockActivatedInGesture = false
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
      }
    }
  }

  init {
    clipChildren = false
    clipToPadding = false
    setPadding(dp(10), dp(6), dp(10), dp(8))
    setBackgroundColor(Color.TRANSPARENT)

    rootColumn.orientation = LinearLayout.VERTICAL
    rootColumn.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
    rootColumn.setBackgroundColor(Color.TRANSPARENT)
    addView(rootColumn)

    row.orientation = LinearLayout.HORIZONTAL
    row.gravity = Gravity.BOTTOM or Gravity.CENTER_VERTICAL
    row.clipChildren = false
    row.clipToPadding = false
    row.layoutParams = LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      LayoutParams.WRAP_CONTENT,
    )
    row.setBackgroundColor(Color.TRANSPARENT)
    rootColumn.addView(row)

    setupActionButton()
    setupAttachmentButton()
    setupTextSurface()
    setupLockHintPill()
    bindEvents()
    refreshVisualState()

    addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
      updateLockHintPosition()
    }
  }

  fun setPlaceholder(value: String) {
    input.hint = value
  }

  fun applyAppearance(appearance: ChatListAppearance, isDark: Boolean, backgroundReferenceColor: Int) {
    currentAppearance = appearance
    val textBase = if (isDark) Color.WHITE else Color.BLACK
    val accentBase = appearance.bubbleMeGradient.lastOrNull() ?: appearance.textColorMe
    surfaceColor = if (isDark) {
      Color.argb(128, 20, 24, 30)
    } else {
      Color.argb(168, 248, 251, 255)
    }
    textColor = if (isDark) Color.WHITE else Color.BLACK
    hintColor = withAlpha(textBase, 0.45f)
    passiveIconColor = withAlpha(textBase, 0.82f)
    accentColor = accentBase

    input.setTextColor(textColor)
    input.setHintTextColor(hintColor)
    recordingTimerLabel.setTextColor(withAlpha(textBase, 0.95f))
    recordingSlideLabel.setTextColor(withAlpha(textBase, 0.78f))
    recordingSlideChevron.setTextColor(withAlpha(textBase, 0.78f))
    lockHintArrow.setTextColor(withAlpha(textBase, 0.92f))
    lockHintIcon.setColorFilter(withAlpha(textBase, 0.92f))
    textSurfaceGlass?.setTint(if (isDark) "dark" else "light")
    textSurfaceGlass?.setCornerRadius(22.0)
    textSurfaceGlass?.setBlurIntensity(28.0)
    textSurfaceGlass?.setBlurReductionFactor(1.2)
    textSurfaceGlass?.setEffect("clear")
    textSurfaceGlass?.setTintColor(surfaceColor)
    textSurfaceGlass?.setBorderEnabled(false)
    textSurfaceGlass?.setShadowEnabled(false)
    mentionAccentBar.background = roundedDrawable(accentColor, dpF(1.5f))
    mentionNameLabel.setTextColor(withAlpha(textColor, 0.92f))
    mentionDescLabel.setTextColor(withAlpha(textColor, 0.72f))
    lockHintPill.background = roundedDrawable(withAlpha(surfaceColor, 0.78f), dpF(22f))
    updateSurfaces()
    refreshVisualState()
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    micTouchActive = false
    uiHandler.removeCallbacks(longPressRunnable)
    vadTicker?.let { uiHandler.removeCallbacks(it) }
    vadTicker = null
    stopRecordingHintAnimations()
    resetVadVisuals()
    recordingTimerLabel.animate().cancel()
    recordingTimerLabel.scaleX = 1f
    recordingTimerLabel.scaleY = 1f
    recordingTimerLabel.alpha = 1f
    recordingTimerLabel.translationY = 0f
    lockHintPill.animate().cancel()
    lockHintPill.visibility = View.GONE
    attachmentMenu?.dismiss(animated = false)
    attachmentMenu = null
    if (isRecording) {
      stopVoiceRecording(send = false)
    }
  }

  private fun setupAttachmentButton() {
    attachmentButton.layoutParams = FrameLayout.LayoutParams(dp(34), dp(34)).apply {
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
      leftMargin = dp(6)
    }
    attachmentButton.background = circleDrawable(Color.TRANSPARENT, Color.TRANSPARENT, 0f)
    attachmentButton.clipChildren = false
    attachmentButton.clipToPadding = false

    attachmentIcon.layoutParams = LayoutParams(dp(22), dp(22), Gravity.CENTER)
    attachmentIcon.setImageResource(R.drawable.ic_attach)
    attachmentIcon.scaleType = ImageView.ScaleType.CENTER_INSIDE
    attachmentButton.addView(attachmentIcon)
  }

  private fun setupTextSurface() {
    textSurface.layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
    textSurface.background = roundedDrawable(withAlpha(surfaceColor, 0.92f), dpF(22f))
    textSurface.clipChildren = false
    textSurface.clipToPadding = false
    textSurface.elevation = 0f
    row.addView(textSurface)

    textSurfaceGlass?.let { glass ->
      glass.layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
      glass.setCornerRadius(22.0)
      glass.setBlurIntensity(28.0)
      glass.setBlurReductionFactor(1.2)
      glass.setEffect("clear")
      glass.setTintColor(surfaceColor)
      glass.setBorderEnabled(false)
      glass.setShadowEnabled(false)
      glass.setInteractive(false)
      glass.setPressFeedbackEnabled(false)
      glass.elevation = 0f
      glass.alpha = 1.0f
      textSurface.addView(glass)
    }

    textContainer.orientation = LinearLayout.VERTICAL
    textContainer.layoutParams = FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
      gravity = Gravity.CENTER_VERTICAL
    }

    mentionBanner.orientation = LinearLayout.HORIZONTAL
    mentionBanner.gravity = Gravity.CENTER_VERTICAL
    mentionBanner.layoutParams = LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, dp(26)).apply {
      topMargin = dp(6)
      leftMargin = dp(46)
      rightMargin = dp(46)
    }
    mentionBanner.visibility = View.GONE

    mentionAccentBar.layoutParams = LinearLayout.LayoutParams(dp(3), dp(26)).apply {
      rightMargin = dp(8)
    }
    mentionAccentBar.background = roundedDrawable(accentColor, dpF(1.5f))
    mentionBanner.addView(mentionAccentBar)

    mentionNameLabel.layoutParams = LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
      rightMargin = dp(6)
    }
    mentionNameLabel.text = "@vibe"
    mentionNameLabel.textSize = 12f
    mentionNameLabel.setTypeface(null, Typeface.BOLD)
    mentionNameLabel.setTextColor(Color.WHITE)
    mentionBanner.addView(mentionNameLabel)

    mentionDescLabel.layoutParams = LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
    mentionDescLabel.text = "Ask AI"
    mentionDescLabel.textSize = 12f
    mentionDescLabel.setTextColor(Color.argb(180, 255, 255, 255))
    mentionBanner.addView(mentionDescLabel)
    mentionBanner.setOnClickListener { handleReadyBannerTap() }

    textContainer.addView(mentionBanner)

    input.layoutParams = LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
    input.setBackgroundColor(Color.TRANSPARENT)
    input.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    input.typeface = Typeface.DEFAULT
    input.maxLines = 4
    input.minLines = 1
    input.gravity = Gravity.CENTER_VERTICAL
    input.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
    input.imeOptions = EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_EXTRACT_UI
    input.setPadding(dp(46), dp(10), dp(46), dp(10))
    input.includeFontPadding = false
    textContainer.addView(input)

    textSurface.addView(textContainer)

    recordingOverlay.layoutParams = FrameLayout.LayoutParams(
      LayoutParams.MATCH_PARENT,
      LayoutParams.MATCH_PARENT,
    ).apply {
      gravity = Gravity.CENTER_VERTICAL
      leftMargin = dp(46)
      rightMargin = dp(46)
    }
    recordingOverlay.orientation = LinearLayout.HORIZONTAL
    recordingOverlay.gravity = Gravity.CENTER_VERTICAL
    recordingOverlay.visibility = View.GONE
    textSurface.addView(recordingOverlay)

    recordingDot.layoutParams = LinearLayout.LayoutParams(dp(8), dp(8)).apply {
      rightMargin = dp(8)
    }
    recordingDot.background = circleDrawable(dangerColor)
    recordingOverlay.addView(recordingDot)

    recordingTimerLabel.layoutParams = LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
    recordingTimerLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    recordingTimerLabel.typeface = Typeface.MONOSPACE
    recordingTimerLabel.text = "0:00.00"
    recordingTimerLabel.maxLines = 1
    recordingOverlay.addView(recordingTimerLabel)

    recordingSlideChevron.layoutParams = LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
      leftMargin = dp(10)
      rightMargin = dp(4)
    }
    recordingSlideChevron.text = "\u2039"
    recordingSlideChevron.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    recordingSlideChevron.maxLines = 1
    recordingOverlay.addView(recordingSlideChevron)

    recordingSlideLabel.layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
    recordingSlideLabel.text = "Slide to cancel"
    recordingSlideLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    recordingSlideLabel.ellipsize = TextUtils.TruncateAt.END
    recordingSlideLabel.maxLines = 1
    recordingOverlay.addView(recordingSlideLabel)

    textSurface.addView(attachmentButton)
    textSurface.addView(actionButton)
  }

  private fun setupActionButton() {
    actionButton.layoutParams = FrameLayout.LayoutParams(dp(34), dp(34)).apply {
      gravity = Gravity.END or Gravity.CENTER_VERTICAL
      rightMargin = dp(6)
    }
    actionButton.background = circleDrawable(Color.TRANSPARENT, Color.TRANSPARENT, 0f)

    actionIcon.layoutParams = LayoutParams(dp(20), dp(20), Gravity.CENTER)
    actionIcon.setImageResource(R.drawable.ic_mic)
    actionIcon.scaleType = ImageView.ScaleType.CENTER_INSIDE
    actionButton.addView(actionIcon)
  }

  private fun setupLockHintPill() {
    lockHintPill.layoutParams = LayoutParams(dp(44), dp(86))
    lockHintPill.visibility = View.GONE
    lockHintPill.alpha = 0f
    lockHintPill.translationY = dpF(8f)
    lockHintPill.background = roundedDrawable(withAlpha(surfaceColor, 0.78f), dpF(22f))
    lockHintPill.elevation = 0f

    lockHintArrow.layoutParams = LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
      gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
      topMargin = dp(14)
    }
    lockHintArrow.text = "\u2303"
    lockHintArrow.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    lockHintArrow.setTextColor(withAlpha(textColor, 0.92f))
    lockHintArrow.maxLines = 1
    lockHintPill.addView(lockHintArrow)

    lockHintIcon.layoutParams = LayoutParams(dp(16), dp(16), Gravity.CENTER_HORIZONTAL).apply {
      topMargin = dp(47)
    }
    lockHintIcon.setImageResource(android.R.drawable.ic_lock_lock)
    lockHintIcon.setColorFilter(withAlpha(textColor, 0.92f))
    lockHintPill.addView(lockHintIcon)

    addView(lockHintPill)
  }

  private fun updateLockHintPosition() {
    if (lockHintPill.width <= 0 || lockHintPill.height <= 0) return
    if (textSurface.width <= 0 || actionButton.width <= 0) return
    val centerX = textSurface.x + actionButton.x + (actionButton.width * 0.5f)
    val top = textSurface.y + actionButton.y
    lockHintPill.x = centerX - (lockHintPill.width * 0.5f)
    lockHintPill.y = top - lockHintPill.height - dpF(8f)
  }

  private fun showLockHint(visible: Boolean, animated: Boolean = true) {
    if (visible) {
      if (lockHintPill.visibility != View.VISIBLE) {
        lockHintPill.visibility = View.VISIBLE
      }
      updateLockHintPosition()
      if (!animated) {
        lockHintPill.alpha = 1f
        lockHintPill.translationY = 0f
        return
      }
      lockHintPill.animate().cancel()
      lockHintPill.alpha = max(lockHintPill.alpha, 0f)
      lockHintPill.animate()
        .alpha(1f)
        .translationY(0f)
        .setDuration(170L)
        .start()
      return
    }

    if (lockHintPill.visibility != View.VISIBLE && lockHintPill.alpha <= 0f) {
      lockHintPill.visibility = View.GONE
      return
    }
    lockHintPill.animate().cancel()
    if (!animated) {
      lockHintPill.alpha = 0f
      lockHintPill.translationY = dpF(8f)
      lockHintPill.visibility = View.GONE
      return
    }
    lockHintPill.animate()
      .alpha(0f)
      .translationY(dpF(8f))
      .setDuration(120L)
      .withEndAction { lockHintPill.visibility = View.GONE }
      .start()
  }

  private fun ensureMicrophonePermission(onReady: (Boolean) -> Unit) {
    val permission =
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        Manifest.permission.RECORD_AUDIO
      } else {
        null
      }
    if (permission == null || hasPermission(permission)) {
      onReady(true)
      return
    }
    launchWithResult<String, Boolean>(ActivityResultContracts.RequestPermission(), permission) { granted ->
      if (!granted) {
        toast("Microphone permission is required for voice messages")
      }
      onReady(granted)
    }
  }

  private fun hasPermission(permission: String): Boolean {
    return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
  }

  private fun <I, O> launchWithResult(
    contract: ActivityResultContract<I, O>,
    input: I,
    callback: (O) -> Unit,
  ) {
    val activity = resolveComponentActivity()
    if (activity == null) {
      callback.invoke(defaultResultForMissingActivity(contract))
      return
    }
    val key = "chat-input-${UUID.randomUUID()}"
    var launcher: ActivityResultLauncher<I>? = null
    launcher =
      activity.activityResultRegistry.register(
        key,
        contract,
        ActivityResultCallback<O> { output ->
          try {
            callback(output)
          } finally {
            launcher?.unregister()
          }
        },
      )
    launcher.launch(input)
  }

  @Suppress("UNCHECKED_CAST")
  private fun <I, O> defaultResultForMissingActivity(contract: ActivityResultContract<I, O>): O {
    return when (contract) {
      is ActivityResultContracts.RequestPermission -> false as O
      else -> throw IllegalStateException("No ComponentActivity available for activity result")
    }
  }

  private fun resolveComponentActivity(): ComponentActivity? {
    return resolveActivity() as? ComponentActivity
  }

  private fun resolveActivity(): Activity? {
    val fromAppContext = appContext?.currentActivity
    if (fromAppContext != null) return fromAppContext
    return context as? Activity
  }

  private fun toast(message: String) {
    Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
  }

  private fun startRecordingHintAnimations() {
    if (!isRecording || isLockedRecording) return
    if (lockHintArrowAnimator != null || slideHintChevronAnimator != null || slideHintLabelAnimator != null) return

    val slideOffset = dpF(8f)
    val upOffset = dpF(6f)
    val interpolator = AccelerateDecelerateInterpolator()

    slideHintChevronAnimator =
      ObjectAnimator.ofFloat(recordingSlideChevron, View.TRANSLATION_X, 0f, -slideOffset).apply {
        duration = 550L
        repeatCount = ValueAnimator.INFINITE
        repeatMode = ValueAnimator.REVERSE
        this.interpolator = interpolator
        start()
      }
    slideHintLabelAnimator =
      ObjectAnimator.ofFloat(recordingSlideLabel, View.TRANSLATION_X, 0f, -slideOffset).apply {
        duration = 550L
        repeatCount = ValueAnimator.INFINITE
        repeatMode = ValueAnimator.REVERSE
        this.interpolator = interpolator
        start()
      }
    lockHintArrowAnimator =
      ObjectAnimator.ofFloat(lockHintArrow, View.TRANSLATION_Y, 0f, -upOffset).apply {
        duration = 520L
        repeatCount = ValueAnimator.INFINITE
        repeatMode = ValueAnimator.REVERSE
        this.interpolator = interpolator
        start()
      }
  }

  private fun stopRecordingHintAnimations(resetTransforms: Boolean = true) {
    lockHintArrowAnimator?.cancel()
    slideHintChevronAnimator?.cancel()
    slideHintLabelAnimator?.cancel()
    lockHintArrowAnimator = null
    slideHintChevronAnimator = null
    slideHintLabelAnimator = null
    if (resetTransforms) {
      lockHintArrow.translationY = 0f
      recordingSlideChevron.translationX = 0f
      recordingSlideLabel.translationX = 0f
    }
  }

  private fun animateTimerLabelEntry() {
    recordingTimerLabel.animate().cancel()
    recordingTimerLabel.alpha = 0.72f
    recordingTimerLabel.translationY = dpF(2f)
    recordingTimerLabel.animate()
      .alpha(1f)
      .translationY(0f)
      .setDuration(180L)
      .start()
  }

  private fun pulseTimerLabel() {
    recordingTimerLabel.animate().cancel()
    recordingTimerLabel.animate()
      .scaleX(1.06f)
      .scaleY(1.06f)
      .setDuration(90L)
      .withEndAction {
        recordingTimerLabel.animate()
          .scaleX(1f)
          .scaleY(1f)
          .setDuration(120L)
          .start()
      }
      .start()
  }

  private fun applyVadVisual(level: Float) {
    if (!isRecording) {
      vadVisualLevel = 0f
      return
    }
    val clamped = level.coerceIn(0f, 1f)
    vadVisualLevel = (vadVisualLevel * 0.72f) + (clamped * 0.28f)
    val baseScale = if (isLockedRecording) 1.08f else 1.1f
    val pulse = if (isLockedRecording) 0.16f else 0.22f
    val scale = baseScale + (vadVisualLevel * pulse)
    actionButton.scaleX = scale
    actionButton.scaleY = scale
    val dotScale = 1f + (vadVisualLevel * 0.26f)
    recordingDot.scaleX = dotScale
    recordingDot.scaleY = dotScale
  }

  private fun resetVadVisuals() {
    vadVisualLevel = 0f
    actionButton.animate().cancel()
    actionButton.animate()
      .scaleX(1f)
      .scaleY(1f)
      .setDuration(160L)
      .start()
    recordingDot.scaleX = 1f
    recordingDot.scaleY = 1f
  }

  private fun updateDragVisuals(dx: Float, dy: Float) {
    if (!isRecording || isLockedRecording) {
      recordingSlideLabel.alpha = 1f
      recordingSlideChevron.alpha = 1f
      recordingSlideLabel.translationX = 0f
      recordingSlideChevron.translationX = 0f
      lockHintPill.translationY = 0f
      return
    }
    if (abs(dx) > dpF(1f) || abs(dy) > dpF(1f)) {
      stopRecordingHintAnimations(resetTransforms = false)
    }
    val cancelProgress = (-dx / cancelThresholdPx.toFloat()).coerceIn(0f, 1f)
    val lockProgress = (-dy / lockThresholdPx.toFloat()).coerceIn(0f, 1f)
    val dragOffset = dpF(18f) * cancelProgress
    recordingSlideLabel.translationX = -dragOffset
    recordingSlideChevron.translationX = -dragOffset
    recordingSlideLabel.alpha = 1f - (cancelProgress * 0.55f)
    recordingSlideChevron.alpha = 1f - (cancelProgress * 0.70f)
    lockHintPill.translationY = dpF(8f) - (dpF(10f) * lockProgress)
    lockHintPill.alpha = 0.72f + (0.28f * lockProgress)
  }

  private fun resetRecordingDragVisuals() {
    recordingSlideLabel.alpha = 1f
    recordingSlideChevron.alpha = 1f
    recordingSlideLabel.translationX = 0f
    recordingSlideChevron.translationX = 0f
    lockHintPill.alpha = if (lockHintPill.visibility == View.VISIBLE) 1f else 0f
    lockHintPill.translationY = 0f
    if (isRecording && !isLockedRecording) {
      startRecordingHintAnimations()
    }
  }

  private fun bindEvents() {
    input.addTextChangedListener(object : TextWatcher {
      override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
      override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
        listener?.onTextChanged(s?.toString().orEmpty())
        refreshVisualState()
      }
      override fun afterTextChanged(s: Editable?) = Unit
    })

    input.setOnEditorActionListener { _, actionId, _ ->
      if (actionId == EditorInfo.IME_ACTION_SEND) {
        sendCurrentText()
        true
      } else {
        false
      }
    }

    attachmentButton.setOnClickListener {
      if (!isRecording) {
        listener?.onAttachmentPressed()
        openAttachmentMenu()
      }
    }
    recordingSlideLabel.setOnClickListener {
      if (isRecording && isLockedRecording) {
        cancelVoiceRecording()
      }
    }
    attachmentButton.setOnTouchListener { _, event -> handleAttachmentTouch(event) }
    actionButton.setOnTouchListener { _, event -> handleActionTouch(event) }
  }

  private fun handleAttachmentTouch(event: MotionEvent): Boolean {
    if (isRecording) return true
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> animateButtonPress(attachmentButton, true, 70L)
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> animateButtonPress(attachmentButton, false, 120L)
    }
    return false
  }

  private fun openAttachmentMenu() {
    if (isRecording) return
    val menu = attachmentMenu ?: ChatAttachmentMenuController(context, appContext).also { created ->
      created.onSelectImage = { uri, caption ->
        listener?.onAttachmentImage(uri, caption)
      }
      created.onSelectFile = { uri, name, size, mimeType, caption ->
        listener?.onAttachmentFile(uri, name, size, mimeType, caption)
      }
      created.onSelectLocation = { latitude, longitude, caption ->
        listener?.onAttachmentLocation(latitude, longitude, caption)
      }
      attachmentMenu = created
    }
    menu.show(anchor = attachmentButton, appearance = currentAppearance)
  }

  private fun handleActionTouch(event: MotionEvent): Boolean {
    val hasText = hasTypedText()

    if (hasText && !isRecording) {
      when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
          animateButtonPress(actionButton, true, 70L)
          return true
        }
        MotionEvent.ACTION_UP -> {
          animateButtonPress(actionButton, false, 120L)
          sendCurrentText()
          return true
        }
        MotionEvent.ACTION_CANCEL -> {
          animateButtonPress(actionButton, false, 120L)
          return true
        }
      }
    }

    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        micTouchActive = true
        downRawX = event.rawX
        downRawY = event.rawY
        longPressStarted = false
        lockActivatedInGesture = false
        animateButtonPress(actionButton, true, 70L)

        if (isRecording && isLockedRecording) {
          return true
        }

        longPressArmed = true
        uiHandler.postDelayed(longPressRunnable, longPressTimeoutMs.toLong())
        return true
      }

      MotionEvent.ACTION_MOVE -> {
        if (isRecording) {
          val dx = event.rawX - downRawX
          val dy = event.rawY - downRawY
          updateDragVisuals(dx = dx, dy = dy)
          if (!isLockedRecording && dy < -lockThresholdPx) {
            isLockedRecording = true
            lockActivatedInGesture = true
            listener?.onRecordingState(true, true)
            performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            recordingSlideLabel.text = "Cancel"
            recordingSlideChevron.visibility = View.GONE
            showLockHint(visible = false, animated = true)
            resetRecordingDragVisuals()
            refreshVisualState()
          }
          if (!isLockedRecording && dx < -cancelThresholdPx) {
            cancelVoiceRecording()
            animateButtonPress(actionButton, false, 90L)
            return true
          }
        }
        return true
      }

      MotionEvent.ACTION_UP -> {
        micTouchActive = false
        uiHandler.removeCallbacks(longPressRunnable)
        longPressArmed = false
        animateButtonPress(actionButton, false, 120L)
        resetRecordingDragVisuals()

        if (isRecording) {
          if (isLockedRecording && lockActivatedInGesture) {
            // Keep recording after the lock gesture release.
            return true
          }
          stopVoiceRecording(send = true)
          return true
        }

        if (longPressStarted) return true
        return true
      }

      MotionEvent.ACTION_CANCEL -> {
        micTouchActive = false
        uiHandler.removeCallbacks(longPressRunnable)
        longPressArmed = false
        animateButtonPress(actionButton, false, 120L)
        resetRecordingDragVisuals()
        if (isRecording && !isLockedRecording) {
          stopVoiceRecording(send = false)
        }
        return true
      }
    }

    return false
  }

  private fun sendCurrentText() {
    if (isRecording && isLockedRecording) {
      stopVoiceRecording(send = true)
      return
    }
    val text = input.text?.toString()?.trim().orEmpty()
    if (text.isEmpty()) return
    val messageId = UUID.randomUUID().toString().lowercase()

    when (val mentionIntent = resolveMentionIntent(text)) {
      is MentionIntent.Builder -> listener?.onRequestVibeAgentBuilder()
      is MentionIntent.Group -> listener?.onSendTextWithAgentMention(text, mentionIntent.agentText, messageId)
      is MentionIntent.Standalone ->
        listener?.onSendTextWithStandaloneAgentMention(
          text,
          mentionIntent.agentText,
          mentionIntent.username,
          messageId,
        )
      is MentionIntent.None -> listener?.onSendText(text, messageId)
    }
    input.setText("")
  }

  private sealed class MentionIntent {
    object None : MentionIntent()
    object Builder : MentionIntent()
    data class Group(val agentText: String) : MentionIntent()
    data class Standalone(val username: String, val agentText: String) : MentionIntent()
  }

  private fun resolveMentionIntent(text: String): MentionIntent {
    val matches =
      Regex("""(?:^|\s)@([A-Za-z0-9_]{3,30})\b""", RegexOption.IGNORE_CASE)
        .findAll(text)
        .mapNotNull { match ->
          match.groups[1]?.value?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        }
        .distinct()
        .toList()

    if (matches.contains("vibeagent")) {
      return MentionIntent.Builder
    }

    if (matches.size != 1) {
      return MentionIntent.None
    }

    val username = matches.first()
    val stripped =
      text
        .replace(Regex("@${Regex.escape(username)}", RegexOption.IGNORE_CASE), "")
        .trim()

    if (stripped.isEmpty()) {
      return MentionIntent.None
    }

    return if (username == "vibe") {
      MentionIntent.Group(stripped)
    } else {
      MentionIntent.Standalone(username, stripped)
    }
  }

  private fun supportsBuilderSlashCommands(): Boolean {
    val hint = input.hint?.toString()?.lowercase().orEmpty()
    return hint.contains("@vibeagent") || hint.contains("/command") || hint.contains("type /")
  }

  private fun resolveReadyBannerAction(text: String): ReadyBannerAction {
    resolveSlashSuggestion(text)?.let { suggestion ->
      return ReadyBannerAction.Slash(suggestion)
    }

    val shouldShowMention =
      text.isNotEmpty() &&
        text.lastIndexOf('@').let { atIndex ->
          if (atIndex < 0) {
            false
          } else {
            val afterAt = text.substring(atIndex + 1).lowercase()
            val isAtStart = atIndex == 0
            val isPrecededBySpace = !isAtStart && text[atIndex - 1].isWhitespace()
            (isAtStart || isPrecededBySpace) &&
              !afterAt.contains(" ") &&
              ("vibe".startsWith(afterAt) || afterAt.isEmpty())
          }
        }

    return if (shouldShowMention) ReadyBannerAction.Mention else ReadyBannerAction.None
  }

  private fun resolveSlashSuggestion(text: String): ReadyCommandSuggestion? {
    if (!supportsBuilderSlashCommands()) return null

    val match =
      Regex("""(?:^|\s)(/[A-Za-z]*)$""")
        .find(text)
        ?: return null

    val token = match.groupValues.getOrElse(1) { "" }.lowercase()
    if (!token.startsWith("/")) return null
    if (token == "/") return builderSlashSuggestions.firstOrNull()
    return builderSlashSuggestions.firstOrNull { it.command.startsWith(token) }
  }

  private fun applyReadyBannerAction(action: ReadyBannerAction) {
    readyBannerAction = action
    when (action) {
      ReadyBannerAction.None -> {
        mentionBanner.visibility = View.GONE
      }

      ReadyBannerAction.Mention -> {
        mentionNameLabel.text = "@vibe"
        mentionDescLabel.text = "Ask AI"
        mentionBanner.visibility = View.VISIBLE
      }

      is ReadyBannerAction.Slash -> {
        mentionNameLabel.text = action.suggestion.command
        mentionDescLabel.text = action.suggestion.description
        mentionBanner.visibility = View.VISIBLE
      }
    }
  }

  private fun handleReadyBannerTap() {
    when (val action = readyBannerAction) {
      ReadyBannerAction.None -> return

      ReadyBannerAction.Mention -> {
        val text = input.text?.toString().orEmpty()
        val updated =
          if (text.contains("@")) {
            val lastAt = text.lastIndexOf('@')
            if (lastAt >= 0) {
              text.substring(0, lastAt) + "@vibe "
            } else {
              "@vibe "
            }
          } else {
            if (text.isBlank()) "@vibe " else "$text @vibe "
          }
        input.setText(updated)
        input.setSelection(updated.length)
      }

      is ReadyBannerAction.Slash -> {
        applySlashSuggestion(action.suggestion)
      }
    }

    applyReadyBannerAction(ReadyBannerAction.None)
    input.requestFocus()
  }

  private fun applySlashSuggestion(suggestion: ReadyCommandSuggestion) {
    val text = input.text?.toString().orEmpty()
    val updated =
      Regex("""(?:^|\s)(/[A-Za-z]*)$""")
        .replace(text, { match ->
          val token = match.groupValues.getOrElse(1) { "" }
          match.value.removeSuffix(token) + suggestion.insertion
        })

    val finalText = if (updated == text) suggestion.insertion else updated
    input.setText(finalText)
    input.setSelection(finalText.length)
  }

  private fun hasTypedText(): Boolean {
    return input.text?.toString()?.trim()?.isNotEmpty() == true
  }

  private fun refreshVisualState() {
    val textStr = input.text?.toString() ?: ""
    val hasText = textStr.trim().isNotEmpty()
    if (!isRecording) {
      applyReadyBannerAction(resolveReadyBannerAction(textStr))
    } else {
      applyReadyBannerAction(ReadyBannerAction.None)
    }
    val actionFill =
      when {
        isRecording && isLockedRecording -> withAlpha(accentColor, 1.0f)
        isRecording -> withAlpha(accentColor, 0.9f)
        hasText -> withAlpha(accentColor, 1.0f)
        else -> Color.TRANSPARENT
      }
    val actionTint =
      when {
        isRecording || hasText -> Color.WHITE
        else -> passiveIconColor
      }
    val nextRes =
      when {
        isRecording && isLockedRecording -> R.drawable.ic_send
        isRecording -> R.drawable.ic_recording_dot
        hasTypedText() -> R.drawable.ic_send
        else -> R.drawable.ic_mic
      }

    if (nextRes != lastActionRes) {
      lastActionRes = nextRes
      actionIcon.setImageResource(nextRes)
      actionIcon.scaleX = 0.84f
      actionIcon.scaleY = 0.84f
      actionIcon.alpha = 0.78f
      actionIcon.animate()
        .scaleX(1f)
        .scaleY(1f)
        .alpha(1f)
        .setDuration(140L)
        .start()
    } else {
      actionIcon.setImageResource(nextRes)
    }
    actionIcon.setColorFilter(actionTint)
    actionButton.background = circleDrawable(actionFill)

    attachmentIcon.setColorFilter(passiveIconColor)
    attachmentButton.alpha = if (isRecording) 0.45f else 1f
    attachmentButton.background = circleDrawable(Color.TRANSPARENT)

    input.visibility = if (isRecording) View.INVISIBLE else View.VISIBLE
    recordingOverlay.visibility = if (isRecording) View.VISIBLE else View.GONE
    if (!isRecording) {
      stopRecordingHintAnimations()
      recordingDot.alpha = 1f
      recordingDot.scaleX = 1f
      recordingDot.scaleY = 1f
      recordingSlideChevron.visibility = View.VISIBLE
      recordingSlideLabel.text = "Slide to cancel"
      recordingSlideLabel.isClickable = false
      recordingSlideLabel.isFocusable = false
      recordingSlideLabel.setTextColor(withAlpha(textColor, 0.78f))
      recordingSlideChevron.setTextColor(withAlpha(textColor, 0.78f))
      recordingTimerLabel.scaleX = 1f
      recordingTimerLabel.scaleY = 1f
      recordingTimerLabel.alpha = 1f
      recordingTimerLabel.translationY = 0f
      attachmentButton.animate().cancel()
      attachmentButton.translationX = 0f
      attachmentButton.scaleX = 1f
      attachmentButton.scaleY = 1f
      showLockHint(visible = false, animated = false)
    } else {
      recordingSlideChevron.visibility = if (isLockedRecording) View.GONE else View.VISIBLE
      recordingSlideLabel.text = if (isLockedRecording) "Cancel" else "Slide to cancel"
      recordingSlideLabel.isClickable = isLockedRecording
      recordingSlideLabel.isFocusable = isLockedRecording
      if (isLockedRecording) {
        recordingSlideLabel.setTextColor(withAlpha(dangerColor, 0.96f))
        stopRecordingHintAnimations()
      } else {
        recordingSlideLabel.setTextColor(withAlpha(textColor, 0.78f))
        startRecordingHintAnimations()
      }
      recordingSlideChevron.setTextColor(withAlpha(textColor, 0.78f))
      showLockHint(visible = !isLockedRecording, animated = true)
    }
    updateSurfaces()
  }

  private fun updateSurfaces() {
    textSurface.background = roundedDrawable(withAlpha(surfaceColor, 0.92f), dpF(22f))
    input.setTextColor(textColor)
    input.setHintTextColor(hintColor)
  }

  private fun animateRecordingStartUi() {
    attachmentButton.animate().cancel()
    attachmentButton.animate()
      .translationX(-dpF(18f))
      .scaleX(0.84f)
      .scaleY(0.84f)
      .alpha(0.18f)
      .setDuration(220L)
      .start()
    actionButton.animate().cancel()
    actionButton.animate()
      .scaleX(1.08f)
      .scaleY(1.08f)
      .setDuration(180L)
      .start()
    showLockHint(visible = true, animated = true)
    resetRecordingDragVisuals()
    startRecordingHintAnimations()
  }

  private fun resetRecordingUiEffects() {
    attachmentButton.animate().cancel()
    attachmentButton.animate()
      .translationX(0f)
      .scaleX(1f)
      .scaleY(1f)
      .alpha(1f)
      .setDuration(180L)
      .start()
    actionButton.animate().cancel()
    actionButton.animate()
      .scaleX(1f)
      .scaleY(1f)
      .setDuration(160L)
      .start()
    stopRecordingHintAnimations()
    resetRecordingDragVisuals()
    showLockHint(visible = false, animated = true)
  }

  private fun animateButtonPress(view: View, pressed: Boolean, durationMs: Long) {
    view.animate()
      .scaleX(if (pressed) 0.96f else 1f)
      .scaleY(if (pressed) 0.96f else 1f)
      .alpha(if (pressed) 0.90f else 1f)
      .setDuration(durationMs)
      .start()
  }

  private fun startVoiceRecording(): Boolean {
    if (isRecording) return true

    val outputFile = File(context.cacheDir, "vibe-voice-${UUID.randomUUID()}.m4a")
    val mediaRecorder = MediaRecorder()

    return try {
      mediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
      mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
      mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
      mediaRecorder.setAudioEncodingBitRate(64000)
      mediaRecorder.setAudioSamplingRate(44100)
      mediaRecorder.setOutputFile(outputFile.absolutePath)
      mediaRecorder.prepare()
      mediaRecorder.start()

      recorder = mediaRecorder
      recordingFile = outputFile
      recordingStartedAtMs = SystemClock.elapsedRealtime()
      lastTimerPulseSecond = -1
      vadVisualLevel = 0f
      isRecording = true
      isLockedRecording = false
      recordingAmplitudes.clear()
      recordingSlideLabel.text = "Slide to cancel"
      recordingSlideChevron.visibility = View.VISIBLE
      updateRecordingStatus(buildRecordingStatusLine())
      animateTimerLabelEntry()
      animateRecordingStartUi()
      refreshVisualState()
      listener?.onRecordingState(true, false)
      startVadTicker()
      true
    } catch (_: Throwable) {
      try {
        mediaRecorder.reset()
      } catch (_: Throwable) {
      }
      try {
        mediaRecorder.release()
      } catch (_: Throwable) {
      }
      recorder = null
      recordingFile = null
      recordingStartedAtMs = 0L
      isRecording = false
      isLockedRecording = false
      resetRecordingUiEffects()
      refreshVisualState()
      listener?.onRecordingCanceled()
      listener?.onRecordingState(false, false)
      false
    }
  }

  private fun startVadTicker() {
    vadTicker?.let { uiHandler.removeCallbacks(it) }
    val ticker = object : Runnable {
      override fun run() {
        if (!isRecording) return

        val amplitude =
          try {
            recorder?.maxAmplitude ?: 0
          } catch (_: Throwable) {
            0
          }
        recordingAmplitudes.add(amplitude)
        val normalized = normalizeRecordingAmplitude(amplitude)
        listener?.onRecordingVad(normalized)
        applyVadVisual(normalized)

        updateRecordingStatus(buildRecordingStatusLine())

        val elapsedMs = max(0L, SystemClock.elapsedRealtime() - recordingStartedAtMs)
        val totalSeconds = (elapsedMs / 1000L).toInt()
        if (totalSeconds != lastTimerPulseSecond) {
          lastTimerPulseSecond = totalSeconds
          pulseTimerLabel()
        }
        val blinkOn = (elapsedMs / 500L) % 2L == 0L
        recordingDot.alpha = if (blinkOn) 1f else 0.24f

        uiHandler.postDelayed(this, 100L)
      }
    }
    vadTicker = ticker
    uiHandler.post(ticker)
  }

  private fun buildRecordingStatusLine(): String {
    val elapsedMs = max(0L, SystemClock.elapsedRealtime() - recordingStartedAtMs)
    val totalSeconds = (elapsedMs / 1000L).toInt()
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    val centis = ((elapsedMs % 1000L) / 10L).toInt()
    return String.format("%d:%02d.%02d", minutes, seconds, centis)
  }

  private fun updateRecordingStatus(text: String) {
    recordingTimerLabel.text = text
  }

  private fun stopVoiceRecording(send: Boolean) {
    if (!isRecording) return

    vadTicker?.let { uiHandler.removeCallbacks(it) }
    vadTicker = null

    val durationMs = max(0L, SystemClock.elapsedRealtime() - recordingStartedAtMs)
    val outputFile = recordingFile
    val recorderRef = recorder

    recorder = null
    recordingFile = null
    recordingStartedAtMs = 0L

    try {
      recorderRef?.stop()
    } catch (_: Throwable) {
    }
    try {
      recorderRef?.reset()
    } catch (_: Throwable) {
    }
    try {
      recorderRef?.release()
    } catch (_: Throwable) {
    }

    isRecording = false
    isLockedRecording = false
    resetRecordingUiEffects()
    resetVadVisuals()
    lastTimerPulseSecond = -1
    recordingTimerLabel.animate().cancel()
    listener?.onRecordingState(false, false)
    listener?.onRecordingVad(0f)

    val canSend =
      send &&
      durationMs >= minRecordSendDurationMs &&
      outputFile != null &&
      outputFile.exists() &&
      outputFile.length() > 0L
    if (canSend) {
      listener?.onVoiceRecorded(
        Uri.fromFile(outputFile).toString(),
        durationMs.toDouble() / 1000.0,
        buildWaveform(recordingAmplitudes, 100),
      )
    } else {
      outputFile?.delete()
      listener?.onRecordingCanceled()
    }

    recordingAmplitudes.clear()
    refreshVisualState()
  }

  private fun cancelVoiceRecording() {
    stopVoiceRecording(send = false)
  }

  private fun buildWaveform(samples: List<Int>, bins: Int): List<Float> {
    if (samples.isEmpty() || bins <= 0) return emptyList()
    val silenceThreshold = 0.02f
    val sanitized =
      samples
        .map(::normalizeRecordingAmplitude)
        .filter { it.isFinite() }
        .map { sample ->
          if (sample <= silenceThreshold) {
            0f
          } else {
            ((sample - silenceThreshold) / (1f - silenceThreshold)).coerceIn(0f, 1f)
          }
        }
    if (sanitized.isEmpty()) return List(bins) { 0f }

    val peakSamples = FloatArray(bins)
    val sourceCount = sanitized.size
    for (index in sanitized.indices) {
      val bucketIndex = min(bins - 1, (index * bins) / max(1, sourceCount))
      peakSamples[bucketIndex] = max(peakSamples[bucketIndex], sanitized[index])
    }

    val averagePeak = peakSamples.sum() / bins.toFloat()
    val normalizationPeak = max(0.04f, averagePeak * 1.8f)
    val result =
      peakSamples.map { sample ->
        (min(sample, normalizationPeak) / normalizationPeak).coerceIn(0f, 1f)
      }
    return if (result.all { it <= 0.003f }) {
      List(bins) { 0f }
    } else {
      result
    }
  }

  private fun normalizeRecordingAmplitude(amplitude: Int): Float {
    val ratio = (amplitude.coerceAtLeast(0) / 32767f).coerceIn(0f, 1f)
    val silenceFloor = 0.015f
    val normalized = ((ratio - silenceFloor) / (1f - silenceFloor)).coerceIn(0f, 1f)
    return normalized.pow(0.72f)
  }

  private fun circleDrawable(
    color: Int,
    strokeColor: Int = Color.TRANSPARENT,
    strokeWidth: Float = 0f,
  ): GradientDrawable =
    GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(color)
      if (strokeWidth > 0f && Color.alpha(strokeColor) > 0) {
        setStroke(max(1, strokeWidth.roundToInt()), strokeColor)
      }
    }

  private fun roundedDrawable(
    color: Int,
    radius: Float,
    strokeColor: Int = Color.TRANSPARENT,
    strokeWidth: Float = 0f,
  ): GradientDrawable =
    GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = radius
      setColor(color)
      if (strokeWidth > 0f && Color.alpha(strokeColor) > 0) {
        setStroke(max(1, strokeWidth.roundToInt()), strokeColor)
      }
    }

  private fun dp(value: Int): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).roundToInt()

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).roundToInt()
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }
}
