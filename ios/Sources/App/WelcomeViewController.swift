import UIKit

final class WelcomeViewController: UIViewController {
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let continueButton = UIButton(type: .system)

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Welcome"
    view.backgroundColor = .systemBackground

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
    titleLabel.text = "Vibe"
    titleLabel.textAlignment = .center

    bodyLabel.translatesAutoresizingMaskIntoConstraints = false
    bodyLabel.font = .systemFont(ofSize: 17, weight: .regular)
    bodyLabel.textColor = .secondaryLabel
    bodyLabel.numberOfLines = 0
    bodyLabel.textAlignment = .center
    bodyLabel.text =
      "This native shell boots without Expo, stores auth locally, and opens the extracted home experience."

    continueButton.translatesAutoresizingMaskIntoConstraints = false
    continueButton.configuration = .filled()
    continueButton.configuration?.title = "Continue"
    continueButton.addTarget(self, action: #selector(handleContinue), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel, continueButton])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 20
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      continueButton.heightAnchor.constraint(equalToConstant: 52),
    ])
  }

  @objc private func handleContinue() {
    navigationController?.pushViewController(AuthViewController(), animated: true)
  }
}
