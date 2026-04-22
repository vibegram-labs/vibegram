import UIKit

final class ChatGroupMembersViewController: UIViewController {
  struct MemberItem {
    let userId: String
    let name: String
    let roleLabel: String
    let isAdmin: Bool
  }

  var chatId: String = ""
  var members: [MemberItem] = []

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let backgroundBlur = UIVisualEffectView(effect: nil)
  private let emptyLabel = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    setup()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    backgroundBlur.frame = view.bounds
    tableView.frame = view.bounds
    emptyLabel.frame = CGRect(x: 24, y: 140, width: view.bounds.width - 48, height: 28)
  }

  private func setup() {
    title = "Members"
    view.backgroundColor = .clear

    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = false
      backgroundBlur.effect = effect
    } else {
      backgroundBlur.effect = UIBlurEffect(style: .systemMaterial)
    }
    view.addSubview(backgroundBlur)

    tableView.dataSource = self
    tableView.delegate = self
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "member_cell")
    view.addSubview(tableView)

    emptyLabel.textAlignment = .center
    emptyLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    emptyLabel.textColor = .secondaryLabel
    emptyLabel.text = "No members available"
    emptyLabel.isHidden = !members.isEmpty
    view.addSubview(emptyLabel)
  }
}

extension ChatGroupMembersViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    members.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "member_cell", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    let item = members[indexPath.row]

    content.text = item.name
    content.secondaryText =
      item.isAdmin ? "\(item.roleLabel) • \(item.userId.prefix(8))" : item.roleLabel
    content.textProperties.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    content.secondaryTextProperties.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    content.secondaryTextProperties.color = .secondaryLabel
    content.image = UIImage(systemName: item.isAdmin ? "star.circle.fill" : "person.circle")
    content.imageProperties.tintColor = item.isAdmin ? .systemYellow : .secondaryLabel
    content.imageToTextPadding = 12
    cell.contentConfiguration = content

    cell.backgroundColor = .clear
    var bg = UIBackgroundConfiguration.listGroupedCell()
    bg.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.55)
    bg.cornerRadius = 14
    cell.backgroundConfiguration = bg
    cell.selectionStyle = .none
    return cell
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    62
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
  }
}
