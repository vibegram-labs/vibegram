import UIKit

#if canImport(GiphyUISDK)
    import GiphyUISDK
#endif

private let chatGifDefaultApiKey = "dc6zaTOxFJmzC"

final class ChatGifPanelConfig {
    static let shared = ChatGifPanelConfig()

    private init() {}

    var apiKey: String = chatGifDefaultApiKey
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
    func chatGifPanelDidRequestClose(_ panel: ChatGifPanelView)
}

final class ChatGifPanelView: UIView {
    weak var delegate: ChatGifPanelViewDelegate?
    private var panelVisible = false
    weak var hostViewController: UIViewController? {
        didSet {
            guard hostViewController !== oldValue else { return }
            removeEmbeddedPicker()
            if panelVisible {
                installEmbeddedPickerIfNeeded()
            }
        }
    }

    private let glassBackground = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let headerView = UIView()
    private let tabControl = UISegmentedControl(items: ["GIFs", "Stickers", "Emoji"])
    private let closeButton = UIButton(type: .system)
    private let contentView = UIView()
    private let fallbackLabel = UILabel()
    private let loadingView = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)

    #if canImport(GiphyUISDK)
        private var pickerViewController: GiphyViewController?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        removeEmbeddedPicker()
    }

    func prepareIfNeeded() {
        guard panelVisible else { return }
        installEmbeddedPickerIfNeeded()
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        if visible {
            installEmbeddedPickerIfNeeded()
        } else {
            removeEmbeddedPicker()
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        glassBackground.layer.cornerRadius = 20
        glassBackground.layer.cornerCurve = .continuous
        glassBackground.clipsToBounds = true
        let headerH: CGFloat = 42
        headerView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerH)
        tabControl.frame = CGRect(x: 12, y: 6, width: max(1, bounds.width - 64), height: 30)
        closeButton.frame = CGRect(x: bounds.width - 40, y: 5, width: 32, height: 32)
        contentView.frame = CGRect(
            x: 0, y: headerH, width: bounds.width, height: max(0, bounds.height - headerH))
        fallbackLabel.frame = contentView.bounds.insetBy(dx: 20, dy: 20)
        loadingView.frame = contentView.bounds
        loadingSpinner.center = CGPoint(x: loadingView.bounds.midX, y: loadingView.bounds.midY)

        #if canImport(GiphyUISDK)
            pickerViewController?.view.frame = contentView.bounds
        #endif
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        #if canImport(GiphyUISDK)
            guard let picker = pickerViewController else { return }
            picker.theme = GPHTheme(
                type: traitCollection.userInterfaceStyle == .dark ? .darkBlur : .lightBlur)
            normalizePickerVisuals()
        #endif
    }

    @objc private func closeTapped() {
        delegate?.chatGifPanelDidRequestClose(self)
    }

    @objc private func contentTypeChanged() {
        #if canImport(GiphyUISDK)
            guard let picker = pickerViewController else { return }
            switch tabControl.selectedSegmentIndex {
            case 1:
                picker.selectedContentType = .stickers
            case 2:
                picker.selectedContentType = .emoji
            default:
                picker.selectedContentType = .gifs
            }
        #endif
    }

    private func setupUI() {
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.35
        layer.borderColor = UIColor(white: 1.0, alpha: 0.08).cgColor
        clipsToBounds = true
        backgroundColor = .clear

        glassBackground.frame = bounds
        glassBackground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glassBackground)

        headerView.backgroundColor = .clear
        addSubview(headerView)

        tabControl.selectedSegmentIndex = 0
        tabControl.backgroundColor = .clear
        tabControl.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.16)
        tabControl.setTitleTextAttributes(
            [
                .foregroundColor: UIColor(white: 0.95, alpha: 0.84),
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            ],
            for: .normal
        )
        tabControl.setTitleTextAttributes(
            [
                .foregroundColor: UIColor.white,
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            ],
            for: .selected
        )
        tabControl.addTarget(self, action: #selector(contentTypeChanged), for: .valueChanged)
        headerView.addSubview(tabControl)

        let closeCfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: closeCfg), for: .normal)
        closeButton.tintColor = UIColor(white: 0.95, alpha: 0.85)
        closeButton.backgroundColor = .clear
        closeButton.layer.borderWidth = 0.35
        closeButton.layer.borderColor = UIColor(white: 1.0, alpha: 0.12).cgColor
        closeButton.layer.cornerRadius = 16
        closeButton.layer.cornerCurve = .continuous
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        headerView.addSubview(closeButton)

        contentView.backgroundColor = .clear
        addSubview(contentView)

        fallbackLabel.text = "Install the Giphy native SDK to enable GIF search."
        fallbackLabel.font = .systemFont(ofSize: 14)
        fallbackLabel.textColor = UIColor(white: 0.84, alpha: 0.78)
        fallbackLabel.textAlignment = .center
        fallbackLabel.numberOfLines = 0
        fallbackLabel.isHidden = true
        contentView.addSubview(fallbackLabel)

        loadingView.backgroundColor = .clear
        loadingView.isUserInteractionEnabled = false
        contentView.addSubview(loadingView)

        loadingSpinner.hidesWhenStopped = true
        loadingSpinner.startAnimating()
        loadingView.addSubview(loadingSpinner)

        if panelVisible {
            installEmbeddedPickerIfNeeded()
        }
        refreshGlass()
    }

    private func refreshGlass() {
        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect()
            glassEffect.isInteractive = true
            glassBackground.effect = glassEffect
            glassBackground.backgroundColor = .clear
        } else {
            glassBackground.effect = UIBlurEffect(style: .systemMaterial)
            glassBackground.backgroundColor = .clear
        }
    }

    private func configureGiphySDKIfNeeded() {
        #if canImport(GiphyUISDK)
            let key = ChatGifPanelConfig.shared.apiKey.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            Giphy.configure(apiKey: key)
        #endif
    }

    private func installEmbeddedPickerIfNeeded() {
        #if canImport(GiphyUISDK)
            guard pickerViewController == nil else { return }
            guard let host = hostViewController else {
                fallbackLabel.isHidden = false
                loadingSpinner.stopAnimating()
                loadingView.isHidden = true
                return
            }

            configureGiphySDKIfNeeded()

            let picker = GiphyViewController()
            picker.delegate = self
            picker.showConfirmationScreen = false
            picker.dimBackground = false
            picker.shouldLocalizeSearch = true
            picker.placeholderText = "Search"
            picker.theme = GPHTheme(
                type: traitCollection.userInterfaceStyle == .dark ? .darkBlur : .lightBlur)
            picker.mediaTypeConfig = [.gifs, .stickers, .emoji]
            picker.selectedContentType = .gifs

            // Try to natively hide the search bar if the property exists
            if picker.responds(to: NSSelectorFromString("setShowSearchBar:")) {
                picker.setValue(false, forKey: "showSearchBar")
            }

            host.addChild(picker)
            contentView.addSubview(picker.view)
            picker.view.frame = contentView.bounds
            picker.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            picker.view.backgroundColor = .clear
            picker.view.isOpaque = false
            contentView.bringSubviewToFront(loadingView)
            contentView.bringSubviewToFront(fallbackLabel)
            picker.didMove(toParent: host)

            pickerViewController = picker
            fallbackLabel.isHidden = true
            loadingSpinner.startAnimating()
            loadingView.isHidden = false
            contentTypeChanged()
            normalizePickerVisuals()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.normalizePickerVisuals()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                self?.normalizePickerVisuals()
                self?.loadingSpinner.stopAnimating()
                self?.loadingView.isHidden = true
            }
        #else
            fallbackLabel.isHidden = false
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
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

    private func normalizePickerVisuals() {
        #if canImport(GiphyUISDK)
            guard let rootView = pickerViewController?.view else { return }
            scrubBackgrounds(in: rootView)

            // Attempt to hide search bar and header views
            for subview in rootView.subviews {
                // If the view is relatively short and at the top, it's likely the search/tab header
                if subview.frame.height > 0 && subview.frame.height < 100 && subview.frame.minY < 50
                {
                    subview.alpha = 0
                    subview.isHidden = true
                }

                // If the view is the main collection/scroll view, shift it up
                if String(describing: type(of: subview)).contains("Grid")
                    || subview is UICollectionView || subview is UIScrollView
                {
                    subview.frame = rootView.bounds
                    subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                }
            }
        #endif
    }

    private func scrubBackgrounds(in view: UIView) {
        if !(view is UIVisualEffectView) {
            view.backgroundColor = .clear
            if let collectionView = view as? UICollectionView {
                collectionView.backgroundColor = .clear
            }
        }
        view.subviews.forEach { scrubBackgrounds(in: $0) }
    }

    private func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        let unwrapped = unwrapOptional(value)
        guard let unwrapped else { return nil }

        if let string = unwrapped as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let url = unwrapped as? URL {
            let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        let described = String(describing: unwrapped).trimmingCharacters(
            in: .whitespacesAndNewlines)
        if described.isEmpty || described == "nil" {
            return nil
        }
        return described
    }

    private func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        let unwrapped = unwrapOptional(value)
        guard let unwrapped else { return nil }

        if let intValue = unwrapped as? Int {
            return intValue
        }
        if let numberValue = unwrapped as? NSNumber {
            return numberValue.intValue
        }
        if let stringValue = unwrapped as? String,
            let parsed = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return parsed
        }
        return nil
    }

    private func value(for selectors: [String], on object: NSObject) -> Any? {
        var current: AnyObject? = object
        for selectorName in selectors {
            guard let target = current else { return nil }
            guard let nsTarget = target as? NSObject else { return nil }
            let selector = NSSelectorFromString(selectorName)
            guard nsTarget.responds(to: selector), let result = nsTarget.perform(selector) else {
                return nil
            }
            current = result.takeUnretainedValue()
        }
        return current
    }
}

