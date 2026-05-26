import CoreImage
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import SwiftUI
import UIKit

private enum SettingsRoute: String, Identifiable {
  case profile
  case qr
  case privacy
  case secretKey
  case appearance
  case mediaCache

  var id: String { rawValue }
}

private enum SettingsModal: String, Identifiable {
  case connectionManager

  var id: String { rawValue }
}

struct SettingsView: View {
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @StateObject private var profileController = AppProfileController.shared

  @AppStorage("vibe.settings.notificationsEnabled") private var notificationsEnabled = true
  @AppStorage(AppThemePlateController.storageKey) private var themePlateRaw =
    AppThemePlateOption.glacier.rawValue

  @State private var activeRoute: SettingsRoute?
  @State private var activeModal: SettingsModal?

  private var palette: AppThemePalette {
    _ = themePlateRaw
    return AppThemePalette.resolve(for: colorScheme)
  }

  private var isDark: Bool {
    colorScheme == .dark
  }

  private var currentProfile: AppUserProfile {
    profileController.profile
      ?? AppUserProfile(
        userID: AppSessionConfig.current?.userID ?? "",
        username: AppSessionConfig.current?.username ?? AppSessionConfig.current?.userID ?? "you",
        name: AppSessionConfig.current?.name,
        phoneNumber: AppSessionConfig.current?.phoneNumber,
        bio: AppSessionConfig.current?.bio,
        dateOfBirth: AppSessionConfig.current?.dateOfBirth,
        profileImage: AppSessionConfig.current?.profileImage,
        showLastSeen: AppSessionConfig.current?.showLastSeen ?? true,
        showOnlineStatus: AppSessionConfig.current?.showOnlineStatus ?? true,
        autoDeleteTimer: AppSessionConfig.current?.autoDeleteTimer,
        privacyLastSeen: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyLastSeen ?? "")
          ?? .everybody,
        privacyForward: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyForward ?? "")
          ?? .everybody,
        privacyCalls: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyCalls ?? "")
          ?? .everybody,
        privacyPhoneNumber: AppPrivacyChoice(
          rawValue: AppSessionConfig.current?.privacyPhoneNumber ?? ""
        ) ?? .everybody,
        privacyProfilePhotos: AppPrivacyChoice(
          rawValue: AppSessionConfig.current?.privacyProfilePhotos ?? ""
        ) ?? .everybody,
        privacyBio: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyBio ?? "")
          ?? .everybody,
        privacyGifts: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyGifts ?? "")
          ?? .everybody,
        privacyBirthday: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyBirthday ?? "")
          ?? .everybody,
        privacySavedMusic: AppPrivacyChoice(
          rawValue: AppSessionConfig.current?.privacySavedMusic ?? ""
        ) ?? .everybody
      )
      ?? AppUserProfile(
        userID: "local-user",
        username: "you"
      )!
  }

  private var headerSubtitle: String {
    let parts = [
      currentProfile.phoneNumber?.nilIfBlank,
      "@\(currentProfile.username)",
    ].compactMap { $0 }
    return parts.joined(separator: " • ")
  }

  private var sections: [SettingsNativeSection] {
    [
      SettingsNativeSection(
        title: "ACCOUNT",
        rows: [
          SettingsNativeRow(
            id: "edit-profile",
            icon: "person.fill",
            label: "Edit Profile",
            detailText: nil,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemBlue,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "saved-messages",
            icon: "bookmark.fill",
            label: "Saved Messages",
            detailText: nil,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemOrange,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "your-qr",
            icon: "qrcode",
            label: "Your QR",
            detailText: "Show",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemGreen,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "connection-manager",
            icon: "server.rack",
            label: "Connection Manager",
            detailText: connectionModeTitle,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemBlue,
            divider: false,
            destructive: false
          ),
        ]
      ),
      SettingsNativeSection(
        title: "PRIVACY & SECURITY",
        rows: [
          SettingsNativeRow(
            id: "privacy",
            icon: "shield.fill",
            label: "Privacy",
            detailText: "Manage",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemGreen,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "secret-key",
            icon: "key.fill",
            label: "Secret Key",
            detailText: nil,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemPurple,
            divider: false,
            destructive: false
          ),
        ]
      ),
      SettingsNativeSection(
        title: "NOTIFICATIONS",
        rows: [
          SettingsNativeRow(
            id: "push-notifications",
            icon: "bell.fill",
            label: "Push Notifications",
            detailText: nil,
            toggleValue: notificationsEnabled,
            kind: .toggle,
            iconColor: UIColor.systemRed,
            divider: false,
            destructive: false
          )
        ]
      ),
      SettingsNativeSection(
        title: "APPEARANCE",
        rows: [
          SettingsNativeRow(
            id: "appearance",
            icon: "moon.fill",
            label: "Appearance",
            detailText: appearanceSummary,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemIndigo,
            divider: false,
            destructive: false
          )
        ]
      ),
      SettingsNativeSection(
        title: "MEDIA & STORAGE",
        rows: [
          SettingsNativeRow(
            id: "media-cache",
            icon: "internaldrive.fill",
            label: "Media Cache",
            detailText: "Manage",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemPink,
            divider: false,
            destructive: false
          )
        ]
      ),
    ]
  }

  var body: some View {
    SettingsNativeMainViewRepresentable(
      displayName: currentProfile.displayName,
      subtitle: headerSubtitle,
      avatarImageURI: currentProfile.profileImage,
      avatarFallbackText: currentProfile.displayName,
      footerText: "Vibe Mobile",
      sections: sections,
      palette: palette,
      isDark: isDark,
      onRowPress: handleRowPress,
      onRowToggle: handleRowToggle,
      onSignOut: {
        AppRootControllerFactory.signOut()
      }
    )
    .ignoresSafeArea(.container, edges: [.top, .bottom])
    .background(palette.background.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          AppUITrace.notice("SettingsView toolbar qr")
          AppUIStallWatchdog.shared.updateContext("SettingsView toolbar qr")
          activeRoute = .qr
        } label: {
          Image(systemName: "qrcode")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(palette.text)
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Edit") {
          AppUITrace.notice("SettingsView toolbar edit")
          AppUIStallWatchdog.shared.updateContext("SettingsView toolbar edit")
          activeRoute = .profile
        }
        .font(.system(size: 17))
        .foregroundStyle(palette.accent)
      }
    }
    .onAppear {
      AppUITrace.notice(
        "SettingsView onAppear hasProfile=\(profileController.profile != nil) hasImage=\(currentProfile.profileImage != nil)"
      )
      AppUIStallWatchdog.shared.updateContext("SettingsView appear")
    }
    .task {
      AppUITrace.notice("SettingsView task profile load start")
      AppUIStallWatchdog.shared.updateContext("SettingsView profile load")
      await profileController.loadIfNeeded()
      AppUITrace.notice(
        "SettingsView task profile load done hasProfile=\(profileController.profile != nil)"
      )
    }
    .sheet(item: $activeModal) { modal in
      switch modal {
      case .connectionManager:
        NavigationStack {
          ConnectionManagerSheetView(onDismiss: {
            activeModal = nil
          })
        }
      }
    }
    .navigationDestination(item: $activeRoute) { route in
      switch route {
      case .profile:
        ProfileSettingsDetailView(profileController: profileController)
      case .qr:
        UserQRSettingsDetailView(profile: currentProfile)
      case .privacy:
        PrivacySettingsDetailView(profileController: profileController)
      case .secretKey:
        SecretKeySettingsDetailView()
      case .appearance:
        AppearanceSettingsDetailView()
      case .mediaCache:
        MediaCacheSettingsDetailView()
      }
    }
  }

  private var appearanceSummary: String {
    let appearance = AppAppearanceController.currentOption.title
    let plate = AppThemePlateController.currentOption.title
    return "\(appearance) • \(plate)"
  }

  private var connectionModeTitle: String {
    switch AppSessionConfig.current?.transportMode ?? .packetMesh {
    case .packetMesh:
      return "Automatic"
    case .direct:
      return "Direct"
    case .offline:
      return "Offline"
    case .bridgeText:
      return "Bridge Text"
    }
  }

  private func handleRowPress(_ rowID: String) {
    AppUITrace.notice("SettingsView rowPress id=\(rowID)")
    AppUIStallWatchdog.shared.updateContext("SettingsView rowPress id=\(rowID)")
    switch rowID {
    case "edit-profile":
      activeRoute = .profile
    case "saved-messages":
      openSavedMessages()
    case "your-qr":
      activeRoute = .qr
    case "connection-manager":
      activeModal = .connectionManager
    case "privacy":
      activeRoute = .privacy
    case "secret-key":
      activeRoute = .secretKey
    case "appearance":
      activeRoute = .appearance
    case "media-cache":
      activeRoute = .mediaCache
    default:
      break
    }
  }

  private func handleRowToggle(_ rowID: String, _ value: Bool) {
    switch rowID {
    case "push-notifications":
      notificationsEnabled = value
    default:
      break
    }
  }

  private func openSavedMessages() {
    let cachedRows = ChatEngine.shared.getChatRows(["chatId": "saved_messages"])
    NSLog(
      "[AppShellRoute] SettingsView openSavedMessages cachedRows=%d currentTab=%@",
      cachedRows.count,
      String(describing: coordinator.selectedTab)
    )
    coordinator.openChat(
      .savedMessages(initialRows: cachedRows)
    )
  }
}

