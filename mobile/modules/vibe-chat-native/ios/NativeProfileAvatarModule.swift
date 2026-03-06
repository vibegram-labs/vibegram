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
      let _ = print("[ProfileAvatar] ContentView: using GlassMorph path (iOS 26+)")
      NativeProfileAvatarGlassMorphView(model: model)
    } else {
      let _ = print("[ProfileAvatar] ContentView: using Legacy path (< iOS 26)")
      NativeProfileAvatarLegacyView(model: model)
    }
  }
}

@available(iOS 26.0, *)
private struct NativeProfileAvatarGlassMorphView: View {
  @ObservedObject var model: NativeProfileAvatarModel
  @Namespace private var namespace
  @State private var showExpanded: Bool = true

  var body: some View {
    let _ = print("[ProfileAvatar] GlassMorph body: showExpanded=\(showExpanded) collapsed=\(model.collapsed) collapsedSize=\(model.collapsedSize) expandedSize=\(model.expandedSize) collapsedTopInset=\(model.collapsedTopInset) expandedTopInset=\(model.expandedTopInset) spacerHeight=\(max(0, model.expandedTopInset - model.collapsedTopInset - model.collapsedSize))")
    GlassEffectContainer(spacing: 200.0) {
      // Use VStack so layout positions the glass shapes — no modifiers after glassEffectID
      VStack(spacing: 0) {
        Spacer()
          .frame(height: model.collapsedTopInset)

        // Anchor glass near Dynamic Island — always present, morph target
        NativeProfileAvatarImageView(
          image: model.loadedImage,
          fallbackText: model.fallbackText
        )
        .frame(width: model.collapsedSize, height: model.collapsedSize)
        .clipShape(Circle())
        .glassEffect()
        .glassEffectID("avatar-anchor", in: namespace)

        if showExpanded {
          Spacer()
            .frame(height: max(0, model.expandedTopInset - model.collapsedTopInset - model.collapsedSize))

          // Expanded avatar — morphs into anchor on collapse
          NativeProfileAvatarImageView(
            image: model.loadedImage,
            fallbackText: model.fallbackText
          )
          .frame(width: model.expandedSize, height: model.expandedSize)
          .clipShape(Circle())
          .glassEffect()
          .glassEffectID("avatar-main", in: namespace)
        }

        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: model.collapsed) { _, isCollapsed in
      print("[ProfileAvatar] onChange: collapsed=\(isCollapsed) -> showExpanded=\(!isCollapsed)")
      withAnimation(.bouncy) {
        showExpanded = !isCollapsed
      }
    }
  }
}

private struct NativeProfileAvatarLegacyView: View {
  @ObservedObject var model: NativeProfileAvatarModel

  var body: some View {
    NativeProfileAvatarImageView(image: model.loadedImage, fallbackText: model.fallbackText)
      .frame(width: model.expandedSize, height: model.expandedSize)
      .clipShape(Circle())
  }
}

private struct NativeProfileAvatarImageView: View {
  let image: UIImage?
  let fallbackText: String

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Circle()
          .fill(Color.white.opacity(0.16))

        Text(String(fallbackText.prefix(1)).uppercased())
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.white)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        print("[ProfileAvatar] VC attached to parent: \(type(of: parentVC))")
      } else {
        print("[ProfileAvatar] VC attach FAILED — no parent VC found in responder chain")
      }
    } else if window == nil, isHostingControllerAttached {
      hostingController.willMove(toParent: nil)
      hostingController.removeFromParent()
      isHostingControllerAttached = false
      print("[ProfileAvatar] VC detached (window=nil)")
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

  override func layoutSubviews() {
    super.layoutSubviews()
    print("[ProfileAvatar] layoutSubviews frame=\(frame) clipsToBounds=\(clipsToBounds) superview.clipsToBounds=\(superview?.clipsToBounds ?? false)")
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
    print("[ProfileAvatar] setCollapsed: \(resolved)")
    model.collapsed = resolved
  }

  func setExpandedSize(_ value: CGFloat?) {
    let resolved = max(1.0, value ?? 100.0)
    guard model.expandedSize != resolved else { return }
    print("[ProfileAvatar] setExpandedSize: \(resolved)")
    model.expandedSize = resolved
  }

  func setCollapsedSize(_ value: CGFloat?) {
    let resolved = max(1.0, value ?? 40.0)
    guard model.collapsedSize != resolved else { return }
    print("[ProfileAvatar] setCollapsedSize: \(resolved)")
    model.collapsedSize = resolved
  }

  func setExpandedTopInset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard model.expandedTopInset != resolved else { return }
    print("[ProfileAvatar] setExpandedTopInset: \(resolved)")
    model.expandedTopInset = resolved
  }

  func setCollapsedTopInset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard model.collapsedTopInset != resolved else { return }
    print("[ProfileAvatar] setCollapsedTopInset: \(resolved)")
    model.collapsedTopInset = resolved
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
    }
  }
}
