import UIKit

final class AuthViewController: UIViewController, UITextFieldDelegate {
  private let apiField = UITextField()
  private let socketField = UITextField()
  private let userField = UITextField()
  private let tokenField = UITextField()
  private let transportField = UITextField()
  private let saveButton = UIButton(type: .system)
  private let footerLabel = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Native Auth"
    view.backgroundColor = .systemBackground

    configureField(apiField, title: "API Base URL", text: AppSessionConfig.current?.apiBaseURLString ?? "https://api.vibegram.io")
    configureField(socketField, title: "Socket URL", text: AppSessionConfig.current?.socketURLString)
    configureField(userField, title: "User ID", text: AppSessionConfig.current?.userID)
    configureField(tokenField, title: "Auth Token", text: AppSessionConfig.current?.authToken)
    configureField(transportField, title: "Transport Mode", text: AppSessionConfig.current?.transportMode.rawValue ?? PacketTransportMode.direct.rawValue)
    tokenField.isSecureTextEntry = true
    tokenField.textContentType = .password

    saveButton.translatesAutoresizingMaskIntoConstraints = false
    saveButton.configuration = .filled()
    saveButton.configuration?.title = "Save and Open Home"
    saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)

    footerLabel.translatesAutoresizingMaskIntoConstraints = false
    footerLabel.font = .systemFont(ofSize: 13, weight: .regular)
    footerLabel.textColor = .secondaryLabel
    footerLabel.numberOfLines = 0
    footerLabel.text =
      "The native app stores the token in secure storage and uses the same API shape as the old home module."

    let stack = UIStackView(arrangedSubviews: [apiField, socketField, userField, tokenField, transportField, saveButton, footerLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 14
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      saveButton.heightAnchor.constraint(equalToConstant: 52),
    ])
  }

  private func configureField(_ field: UITextField, title: String, text: String?) {
    field.translatesAutoresizingMaskIntoConstraints = false
    field.borderStyle = .roundedRect
    field.placeholder = title
    field.text = text
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.delegate = self
  }

  @objc private func handleSave() {
    let userID = userField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let token = tokenField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let apiBaseURL = apiField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let transportMode = PacketTransportMode(transportField.text)

    guard !userID.isEmpty, !token.isEmpty, !apiBaseURL.isEmpty else {
      presentAlert(title: "Missing fields", message: "API base URL, user ID, and token are required.")
      return
    }

    let config = AppSessionConfig(
      apiBaseURLString: apiBaseURL,
      socketURLString: socketField.text,
      userID: userID,
      authToken: token,
      transportMode: transportMode
    )
    var payload = ChatEngineStore.shared.getConfig()
    config.payload.forEach { payload[$0.key] = $0.value }
    ChatEngineStore.shared.setConfig(payload)
    if let savedConfig = AppSessionConfig.current {
      Task.detached {
        await PacketBootstrapService.prefetchIfNeeded(config: savedConfig)
      }
    }
    navigationController?.setViewControllers([ChatHomeViewController()], animated: true)
  }

  private func presentAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
