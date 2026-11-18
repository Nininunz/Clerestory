import AppKit
import SwiftUI

struct NotchSettingsTab: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsForm {
            Section("Notch") {
                Toggle("Show in notch", isOn: $settings.showNotch)
                    .accessibilityIdentifier("settings.showCompactIsland")
                Text("Appears only on notched displays. Your preference is saved for when a notched display is in use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cycling Shortcut") {
                LabeledContent("Cycle notch modules") {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(shortcut: $settings.notchCycleShortcut)
                        Button("Restore Default") { settings.notchCycleShortcut = .notchCycle }
                            .disabled(settings.notchCycleShortcut == .notchCycle)
                    }
                }
                Text("Hold Shift with the shortcut to cycle backward (release Shift if it is already part of your shortcut). Your choice is remembered independently of the panel module. Clear the shortcut to disable both directions.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = settings.notchCycleShortcutError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Modules and Order") {
                Text("Inclusion here controls cycling, not whether a module is enabled. Enable modules in Modules. These choices are shared with Quick Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                NotchModuleOrderEditor(style: .settings)
            }
        }
    }
}