private enum PrivacyRoute: Hashable, Identifiable {
  case blockedUsers
  case autoDelete
  case phoneNumber
  case lastSeen
  case profilePhotos
  case bio
  case gifts
  case birthday
  case savedMusic
  case forwardedMessages
  case calls

  var id: String {
    switch self {
    case .blockedUsers:
      return "blockedUsers"
    case .autoDelete:
      return "autoDelete"
    case .phoneNumber:
      return "phoneNumber"
    case .lastSeen:
      return "lastSeen"
    case .profilePhotos:
      return "profilePhotos"
    case .bio:
      return "bio"
    case .gifts:
      return "gifts"
    case .birthday:
      return "birthday"
    case .savedMusic:
      return "savedMusic"
    case .forwardedMessages:
      return "forwardedMessages"
    case .calls:
      return "calls"
    }
  }
}

private struct PrivacySettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var profileController: AppProfileController

  @AppStorage("vibe.settings.biometricsEnabled") private var biometricsEnabled = false
  @AppStorage(AppThemePlateController.storageKey) private var themePlateRaw =
    AppThemePlateOption.glacier.rawValue

  @State private var blockedUsers: [AppBlockedUser] = []
  @State private var route: PrivacyRoute?
  @State private var alertMessage: String?
  @State private var isRunningBiometricsToggle = false

  private var palette: AppThemePalette {
    _ = themePlateRaw
    return AppThemePalette.resolve(for: colorScheme)
  }

  private var isDark: Bool {
    colorScheme == .dark
  }

  private var profile: AppUserProfile {
    profileController.profile ?? AppUserProfile(
      userID: AppSessionConfig.current?.userID ?? "",
      username: AppSessionConfig.current?.username ?? "you"
    )!
  }

  private var sections: [SettingsNativeSection] {
    [
      SettingsNativeSection(
        title: nil,
        rows: [
          SettingsNativeRow(
            id: "blocked-users",
            icon: "nosign",
            label: "Blocked Users",
            detailText: blockedUsers.isEmpty ? nil : "\(blockedUsers.count)",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemRed,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "passcode-face-id",
            icon: "faceid",
            label: "Passcode & Face ID",
            detailText: biometricsEnabled ? "On" : "Off",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemGreen,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "two-step-verification",
            icon: "lock.fill",
            label: "Two-Step Verification",
            detailText: "Off",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemOrange,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "passkeys",
            icon: "key.fill",
            label: "Passkeys",
            detailText: "Off",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemIndigo,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "auto-delete",
            icon: "clock.fill",
            label: "Auto-Delete Messages",
            detailText: AppAutoDeleteOption.label(for: profile.autoDeleteTimer),
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemPurple,
            divider: false,
            destructive: false
          ),
        ]
      ),
      SettingsNativeSection(
        title: "PRIVACY",
        rows: [
          makeChoiceRow(id: "phone-number", label: "Phone Number", value: profile.privacyPhoneNumber),
          makeChoiceRow(id: "last-seen", label: "Last Seen & Online", value: profile.privacyLastSeen),
          makeChoiceRow(
            id: "profile-photos",
            label: "Profile Photos",
            value: profile.privacyProfilePhotos
          ),
          makeChoiceRow(id: "bio", label: "Bio", value: profile.privacyBio),
          makeChoiceRow(id: "gifts", label: "Gifts", value: profile.privacyGifts),
          makeChoiceRow(id: "birthday", label: "Birthday", value: profile.privacyBirthday),
          makeChoiceRow(id: "saved-music", label: "Saved Music", value: profile.privacySavedMusic),
          makeChoiceRow(
            id: "forwarded-messages",
            label: "Forwarded Messages",
            value: profile.privacyForward
          ),
          SettingsNativeRow(
            id: "calls",
            icon: "phone.fill",
            label: "Calls",
            detailText: profile.privacyCalls.title,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemGreen,
            divider: false,
            destructive: false
          ),
        ]
      ),
    ]
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 22) {
        ForEach(sections) { section in
          SettingsNativeSectionCard(
            section: section,
            palette: palette,
            isDark: isDark,
            onPress: handleRowPress,
            onToggle: { _, _ in }
          )
        }

        Text(
          "Automatically delete messages for everyone after a period of time in all new chats you start."
        )
        .font(.system(size: 13))
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Privacy")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await loadBlockedUsers()
    }
    .alert("Privacy", isPresented: Binding(get: {
      alertMessage != nil
    }, set: { if !$0 { alertMessage = nil } })) {
      Button("OK", role: .cancel) {
        alertMessage = nil
      }
    } message: {
      Text(alertMessage ?? "")
    }
    .navigationDestination(item: $route) { nextRoute in
      switch nextRoute {
      case .blockedUsers:
        BlockedUsersDetailView(users: blockedUsers)
      case .autoDelete:
        AutoDeleteSettingsDetailView(currentValue: profile.autoDeleteTimer) { value in
          try await profileController.updateFields(["autoDeleteTimer": value as Any])
        }
      case .phoneNumber:
        PrivacyChoiceDetailView(
          title: "Phone Number",
          currentChoice: profile.privacyPhoneNumber
        ) { choice in
          try await profileController.updateFields(["privacyPhoneNumber": choice.rawValue])
        }
      case .lastSeen:
        PrivacyChoiceDetailView(
          title: "Last Seen & Online",
          currentChoice: profile.privacyLastSeen
        ) { choice in
          try await profileController.updateFields([
            "privacyLastSeen": choice.rawValue,
            "showLastSeen": choice != .nobody,
            "showOnlineStatus": choice != .nobody,
          ])
        }
      case .profilePhotos:
        PrivacyChoiceDetailView(
          title: "Profile Photos",
          currentChoice: profile.privacyProfilePhotos
        ) { choice in
          try await profileController.updateFields(["privacyProfilePhotos": choice.rawValue])
        }
      case .bio:
        PrivacyChoiceDetailView(title: "Bio", currentChoice: profile.privacyBio) { choice in
          try await profileController.updateFields(["privacyBio": choice.rawValue])
        }
      case .gifts:
        PrivacyChoiceDetailView(title: "Gifts", currentChoice: profile.privacyGifts) { choice in
          try await profileController.updateFields(["privacyGifts": choice.rawValue])
        }
      case .birthday:
        PrivacyChoiceDetailView(title: "Birthday", currentChoice: profile.privacyBirthday) {
          choice in
          try await profileController.updateFields(["privacyBirthday": choice.rawValue])
        }
      case .savedMusic:
        PrivacyChoiceDetailView(
          title: "Saved Music",
          currentChoice: profile.privacySavedMusic
        ) { choice in
          try await profileController.updateFields(["privacySavedMusic": choice.rawValue])
        }
      case .forwardedMessages:
        PrivacyChoiceDetailView(
          title: "Forwarded Messages",
          currentChoice: profile.privacyForward
        ) { choice in
          try await profileController.updateFields(["privacyForward": choice.rawValue])
        }
      case .calls:
        PrivacyChoiceDetailView(title: "Calls", currentChoice: profile.privacyCalls) { choice in
          try await profileController.updateFields(["privacyCalls": choice.rawValue])
        }
      }
    }
  }

  private func makeChoiceRow(id: String, label: String, value: AppPrivacyChoice) -> SettingsNativeRow
  {
    SettingsNativeRow(
      id: id,
      icon: "person.crop.circle.fill",
      label: label,
      detailText: value.title,
      toggleValue: false,
      kind: .link,
      iconColor: UIColor.systemBlue,
      divider: true,
      destructive: false
    )
  }

  private func handleRowPress(_ rowID: String) {
    switch rowID {
    case "blocked-users":
      route = .blockedUsers
    case "passcode-face-id":
      Task {
        await toggleBiometrics()
      }
    case "two-step-verification", "passkeys":
      alertMessage = "This control is not wired into the standalone app yet."
    case "auto-delete":
      route = .autoDelete
    case "phone-number":
      route = .phoneNumber
    case "last-seen":
      route = .lastSeen
    case "profile-photos":
      route = .profilePhotos
    case "bio":
      route = .bio
    case "gifts":
      route = .gifts
    case "birthday":
      route = .birthday
    case "saved-music":
      route = .savedMusic
    case "forwarded-messages":
      route = .forwardedMessages
    case "calls":
      route = .calls
    default:
      break
    }
  }

  @MainActor
  private func toggleBiometrics() async {
    guard !isRunningBiometricsToggle else { return }
    isRunningBiometricsToggle = true
    defer { isRunningBiometricsToggle = false }

    if biometricsEnabled {
      biometricsEnabled = false
      return
    }

    let context = LAContext()
    var authError: NSError?
    guard
      context.canEvaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        error: &authError
      )
    else {
      alertMessage = authError?.localizedDescription ?? "This device does not support biometrics."
      return
    }

    do {
      let result = try await context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: "Authenticate to enable Face ID / Touch ID"
      )
      biometricsEnabled = result
    } catch let evaluationError {
      alertMessage = evaluationError.localizedDescription
    }
  }

  @MainActor
  private func loadBlockedUsers() async {
    guard let config = AppSessionConfig.current else { return }
    do {
      blockedUsers = try await AppBlockedUsersService.fetch(config: config)
    } catch {
      blockedUsers = []
    }
  }
}

