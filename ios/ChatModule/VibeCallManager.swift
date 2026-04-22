import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit

public final class VibeNativeCallManager: NSObject {
  public static let shared = VibeNativeCallManager()

  private let store = VibeNativeCallStore.shared
  private lazy var provider: CXProvider = {
    let config = CXProviderConfiguration()
    // `localizedName` is derived from the app bundle on newer SDKs.
    config.supportsVideo = true
    config.maximumCallsPerCallGroup = 1
    config.maximumCallGroups = 1
    config.supportedHandleTypes = [.generic]
    config.includesCallsInRecents = false
    return CXProvider(configuration: config)
  }()
  private let callController = CXCallController()
  private var pushRegistry: PKPushRegistry?
  private var started = false

  private override init() {
    super.init()
  }

  public func start() {
    DispatchQueue.main.async {
      guard !self.started else {
        NSLog("[VibeNativeCall] start skipped alreadyStarted=true")
        return
      }
      self.started = true
      NSLog("[VibeNativeCall] start begin mainThread=%@", Thread.isMainThread ? "true" : "false")
      self.provider.setDelegate(self, queue: nil)
      NSLog("[VibeNativeCall] CXProvider delegate set")
      let registry = PKPushRegistry(queue: DispatchQueue.main)
      registry.delegate = self
      registry.desiredPushTypes = [.voIP]
      self.pushRegistry = registry
      NSLog("[VibeNativeCall] PKPushRegistry configured desiredPushTypes=%@", String(describing: registry.desiredPushTypes))
    }
  }

  public func handleRemoteNotification(userInfo: [AnyHashable: Any]) -> Bool {
    NSLog("[VibeNativeCall] handleRemoteNotification keys=[%@]", userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ","))
    guard let payload = normalizeIncomingCallPayload(userInfo: userInfo) else {
      NSLog("[VibeNativeCall] handleRemoteNotification ignored reason=normalizeFailed")
      return false
    }
    NSLog("[VibeNativeCall] handleRemoteNotification normalized callId=%@ callType=%@ fromUser=%@", payload["callId"] ?? "-", payload["callType"] ?? "-", payload["fromUserId"] ?? "-")
    reportIncomingCall(payload: payload, source: "remoteNotification")
    return true
  }

  public func clearIncomingCallUi(callId: String?) {
    guard let callId, !callId.isEmpty else {
      NSLog("[VibeNativeCall] clearIncomingCallUi skipped reason=missingCallId")
      return
    }
    guard let uuid = store.uuid(forCallId: callId) else {
      NSLog("[VibeNativeCall] clearIncomingCallUi skipped reason=uuidNotFound callId=%@", callId)
      return
    }
    NSLog("[VibeNativeCall] clearIncomingCallUi callId=%@ uuid=%@", callId, uuid.uuidString)
    provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
    store.clearActiveCall(callId: callId)
  }

  private func reportIncomingCall(payload: [String: String], source: String) {
    let callId = payload["callId"] ?? UUID().uuidString
    let uuid = store.uuid(forCallId: callId) ?? UUID()
    NSLog(
      "[VibeNativeCall] reportIncomingCall source=%@ callId=%@ uuid=%@ fromUser=%@ callType=%@",
      source, callId, uuid.uuidString, payload["fromUserId"] ?? "-", payload["callType"] ?? "-"
    )
    let update = CXCallUpdate()
    let callerName = payload["fromUserName"] ?? payload["fromUserId"] ?? "Incoming call"
    update.localizedCallerName = callerName
    update.remoteHandle = CXHandle(type: .generic, value: payload["fromUserId"] ?? callerName)
    update.hasVideo = (payload["callType"] ?? "voice") == "video"
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false

    store.setActiveCall(uuid: uuid, payload: payload)
    var incomingEventPayload = payload
    incomingEventPayload["nativeSource"] = source
    store.enqueueEvent(type: "incomingCall", payload: incomingEventPayload)

    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      if let error {
        NSLog("[VibeNativeCall] reportNewIncomingCall failed callId=%@ error=%@", callId, error.localizedDescription)
      } else {
        NSLog("[VibeNativeCall] reportNewIncomingCall ok callId=%@ uuid=%@", callId, uuid.uuidString)
      }
    }
  }

  private func normalizeIncomingCallPayload(userInfo: [AnyHashable: Any]) -> [String: String]? {
    func string(_ value: Any?) -> String? {
      guard let text = value as? String else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    func dict(_ value: Any?) -> [String: Any]? {
      if let map = value as? [String: Any] { return map }
      if let map = value as? [AnyHashable: Any] {
        var normalized: [String: Any] = [:]
        for (key, val) in map {
          normalized[String(describing: key)] = val
        }
        return normalized
      }
      if let raw = value as? String,
         let data = raw.data(using: .utf8),
         let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return parsed
      }
      return nil
    }

    let root = userInfo.reduce(into: [String: Any]()) { partial, entry in
      partial[String(describing: entry.key)] = entry.value
    }
    NSLog("[VibeNativeCall] normalizeIncomingCallPayload rootKeys=[%@]", root.keys.sorted().joined(separator: ","))
    let candidates = [root, dict(root["data"]), dict(root["body"]), dict(root["payload"])].compactMap { $0 }
    NSLog("[VibeNativeCall] normalizeIncomingCallPayload candidateCount=%d", candidates.count)

    func pick(_ keys: [String]) -> String? {
      for candidate in candidates {
        for key in keys {
          if let value = string(candidate[key]) { return value }
        }
      }
      return nil
    }

    let callId = pick(["callId", "call_id", "callUUID", "call_uuid"])
    let fromUserId = pick(["fromUserId", "from_user_id", "callerId", "caller_id", "userId", "user_id"])
    guard let callId, let fromUserId else {
      NSLog(
        "[VibeNativeCall] normalizeIncomingCallPayload missing callId/fromUserId callId=%@ fromUserId=%@",
        callId ?? "nil", fromUserId ?? "nil"
      )
      return nil
    }
    let event = (pick(["type", "event"]) ?? "").lowercased()
    let callTypeRaw = (pick(["callType", "call_type"]) ?? "").lowercased()
    let isCallEvent = ["call-start", "call_start", "incoming-call", "incoming_call", "call"].contains(event)
    let hasCallType = callTypeRaw == "voice" || callTypeRaw == "video"
    guard isCallEvent || hasCallType else {
      NSLog("[VibeNativeCall] normalizeIncomingCallPayload rejected event=%@ callType=%@", event, callTypeRaw)
      return nil
    }

    var result: [String: String] = [
      "type": "call-start",
      "event": "call-start",
      "callId": callId,
      "fromUserId": fromUserId,
      "fromUserName": pick(["fromUserName", "from_user_name", "callerName", "caller_name", "userName", "user_name"]) ?? fromUserId,
      "callType": callTypeRaw == "video" ? "video" : "voice",
    ]
    if let image = pick(["fromUserImage", "from_user_image", "callerImage", "caller_image", "userImage", "user_image"]) {
      result["fromUserImage"] = image
    }
    NSLog(
      "[VibeNativeCall] normalizeIncomingCallPayload ok callId=%@ event=%@ callType=%@ fromUser=%@",
      callId, event, result["callType"] ?? "-", fromUserId
    )
    return result
  }
}

