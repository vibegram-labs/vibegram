package expo.modules.vibechatnative

import android.Manifest
import android.app.Activity
import android.app.Dialog
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.text.InputType
import android.text.TextUtils
import android.util.Log
import android.util.LruCache
import android.util.Size
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.animation.PathInterpolator
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import expo.modules.kotlin.AppContext
import java.io.File
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal class ChatAttachmentMenuController(
  private val context: Context,
  private val appContext: AppContext? = null,
) {
  companion object {
    private const val TAG = "ChatAttachmentMenu"
  }

  var onSelectImage: ((String, String?) -> Unit)? = null
  var onSelectFile: ((String, String, Long?, String?, String?) -> Unit)? = null
  var onSelectLocation: ((Double, Double, String?) -> Unit)? = null

  private enum class AttachmentTab {
    GALLERY,
    FILE,
    LOCATION,
  }

  private data class GalleryMediaItem(
    val uri: Uri,
  )

  private data class FileSelection(
    val uri: Uri,
    val name: String,
    val size: Long?,
    val mimeType: String?,
  )

  private var dialog: Dialog? = null
  private var rootView: FrameLayout? = null
  private var scrimView: View? = null
  private var sheetView: FrameLayout? = null
  private var contentHost: FrameLayout? = null
  private var bottomSharedSurface: FrameLayout? = null
  private var tabsContainer: LinearLayout? = null
  private var inputContainer: LinearLayout? = null
  private var inputBackButton: FrameLayout? = null
  private var closeButton: FrameLayout? = null
  private var captionInput: EditText? = null
  private var safeBottomInsetPx: Int = 0
  private var isInputMode = false

  private var galleryPage: LinearLayout? = null
  private var filePage: LinearLayout? = null
  private var locationPage: LinearLayout? = null
  private var fullCameraPage: FrameLayout? = null

  private var galleryTileHost: AspectRatioFrameLayout? = null
  private var galleryTopImagePrimary: SquareImageTile? = null
  private var galleryTopImageSecondary: SquareImageTile? = null
  private var galleryPermissionLabel: TextView? = null
  private var galleryRecycler: RecyclerView? = null

  private var fullCameraHost: FrameLayout? = null
  private var cameraFlipButton: FrameLayout? = null
  private var cameraCaptureButton: FrameLayout? = null
  private var cameraCloseButton: FrameLayout? = null

  private var galleryTabButton: TextView? = null
  private var fileTabButton: TextView? = null
  private var locationTabButton: TextView? = null

  private val galleryAllItems = ArrayList<GalleryMediaItem>()
  private val galleryGridItems = ArrayList<GalleryMediaItem>()
  private var galleryGridAdapter: GalleryGridAdapter? = null

  private var activeTab: AttachmentTab = AttachmentTab.GALLERY
  private var isDismissing = false
  private var isFullCameraVisible = false
  private var cameraSelector: CameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

  private val uiHandler = Handler(Looper.getMainLooper())
  private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()
  private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
  private val thumbnailCache = object : LruCache<String, Bitmap>(64) {}

  private var cameraPreviewView: PreviewView? = null
  private var cameraPreviewParent: FrameLayout? = null
  private var cameraProvider: ProcessCameraProvider? = null
  private var imageCapture: ImageCapture? = null

  fun show(anchor: View, appearance: ChatListAppearance) {
    if (dialog?.isShowing == true) return
    val activity = resolveActivity() ?: run {
      Log.w(TAG, "show skipped: missing Activity")
      return
    }

    buildDialogUi(activity, appearance)
    dialog?.show()

    rootView?.post {
      animateIn()
      loadGalleryWithPermissionCheck()
      ensureCameraPreviewInTile()
    }

    anchor.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
  }

  fun dismiss(animated: Boolean = true) {
    val showingDialog = dialog ?: return
    if (isDismissing) return
    if (!animated) {
      showingDialog.dismiss()
      return
    }
    isDismissing = true
    val scrim = scrimView
    val sheet = sheetView
    scrim?.animate()
      ?.alpha(0f)
      ?.setDuration(170L)
      ?.start()
    sheet?.animate()
      ?.translationY((sheet.height + dp(36)).toFloat())
      ?.setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
      ?.setDuration(220L)
      ?.withEndAction {
        dialog?.dismiss()
      }
      ?.start()
  }

  private fun buildDialogUi(activity: Activity, appearance: ChatListAppearance) {
    val windowDialog = Dialog(activity, android.R.style.Theme_Translucent_NoTitleBar_Fullscreen)
    windowDialog.setCancelable(true)
    windowDialog.setCanceledOnTouchOutside(false)

    val root = FrameLayout(activity).apply {
      layoutParams = ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      )
      setBackgroundColor(Color.TRANSPARENT)
      clipChildren = false
      clipToPadding = false
    }

    val scrim = View(activity).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
      setBackgroundColor(Color.argb(118, 0, 0, 0))
      alpha = 0f
      setOnClickListener { dismiss(animated = true) }
    }
    root.addView(scrim)

    val isDark = luminance(appearance.wallpaperGradient.firstOrNull() ?: appearance.bubbleThemColor) < 0.42f
    val panelFill = if (isDark) Color.parseColor("#242424") else Color.parseColor("#F5F4F1")
    val panelStroke = if (isDark) Color.argb(24, 255, 255, 255) else Color.argb(20, 24, 28, 34)
    val panelText = if (isDark) Color.WHITE else Color.argb(255, 24, 28, 34)
    val innerFill = Color.WHITE
    val innerText = Color.argb(255, 24, 28, 34)
    val innerSubtext = withAlpha(innerText, 0.66f)
    val accent = Color.parseColor("#7CB8B8")
    val tabActiveFill = withAlpha(accent, 0.24f)
    val tabInactiveFill = Color.TRANSPARENT
    val tabBorder = Color.argb(18, 24, 28, 34)

    val displayHeight = activity.resources.displayMetrics.heightPixels
    val panelHeight = min(max(dp(420), (displayHeight * 0.74f).roundToInt()), displayHeight - dp(26))

    val sheet = FrameLayout(activity).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        panelHeight,
        Gravity.BOTTOM,
      )
      setPadding(dp(12), dp(8), dp(12), dp(12))
      clipChildren = false
      clipToPadding = false
      elevation = 0f
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadii = floatArrayOf(
          dpF(24f), dpF(24f),
          dpF(24f), dpF(24f),
          0f, 0f,
          0f, 0f,
        )
        setColor(panelFill)
        setStroke(max(1, dp(1)), panelStroke)
      }
      translationY = panelHeight.toFloat()
      alpha = 1f
    }
    root.addView(sheet)

    val titleView = TextView(activity).apply {
      text = "Attachments"
      setTextColor(panelText)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
      typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    sheet.addView(
      titleView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        gravity = Gravity.START or Gravity.TOP
        leftMargin = dp(6)
        topMargin = dp(10)
      },
    )

    closeButton = FrameLayout(activity).apply {
      layoutParams = FrameLayout.LayoutParams(dp(34), dp(34))
      background = circleDrawable(withAlpha(panelText, 0.12f))
      setOnClickListener { dismiss(animated = true) }
      setOnTouchListener(::handleButtonTouchFeedback)
    }.also { close ->
      close.addView(
        TextView(activity).apply {
          text = "\u2715"
          gravity = Gravity.CENTER
          setTextColor(withAlpha(panelText, 0.92f))
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
          typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        },
        FrameLayout.LayoutParams(
          FrameLayout.LayoutParams.MATCH_PARENT,
          FrameLayout.LayoutParams.MATCH_PARENT,
        ),
      )
    }
    sheet.addView(
      closeButton,
      FrameLayout.LayoutParams(dp(34), dp(34)).apply {
        gravity = Gravity.END or Gravity.TOP
        rightMargin = dp(6)
        topMargin = dp(6)
      },
    )

    contentHost = FrameLayout(activity).apply {
      clipChildren = false
      clipToPadding = false
      setBackgroundColor(Color.TRANSPARENT)
    }
    sheet.addView(
      contentHost,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ).apply {
        topMargin = dp(52)
        bottomMargin = dp(90)
      },
    )

    bottomSharedSurface = FrameLayout(activity).apply {
      clipChildren = false
      clipToPadding = false
      setPadding(dp(8), dp(6), dp(8), dp(6))
      background = roundedDrawable(innerFill, dpF(18f), tabBorder, dpF(1f))
      elevation = 0f
    }
    sheet.addView(
      bottomSharedSurface,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        dp(56),
        Gravity.BOTTOM,
      ),
    )

    val tabContainer = LinearLayout(activity).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
      background = roundedDrawable(Color.TRANSPARENT, dpF(14f))
      setPadding(dp(2), dp(2), dp(2), dp(2))
      elevation = 0f
    }
    bottomSharedSurface?.addView(
      tabContainer,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    tabsContainer = tabContainer

    galleryTabButton = buildTabButton(activity, "Gallery", R.drawable.ic_attach_tab_gallery, innerText).apply {
      setOnClickListener { switchTab(AttachmentTab.GALLERY, animated = true) }
    }
    fileTabButton = buildTabButton(activity, "File", R.drawable.ic_attach_tab_file, innerText).apply {
      setOnClickListener { switchTab(AttachmentTab.FILE, animated = true) }
    }
    locationTabButton = buildTabButton(activity, "Location", R.drawable.ic_attach_tab_location, innerText).apply {
      setOnClickListener { switchTab(AttachmentTab.LOCATION, animated = true) }
    }

    tabContainer.addView(galleryTabButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))
    tabContainer.addView(fileTabButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))
    tabContainer.addView(locationTabButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))

    val inputModeContainer = LinearLayout(activity).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      visibility = View.INVISIBLE
      alpha = 0f
      translationY = dpF(8f)
      setPadding(dp(2), dp(2), dp(2), dp(2))
    }
    bottomSharedSurface?.addView(
      inputModeContainer,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    inputContainer = inputModeContainer

    val switchBack = FrameLayout(activity).apply {
      background = roundedDrawable(withAlpha(innerText, 0.08f), dpF(12f))
      setOnClickListener {
        setInputMode(enabled = false, animated = true, requestFocus = false)
      }
      setOnTouchListener(::handleButtonTouchFeedback)
    }
    switchBack.addView(
      TextView(activity).apply {
        text = "\u2039"
        setTextColor(withAlpha(innerText, 0.92f))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        gravity = Gravity.CENTER
      },
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    inputModeContainer.addView(
      switchBack,
      LinearLayout.LayoutParams(dp(36), LinearLayout.LayoutParams.MATCH_PARENT).apply {
        rightMargin = dp(8)
      },
    )
    inputBackButton = switchBack

    captionInput = EditText(activity).apply {
      hint = "Add a message"
      setSingleLine(true)
      maxLines = 1
      imeOptions = EditorInfo.IME_ACTION_DONE
      inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
      ellipsize = TextUtils.TruncateAt.END
      setBackgroundColor(Color.TRANSPARENT)
      setTextColor(innerText)
      setHintTextColor(withAlpha(innerText, 0.50f))
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
      setPadding(dp(2), dp(0), dp(2), dp(0))
      setOnEditorActionListener { _, actionId, _ ->
        if (actionId == EditorInfo.IME_ACTION_DONE && text.isNullOrBlank()) {
          setInputMode(enabled = false, animated = true, requestFocus = false)
        }
        false
      }
      setOnFocusChangeListener { _, hasFocus ->
        if (!hasFocus && text.isNullOrBlank()) {
          setInputMode(enabled = false, animated = true, requestFocus = false)
        }
      }
    }
    inputModeContainer.addView(
      captionInput,
      LinearLayout.LayoutParams(
        0,
        LinearLayout.LayoutParams.MATCH_PARENT,
        1f,
      ),
    )

    buildGalleryPage(activity, innerText, innerSubtext)
    buildFilePage(activity, innerText, innerSubtext)
    buildLocationPage(activity, innerText, innerSubtext)
    buildFullCameraPage(activity, innerText, innerSubtext, panelFill)

    val host = contentHost ?: return
    host.addView(galleryPage)
    host.addView(filePage)
    host.addView(locationPage)
    host.addView(fullCameraPage)

    filePage?.visibility = View.GONE
    locationPage?.visibility = View.GONE
    fullCameraPage?.visibility = View.GONE
    activeTab = AttachmentTab.GALLERY
    updateTabVisuals(innerText, tabActiveFill, tabInactiveFill, tabBorder)
    setInputMode(enabled = false, animated = false, requestFocus = false)

    rootView = root
    scrimView = scrim
    sheetView = sheet

    ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
      val systemBottom = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
      val imeBottom = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
      safeBottomInsetPx = max(systemBottom, imeBottom)
      applyBottomInsets()
      insets
    }
    root.requestApplyInsets()
    applyBottomInsets()

    windowDialog.setContentView(root)
    windowDialog.window?.setLayout(
      ViewGroup.LayoutParams.MATCH_PARENT,
      ViewGroup.LayoutParams.MATCH_PARENT,
    )
    windowDialog.window?.setBackgroundDrawableResource(android.R.color.transparent)
    windowDialog.setOnDismissListener {
      cleanupAfterDismiss()
    }
    dialog = windowDialog
  }

  private fun buildGalleryPage(activity: Activity, textColor: Int, subColor: Int) {
    val page = LinearLayout(activity).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(10), dp(10), dp(10), dp(10))
      background = roundedDrawable(Color.WHITE, dpF(22f), withAlpha(textColor, 0.08f), dpF(1f))
      clipChildren = false
      clipToPadding = false
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
    }

    val topRow = LinearLayout(activity).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      clipChildren = false
      clipToPadding = false
    }
    page.addView(
      topRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        bottomMargin = dp(10)
      },
    )

    val tileHost = AspectRatioFrameLayout(activity, 9f, 16f).apply {
      background = roundedDrawable(Color.argb(224, 10, 12, 15), dpF(16f))
      clipChildren = true
      clipToPadding = true
      setOnClickListener {
        openFullCameraView()
      }
    }
    topRow.addView(
      tileHost,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.04f).apply {
        rightMargin = dp(10)
      },
    )

    val cameraBadge = FrameLayout(activity).apply {
      background = roundedDrawable(Color.argb(88, 0, 0, 0), dpF(12f))
      setPadding(dp(8), dp(4), dp(8), dp(4))
    }
    cameraBadge.addView(
      TextView(activity).apply {
        text = "Open Camera"
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
      },
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    tileHost.addView(
      cameraBadge,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.BOTTOM or Gravity.START,
      ).apply {
        leftMargin = dp(8)
        bottomMargin = dp(8)
      },
    )

    val rightColumn = LinearLayout(activity).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      clipChildren = true
      clipToPadding = true
    }
    topRow.addView(
      rightColumn,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 0.96f),
    )

    val primary = SquareImageTile(activity).apply {
      setOnClickListener { selectTopTileImage(0) }
    }
    rightColumn.addView(
      primary,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ).apply {
        bottomMargin = dp(8)
      },
    )

    val secondary = SquareImageTile(activity).apply {
      setOnClickListener { selectTopTileImage(1) }
    }
    rightColumn.addView(
      secondary,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )

    val permissionLabel = TextView(activity).apply {
      text = "Grant Photos access to show gallery"
      setTextColor(subColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      gravity = Gravity.CENTER
      visibility = View.GONE
      setOnClickListener { requestMediaPermissionAndLoad() }
    }
    page.addView(
      permissionLabel,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(6)
        bottomMargin = dp(10)
      },
    )

    val recycler = RecyclerView(activity).apply {
      clipChildren = false
      clipToPadding = false
      setPadding(0, 0, 0, dp(4))
      setBackgroundColor(Color.TRANSPARENT)
      layoutManager = GridLayoutManager(activity, 3)
      addItemDecoration(GridSpacingDecoration(dp(6)))
    }
    page.addView(
      recycler,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )

    val footerHint = TextView(activity).apply {
      text = "Tap image to send"
      setTextColor(withAlpha(textColor, 0.7f))
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      gravity = Gravity.CENTER
    }
    page.addView(
      footerHint,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(8)
      },
    )

    galleryGridAdapter =
      GalleryGridAdapter(
        context = activity,
        onTap = { item ->
          onSelectImage?.invoke(item.uri.toString(), currentCaption())
          dismiss(animated = true)
        },
        thumbnailLoader = { uri, target, imageView ->
          bindThumbnail(uri, target, imageView)
        },
      ).also { adapter ->
        recycler.adapter = adapter
      }

    galleryPage = page
    galleryTileHost = tileHost
    galleryTopImagePrimary = primary
    galleryTopImageSecondary = secondary
    galleryPermissionLabel = permissionLabel
    galleryRecycler = recycler
  }

  private fun buildFilePage(activity: Activity, textColor: Int, subColor: Int) {
    val page = LinearLayout(activity).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      setPadding(dp(16), dp(18), dp(16), dp(16))
      background = roundedDrawable(Color.WHITE, dpF(22f), withAlpha(textColor, 0.08f), dpF(1f))
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
    }

    page.addView(
      TextView(activity).apply {
        text = "Share a File"
        setTextColor(textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        gravity = Gravity.CENTER
      },
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(28)
      },
    )

    page.addView(
      TextView(activity).apply {
        text = "Pick any document and send instantly."
        setTextColor(subColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        gravity = Gravity.CENTER
      },
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(8)
      },
    )

    val action = buildPrimaryActionButton(activity, "Choose File", android.R.drawable.ic_menu_upload, textColor)
    action.setOnClickListener { openDocumentPicker() }
    page.addView(
      action,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        dp(48),
      ).apply {
        topMargin = dp(22)
      },
    )

    filePage = page
  }

  private fun buildLocationPage(activity: Activity, textColor: Int, subColor: Int) {
    val page = LinearLayout(activity).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      setPadding(dp(16), dp(18), dp(16), dp(16))
      background = roundedDrawable(Color.WHITE, dpF(22f), withAlpha(textColor, 0.08f), dpF(1f))
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
    }

    page.addView(
      TextView(activity).apply {
        text = "Share Location"
        setTextColor(textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        gravity = Gravity.CENTER
      },
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(28)
      },
    )

    page.addView(
      TextView(activity).apply {
        text = "Use current GPS coordinates."
        setTextColor(subColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        gravity = Gravity.CENTER
      },
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(8)
      },
    )

    val action = buildPrimaryActionButton(activity, "Send Current Location", android.R.drawable.ic_menu_mylocation, textColor)
    action.setOnClickListener {
      requestLocationAndSend()
    }
    page.addView(
      action,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        dp(48),
      ).apply {
        topMargin = dp(22)
      },
    )

    locationPage = page
  }

  private fun buildFullCameraPage(activity: Activity, textColor: Int, subColor: Int, panelFill: Int) {
    val page = FrameLayout(activity).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
      setBackgroundColor(Color.argb(255, 8, 10, 14))
      visibility = View.GONE
      clipChildren = true
      clipToPadding = true
    }

    val previewHost = FrameLayout(activity).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
      setBackgroundColor(Color.argb(255, 8, 10, 14))
    }
    page.addView(previewHost)

    val title = TextView(activity).apply {
      text = "Camera"
      setTextColor(Color.WHITE)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
      typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    page.addView(
      title,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.TOP or Gravity.CENTER_HORIZONTAL,
      ).apply {
        topMargin = dp(18)
      },
    )

    val close = FrameLayout(activity).apply {
      background = circleDrawable(Color.argb(126, 0, 0, 0))
      setOnClickListener { closeFullCameraView(animated = true) }
      setOnTouchListener(::handleButtonTouchFeedback)
    }.also { closeWrap ->
      closeWrap.addView(
        TextView(activity).apply {
          text = "\u2039"
          setTextColor(Color.WHITE)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
          gravity = Gravity.CENTER
        },
        FrameLayout.LayoutParams(
          FrameLayout.LayoutParams.MATCH_PARENT,
          FrameLayout.LayoutParams.MATCH_PARENT,
        ),
      )
    }
    page.addView(
      close,
      FrameLayout.LayoutParams(dp(40), dp(40), Gravity.TOP or Gravity.START).apply {
        topMargin = dp(10)
        leftMargin = dp(10)
      },
    )

    val flip = FrameLayout(activity).apply {
      background = circleDrawable(Color.argb(126, 0, 0, 0))
      setOnClickListener { flipCameraSelector() }
      setOnTouchListener(::handleButtonTouchFeedback)
    }.also { flipWrap ->
      flipWrap.addView(
        ImageView(activity).apply {
          setImageResource(android.R.drawable.ic_menu_rotate)
          setColorFilter(Color.WHITE)
          scaleType = ImageView.ScaleType.CENTER_INSIDE
        },
        FrameLayout.LayoutParams(
          FrameLayout.LayoutParams.MATCH_PARENT,
          FrameLayout.LayoutParams.MATCH_PARENT,
        ),
      )
    }
    page.addView(
      flip,
      FrameLayout.LayoutParams(dp(40), dp(40), Gravity.TOP or Gravity.END).apply {
        topMargin = dp(10)
        rightMargin = dp(10)
      },
    )

    val captureWrap = FrameLayout(activity).apply {
      setOnClickListener { capturePhotoAndSend() }
      setOnTouchListener(::handleButtonTouchFeedback)
      background = circleDrawable(Color.WHITE)
    }
    captureWrap.addView(
      View(activity).apply {
        background = circleDrawable(panelFill)
      },
      FrameLayout.LayoutParams(dp(58), dp(58), Gravity.CENTER),
    )
    page.addView(
      captureWrap,
      FrameLayout.LayoutParams(dp(74), dp(74), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
        bottomMargin = dp(22)
      },
    )

    page.addView(
      TextView(activity).apply {
        text = "Tap to capture"
        setTextColor(withAlpha(subColor, 0.95f))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        gravity = Gravity.CENTER
      },
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
      ).apply {
        bottomMargin = dp(6)
      },
    )

    fullCameraPage = page
    fullCameraHost = previewHost
    cameraCloseButton = close
    cameraFlipButton = flip
    cameraCaptureButton = captureWrap
  }

  private fun switchTab(next: AttachmentTab, animated: Boolean) {
    if (isFullCameraVisible) return
    if (next == activeTab) {
      setInputMode(enabled = true, animated = animated)
      return
    }

    val fromView = tabViewFor(activeTab) ?: return
    val toView = tabViewFor(next) ?: return
    if (!animated || contentHost == null || contentHost!!.width <= 1) {
      fromView.visibility = View.GONE
      toView.visibility = View.VISIBLE
      toView.alpha = 1f
      toView.translationX = 0f
      activeTab = next
      updateTabVisuals()
      setInputMode(enabled = true, animated = false)
      return
    }

    val hostHeight = contentHost!!.height.toFloat().coerceAtLeast(dpF(200f))
    val direction = if (next.ordinal > activeTab.ordinal) 1f else -1f
    toView.visibility = View.VISIBLE
    toView.translationY = direction * min(dpF(26f), hostHeight * 0.18f)
    toView.alpha = 0.92f
    toView.animate().cancel()
    fromView.animate().cancel()

    fromView.animate()
      .translationY(-direction * dpF(18f))
      .alpha(0f)
      .setDuration(180L)
      .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
      .withEndAction {
        fromView.visibility = View.GONE
        fromView.translationY = 0f
        fromView.alpha = 1f
      }
      .start()

    toView.animate()
      .translationY(0f)
      .alpha(1f)
      .setDuration(210L)
      .setInterpolator(PathInterpolator(0.23f, 1.0f, 0.32f, 1f))
      .start()

    activeTab = next
    updateTabVisuals()
    setInputMode(enabled = true, animated = true)
  }

  private fun setInputMode(
    enabled: Boolean,
    animated: Boolean,
    requestFocus: Boolean = true,
  ) {
    val tabs = tabsContainer ?: return
    val input = inputContainer ?: return
    if (isInputMode == enabled) {
      if (enabled && requestFocus) {
        captionInput?.post { captionInput?.requestFocus() }
      }
      return
    }
    isInputMode = enabled
    tabs.animate().cancel()
    input.animate().cancel()

    if (!animated) {
      tabs.visibility = if (enabled) View.INVISIBLE else View.VISIBLE
      tabs.alpha = if (enabled) 0f else 1f
      tabs.translationY = 0f
      input.visibility = if (enabled) View.VISIBLE else View.INVISIBLE
      input.alpha = if (enabled) 1f else 0f
      input.translationY = 0f
      if (enabled && requestFocus) {
        captionInput?.requestFocus()
      } else if (!enabled) {
        captionInput?.clearFocus()
      }
      return
    }

    if (enabled) {
      input.visibility = View.VISIBLE
      input.alpha = 0f
      input.translationY = dpF(10f)
      tabs.animate()
        .alpha(0f)
        .translationY(-dpF(8f))
        .setDuration(140L)
        .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
        .withEndAction {
          tabs.visibility = View.INVISIBLE
          tabs.translationY = 0f
        }
        .start()
      input.animate()
        .alpha(1f)
        .translationY(0f)
        .setDuration(180L)
        .setInterpolator(PathInterpolator(0.23f, 1f, 0.32f, 1f))
        .start()
      if (requestFocus) {
        captionInput?.post { captionInput?.requestFocus() }
      }
      return
    }

    tabs.visibility = View.VISIBLE
    tabs.alpha = 0f
    tabs.translationY = dpF(8f)
    input.animate()
      .alpha(0f)
      .translationY(dpF(8f))
      .setDuration(140L)
      .setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
      .withEndAction {
        input.visibility = View.INVISIBLE
        input.translationY = 0f
      }
      .start()
    tabs.animate()
      .alpha(1f)
      .translationY(0f)
      .setDuration(180L)
      .setInterpolator(PathInterpolator(0.23f, 1f, 0.32f, 1f))
      .start()
    captionInput?.clearFocus()
  }

  private fun animateIn() {
    val scrim = scrimView ?: return
    val sheet = sheetView ?: return
    scrim.animate().cancel()
    sheet.animate().cancel()
    scrim.animate()
      .alpha(1f)
      .setDuration(180L)
      .start()
    sheet.animate()
      .translationY(0f)
      .setDuration(240L)
      .setInterpolator(PathInterpolator(0.23f, 1.0f, 0.32f, 1f))
      .start()
  }

  private fun openFullCameraView() {
    ensureCameraPermission { granted ->
      if (!granted) {
        toast("Camera permission is required")
        return@ensureCameraPermission
      }
      val fullPage = fullCameraPage ?: return@ensureCameraPermission
      val bottom = bottomSharedSurface ?: return@ensureCameraPermission
      if (isFullCameraVisible) return@ensureCameraPermission
      isFullCameraVisible = true
      setInputMode(enabled = false, animated = false, requestFocus = false)
      fullPage.visibility = View.VISIBLE
      fullPage.translationX = (contentHost?.width ?: dp(240)).toFloat()
      fullPage.alpha = 1f
      bottom.animate().alpha(0f).setDuration(140L).withEndAction {
        bottom.visibility = View.INVISIBLE
      }.start()
      attachCameraPreview(host = fullCameraHost)
      bindCameraPreviewIfPossible()
      fullPage.animate()
        .translationX(0f)
        .setDuration(220L)
        .setInterpolator(PathInterpolator(0.23f, 1.0f, 0.32f, 1f))
        .start()
    }
  }

  private fun closeFullCameraView(animated: Boolean) {
    if (!isFullCameraVisible && animated) return
    val fullPage = fullCameraPage
    val bottom = bottomSharedSurface
    isFullCameraVisible = false
    val endAction = {
      fullPage?.visibility = View.GONE
      fullPage?.translationX = 0f
      bottom?.visibility = View.VISIBLE
      bottom?.alpha = 0f
      bottom?.animate()?.alpha(1f)?.setDuration(140L)?.start()
      setInputMode(enabled = false, animated = false, requestFocus = false)
      attachCameraPreview(host = galleryTileHost)
      bindCameraPreviewIfPossible()
    }
    if (!animated) {
      endAction()
      return
    }
    fullPage?.animate()
      ?.translationX((contentHost?.width ?: dp(240)).toFloat())
      ?.setDuration(190L)
      ?.setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f))
      ?.withEndAction { endAction() }
      ?.start()
  }

  private fun ensureCameraPreviewInTile() {
    ensureCameraPermission { granted ->
      if (!granted) {
        galleryPermissionLabel?.visibility = View.VISIBLE
        return@ensureCameraPermission
      }
      attachCameraPreview(host = galleryTileHost)
      bindCameraPreviewIfPossible()
    }
  }

  private fun attachCameraPreview(host: FrameLayout?) {
    val targetHost = host ?: return
    val preview = cameraPreviewView ?: PreviewView(context).also { created ->
      created.layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
      created.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
      created.scaleType = PreviewView.ScaleType.FILL_CENTER
      created.setBackgroundColor(Color.BLACK)
      cameraPreviewView = created
    }
    if (cameraPreviewParent === targetHost && preview.parent === targetHost) {
      return
    }
    (preview.parent as? ViewGroup)?.removeView(preview)
    targetHost.addView(
      preview,
      0,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    cameraPreviewParent = targetHost
  }

  private fun bindCameraPreviewIfPossible() {
    val preview = cameraPreviewView ?: return
    val activity = resolveComponentActivity() ?: return
    if (!hasPermission(Manifest.permission.CAMERA)) return
    val future = ProcessCameraProvider.getInstance(context)
    future.addListener(
      {
        try {
          val provider = future.get()
          cameraProvider = provider
          provider.unbindAll()
          val previewUseCase = Preview.Builder().build().also {
            it.setSurfaceProvider(preview.surfaceProvider)
          }
          imageCapture =
            ImageCapture.Builder()
              .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
              .build()
          provider.bindToLifecycle(activity, cameraSelector, previewUseCase, imageCapture)
        } catch (error: Throwable) {
          Log.w(TAG, "bindCameraPreview failed", error)
        }
      },
      ContextCompat.getMainExecutor(context),
    )
  }

  private fun flipCameraSelector() {
    cameraSelector =
      if (cameraSelector == CameraSelector.DEFAULT_BACK_CAMERA) {
        CameraSelector.DEFAULT_FRONT_CAMERA
      } else {
        CameraSelector.DEFAULT_BACK_CAMERA
      }
    bindCameraPreviewIfPossible()
  }

  private fun capturePhotoAndSend() {
    val capture = imageCapture
    if (capture == null) {
      toast("Camera is not ready")
      return
    }
    val output = File(context.cacheDir, "attachment-camera-${UUID.randomUUID()}.jpg")
    val outputOptions = ImageCapture.OutputFileOptions.Builder(output).build()
    capture.takePicture(
      outputOptions,
      cameraExecutor,
      object : ImageCapture.OnImageSavedCallback {
        override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
          uiHandler.post {
            onSelectImage?.invoke(Uri.fromFile(output).toString(), currentCaption())
            dismiss(animated = true)
          }
        }

        override fun onError(exception: ImageCaptureException) {
          Log.w(TAG, "capturePhoto failed", exception)
          uiHandler.post {
            toast("Capture failed")
          }
        }
      },
    )
  }

  private fun loadGalleryWithPermissionCheck() {
    if (hasMediaPermission()) {
      loadGalleryItems()
    } else {
      requestMediaPermissionAndLoad()
    }
  }

  private fun requestMediaPermissionAndLoad() {
    val permission = mediaPermission() ?: run {
      loadGalleryItems()
      return
    }
    ensurePermission(permission) { granted ->
      if (granted) {
        loadGalleryItems()
      } else {
        galleryPermissionLabel?.visibility = View.VISIBLE
        toast("Photos permission denied")
      }
    }
  }

  private fun loadGalleryItems() {
    galleryPermissionLabel?.visibility = View.GONE
    ioExecutor.execute {
      val result = ArrayList<GalleryMediaItem>(180)
      val projection = arrayOf(MediaStore.Images.Media._ID)
      val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"
      var cursor: Cursor? = null
      try {
        cursor =
          context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            null,
            null,
            sortOrder,
          )
        val idIndex = cursor?.getColumnIndexOrThrow(MediaStore.Images.Media._ID) ?: -1
        if (idIndex >= 0) {
          while (cursor?.moveToNext() == true && result.size < 180) {
            val id = cursor.getLong(idIndex)
            val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
            result.add(GalleryMediaItem(uri = uri))
          }
        }
      } catch (error: Throwable) {
        Log.w(TAG, "loadGalleryItems failed", error)
      } finally {
        cursor?.close()
      }
      uiHandler.post {
        galleryAllItems.clear()
        galleryAllItems.addAll(result)
        bindTopGalleryTiles()
        bindGalleryGrid()
      }
    }
  }

  private fun bindTopGalleryTiles() {
    val primary = galleryTopImagePrimary
    val secondary = galleryTopImageSecondary
    val first = galleryAllItems.getOrNull(0)
    val second = galleryAllItems.getOrNull(1)

    if (primary != null) {
      if (first != null) {
        primary.visibility = View.VISIBLE
        bindThumbnail(first.uri, dp(140), primary.image)
      } else {
        primary.visibility = View.VISIBLE
        primary.image.setImageDrawable(null)
        primary.image.setBackgroundColor(Color.argb(44, 255, 255, 255))
      }
    }

    if (secondary != null) {
      if (second != null) {
        secondary.visibility = View.VISIBLE
        bindThumbnail(second.uri, dp(140), secondary.image)
      } else {
        secondary.visibility = View.VISIBLE
        secondary.image.setImageDrawable(null)
        secondary.image.setBackgroundColor(Color.argb(44, 255, 255, 255))
      }
    }
  }

  private fun bindGalleryGrid() {
    galleryGridItems.clear()
    if (galleryAllItems.size > 2) {
      galleryGridItems.addAll(galleryAllItems.subList(2, galleryAllItems.size))
    }
    galleryGridAdapter?.submit(galleryGridItems)
  }

  private fun selectTopTileImage(index: Int) {
    val item = galleryAllItems.getOrNull(index) ?: return
    onSelectImage?.invoke(item.uri.toString(), currentCaption())
    dismiss(animated = true)
  }

  private fun bindThumbnail(uri: Uri, targetPx: Int, imageView: ImageView) {
    val cacheKey = "${uri}_$targetPx"
    val cached = thumbnailCache.get(cacheKey)
    if (cached != null) {
      imageView.setImageBitmap(cached)
      return
    }
    imageView.tag = cacheKey
    ioExecutor.execute {
      val decoded = loadThumbnailBitmap(uri, targetPx)
      if (decoded != null) {
        thumbnailCache.put(cacheKey, decoded)
      }
      uiHandler.post {
        if (imageView.tag == cacheKey) {
          if (decoded != null) {
            imageView.setImageBitmap(decoded)
          } else {
            imageView.setImageDrawable(null)
            imageView.setBackgroundColor(Color.argb(34, 255, 255, 255))
          }
        }
      }
    }
  }

  private fun loadThumbnailBitmap(uri: Uri, targetPx: Int): Bitmap? {
    return try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        context.contentResolver.loadThumbnail(uri, Size(targetPx, targetPx), null)
      } else {
        context.contentResolver.openInputStream(uri)?.use { stream ->
          BitmapFactory.decodeStream(stream)
        }
      }
    } catch (_: Throwable) {
      null
    }
  }

  private fun openDocumentPicker() {
    launchWithResult<Array<String>, Uri?>(ActivityResultContracts.OpenDocument(), arrayOf("*/*")) { uri: Uri? ->
      if (uri == null) return@launchWithResult
      val selection = resolveFileSelection(uri) ?: return@launchWithResult
      onSelectFile?.invoke(
        selection.uri.toString(),
        selection.name,
        selection.size,
        selection.mimeType,
        currentCaption(),
      )
      dismiss(animated = true)
    }
  }

  private fun resolveFileSelection(uri: Uri): FileSelection? {
    val resolver = context.contentResolver
    var name = "File"
    var size: Long? = null
    try {
      resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
        if (cursor.moveToFirst()) {
          if (nameIdx >= 0) {
            cursor.getString(nameIdx)?.let { value ->
              if (value.isNotBlank()) name = value
            }
          }
          if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
            size = cursor.getLong(sizeIdx)
          }
        }
      }
    } catch (_: Throwable) {
    }
    val mimeType = resolver.getType(uri)
    return FileSelection(uri = uri, name = name, size = size, mimeType = mimeType)
  }

  private fun requestLocationAndSend() {
    ensureLocationPermission { granted ->
      if (!granted) {
        toast("Location permission denied")
        return@ensureLocationPermission
      }
      fetchCurrentLocation { location ->
        if (location == null) {
          toast("Unable to resolve location")
          return@fetchCurrentLocation
        }
        onSelectLocation?.invoke(location.latitude, location.longitude, currentCaption())
        dismiss(animated = true)
      }
    }
  }

  private fun fetchCurrentLocation(onResolved: (Location?) -> Unit) {
    val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
    if (manager == null) {
      onResolved(null)
      return
    }
    val bestProvider =
      when {
        manager.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
        manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
        else -> null
      }
    if (bestProvider == null) {
      onResolved(bestLastKnown(manager))
      return
    }

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      try {
        manager.getCurrentLocation(
          bestProvider,
          CancellationSignal(),
          ContextCompat.getMainExecutor(context),
        ) { location ->
          onResolved(location ?: bestLastKnown(manager))
        }
        return
      } catch (_: Throwable) {
      }
    }
    onResolved(bestLastKnown(manager))
  }

  private fun bestLastKnown(manager: LocationManager): Location? {
    val candidates = ArrayList<Location>(3)
    try {
      manager.getLastKnownLocation(LocationManager.GPS_PROVIDER)?.let { candidates.add(it) }
    } catch (_: Throwable) {
    }
    try {
      manager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)?.let { candidates.add(it) }
    } catch (_: Throwable) {
    }
    try {
      manager.getLastKnownLocation(LocationManager.PASSIVE_PROVIDER)?.let { candidates.add(it) }
    } catch (_: Throwable) {
    }
    return candidates.maxByOrNull { it.time }
  }

  private fun updateTabVisuals() {
    val defaultText = Color.argb(255, 24, 28, 34)
    val activeFill = withAlpha(Color.parseColor("#7CB8B8"), 0.24f)
    val inactiveFill = Color.TRANSPARENT
    val border = Color.argb(18, 24, 28, 34)
    updateTabVisuals(defaultText, activeFill, inactiveFill, border)
  }

  private fun updateTabVisuals(
    defaultText: Int,
    activeFill: Int,
    inactiveFill: Int,
    border: Int,
  ) {
    fun style(button: TextView?, active: Boolean) {
      if (button == null) return
      val targetColor = if (active) defaultText else withAlpha(defaultText, 0.68f)
      button.setTextColor(targetColor)
      button.compoundDrawablesRelative.forEach { drawable ->
        drawable?.mutate()?.setTint(targetColor)
      }
      button.typeface = Typeface.create(Typeface.DEFAULT, if (active) Typeface.BOLD else Typeface.NORMAL)
      button.background =
        roundedDrawable(
          if (active) activeFill else inactiveFill,
          dpF(14f),
          border,
          dpF(0.8f),
        )
      button.alpha = if (active) 1f else 0.9f
    }

    style(galleryTabButton, activeTab == AttachmentTab.GALLERY)
    style(fileTabButton, activeTab == AttachmentTab.FILE)
    style(locationTabButton, activeTab == AttachmentTab.LOCATION)
  }

  private fun tabViewFor(tab: AttachmentTab): View? {
    return when (tab) {
      AttachmentTab.GALLERY -> galleryPage
      AttachmentTab.FILE -> filePage
      AttachmentTab.LOCATION -> locationPage
    }
  }

  private fun currentCaption(): String? {
    val value = captionInput?.text?.toString()?.trim().orEmpty()
    return value.takeIf { it.isNotEmpty() }
  }

  private fun applyBottomInsets() {
    val content = contentHost
    val sharedSurface = bottomSharedSurface
    if (content == null || sharedSurface == null) return

    val inset = safeBottomInsetPx
    val baseBottom = dp(8) + inset
    val sharedHeight = dp(56)
    val between = dp(10)

    (sharedSurface.layoutParams as? FrameLayout.LayoutParams)?.let { lp ->
      lp.gravity = Gravity.BOTTOM
      lp.bottomMargin = baseBottom
      sharedSurface.layoutParams = lp
    }
    (content.layoutParams as? FrameLayout.LayoutParams)?.let { lp ->
      lp.bottomMargin = baseBottom + sharedHeight + between
      content.layoutParams = lp
    }
  }

  private fun handleButtonTouchFeedback(view: View, event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        view.animate().scaleX(0.95f).scaleY(0.95f).setDuration(80L).start()
      }
      MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_UP -> {
        view.animate().scaleX(1f).scaleY(1f).setDuration(130L).start()
      }
    }
    return false
  }

  private fun buildTabButton(
    activity: Activity,
    title: String,
    iconRes: Int,
    textColor: Int,
  ): TextView {
    val drawable = ContextCompat.getDrawable(activity, iconRes)?.mutate()
    drawable?.setTint(textColor)
    return TextView(activity).apply {
      text = title
      gravity = Gravity.CENTER
      setTextColor(textColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
      typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
      setCompoundDrawablesRelativeWithIntrinsicBounds(drawable, null, null, null)
      compoundDrawablePadding = dp(6)
      setPadding(dp(10), dp(3), dp(10), dp(3))
      includeFontPadding = false
      maxLines = 1
      ellipsize = TextUtils.TruncateAt.END
      elevation = 0f
    }
  }

  private fun buildPrimaryActionButton(activity: Activity, title: String, iconRes: Int, textColor: Int): FrameLayout {
    val button = FrameLayout(activity).apply {
      background = roundedDrawable(Color.WHITE, dpF(16f), withAlpha(textColor, 0.12f), dpF(1f))
      elevation = 0f
      setOnTouchListener(::handleButtonTouchFeedback)
    }
    val row = LinearLayout(activity).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
    }
    row.addView(
      ImageView(activity).apply {
        setImageResource(iconRes)
        setColorFilter(textColor)
      },
      LinearLayout.LayoutParams(dp(20), dp(20)).apply {
        rightMargin = dp(8)
      },
    )
    row.addView(
      TextView(activity).apply {
        text = title
        setTextColor(textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
      },
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
    button.addView(
      row,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    return button
  }

  private fun ensureCameraPermission(onReady: (Boolean) -> Unit) {
    ensurePermission(Manifest.permission.CAMERA, onReady)
  }

  private fun ensureLocationPermission(onReady: (Boolean) -> Unit) {
    val permissions =
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
      } else {
        arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION)
      }
    val alreadyGranted = permissions.all { hasPermission(it) }
    if (alreadyGranted) {
      onReady(true)
      return
    }
    launchWithResult<Array<String>, Map<String, Boolean>>(ActivityResultContracts.RequestMultiplePermissions(), permissions) { result ->
      val granted = result.values.any { it }
      onReady(granted)
    }
  }

  private fun ensurePermission(permission: String, onReady: (Boolean) -> Unit) {
    if (hasPermission(permission)) {
      onReady(true)
      return
    }
    launchWithResult<String, Boolean>(ActivityResultContracts.RequestPermission(), permission) { granted ->
      onReady(granted)
    }
  }

  private fun hasPermission(permission: String): Boolean {
    return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
  }

  private fun hasMediaPermission(): Boolean {
    val permission = mediaPermission() ?: return true
    return hasPermission(permission)
  }

  private fun mediaPermission(): String? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      Manifest.permission.READ_MEDIA_IMAGES
    } else {
      Manifest.permission.READ_EXTERNAL_STORAGE
    }
  }

  private fun <I, O> launchWithResult(
    contract: ActivityResultContract<I, O>,
    input: I,
    callback: (O) -> Unit,
  ) {
    val activity = resolveComponentActivity()
    if (activity == null) {
      Log.w(TAG, "launchWithResult skipped: ComponentActivity missing")
      return
    }
    val key = "chat-attachment-${UUID.randomUUID()}"
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

  private fun resolveComponentActivity(): ComponentActivity? {
    return resolveActivity() as? ComponentActivity
  }

  private fun resolveActivity(): Activity? {
    val fromAppContext = appContext?.currentActivity
    if (fromAppContext != null) return fromAppContext
    return context as? Activity
  }

  private fun cleanupAfterDismiss() {
    isDismissing = false
    closeFullCameraView(animated = false)
    isFullCameraVisible = false
    try {
      cameraProvider?.unbindAll()
    } catch (_: Throwable) {
    }
    cameraProvider = null
    imageCapture = null
    cameraPreviewParent = null
    rootView = null
    scrimView = null
    sheetView = null
    contentHost = null
    bottomSharedSurface = null
    tabsContainer = null
    inputContainer = null
    inputBackButton = null
    closeButton = null
    captionInput = null
    safeBottomInsetPx = 0
    isInputMode = false
    galleryPage = null
    filePage = null
    locationPage = null
    fullCameraPage = null
    galleryTileHost = null
    galleryTopImagePrimary = null
    galleryTopImageSecondary = null
    galleryPermissionLabel = null
    galleryRecycler = null
    fullCameraHost = null
    cameraFlipButton = null
    cameraCaptureButton = null
    cameraCloseButton = null
    galleryTabButton = null
    fileTabButton = null
    locationTabButton = null
    dialog = null
    activeTab = AttachmentTab.GALLERY
  }

  private fun luminance(color: Int): Float {
    val r = Color.red(color) / 255f
    val g = Color.green(color) / 255f
    val b = Color.blue(color) / 255f
    return 0.299f * r + 0.587f * g + 0.114f * b
  }

  private fun toast(message: String) {
    Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
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

  private fun circleDrawable(color: Int): GradientDrawable =
    GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(color)
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

  private class GridSpacingDecoration(
    private val spacingPx: Int,
  ) : RecyclerView.ItemDecoration() {
    override fun getItemOffsets(
      outRect: android.graphics.Rect,
      view: View,
      parent: RecyclerView,
      state: RecyclerView.State,
    ) {
      outRect.left = spacingPx / 2
      outRect.right = spacingPx / 2
      outRect.top = spacingPx / 2
      outRect.bottom = spacingPx / 2
    }
  }

  private class SquareImageTile(
    context: Context,
  ) : FrameLayout(context) {
    val image = ImageView(context)

    init {
      clipChildren = true
      clipToPadding = true
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(14f)
        setColor(Color.argb(58, 255, 255, 255))
      }
      image.scaleType = ImageView.ScaleType.CENTER_CROP
      addView(
        image,
        LayoutParams(
          LayoutParams.MATCH_PARENT,
          LayoutParams.MATCH_PARENT,
        ),
      )
    }

    private fun dpF(value: Float): Float {
      return TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        value,
        resources.displayMetrics,
      )
    }
  }

  private class AspectRatioFrameLayout(
    context: Context,
    private val widthRatio: Float,
    private val heightRatio: Float,
  ) : FrameLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
      val width = MeasureSpec.getSize(widthMeasureSpec)
      val targetHeight =
        if (widthRatio > 0f) {
          (width * (heightRatio / widthRatio)).roundToInt()
        } else {
          width
        }
      val exactHeightSpec = MeasureSpec.makeMeasureSpec(targetHeight, MeasureSpec.EXACTLY)
      super.onMeasure(widthMeasureSpec, exactHeightSpec)
    }
  }

  private class GalleryGridAdapter(
    context: Context,
    private val onTap: (GalleryMediaItem) -> Unit,
    private val thumbnailLoader: (Uri, Int, ImageView) -> Unit,
  ) : RecyclerView.Adapter<GalleryGridAdapter.ImageHolder>() {
    private val items = ArrayList<GalleryMediaItem>()
    private val density = context.resources.displayMetrics.density

    fun submit(next: List<GalleryMediaItem>) {
      items.clear()
      items.addAll(next)
      notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ImageHolder {
      val root = FrameLayout(parent.context).apply {
        background = GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadius = 12f * density
          setColor(Color.argb(52, 255, 255, 255))
        }
        clipChildren = true
        clipToPadding = true
      }
      val image = ImageView(parent.context).apply {
        scaleType = ImageView.ScaleType.CENTER_CROP
      }
      root.addView(
        image,
        FrameLayout.LayoutParams(
          FrameLayout.LayoutParams.MATCH_PARENT,
          FrameLayout.LayoutParams.MATCH_PARENT,
        ),
      )
      return ImageHolder(root, image)
    }

    override fun onBindViewHolder(holder: ImageHolder, position: Int) {
      val item = items[position]
      holder.root.setOnClickListener { onTap(item) }
      holder.root.post {
        val side = max(holder.root.width, holder.root.height)
        thumbnailLoader(item.uri, max((side * 1.2f).roundToInt(), 180), holder.image)
      }
    }

    override fun getItemCount(): Int = items.size

    override fun onViewAttachedToWindow(holder: ImageHolder) {
      super.onViewAttachedToWindow(holder)
      val lp = holder.root.layoutParams as? RecyclerView.LayoutParams
      if (lp != null) {
        lp.height = holder.root.resources.displayMetrics.widthPixels / 3
        holder.root.layoutParams = lp
      }
    }

    class ImageHolder(
      val root: FrameLayout,
      val image: ImageView,
    ) : RecyclerView.ViewHolder(root)
  }
}
