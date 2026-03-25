import ExpoModulesCore
import Foundation
import UIKit

private func chatNativeHomeNormalizedString(_ value: Any?) -> String? {
  if let string = value as? String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if let number = value as? NSNumber {
    return number.stringValue
  }
  return nil
}

private func chatNativeHomeBuildChatsURL(apiBaseUrl: String, userId: String) -> URL? {
  var base = apiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
  while base.hasSuffix("/") {
    base.removeLast()
  }
  guard !base.isEmpty else { return nil }
  let hasApiSuffix = base.lowercased().hasSuffix("/api")
  let pathBase = hasApiSuffix ? base : "\(base)/api"
  let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
  return URL(string: "\(pathBase)/chats/\(encodedUserId)")
}

private func chatNativeHomeBuildBridgeURL(bridgeBaseUrl: String, path: String) -> URL? {
  var base = bridgeBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
  while base.hasSuffix("/") {
    base.removeLast()
  }
  let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  guard !base.isEmpty else { return nil }
  return URL(string: "\(base)/\(trimmedPath)")
}

private func chatNativeHomeFetchData(request: URLRequest) async throws -> Data {
  let session: URLSession = {
    if #available(iOS 13.0, *) {
      return ChatPhoenixClient.makePinnedURLSession()
    }
    return URLSession.shared
  }()
  let (data, response) = try await session.data(for: request)

  guard let httpResponse = response as? HTTPURLResponse else {
    throw NSError(
      domain: "ChatNativeHome",
      code: 500,
      userInfo: [NSLocalizedDescriptionKey: "Invalid home response"]
    )
  }

  guard (200...299).contains(httpResponse.statusCode) else {
    let bodyText = String(data: data, encoding: .utf8) ?? ""
    throw NSError(
      domain: "ChatNativeHome",
      code: httpResponse.statusCode,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Home fetch failed with status \(httpResponse.statusCode): \(bodyText.prefix(120))"
      ]
    )
  }

  return data
}

private func chatNativeHomeParseChats(_ data: Data) throws -> [[String: Any]] {
  let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  if let chats = json as? [[String: Any]] {
    return chats
  }
  if let dict = json as? [String: Any], let chats = dict["data"] as? [[String: Any]] {
    return chats
  }
  if let dict = json as? [String: Any], let chats = dict["chats"] as? [[String: Any]] {
    return chats
  }
  if let items = json as? [Any] {
    return items.compactMap { $0 as? [String: Any] }
  }
  throw NSError(
    domain: "ChatNativeHome",
    code: 500,
    userInfo: [NSLocalizedDescriptionKey: "Invalid chats payload"]
  )
}

private final class ChatNativeHomePresentationDelegate: NSObject,
  UIAdaptivePresentationControllerDelegate
{
  var onDidDismiss: (() -> Void)?

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    onDidDismiss?()
  }
}

public class ChatNativeHomeModule: Module {
  private static let fallbackApiBaseURL = "https://api.vibegram.io"
  private var pendingNewChatPromise: Promise?
  private weak var pendingNewChatController: UIViewController?
  private let newChatPresentationDelegate = ChatNativeHomePresentationDelegate()

  public func definition() -> ModuleDefinition {
    Name("ChatNativeHome")

    Function("isSupported") {
      true
    }

    Function("supportsNativeHome") {
      true
    }

    AsyncFunction("fetchChats") { (payload: [String: Any]) async throws -> [String: Any] in
      guard let userId = chatNativeHomeNormalizedString(payload["userId"]) else {
        print("[ChatNativeHome] fetchChats ERROR: userId is nil or empty")
        throw NSError(
          domain: "ChatNativeHome",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "userId is required"]
        )
      }

      let transportMode =
        chatNativeHomeNormalizedString(payload["transportMode"])
        ?? (ChatEngine.shared.getTransportStatus()["transportMode"] as? String)
        ?? "direct"
      let apiBaseUrl =
        chatNativeHomeNormalizedString(payload["apiBaseUrl"])
        ?? Self.fallbackApiBaseURL
      let bridgeBaseUrl =
        chatNativeHomeNormalizedString(payload["bridgeBaseUrl"])
        ?? (ChatEngine.shared.getTransportStatus()["bridgeBaseUrl"] as? String)
      guard let url = chatNativeHomeBuildChatsURL(apiBaseUrl: apiBaseUrl, userId: userId) else {
        print("[ChatNativeHome] fetchChats ERROR: invalid apiBaseUrl=\(apiBaseUrl)")
        throw NSError(
          domain: "ChatNativeHome",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Invalid apiBaseUrl"]
        )
      }

      let authToken = chatNativeHomeNormalizedString(payload["authToken"])
      let tokenPrefix = authToken.map { String($0.prefix(8)) } ?? "nil"
      print(
        "[ChatNativeHome] fetchChats url=\(url.absoluteString) userId=\(userId.prefix(12))... tokenLen=\(authToken?.count ?? 0) tokenPrefix=\(tokenPrefix)"
      )

      var request: URLRequest
      if transportMode == "bridge_text",
        let bridgeBaseUrl,
        let bridgeURL = chatNativeHomeBuildBridgeURL(
          bridgeBaseUrl: bridgeBaseUrl,
          path: "/bridge/v1/home/snapshot"
        )
      {
        request = URLRequest(url: bridgeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
          withJSONObject: ["userId": userId],
          options: []
        )
      } else {
        request = URLRequest(url: url)
        request.httpMethod = "GET"
      }
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if let authToken, !authToken.isEmpty {
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
      }

      let data = try await chatNativeHomeFetchData(request: request)
      let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
      print(
        "[ChatNativeHome] fetchChats response bytes=\(data.count) body=\(bodyPreview)"
      )

      let chats = try chatNativeHomeParseChats(data)
      print("[ChatNativeHome] fetchChats parsed \(chats.count) chats")
      return ["chats": chats]
    }

