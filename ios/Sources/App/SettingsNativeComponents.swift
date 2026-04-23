import SwiftUI
import UIKit

enum SettingsNativeRowKind {
  case link
  case toggle
}

struct SettingsNativeRow: Identifiable, Equatable {
  let id: String
  let icon: String
  let label: String
  let detailText: String?
  let toggleValue: Bool
  let kind: SettingsNativeRowKind
  let iconColor: UIColor
  let divider: Bool
  let destructive: Bool
}

struct SettingsNativeSection: Identifiable, Equatable {
  let id = UUID()
  let title: String?
  let rows: [SettingsNativeRow]
}

struct SettingsNativeTheme {
  let background: UIColor
  let card: UIColor
  let text: UIColor
  let secondaryText: UIColor
  let primary: UIColor
  let isDark: Bool

  init(palette: AppThemePalette, isDark: Bool) {
    self.background = palette.backgroundUIColor
    self.card = palette.cardUIColor
    self.text = palette.textUIColor
    self.secondaryText = palette.secondaryTextUIColor
    self.primary = palette.accentUIColor
    self.isDark = isDark
  }
}

final class SettingsNativeRowView: UIControl {
  private let highlightOverlayView = UIView()
  private let iconBackgroundView = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let chevronImageView = UIImageView()
  private let switchControl = UISwitch()
  private let dividerView = UIView()

  private var currentRow: SettingsNativeRow?
  private var currentTheme: SettingsNativeTheme?
  private var onPress: (() -> Void)?
  private var onToggle: ((Bool) -> Void)?

  override var isHighlighted: Bool {
    didSet {
      updateHighlightAppearance(animated: true)
    }
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 58)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)

    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)

    highlightOverlayView.translatesAutoresizingMaskIntoConstraints = false
    highlightOverlayView.isUserInteractionEnabled = false
    highlightOverlayView.alpha = 0
    addSubview(highlightOverlayView)

    iconBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    iconBackgroundView.layer.cornerRadius = 8
    iconBackgroundView.clipsToBounds = true
    addSubview(iconBackgroundView)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    addSubview(titleLabel)

    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    valueLabel.font = .systemFont(ofSize: 15, weight: .regular)
    valueLabel.textAlignment = .right
    valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    valueLabel.setContentHuggingPriority(.required, for: .horizontal)
    addSubview(valueLabel)

    chevronImageView.translatesAutoresizingMaskIntoConstraints = false
    chevronImageView.contentMode = .scaleAspectFit
    chevronImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    chevronImageView.setContentHuggingPriority(.required, for: .horizontal)
    chevronImageView.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    )
    addSubview(chevronImageView)

    switchControl.translatesAutoresizingMaskIntoConstraints = false
    switchControl.setContentCompressionResistancePriority(.required, for: .horizontal)
    switchControl.setContentHuggingPriority(.required, for: .horizontal)
    switchControl.addTarget(self, action: #selector(handleSwitchChanged), for: .valueChanged)
    addSubview(switchControl)

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dividerView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 58),

      highlightOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      highlightOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      highlightOverlayView.topAnchor.constraint(equalTo: topAnchor),
      highlightOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      iconBackgroundView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconBackgroundView.widthAnchor.constraint(equalToConstant: 32),
      iconBackgroundView.heightAnchor.constraint(equalToConstant: 32),

      iconView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),

      titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevronImageView.widthAnchor.constraint(equalToConstant: 14),
      chevronImageView.heightAnchor.constraint(equalToConstant: 14),

      valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
      valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      valueLabel.trailingAnchor.constraint(equalTo: chevronImageView.leadingAnchor, constant: -8),

      switchControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      switchControl.centerYAnchor.constraint(equalTo: centerYAnchor),
      switchControl.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),

      dividerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 60),
      dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

      topAnchor.constraint(lessThanOrEqualTo: titleLabel.topAnchor, constant: 16),
      bottomAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor, constant: 16),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    row: SettingsNativeRow,
    theme: SettingsNativeTheme,
    onPress: (() -> Void)?,
    onToggle: ((Bool) -> Void)?
  ) {
    currentRow = row
    currentTheme = theme
    self.onPress = onPress
    self.onToggle = onToggle

    iconBackgroundView.backgroundColor = row.iconColor
    iconView.image = UIImage(
      systemName: row.icon,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    )
    iconView.tintColor = .white
    titleLabel.text = row.label
    titleLabel.textColor =
      row.destructive
      ? UIColor(red: 239 / 255, green: 68 / 255, blue: 68 / 255, alpha: 1.0)
      : theme.text
    valueLabel.text = row.detailText
    valueLabel.textColor = theme.secondaryText
    dividerView.isHidden = !row.divider
    dividerView.backgroundColor =
      (theme.isDark ? UIColor.white : UIColor.black).withAlphaComponent(theme.isDark ? 0.05 : 0.06)

    switch row.kind {
    case .link:
      chevronImageView.isHidden = false
      valueLabel.isHidden = row.detailText == nil
      switchControl.isHidden = true
    case .toggle:
      chevronImageView.isHidden = true
      valueLabel.isHidden = true
      switchControl.isHidden = false
      switchControl.onTintColor = theme.primary
      switchControl.setOn(row.toggleValue, animated: false)
    }

    chevronImageView.tintColor =
      (theme.isDark ? UIColor.white : UIColor.black).withAlphaComponent(theme.isDark ? 0.5 : 0.32)
    updateHighlightAppearance(animated: false)
  }

  @objc private func handleTap() {
    guard let row = currentRow else { return }
    switch row.kind {
    case .toggle:
      let nextValue = !switchControl.isOn
      switchControl.setOn(nextValue, animated: true)
      onToggle?(nextValue)
    case .link:
      onPress?()
    }
  }

  @objc private func handleSwitchChanged() {
    onToggle?(switchControl.isOn)
  }

  private func updateHighlightAppearance(animated: Bool) {
    guard let row = currentRow, let theme = currentTheme else { return }

    let targetAlpha: CGFloat = row.kind == .toggle ? 0 : (isHighlighted ? 1 : 0)
    let targetTransform: CGAffineTransform =
      row.kind == .toggle || !isHighlighted
      ? .identity
      : CGAffineTransform(scaleX: 0.97, y: 0.97)
    let targetOverlayColor =
      theme.isDark
      ? UIColor.white.withAlphaComponent(0.08)
      : UIColor.black.withAlphaComponent(0.05)

    let updates = {
      self.highlightOverlayView.backgroundColor = targetOverlayColor
      self.highlightOverlayView.alpha = targetAlpha
      self.iconBackgroundView.transform = targetTransform
    }

    if animated {
      UIView.animate(
        withDuration: 0.16,
        delay: 0,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
        animations: updates
      )
    } else {
      updates()
    }
  }
}

