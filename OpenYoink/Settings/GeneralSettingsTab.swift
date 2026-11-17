import AppKit
import Combine
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @Environment(UpdateController.self) private var updateController

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
                Text("The icon stays visible whenever the panel cannot be opened directly, so Settings remains accessible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $settings.autoUpdateCheckEnabled)
                Text("Update checks contact the configured update feed and release server.")
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
    }
}
