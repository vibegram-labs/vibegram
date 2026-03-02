import ExpoModulesCore
import UIKit

final class ChatNativeProfileView: ExpoView {
  private let profileMainView: ChatMainView

  public var onViewportChanged = EventDispatcher() {
    didSet { profileMainView.onViewportChanged = onViewportChanged }
  }

  public var onNativeEvent = EventDispatcher() {
    didSet { profileMainView.onNativeEvent = onNativeEvent }
  }

  @objc public var surfaceId: String = "" {
    didSet { profileMainView.surfaceId = surfaceId }
  }

  required init(appContext: AppContext? = nil) {
    profileMainView = ChatMainView(appContext: appContext)
    super.init(appContext: appContext)
    clipsToBounds = true
    addSubview(profileMainView)
    profileMainView.setStandaloneProfileMode(true)
    profileMainView.onViewportChanged = onViewportChanged
    profileMainView.onNativeEvent = onNativeEvent
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    profileMainView.frame = bounds
  }

  func setProfileOnly(_ value: Bool) {
    profileMainView.setStandaloneProfileMode(value)
  }

  func setRows(_ rows: [[String: Any]]) {
    profileMainView.setRows(rows)
  }

  func setEngineSurfaceId(_ value: String) {
    profileMainView.setEngineSurfaceId(value)
  }

  func setEngineChatId(_ value: String) {
    profileMainView.setEngineChatId(value)
  }

  func setEngineMyUserId(_ value: String) {
    profileMainView.setEngineMyUserId(value)
  }

  func setEnginePeerUserId(_ value: String) {
    profileMainView.setEnginePeerUserId(value)
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    profileMainView.setStatusAuthorityEnabled(enabled)
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    profileMainView.setAppearance(rawAppearance)
  }

  func setHeaderTitle(_ value: String) {
    profileMainView.setHeaderTitle(value)
  }

  func setHeaderSubtitle(_ value: String) {
    profileMainView.setHeaderSubtitle(value)
  }

  func setProfileName(_ value: String) {
    profileMainView.setProfileName(value)
  }

  func setProfileHandle(_ value: String) {
    profileMainView.setProfileHandle(value)
  }

  func setProfileBio(_ value: String) {
    profileMainView.setProfileBio(value)
  }

  func setAvatarUri(_ value: String?) {
    profileMainView.setAvatarUri(value)
  }

  func setIsOnline(_ value: Bool) {
    profileMainView.setIsOnline(value)
  }

  func setIsChatMuted(_ value: Bool) {
    profileMainView.setIsChatMuted(value)
  }

  func setIsGroupOrChannel(_ value: Bool) {
    profileMainView.setIsGroupOrChannel(value)
  }

  func setGroupMembers(_ members: [[String: Any]]) {
    profileMainView.setGroupMembers(members)
  }

  func setGroupMemberCount(_ value: Int?) {
    profileMainView.setGroupMemberCount(value)
  }

  func setAgentConfig(_ config: [String: Any]?) {
    profileMainView.setAgentConfig(config)
  }

  func setPage(_ value: String, animated: Bool) {
    profileMainView.setPage(value, animated: animated)
  }
}