final class SettingsNativeRowContainerView: UIView {
  private let rowView = SettingsNativeRowView()

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 58)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)

    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    rowView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rowView)

    NSLayoutConstraint.activate([
      rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
      rowView.topAnchor.constraint(equalTo: topAnchor),
      rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    row: SettingsNativeRow,
    theme: SettingsNativeTheme,
    onPress: (() -> Void)?,
    onToggle: ((Bool) -> Void)?
  ) {
    rowView.configure(row: row, theme: theme, onPress: onPress, onToggle: onToggle)
  }
}

struct SettingsNativeRowControl: UIViewRepresentable {
  let row: SettingsNativeRow
  let palette: AppThemePalette
  let isDark: Bool
  let onPress: (() -> Void)?
  let onToggle: ((Bool) -> Void)?

  func makeUIView(context: Context) -> SettingsNativeRowContainerView {
    SettingsNativeRowContainerView()
  }

  func updateUIView(_ uiView: SettingsNativeRowContainerView, context: Context) {
    uiView.configure(
      row: row,
      theme: SettingsNativeTheme(palette: palette, isDark: isDark),
      onPress: onPress,
      onToggle: onToggle
    )
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: SettingsNativeRowContainerView,
    context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? UIView.noIntrinsicMetric, height: 58)
  }
}

struct SettingsNativeSectionCard: View {
  let section: SettingsNativeSection
  let palette: AppThemePalette
  let isDark: Bool
  let onPress: (String) -> Void
  let onToggle: (String, Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title = section.title, !title.isEmpty {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(palette.secondaryText.opacity(0.72))
          .padding(.horizontal, 16)
      }

      VStack(spacing: 0) {
        ForEach(section.rows) { row in
          SettingsNativeRowControl(
            row: row,
            palette: palette,
            isDark: isDark,
            onPress: {
              onPress(row.id)
            },
            onToggle: { value in
              onToggle(row.id, value)
            }
          )
          .frame(maxWidth: .infinity, minHeight: 58)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .fill(palette.card)
      )
      .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
  }
}

@MainActor
private final class SettingsAvatarModel: ObservableObject {
  @Published var fallbackText: String = "U"
  @Published var loadedImage: UIImage?
  @Published var expandedSize: CGFloat = 100.0
  @Published var collapsedSize: CGFloat = 32.0
  @Published var expandedTopInset: CGFloat = 80.0
  @Published var collapsedTopInset: CGFloat = 0.0
  @Published var scrollOffset: CGFloat = 0.0
  @Published var islandCoverColor: UIColor = UIColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1.0)
  @Published var fallbackBackgroundColor: UIColor = UIColor(
    red: 222 / 255,
    green: 230 / 255,
    blue: 243 / 255,
    alpha: 1.0
  )
  @Published var fallbackIconTintColor: UIColor = UIColor.darkText

  private var imageURI: String?
  private var imageTask: Task<Void, Never>?

  deinit {
    imageTask?.cancel()
  }

