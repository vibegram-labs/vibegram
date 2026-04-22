import UIKit

#if canImport(GiphyUISDK)
    import GiphyUISDK
#endif

final class ChatGifPanelConfig {
    static let shared = ChatGifPanelConfig()

    private init() {}

    var apiKey: String = ""
}

struct ChatGifSelection {
    let id: String
    let url: String
    let previewUrl: String
    let width: Int
    let height: Int
}

protocol ChatGifPanelViewDelegate: AnyObject {
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectGif gif: ChatGifSelection)
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectSticker sticker: ChatStickerSelection)
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectEmoji emoji: String)
    func chatGifPanelDidRequestClose(_ panel: ChatGifPanelView)
}

private enum ChatGifPanelTab: Int, CaseIterable {
    case gifs = 0
    case stickers = 1
    case emoji = 2

    var title: String {
        switch self {
        case .gifs: return "GIFs"
        case .stickers: return "Stickers"
        case .emoji: return "Emoji"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .gifs: return "Search GIFs"
        case .stickers: return "Search stickers"
        case .emoji: return "Search emoji"
        }
    }
}

private struct ChatGifQuickFilter {
    let id: String
    let title: String
    let query: String
}

private enum ChatEmojiCategory: String, CaseIterable {
    case recent
    case smileys
    case love
    case gestures
    case party
    case sad
    case angry
    case neutral

    static let browseCases: [ChatEmojiCategory] = [
        .smileys, .love, .gestures, .party, .sad, .angry, .neutral,
    ]

    var title: String {
        switch self {
        case .recent: return "Recently Used"
        case .smileys: return "Kawaii Emoji"
        case .love: return "Love"
        case .gestures: return "Hands"
        case .party: return "Party"
        case .sad: return "Sad"
        case .angry: return "Angry"
        case .neutral: return "Neutral"
        }
    }

    var icon: String {
        switch self {
        case .recent: return "🕘"
        case .smileys: return "🙂"
        case .love: return "♡"
        case .gestures: return "👍"
        case .party: return "🎉"
        case .sad: return "🥹"
        case .angry: return "😠"
        case .neutral: return "😐"
        }
    }
}

private struct ChatEmojiEntry: Hashable {
    let value: String
    let searchText: String
    let category: ChatEmojiCategory
}

private struct ChatEmojiSection {
    let title: String
    let items: [ChatEmojiEntry]
}

private final class ChatGifPanelEmojiCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatGifPanelEmojiCell"

    private let emojiLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(emojiLabel)
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous

        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        emojiLabel.font = .systemFont(ofSize: 31)
        emojiLabel.textAlignment = .center

        NSLayoutConstraint.activate([
            emojiLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            emojiLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            emojiLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            emojiLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(emoji: String, highlighted: Bool) {
        emojiLabel.text = emoji
        contentView.backgroundColor =
            highlighted
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.clear
    }
}

private final class ChatGifPanelEmojiHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "ChatGifPanelEmojiHeaderView"

    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(titleLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, color: UIColor) {
        titleLabel.text = title.uppercased()
        titleLabel.textColor = color
    }
}

private final class FloatingTabBar: UITabBar {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

final class ChatGifPanelView: UIView {
    weak var delegate: ChatGifPanelViewDelegate?
    var onPreferredHeightChange: (() -> Void)?

    private(set) var preferredHeightExpansion: CGFloat = 0
    private(set) var preferredHeightScaleBoost: CGFloat = 0

    private let bottomFloatingInset: CGFloat = 52
    private let bottomFloatingControlHeight: CGFloat = 38
    private let bottomFloatingEdgeInset: CGFloat = 0
    private let topControlsSpacing: CGFloat = 4
    private let stripHeight: CGFloat = 34
    private let searchHeight: CGFloat = 38
    // Total header zone: strip + gap + search + bottom gap
    private var headerZoneHeight: CGFloat {
        8 + stripHeight + topControlsSpacing + searchHeight + 2
    }

    private var panelVisible = false
    private var activeTab: ChatGifPanelTab = .gifs
    private var searchTextByTab: [ChatGifPanelTab: String] = [:]
    private var selectedGifFilterID: String?
    private var selectedStickerPackID: String? = ChatGifPanelView.loadSelectedStickerPackID()
    private var stickerShowingRecent = false
    private var selectedEmojiCategory: ChatEmojiCategory?

    // Native sticker pack panel (replaces Giphy stickers when packs are available)
    private lazy var stickerPackPanel: ChatStickerPackPanel = {
        let panel = ChatStickerPackPanel()
        panel.delegate = self
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        return panel
    }()
    private var emojiSections: [ChatEmojiSection] = []
    private var recentEmojiValues = ChatGifPanelView.loadRecentEmojiValues()

    weak var hostViewController: UIViewController? {
        didSet {
            guard hostViewController !== oldValue else { return }
            removeEmbeddedPicker()
            if panelVisible, activeTab == .gifs {
                installEmbeddedPickerIfNeeded()
            }
        }
    }

    private let glassBackground = UIVisualEffectView(effect: nil)
    // Scrollable header (strip + search) — scrolls with content for all tabs
    private let headerView = UIView()
    private let topStripScrollView = UIScrollView()
    private let topStripStack = UIStackView()
    private let searchChromeView = UIVisualEffectView(effect: nil)
    private let searchIconView = UIImageView()
    private let searchField = UITextField()
    private let clearSearchButton = UIButton(type: .system)
    // Full-bleed content container
    private let contentContainerView = UIView()
    private let mediaContainerView = UIView()
    private let stateLabel = UILabel()
    private let loadingView = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)
    // Bottom gradient mask (fades into tab bar)
    private let bottomMaskView = UIView()
    private let bottomMaskGradient = CAGradientLayer()
    // Bottom floating controls
    private let bottomTabBarContainer = UIView()
    private let bottomTabBar = FloatingTabBar()
    private let closeChromeView = UIVisualEffectView(effect: nil)
    private let closeButton = UIButton(type: .system)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private let emojiCollectionView: UICollectionView

