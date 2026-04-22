import UIKit

final class ChatProfileMediaGridRowCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileMediaGridRowCell"

  // Use array for up to 3 thumbnails
  let thumbnails: [ChatMainProfileMediaCellNode] = [
    ChatMainProfileMediaCellNode(),
    ChatMainProfileMediaCellNode(),
    ChatMainProfileMediaCellNode(),
  ]

  var onMediaTapped: ((Int) -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    for (index, node) in thumbnails.enumerated() {
      node.tag = index
      node.addTarget(self, action: #selector(handleNodeTap(_:)), for: .touchUpInside)
      contentView.addSubview(node)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let columns = 3
    let gap: CGFloat = 2.0
    let totalWidth = contentView.bounds.width
    let padding: CGFloat = 16.0
    let availableWidth = max(0.0, totalWidth - padding * 2.0 - gap * CGFloat(columns - 1))
    let itemWidth = floor(availableWidth / CGFloat(columns))
    
    for i in 0..<columns {
      let x = padding + CGFloat(i) * (itemWidth + gap)
      // Cell is a square
      thumbnails[i].frame = CGRect(x: x, y: gap, width: itemWidth, height: itemWidth)
    }
  }

  @objc private func handleNodeTap(_ sender: ChatMainProfileMediaCellNode) {
    onMediaTapped?(sender.tag)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    for node in thumbnails {
      node.isHidden = true
    }
  }

  func configure(items: [(url: String?, isVideo: Bool, thumbnailBase64: String?)], startIndex: Int, placeholderTintColor: UIColor, placeholderBackgroundColor: UIColor) {
    for i in 0..<thumbnails.count {
      let node = thumbnails[i]
      node.applyTheme(placeholderTintColor: placeholderTintColor, placeholderBackgroundColor: placeholderBackgroundColor)
      
      if i < items.count {
        node.isHidden = false
        node.tag = startIndex + i // absolute index
        let item = items[i]
        node.configure(urlString: item.url, isVideo: item.isVideo, thumbnailBase64: item.thumbnailBase64)
      } else {
        node.isHidden = true
      }
    }
  }
}