  func setImageURI(_ value: String?) {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized != imageURI else { return }

    imageURI = normalized
    imageTask?.cancel()

    guard let normalized, !normalized.isEmpty else {
      loadedImage = nil
      return
    }

    imageTask = Task { [weak self] in
      let image = await SettingsAvatarImageLoader.load(from: normalized)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.imageURI == normalized else { return }
        self.loadedImage = image
      }
    }
  }
}

private enum SettingsAvatarHeroMetrics {
  static let topAdjust: CGFloat = 12
  static let islandAnchor: CGFloat = 56
  static let topOffset: CGFloat = 80
  static let collapsedTopOffset: CGFloat = 25
  static let expandedSize: CGFloat = 100
  static let collapsedSize: CGFloat = 32
  static let bottomSpacing: CGFloat = 20

  static func expandedTop(for safeTop: CGFloat) -> CGFloat {
    max(0, safeTop - islandAnchor - topAdjust) + topOffset
  }

  static func collapsedTop(for safeTop: CGFloat) -> CGFloat {
    max(0, safeTop - 18 - collapsedTopOffset)
  }

  static func hostHeight(for safeTop: CGFloat) -> CGFloat {
    expandedTop(for: safeTop) + expandedSize + bottomSpacing
  }
}

private enum SettingsAvatarImageLoader {
  static func load(from rawValue: String?) async -> UIImage? {
    guard let rawValue else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    if value.hasPrefix("data:"), let commaIndex = value.firstIndex(of: ",") {
      let base64 = String(value[value.index(after: commaIndex)...])
      guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
        return nil
      }
      return UIImage(data: data)
    }

    if let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) {
      return UIImage(data: data)
    }

    if value.hasPrefix("/") {
      return UIImage(contentsOfFile: value)
    }

    guard let url = URL(string: value) else { return nil }
    if url.isFileURL {
      return UIImage(contentsOfFile: url.path)
    }

    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return nil
    }

    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      return UIImage(data: data)
    } catch {
      return nil
    }
  }
}

struct SettingsAvatarHeroView: View {
  let imageURI: String?
  let fallbackText: String
  let scrollOffset: CGFloat
  let palette: AppThemePalette

  static var hostHeight: CGFloat {
    SettingsAvatarHeroMetrics.hostHeight(for: 0)
  }

  @StateObject private var model = SettingsAvatarModel()

  var body: some View {
    GeometryReader { proxy in
      let safeTop = proxy.safeAreaInsets.top

      ZStack(alignment: .top) {
        if #available(iOS 26.0, *) {
          SettingsAvatarGlassMorphView(model: model)
        } else {
          SettingsAvatarLegacyView(model: model)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        applyModelMetrics(safeTop: safeTop)
      }
      .onChange(of: safeTop) { _, newValue in
        applyModelMetrics(safeTop: newValue)
      }
    }
    .frame(height: Self.hostHeight)
    .frame(maxWidth: .infinity, alignment: .top)
    .onAppear {
      model.setImageURI(imageURI)
      model.fallbackText = fallbackText
      model.scrollOffset = scrollOffset
      applyPalette()
    }
    .onChange(of: imageURI) { _, newValue in
      model.setImageURI(newValue)
    }
    .onChange(of: fallbackText) { _, newValue in
      model.fallbackText = newValue
    }
    .onChange(of: scrollOffset) { _, newValue in
      model.scrollOffset = max(0, newValue)
    }
    .onChange(of: palette.backgroundUIColor.description) { _, _ in
      applyPalette()
    }
  }

  private func applyModelMetrics(safeTop: CGFloat) {
    model.expandedSize = SettingsAvatarHeroMetrics.expandedSize
    model.collapsedSize = SettingsAvatarHeroMetrics.collapsedSize
    model.expandedTopInset = SettingsAvatarHeroMetrics.expandedTop(for: safeTop)
    model.collapsedTopInset = SettingsAvatarHeroMetrics.collapsedTop(for: safeTop)
  }

  private func applyPalette() {
    model.islandCoverColor = palette.backgroundUIColor
    model.fallbackBackgroundColor = palette.cardUIColor
    model.fallbackIconTintColor = palette.textUIColor
  }
}

private struct SettingsAvatarInnerContent: View {
  let image: UIImage?
  let fallbackIconTintColor: UIColor
  let fallbackBackgroundColor: UIColor
  let size: CGFloat

  private var inset: CGFloat {
    max(2.0, size * 0.06)
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(Color(uiColor: fallbackBackgroundColor))

      Group {
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "person.fill")
            .resizable()
            .scaledToFit()
            .frame(
              width: max(14.0, size * 0.34),
              height: max(14.0, size * 0.34)
            )
            .foregroundStyle(Color(uiColor: fallbackIconTintColor))
        }
      }
      .padding(inset)
      .clipShape(Circle())
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }
}

@available(iOS 26.0, *)
private struct SettingsAvatarGlassMorphView: View {
  @ObservedObject var model: SettingsAvatarModel

  private var progress: CGFloat {
    let travel = max(1, model.expandedTopInset - model.collapsedTopInset)
    return max(0, min(1, model.scrollOffset / travel))
  }

