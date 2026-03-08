import ExpoModulesCore
import SwiftUI
import UIKit

@MainActor
private final class NativeProfileAvatarModel: ObservableObject {
  @Published var fallbackText: String = "U"
  @Published var collapsed: Bool = false
  @Published var loadedImage: UIImage?
  @Published var expandedSize: CGFloat = 100.0
  @Published var collapsedSize: CGFloat = 40.0
  @Published var expandedTopInset: CGFloat = 0.0
  @Published var collapsedTopInset: CGFloat = 0.0
  @Published var scrollOffset: CGFloat = 0.0

  private var imageUri: String?
  private var imageTask: Task<Void, Never>?

  deinit {
    imageTask?.cancel()
  }

  func setImageUri(_ value: String?) {
    let normalizedValue = value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty

    guard normalizedValue != imageUri else { return }

    imageUri = normalizedValue
    imageTask?.cancel()

    guard let normalizedValue else {
      loadedImage = nil
      return
    }

    imageTask = Task { [weak self] in
      let image = await NativeProfileAvatarImageLoader.load(from: normalizedValue)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard let self else { return }
        guard self.imageUri == normalizedValue else { return }
        self.loadedImage = image
      }
    }
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

private enum NativeProfileAvatarImageLoader {
  static func load(from rawValue: String?) async -> UIImage? {
    guard let rawValue else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    if value.hasPrefix("data:"),
      let commaIndex = value.firstIndex(of: ",")
    {
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

    guard let url = URL(string: value) else {
      return nil
    }

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

private struct NativeProfileAvatarContentView: View {
  @ObservedObject var model: NativeProfileAvatarModel

  var body: some View {
    if #available(iOS 26.0, *) {
      NativeProfileAvatarGlassMorphView(model: model)
    } else {
      NativeProfileAvatarLegacyView(model: model)
    }
  }
}

private struct NativeProfileAvatarInnerContent: View {
  let image: UIImage?
  let fallbackText: String
  let size: CGFloat

  private var inset: CGFloat {
    max(2.0, size * 0.06)
  }

  var body: some View {
    ZStack {
      Color.clear

      Group {
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Circle()
            .fill(Color.white.opacity(0.16))

          Text(String(fallbackText.prefix(1)).uppercased())
            .font(.system(size: max(14.0, size * 0.34), weight: .semibold))
            .foregroundStyle(.white)
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
private struct NativeProfileAvatarGlassMorphView: View {
  @ObservedObject var model: NativeProfileAvatarModel
  @Namespace private var namespace
  @State private var showExpanded: Bool = true

  /// Distance between anchor bottom and expanded top — matches the
  /// GlassEffectContainer spacing exactly so effects stay separate at
  /// rest but morph during transitions (Apple pattern: container spacing
  /// == layout container spacing).
  private var gap: CGFloat {
    max(1, model.expandedTopInset - model.collapsedTopInset - model.collapsedSize)
  }

  var body: some View {
    GlassEffectContainer(spacing: gap) {
      // VStack spacing MUST equal container spacing — if container
      // spacing > VStack spacing, effects merge at rest.
      VStack(spacing: gap) {
        // Anchor: always-present morph target at collapsed position
        NativeProfileAvatarInnerContent(
          image: model.loadedImage,
          fallbackText: model.fallbackText,
          size: model.collapsedSize
        )
        .frame(width: model.collapsedSize, height: model.collapsedSize)
        .clipShape(Circle())
        .glassEffect()
        .glassEffectID("avatar-anchor", in: namespace)

        if showExpanded {
          // Expanded avatar — morphs into/out of anchor
          NativeProfileAvatarInnerContent(
            image: model.loadedImage,
            fallbackText: model.fallbackText,
            size: model.expandedSize
          )
          .frame(width: model.expandedSize, height: model.expandedSize)
          .clipShape(Circle())
          .glassEffect()
          .glassEffectID("avatar-main", in: namespace)
        }
      }
      .padding(.top, model.collapsedTopInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: model.collapsed) { _, isCollapsed in
      withAnimation(.bouncy) {
        showExpanded = !isCollapsed
      }
    }
  }
}

private struct NativeProfileAvatarLegacyView: View {
  @ObservedObject var model: NativeProfileAvatarModel

  private var currentSize: CGFloat {
    let travelDistance = max(1.0, model.expandedTopInset - model.collapsedTopInset)
    let progress = max(0.0, min(1.0, model.scrollOffset / travelDistance))
    return model.expandedSize + ((model.collapsedSize - model.expandedSize) * progress)
  }

  private var currentTopInset: CGFloat {
    let travelDistance = max(1.0, model.expandedTopInset - model.collapsedTopInset)
    let progress = max(0.0, min(1.0, model.scrollOffset / travelDistance))
    return model.expandedTopInset + ((model.collapsedTopInset - model.expandedTopInset) * progress)
  }

  var body: some View {
    NativeProfileAvatarInnerContent(
      image: model.loadedImage,
      fallbackText: model.fallbackText,
      size: currentSize
    )
    .padding(.top, currentTopInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

final class NativeProfileAvatarView: ExpoView {
  private let model = NativeProfileAvatarModel()
  private let hostingController: UIHostingController<AnyView>
  private var isHostingControllerAttached = false

  required init(appContext: AppContext? = nil) {
    hostingController = UIHostingController(
      rootView: AnyView(NativeProfileAvatarContentView(model: model))
    )
    super.init(appContext: appContext)

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

  func setImageUri(_ value: String?) {
    model.setImageUri(value)
  }

  func setFallbackText(_ value: String?) {
    let nextValue = (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? value
      : "U") ?? "U"
    guard model.fallbackText != nextValue else { return }
    model.fallbackText = nextValue
  }

  func setCollapsed(_ value: Bool?) {
    let resolved = value ?? false
    guard model.collapsed != resolved else { return }
    model.collapsed = resolved
  }

  func setExpandedSize(_ value: CGFloat?) {
    let resolved = max(1.0, value ?? 100.0)
    guard model.expandedSize != resolved else { return }
    model.expandedSize = resolved
  }

  func setCollapsedSize(_ value: CGFloat?) {
    let resolved = max(1.0, value ?? 40.0)
    guard model.collapsedSize != resolved else { return }
    model.collapsedSize = resolved
  }

  func setExpandedTopInset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard model.expandedTopInset != resolved else { return }
    model.expandedTopInset = resolved
  }

  func setCollapsedTopInset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard model.collapsedTopInset != resolved else { return }
    model.collapsedTopInset = resolved
  }

  func setScrollOffset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard model.scrollOffset != resolved else { return }
    model.scrollOffset = resolved
  }
}

public final class NativeProfileAvatarModule: Module {
  public func definition() -> ModuleDefinition {
    Name("NativeProfileAvatar")

    View(NativeProfileAvatarView.self) {
      Prop("imageUri") { (view: NativeProfileAvatarView, value: String?) in
        view.setImageUri(value)
      }

      Prop("fallbackText") { (view: NativeProfileAvatarView, value: String?) in
        view.setFallbackText(value)
      }

      Prop("collapsed") { (view: NativeProfileAvatarView, value: Bool?) in
        view.setCollapsed(value)
      }

      Prop("expandedSize") { (view: NativeProfileAvatarView, value: Double?) in
        view.setExpandedSize(value.map { CGFloat($0) })
      }

      Prop("collapsedSize") { (view: NativeProfileAvatarView, value: Double?) in
        view.setCollapsedSize(value.map { CGFloat($0) })
      }

      Prop("expandedTopInset") { (view: NativeProfileAvatarView, value: Double?) in
        view.setExpandedTopInset(value.map { CGFloat($0) })
      }

      Prop("collapsedTopInset") { (view: NativeProfileAvatarView, value: Double?) in
        view.setCollapsedTopInset(value.map { CGFloat($0) })
      }

      Prop("scrollOffset") { (view: NativeProfileAvatarView, value: Double?) in
        view.setScrollOffset(value.map { CGFloat($0) })
      }
    }
  }
}
