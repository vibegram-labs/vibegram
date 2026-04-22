import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let navigationController = UINavigationController(
      rootViewController: initialViewController()
    )
    navigationController.navigationBar.prefersLargeTitles = true

    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = navigationController
    window.makeKeyAndVisible()

    self.window = window
    return true
  }

  private func initialViewController() -> UIViewController {
    if AppSessionConfig.current != nil {
      return ChatHomeViewController()
    }
    return WelcomeViewController()
  }
}
