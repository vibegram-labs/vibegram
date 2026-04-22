import Foundation

struct AppSessionConfig {
  let apiBaseURL: URL
  let apiBaseURLString: String
  let socketURLString: String
  let userID: String
  let authToken: String
  let transportMode: PacketTransportMode

  static var current: AppSessionConfig? {
    AppSessionConfig(payload: ChatEngineStore.shared.getConfig())
  }

  init?(payload: [String: Any]) {
    let apiBaseURLString =
      Self.normalizedString(payload["apiBaseUrl"] ?? payload["baseUrl"])
      ?? ChatAvatarURLResolver.resolvedAPIBaseURL()?.absoluteString
      ?? "https://api.vibegram.io"
    guard let apiBaseURL = URL(string: apiBaseURLString),
      let userID = Self.normalizedString(payload["userId"]),
      let authToken = Self.normalizedString(payload["authToken"] ?? payload["token"])
    else {
      return nil
    }

    self.apiBaseURL = apiBaseURL
    self.apiBaseURLString = apiBaseURLString
    self.socketURLString =
      Self.normalizedString(payload["socketUrl"] ?? payload["url"])
      ?? Self.derivedSocketURL(from: apiBaseURLString)
    self.userID = userID
    self.authToken = authToken
    self.transportMode = PacketTransportMode(payload["transportMode"])
  }

  init(
    apiBaseURLString: String,
    socketURLString: String?,
    userID: String,
    authToken: String,
    transportMode: PacketTransportMode = .direct
  ) {
    let normalizedAPI = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    self.apiBaseURLString = normalizedAPI
    self.apiBaseURL = URL(string: normalizedAPI) ?? URL(string: "https://api.vibegram.io")!
    self.socketURLString =
      socketURLString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? socketURLString!.trimmingCharacters(in: .whitespacesAndNewlines)
      : Self.derivedSocketURL(from: normalizedAPI)
    self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    self.transportMode = transportMode
  }

  var payload: [String: Any] {
    [
      "apiBaseUrl": apiBaseURLString,
      "baseUrl": apiBaseURLString,
      "socketUrl": socketURLString,
      "url": socketURLString,
      "userId": userID,
      "authToken": authToken,
      "token": authToken,
      "userChannelTopic": "user:\(userID)",
      "transportMode": transportMode.rawValue,
    ]
  }

  var bootstrapURL: URL? {
    var base = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    return URL(string: "\(base)/packet/bootstrap")
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func derivedSocketURL(from apiBaseURLString: String) -> String {
    guard var components = URLComponents(string: apiBaseURLString) else {
      return "wss://api.vibegram.io/socket"
    }
    if components.scheme == "https" {
      components.scheme = "wss"
    } else if components.scheme == "http" {
      components.scheme = "ws"
    }
    var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path.lowercased().hasSuffix("api") {
      path = String(path.dropLast(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    components.path = "/" + path
    if !components.path.hasSuffix("/socket") {
      components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      components.path = components.path.isEmpty ? "/socket" : "/\(components.path)/socket"
    }
    return components.string ?? "wss://api.vibegram.io/socket"
  }
}
