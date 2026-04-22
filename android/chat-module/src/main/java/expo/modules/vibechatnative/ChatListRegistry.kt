package expo.modules.vibechatnative

import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap

object ChatListRegistry {
  private val map = ConcurrentHashMap<String, WeakReference<ChatListView>>()

  fun register(surfaceId: String, view: ChatListView) {
    if (surfaceId.isBlank()) return
    map[surfaceId] = WeakReference(view)
  }

  fun view(surfaceId: String): ChatListView? {
    val value = map[surfaceId]?.get()
    if (value == null) {
      map.remove(surfaceId)
    }
    return value
  }
}
