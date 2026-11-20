import AppKit
import SwiftUI

/// Battery settings for the optional Low Power Mode helper: its status and how to install it.
struct LowPowerModeHelperSection: View {
    private enum Status { case checking, available, unavailable }

    @Environment(SettingsStore.self) private var settings
    @State private var status = Status.checking

    var body: some View {
        @Bindable var settings = settings
        Section("Low Power Mode") {
            Toggle("Open System Settings instead of using the helper", isOn: $settings.lowPowerModeOpensSystemSettings)
                .accessibilityIdentifier("settings.battery.lowPowerModeOpensSystemSettings")
            Text("When this is on, the leaf button in Battery opens Battery in System Settings, where macOS has its own Low Power Mode control. No helper is needed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Low Power Mode Helper") {
            LabeledContent("Helper") {
                switch status {
                case .checking: Text("Checking…")
                case .available: Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .unavailable: Text("Not installed")
                }
            }
            .accessibilityIdentifier("settings.battery.helperStatus")
            if status == .unavailable {
                Text("The leaf button in Battery uses a small helper to switch Low Power Mode without asking for a password. Download and open the installer, then allow Clerestory in System Settings under Login Items & Extensions.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Download Helper…", destination: LowPowerModeHelper.downloadURL)
                    Button("Open Login Items…") { NSWorkspace.shared.open(LowPowerModeHelper.loginItemsSettingsURL) }
                    Spacer()
                    Button("Check Again") { Task { await refresh() } }
                }
            } else if status == .available {
                Text("Use the leaf button in Battery to switch Low Power Mode for the active power source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await refresh() }
        // Check again when returning from the installer or System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        status = await LowPowerModeHelper.isAvailable() ? .available : .unavailable
    }
}