extension VibeNativeCallManager: PKPushRegistryDelegate {
  public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    NSLog("[VibeNativeCall] PKPush didUpdateCredentials type=%@", type.rawValue)
    guard type == .voIP else { return }
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    store.setVoipToken(token)
    NSLog("[VibeNativeCall] VoIP token updated len=%d", token.count)
  }

  public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    NSLog("[VibeNativeCall] PKPush didInvalidateToken type=%@", type.rawValue)
    guard type == .voIP else { return }
    store.setVoipToken(nil)
  }

  public func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    defer { completion() }
    NSLog("[VibeNativeCall] PKPush didReceiveIncomingPush type=%@ keys=[%@]", type.rawValue, payload.dictionaryPayload.keys.map { String(describing: $0) }.sorted().joined(separator: ","))
    guard type == .voIP else { return }
    guard let normalized = normalizeIncomingCallPayload(userInfo: payload.dictionaryPayload) else {
      NSLog("[VibeNativeCall] PKPush incomingPush ignored reason=normalizeFailed")
      return
    }
    NSLog("[VibeNativeCall] PKPush incomingPush normalized callId=%@ fromUser=%@", normalized["callId"] ?? "-", normalized["fromUserId"] ?? "-")
    reportIncomingCall(payload: normalized, source: "voip")
  }
}

extension VibeNativeCallManager: CXProviderDelegate {
  public func providerDidReset(_ provider: CXProvider) {
    NSLog("[VibeNativeCall] CXProvider providerDidReset")
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    NSLog("[VibeNativeCall] CXProvider answer action uuid=%@", action.callUUID.uuidString)
    if let payload = store.payload(for: action.callUUID) {
      var eventPayload = payload
      eventPayload["action"] = "answer"
      store.enqueueEvent(type: "callAction", payload: eventPayload)
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    NSLog("[VibeNativeCall] CXProvider end action uuid=%@", action.callUUID.uuidString)
    if let payload = store.payload(for: action.callUUID) {
      var eventPayload = payload
      eventPayload["action"] = "decline"
      store.enqueueEvent(type: "callAction", payload: eventPayload)
      store.clearActiveCall(uuid: action.callUUID)
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    NSLog("[VibeNativeCall] CXProvider didActivateAudioSession")
  }
  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("[VibeNativeCall] CXProvider didDeactivateAudioSession")
  }
}
