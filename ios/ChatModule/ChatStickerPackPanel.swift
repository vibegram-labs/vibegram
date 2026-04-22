import Lottie
import UIKit

// MARK: - Selection

struct ChatStickerSelection {
  let stickerId: String
  let packId: String
  let bundleFileName: String?
  let remoteUrl: String?
  let emoji: String?
  let width: Int
  let height: Int
}

// MARK: - Delegate

protocol ChatStickerPackPanelDelegate: AnyObject {
  func stickerPackPanel(
    _ panel: ChatStickerPackPanel, didSelectSticker sticker: ChatStickerSelection)
}

// MARK: - Lottie Sticker Cell

private final class LottieStickerCell: UICollectionViewCell {
  static let reuseIdentifier = "LottieStickerCell"

  private var animationView: LottieAnimationView?
  private var currentFileName: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.clipsToBounds = true
    contentView.layer.cornerRadius = 12
    contentView.layer.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) { nil }

  func configure(sticker: StickerPackSticker) {
    let fileName = sticker.bundleFileName ?? sticker.id
    guard fileName != currentFileName else { return }
    currentFileName = fileName

    animationView?.stop()
    animationView?.removeFromSuperview()
    animationView = nil

    guard let filePath = ChatStickerPackStore.shared.lottieFilePath(for: sticker) else {
      showFallback(sticker: sticker)
      return
    }

    let animation = LottieAnimation.filepath(filePath)
    let view = LottieAnimationView(animation: animation)
    view.contentMode = .scaleAspectFit
    view.loopMode = .loop
    view.backgroundBehavior = .pauseAndRestore
    view.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
      view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
      view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
    ])
    animationView = view
    view.play()
  }

  func configureRecent(recent: RecentSticker) {
    let fileName = recent.bundleFileName ?? recent.stickerId
    guard fileName != currentFileName else { return }
    currentFileName = fileName

    animationView?.stop()
    animationView?.removeFromSuperview()
    animationView = nil

    // Build a temporary sticker to resolve file path
    let sticker = StickerPackSticker(
      id: recent.stickerId, packId: recent.packId,
      bundleFileName: recent.bundleFileName, remoteUrl: recent.remoteUrl,
      emoji: nil, width: 512, height: 512)
    guard let filePath = ChatStickerPackStore.shared.lottieFilePath(for: sticker) else {
      showFallbackEmoji("📦")
      return
    }

    let animation = LottieAnimation.filepath(filePath)
    let view = LottieAnimationView(animation: animation)
    view.contentMode = .scaleAspectFit
    view.loopMode = .loop
    view.backgroundBehavior = .pauseAndRestore
    view.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
      view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
      view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
    ])
    animationView = view
    view.play()
  }

  private func showFallback(sticker: StickerPackSticker) {
    showFallbackEmoji(sticker.emoji ?? "📦")
  }

  private func showFallbackEmoji(_ emoji: String) {
    let label = UILabel()
    label.text = emoji
    label.font = .systemFont(ofSize: 40)
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    animationView?.stop()
    animationView?.removeFromSuperview()
    animationView = nil
    currentFileName = nil
    contentView.subviews.forEach { $0.removeFromSuperview() }
  }

  func pauseAnimation() {
    animationView?.pause()
  }

  func resumeAnimation() {
    animationView?.play()
  }
}

// MARK: - Section Header

private final class StickerSectionHeader: UICollectionReusableView {
  static let reuseIdentifier = "StickerSectionHeader"

  private let titleLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(titleLabel)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func configure(title: String, color: UIColor) {
    titleLabel.text = title.uppercased()
    titleLabel.textColor = color
  }
}

// MARK: - Panel

final class ChatStickerPackPanel: UIView {
  weak var delegate: ChatStickerPackPanelDelegate?

  private let store = ChatStickerPackStore.shared

  // Currently displayed stickers
  private var selectedPackId: String?
  private var displayMode: DisplayMode = .recent

  fileprivate enum DisplayMode {
    case recent
    case pack(String)
  }

  // UI
  private let packStripScrollView = UIScrollView()
  private let packStripStack = UIStackView()
  private let collectionView: UICollectionView
  private let emptyLabel = UILabel()
  private let selectionFeedback = UISelectionFeedbackGenerator()
  private var searchQuery: String = ""
  private var packStripHeightConstraint: NSLayoutConstraint?