private struct PrivacyChoiceDetailView: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let currentChoice: AppPrivacyChoice
  let onSelect: (AppPrivacyChoice) async throws -> Void

  @State private var selectedChoice: AppPrivacyChoice
  @State private var saveError: String?
  @State private var isSaving = false

  init(
    title: String,
    currentChoice: AppPrivacyChoice,
    onSelect: @escaping (AppPrivacyChoice) async throws -> Void
  ) {
    self.title = title
    self.currentChoice = currentChoice
    self.onSelect = onSelect
    _selectedChoice = State(initialValue: currentChoice)
  }

  var body: some View {
    List {
      ForEach(AppPrivacyChoice.allCases) { choice in
        Button {
          Task {
            await save(choice)
          }
        } label: {
          HStack {
            Text(choice.title)
              .foregroundStyle(.primary)
            Spacer()
            if choice == selectedChoice {
              Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.tint)
            }
          }
        }
        .disabled(isSaving)
      }

      if let saveError {
        Section {
          Text(saveError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }

  @MainActor
  private func save(_ choice: AppPrivacyChoice) async {
    guard !isSaving else { return }
    isSaving = true
    saveError = nil
    do {
      try await onSelect(choice)
      selectedChoice = choice
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
    isSaving = false
  }
}

private enum AppAutoDeleteOption: CaseIterable, Identifiable {
  case off
  case oneHour
  case oneDay
  case oneWeek

  var id: String { title }

  var minutes: Int? {
    switch self {
    case .off:
      return nil
    case .oneHour:
      return 60
    case .oneDay:
      return 1_440
    case .oneWeek:
      return 10_080
    }
  }

  var title: String {
    switch self {
    case .off:
      return "Off"
    case .oneHour:
      return "1 Hour"
    case .oneDay:
      return "1 Day"
    case .oneWeek:
      return "1 Week"
    }
  }

  static func option(for value: Int?) -> AppAutoDeleteOption {
    switch value {
    case 60:
      return .oneHour
    case 1_440:
      return .oneDay
    case 10_080:
      return .oneWeek
    default:
      return .off
    }
  }

  static func label(for value: Int?) -> String {
    option(for: value).title
  }
}

private struct AutoDeleteSettingsDetailView: View {
  @Environment(\.dismiss) private var dismiss
  let currentValue: Int?
  let onSelect: (Int?) async throws -> Void

  @State private var selectedOption: AppAutoDeleteOption
  @State private var isSaving = false
  @State private var saveError: String?

  init(currentValue: Int?, onSelect: @escaping (Int?) async throws -> Void) {
    self.currentValue = currentValue
    self.onSelect = onSelect
    _selectedOption = State(initialValue: AppAutoDeleteOption.option(for: currentValue))
  }

  var body: some View {
    List {
      ForEach(AppAutoDeleteOption.allCases) { option in
        Button {
          Task {
            await save(option)
          }
        } label: {
          HStack {
            Text(option.title)
              .foregroundStyle(.primary)
            Spacer()
            if option == selectedOption {
              Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.tint)
            }
          }
        }
        .disabled(isSaving)
      }

      if let saveError {
        Section {
          Text(saveError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Auto-Delete")
    .navigationBarTitleDisplayMode(.inline)
  }

  @MainActor
  private func save(_ option: AppAutoDeleteOption) async {
    guard !isSaving else { return }
    isSaving = true
    saveError = nil
    do {
      try await onSelect(option.minutes)
      selectedOption = option
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
    isSaving = false
  }
}

private struct AppearanceSettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(AppAppearanceController.storageKey) private var appearanceRaw =
    AppAppearanceOption.system.rawValue
  @AppStorage(AppThemePlateController.storageKey) private var plateRaw =
    AppThemePlateOption.glacier.rawValue

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var selectedAppearance: Binding<AppAppearanceOption> {
    Binding(
      get: { AppAppearanceOption(rawValue: appearanceRaw) ?? .system },
      set: { nextValue in
        appearanceRaw = nextValue.rawValue
        AppAppearanceController.setOption(nextValue)
      }
    )
  }

  private var selectedPlate: Binding<AppThemePlateOption> {
    Binding(
      get: { AppThemePlateOption(rawValue: plateRaw) ?? .glacier },
      set: { nextValue in
        plateRaw = nextValue.rawValue
        AppThemePlateController.setOption(nextValue)
      }
    )
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 24) {
        VStack(alignment: .leading, spacing: 10) {
          Text("MODE")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.secondaryText.opacity(0.72))
            .padding(.horizontal, 16)

          VStack(spacing: 0) {
            ForEach(AppAppearanceOption.allCases) { option in
              Button {
                selectedAppearance.wrappedValue = option
              } label: {
                HStack {
                  Text(option.title)
                    .foregroundStyle(palette.text)
                  Spacer()
                  if option == selectedAppearance.wrappedValue {
                    Image(systemName: "checkmark")
                      .font(.system(size: 14, weight: .bold))
                      .foregroundStyle(palette.accent)
                  }
                }
                .padding(.horizontal, 18)
                .frame(height: 56)
              }
              .buttonStyle(.plain)

              if option != AppAppearanceOption.allCases.last {
                Divider()
                  .padding(.leading, 18)
              }
            }
          }
          .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
              .fill(palette.card)
          )
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("COLOR PLATE")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.secondaryText.opacity(0.72))
            .padding(.horizontal, 16)

          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(AppThemePlateOption.allCases) { option in
              Button {
                selectedPlate.wrappedValue = option
              } label: {
                ThemePlateCard(
                  option: option,
                  isSelected: option == selectedPlate.wrappedValue,
                  colorScheme: colorScheme
                )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 2)
        }

        Text("Theme mode and color plate apply across the native shell.")
          .font(.system(size: 13))
          .foregroundStyle(palette.secondaryText)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Appearance")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct ThemePlateCard: View {
  let option: AppThemePlateOption
  let isSelected: Bool
  let colorScheme: ColorScheme

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme, plate: option)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(
          LinearGradient(
            colors: [palette.background, palette.card],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(height: 118)
        .overlay(alignment: .topTrailing) {
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 18))
              .foregroundStyle(palette.accent)
              .padding(10)
          }
        }
        .overlay(alignment: .bottomLeading) {
          VStack(alignment: .leading, spacing: 6) {
            Capsule()
              .fill(palette.bubbleThem)
              .frame(width: 54, height: 8)
            Capsule()
              .fill(palette.bubbleMe)
              .frame(width: 72, height: 8)
          }
          .padding(14)
        }

      Text(option.title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(palette.text)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(palette.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(isSelected ? palette.accent : palette.border, lineWidth: isSelected ? 1.5 : 1)
    )
  }
}

private struct ProfileSettingsDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var profileController: AppProfileController

  @State private var draft = AppUserProfileDraft(profile: nil)
  @State private var saveError: String?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var baselineDraft: AppUserProfileDraft {
    AppUserProfileDraft(profile: profileController.profile)
  }

  private var isDirty: Bool {
    draft != baselineDraft
  }

  var body: some View {
    List {
      Section("Profile") {
        TextField("Name", text: $draft.name)
        TextField("Username", text: $draft.username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Phone Number", text: $draft.phoneNumber)
          .keyboardType(.phonePad)
      }
      .listRowBackground(palette.card)

      Section("About") {
        TextField("Bio", text: $draft.bio, axis: .vertical)
          .lineLimit(3...6)
        TextField("Date of Birth", text: $draft.dateOfBirth)
      }
      .listRowBackground(palette.card)

      if let saveError {
        Section {
          Text(saveError)
            .font(.footnote)
            .foregroundStyle(palette.danger)
        }
        .listRowBackground(palette.card)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Profile")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(profileController.isLoading ? "Saving..." : "Save") {
          Task {
            await saveProfile()
          }
        }
        .disabled(
          !isDirty
            || profileController.isLoading
            || draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
    .onAppear {
      draft = baselineDraft
    }
  }

  @MainActor
  private func saveProfile() async {
    saveError = nil
    do {
      try await profileController.update(draft)
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
  }
}

private struct UserQRSettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  let profile: AppUserProfile

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var qrCodeValue: String {
    "vibe:\(profile.userID)"
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(spacing: 32) {
          VStack(spacing: 24) {
            QRCodePanel(value: qrCodeValue, palette: palette)
              .scaleEffect(1.05)

            VStack(spacing: 8) {
              Text(profile.displayName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(palette.text)

              Text("@\(profile.username)")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            }
          }
          .padding(.top, 40)

          VStack(alignment: .leading, spacing: 16) {
             Text("YOUR UNIQUE ID")
               .font(.system(size: 11, weight: .bold))
               .tracking(1.2)
               .foregroundStyle(palette.secondaryText)
               .padding(.leading, 4)

             HStack {
               Text(profile.userID)
                 .font(.system(.body, design: .monospaced))
                 .foregroundStyle(palette.text)
                 .lineLimit(1)

               Spacer()

               Button {
                 UIPasteboard.general.string = profile.userID
                 AppToastController.shared.show("ID Copied")
               } label: {
                 Image(systemName: "doc.on.doc")
                   .font(.system(size: 14, weight: .medium))
                   .foregroundStyle(palette.accent)
               }
             }
             .padding(16)
             .background(palette.card)
             .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
          .padding(.horizontal, 24)
        }
      }
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Your QR")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct SecretKeySettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var isRevealed = false
  @State private var copied = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var secretKey: String {
    SecureKeyStore.shared.retrieveSecret(key: "loginSecret") ?? ""
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(spacing: 32) {
          QRCodePanel(value: secretKey, palette: palette)
            .padding(.top, 40)

          VStack(alignment: .leading, spacing: 16) {
            Text("YOUR SECRET KEY")
              .font(.system(size: 11, weight: .bold))
              .tracking(1.2)
              .foregroundStyle(palette.secondaryText)
              .padding(.leading, 4)

            ZStack {
              // The real key (single line, no wrap)
              Text(secretKey.isEmpty ? "No secret key stored" : secretKey)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)

              // The Metal Mask
              if !isRevealed && !secretKey.isEmpty {
                MetalKeyMaskView(isRevealed: isRevealed, palette: palette)
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                  .padding(4)
              }
            }
            .background(palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
          .padding(.horizontal, 24)

          HStack(spacing: 16) {
            Button {
              guard !secretKey.isEmpty else { return }
              withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isRevealed.toggle()
              }
              copied = false
            } label: {
              HStack {
                Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                Text(isRevealed ? "Hide Key" : "Reveal Key")
              }
              .font(.system(size: 16, weight: .semibold))
              .frame(maxWidth: .infinity)
              .frame(height: 54)
              .background(palette.card)
              .foregroundStyle(palette.text)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .stroke(palette.divider, lineWidth: 1)
              )
            }
            .disabled(secretKey.isEmpty)

            Button {
              guard !secretKey.isEmpty else { return }
              UIPasteboard.general.string = secretKey
              withAnimation { copied = true }
              AppToastController.shared.show("Key Copied")
              DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { copied = false }
              }
            } label: {
              HStack {
                Image(systemName: copied ? "checkmark" : "doc.on.doc.fill")
                Text(copied ? "Copied" : "Copy")
              }
              .font(.system(size: 16, weight: .semibold))
              .frame(maxWidth: .infinity)
              .frame(height: 54)
              .background(palette.accent)
              .foregroundStyle(.white)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(secretKey.isEmpty)
          }
          .padding(.horizontal, 24)

          Text("CRITICAL: Never share your secret key. This key provides full access to your identity and encrypted messages.")
            .font(.system(size: 13))
            .foregroundStyle(palette.danger.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.top, 8)
        }
      }
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Secret Key")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct MediaCacheSettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("vibe.settings.media.maxCacheSize") private var maxCacheSize = 100
  @AppStorage("vibe.settings.media.cacheExpiryDays") private var cacheExpiryDays = 7
  @AppStorage("vibe.settings.media.autoPlayNext") private var autoPlayNext = true
  @AppStorage("vibe.settings.media.streamQuality") private var streamQuality = "high"

  @State private var stats = AppMediaCacheController.cacheStats()

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      Section("Storage") {
        SettingsValueLine(title: "Cached tracks", value: "\(stats.trackCount)")
        SettingsValueLine(title: "Recent plays", value: "\(stats.recentlyPlayedCount)")
        SettingsValueLine(title: "Used storage", value: formattedBytes(stats.bytesUsed))
      }
      .listRowBackground(palette.card)

      Section("Playback") {
        Stepper(value: $maxCacheSize, in: 50...500, step: 25) {
          LabeledContent("Max cache size") {
            Text("\(maxCacheSize) GB")
              .foregroundStyle(.secondary)
          }
        }

        Stepper(value: $cacheExpiryDays, in: 1...60) {
          LabeledContent("Expiry window") {
            Text("\(cacheExpiryDays) days")
              .foregroundStyle(.secondary)
          }
        }

        Toggle("Auto-play next", isOn: $autoPlayNext)

        Picker("Stream quality", selection: $streamQuality) {
          Text("Low").tag("low")
          Text("Medium").tag("medium")
          Text("High").tag("high")
        }
      }
      .listRowBackground(palette.card)

      Section("Actions") {
        Button("Clear Expired") {
          AppMediaCacheController.clearExpired(olderThanDays: cacheExpiryDays)
          refreshStats()
        }

        Button("Clear All", role: .destructive) {
          AppMediaCacheController.clearAll()
          refreshStats()
        }
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Media Cache")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      refreshStats()
    }
  }

  private func refreshStats() {
    stats = AppMediaCacheController.cacheStats()
  }

  private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

private struct ConnectionManagerSheetView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  let onDismiss: () -> Void

  @State private var selectedMode = AppSessionConfig.current?.transportMode ?? .packetMesh

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private let modes: [PacketTransportMode] = [.packetMesh, .direct, .offline]

  var body: some View {
    List {
      Section {
        ForEach(modes, id: \.rawValue) { mode in
          Button {
            apply(mode)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(title(for: mode))
                  .foregroundStyle(.primary)
                Text(description(for: mode))
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if mode == selectedMode {
                Image(systemName: "checkmark")
                  .font(.system(size: 14, weight: .bold))
                  .foregroundStyle(palette.accent)
              }
            }
          }
        }
      }
      .listRowBackground(palette.card)

      Section {
        Text("Connection mode changes take effect the next time chats refresh or reconnect.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Connection Manager")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismiss()
          onDismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .bold))
        }
      }
    }
  }

  private func apply(_ mode: PacketTransportMode) {
    guard let current = AppSessionConfig.current else { return }

    let updated = AppSessionConfig(
      apiBaseURLString: current.apiBaseURLString,
      socketURLString: current.socketURLString,
      userID: current.userID,
      authToken: current.authToken,
      transportMode: mode,
      username: current.username,
      name: current.name,
      secureID: current.secureID,
      publicKeyPem: current.publicKeyPem,
      privateKeyPem: current.privateKeyPem,
      encryptedPrivateKey: current.encryptedPrivateKey,
      tokenExpiresAt: current.tokenExpiresAt,
      identityKey: current.identityKey,
      phoneNumber: current.phoneNumber,
      bio: current.bio,
      profileImage: current.profileImage,
      dateOfBirth: current.dateOfBirth,
      showLastSeen: current.showLastSeen,
      showOnlineStatus: current.showOnlineStatus,
      autoDeleteTimer: current.autoDeleteTimer,
      privacyLastSeen: current.privacyLastSeen,
      privacyForward: current.privacyForward,
      privacyCalls: current.privacyCalls,
      privacyPhoneNumber: current.privacyPhoneNumber,
      privacyProfilePhotos: current.privacyProfilePhotos,
      privacyBio: current.privacyBio,
      privacyGifts: current.privacyGifts,
      privacyBirthday: current.privacyBirthday,
      privacySavedMusic: current.privacySavedMusic
    )

    AppSessionConfig.store(updated)
    PacketRuntime.shared.stop(resetToDirect: mode == .direct)
    AppToastController.shared.show("Connection mode set to \(title(for: mode)).")
    selectedMode = mode
    dismiss()
    onDismiss()
  }

  private func title(for mode: PacketTransportMode) -> String {
    switch mode {
    case .packetMesh:
      return "Automatic"
    case .direct:
      return "Direct"
    case .offline:
      return "Offline"
    case .bridgeText:
      return "Bridge Text"
    }
  }

  private func description(for mode: PacketTransportMode) -> String {
    switch mode {
    case .packetMesh:
      return "Use packet mesh when available and fall back automatically."
    case .direct:
      return "Connect to the API directly without packet mesh."
    case .offline:
      return "Pause remote chat traffic until you switch back."
    case .bridgeText:
      return "Text bridge transport."
    }
  }
}

private struct BlockedUsersDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  let users: [AppBlockedUser]

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      if users.isEmpty {
        Section {
          ContentUnavailableView("No Blocked Users", systemImage: "nosign")
        }
        .listRowBackground(palette.card)
      } else {
        ForEach(users) { user in
          HStack(spacing: 12) {
            if let urlString = user.profileImage, let url = URL(string: urlString) {
              AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                  image
                    .resizable()
                    .scaledToFill()
                default:
                  fallbackAvatar(for: user)
                }
              }
              .frame(width: 42, height: 42)
              .clipShape(Circle())
            } else {
              fallbackAvatar(for: user)
            }

            VStack(alignment: .leading, spacing: 3) {
              Text(user.displayName)
              Text("@\(user.username)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 2)
        }
        .listRowBackground(palette.card)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Blocked Users")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func fallbackAvatar(for user: AppBlockedUser) -> some View {
    Circle()
      .fill(Color.secondary.opacity(0.16))
      .frame(width: 42, height: 42)
      .overlay(
        Text(String(user.displayName.prefix(1)).uppercased())
          .font(.system(size: 16, weight: .bold))
      )
  }
}

private struct SettingsValueLine: View {
  let title: String
  let value: String

  var body: some View {
    LabeledContent(title) {
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }
}

private struct QRCodePanel: View {
  let value: String
  let palette: AppThemePalette
  @State private var renderedImage: UIImage?
  @State private var renderedValue = ""

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .fill(Color.white)
        .frame(width: 240, height: 240)
        .shadow(color: Color.black.opacity(0.12), radius: 24, x: 0, y: 12)
        .overlay(
          RoundedRectangle(cornerRadius: 32, style: .continuous)
            .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )

      if value.isEmpty {
        Image(systemName: "qrcode")
          .font(.system(size: 72, weight: .light))
          .foregroundStyle(palette.secondaryText)
      } else if renderedValue == value, let image = renderedImage {
        Image(uiImage: image)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 190, height: 190)
      } else {
        ProgressView()
          .tint(.black.opacity(0.42))
      }
    }
    .task(id: value) {
      guard !value.isEmpty else {
        renderedValue = ""
        renderedImage = nil
        return
      }
      let nextImage = await Task.detached(priority: .userInitiated) {
        QRCodeRenderer.image(for: value)
      }.value
      guard !Task.isCancelled else { return }
      renderedValue = value
      renderedImage = nextImage
    }
  }
}