    #if canImport(GiphyUISDK)
        private var pickerViewController: GiphyGridController?
    #endif

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 6, left: 12, bottom: 16, right: 12)
        layout.headerReferenceSize = CGSize(width: 120, height: 34)
        emojiCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        removeEmbeddedPicker()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let panelCornerRadius: CGFloat = 28
        let topCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.cornerRadius = panelCornerRadius
        layer.cornerCurve = .continuous
        layer.maskedCorners = topCorners
        glassBackground.layer.cornerRadius = panelCornerRadius
        glassBackground.layer.cornerCurve = .continuous
        glassBackground.layer.maskedCorners = topCorners
        closeChromeView.layer.cornerRadius = 19
        closeChromeView.layer.cornerCurve = .continuous
        applyFrameLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshChrome()
        rebuildTopStripButtons()
        rebuildSearchChrome()
        emojiCollectionView.reloadData()

        #if canImport(GiphyUISDK)
            pickerViewController?.theme = currentGiphyTheme()
        #endif
    }

    func prepareIfNeeded() {
        guard panelVisible else { return }
        if activeTab == .emoji {
            rebuildEmojiSections()
        } else if activeTab == .gifs {
            installEmbeddedPickerIfNeeded()
        } else {
            applyStickerPanelState()
        }
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible

        if visible {
            applyActiveTabState(animated: false)
            if activeTab == .gifs {
                installEmbeddedPickerIfNeeded()
            }
            return
        }

        searchField.resignFirstResponder()
        setSearchExpanded(false)
        removeEmbeddedPicker()
        loadingSpinner.stopAnimating()
        loadingView.isHidden = true
        stateLabel.isHidden = true
    }

    private func setupUI() {
        clipsToBounds = true
        backgroundColor = .clear
        ensureStickerPackSelection()

        // Glass background fills everything
        glassBackground.frame = bounds
        glassBackground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glassBackground)

        // Full-bleed content container (top to bottom — header floats above)
        contentContainerView.backgroundColor = .clear
        contentContainerView.frame = bounds
        contentContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentContainerView)

        // Media container for GIF/sticker picker — fills content
        mediaContainerView.backgroundColor = .clear
        contentContainerView.addSubview(mediaContainerView)

        // Emoji collection view — fills content, contentInset pushes below header
        emojiCollectionView.translatesAutoresizingMaskIntoConstraints = true
        emojiCollectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        emojiCollectionView.backgroundColor = .clear
        emojiCollectionView.alwaysBounceVertical = true
        emojiCollectionView.keyboardDismissMode = .onDrag
        emojiCollectionView.dataSource = self
        emojiCollectionView.delegate = self
        emojiCollectionView.register(
            ChatGifPanelEmojiCell.self,
            forCellWithReuseIdentifier: ChatGifPanelEmojiCell.reuseIdentifier
        )
        emojiCollectionView.register(
            ChatGifPanelEmojiHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: ChatGifPanelEmojiHeaderView.reuseIdentifier
        )
        contentContainerView.addSubview(emojiCollectionView)
        contentContainerView.addSubview(stickerPackPanel)

        // State / loading overlays
        stateLabel.translatesAutoresizingMaskIntoConstraints = true
        stateLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stateLabel.font = .systemFont(ofSize: 14)
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateLabel.isHidden = true
        contentContainerView.addSubview(stateLabel)

        loadingView.backgroundColor = .clear
        loadingView.isUserInteractionEnabled = false
        loadingView.isHidden = true
        contentContainerView.addSubview(loadingView)

        loadingSpinner.hidesWhenStopped = true
        loadingView.addSubview(loadingSpinner)

        // Bottom gradient mask: transparent → bg colour (feathers into tab bar)
        bottomMaskView.isUserInteractionEnabled = false
        bottomMaskGradient.startPoint = CGPoint(x: 0.5, y: 0)
        bottomMaskGradient.endPoint = CGPoint(x: 0.5, y: 1)
        bottomMaskView.layer.addSublayer(bottomMaskGradient)
        addSubview(bottomMaskView)

        // ── Scrollable header: strip + search (scrolls with content) ──
        headerView.backgroundColor = .clear
        headerView.isUserInteractionEnabled = true
        addSubview(headerView)

        topStripScrollView.showsHorizontalScrollIndicator = false
        topStripScrollView.alwaysBounceHorizontal = true
        topStripScrollView.backgroundColor = .clear
        headerView.addSubview(topStripScrollView)

        topStripStack.axis = .horizontal
        topStripStack.alignment = .center
        topStripStack.spacing = 6
        topStripStack.translatesAutoresizingMaskIntoConstraints = false
        topStripScrollView.addSubview(topStripStack)

        let topStripMinHeight = topStripStack.heightAnchor.constraint(
            greaterThanOrEqualTo: topStripScrollView.frameLayoutGuide.heightAnchor)

        NSLayoutConstraint.activate([
            topStripStack.leadingAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.leadingAnchor),
            topStripStack.trailingAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.trailingAnchor),
            topStripStack.topAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.topAnchor),
            topStripStack.bottomAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.bottomAnchor),
            topStripMinHeight,
        ])

        searchChromeView.clipsToBounds = true
        searchChromeView.layer.cornerRadius = 18
        searchChromeView.layer.cornerCurve = .continuous
        headerView.addSubview(searchChromeView)

        searchIconView.contentMode = .scaleAspectFit
        searchChromeView.contentView.addSubview(searchIconView)

        searchField.delegate = self
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .never
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.addTarget(self, action: #selector(searchTextDidChange), for: .editingChanged)
        searchChromeView.contentView.addSubview(searchField)

        clearSearchButton.translatesAutoresizingMaskIntoConstraints = false
        clearSearchButton.addTarget(self, action: #selector(clearSearchTapped), for: .touchUpInside)
        searchChromeView.contentView.addSubview(clearSearchButton)

        // Internal search chrome constraints
        let searchIcon = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        let searchIconLeading = searchIconView.leadingAnchor.constraint(
            equalTo: searchChromeView.contentView.leadingAnchor, constant: 12)
        let searchIconWidth = searchIconView.widthAnchor.constraint(equalToConstant: 20)
        let clearButtonTrailing = clearSearchButton.trailingAnchor.constraint(
            equalTo: searchChromeView.contentView.trailingAnchor, constant: -10)
        let clearButtonWidth = clearSearchButton.widthAnchor.constraint(equalToConstant: 24)
        let searchFieldLeading = searchField.leadingAnchor.constraint(
            equalTo: searchIconView.trailingAnchor, constant: 8)
        let searchFieldTrailing = searchField.trailingAnchor.constraint(
            equalTo: clearSearchButton.leadingAnchor, constant: -6)
        [searchIconLeading, searchIconWidth, clearButtonTrailing, clearButtonWidth, searchFieldLeading,
         searchFieldTrailing].forEach { $0.priority = .defaultHigh }

        NSLayoutConstraint.activate([
            searchIconLeading,
            searchIconView.centerYAnchor.constraint(
                equalTo: searchChromeView.contentView.centerYAnchor),
            searchIconWidth,
            searchIconView.heightAnchor.constraint(equalToConstant: 20),

            clearButtonTrailing,
            clearSearchButton.centerYAnchor.constraint(
                equalTo: searchChromeView.contentView.centerYAnchor),
            clearButtonWidth,
            clearSearchButton.heightAnchor.constraint(equalToConstant: 24),

            searchFieldLeading,
            searchFieldTrailing,
            searchField.centerYAnchor.constraint(
                equalTo: searchChromeView.contentView.centerYAnchor),
        ])
        _ = searchIcon  // suppress unused warning

        // ── Bottom floating tab bar + close ──
        bottomTabBarContainer.backgroundColor = .clear
        bottomTabBarContainer.clipsToBounds = false
        bottomTabBarContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomTabBarContainer)

        bottomTabBar.translatesAutoresizingMaskIntoConstraints = false
        bottomTabBar.delegate = self
        bottomTabBar.itemPositioning = .automatic
        bottomTabBarContainer.addSubview(bottomTabBar)

        closeChromeView.clipsToBounds = true
        closeChromeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeChromeView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeChromeView.contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            bottomTabBarContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomTabBarContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -bottomFloatingEdgeInset),
            bottomTabBarContainer.widthAnchor.constraint(equalToConstant: 220),
            bottomTabBarContainer.heightAnchor.constraint(equalToConstant: bottomFloatingControlHeight),

            bottomTabBar.leadingAnchor.constraint(
                equalTo: bottomTabBarContainer.leadingAnchor, constant: -16),
            bottomTabBar.trailingAnchor.constraint(
                equalTo: bottomTabBarContainer.trailingAnchor, constant: 16),
            bottomTabBar.centerYAnchor.constraint(equalTo: bottomTabBarContainer.centerYAnchor),

            closeChromeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeChromeView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -bottomFloatingEdgeInset),
            closeChromeView.widthAnchor.constraint(equalToConstant: bottomFloatingControlHeight),
            closeChromeView.heightAnchor.constraint(equalToConstant: bottomFloatingControlHeight),

            closeButton.leadingAnchor.constraint(
                equalTo: closeChromeView.contentView.leadingAnchor),
            closeButton.trailingAnchor.constraint(
                equalTo: closeChromeView.contentView.trailingAnchor),
            closeButton.topAnchor.constraint(equalTo: closeChromeView.contentView.topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: closeChromeView.contentView.bottomAnchor),
        ])

        var items: [UITabBarItem] = []
        for tab in ChatGifPanelTab.allCases {
            items.append(UITabBarItem(title: tab.title, image: nil, tag: tab.rawValue))
        }
        bottomTabBar.items = items
        bottomTabBar.selectedItem = items.first

        let closeConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        closeButton.setImage(
            UIImage(systemName: "xmark.circle.fill", withConfiguration: closeConfig),
            for: .normal
        )
        closeButton.tintColor = secondaryTextColor

        selectionFeedback.prepare()
        refreshChrome()
        rebuildSearchChrome()
        rebuildTopStripButtons()
        rebuildEmojiSections()
        updateContentInsets()
        applyActiveTabState(animated: false)
    }

    private func updateContentInsets() {
        let insets = UIEdgeInsets(top: headerZoneHeight, left: 0, bottom: bottomFloatingInset, right: 0)
        emojiCollectionView.contentInset = insets
        emojiCollectionView.scrollIndicatorInsets = insets
        stickerPackPanel.contentScrollView.contentInset = insets
        stickerPackPanel.contentScrollView.scrollIndicatorInsets = insets
        #if canImport(GiphyUISDK)
        if let pickerView = pickerViewController?.view, let sv = findScrollView(in: pickerView) {
            sv.contentInset = insets
            sv.scrollIndicatorInsets = insets
        }
        #endif
    }

    /// Frame-based layout — called from layoutSubviews.
    /// Mirrors ChatAttachmentMenuController.layoutAll().
    private func applyFrameLayout() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let hInset: CGFloat = 10
        let stripTop: CGFloat = 8

        // Header is fixed at the top
        headerView.frame = CGRect(x: 0, y: 0, width: w, height: headerZoneHeight)
        let stripFrame = CGRect(x: hInset, y: stripTop, width: w - hInset * 2, height: stripHeight)
        topStripScrollView.frame = stripFrame
        let searchY = stripFrame.maxY + topControlsSpacing
        searchChromeView.frame = CGRect(
            x: hInset, y: searchY, width: w - hInset * 2, height: searchHeight)

        // Content: full-bleed
        contentContainerView.frame = bounds

        mediaContainerView.frame = bounds
        emojiCollectionView.frame = bounds

        // Sticker pack panel
        stickerPackPanel.translatesAutoresizingMaskIntoConstraints = true
        stickerPackPanel.frame = CGRect(
            x: 0, y: 0, width: w, height: h)

        stateLabel.frame = bounds
        loadingView.frame = bounds
        loadingSpinner.center = CGPoint(x: w * 0.5, y: h * 0.5 - 18)

        // Bottom gradient mask
        let bottomMaskH: CGFloat = 80
        bottomMaskView.frame = CGRect(x: 0, y: h - bottomMaskH, width: w, height: bottomMaskH)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomMaskGradient.frame = bottomMaskView.bounds
        CATransaction.commit()

        // Z-order: content → bottom mask → floating controls → fixed header
        bringSubviewToFront(bottomMaskView)
        bringSubviewToFront(bottomTabBarContainer)
        bringSubviewToFront(closeChromeView)
        bringSubviewToFront(headerView)
    }

    private func refreshChrome() {
        let blurStyle: UIBlurEffect.Style =
            isDarkMode ? .systemChromeMaterialDark : .systemChromeMaterialLight

        if #available(iOS 26.0, *) {
            let backgroundGlass = UIGlassEffect()
            backgroundGlass.isInteractive = true
            glassBackground.effect = backgroundGlass
            searchChromeView.effect = nil
            let closeGlass = UIGlassEffect()
            closeGlass.isInteractive = true
            closeChromeView.effect = closeGlass
        } else {
            glassBackground.effect = UIBlurEffect(style: .systemMaterial)
            searchChromeView.effect = nil
            closeChromeView.effect = UIBlurEffect(style: blurStyle)
        }

        // Very soft transparent search bar
        searchChromeView.backgroundColor = UIColor.label.withAlphaComponent(0.06)

        // Update gradient mask colours to match current background
        let bgColor =
            isDarkMode
            ? UIColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1)
            : UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        bottomMaskGradient.colors = [bgColor.withAlphaComponent(0).cgColor, bgColor.cgColor]

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        tabAppearance.shadowColor = .clear
        tabAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)

        let itemAppearance = tabAppearance.stackedLayoutAppearance
        let inactive = secondaryTextColor
        itemAppearance.normal.iconColor = inactive
        itemAppearance.normal.titleTextAttributes = [
            .foregroundColor: inactive,
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        itemAppearance.normal.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -12)
        itemAppearance.selected.iconColor = primaryTextColor
        itemAppearance.selected.titleTextAttributes = [
            .foregroundColor: primaryTextColor,
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        itemAppearance.selected.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -12)
        tabAppearance.stackedLayoutAppearance = itemAppearance
        tabAppearance.inlineLayoutAppearance = itemAppearance
        tabAppearance.compactInlineLayoutAppearance = itemAppearance

        bottomTabBar.standardAppearance = tabAppearance
        if #available(iOS 15.0, *) {
            bottomTabBar.scrollEdgeAppearance = tabAppearance
        }
    }

    private func rebuildSearchChrome() {
        let searchConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        searchIconView.image = UIImage(
            systemName: "magnifyingglass", withConfiguration: searchConfig)
        searchIconView.tintColor = secondaryTextColor.withAlphaComponent(0.5)

        let clearConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        clearSearchButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: clearConfig),
            for: .normal
        )
        clearSearchButton.tintColor = secondaryTextColor
        clearSearchButton.isHidden = currentSearchText().isEmpty
        searchField.textColor = primaryTextColor
        searchField.tintColor = primaryTextColor
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.attributedPlaceholder = NSAttributedString(
            string: activeTab.searchPlaceholder,
            attributes: [.foregroundColor: secondaryTextColor.withAlphaComponent(0.5)]
        )
    }

    private func rebuildTopStripButtons() {
        topStripStack.arrangedSubviews.forEach { view in
            topStripStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch activeTab {
        case .gifs:
            for (index, filter) in gifQuickFilters.enumerated() {
                let button = makeStripButton(
                    title: filter.title,
                    selected: selectedGifFilterID == filter.id,
                    showsAddBadge: false
                )
                button.tag = index
                button.accessibilityLabel = filter.query
                button.addTarget(
                    self, action: #selector(gifQuickFilterTapped(_:)), for: .touchUpInside)
                topStripStack.addArrangedSubview(button)
            }
        case .stickers:
            ensureStickerPackSelection()
            let recentButton = makeStripButton(
                title: "🕘",
                selected: stickerShowingRecent,
                showsAddBadge: false
            )
            recentButton.accessibilityLabel = "Recently Used"
            recentButton.addTarget(
                self, action: #selector(stickerRecentTapped), for: .touchUpInside)
            topStripStack.addArrangedSubview(recentButton)

            let installedStickerPacks = ChatStickerPackStore.shared.installedPacks
            for (index, pack) in installedStickerPacks.enumerated() {
                let button = makeStripButton(
                    title: pack.icon,
                    selected: !stickerShowingRecent && selectedStickerPackID == pack.id,
                    showsAddBadge: false
                )
                button.tag = index
                button.accessibilityLabel = pack.name
                button.addTarget(
                    self, action: #selector(stickerStarterPackTapped(_:)), for: .touchUpInside)
                topStripStack.addArrangedSubview(button)
            }
        case .emoji:
            let categories = [ChatEmojiCategory.recent] + ChatEmojiCategory.browseCases
            for (index, category) in categories.enumerated() {
                let selected = selectedEmojiCategory == category
                let button = makeStripButton(
                    title: category.icon,
                    selected: selected,
                    showsAddBadge: false
                )
                button.tag = index
                button.accessibilityLabel = category.title
                button.addTarget(
                    self, action: #selector(emojiCategoryTapped(_:)), for: .touchUpInside)
                topStripStack.addArrangedSubview(button)
            }
        }
    }

    private func makeStripButton(title: String, selected: Bool, showsAddBadge: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let isEmoji = title.count <= 2
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: isEmoji ? 6 : 10, bottom: 0, trailing: isEmoji ? 6 : 10)
        button.configuration = config
        button.setTitle(title, for: .normal)
        button.setTitleColor(primaryTextColor, for: .normal)
        button.titleLabel?.font = .systemFont(
            ofSize: isEmoji ? 24 : 15,
            weight: isEmoji ? .regular : .semibold
        )
        button.backgroundColor = selected ? selectedChipColor : .clear
        if activeTab == .emoji {
            button.alpha = 1.0
            button.transform = selected ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity
        }

        button.layer.cornerRadius = 17
        button.layer.cornerCurve = .continuous
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: 34)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        if showsAddBadge {
            let badge = UILabel()
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.text = "+"
            badge.textAlignment = .center
            badge.font = .systemFont(ofSize: 13, weight: .bold)
            badge.textColor = .white
            badge.backgroundColor = accentBadgeColor
            badge.layer.cornerRadius = 10
            badge.layer.cornerCurve = .continuous
            badge.clipsToBounds = true
            button.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 20),
                badge.heightAnchor.constraint(equalToConstant: 20),
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 3),
                badge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: 3),
            ])
        }

        return button
    }

    private func applyActiveTabState(animated: Bool) {
        if activeTab == .stickers {
            ensureStickerPackSelection()
        }
        rebuildSearchChrome()
        rebuildTopStripButtons()

        switch activeTab {
        case .emoji:
            mediaContainerView.isHidden = true
            stickerPackPanel.isHidden = true
            emojiCollectionView.isHidden = false
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
            rebuildEmojiSections()
        case .stickers:
            emojiCollectionView.isHidden = true
            mediaContainerView.isHidden = true
            stickerPackPanel.isHidden = false
            stateLabel.isHidden = true
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
            applyStickerPanelState()
        case .gifs:
            emojiCollectionView.isHidden = true
            stickerPackPanel.isHidden = true
            mediaContainerView.isHidden = false
            stateLabel.isHidden = true
            if panelVisible {
                installEmbeddedPickerIfNeeded()
            }
            updateEmbeddedPickerContent(showLoading: animated && pickerViewController == nil)
        }
        setNeedsLayout()
    }

    private func applyStickerPanelState() {
        stickerPackPanel.setSearchQuery(currentSearchText())
        if stickerShowingRecent {
            stickerPackPanel.setDisplayModeRecent()
        } else {
            stickerPackPanel.setDisplayedPack(id: selectedStickerPackID)
        }
    }

    // MARK: - Scroll-hosted header

    private func activeContentScrollView() -> UIScrollView? {
        switch activeTab {
        case .emoji:
            return emojiCollectionView
        case .stickers:
            return stickerPackPanel.contentScrollView
        case .gifs:
            #if canImport(GiphyUISDK)
                if let pickerView = pickerViewController?.view {
                    return findScrollView(in: pickerView)
                }
            #endif
            return nil
        }
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let sv = sub as? UIScrollView { return sv }
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    @objc private func gifQuickFilterTapped(_ sender: UIButton) {
        guard sender.tag >= 0, sender.tag < gifQuickFilters.count else { return }
        let filter = gifQuickFilters[sender.tag]
        selectionFeedback.selectionChanged()
        selectedGifFilterID = filter.id
        updateCurrentSearchText(filter.query, synchronizeField: true, clearPresetSelection: false)
        searchField.resignFirstResponder()
        rebuildTopStripButtons()
    }

    @objc private func stickerStarterPackTapped(_ sender: UIButton) {
        let installedStickerPacks = ChatStickerPackStore.shared.installedPacks
        guard sender.tag >= 0, sender.tag < installedStickerPacks.count else { return }
        let pack = installedStickerPacks[sender.tag]
        selectionFeedback.selectionChanged()
        stickerShowingRecent = false
        selectedStickerPackID = pack.id
        persistSelectedStickerPackID()
        searchField.resignFirstResponder()
        rebuildTopStripButtons()
        applyStickerPanelState()
    }

    @objc private func stickerRecentTapped() {
        selectionFeedback.selectionChanged()
        stickerShowingRecent = true
        searchField.resignFirstResponder()
        rebuildTopStripButtons()
        applyStickerPanelState()
    }

    @objc private func emojiCategoryTapped(_ sender: UIButton) {
        let categories = [ChatEmojiCategory.recent] + ChatEmojiCategory.browseCases
        guard sender.tag >= 0, sender.tag < categories.count else { return }
        let category = categories[sender.tag]
        selectionFeedback.selectionChanged()
        selectedEmojiCategory = (selectedEmojiCategory == category) ? nil : category
        updateCurrentSearchText("", synchronizeField: true, clearPresetSelection: false)
        searchField.resignFirstResponder()
        rebuildTopStripButtons()
        rebuildEmojiSections()
    }

    @objc private func searchTextDidChange() {
        updateCurrentSearchText(
            searchField.text ?? "", synchronizeField: false, clearPresetSelection: true)
    }

    @objc private func clearSearchTapped() {
        updateCurrentSearchText("", synchronizeField: true, clearPresetSelection: true)
        searchField.becomeFirstResponder()
    }

    @objc private func closeTapped() {
        delegate?.chatGifPanelDidRequestClose(self)
    }

    private func updateCurrentSearchText(
        _ rawValue: String,
        synchronizeField: Bool,
        clearPresetSelection: Bool
    ) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTextByTab[activeTab] = value

        if synchronizeField, searchField.text != value {
            searchField.text = value
        }

        if clearPresetSelection {
            switch activeTab {
            case .gifs:
                selectedGifFilterID = nil
            case .stickers:
                break
            case .emoji:
                if !value.isEmpty {
                    selectedEmojiCategory = nil
                }
            }
            rebuildTopStripButtons()
        }

        clearSearchButton.isHidden = value.isEmpty

        switch activeTab {
        case .emoji:
            rebuildEmojiSections()
        case .gifs:
            updateEmbeddedPickerContent(showLoading: false)
        case .stickers:
            stickerPackPanel.setSearchQuery(value)
        }
    }

    private func currentSearchText() -> String {
        searchTextByTab[activeTab] ?? ""
    }

    private func ensureStickerPackSelection() {
        let installedStickerPacks = ChatStickerPackStore.shared.installedPacks
        guard !installedStickerPacks.isEmpty else {
            selectedStickerPackID = nil
            return
        }

        if let selectedStickerPackID,
            installedStickerPacks.contains(where: { $0.id == selectedStickerPackID })
        {
            return
        }

        selectedStickerPackID = installedStickerPacks.first?.id
        persistSelectedStickerPackID()
    }

    private func persistSelectedStickerPackID() {
        guard let selectedStickerPackID else {
            UserDefaults.standard.removeObject(forKey: Self.selectedStickerPackDefaultsKey)
            return
        }
        UserDefaults.standard.set(
            selectedStickerPackID, forKey: Self.selectedStickerPackDefaultsKey)
    }

    private func searchFocusedHeightScaleBoost(for tab: ChatGifPanelTab) -> CGFloat {
        switch tab {
        case .gifs:
            return 1.15
        case .stickers:
            return 0.10
        case .emoji:
            return 0.18
        }
    }

    private func setSearchExpanded(_ expanded: Bool) {
        let nextExpansion: CGFloat = 0
        let nextScaleBoost = expanded ? searchFocusedHeightScaleBoost(for: activeTab) : 0
        guard
            abs(preferredHeightExpansion - nextExpansion) > 0.5
                || abs(preferredHeightScaleBoost - nextScaleBoost) > 0.001
        else {
            return
        }
        preferredHeightExpansion = nextExpansion
        preferredHeightScaleBoost = nextScaleBoost
        onPreferredHeightChange?()
    }

    private func rebuildEmojiSections() {
        let query = currentSearchText().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !query.isEmpty {
            let matches = emojiCatalog.filter {
                $0.value.contains(query) || $0.searchText.localizedCaseInsensitiveContains(query)
            }
            emojiSections =
                matches.isEmpty
                ? []
                : [ChatEmojiSection(title: "Search Results", items: matches)]
        } else if let selectedEmojiCategory {
            if selectedEmojiCategory == .recent {
                let recents = resolvedRecentEmojiEntries()
                emojiSections =
                    recents.isEmpty
                    ? []
                    : [ChatEmojiSection(title: ChatEmojiCategory.recent.title, items: recents)]
            } else {
                emojiSections = [
                    ChatEmojiSection(
                        title: selectedEmojiCategory.title,
                        items: emojiCatalog.filter { $0.category == selectedEmojiCategory }
                    )
                ]
            }
        } else {
            var sections: [ChatEmojiSection] = []
            let recents = resolvedRecentEmojiEntries()
            if !recents.isEmpty {
                sections.append(
                    ChatEmojiSection(title: ChatEmojiCategory.recent.title, items: recents))
            }
            for category in ChatEmojiCategory.browseCases {
                let items = emojiCatalog.filter { $0.category == category }
                if !items.isEmpty {
                    sections.append(ChatEmojiSection(title: category.title, items: items))
                }
            }
            emojiSections = sections
        }

        emojiCollectionView.reloadData()
        let shouldShowEmpty = activeTab == .emoji && emojiSections.allSatisfy(\.items.isEmpty)
        if shouldShowEmpty {
            stateLabel.text =
                query.isEmpty
                ? "No emoji available yet."
                : "No emoji found for \"\(query)\"."
            stateLabel.textColor = secondaryTextColor
            stateLabel.isHidden = false
        } else if activeTab == .emoji {
            stateLabel.isHidden = true
        }
    }

    private func resolvedRecentEmojiEntries() -> [ChatEmojiEntry] {
        recentEmojiValues.compactMap { value in
            emojiCatalog.first(where: { $0.value == value })
        }
    }

    private func registerRecentEmoji(_ emoji: String) {
        recentEmojiValues.removeAll(where: { $0 == emoji })
        recentEmojiValues.insert(emoji, at: 0)
        if recentEmojiValues.count > 32 {
            recentEmojiValues = Array(recentEmojiValues.prefix(32))
        }
        UserDefaults.standard.set(recentEmojiValues, forKey: Self.recentEmojiDefaultsKey)
    }

    private static func loadRecentEmojiValues() -> [String] {
        let stored = UserDefaults.standard.array(forKey: recentEmojiDefaultsKey) as? [String]
        return stored ?? []
    }

    private static func loadSelectedStickerPackID() -> String? {
        let stored = UserDefaults.standard.string(forKey: selectedStickerPackDefaultsKey)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    @discardableResult
    private func configureGiphySDKIfNeeded() -> Bool {
        #if canImport(GiphyUISDK)
            let key = ChatGifPanelConfig.shared.apiKey.trimmingCharacters(
                in: .whitespacesAndNewlines)
            print("[NativeGif][iOS] configureGiphySDKIfNeeded keyLength=\(key.count)")
            guard !key.isEmpty else { return false }
            Giphy.configure(apiKey: key)
            print("[NativeGif][iOS] Giphy.configure succeeded")
            return true
        #else
            print("[NativeGif][iOS] GiphyUISDK unavailable")
            return false
        #endif
    }

    #if canImport(GiphyUISDK)
        private func currentGiphyTheme() -> GPHTheme {
            GPHTheme(type: isDarkMode ? .darkBlur : .lightBlur)
        }

        private func resolvedGiphyContent() -> GPHContent {
            let query = currentSearchText().trimmingCharacters(in: .whitespacesAndNewlines)

            if !query.isEmpty {
                return .search(
                    withQuery: query,
                    mediaType: .gif,
                    language: .english,
                    includeDynamicResults: true
                )
            }

            switch activeTab {
            case .emoji:
                return .emoji
            case .gifs:
                return .trendingGifs
            case .stickers:
                return .trendingGifs
            }
        }
    #endif

    private func installEmbeddedPickerIfNeeded() {
        #if canImport(GiphyUISDK)
            guard activeTab == .gifs else { return }
            guard pickerViewController == nil else { return }
            guard let host = hostViewController else {
                print("[NativeGif][iOS] installEmbeddedPickerIfNeeded missing hostViewController")
                showStateLabel("GIF host is unavailable right now.")
                return
            }

            guard configureGiphySDKIfNeeded() else {
                print("[NativeGif][iOS] installEmbeddedPickerIfNeeded missing API key")
                showStateLabel("Configure a Giphy API key to enable GIF search.")
                return
            }

            print("[NativeGif][iOS] creating GiphyGridController")

            let picker = GiphyGridController()
            picker.delegate = self
            picker.theme = currentGiphyTheme()
            picker.direction = .vertical
            picker.fixedSizeCells = false
            picker.additionalSafeAreaInsets = .zero
            picker.content = resolvedGiphyContent()

            host.addChild(picker)
            mediaContainerView.addSubview(picker.view)
            picker.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                picker.view.leadingAnchor.constraint(equalTo: mediaContainerView.leadingAnchor),
                picker.view.trailingAnchor.constraint(equalTo: mediaContainerView.trailingAnchor),
                picker.view.topAnchor.constraint(equalTo: mediaContainerView.topAnchor),
                picker.view.bottomAnchor.constraint(equalTo: mediaContainerView.bottomAnchor),
            ])
            picker.view.backgroundColor = .clear
            picker.view.isOpaque = false
            picker.didMove(toParent: host)

            pickerViewController = picker
            stateLabel.isHidden = true
            updateEmbeddedPickerContent(showLoading: panelVisible)
            updateContentInsets()
        #else
            showStateLabel("Install the Giphy native SDK to enable GIF search.")
        #endif
    }

    private func updateEmbeddedPickerContent(showLoading: Bool) {
        #if canImport(GiphyUISDK)
            guard activeTab == .gifs else { return }
            guard let picker = pickerViewController else {
                if panelVisible {
                    installEmbeddedPickerIfNeeded()
                }
                return
            }

            picker.content = resolvedGiphyContent()
            if showLoading {
                loadingSpinner.startAnimating()
                loadingView.isHidden = false
            } else {
                loadingSpinner.stopAnimating()
                loadingView.isHidden = true
            }
            stateLabel.isHidden = true
            picker.update()
        #endif
    }

    private func removeEmbeddedPicker() {
        #if canImport(GiphyUISDK)
            guard let picker = pickerViewController else { return }
            picker.willMove(toParent: nil)
            picker.view.removeFromSuperview()
            picker.removeFromParent()
            pickerViewController = nil
        #endif
    }

    private func showStateLabel(_ text: String) {
        loadingSpinner.stopAnimating()
        loadingView.isHidden = true
        stateLabel.text = text
        stateLabel.textColor = secondaryTextColor
        stateLabel.isHidden = false
    }

    private func normalizedNonEmptyString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    #if canImport(GiphyUISDK)
        private func resolvedPrimaryImage(from images: GPHImages?) -> GPHImage? {
            guard let images else { return nil }
            if let original = images.original { return original }
            if let fixedWidth = images.fixedWidth { return fixedWidth }
            if let fixedHeight = images.fixedHeight { return fixedHeight }
            if let downsized = images.downsized { return downsized }
            if let preview = images.preview { return preview }
            if let fixedWidthSmall = images.fixedWidthSmall { return fixedWidthSmall }
            return nil
        }

        private func resolvedPreviewURL(
            from images: GPHImages?,
            primaryImage: GPHImage?,
            fallbackURL: String
        ) -> String {
            if let preview = normalizedNonEmptyString(images?.preview?.gifUrl) {
                return preview
            }
            if let fixedWidthSmallStill = normalizedNonEmptyString(
                images?.fixedWidthSmallStill?.stillGifUrl)
            {
                return fixedWidthSmallStill
            }
            if let fixedWidthStill = normalizedNonEmptyString(images?.fixedWidthStill?.stillGifUrl)
            {
                return fixedWidthStill
            }
            if let originalStill = normalizedNonEmptyString(images?.originalStill?.stillGifUrl) {
                return originalStill
            }
            if let primaryStill = normalizedNonEmptyString(primaryImage?.stillGifUrl) {
                return primaryStill
            }
            return fallbackURL
        }
    #endif

    private var isDarkMode: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    private var primaryTextColor: UIColor {
        isDarkMode
            ? UIColor(white: 0.95, alpha: 0.96)
            : UIColor(white: 0.12, alpha: 0.96)
    }

    private var secondaryTextColor: UIColor {
        isDarkMode
            ? UIColor(white: 0.84, alpha: 0.62)
            : UIColor(white: 0.12, alpha: 0.42)
    }

    private var selectedChipColor: UIColor {
        isDarkMode
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.1)
    }

    private var accentBadgeColor: UIColor {
        UIColor(red: 0.90, green: 0.75, blue: 0.48, alpha: 0.92)
    }

    private static let recentEmojiDefaultsKey = "chat.gif.panel.recent.emoji"
    private static let selectedStickerPackDefaultsKey = "chat.gif.panel.selected.sticker.pack"

    private let gifQuickFilters: [ChatGifQuickFilter] = [
        .init(id: "love", title: "♡", query: "love"),
        .init(id: "like", title: "👍", query: "like"),
        .init(id: "dislike", title: "👎", query: "dislike"),
        .init(id: "party", title: "🎉", query: "party"),
        .init(id: "happy", title: "🙂", query: "happy"),
        .init(id: "sad", title: "🥲", query: "sad"),
        .init(id: "angry", title: "😠", query: "angry"),
        .init(id: "neutral", title: "😐", query: "neutral"),
    ]

    private let emojiCatalog: [ChatEmojiEntry] = [
        .init(value: "😀", searchText: "grinning smile happy face", category: .smileys),
        .init(value: "😁", searchText: "beaming smile grin face", category: .smileys),
        .init(value: "😂", searchText: "laugh tears joy funny", category: .smileys),
        .init(value: "😊", searchText: "smile blush happy cute", category: .smileys),
        .init(value: "😉", searchText: "wink playful face", category: .smileys),
        .init(value: "😍", searchText: "heart eyes love crush", category: .smileys),
        .init(value: "🤩", searchText: "star struck wow excited", category: .smileys),
        .init(value: "😎", searchText: "cool sunglasses face", category: .smileys),
        .init(value: "🥳", searchText: "party celebrate happy", category: .smileys),
        .init(value: "🤗", searchText: "hug warm happy", category: .smileys),
        .init(value: "😋", searchText: "yum tasty playful", category: .smileys),
        .init(value: "😜", searchText: "tongue wink goofy", category: .smileys),

        .init(value: "❤️", searchText: "red heart love", category: .love),
        .init(value: "🩷", searchText: "pink heart love", category: .love),
        .init(value: "🧡", searchText: "orange heart love", category: .love),
        .init(value: "💛", searchText: "yellow heart love", category: .love),
        .init(value: "💚", searchText: "green heart love", category: .love),
        .init(value: "💙", searchText: "blue heart love", category: .love),
        .init(value: "💜", searchText: "purple heart love", category: .love),
        .init(value: "🤍", searchText: "white heart love", category: .love),
        .init(value: "🖤", searchText: "black heart love", category: .love),
        .init(value: "💘", searchText: "heart arrow crush", category: .love),
        .init(value: "💞", searchText: "revolving hearts", category: .love),
        .init(value: "💝", searchText: "gift heart valentine", category: .love),

        .init(value: "👍", searchText: "thumbs up like approve", category: .gestures),
        .init(value: "👎", searchText: "thumbs down dislike", category: .gestures),
        .init(value: "👌", searchText: "ok hand approve", category: .gestures),
        .init(value: "✌️", searchText: "peace victory hand", category: .gestures),
        .init(value: "🤞", searchText: "cross fingers luck", category: .gestures),
        .init(value: "🙌", searchText: "raised hands cheer", category: .gestures),
        .init(value: "👏", searchText: "clap applause", category: .gestures),
        .init(value: "👋", searchText: "wave hello hi", category: .gestures),
        .init(value: "🤝", searchText: "handshake deal", category: .gestures),
        .init(value: "🫶", searchText: "heart hands love", category: .gestures),
        .init(value: "🙏", searchText: "pray thanks please", category: .gestures),
        .init(value: "✍️", searchText: "writing pen note", category: .gestures),

        .init(value: "🎉", searchText: "party confetti celebration", category: .party),
        .init(value: "🎊", searchText: "confetti ball celebrate", category: .party),
        .init(value: "✨", searchText: "sparkles magic shiny", category: .party),
        .init(value: "💫", searchText: "dizzy stars sparkle", category: .party),
        .init(value: "⭐️", searchText: "star favorite", category: .party),
        .init(value: "🔥", searchText: "fire hot lit", category: .party),
        .init(value: "🎈", searchText: "balloon celebrate", category: .party),
        .init(value: "🎁", searchText: "gift present", category: .party),
        .init(value: "🥂", searchText: "cheers toast party", category: .party),
        .init(value: "🎵", searchText: "music note song", category: .party),
        .init(value: "🎶", searchText: "music notes song", category: .party),
        .init(value: "🌟", searchText: "glowing star", category: .party),

        .init(value: "🥹", searchText: "teary eyes soft sweet", category: .sad),
        .init(value: "😢", searchText: "cry sad tear", category: .sad),
        .init(value: "🥲", searchText: "smile tear sad", category: .sad),
        .init(value: "😭", searchText: "sob cry loudly", category: .sad),
        .init(value: "😞", searchText: "disappointed sad", category: .sad),
        .init(value: "😔", searchText: "pensive down", category: .sad),
        .init(value: "😩", searchText: "weary tired upset", category: .sad),
        .init(value: "😫", searchText: "tired exhausted sad", category: .sad),
        .init(value: "😕", searchText: "confused sad unsure", category: .sad),
        .init(value: "🫠", searchText: "melting awkward", category: .sad),
        .init(value: "😥", searchText: "sad relief sweat", category: .sad),
        .init(value: "😪", searchText: "sleepy tired", category: .sad),

        .init(value: "😠", searchText: "angry mad face", category: .angry),
        .init(value: "😡", searchText: "rage angry", category: .angry),
        .init(value: "🤬", searchText: "swearing angry rage", category: .angry),
        .init(value: "😤", searchText: "steam nose frustrated", category: .angry),
        .init(value: "🙄", searchText: "eye roll annoyed", category: .angry),
        .init(value: "😒", searchText: "unamused annoyed", category: .angry),
        .init(value: "😑", searchText: "expressionless blank", category: .angry),
        .init(value: "🤨", searchText: "raised eyebrow skeptical", category: .angry),
        .init(value: "🥴", searchText: "woozy irritated", category: .angry),
        .init(value: "🤯", searchText: "mind blown anger shock", category: .angry),
        .init(value: "💢", searchText: "anger symbol mad comic", category: .angry),
        .init(value: "👺", searchText: "goblin angry demon", category: .angry),

        .init(value: "🙂", searchText: "slight smile calm", category: .neutral),
        .init(value: "😐", searchText: "neutral blank face", category: .neutral),
        .init(value: "😶", searchText: "no mouth quiet", category: .neutral),
        .init(value: "🫥", searchText: "dotted line face invisible", category: .neutral),
        .init(value: "🤔", searchText: "thinking curious", category: .neutral),
        .init(value: "😬", searchText: "grimace awkward", category: .neutral),
        .init(value: "🫤", searchText: "diagonal mouth unsure", category: .neutral),
        .init(value: "🙃", searchText: "upside down silly", category: .neutral),
        .init(value: "😮", searchText: "open mouth surprised", category: .neutral),
        .init(value: "😯", searchText: "hushed surprise", category: .neutral),
        .init(value: "😳", searchText: "flushed shy", category: .neutral),
        .init(value: "🤷", searchText: "shrug whatever", category: .neutral),
    ]
}

