import UIKit
import WebKit

final class InAppBrowserViewController: UIViewController, WKNavigationDelegate {
  private let url: URL
  private let webView = WKWebView()
  private let progressView = UIProgressView(progressViewStyle: .default)

  init(url: URL) {
    self.url = url
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(dismissSelf)
    )
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareTapped)),
      UIBarButtonItem(title: "Open", style: .plain, target: self, action: #selector(openInSafari))
    ]

    webView.navigationDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)
    view.addSubview(progressView)
    progressView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
    loadURL()
  }

  deinit {
    webView.removeObserver(self, forKeyPath: "estimatedProgress")
  }

  private func loadURL() {
    webView.load(URLRequest(url: url))
    title = url.host
  }

  @objc private func dismissSelf() {
    dismiss(animated: true, completion: nil)
  }

  @objc private func shareTapped() {
    let items: [Any] = [url]
    let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
    if let pop = ac.popoverPresentationController {
      pop.barButtonItem = navigationItem.rightBarButtonItems?.first
    }
    present(ac, animated: true)
  }

  @objc private func openInSafari() {
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    if keyPath == "estimatedProgress" {
      progressView.progress = Float(webView.estimatedProgress)
      progressView.isHidden = progressView.progress >= 1.0
    }
  }

  // MARK: - presentation helper
  static func present(url: URL) {
    DispatchQueue.main.async {
      guard let top = UIApplication.topMostViewController() else { return }
      let vc = InAppBrowserViewController(url: url)
      let nav = UINavigationController(rootViewController: vc)
      nav.modalPresentationStyle = .pageSheet
      top.present(nav, animated: true, completion: nil)
    }
  }
}

extension UIApplication {
  func topMostViewController() -> UIViewController? {
    var rootVC = keyWindow?.rootViewController
    if rootVC == nil {
      rootVC = windows.first { $0.isKeyWindow }?.rootViewController
    }
    guard var top = rootVC else { return nil }
    while let presented = top.presentedViewController {
      top = presented
    }
    if let nav = top as? UINavigationController, let visible = nav.visibleViewController {
      top = visible
    }
    return top
  }
}