  private var currentSize: CGFloat {
    model.expandedSize + (model.collapsedSize - model.expandedSize) * progress
  }

  private var currentTop: CGFloat {
    model.expandedTopInset + (model.collapsedTopInset - model.expandedTopInset) * progress
  }

  private var glassOpacity: CGFloat {
    progress < 0.85 ? 1.0 : max(0, 1.0 - (progress - 0.85) / 0.15)
  }

  var body: some View {
    ZStack(alignment: .top) {
      GlassEffectContainer(spacing: 40.0) {
        ZStack(alignment: .top) {
          Capsule()
            .fill(Color.black)
            .frame(width: 126, height: 37)
            .glassEffect(in: .capsule)
            .opacity(progress > 0.05 ? glassOpacity : 0.0)
            .offset(y: 11)

          Circle()
            .fill(Color.black)
            .frame(width: currentSize, height: currentSize)
            .glassEffect(in: .circle)
            .opacity(glassOpacity)
            .offset(y: currentTop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      .environment(\.colorScheme, .dark)

      Capsule()
        .fill(Color(uiColor: model.islandCoverColor))
        .frame(width: 130, height: 40)
        .offset(y: 9)

      SettingsAvatarInnerContent(
        image: model.loadedImage,
        fallbackIconTintColor: model.fallbackIconTintColor,
        fallbackBackgroundColor: model.fallbackBackgroundColor,
        size: currentSize
      )
      .offset(y: currentTop)
      .opacity(glassOpacity)
    }
  }
}

private struct SettingsAvatarLegacyView: View {
  @ObservedObject var model: SettingsAvatarModel

  private var progress: CGFloat {
    let travelDistance = max(1.0, model.expandedTopInset - model.collapsedTopInset)
    return max(0.0, min(1.0, model.scrollOffset / travelDistance))
  }

  private var currentSize: CGFloat {
    model.expandedSize + ((model.collapsedSize - model.expandedSize) * progress)
  }

  private var currentTopInset: CGFloat {
    model.expandedTopInset + ((model.collapsedTopInset - model.expandedTopInset) * progress)
  }

  var body: some View {
    SettingsAvatarInnerContent(
      image: model.loadedImage,
      fallbackIconTintColor: model.fallbackIconTintColor,
      fallbackBackgroundColor: model.fallbackBackgroundColor,
      size: currentSize
    )
    .padding(.top, currentTopInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

private struct SettingsNativeAvatarContentView: View {
  @ObservedObject var model: SettingsAvatarModel

  var body: some View {
    if #available(iOS 26.0, *) {
      SettingsAvatarGlassMorphView(model: model)
    } else {
      SettingsAvatarLegacyView(model: model)
    }
  }
}

final class SettingsNativeAvatarView: UIView {
  private let model = SettingsAvatarModel()
  private let hostingController: UIHostingController<AnyView>
  private var isHostingControllerAttached = false

  override init(frame: CGRect) {
    hostingController = UIHostingController(
      rootView: AnyView(SettingsNativeAvatarContentView(model: model))
    )
    super.init(frame: frame)

    backgroundColor = .clear
    clipsToBounds = false

    if #available(iOS 16.4, *) {
      hostingController.safeAreaRegions = []
    }

    let hostedView = hostingController.view!
    hostedView.translatesAutoresizingMaskIntoConstraints = false
    hostedView.backgroundColor = .clear
    hostedView.clipsToBounds = false
    addSubview(hostedView)

    NSLayoutConstraint.activate([
      hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostedView.topAnchor.constraint(equalTo: topAnchor),
      hostedView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, !isHostingControllerAttached {
      if let parentVC = findNearestViewController() {
        parentVC.addChild(hostingController)
        hostingController.didMove(toParent: parentVC)
        isHostingControllerAttached = true
      }
    } else if window == nil, isHostingControllerAttached {
      hostingController.willMove(toParent: nil)
      hostingController.removeFromParent()
      isHostingControllerAttached = false
    }
  }

  private func findNearestViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let vc = next as? UIViewController {
        return vc
      }
      responder = next
    }
    return nil
  }

  func setImageURI(_ value: String?) {
    model.setImageURI(value)
  }

  func setFallbackText(_ value: String?) {
    let nextValue =
      (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? value
        : "U") ?? "U"
    guard model.fallbackText != nextValue else { return }
    model.fallbackText = nextValue
  }

  func setExpandedSize(_ value: CGFloat) {
    let resolved = max(1.0, value)
    guard model.expandedSize != resolved else { return }
    model.expandedSize = resolved
  }

  func setCollapsedSize(_ value: CGFloat) {
    let resolved = max(1.0, value)
    guard model.collapsedSize != resolved else { return }
    model.collapsedSize = resolved
  }

  func setExpandedTopInset(_ value: CGFloat) {
    let resolved = max(0.0, value)
    guard model.expandedTopInset != resolved else { return }
    model.expandedTopInset = resolved
  }

  func setCollapsedTopInset(_ value: CGFloat) {
    let resolved = max(0.0, value)
    guard model.collapsedTopInset != resolved else { return }
    model.collapsedTopInset = resolved
  }

  func setScrollOffset(_ value: CGFloat) {
    let resolved = max(0.0, value)
    guard model.scrollOffset != resolved else { return }
    model.scrollOffset = resolved
  }

  func setIslandCoverColor(_ value: UIColor) {
    guard model.islandCoverColor != value else { return }
    model.islandCoverColor = value
  }

  func setFallbackBackgroundColor(_ value: UIColor) {
    guard model.fallbackBackgroundColor != value else { return }
    model.fallbackBackgroundColor = value
  }

  func setFallbackIconTintColor(_ value: UIColor) {
    guard model.fallbackIconTintColor != value else { return }
    model.fallbackIconTintColor = value
  }
}

private final class SettingsNativeGlassButton: UIControl {
  private let effectView = UIVisualEffectView(effect: nil)
  private let titleLabelView = UILabel()
  private let iconView = UIImageView()
  private let overlayView = UIView()
  private var iconSizeConstraint: NSLayoutConstraint?
  private var heightConstraint: NSLayoutConstraint?
  private var widthConstraint: NSLayoutConstraint?

  var iconTintColor: UIColor = .white {
    didSet {
      iconView.tintColor = iconTintColor
      titleLabelView.textColor = iconTintColor
    }
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.16) {
        self.overlayView.alpha = self.isHighlighted ? 1.0 : 0.0
        self.transform =
          self.isHighlighted
          ? CGAffineTransform(scaleX: 0.96, y: 0.96)
          : .identity
      }
    }
  }

  override var intrinsicContentSize: CGSize {
    let height = heightConstraint?.constant ?? 44
    if let widthConstraint, widthConstraint.isActive {
      return CGSize(width: widthConstraint.constant, height: height)
    }

    if let text = titleLabelView.text, !text.isEmpty {
      let textWidth = ceil(
        (text as NSString).size(withAttributes: [.font: titleLabelView.font as Any]).width)
      return CGSize(width: max(56, textWidth + 28), height: height)
    }

    if iconView.image != nil {
      return CGSize(width: height, height: height)
    }

    return CGSize(width: height, height: height)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)

    translatesAutoresizingMaskIntoConstraints = false
    clipsToBounds = false

    effectView.translatesAutoresizingMaskIntoConstraints = false
    effectView.clipsToBounds = true
    if #available(iOS 13.0, *) {
      effectView.layer.cornerCurve = .continuous
    }
    addSubview(effectView)

    overlayView.translatesAutoresizingMaskIntoConstraints = false
    overlayView.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    overlayView.alpha = 0
    effectView.contentView.addSubview(overlayView)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.tintColor = iconTintColor
    effectView.contentView.addSubview(iconView)

    titleLabelView.translatesAutoresizingMaskIntoConstraints = false
    titleLabelView.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabelView.textAlignment = .center
    titleLabelView.textColor = iconTintColor
    effectView.contentView.addSubview(titleLabelView)

    NSLayoutConstraint.activate([
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

      overlayView.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
      overlayView.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
      overlayView.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),

      iconView.centerXAnchor.constraint(equalTo: effectView.contentView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),

      titleLabelView.leadingAnchor.constraint(
        equalTo: effectView.contentView.leadingAnchor,
        constant: 14
      ),
      titleLabelView.trailingAnchor.constraint(
        equalTo: effectView.contentView.trailingAnchor,
        constant: -14
      ),
      titleLabelView.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),
    ])

    iconSizeConstraint = iconView.widthAnchor.constraint(equalToConstant: 20)
    iconSizeConstraint?.isActive = true
    iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor).isActive = true

    heightConstraint = heightAnchor.constraint(equalToConstant: 44)
    heightConstraint?.isActive = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setGlassTheme(isDark: Bool) {
    if #available(iOS 26.0, *) {
      effectView.effect = UIGlassEffect()
      effectView.contentView.backgroundColor = .clear
    } else {
      effectView.effect = UIBlurEffect(
        style: isDark ? .systemThinMaterialDark : .systemThinMaterialLight
      )
      effectView.contentView.backgroundColor =
        (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.12 : 0.06)
    }
    effectView.layer.cornerRadius = (heightConstraint?.constant ?? 44) * 0.5
  }

  func setIcon(systemName: String?, pointSize: CGFloat = 20) {
    guard let systemName, !systemName.isEmpty else {
      iconView.image = nil
      iconView.isHidden = true
      invalidateIntrinsicContentSize()
      return
    }
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    iconView.image = UIImage(systemName: systemName, withConfiguration: configuration)
    iconView.isHidden = false
    iconSizeConstraint?.constant = pointSize
    invalidateIntrinsicContentSize()
  }

  func setTitle(_ title: String?) {
    titleLabelView.text = title
    titleLabelView.isHidden = title?.isEmpty ?? true
    invalidateIntrinsicContentSize()
  }

  func setButtonSize(width: CGFloat?, height: CGFloat = 44) {
    heightConstraint?.constant = height
    if let width {
      if widthConstraint == nil {
        widthConstraint = widthAnchor.constraint(equalToConstant: width)
        widthConstraint?.isActive = true
      } else {
        widthConstraint?.constant = width
      }
    } else {
      widthConstraint?.isActive = false
      widthConstraint = nil
    }
    effectView.layer.cornerRadius = height * 0.5
    invalidateIntrinsicContentSize()
  }
}

