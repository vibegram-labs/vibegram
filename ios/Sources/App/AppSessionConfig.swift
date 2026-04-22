import Foundation

struct AppSessionConfig {
  let apiBaseURL: URL
  let apiBaseURLString: String
  let socketURLString: String
  let userID: String
  let authToken: String
  let transportMode: PacketTransportMode
  let username: String?
  let secureID: String?
  let publicKeyPem: String?
  let privateKeyPem: String?
  let encryptedPrivateKey: String?
  let tokenExpiresAt: String?
  let identityKey: String?
  let phoneNumber: String?

  static var defaultAPIBaseURLString: String {
    ChatAvatarURLResolver.resolvedAPIBaseURL()?.absoluteString ?? "https://api.vibegram.io"
  }

  static var current: AppSessionConfig? {
    AppSessionConfig(payload: ChatEngineStore.shared.getConfig())
  }

  init?(payload: [String: Any]) {
    let apiBaseURLString =
      Self.normalizedString(payload["apiBaseUrl"] ?? payload["baseUrl"])
      ?? Self.defaultAPIBaseURLString
    guard let apiBaseURL = URL(string: apiBaseURLString),
      let userID = Self.normalizedString(payload["userId"]),
      let authToken = Self.normalizedString(
        payload["authToken"] ?? payload["token"] ?? payload["loginToken"])
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
    self.username = Self.normalizedString(payload["username"])
    self.secureID = Self.normalizedString(payload["secureId"])
    self.publicKeyPem =
      Self.normalizedString(payload["publicKeyPem"] ?? payload["publicKey"])
    self.privateKeyPem =
      Self.normalizedString(payload["privateKeyPem"] ?? payload["privateKey"])
    self.encryptedPrivateKey = Self.normalizedString(payload["encryptedPrivateKey"])
    self.tokenExpiresAt = Self.normalizedString(payload["tokenExpiresAt"])
    self.identityKey = Self.normalizedString(payload["identityKey"])
    self.phoneNumber = Self.normalizedString(payload["phoneNumber"])
  }

  init(
    apiBaseURLString: String,
    socketURLString: String?,
    userID: String,
    authToken: String,
    transportMode: PacketTransportMode = .packetMesh,
    username: String? = nil,
    secureID: String? = nil,
    publicKeyPem: String? = nil,
    privateKeyPem: String? = nil,
    encryptedPrivateKey: String? = nil,
    tokenExpiresAt: String? = nil,
    identityKey: String? = nil,
    phoneNumber: String? = nil
  ) {
    let normalizedAPI =
      apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    self.apiBaseURLString = normalizedAPI
    self.apiBaseURL = URL(string: normalizedAPI) ?? URL(string: Self.defaultAPIBaseURLString)!
    self.socketURLString =
      socketURLString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? socketURLString!.trimmingCharacters(in: .whitespacesAndNewlines)
      : Self.derivedSocketURL(from: normalizedAPI)
    self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    self.transportMode = transportMode
    self.username = Self.normalizedString(username)
    self.secureID = Self.normalizedString(secureID)
    self.publicKeyPem = Self.normalizedString(publicKeyPem)
    self.privateKeyPem = Self.normalizedString(privateKeyPem)
    self.encryptedPrivateKey = Self.normalizedString(encryptedPrivateKey)
    self.tokenExpiresAt = Self.normalizedString(tokenExpiresAt)
    self.identityKey = Self.normalizedString(identityKey)
    self.phoneNumber = Self.normalizedString(phoneNumber)
  }

  var payload: [String: Any] {
    var value: [String: Any] = [
      "apiBaseUrl": apiBaseURLString,
      "baseUrl": apiBaseURLString,
      "socketUrl": socketURLString,
      "url": socketURLString,
      "userId": userID,
      "authToken": authToken,
      "token": authToken,
      "loginToken": authToken,
      "userChannelTopic": "user:\(userID)",
      "transportMode": transportMode.rawValue,
      "identityKey": identityKey ?? "v2",
    ]
    if let username { value["username"] = username }
    if let secureID { value["secureId"] = secureID }
    if let publicKeyPem {
      value["publicKeyPem"] = publicKeyPem
      value["publicKey"] = publicKeyPem
    }
    if let privateKeyPem {
      value["privateKeyPem"] = privateKeyPem
      value["privateKey"] = privateKeyPem
    }
    if let encryptedPrivateKey { value["encryptedPrivateKey"] = encryptedPrivateKey }
    if let tokenExpiresAt { value["tokenExpiresAt"] = tokenExpiresAt }
    if let phoneNumber { value["phoneNumber"] = phoneNumber }
    return value
  }

  var bootstrapURL: URL? {
    var base = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    return URL(string: "\(base)/packet/bootstrap")
  }

  static func store(_ config: AppSessionConfig) {
    ChatEngineStore.shared.clearConfig()
    ChatEngineStore.shared.setConfig(config.payload)
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
    var path =
      components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path.lowercased().hasSuffix("api") {
      path =
        String(path.dropLast(3))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    components.path = "/" + path
    if !components.path.hasSuffix("/socket") {
      components.path =
        components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      components.path =
        components.path.isEmpty ? "/socket" : "/\(components.path)/socket"
    }
    return components.string ?? "wss://api.vibegram.io/socket"
  }
}