  var contentScrollView: UIScrollView { collectionView }

  override init(frame: CGRect) {
    let layout = UICollectionViewFlowLayout()
    layout.minimumLineSpacing = 8
    layout.minimumInteritemSpacing = 8
    layout.sectionInset = UIEdgeInsets(top: 4, left: 12, bottom: 12, right: 12)
    layout.headerReferenceSize = CGSize(width: 100, height: 30)
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    super.init(frame: frame)
    setupUI()
    rebuildPackStrip()
    updatePackStripVisibility()
    reloadDisplayedStickers()
  }

  required init?(coder: NSCoder) { nil }

  // MARK: - Setup

  private func setupUI() {
    backgroundColor = .clear

    // Pack tab strip
    packStripScrollView.translatesAutoresizingMaskIntoConstraints = false
    packStripScrollView.showsHorizontalScrollIndicator = false
    packStripScrollView.alwaysBounceHorizontal = true
    packStripScrollView.backgroundColor = .clear
    packStripScrollView.isHidden = true
    addSubview(packStripScrollView)

    packStripStack.translatesAutoresizingMaskIntoConstraints = false
    packStripStack.axis = .horizontal
    packStripStack.alignment = .center
    packStripStack.spacing = 4
    packStripScrollView.addSubview(packStripStack)

    // Collection view
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    collectionView.keyboardDismissMode = .onDrag
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(
      LottieStickerCell.self,
      forCellWithReuseIdentifier: LottieStickerCell.reuseIdentifier)
    collectionView.register(
      StickerSectionHeader.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: StickerSectionHeader.reuseIdentifier)
    addSubview(collectionView)

    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyLabel.text = "No stickers yet"
    emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
    emptyLabel.textAlignment = .center
    emptyLabel.numberOfLines = 0
    emptyLabel.isHidden = true
    addSubview(emptyLabel)

    let packStripHeightConstraint = packStripScrollView.heightAnchor.constraint(equalToConstant: 0)
    self.packStripHeightConstraint = packStripHeightConstraint

    NSLayoutConstraint.activate([
      packStripScrollView.topAnchor.constraint(equalTo: topAnchor),
      packStripScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      packStripScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      packStripHeightConstraint,

      packStripStack.leadingAnchor.constraint(
        equalTo: packStripScrollView.contentLayoutGuide.leadingAnchor, constant: 12),
      packStripStack.trailingAnchor.constraint(
        equalTo: packStripScrollView.contentLayoutGuide.trailingAnchor, constant: -12),
      packStripStack.topAnchor.constraint(
        equalTo: packStripScrollView.contentLayoutGuide.topAnchor),
      packStripStack.bottomAnchor.constraint(
        equalTo: packStripScrollView.contentLayoutGuide.bottomAnchor),
      packStripStack.heightAnchor.constraint(
        greaterThanOrEqualTo: packStripScrollView.frameLayoutGuide.heightAnchor),

      collectionView.topAnchor.constraint(equalTo: packStripScrollView.bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

      emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 20),
    ])

    selectionFeedback.prepare()
  }

  // MARK: - Pack Strip