final class SettingsNativeMainView: UIView, UIScrollViewDelegate {
  var onRowPress: ((String) -> Void)?
  var onRowToggle: ((String, Bool) -> Void)?
  var onHeaderQr: (() -> Void)?
  var onHeaderEdit: (() -> Void)?
  var onSignOut: (() -> Void)?

  private let backgroundView = UIView()
  private let scrollView = UIScrollView()
  private let scrollContentView = UIView()
  private let contentStack = UIStackView()
  private let headerMaskContainer = UIView()
  private let headerMaskLayer = CAGradientLayer()
  private let qrButton = SettingsNativeGlassButton()
  private let editButton = SettingsNativeGlassButton()
  private let avatarView = SettingsNativeAvatarView()
  private let heroSpacerView = UIView()
  private let profileHeaderStack = UIStackView()
  private let profileNameRow = UIStackView()
  private let nameLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let footerLabel = UILabel()
  private let signOutButton = UIButton(type: .system)

  private var headerMaskHeightConstraint: NSLayoutConstraint?
  private var qrTopConstraint: NSLayoutConstraint?
  private var editTopConstraint: NSLayoutConstraint?
  private var avatarHeightConstraint: NSLayoutConstraint?
  private var heroSpacerHeightConstraint: NSLayoutConstraint?

