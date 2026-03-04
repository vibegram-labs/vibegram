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

private func chatNativeHomeFetchData(request: URLRequest) async throws -> Data {
  let (data, response) = try await URLSession.shared.data(for: request)

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
  private static let fallbackApiBaseURL = "https://modest-recreation-production-8329.up.railway.app"
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
        throw NSError(
          domain: "ChatNativeHome",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "userId is required"]
        )
      }

      let apiBaseUrl =
        chatNativeHomeNormalizedString(payload["apiBaseUrl"])
        ?? Self.fallbackApiBaseURL
      guard let url = chatNativeHomeBuildChatsURL(apiBaseUrl: apiBaseUrl, userId: userId) else {
        throw NSError(
          domain: "ChatNativeHome",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Invalid apiBaseUrl"]
        )
      }

      let authToken = chatNativeHomeNormalizedString(payload["authToken"])

      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if let authToken, !authToken.isEmpty {
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
      }

      let data = try await chatNativeHomeFetchData(request: request)
      let chats = try chatNativeHomeParseChats(data)
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