extension ChatGifPanelView: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        setSearchExpanded(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        setSearchExpanded(false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension ChatGifPanelView: UITabBarDelegate {
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let nextTab = ChatGifPanelTab(rawValue: item.tag), nextTab != activeTab else {
            return
        }
        activeTab = nextTab
        if nextTab == .stickers {
            ensureStickerPackSelection()
        }
        searchField.resignFirstResponder()
        if searchField.text != currentSearchText() {
            searchField.text = currentSearchText()
        }
        selectionFeedback.selectionChanged()
        applyActiveTabState(animated: true)
    }
}

extension ChatGifPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        emojiSections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
        -> Int
    {
        emojiSections[section].items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatGifPanelEmojiCell.reuseIdentifier,
                for: indexPath
            ) as? ChatGifPanelEmojiCell
        else {
            return UICollectionViewCell()
        }

        let item = emojiSections[indexPath.section].items[indexPath.item]
        cell.configure(emoji: item.value, highlighted: false)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = emojiSections[indexPath.section].items[indexPath.item]
        registerRecentEmoji(item.value)
        delegate?.chatGifPanel(self, didSelectEmoji: item.value)
        if activeTab == .emoji && currentSearchText().isEmpty {
            rebuildEmojiSections()
        }
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
                withReuseIdentifier: ChatGifPanelEmojiHeaderView.reuseIdentifier,
                for: indexPath
            ) as? ChatGifPanelEmojiHeaderView
        else {
            return UICollectionReusableView()
        }

        header.configure(title: emojiSections[indexPath.section].title, color: secondaryTextColor)
        return header
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let columns: CGFloat = bounds.width < 360 ? 7 : 8
        let horizontalPadding: CGFloat = 24
        let spacing: CGFloat = 8 * (columns - 1)
        let width = floor((collectionView.bounds.width - horizontalPadding - spacing) / columns)
        return CGSize(width: max(34, width), height: max(40, width))
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        let title = emojiSections[section].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? .zero : CGSize(width: collectionView.bounds.width, height: 36)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Header is hosted inside the scroll view itself, so no manual sync is needed.
    }
}