  private func rebuildPackStrip() {
    packStripStack.arrangedSubviews.forEach {
      packStripStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }

    // Recent button
    let recentBtn = makePackButton(
      title: "🕘",
      selected: displayMode.isRecent,
      tag: -1
    )
    recentBtn.addTarget(self, action: #selector(recentTapped), for: .touchUpInside)
    packStripStack.addArrangedSubview(recentBtn)

    // Pack buttons
    for (index, pack) in store.installedPacks.enumerated() {
      let isSelected: Bool = {
        if case .pack(let id) = displayMode { return id == pack.id }
        return false
      }()
      let btn = makePackButton(title: pack.icon, selected: isSelected, tag: index)
      btn.addTarget(self, action: #selector(packTapped(_:)), for: .touchUpInside)
      packStripStack.addArrangedSubview(btn)
    }
    updatePackStripVisibility()
  }

  private func updatePackStripVisibility() {
    let shouldShow = false
    packStripScrollView.isHidden = !shouldShow
    packStripHeightConstraint?.constant = shouldShow ? 36 : 0
  }

  private func makePackButton(title: String, selected: Bool, tag: Int) -> UIButton {
    let btn = UIButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.setTitle(title, for: .normal)
    btn.titleLabel?.font = .systemFont(ofSize: 24)
    btn.tag = tag

    let isDark = traitCollection.userInterfaceStyle == .dark
    btn.backgroundColor =
      selected
      ? (isDark ? UIColor.white.withAlphaComponent(0.18) : UIColor.black.withAlphaComponent(0.10))
      : .clear
    btn.layer.cornerRadius = 18
    btn.layer.cornerCurve = .continuous

    NSLayoutConstraint.activate([
      btn.widthAnchor.constraint(equalToConstant: 44),
      btn.heightAnchor.constraint(equalToConstant: 36),
    ])

    return btn
  }

  // MARK: - Actions

  @objc private func recentTapped() {
    selectionFeedback.selectionChanged()
    displayMode = .recent
    selectedPackId = nil
    rebuildPackStrip()
    reloadDisplayedStickers()
  }

  @objc private func packTapped(_ sender: UIButton) {
    let index = sender.tag
    guard index >= 0, index < store.installedPacks.count else { return }
    let pack = store.installedPacks[index]
    selectionFeedback.selectionChanged()
    displayMode = .pack(pack.id)
    selectedPackId = pack.id
    rebuildPackStrip()
    reloadDisplayedStickers()
  }

  // MARK: - Display

  private var displayedStickers: [StickerPackSticker] = []
  private var displayedRecents: [RecentSticker] = []
  private var sectionTitle: String = ""

  private func reloadDisplayedStickers() {
    switch displayMode {
    case .recent:
      displayedRecents = store.recentStickers
      displayedStickers = []
      sectionTitle = "Recently Used"
    case .pack(let packId):
      displayedRecents = []
      displayedStickers = store.pack(byId: packId)?.stickers ?? []
      sectionTitle = store.pack(byId: packId)?.name ?? ""
    }

    let isEmpty = displayedStickers.isEmpty && displayedRecents.isEmpty
    emptyLabel.isHidden = !isEmpty
    let isDark = traitCollection.userInterfaceStyle == .dark
    emptyLabel.textColor =
      isDark
      ? UIColor(white: 0.84, alpha: 0.62) : UIColor(white: 0.12, alpha: 0.42)

    if !searchQuery.isEmpty {
      if displayMode.isRecent {
        displayedRecents = displayedRecents.filter { matchesSearch(recent: $0) }
      } else {
        displayedStickers = displayedStickers.filter { matchesSearch(sticker: $0) }
      }
    }

    let filteredIsEmpty = displayedStickers.isEmpty && displayedRecents.isEmpty
    emptyLabel.isHidden = !filteredIsEmpty

    if filteredIsEmpty && displayMode.isRecent {
      emptyLabel.text =
        searchQuery.isEmpty ? "Send a sticker to see it here" : "No recent stickers match."
    } else if filteredIsEmpty {
      emptyLabel.text = searchQuery.isEmpty ? "No stickers yet" : "No stickers found."
    }

    collectionView.reloadData()
  }

  func refreshContent() {
    rebuildPackStrip()
    reloadDisplayedStickers()
  }

  func setDisplayModeRecent() {
    displayMode = .recent
    selectedPackId = nil
    refreshContent()
  }

  func setDisplayedPack(id packId: String?) {
    let resolvedPackId = packId ?? store.installedPacks.first?.id
    guard let resolvedPackId else {
      setDisplayModeRecent()
      return
    }
    displayMode = .pack(resolvedPackId)
    selectedPackId = resolvedPackId
    refreshContent()
  }

  func setSearchQuery(_ query: String) {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized != searchQuery else { return }
    searchQuery = normalized
    reloadDisplayedStickers()
  }

  private func matchesSearch(sticker: StickerPackSticker) -> Bool {
    guard !searchQuery.isEmpty else { return true }
    let packName = store.pack(byId: sticker.packId)?.name ?? ""
    let haystack = [
      sticker.id,
      sticker.bundleFileName ?? "",
      sticker.emoji ?? "",
      sticker.packId,
      packName,
    ].joined(separator: " ").lowercased()
    return haystack.contains(searchQuery)
  }

  private func matchesSearch(recent: RecentSticker) -> Bool {
    if let sticker = store.sticker(byId: recent.stickerId) {
      return matchesSearch(sticker: sticker)
    }
    guard !searchQuery.isEmpty else { return true }
    let haystack = [
      recent.stickerId,
      recent.bundleFileName ?? "",
      recent.packId,
    ].joined(separator: " ").lowercased()
    return haystack.contains(searchQuery)
  }
}

// MARK: - DisplayMode helpers

fileprivate extension ChatStickerPackPanel.DisplayMode {
  var isRecent: Bool {
    if case .recent = self { return true }
    return false
  }
}

// MARK: - UICollectionView

extension ChatStickerPackPanel: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  func numberOfSections(in collectionView: UICollectionView) -> Int {
    1
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
    -> Int
  {
    displayMode.isRecent ? displayedRecents.count : displayedStickers.count
  }

  func collectionView(
    _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    guard
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: LottieStickerCell.reuseIdentifier, for: indexPath
      ) as? LottieStickerCell
    else { return UICollectionViewCell() }

    if displayMode.isRecent {
      guard indexPath.item < displayedRecents.count else { return cell }
      cell.configureRecent(recent: displayedRecents[indexPath.item])
    } else {
      guard indexPath.item < displayedStickers.count else { return cell }
      cell.configure(sticker: displayedStickers[indexPath.item])
    }
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    let sticker: StickerPackSticker

    if displayMode.isRecent {
      guard indexPath.item < displayedRecents.count else { return }
      let recent = displayedRecents[indexPath.item]
      sticker =
        store.sticker(byId: recent.stickerId)
        ?? StickerPackSticker(
          id: recent.stickerId, packId: recent.packId,
          bundleFileName: recent.bundleFileName, remoteUrl: recent.remoteUrl,
          emoji: nil, width: 512, height: 512)
    } else {
      guard indexPath.item < displayedStickers.count else { return }
      sticker = displayedStickers[indexPath.item]
    }

    store.recordUsed(sticker: sticker)
    selectionFeedback.selectionChanged()

    delegate?.stickerPackPanel(
      self,
      didSelectSticker: ChatStickerSelection(
        stickerId: sticker.id,
        packId: sticker.packId,
        bundleFileName: sticker.bundleFileName,
        remoteUrl: sticker.remoteUrl,
        emoji: sticker.emoji,
        width: sticker.width,
        height: sticker.height
      ))
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let columns: CGFloat = bounds.width < 360 ? 3 : 4
    let horizontalPadding: CGFloat = 24
    let spacing: CGFloat = 8 * (columns - 1)
    let width = floor((collectionView.bounds.width - horizontalPadding - spacing) / columns)
    return CGSize(width: max(60, width), height: max(60, width))
  }

  func collectionView(
    _ collectionView: UICollectionView,
    viewForSupplementaryElementOfKind kind: String,
    at indexPath: IndexPath
  ) -> UICollectionReusableView {
    guard
      kind == UICollectionView.elementKindSectionHeader,
      let header = collectionView.dequeueReusableSupplementaryView(
        ofKind: kind,
        withReuseIdentifier: StickerSectionHeader.reuseIdentifier,
        for: indexPath
      ) as? StickerSectionHeader
    else { return UICollectionReusableView() }

    let isDark = traitCollection.userInterfaceStyle == .dark
    let color =
      isDark
      ? UIColor(white: 0.84, alpha: 0.62) : UIColor(white: 0.12, alpha: 0.42)
    header.configure(title: sectionTitle, color: color)
    return header
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    referenceSizeForHeaderInSection section: Int
  ) -> CGSize {
    sectionTitle.isEmpty ? .zero : CGSize(width: collectionView.bounds.width, height: 30)
  }

  // Pause/resume Lottie on scroll for performance
  func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    (cell as? LottieStickerCell)?.resumeAnimation()
  }

  func collectionView(
    _ collectionView: UICollectionView,
    didEndDisplaying cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    (cell as? LottieStickerCell)?.pauseAnimation()
  }
}