    AsyncFunction("presentNativeNewChat") {
      [weak self] (payload: [String: Any], promise: Promise) in
      guard let self else {
        promise.resolve(["action": "cancel"])
        return
      }
      DispatchQueue.main.async {
        self.presentNativeNewChat(payload: payload, promise: promise)
      }
    }
  }

  private func presentNativeNewChat(payload: [String: Any], promise: Promise) {
    print("[ChatNativeHome] presentNativeNewChat requested")
    guard pendingNewChatPromise == nil else {
      print("[ChatNativeHome] presentNativeNewChat busy")
      promise.resolve(["action": "busy"])
      return
    }
    guard let presenter = topMostViewController() else {
      print("[ChatNativeHome] presentNativeNewChat error=no_presenter")
      promise.resolve([
        "action": "error",
        "error": "No active presenter found",
      ])
      return
    }

    let currentUserId = chatNativeHomeNormalizedString(payload["userId"]) ?? ""
    let authToken = chatNativeHomeNormalizedString(payload["authToken"])
    let apiBaseUrl =
      chatNativeHomeNormalizedString(payload["apiBaseUrl"])
      ?? Self.fallbackApiBaseURL
    let transportMode =
      chatNativeHomeNormalizedString(payload["transportMode"])
      ?? (ChatEngine.shared.getTransportStatus()["transportMode"] as? String)
      ?? "direct"

    if transportMode == "bridge_text" {
      promise.resolve([
        "action": "error",
        "error": "New chat search is disabled in blackout mode",
      ])
      return
    }

    let controller = ChatNativeNewChatViewController(
      apiBaseUrl: apiBaseUrl,
      authToken: authToken,
      currentUserId: currentUserId,
      themePayload: payload["theme"] as? [String: Any]
    )
    controller.onResult = { [weak self] result in
      self?.completeNewChatFlow(result: result)
    }

    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .pageSheet
    if let sheet = navigationController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 24
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    newChatPresentationDelegate.onDidDismiss = { [weak self] in
      guard self?.pendingNewChatController != nil else { return }
      print("[ChatNativeHome] presentationControllerDidDismiss -> cancel")
      self?.completeNewChatFlow(result: ["action": "cancel"])
    }
    navigationController.presentationController?.delegate = newChatPresentationDelegate

    pendingNewChatPromise = promise
    pendingNewChatController = navigationController
    presenter.present(navigationController, animated: true)
    print("[ChatNativeHome] presentNativeNewChat presented")
  }

  private func completeNewChatFlow(result: [String: Any]) {
    guard let promise = pendingNewChatPromise else { return }
    let action = (result["action"] as? String) ?? "unknown"
    print("[ChatNativeHome] completeNewChatFlow action=\(action)")
    let presentedController = pendingNewChatController
    newChatPresentationDelegate.onDidDismiss = nil
    pendingNewChatPromise = nil
    pendingNewChatController = nil

    if let presentedController, presentedController.presentingViewController != nil {
      presentedController.dismiss(animated: true) {
        promise.resolve(result)
      }
    } else {
      promise.resolve(result)
    }
  }

  private func topMostViewController() -> UIViewController? {
    let root =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow })?.rootViewController
      ?? UIApplication.shared.delegate?.window??.rootViewController

    guard let root else { return nil }
    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }
}
