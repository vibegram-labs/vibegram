import UIKit
import UserNotifications
import OSLog

private let appDelegateUITraceLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "UITrace"
)

private func appDelegateUITrace(_ message: String) {
  appDelegateUITraceLogger.notice("\(message, privacy: .public)")
  NSLog("[VibeUITrace] %@", message)
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    appDelegateUITrace("AppDelegate didFinishLaunching")
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = AppRootControllerFactory.makeInitialController()
    AppAppearanceController.applyStoredPreference(to: window)
    window.makeKeyAndVisible()

    self.window = window
    configureCallNotifications()
    VibeNativeCallManager.shared.start()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidReceiveMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
    return true
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate didBecomeActive")
  }

  func applicationWillResignActive(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate willResignActive")
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate didEnterBackground")
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate willEnterForeground")
  }

  func applicationWillTerminate(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate willTerminate")
  }

  @objc private func handleDidReceiveMemoryWarning() {
    appDelegateUITrace("AppDelegate didReceiveMemoryWarning")
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    let handled = VibeNativeCallManager.shared.handleRemoteNotification(
      userInfo: userInfo,
      preferSystemUI: application.applicationState != .active
    )
    completionHandler(handled ? .newData : .noData)
  }

  private func configureCallNotifications() {
    let accept = UNNotificationAction(
      identifier: VibeNativeCallManager.foregroundCallAcceptAction,
      title: "Accept",
      options: [.foreground]
    )
    let decline = UNNotificationAction(
      identifier: VibeNativeCallManager.foregroundCallDeclineAction,
      title: "Decline",
      options: [.destructive]
    )
    let category = UNNotificationCategory(
      identifier: VibeNativeCallManager.foregroundCallCategoryIdentifier,
      actions: [accept, decline],
      intentIdentifiers: [],
      options: []
    )
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([category])
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      NSLog(
        "[VibeNativeCall] foreground notification auth granted=%@ error=%@",
        granted ? "true" : "false",
        error?.localizedDescription ?? "nil"
      )
      guard granted else { return }
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    VibeNativeCallManager.shared.setApnsDeviceToken(deviceToken)
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("[VibeNativeCall] APNs registration failed error=%@", error.localizedDescription)
    VibeNativeCallManager.shared.clearApnsDeviceToken()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard notification.request.content.categoryIdentifier == VibeNativeCallManager.foregroundCallCategoryIdentifier else {
      completionHandler([])
      return
    }
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer { completionHandler() }
    guard response.notification.request.content.categoryIdentifier == VibeNativeCallManager.foregroundCallCategoryIdentifier else {
      return
    }
    let payload = response.notification.request.content.userInfo.reduce(into: [String: Any]()) {
      $0[String(describing: $1.key)] = $1.value
    }
    switch response.actionIdentifier {
    case VibeNativeCallManager.foregroundCallAcceptAction:
      _ = VibeNativeCallEngine.shared.acceptIncoming(payload)
    case VibeNativeCallManager.foregroundCallDeclineAction:
      _ = VibeNativeCallEngine.shared.endCall(payload)
    default:
      _ = VibeNativeCallEngine.shared.handleSignal(payload)
    }
  }
}
