import ExpoModulesCore
import Foundation

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

private func chatNativeHomeFetchData(request: URLRequest, timeout: TimeInterval) throws -> Data {
  let semaphore = DispatchSemaphore(value: 0)
  var responseData: Data?
  var response: URLResponse?
  var responseError: Error?

  let task = URLSession.shared.dataTask(with: request) { data, urlResponse, error in
    responseData = data
    response = urlResponse
    responseError = error
    semaphore.signal()
  }

  task.resume()

  if semaphore.wait(timeout: .now() + timeout) == .timedOut {
    task.cancel()
    throw NSError(
      domain: "ChatNativeHome",
      code: 408,
      userInfo: [NSLocalizedDescriptionKey: "Home fetch timed out"]
    )
  }

  if let responseError {
    throw responseError
  }

  guard let httpResponse = response as? HTTPURLResponse else {
    throw NSError(
      domain: "ChatNativeHome",
      code: 500,
      userInfo: [NSLocalizedDescriptionKey: "Invalid home response"]
    )
  }

  guard (200...299).contains(httpResponse.statusCode) else {
    let bodyText: String
    if let responseData {
      bodyText = String(data: responseData, encoding: .utf8) ?? ""
    } else {
      bodyText = ""
    }
    throw NSError(
      domain: "ChatNativeHome",
      code: httpResponse.statusCode,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Home fetch failed with status \(httpResponse.statusCode): \(bodyText.prefix(120))"
      ]
    )
  }

  guard let responseData else {
    throw NSError(
      domain: "ChatNativeHome",
      code: 500,
      userInfo: [NSLocalizedDescriptionKey: "Home response body is empty"]
    )
  }

  return responseData
}

private func chatNativeHomeParseChats(_ data: Data) throws -> [[String: Any]] {
  let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  if let chats = json as? [[String: Any]] {
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

public class ChatNativeHomeModule: Module {
  private static let fallbackApiBaseURL = "https://modest-recreation-production-8329.up.railway.app"

  public func definition() -> ModuleDefinition {
    Name("ChatNativeHome")

    Function("isSupported") {
      true
    }

    Function("supportsNativeHome") {
      true
    }

    AsyncFunction("fetchChats") { (payload: [String: Any]) throws -> [String: Any] in
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
      request.timeoutInterval = 25.0
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if let authToken, !authToken.isEmpty {
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
      }

      let data = try chatNativeHomeFetchData(request: request, timeout: 27.0)
      let chats = try chatNativeHomeParseChats(data)
      return ["chats": chats]
    }
  }
}