#if canImport(GiphyUISDK)
    extension ChatGifPanelView: GiphyDelegate {
        func didDismiss(controller: GiphyViewController?) {
            delegate?.chatGifPanelDidRequestClose(self)
        }

        func didSelectMedia(
            giphyViewController: GiphyViewController,
            media: GPHMedia
        ) {
            emitSelection(media: media)
        }

        func didSelectMedia(
            giphyViewController: GiphyViewController,
            media: GPHMedia,
            contentType: GPHContentType
        ) {
            emitSelection(media: media)
        }

        private func emitSelection(media: GPHMedia) {
            let mediaObject = media as NSObject

            let id =
                stringValue(value(for: ["id"], on: mediaObject))
                ?? UUID().uuidString.lowercased()

            let urlCandidates: [String] = [
                stringValue(value(for: ["images", "original", "gifUrl"], on: mediaObject)),
                stringValue(value(for: ["images", "fixedWidth", "gifUrl"], on: mediaObject)),
                stringValue(value(for: ["images", "fixedHeight", "gifUrl"], on: mediaObject)),
                stringValue(value(for: ["url"], on: mediaObject)),
            ].compactMap { $0 }

            guard let url = urlCandidates.first else { return }

            let previewCandidates: [String] = [
                stringValue(value(for: ["images", "previewGif", "gifUrl"], on: mediaObject)),
                stringValue(
                    value(for: ["images", "fixedWidthSmallStill", "gifUrl"], on: mediaObject)),
                stringValue(value(for: ["images", "fixedWidthStill", "gifUrl"], on: mediaObject)),
                url,
            ].compactMap { $0 }

            let width = intValue(value(for: ["images", "original", "width"], on: mediaObject)) ?? 0
            let height =
                intValue(value(for: ["images", "original", "height"], on: mediaObject)) ?? 0

            delegate?.chatGifPanel(
                self,
                didSelectGif: ChatGifSelection(
                    id: id,
                    url: url,
                    previewUrl: previewCandidates.first ?? url,
                    width: width,
                    height: height
                )
            )
        }
    }
#endif