#if canImport(GiphyUISDK)
    extension ChatGifPanelView: GPHGridDelegate {
        func contentDidUpdate(resultCount: Int, error: (any Error)?) {
            print(
                "[NativeGif][iOS] contentDidUpdate resultCount=\(resultCount) error=\(error != nil)"
            )
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
            if activeTab != .emoji {
                stateLabel.isHidden = true
            }
        }

        func didSelectMedia(media: GPHMedia, cell: UICollectionViewCell) {
            emitSelection(media: media)
        }

        func didSelectMoreByYou(query: String) {}

        func didScroll(offset: CGFloat) {
            // Header is hosted inside the scroll view itself, so no manual sync is needed.
        }

        func errorDidOccur(_ error: any Error) {
            print("[NativeGif][iOS] grid error: \(error.localizedDescription)")
            showStateLabel("Unable to load \(activeTab.title.lowercased()) right now.")
        }

        func syntheticErrorDidOccur() {
            print("[NativeGif][iOS] grid synthetic error")
            showStateLabel("Unable to load \(activeTab.title.lowercased()) right now.")
        }

        private func emitSelection(media: GPHMedia) {
            let images = media.images
            let primaryImage = resolvedPrimaryImage(from: images)
            let normalizedMediaID = media.id.isEmpty ? UUID().uuidString.lowercased() : media.id
            let primaryURL = normalizedNonEmptyString(primaryImage?.gifUrl)

            guard
                let url = primaryURL
            else {
                guard let fallbackUrl = normalizedNonEmptyString(media.url) else { return }
                // Kick off prefetch immediately so the image is cached before cell appears
                chatMediaPrefetch(urlString: fallbackUrl, animated: true)
                delegate?.chatGifPanel(
                    self,
                    didSelectGif: ChatGifSelection(
                        id: normalizedMediaID,
                        url: fallbackUrl,
                        previewUrl: fallbackUrl,
                        width: 0,
                        height: 0
                    )
                )
                return
            }

            let previewUrl = resolvedPreviewURL(
                from: images,
                primaryImage: primaryImage,
                fallbackURL: url
            )

            // Kick off prefetch immediately so the image is cached before cell appears
            chatMediaPrefetch(urlString: url, animated: true)

            delegate?.chatGifPanel(
                self,
                didSelectGif: ChatGifSelection(
                    id: normalizedMediaID,
                    url: url,
                    previewUrl: previewUrl,
                    width: primaryImage?.width ?? 0,
                    height: primaryImage?.height ?? 0
                )
            )
        }
    }
#endif

// MARK: - ChatStickerPackPanelDelegate

extension ChatGifPanelView: ChatStickerPackPanelDelegate {
    func stickerPackPanel(
        _ panel: ChatStickerPackPanel, didSelectSticker sticker: ChatStickerSelection
    ) {
        delegate?.chatGifPanel(self, didSelectSticker: sticker)
    }
}
