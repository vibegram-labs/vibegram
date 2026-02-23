import Foundation

public final class VibeNativeCallStore {
  public static let shared = VibeNativeCallStore()

  private let defaults = UserDefaults.standard
  private let queue = DispatchQueue(label: "vibe.native.call.store")

  private enum Keys {
    static let pendingEvents = "vibe.native.call.pendingEvents"
    static let voipToken = "vibe.native.call.voipToken"
    static let apnsToken = "vibe.native.call.apnsToken"
    static let activeCallsByCallId = "vibe.native.call.activeCallsByCallId"
    static let payloadByUuid = "vibe.native.call.payloadByUuid"
  }

  private init() {}

  public func setVoipToken(_ token: String?) {
    queue.sync {
      let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines)
      defaults.set(normalized, forKey: Keys.voipToken)
      NSLog("[VibeNativeCall][Store] setVoipToken len=%d", normalized?.count ?? 0)
    }
  }

  public func setApnsToken(_ token: String?) {
    queue.sync {
      let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines)
      defaults.set(normalized, forKey: Keys.apnsToken)
      NSLog("[VibeNativeCall][Store] setApnsToken len=%d", normalized?.count ?? 0)
    }
  }

  public func getPushTokens() -> [String: Any] {
    queue.sync {
      var result: [String: Any] = [
        "platform": "ios"
      ]
      result["voip"] = defaults.string(forKey: Keys.voipToken) as Any
      result["apns"] = defaults.string(forKey: Keys.apnsToken) as Any
      return result
    }
  }

  public func enqueueEvent(type: String, payload: [String: String]) {
    queue.sync {
      var events = readPendingEventsLocked()
      let callId = payload["callId"] ?? payload["call_id"] ?? "-"
      NSLog("[VibeNativeCall][Store] enqueueEvent type=%@ callId=%@ before=%d", type, callId, events.count)
      events.append([
        "type": type,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        "payload": payload,
      ])
      writePendingEventsLocked(events)
      NSLog("[VibeNativeCall][Store] enqueueEvent type=%@ after=%d", type, events.count)
    }
  }

  public func drainEvents() -> [[String: Any]] {
    queue.sync {
      let events = readPendingEventsLocked()
      defaults.removeObject(forKey: Keys.pendingEvents)
      NSLog("[VibeNativeCall][Store] drainEvents count=%d", events.count)
      return events
    }
  }

  public func setActiveCall(uuid: UUID, payload: [String: String]) {
    queue.sync {
      guard let callId = payload["callId"], !callId.isEmpty else { return }
      var byCallId = defaults.dictionary(forKey: Keys.activeCallsByCallId) as? [String: String] ?? [:]
      var byUuid = defaults.dictionary(forKey: Keys.payloadByUuid) as? [String: [String: String]] ?? [:]
      byCallId[callId] = uuid.uuidString
      byUuid[uuid.uuidString] = payload
      defaults.set(byCallId, forKey: Keys.activeCallsByCallId)
      defaults.set(byUuid, forKey: Keys.payloadByUuid)
      NSLog("[VibeNativeCall][Store] setActiveCall callId=%@ uuid=%@", callId, uuid.uuidString)
    }
  }

  public func payload(for uuid: UUID) -> [String: String]? {
    queue.sync {
      let byUuid = defaults.dictionary(forKey: Keys.payloadByUuid) as? [String: [String: String]]
      return byUuid?[uuid.uuidString]
    }
  }

  public func uuid(forCallId callId: String) -> UUID? {
    queue.sync {
      let byCallId = defaults.dictionary(forKey: Keys.activeCallsByCallId) as? [String: String]
      guard let uuidString = byCallId?[callId] else { return nil }
      return UUID(uuidString: uuidString)
    }
  }

  public func clearActiveCall(callId: String?) {
    queue.sync {
      var byCallId = defaults.dictionary(forKey: Keys.activeCallsByCallId) as? [String: String] ?? [:]
      var byUuid = defaults.dictionary(forKey: Keys.payloadByUuid) as? [String: [String: String]] ?? [:]

      if let callId, let uuidString = byCallId.removeValue(forKey: callId) {
        byUuid.removeValue(forKey: uuidString)
        NSLog("[VibeNativeCall][Store] clearActiveCall callId=%@ uuid=%@", callId, uuidString)
      } else if let callId {
        NSLog("[VibeNativeCall][Store] clearActiveCall callId=%@ noMapping", callId)
      }

      defaults.set(byCallId, forKey: Keys.activeCallsByCallId)
      defaults.set(byUuid, forKey: Keys.payloadByUuid)
    }
  }

  public func clearActiveCall(uuid: UUID) {
    queue.sync {
      var byCallId = defaults.dictionary(forKey: Keys.activeCallsByCallId) as? [String: String] ?? [:]
      var byUuid = defaults.dictionary(forKey: Keys.payloadByUuid) as? [String: [String: String]] ?? [:]
      let uuidString = uuid.uuidString
      byUuid.removeValue(forKey: uuidString)
      for (callId, mapped) in byCallId where mapped == uuidString {
        byCallId.removeValue(forKey: callId)
        NSLog("[VibeNativeCall][Store] clearActiveCall uuid=%@ callId=%@", uuidString, callId)
      }
      defaults.set(byCallId, forKey: Keys.activeCallsByCallId)
      defaults.set(byUuid, forKey: Keys.payloadByUuid)
    }
  }

  private func readPendingEventsLocked() -> [[String: Any]] {
    guard let raw = defaults.data(forKey: Keys.pendingEvents) else { return [] }
    guard let decoded = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else {
      return []
    }
    return decoded
  }

  private func writePendingEventsLocked(_ events: [[String: Any]]) {
    guard let data = try? JSONSerialization.data(withJSONObject: events) else { return }
    defaults.set(data, forKey: Keys.pendingEvents)
  }
}