private enum QRCodeRenderer {
  static let context = CIContext()

  static func image(for value: String) -> UIImage? {
    guard !value.isEmpty else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage else { return nil }
    let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
      return nil
    }
    return UIImage(cgImage: cgImage)
  }
}

private struct AppMediaCacheStats {
  let trackCount: Int
  let recentlyPlayedCount: Int
  let bytesUsed: Int64
}

private enum AppMediaCacheController {
  private static let directoryNames = [
    "native-music-player-cache",
    "music_cache",
  ]

  static func cacheStats() -> AppMediaCacheStats {
    var trackCount = 0
    var bytesUsed: Int64 = 0

    for fileURL in cachedFileURLs() {
      trackCount += 1
      let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      bytesUsed += Int64(fileSize)
    }

    return AppMediaCacheStats(
      trackCount: trackCount,
      recentlyPlayedCount: 0,
      bytesUsed: bytesUsed
    )
  }

  static func clearExpired(olderThanDays days: Int) {
    let threshold = Date().addingTimeInterval(-Double(max(days, 1)) * 86_400.0)
    for fileURL in cachedFileURLs() {
      let contentDate =
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      if contentDate < threshold {
        try? FileManager.default.removeItem(at: fileURL)
      }
    }
  }

  static func clearAll() {
    for fileURL in cachedFileURLs() {
      try? FileManager.default.removeItem(at: fileURL)
    }
  }

