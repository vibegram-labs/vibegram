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
  let card: UIColor
  let text: UIColor
  let secondaryText: UIColor
  let primary: UIColor
  let isDark: Bool

  init(palette: AppThemePalette, isDark: Bool) {
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
