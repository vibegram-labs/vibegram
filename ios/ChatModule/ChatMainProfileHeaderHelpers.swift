import UIKit

enum ChatMainProfileHeaderHelpers {
  static func applyProfileMenuButtonStyle(_ button: UIButton) {
    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.cornerStyle = .capsule
      config.image = UIImage(
        systemName: "ellipsis",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
      )
      config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
      button.configuration = config
      return
    }

    button.configuration = nil
    button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
  }

  static func buildProfileMenu(
    isMuted: Bool,
    onSearch: @escaping () -> Void,
    onToggleMute: @escaping () -> Void,
    onClearChat: @escaping () -> Void,
    onBlockUser: @escaping () -> Void
  ) -> UIMenu {
    let searchAction = UIAction(
      title: "Search in Chat",
      image: UIImage(systemName: "magnifyingglass")
    ) { _ in
      onSearch()
    }

    let muteAction = UIAction(
      title: isMuted ? "Unmute" : "Mute",
      image: UIImage(systemName: isMuted ? "bell" : "bell.slash")
    ) { _ in
      onToggleMute()
    }

    let clearAction = UIAction(
      title: "Clear Chat",
      image: UIImage(systemName: "trash"),
      attributes: .destructive
    ) { _ in
      onClearChat()
    }

    let blockAction = UIAction(
      title: "Block User",
      image: UIImage(systemName: "hand.raised"),
      attributes: .destructive
    ) { _ in
      onBlockUser()
    }

    return UIMenu(children: [searchAction, muteAction, clearAction, blockAction])
  }
}
