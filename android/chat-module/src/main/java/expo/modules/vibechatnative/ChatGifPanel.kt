package expo.modules.vibechatnative

import android.content.Context
import androidx.fragment.app.FragmentActivity
import com.giphy.sdk.core.models.Media
import com.giphy.sdk.ui.GPHContentType
import com.giphy.sdk.ui.GPHSettings
import com.giphy.sdk.ui.Giphy
import com.giphy.sdk.ui.views.GiphyDialogFragment
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import kotlin.math.max

private const val GIF_PANEL_TAG = "chat_native_gif_panel"

data class ChatGifSelection(
  val id: String,
  val url: String,
  val previewUrl: String,
  val width: Int,
  val height: Int,
)

object ChatGifPanelConfig {
  @Volatile
  private var storedApiKey: String = ""

  val apiKey: String
    get() = storedApiKey

  fun setApiKey(nextValue: String) {
    val trimmed = nextValue.trim()
    if (trimmed.isNotEmpty()) {
      storedApiKey = trimmed
    }
  }
}

class ChatGifPanel(
  private val context: Context,
  private val onGifSelected: (ChatGifSelection) -> Unit,
  private val onClosed: () -> Unit,
) {
  private var dialogFragment: GiphyDialogFragment? = null

  fun setApiKey(nextValue: String) {
    ChatGifPanelConfig.setApiKey(nextValue)
  }

  fun show(activity: FragmentActivity, keyboardHeightPx: Int?) {
    if (dialogFragment?.isAdded == true) {
      return
    }

    val apiKey = ChatGifPanelConfig.apiKey.trim()
    if (apiKey.isEmpty()) {
      return
    }

    Giphy.configure(context.applicationContext, apiKey)

    val settings = GPHSettings().apply {
      showConfirmationScreen = false
    }

    val fragment = GiphyDialogFragment.newInstance(settings)
    fragment.gifSelectionListener = object : GiphyDialogFragment.GifSelectionListener {
      override fun didSearchTerm(term: String) {
        // No-op.
      }

      override fun onDismissed(selectedContentType: GPHContentType) {
        dialogFragment = null
        onClosed()
      }

      override fun onGifSelected(
        media: Media,
        searchTerm: String?,
        selectedContentType: GPHContentType,
      ) {
        val selection = extractSelection(media) ?: return
        onGifSelected(selection)
      }
    }

    fragment.show(activity.supportFragmentManager, GIF_PANEL_TAG)
    dialogFragment = fragment

    val resolvedHeight = keyboardHeightPx?.coerceAtLeast(0) ?: 0
    if (resolvedHeight > 0) {
      activity.window.decorView.post {
        val dialog = fragment.dialog as? BottomSheetDialog ?: return@post
        dialog.behavior.peekHeight = max(220, resolvedHeight)
        dialog.behavior.state = BottomSheetBehavior.STATE_EXPANDED
      }
    }
  }

  fun dismiss() {
    dialogFragment?.dismissAllowingStateLoss()
    dialogFragment = null
  }

  private fun extractSelection(media: Media): ChatGifSelection? {
    val id = readStringPath(media, "getId") ?: return null
    val url = firstNonBlank(
      readStringPath(media, "getImages", "getOriginal", "getGifUrl"),
      readStringPath(media, "getImages", "getFixedWidth", "getGifUrl"),
      readStringPath(media, "getImages", "getFixedHeight", "getGifUrl"),
      readStringPath(media, "getUrl"),
    ) ?: return null

    val previewUrl = firstNonBlank(
      readStringPath(media, "getImages", "getPreviewGif", "getGifUrl"),
      readStringPath(media, "getImages", "getFixedWidthSmallStill", "getGifUrl"),
      readStringPath(media, "getImages", "getFixedWidthStill", "getGifUrl"),
      url,
    ) ?: url

    val width = readIntPath(media, "getImages", "getOriginal", "getWidth") ?: 0
    val height = readIntPath(media, "getImages", "getOriginal", "getHeight") ?: 0

    return ChatGifSelection(
      id = id,
      url = url,
      previewUrl = previewUrl,
      width = width,
      height = height,
    )
  }

  private fun readValuePath(root: Any?, vararg getters: String): Any? {
    var current: Any? = root
    for (getter in getters) {
      val receiver = current ?: return null
      val method = receiver::class.java.methods.firstOrNull {
        it.name == getter && it.parameterTypes.isEmpty()
      } ?: return null
      current = runCatching { method.invoke(receiver) }.getOrNull()
    }
    return current
  }

  private fun readStringPath(root: Any?, vararg getters: String): String? {
    val value = readValuePath(root, *getters) ?: return null
    return when (value) {
      is String -> value.trim().takeIf { it.isNotEmpty() }
      else -> value.toString().trim().takeIf { it.isNotEmpty() }
    }
  }

  private fun readIntPath(root: Any?, vararg getters: String): Int? {
    val value = readValuePath(root, *getters) ?: return null
    return when (value) {
      is Int -> value
      is Number -> value.toInt()
      is String -> value.trim().toIntOrNull()
      else -> null
    }
  }

  private fun firstNonBlank(vararg values: String?): String? {
    return values.firstOrNull { !it.isNullOrBlank() }
  }
}
