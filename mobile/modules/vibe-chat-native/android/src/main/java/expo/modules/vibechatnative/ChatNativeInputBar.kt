package expo.modules.vibechatnative

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.MediaRecorder
import android.net.Uri
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
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.util.UUID
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal class ChatNativeInputBar(
  context: Context,
) : FrameLayout(context) {
  interface Listener {
    fun onTextChanged(text: String)
    fun onAttachmentPressed()
    fun onSendText(text: String, messageId: String)
    fun onRecordingState(isRecording: Boolean, isLocked: Boolean)
    fun onRecordingVad(level: Float)
    fun onRecordingCanceled()
    fun onVoiceRecorded(uri: String, durationSeconds: Double, waveform: List<Float>)
  }

  var listener: Listener? = null

  private val rootColumn = LinearLayout(context)
  private val row = LinearLayout(context)
  private val attachmentButton = FrameLayout(context)
  private val attachmentIcon = ChatNativeInputGlyphView(context)
  private val textSurface = FrameLayout(context)
  private val input = EditText(context)
  private val recordingOverlay = LinearLayout(context)
  private val recordingDot = View(context)
  private val recordingLabel = TextView(context)
  private val actionButton = FrameLayout(context)
  private val actionIcon = ChatNativeInputGlyphView(context)

  private val uiHandler = Handler(Looper.getMainLooper())
  private val longPressTimeoutMs = min(230, ViewConfiguration.getLongPressTimeout())
  private val lockThresholdPx = dp(44)
  private val cancelThresholdPx = dp(76)

  private var surfaceColor = Color.argb(246, 20, 24, 30)
  private var mutedSurfaceColor = Color.argb(28, 255, 255, 255)
  private var textColor = Color.WHITE
  private var hintColor = Color.argb(150, 255, 255, 255)
  private var passiveIconColor = Color.WHITE
  private var accentColor = Color.argb(255, 106, 79, 207)
  private var dangerColor = Color.argb(255, 255, 59, 48)
  private var neutralButtonColor = Color.argb(40, 255, 255, 255)

  private var longPressArmed = false
  private var longPressStarted = false
  private var lockActivatedInGesture = false
  private var downX = 0f
  private var downY = 0f

  private var isRecording = false
  private var isLockedRecording = false
  private var recorder: MediaRecorder? = null
  private var recordingFile: File? = null
  private var recordingStartedAtMs = 0L
  private var vadTicker: Runnable? = null
  private val recordingAmplitudes = ArrayList<Int>(256)

  private val longPressRunnable = Runnable {
    longPressArmed = false
    if (startVoiceRecording()) {
      longPressStarted = true
      lockActivatedInGesture = false
      performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    }
  }

  init {
    clipChildren = false
    clipToPadding = false
    setPadding(dp(10), dp(6), dp(10), dp(8))

    rootColumn.orientation = LinearLayout.VERTICAL
    rootColumn.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
    addView(rootColumn)

    row.orientation = LinearLayout.HORIZONTAL
    row.gravity = Gravity.BOTTOM or Gravity.CENTER_VERTICAL
    row.layoutParams = LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      LayoutParams.WRAP_CONTENT,
    )
    rootColumn.addView(row)

    setupAttachmentButton()
    setupTextSurface()
    setupActionButton()
    bindEvents()
    refreshVisualState()
  }

  fun setPlaceholder(value: String) {
    input.hint = value
  }

  fun applyAppearance(appearance: ChatListAppearance, isDark: Boolean, backgroundReferenceColor: Int) {
    val ref = backgroundReferenceColor
    val textBase = appearance.textColorThem
    val accentBase = appearance.bubbleMeGradient.lastOrNull() ?: appearance.textColorMe
    surfaceColor =
      if (isDark) {
        withAlpha(blend(ref, Color.BLACK, 0.40f), 0.97f)
      } else {
        withAlpha(blend(ref, Color.WHITE, 0.86f), 0.985f)
      }
    mutedSurfaceColor =
      if (isDark) withAlpha(Color.WHITE, 0.06f) else withAlpha(Color.BLACK, 0.045f)
    textColor = textBase
    hintColor = withAlpha(textBase, if (isDark) 0.52f else 0.45f)
    passiveIconColor = withAlpha(textBase, if (isDark) 0.90f else 0.84f)
    accentColor = accentBase
    neutralButtonColor = if (isDark) withAlpha(surfaceColor, 0.96f) else withAlpha(surfaceColor, 0.98f)

    input.setTextColor(textColor)
    input.setHintTextColor(hintColor)
    recordingLabel.setTextColor(withAlpha(textBase, if (isDark) 0.88f else 0.80f))
    updateSurfaces()
    refreshVisualState()
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    uiHandler.removeCallbacks(longPressRunnable)
    vadTicker?.let { uiHandler.removeCallbacks(it) }
    vadTicker = null
    if (isRecording) {
      stopVoiceRecording(send = false)
    }
  }

  private fun setupAttachmentButton() {
    attachmentButton.layoutParams = LinearLayout.LayoutParams(dp(44), dp(44)).apply {
      rightMargin = dp(8)
      bottomMargin = dp(2)
    }
    attachmentButton.background = circleDrawable(mutedSurfaceColor)
    attachmentButton.clipChildren = false
    attachmentButton.clipToPadding = false
    row.addView(attachmentButton)

    attachmentIcon.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    attachmentIcon.glyph = ChatNativeInputGlyph.ATTACH
    attachmentButton.addView(attachmentIcon)
  }

  private fun setupTextSurface() {
    textSurface.layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply {
      rightMargin = dp(8)
    }
    textSurface.background = roundedDrawable(surfaceColor, dpF(22f))
    textSurface.clipChildren = false
    textSurface.clipToPadding = false
    row.addView(textSurface)

    input.layoutParams = FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
    input.setBackgroundColor(Color.TRANSPARENT)
    input.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    input.typeface = Typeface.DEFAULT
    input.maxLines = 4
    input.minLines = 1
    input.gravity = Gravity.CENTER_VERTICAL
    input.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
    input.imeOptions = EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_EXTRACT_UI
    input.setPadding(dp(14), dp(10), dp(14), dp(10))
    input.includeFontPadding = false
    textSurface.addView(input)

    recordingOverlay.layoutParams = FrameLayout.LayoutParams(
      LayoutParams.MATCH_PARENT,
      LayoutParams.MATCH_PARENT,
    ).apply {
      gravity = Gravity.CENTER_VERTICAL
      leftMargin = dp(14)
      rightMargin = dp(14)
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

    recordingLabel.layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
    recordingLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    recordingLabel.ellipsize = TextUtils.TruncateAt.END
    recordingLabel.maxLines = 1
    recordingOverlay.addView(recordingLabel)
  }

  private fun setupActionButton() {
    actionButton.layoutParams = LinearLayout.LayoutParams(dp(44), dp(44)).apply {
      bottomMargin = dp(2)
    }
    actionButton.background = circleDrawable(neutralButtonColor)
    row.addView(actionButton)

    actionIcon.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    actionIcon.glyph = ChatNativeInputGlyph.MIC
    actionButton.addView(actionIcon)
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
        downX = event.x
        downY = event.y
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
          val dx = event.x - downX
          val dy = event.y - downY
          if (!isLockedRecording && dy < -lockThresholdPx) {
            isLockedRecording = true
            lockActivatedInGesture = true
            listener?.onRecordingState(true, true)
            performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            updateRecordingStatus(buildRecordingStatusLine())
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
        uiHandler.removeCallbacks(longPressRunnable)
        longPressArmed = false
        animateButtonPress(actionButton, false, 120L)

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
        uiHandler.removeCallbacks(longPressRunnable)
        longPressArmed = false
        animateButtonPress(actionButton, false, 120L)
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
    listener?.onSendText(text, "android-native-${UUID.randomUUID()}")
    input.setText("")
  }

  private fun hasTypedText(): Boolean {
    return input.text?.toString()?.trim()?.isNotEmpty() == true
  }

  private fun refreshVisualState() {
    val hasText = hasTypedText()
    val actionFill =
      when {
        isRecording && isLockedRecording -> withAlpha(accentColor, 0.96f)
        isRecording -> withAlpha(accentColor, 0.88f)
        hasText -> withAlpha(accentColor, 0.94f)
        else -> neutralButtonColor
      }
    val actionTint =
      when {
        isRecording || hasText -> Color.WHITE
        else -> passiveIconColor
      }
    val nextGlyph =
      when {
        isRecording && isLockedRecording -> ChatNativeInputGlyph.SEND
        isRecording -> ChatNativeInputGlyph.RECORDING_DOT
        hasText -> ChatNativeInputGlyph.SEND
        else -> ChatNativeInputGlyph.MIC
      }

    actionIcon.glyph = nextGlyph
    actionIcon.tintColor = actionTint
    actionButton.background = circleDrawable(actionFill)

    attachmentIcon.tintColor = passiveIconColor
    attachmentButton.alpha = if (isRecording) 0.45f else 1f
    attachmentButton.background = circleDrawable(if (isRecording) mutedSurfaceColor else neutralButtonColor)

    input.visibility = if (isRecording) View.INVISIBLE else View.VISIBLE
    recordingOverlay.visibility = if (isRecording) View.VISIBLE else View.GONE
    if (!isRecording) {
      recordingDot.alpha = 1f
    }
    updateSurfaces()
  }

  private fun updateSurfaces() {
    textSurface.background = roundedDrawable(surfaceColor, dpF(22f))
    input.setTextColor(textColor)
    input.setHintTextColor(hintColor)
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
      isRecording = true
      isLockedRecording = false
      recordingAmplitudes.clear()
      updateRecordingStatus(buildRecordingStatusLine())
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
        val normalized = (amplitude / 32767f).coerceIn(0f, 1f)
        listener?.onRecordingVad(normalized)

        updateRecordingStatus(buildRecordingStatusLine())

        val elapsedMs = max(0L, SystemClock.elapsedRealtime() - recordingStartedAtMs)
        val blinkOn = (elapsedMs / 420L) % 2L == 0L
        recordingDot.alpha = if (blinkOn) 1f else 0.24f

        uiHandler.postDelayed(this, 70L)
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
    val timeText = String.format("%d:%02d", minutes, seconds)
    val hint = if (isLockedRecording) "Locked - tap send" else "Swipe left cancel / up lock"
    return "$timeText  $hint"
  }

  private fun updateRecordingStatus(text: String) {
    recordingLabel.text = text
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
    listener?.onRecordingState(false, false)
    listener?.onRecordingVad(0f)

    if (send && outputFile != null && outputFile.exists() && outputFile.length() > 0L) {
      listener?.onVoiceRecorded(
        Uri.fromFile(outputFile).toString(),
        (durationMs.toDouble() / 1000.0).coerceAtLeast(0.1),
        buildWaveform(recordingAmplitudes, 40),
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
    val out = ArrayList<Float>(bins)
    val chunk = max(1, samples.size / bins)
    var i = 0
    while (i < samples.size && out.size < bins) {
      var maxAmp = 0
      var j = i
      val end = min(samples.size, i + chunk)
      while (j < end) {
        maxAmp = max(maxAmp, samples[j])
        j++
      }
      out.add((maxAmp / 32767f).coerceIn(0f, 1f))
      i += chunk
    }
    while (out.size < bins) out.add(0f)
    return out
  }

  private fun circleDrawable(color: Int): GradientDrawable =
    GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(color)
    }

  private fun roundedDrawable(color: Int, radius: Float): GradientDrawable =
    GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = radius
      setColor(color)
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

  private fun blend(from: Int, to: Int, amount: Float): Int {
    val t = amount.coerceIn(0f, 1f)
    val inv = 1f - t
    return Color.argb(
      (Color.alpha(from) * inv + Color.alpha(to) * t).roundToInt(),
      (Color.red(from) * inv + Color.red(to) * t).roundToInt(),
      (Color.green(from) * inv + Color.green(to) * t).roundToInt(),
      (Color.blue(from) * inv + Color.blue(to) * t).roundToInt(),
    )
  }
}

internal enum class ChatNativeInputGlyph {
  ATTACH,
  MIC,
  SEND,
  RECORDING_DOT,
}

internal class ChatNativeInputGlyphView(
  context: Context,
) : View(context) {
  var glyph: ChatNativeInputGlyph = ChatNativeInputGlyph.MIC
    set(value) {
      if (field == value) return
      field = value
      invalidate()
    }

  var tintColor: Int = Color.WHITE
    set(value) {
      if (field == value) return
      field = value
      stroke.color = value
      fill.color = value
      invalidate()
    }

  private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    color = tintColor
    strokeCap = Paint.Cap.ROUND
    strokeJoin = Paint.Join.ROUND
    strokeWidth = dpF(1.9f)
  }
  private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = tintColor
  }
  private val path = Path()
  private val rect = RectF()

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val side = min(width, height).toFloat()
    if (side <= 0f) return
    val left = (width - side) * 0.5f
    val top = (height - side) * 0.5f
    canvas.save()
    canvas.translate(left, top)
    when (glyph) {
      ChatNativeInputGlyph.ATTACH -> drawAttach(canvas, side)
      ChatNativeInputGlyph.MIC -> drawMic(canvas, side)
      ChatNativeInputGlyph.SEND -> drawSend(canvas, side)
      ChatNativeInputGlyph.RECORDING_DOT -> drawRecordingDot(canvas, side)
    }
    canvas.restore()
  }

  private fun drawRecordingDot(canvas: Canvas, side: Float) {
    canvas.drawCircle(side * 0.5f, side * 0.5f, side * 0.18f, fill)
  }

  private fun drawMic(canvas: Canvas, side: Float) {
    val cx = side * 0.5f
    rect.set(side * 0.34f, side * 0.20f, side * 0.66f, side * 0.58f)
    canvas.drawRoundRect(rect, side * 0.15f, side * 0.15f, stroke)
    canvas.drawLine(cx, side * 0.58f, cx, side * 0.72f, stroke)
    path.reset()
    path.moveTo(side * 0.28f, side * 0.56f)
    path.quadTo(cx, side * 0.80f, side * 0.72f, side * 0.56f)
    canvas.drawPath(path, stroke)
    canvas.drawLine(side * 0.38f, side * 0.82f, side * 0.62f, side * 0.82f, stroke)
  }

  private fun drawSend(canvas: Canvas, side: Float) {
    path.reset()
    path.moveTo(side * 0.20f, side * 0.50f)
    path.lineTo(side * 0.78f, side * 0.24f)
    path.lineTo(side * 0.58f, side * 0.78f)
    path.lineTo(side * 0.50f, side * 0.58f)
    path.close()
    canvas.drawPath(path, fill)

    val trail = Paint(stroke).apply { color = withAlpha(tintColor, 0.34f) }
    path.reset()
    path.moveTo(side * 0.30f, side * 0.50f)
    path.lineTo(side * 0.53f, side * 0.57f)
    path.lineTo(side * 0.70f, side * 0.34f)
    canvas.drawPath(path, trail)
  }

  private fun drawAttach(canvas: Canvas, side: Float) {
    path.reset()
    path.moveTo(side * 0.64f, side * 0.28f)
    path.quadTo(side * 0.80f, side * 0.43f, side * 0.64f, side * 0.59f)
    path.lineTo(side * 0.43f, side * 0.80f)
    path.quadTo(side * 0.26f, side * 0.96f, side * 0.10f, side * 0.80f)
    path.quadTo(side * -0.02f, side * 0.68f, side * 0.10f, side * 0.54f)
    path.lineTo(side * 0.47f, side * 0.18f)
    path.quadTo(side * 0.60f, side * 0.05f, side * 0.74f, side * 0.18f)
    path.quadTo(side * 0.86f, side * 0.31f, side * 0.74f, side * 0.44f)
    path.lineTo(side * 0.37f, side * 0.81f)
    canvas.drawPath(path, stroke)
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).roundToInt()
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )
}
