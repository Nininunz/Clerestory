import AppKit
import Combine
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @Environment(UpdateController.self) private var updateController
    @State private var islandScreens: [IslandScreenCatalog.Option] = []

    var body: some View {
        @Bindable var settings = settings
        SettingsForm {
            Section("Startup") {
                Toggle("Launch OpenYoink at login", isOn: Binding(
                    get: { launchAtLoginController.isRequested },
                    set: { launchAtLoginController.setRequested($0) }
                ))
                .disabled(!launchAtLoginController.isAvailable)

                if launchAtLoginController.requiresApproval {
                    HStack {
                        Label("Approval is required in System Settings.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") {
                            launchAtLoginController.openSystemSettings()
                        }
                    }
                } else if let error = launchAtLoginController.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !launchAtLoginController.isAvailable {
                    Text("Login item registration is unavailable for this copy of the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Menu Bar") {
                Toggle("Show OpenYoink in menu bar", isOn: $settings.menuBarIconEnabled)
                Text("The icon stays visible whenever Island cannot be opened directly, so Settings remains accessible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenYoink Island") {
                Toggle("Enable OpenYoink Island", isOn: $settings.islandEnabled)

                if settings.islandEnabled {
                    Text("Island uses the built-in camera housing on a notched display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if islandScreens.isEmpty {
                        Text("Connect a notched display to show Island.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Display", selection: $settings.islandDisplayTarget) {
                            Text("Main Display")
                                .tag(SettingsStore.IslandDisplayTarget.main)
                            Text("Follow Pointer")
                                .tag(SettingsStore.IslandDisplayTarget.automatic)
                            ForEach(islandScreens) { screen in
                                Text(islandScreenTitle(screen))
                                    .tag(SettingsStore.IslandDisplayTarget.display(screen.id))
                            }
                            if case let .display(id) = settings.islandDisplayTarget,
                               !islandScreens.contains(where: { $0.id == id }) {
                                Text("Unavailable Display")
                                    .tag(SettingsStore.IslandDisplayTarget.display(id))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("settings.islandDisplay")

                        Text(islandDisplayDescription)
                            .font(.caption)
                            .foregroundStyle(isSelectedIslandDisplayUnavailable
                                             ? Color.orange : Color.secondary)

                        Text("Configure Island reveal behavior in Triggers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Language") {
                Picker("Language", selection: $settings.language) {
                    Text("System").tag(SettingsStore.LanguagePreference.system)
                    Text("English").tag(SettingsStore.LanguagePreference.english)
                    Text("中文").tag(SettingsStore.LanguagePreference.chinese)
                }
                .accessibilityIdentifier("settings.language")
                // S10: AppleLanguages 覆盖在启动最早期应用（AppDelegate.
                // applicationWillFinishLaunching），运行期切换故需重启生效。
                Text("Takes effect after relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Sparkle: 自动检查更新（应用唯一的联网行为；手动检查在菜单栏菜单）。
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $settings.autoUpdateCheckEnabled)
                Text("Update checks contact GitHub Pages and releases only; nothing else uses the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case .error(let message) = updateController.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Download Latest Release…") {
                        updateController.openManualDownloadPage()
                    }
                }
            }
        }
        .onAppear { launchAtLoginController.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginController.refresh()
        }
        .onAppear {
            refreshIslandScreens()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            refreshIslandScreens()
        }
    }

    private func refreshIslandScreens() {
        islandScreens = IslandScreenCatalog.options()
    }

    private func islandScreenTitle(_ screen: IslandScreenCatalog.Option) -> String {
        guard screen.isMain else { return screen.name }
        return "\(screen.name) · \(String(localized: "Current Main"))"
    }

    private var isSelectedIslandDisplayUnavailable: Bool {
        guard case let .display(id) = settings.islandDisplayTarget else {
            return false
        }
        return !islandScreens.contains(where: { $0.id == id })
    }

    private var islandDisplayDescription: String {
        switch settings.islandDisplayTarget {
        case .main:
            if islandScreens.contains(where: \.isMain) {
                String(localized: "Island stays on the display chosen as main in System Settings.")
            } else {
                String(localized: "The main display has no notch. Island uses a connected notched display.")
            }
        case .automatic:
            String(localized: "Island follows the pointer across notched displays.")
        case .display where isSelectedIslandDisplayUnavailable:
            String(localized: "This display is unavailable or has no notch. Island uses a connected notched display.")
        case .display:
            String(localized: "Island stays on this display until you choose another.")
        }
    }
}
