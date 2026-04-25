package com.mohammadshayani.vibe.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.Space
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.mohammadshayani.vibe.R
import com.mohammadshayani.vibe.session.AppSessionConfig
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class StoryActivity : AppCompatActivity() {

  private enum class StoryMode {
    MAIN,
    EDIT,
  }

  private lateinit var palette: AppThemePalette
  private lateinit var root: FrameLayout
  private lateinit var cameraPreviewView: PreviewView
  private lateinit var selectedBackdropView: ImageView
  private lateinit var permissionCard: LinearLayout
  private lateinit var mainPage: FrameLayout
  private lateinit var editPage: FrameLayout
  private lateinit var editPreviewCard: FrameLayout
  private lateinit var previewImageView: ImageView
  private lateinit var captionInput: EditText
  private lateinit var mainCloseButton: TextView
  private lateinit var mainFlipButton: TextView
  private lateinit var galleryQuickButton: TextView
  private lateinit var shutterButton: FrameLayout
  private lateinit var editCloseButton: TextView
  private lateinit var retakeButton: TextView
  private lateinit var saveButton: TextView
  private lateinit var aiEditButton: TextView
  private lateinit var nextButton: MaterialButton
  private lateinit var loadingIndicator: ProgressBar
  private lateinit var cameraCardContainer: FrameLayout

  private val httpClient = OkHttpClient()
  private val mainHandler = Handler(Looper.getMainLooper())
  private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

  private var currentMode = StoryMode.MAIN
  private var selectedImageUri: Uri? = null
  private var cameraProvider: ProcessCameraProvider? = null
  private var imageCapture: ImageCapture? = null
  private var cameraSelector: CameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
  private var selectedAudience = "everyone"
  private var selectedDuration = 24

  private val pickImageLauncher =
    registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
      if (result.resultCode == Activity.RESULT_OK) {
        result.data?.data?.let(::handleImageSelected)
      }
    }

  private val requestCameraPermissionLauncher =
    registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
      if (granted) {
        bindCameraPreviewIfPossible()
      } else {
        updatePermissionCard()
        showPermissionSettingsDialog(
          "Camera Permission Required",
          "Allow camera access to capture a story from the main page."
        )
      }
    }

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    overridePendingTransition(android.R.anim.slide_in_left, android.R.anim.slide_out_right)

    window.setFlags(
      WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
      WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
    )

    palette = resolveAppThemePalette(this)
    root = FrameLayout(this).apply {
      setBackgroundColor(Color.BLACK)
    }

    buildViewHierarchy()
    setContentView(root)
    setMode(StoryMode.MAIN)
  }

  override fun onStart() {
    super.onStart()
    if (currentMode == StoryMode.MAIN) {
      ensureCameraReady()
    }
  }

  override fun onStop() {
    super.onStop()
    unbindCamera()
  }

  override fun onDestroy() {
    super.onDestroy()
    unbindCamera()
    cameraExecutor.shutdown()
  }

  override fun finish() {
    super.finish()
    overridePendingTransition(android.R.anim.slide_in_left, android.R.anim.slide_out_right)
  }

  private fun buildViewHierarchy() {
    cameraPreviewView = PreviewView(this).apply {
      id = View.generateViewId()
      implementationMode = PreviewView.ImplementationMode.COMPATIBLE
      scaleType = PreviewView.ScaleType.FILL_CENTER
      setBackgroundColor(Color.BLACK)
    }

    selectedBackdropView = ImageView(this).apply {
      layoutParams =
        FrameLayout.LayoutParams(
          FrameLayout.LayoutParams.MATCH_PARENT,
          FrameLayout.LayoutParams.MATCH_PARENT
        )
      scaleType = ImageView.ScaleType.CENTER_CROP
      alpha = 0.18f
      visibility = View.GONE
    }
    root.addView(selectedBackdropView)

    root.addView(
      View(this).apply {
        layoutParams =
          FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
          )
        background =
          GradientDrawable(
            GradientDrawable.Orientation.TOP_BOTTOM,
            intArrayOf(
              Color.argb(168, 0, 0, 0),
              Color.argb(72, 0, 0, 0),
              Color.argb(184, 0, 0, 0)
            )
          )
      }
    )

    mainPage = buildMainPage()
    editPage = buildEditPage()
    permissionCard = buildPermissionCard()

    root.addView(mainPage)
    root.addView(editPage)
    root.addView(permissionCard)

    loadingIndicator = ProgressBar(this).apply {
      layoutParams =
        FrameLayout.LayoutParams(
          FrameLayout.LayoutParams.WRAP_CONTENT,
          FrameLayout.LayoutParams.WRAP_CONTENT,
          Gravity.CENTER
        )
      visibility = View.GONE
    }
    root.addView(loadingIndicator)
  }

  private fun buildMainPage(): FrameLayout {
    val page = FrameLayout(this).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT
      )
    }

    val safeTop = safeTopInset().toFloat()
    val horizontalMargin = dp(10f)
    val cardTop = (safeTop + dp(10f).toFloat()).toInt()

    cameraCardContainer = FrameLayout(this).apply {
      background = roundedPanelDrawable(Color.argb(15, 255, 255, 255), Color.argb(20, 255, 255, 255), 32f)
      clipToOutline = true
      setPadding(dp(1f), dp(1f), dp(1f), dp(1f))
    }

    val displayMetrics = resources.displayMetrics
    val cardHeight = (displayMetrics.heightPixels * 0.65f).toInt()

    page.addView(
      cameraCardContainer,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        cardHeight
      ).apply {
        topMargin = cardTop
        marginStart = horizontalMargin
        marginEnd = horizontalMargin
      }
    )

    cameraCardContainer.addView(
      cameraPreviewView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT
      )
    )

    val topBar = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      setPadding(dp(14f), dp(14f), dp(14f), 0)
    }

    mainCloseButton = overlayCircleButton("X").apply { setOnClickListener { finish() } }
    mainFlipButton = overlayCircleButton("FLIP").apply { setOnClickListener { flipCamera() } }

    topBar.addView(mainCloseButton, LinearLayout.LayoutParams(dp(44f), dp(44f)))
    topBar.addView(Space(this), LinearLayout.LayoutParams(0, 0, 1f))
    topBar.addView(mainFlipButton, LinearLayout.LayoutParams(dp(60f), dp(44f)))

    cameraCardContainer.addView(
      topBar,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.TOP
      )
    )

    val centerStack = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
    }

    centerStack.addView(
      TextView(this).apply {
        text = "Story"
        setTextColor(Color.WHITE)
        textSize = 14f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        background = capsuleDrawable(Color.argb(58, 255, 255, 255), Color.TRANSPARENT)
        setPadding(dp(14f), dp(8f), dp(14f), dp(8f))
      }
    )

    cameraCardContainer.addView(
      centerStack,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER
      )
    )

    val bottomDock = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      setPadding(dp(22f), 0, dp(22f), safeBottomInset() + dp(24f))
    }

    val photoLabel = TextView(this).apply {
      text = "Photo"
      setTextColor(Color.WHITE)
      textSize = 13f
      typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      background = capsuleDrawable(Color.argb(42, 255, 255, 255), Color.TRANSPARENT)
      setPadding(dp(16f), dp(8f), dp(16f), dp(8f))
    }
    bottomDock.addView(photoLabel)
    bottomDock.addView(spaceView(16f))

    val captureRow = FrameLayout(this).apply {
      layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
    }

    galleryQuickButton = overlayCircleButton("G").apply { setOnClickListener { launchGallery() } }
    captureRow.addView(galleryQuickButton, FrameLayout.LayoutParams(dp(52f), dp(52f), Gravity.START or Gravity.CENTER_VERTICAL))

    shutterButton = FrameLayout(this).apply {
      background = circleDrawable(Color.WHITE)
      setOnClickListener { capturePhoto() }
    }
    shutterButton.addView(View(this).apply { background = circleDrawable(Color.BLACK) }, FrameLayout.LayoutParams(dp(58f), dp(58f), Gravity.CENTER))
    captureRow.addView(shutterButton, FrameLayout.LayoutParams(dp(78f), dp(78f), Gravity.CENTER))

    val importBtn = TextView(this).apply {
      text = "Import"
      setTextColor(Color.WHITE)
      textSize = 13f
      gravity = Gravity.CENTER
      background = capsuleDrawable(Color.argb(42, 255, 255, 255), Color.TRANSPARENT)
      setPadding(dp(16f), dp(14f), dp(16f), dp(14f))
      setOnClickListener { launchGallery() }
    }
    captureRow.addView(importBtn, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.END or Gravity.CENTER_VERTICAL))
    bottomDock.addView(captureRow)

    page.addView(
      bottomDock,
      FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM)
    )

    return page
  }

  private fun buildEditPage(): FrameLayout {
    val page =
      FrameLayout(this).apply {
        layoutParams =
          FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
          )
        visibility = View.GONE
      }

    val topBar =
      LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(16f), safeTopInset() + dp(10f), dp(16f), 0)
      }

    editCloseButton =
      overlayCircleButton("X").apply {
        setOnClickListener { confirmDiscard() }
      }
    retakeButton =
      overlayCircleButton("RETAKE").apply {
        setOnClickListener { setMode(StoryMode.MAIN) }
      }
    topBar.addView(editCloseButton, LinearLayout.LayoutParams(dp(44f), dp(44f)))
    topBar.addView(Space(this), LinearLayout.LayoutParams(0, 0, 1f))
    topBar.addView(retakeButton, LinearLayout.LayoutParams(dp(84f), dp(44f)))
    page.addView(
      topBar,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.TOP
      )
    )

    editPreviewCard =
      FrameLayout(this).apply {
        background = roundedPanelDrawable(Color.argb(18, 255, 255, 255), Color.argb(38, 255, 255, 255), 28f)
        clipToOutline = false
        setPadding(dp(10f), dp(10f), dp(10f), dp(10f))
      }

    previewImageView =
      ImageView(this).apply {
        scaleType = ImageView.ScaleType.CENTER_CROP
        background = roundedPanelDrawable(Color.parseColor("#101014"), Color.TRANSPARENT, 22f)
      }
    editPreviewCard.addView(
      previewImageView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT
      )
    )

    val previewActions =
      LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = roundedPanelDrawable(Color.argb(116, 10, 10, 12), Color.TRANSPARENT, 22f)
        setPadding(dp(6f), dp(6f), dp(6f), dp(6f))
      }

    saveButton =
      actionChip("Save").apply {
        setOnClickListener { saveToDraftToast("Saved a local copy") }
      }
    aiEditButton =
      actionChip("AI").apply {
        setOnClickListener { showAIEditPrompt() }
      }
    previewActions.addView(saveButton)
    previewActions.addView(spaceView(6f, horizontal = true))
    previewActions.addView(aiEditButton)
    editPreviewCard.addView(
      previewActions,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.TOP or Gravity.END
      ).apply {
        topMargin = dp(14f)
        marginEnd = dp(14f)
      }
    )

    page.addView(
      editPreviewCard,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        dp(540f),
        Gravity.TOP or Gravity.CENTER_HORIZONTAL
      ).apply {
        topMargin = safeTopInset() + dp(70f)
        marginStart = dp(12f)
        marginEnd = dp(12f)
      }
    )

    val bottomComposer =
      LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(12f), dp(10f), dp(12f), safeBottomInset() + dp(16f))
      }

    val captionChrome =
      FrameLayout(this).apply {
        background = roundedPanelDrawable(Color.argb(162, 10, 10, 12), Color.argb(28, 255, 255, 255), 24f)
      }
    captionInput =
      EditText(this).apply {
        hint = "Add a caption"
        setHintTextColor(Color.argb(160, 255, 255, 255))
        setTextColor(Color.WHITE)
        background = null
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        setPadding(dp(16f), dp(14f), dp(16f), dp(14f))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
      }
    captionChrome.addView(
      captionInput,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT
      )
    )
    bottomComposer.addView(
      captionChrome,
      LinearLayout.LayoutParams(0, FrameLayout.LayoutParams.WRAP_CONTENT, 1f)
    )

    nextButton =
      MaterialButton(this).apply {
        text = "Next"
        isAllCaps = false
        setTextColor(Color.WHITE)
        setBackgroundColor(Color.parseColor("#007AFF"))
        cornerRadius = dp(22f)
        insetTop = 0
        insetBottom = 0
        setPadding(dp(18f), dp(14f), dp(18f), dp(14f))
        setOnClickListener { showPublishModal() }
      }
    bottomComposer.addView(
      nextButton,
      LinearLayout.LayoutParams(dp(92f), dp(52f)).apply { marginStart = dp(10f) }
    )

    page.addView(
      bottomComposer,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.BOTTOM
      )
    )

    return page
  }

  private fun buildPermissionCard(): LinearLayout {
    val card =
      LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        background = roundedPanelDrawable(Color.argb(214, 18, 18, 22), Color.argb(34, 255, 255, 255), 26f)
        setPadding(dp(22f), dp(22f), dp(22f), dp(22f))
        visibility = View.GONE
      }

    card.addView(
      TextView(this).apply {
        text = "Camera permission needed"
        setTextColor(Color.WHITE)
        textSize = 16f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      }
    )
    card.addView(spaceView(8f))
    card.addView(
      TextView(this).apply {
        text = "Grant access to use the story camera from the main page."
        setTextColor(Color.argb(210, 255, 255, 255))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        gravity = Gravity.CENTER
      }
    )
    card.addView(spaceView(16f))
    card.addView(
      MaterialButton(this).apply {
        text = "Grant Permission"
        isAllCaps = false
        setTextColor(Color.BLACK)
        setBackgroundColor(Color.WHITE)
        cornerRadius = dp(22f)
        insetTop = 0
        insetBottom = 0
        setOnClickListener { requestCameraPermissionLauncher.launch(Manifest.permission.CAMERA) }
      },
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        dp(48f)
      )
    )

    return card
  }

  private fun setMode(mode: StoryMode) {
    currentMode = mode
    val editing = mode == StoryMode.EDIT && selectedImageUri != null

    mainPage.visibility = if (mode == StoryMode.MAIN) View.VISIBLE else View.GONE
    editPage.visibility = if (editing) View.VISIBLE else View.GONE
    cameraPreviewView.visibility = if (mode == StoryMode.MAIN) View.VISIBLE else View.GONE
    selectedBackdropView.visibility = if (editing) View.VISIBLE else View.GONE

    if (mode == StoryMode.MAIN) {
      ensureCameraReady()
    } else {
      permissionCard.visibility = View.GONE
      unbindCamera()
    }
  }

  private fun ensureCameraReady() {
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
      permissionCard.visibility = View.GONE
      bindCameraPreviewIfPossible()
    } else {
      updatePermissionCard()
    }
  }

  private fun updatePermissionCard() {
    permissionCard.visibility = if (currentMode == StoryMode.MAIN) View.VISIBLE else View.GONE
  }

  private fun bindCameraPreviewIfPossible() {
    if (currentMode != StoryMode.MAIN) return
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
      updatePermissionCard()
      return
    }

    setLoading(true)
    val future = ProcessCameraProvider.getInstance(this)
    future.addListener(
      {
        try {
          val provider = future.get()
          cameraProvider = provider
          provider.unbindAll()

          val preview =
            Preview.Builder().build().also {
              it.setSurfaceProvider(cameraPreviewView.surfaceProvider)
            }
          imageCapture =
            ImageCapture.Builder()
              .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
              .build()

          provider.bindToLifecycle(this, cameraSelector, preview, imageCapture)
          permissionCard.visibility = View.GONE
        } catch (error: Throwable) {
          permissionCard.visibility = View.VISIBLE
          Toast.makeText(this, "Camera unavailable", Toast.LENGTH_SHORT).show()
        } finally {
          setLoading(false)
        }
      },
      ContextCompat.getMainExecutor(this)
    )
  }

  private fun unbindCamera() {
    try {
      cameraProvider?.unbindAll()
    } catch (_: Throwable) {
    }
    cameraProvider = null
    imageCapture = null
  }

  private fun flipCamera() {
    if (currentMode != StoryMode.MAIN) return
    cameraSelector =
      if (cameraSelector == CameraSelector.DEFAULT_BACK_CAMERA) {
        CameraSelector.DEFAULT_FRONT_CAMERA
      } else {
        CameraSelector.DEFAULT_BACK_CAMERA
      }
    bindCameraPreviewIfPossible()
  }

  private fun capturePhoto() {
    val capture = imageCapture
    if (capture == null) {
      ensureCameraReady()
      return
    }

    val output = File(cacheDir, "story-camera-${UUID.randomUUID()}.jpg")
    val outputOptions = ImageCapture.OutputFileOptions.Builder(output).build()
    setLoading(true)
    capture.takePicture(
      outputOptions,
      cameraExecutor,
      object : ImageCapture.OnImageSavedCallback {
        override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
          mainHandler.post {
            setLoading(false)
            handleImageSelected(Uri.fromFile(output))
          }
        }

        override fun onError(exception: ImageCaptureException) {
          mainHandler.post {
            setLoading(false)
            Toast.makeText(this@StoryActivity, "Capture failed", Toast.LENGTH_SHORT).show()
          }
        }
      }
    )
  }

  private fun launchGallery() {
    pickImageLauncher.launch(
      Intent(Intent.ACTION_GET_CONTENT).apply {
        type = "image/*"
      }
    )
  }

  private fun handleImageSelected(uri: Uri) {
    selectedImageUri = uri
    selectedBackdropView.setImageURI(uri)
    previewImageView.setImageURI(uri)
    setMode(StoryMode.EDIT)
  }

  private fun confirmDiscard() {
    MaterialAlertDialogBuilder(this)
      .setTitle("Discard story?")
      .setMessage("Your current edits will be removed.")
      .setPositiveButton("Discard") { _, _ ->
        selectedImageUri = null
        captionInput.setText("")
        selectedBackdropView.setImageDrawable(null)
        previewImageView.setImageDrawable(null)
        setMode(StoryMode.MAIN)
      }
      .setNegativeButton("Cancel", null)
      .show()
  }

  private fun showAIEditPrompt() {
    val input =
      EditText(this).apply {
        hint = "Describe the edit"
        setTextColor(Color.BLACK)
        setText(captionInput.text?.toString().orEmpty())
      }
    MaterialAlertDialogBuilder(this)
      .setTitle("AI Edit")
      .setMessage("Describe how you want to change this story.")
      .setView(
        FrameLayout(this).apply {
          setPadding(dp(20f), dp(10f), dp(20f), dp(10f))
          addView(input)
        }
      )
      .setPositiveButton("Generate") { _, _ ->
        val prompt = input.text?.toString()?.trim().orEmpty()
        if (prompt.isNotEmpty()) {
          performAIEdit(prompt)
        }
      }
      .setNegativeButton("Cancel", null)
      .show()
  }

  private fun performAIEdit(prompt: String) {
    setLoading(true)
    mainHandler.postDelayed({
      setLoading(false)
      Toast.makeText(this, "AI edit queued: $prompt", Toast.LENGTH_SHORT).show()
    }, 1200)
  }

  private fun showPublishModal() {
    val bottomSheet = BottomSheetDialog(this, R.style.ThemeOverlay_Vibe_BottomSheetDialog)

    val container =
      LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20f), dp(18f), dp(20f), dp(28f))
        background = roundedPanelDrawable(palette.backgroundColor, Color.TRANSPARENT, 32f)
      }

    container.addView(
      TextView(this).apply {
        text = "Publish Story"
        setTextColor(palette.textColor)
        textSize = 20f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      }
    )

    container.addView(spaceView(18f))
    container.addView(sheetSectionLabel("Audience"))
    container.addView(spaceView(10f))
    val audienceRow =
      LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
      }
    val audienceButtons = linkedMapOf<String, MaterialButton>()
    listOf(
      "everyone" to "Everyone",
      "contacts" to "Contacts",
      "close_friends" to "Close Friends"
    ).forEach { (value, label) ->
      val button =
        publishChip(label).apply {
          setOnClickListener {
            selectedAudience = value
            audienceButtons.forEach { (key, item) ->
              item.applyPublishChipSelected(key == selectedAudience)
            }
          }
        }
      audienceButtons[value] = button
      audienceRow.addView(button, LinearLayout.LayoutParams(0, dp(42f), 1f).apply {
        if (audienceRow.childCount > 0) marginStart = dp(8f)
      })
    }
    audienceButtons.forEach { (key, button) ->
      button.applyPublishChipSelected(key == selectedAudience)
    }
    container.addView(audienceRow)

    container.addView(spaceView(18f))
    container.addView(sheetSectionLabel("Duration"))
    container.addView(spaceView(10f))
    val durationRow =
      LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
      }
    val durationButtons = linkedMapOf<Int, MaterialButton>()
    listOf(12, 24, 48).forEach { duration ->
      val button =
        publishChip("${duration}h").apply {
          setOnClickListener {
            selectedDuration = duration
            durationButtons.forEach { (key, item) ->
              item.applyPublishChipSelected(key == selectedDuration)
            }
          }
        }
      durationButtons[duration] = button
      durationRow.addView(button, LinearLayout.LayoutParams(0, dp(42f), 1f).apply {
        if (durationRow.childCount > 0) marginStart = dp(8f)
      })
    }
    durationButtons.forEach { (key, button) ->
      button.applyPublishChipSelected(key == selectedDuration)
    }
    container.addView(durationRow)

    container.addView(spaceView(22f))
    val actionRow =
      LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
      }
    actionRow.addView(
      publishChip("Draft").apply {
        applyPublishChipSelected(false)
        setOnClickListener {
          bottomSheet.dismiss()
          saveToDraftToast("Saved to Drafts")
          finish()
        }
      },
      LinearLayout.LayoutParams(0, dp(46f), 1f).apply { marginEnd = dp(8f) }
    )
    actionRow.addView(
      publishChip("Publish").apply {
        applyPublishChipSelected(true)
        setOnClickListener {
          bottomSheet.dismiss()
          publishStory()
        }
      },
      LinearLayout.LayoutParams(0, dp(46f), 1f)
    )
    container.addView(actionRow)

    bottomSheet.setContentView(container)
    bottomSheet.window?.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))
    bottomSheet.show()
  }

  private fun publishStory() {
    val uri = selectedImageUri ?: return
    val config = AppSessionConfig.current(this)
    if (config == null) {
      Toast.makeText(this, "Not authenticated", Toast.LENGTH_SHORT).show()
      return
    }

    setLoading(true)
    Thread {
      try {
        val tempFile = File(cacheDir, "story_upload_${System.currentTimeMillis()}.jpg")
        contentResolver.openInputStream(uri)?.use { input ->
          FileOutputStream(tempFile).use { output ->
            input.copyTo(output)
          }
        } ?: throw IOException("Unable to read story media")

        val base = config.apiBaseUrl.trim().trimEnd('/')
        val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"

        val uploadRequest =
          Request.Builder()
            .url("$pathBase/media/upload")
            .post(
              MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart(
                  "file",
                  tempFile.name,
                  tempFile.asRequestBody("image/jpeg".toMediaTypeOrNull())
                )
                .build()
            )
            .header("Authorization", "Bearer ${config.authToken}")
            .header("ngrok-skip-browser-warning", "true")
            .build()

        val uploadResponse = httpClient.newCall(uploadRequest).execute()
        val uploadBody = uploadResponse.body?.string()
        if (!uploadResponse.isSuccessful || uploadBody.isNullOrBlank()) {
          throw IOException("Failed to upload media: ${uploadResponse.code}")
        }

        val uploadJson = JSONObject(uploadBody)
        val uploadedUri = uploadJson.optString("uri").ifBlank { uploadJson.optString("url") }
        if (uploadedUri.isBlank()) {
          throw IOException("Upload response missing media URL")
        }

        val body =
          JSONObject().apply {
            put("user_id", config.userId)
            put("media_url", uploadedUri)
            put("media_type", "image")
            put("visibility", selectedAudience)
            put("visible_to", JSONArray())
            put("hidden_from", JSONArray())
            put("duration", selectedDuration)
            val caption = captionInput.text?.toString()?.trim().orEmpty()
            if (caption.isNotEmpty()) {
              put("caption", caption)
            }
          }

        val publishRequest =
          Request.Builder()
            .url("$pathBase/stories")
            .post(body.toString().toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
            .header("Authorization", "Bearer ${config.authToken}")
            .header("Content-Type", "application/json")
            .header("ngrok-skip-browser-warning", "true")
            .build()

        val publishResponse = httpClient.newCall(publishRequest).execute()
        val publishBody = publishResponse.body?.string()
        if (!publishResponse.isSuccessful) {
          throw IOException(
            if (publishBody.isNullOrBlank()) {
              "Failed to publish story: ${publishResponse.code}"
            } else {
              publishBody
            }
          )
        }

        mainHandler.post {
          setLoading(false)
          Toast.makeText(this, "Story published", Toast.LENGTH_SHORT).show()
          finish()
        }
      } catch (error: Exception) {
        mainHandler.post {
          setLoading(false)
          Toast.makeText(this, error.message ?: "Story publish failed", Toast.LENGTH_LONG).show()
        }
      }
    }.start()
  }

  private fun setLoading(isLoading: Boolean) {
    loadingIndicator.visibility = if (isLoading) View.VISIBLE else View.GONE
    shutterButton.isEnabled = !isLoading
    galleryQuickButton.isEnabled = !isLoading
    mainFlipButton.isEnabled = !isLoading
    retakeButton.isEnabled = !isLoading
    saveButton.isEnabled = !isLoading
    aiEditButton.isEnabled = !isLoading
    nextButton.isEnabled = !isLoading
    editCloseButton.isEnabled = !isLoading
    mainCloseButton.isEnabled = !isLoading
  }

  private fun showPermissionSettingsDialog(title: String, message: String) {
    MaterialAlertDialogBuilder(this)
      .setTitle(title)
      .setMessage(message)
      .setPositiveButton("Open Settings") { _, _ ->
        startActivity(
          Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
          }
        )
      }
      .setNegativeButton("Cancel", null)
      .show()
  }

  private fun saveToDraftToast(message: String) {
    Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
  }

  private fun sheetSectionLabel(text: String): TextView {
    return TextView(this).apply {
      this.text = text
      setTextColor(palette.secondaryTextColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
  }

  private fun publishChip(label: String): MaterialButton {
    return MaterialButton(this).apply {
      text = label
      isAllCaps = false
      cornerRadius = dp(18f)
      insetTop = 0
      insetBottom = 0
      strokeWidth = 0
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    }
  }

  private fun MaterialButton.applyPublishChipSelected(selected: Boolean) {
    if (selected) {
      setBackgroundColor(Color.parseColor("#007AFF"))
      setTextColor(Color.WHITE)
    } else {
      setBackgroundColor(palette.inputColor)
      setTextColor(palette.textColor)
    }
  }

  private fun overlayCircleButton(label: String): TextView {
    return TextView(this).apply {
      text = label
      gravity = Gravity.CENTER
      setTextColor(Color.WHITE)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, if (label.length > 2) 11f else 13f)
      typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      background = capsuleDrawable(Color.argb(96, 0, 0, 0), Color.TRANSPARENT)
    }
  }

  private fun actionChip(label: String): TextView {
    return TextView(this).apply {
      text = label
      gravity = Gravity.CENTER
      setTextColor(Color.WHITE)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      background = capsuleDrawable(Color.argb(44, 255, 255, 255), Color.TRANSPARENT)
      setPadding(dp(12f), dp(10f), dp(12f), dp(10f))
    }
  }

  private fun circleDrawable(fillColor: Int): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(fillColor)
    }
  }

  private fun capsuleDrawable(fillColor: Int, strokeColor: Int): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = dp(22f).toFloat()
      setColor(fillColor)
      if (strokeColor != Color.TRANSPARENT) {
        setStroke(dp(1f), strokeColor)
      }
    }
  }

  private fun roundedPanelDrawable(fillColor: Int, strokeColor: Int, radiusDp: Float): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = dp(radiusDp).toFloat()
      setColor(fillColor)
      if (strokeColor != Color.TRANSPARENT) {
        setStroke(dp(1f), strokeColor)
      }
    }
  }

  private fun spaceView(value: Float, horizontal: Boolean = false): View {
    return Space(this).apply {
      layoutParams =
        if (horizontal) {
          LinearLayout.LayoutParams(dp(value), 1)
        } else {
          LinearLayout.LayoutParams(1, dp(value))
        }
    }
  }

  private fun safeTopInset(): Int {
    return resources.getIdentifier("status_bar_height", "dimen", "android")
      .takeIf { it > 0 }
      ?.let(resources::getDimensionPixelSize)
      ?: dp(24f)
  }

  private fun safeBottomInset(): Int {
    return resources.getIdentifier("navigation_bar_height", "dimen", "android")
      .takeIf { it > 0 }
      ?.let(resources::getDimensionPixelSize)
      ?: dp(16f)
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
}
