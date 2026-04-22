package expo.modules.vibechatnative

import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap

internal object ChatMainRegistry {
  private val map = ConcurrentHashMap<String, WeakReference<ChatMainView>>()

  fun register(surfaceId: String, view: ChatMainView) {
    map[surfaceId] = WeakReference(view)
  }

  fun view(surfaceId: String): ChatMainView? {
    val resolved = map[surfaceId]?.get()
    if (resolved == null) {
      map.remove(surfaceId)
    }
    return resolved
  }

  fun unregister(surfaceId: String) {
    map.remove(surfaceId)
  }
}