  private static func cachedFileURLs() -> [URL] {
    let baseDirectory =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    return directoryNames.flatMap { directoryName in
      let directoryURL = baseDirectory.appendingPathComponent(directoryName, isDirectory: true)
      let fileURLs =
        (try? FileManager.default.contentsOfDirectory(
          at: directoryURL,
          includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
          options: [.skipsHiddenFiles]
        )) ?? []
      return fileURLs.filter { !$0.hasDirectoryPath }
    }
  }
}

private struct AppBlockedUser: Identifiable {
  let id: String
  let username: String
  let displayName: String
  let profileImage: String?

  init?(payload: [String: Any]) {
    guard let id = Self.normalizedString(payload["userId"] ?? payload["id"]),
      let username = Self.normalizedString(payload["username"])
    else {
      return nil
    }

    self.id = id
    self.username = username
    self.displayName =
      Self.normalizedString(payload["name"])
      ?? username
    self.profileImage = Self.normalizedString(payload["profileImage"] ?? payload["profile_image"])
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

private enum AppBlockedUsersService {
  static func fetch(config: AppSessionConfig) async throws -> [AppBlockedUser] {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/user/blocks/\(config.userID)") else {
      return []
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode)
    else {
      return []
    }

    guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return raw.compactMap(AppBlockedUser.init(payload:))
  }

  private static func apiURL(base: String, path: String) -> URL? {
    var normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    guard !normalized.isEmpty else { return nil }

    let pathBase = normalized.lowercased().hasSuffix("/api") ? normalized : "\(normalized)/api"
    return URL(string: pathBase + path)
  }
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
