package expo.modules.vibechatnative

import androidx.fragment.app.FragmentActivity
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ChatNativeGifModule : Module() {
  private var gifPanel: ChatGifPanel? = null

  override fun definition() = ModuleDefinition {
    Name("ChatNativeGif")

    Events("onGifSelected", "onGifPanelClosed")

    Function("isSupported") {
      true
    }

    Function("supportsNativeGifPanel") {
      true
    }

    Function("setApiKey") { apiKey: String ->
      ChatGifPanelConfig.setApiKey(apiKey)
      gifPanel?.setApiKey(apiKey)
    }

    Function("getApiKey") {
      ChatGifPanelConfig.apiKey
    }

    AsyncFunction("openPanel") { keyboardHeight: Double? ->
      val activity = appContext.currentActivity as? FragmentActivity
        ?: throw IllegalStateException("A FragmentActivity is required to open the GIF panel")

      panel().show(activity, keyboardHeight?.toInt())
    }

    Function("closePanel") {
      gifPanel?.dismiss()
    }

    OnDestroy {
      gifPanel?.dismiss()
      gifPanel = null
    }
  }

  private fun panel(): ChatGifPanel {
    gifPanel?.let { return it }

    val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext
      ?: throw IllegalStateException("React context is unavailable")

    val created = ChatGifPanel(
      context = context,
      onGifSelected = { selection ->
        sendEvent(
          "onGifSelected",
          mapOf(
            "id" to selection.id,
            "url" to selection.url,
            "previewUrl" to selection.previewUrl,
            "width" to selection.width,
            "height" to selection.height,
          ),
        )
      },
      onClosed = {
        sendEvent("onGifPanelClosed", mapOf("type" to "closed"))
      },
    )

    gifPanel = created
    return created
  }
}
