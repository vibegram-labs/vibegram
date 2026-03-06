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
      NativeProfileAvatarGlassMorphView(model: model)
    } else {
      NativeProfileAvatarLegacyView(model: model)
    }
  }
}

@available(iOS 26.0, *)
private struct NativeProfileAvatarGlassMorphView: View {
  @ObservedObject var model: NativeProfileAvatarModel
  @Namespace private var namespace
  @State private var showAvatar: Bool = true

  var body: some View {
    GlassEffectContainer(spacing: 40.0) {
      ZStack(alignment: .top) {
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        if showAvatar {
          NativeProfileAvatarImageView(
            image: model.loadedImage,
            fallbackText: model.fallbackText
          )
          .frame(width: model.expandedSize, height: model.expandedSize)
          .clipShape(Circle())
          .glassEffect()
          .glassEffectID("profile-avatar", in: namespace)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .padding(.top, model.expandedTopInset)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onChange(of: model.collapsed) { _, isCollapsed in
      withAnimation(.bouncy) {
        showAvatar = !isCollapsed
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
    model.fallbackText = nextValue
  }

  func setCollapsed(_ value: Bool?) {
    model.collapsed = value ?? false
  }

  func setExpandedSize(_ value: CGFloat?) {
    model.expandedSize = max(1.0, value ?? 100.0)
  }

  func setCollapsedSize(_ value: CGFloat?) {
    model.collapsedSize = max(1.0, value ?? 40.0)
  }

  func setExpandedTopInset(_ value: CGFloat?) {
    model.expandedTopInset = max(0.0, value ?? 0.0)
  }

  func setCollapsedTopInset(_ value: CGFloat?) {
    model.collapsedTopInset = max(0.0, value ?? 0.0)
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