  private var theme = SettingsNativeTheme(
    palette: AppThemePalette.resolve(for: .dark),
    isDark: true
  )
  private var sections: [SettingsNativeSection] = []
  private var currentHeroTop: CGFloat = 0
  private var currentCollapsedTop: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    configureView()
    rebuildSections()
    updateMetrics()
    updateScrollAnimations(offsetY: 0)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    updateMetrics()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    headerMaskLayer.frame = headerMaskContainer.bounds
  }

  func configure(
    displayName: String,
    subtitle: String,
    avatarImageURI: String?,
    avatarFallbackText: String,
    footerText: String,
    sections: [SettingsNativeSection],
    palette: AppThemePalette,
    isDark: Bool,
    onRowPress: ((String) -> Void)?,
    onRowToggle: ((String, Bool) -> Void)?,
    onHeaderQr: (() -> Void)?,
    onHeaderEdit: (() -> Void)?,
    onSignOut: (() -> Void)?
  ) {
    theme = SettingsNativeTheme(palette: palette, isDark: isDark)
    self.sections = sections
    self.onRowPress = onRowPress
    self.onRowToggle = onRowToggle
    self.onHeaderQr = onHeaderQr
    self.onHeaderEdit = onHeaderEdit
    self.onSignOut = onSignOut

    nameLabel.text = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    subtitleLabel.text = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    footerLabel.text = footerText.trimmingCharacters(in: .whitespacesAndNewlines)

    avatarView.setImageURI(avatarImageURI)
    avatarView.setFallbackText(avatarFallbackText)
    avatarView.setIslandCoverColor(palette.backgroundUIColor)
    avatarView.setFallbackBackgroundColor(palette.cardUIColor)
    avatarView.setFallbackIconTintColor(palette.textUIColor)

    applyTheme()
    rebuildSections()
    updateMetrics()
    updateScrollAnimations(offsetY: scrollView.contentOffset.y)
  }

  private func configureView() {
    backgroundColor = .clear
    clipsToBounds = false

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.showsVerticalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.alwaysBounceVertical = true
    scrollView.delegate = self
    addSubview(scrollView)

    scrollContentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(scrollContentView)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 24
    scrollContentView.addSubview(contentStack)

    headerMaskContainer.translatesAutoresizingMaskIntoConstraints = false
    headerMaskContainer.isUserInteractionEnabled = false
    headerMaskContainer.layer.zPosition = 10
    addSubview(headerMaskContainer)

    headerMaskLayer.locations = [0.0, 0.7, 1.0]
    headerMaskLayer.startPoint = CGPoint(x: 0.5, y: 0)
    headerMaskLayer.endPoint = CGPoint(x: 0.5, y: 1)
    headerMaskContainer.layer.addSublayer(headerMaskLayer)

    qrButton.setIcon(systemName: "qrcode", pointSize: 20)
    qrButton.setButtonSize(width: 44)
    qrButton.addTarget(self, action: #selector(handleHeaderQrPress), for: .touchUpInside)
    qrButton.layer.zPosition = 40
    addSubview(qrButton)

    editButton.setTitle("Edit")
    editButton.setButtonSize(width: nil)
    editButton.addTarget(self, action: #selector(handleHeaderEditPress), for: .touchUpInside)
    editButton.layer.zPosition = 40
    addSubview(editButton)

    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.clipsToBounds = false
    avatarView.layer.zPosition = 30
    addSubview(avatarView)

    heroSpacerView.translatesAutoresizingMaskIntoConstraints = false
    contentStack.addArrangedSubview(heroSpacerView)

    profileHeaderStack.translatesAutoresizingMaskIntoConstraints = false
    profileHeaderStack.axis = .vertical
    profileHeaderStack.alignment = .center
    profileHeaderStack.spacing = 2
    contentStack.addArrangedSubview(profileHeaderStack)

    profileNameRow.translatesAutoresizingMaskIntoConstraints = false
    profileNameRow.axis = .horizontal
    profileNameRow.alignment = .center
    profileNameRow.spacing = 6
    profileHeaderStack.addArrangedSubview(profileNameRow)

    nameLabel.font = .systemFont(ofSize: 28, weight: .regular)
    nameLabel.textAlignment = .center
    profileNameRow.addArrangedSubview(nameLabel)

    subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
    subtitleLabel.textAlignment = .center
    profileHeaderStack.addArrangedSubview(subtitleLabel)

    footerLabel.translatesAutoresizingMaskIntoConstraints = false
    footerLabel.font = .systemFont(ofSize: 12, weight: .regular)
    footerLabel.textAlignment = .center

    signOutButton.translatesAutoresizingMaskIntoConstraints = false
    signOutButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    signOutButton.layer.cornerRadius = 24
    if #available(iOS 13.0, *) {
      signOutButton.layer.cornerCurve = .continuous
    }
    signOutButton.addTarget(self, action: #selector(handleSignOutPress), for: .touchUpInside)

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollContentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      scrollContentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      scrollContentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      scrollContentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      scrollContentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      contentStack.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
      contentStack.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),
      contentStack.topAnchor.constraint(equalTo: scrollContentView.topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: scrollContentView.bottomAnchor, constant: -100),

      headerMaskContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      headerMaskContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      headerMaskContainer.topAnchor.constraint(equalTo: topAnchor),

      qrButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      editButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

      avatarView.leadingAnchor.constraint(equalTo: leadingAnchor),
      avatarView.trailingAnchor.constraint(equalTo: trailingAnchor),
      avatarView.topAnchor.constraint(equalTo: topAnchor),
    ])

    headerMaskHeightConstraint = headerMaskContainer.heightAnchor.constraint(equalToConstant: 104)
    headerMaskHeightConstraint?.isActive = true

    qrTopConstraint = qrButton.topAnchor.constraint(equalTo: topAnchor, constant: 8)
    qrTopConstraint?.isActive = true

    editTopConstraint = editButton.topAnchor.constraint(equalTo: topAnchor, constant: 8)
    editTopConstraint?.isActive = true

    avatarHeightConstraint = avatarView.heightAnchor.constraint(equalToConstant: 220)
    avatarHeightConstraint?.isActive = true

    heroSpacerHeightConstraint = heroSpacerView.heightAnchor.constraint(equalToConstant: 220)
    heroSpacerHeightConstraint?.isActive = true

    bringSubviewToFront(avatarView)
    bringSubviewToFront(qrButton)
    bringSubviewToFront(editButton)

    applyTheme()
  }

  private func rebuildSections() {
    while contentStack.arrangedSubviews.count > 2 {
      let subview = contentStack.arrangedSubviews[2]
      contentStack.removeArrangedSubview(subview)
      subview.removeFromSuperview()
    }

    for section in sections {
      contentStack.addArrangedSubview(makeSectionView(section))
    }

    contentStack.addArrangedSubview(makeSignOutView())
    contentStack.addArrangedSubview(makeFooterView())
  }

  private func makeSectionView(_ section: SettingsNativeSection) -> UIView {
    let wrapper = UIStackView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    wrapper.axis = .vertical
    wrapper.spacing = 8

    if let title = section.title, !title.isEmpty {
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = .systemFont(ofSize: 13, weight: .semibold)
      label.textColor = theme.secondaryText
      label.text = title.uppercased()
      label.alpha = 0.6
      wrapper.addArrangedSubview(label)
    }

    let card = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = theme.card
    card.layer.cornerRadius = 26
    if #available(iOS 13.0, *) {
      card.layer.cornerCurve = .continuous
    }
    card.clipsToBounds = true
    wrapper.addArrangedSubview(card)

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 0
    card.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      stack.topAnchor.constraint(equalTo: card.topAnchor),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
    ])

    for row in section.rows {
      let rowView = SettingsNativeRowView()
      rowView.configure(
        row: row,
        theme: theme,
        onPress: { [weak self] in
          self?.onRowPress?(row.id)
        },
        onToggle: { [weak self] value in
          self?.onRowToggle?(row.id, value)
        }
      )
      stack.addArrangedSubview(rowView)
    }

    return wrapper
  }

  private func makeSignOutView() -> UIView {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    signOutButton.removeFromSuperview()
    container.addSubview(signOutButton)

    NSLayoutConstraint.activate([
      signOutButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      signOutButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      signOutButton.topAnchor.constraint(equalTo: container.topAnchor),
      signOutButton.heightAnchor.constraint(equalToConstant: 54),
      signOutButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    return container
  }

  private func makeFooterView() -> UIView {
    let footerContainer = UIView()
    footerContainer.translatesAutoresizingMaskIntoConstraints = false
    footerLabel.removeFromSuperview()
    footerContainer.addSubview(footerLabel)

    NSLayoutConstraint.activate([
      footerLabel.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
      footerLabel.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),
      footerLabel.topAnchor.constraint(equalTo: footerContainer.topAnchor, constant: 10),
      footerLabel.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor, constant: -30),
    ])

    return footerContainer
  }

  private func applyTheme() {
    backgroundView.backgroundColor = theme.background
    headerMaskLayer.colors = [
      theme.background.withAlphaComponent(theme.isDark ? 0.16 : 0.10).cgColor,
      theme.background.withAlphaComponent(theme.isDark ? 0.05 : 0.03).cgColor,
      UIColor.clear.cgColor,
    ]
    nameLabel.textColor = theme.text
    subtitleLabel.textColor = theme.secondaryText
    footerLabel.textColor = theme.secondaryText
    footerLabel.alpha = 0.5
    qrButton.iconTintColor = theme.text
    editButton.iconTintColor = theme.text
    qrButton.setGlassTheme(isDark: theme.isDark)
    editButton.setGlassTheme(isDark: theme.isDark)
    signOutButton.backgroundColor = theme.card
    signOutButton.setTitleColor(
      UIColor(red: 239 / 255, green: 68 / 255, blue: 68 / 255, alpha: 1.0),
      for: .normal
    )
    signOutButton.setTitle("Sign Out", for: .normal)
  }

  private func updateMetrics() {
    let topInset = safeAreaInsets.top
    let headerHeight = topInset + 60
    let heroTop = SettingsAvatarHeroMetrics.expandedTop(for: topInset)
    let collapsedTop = SettingsAvatarHeroMetrics.collapsedTop(for: topInset)
    let hostHeight = SettingsAvatarHeroMetrics.hostHeight(for: topInset)

    currentHeroTop = heroTop
    currentCollapsedTop = collapsedTop

    headerMaskHeightConstraint?.constant = headerHeight
    qrTopConstraint?.constant = topInset
    editTopConstraint?.constant = topInset
    avatarHeightConstraint?.constant = hostHeight
    heroSpacerHeightConstraint?.constant = hostHeight

    avatarView.setExpandedSize(SettingsAvatarHeroMetrics.expandedSize)
    avatarView.setCollapsedSize(SettingsAvatarHeroMetrics.collapsedSize)
    avatarView.setExpandedTopInset(heroTop)
    avatarView.setCollapsedTopInset(collapsedTop)
    avatarView.setScrollOffset(scrollView.contentOffset.y)
  }

  private func updateScrollAnimations(offsetY: CGFloat) {
    let resolvedOffset = max(0, offsetY)
    avatarView.setScrollOffset(resolvedOffset)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateScrollAnimations(offsetY: scrollView.contentOffset.y)
  }

  @objc private func handleHeaderQrPress() {
    onHeaderQr?()
  }

  @objc private func handleHeaderEditPress() {
    onHeaderEdit?()
  }

  @objc private func handleSignOutPress() {
    onSignOut?()
  }
}

struct SettingsNativeMainViewRepresentable: UIViewRepresentable {
  let displayName: String
  let subtitle: String
  let avatarImageURI: String?
  let avatarFallbackText: String
  let footerText: String
  let sections: [SettingsNativeSection]
  let palette: AppThemePalette
  let isDark: Bool
  let onRowPress: (String) -> Void
  let onRowToggle: (String, Bool) -> Void
  let onHeaderQr: () -> Void
  let onHeaderEdit: () -> Void
  let onSignOut: () -> Void

  func makeUIView(context: Context) -> SettingsNativeMainView {
    SettingsNativeMainView()
  }

  func updateUIView(_ uiView: SettingsNativeMainView, context: Context) {
    uiView.configure(
      displayName: displayName,
      subtitle: subtitle,
      avatarImageURI: avatarImageURI,
      avatarFallbackText: avatarFallbackText,
      footerText: footerText,
      sections: sections,
      palette: palette,
      isDark: isDark,
      onRowPress: onRowPress,
      onRowToggle: onRowToggle,
      onHeaderQr: onHeaderQr,
      onHeaderEdit: onHeaderEdit,
      onSignOut: onSignOut
    )
  }
}
