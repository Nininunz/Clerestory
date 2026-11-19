import SwiftUI

struct PanelTriggerSettingsSections: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HotKeyMonitor.self) private var hotKeyMonitor

    var body: some View {
        @Bindable var settings = settings
        Group {
            Section("Opening and Closing") {
                Toggle("Open panel on hover", isOn: $settings.islandHoverRevealEnabled)
                    .disabled(!settings.islandEnabled)
                Toggle("Open panel on click", isOn: $settings.islandClickRevealEnabled)
                    .disabled(!settings.islandEnabled)
                Text("Use the notch display when visible, or the top-center screen edge when it is hidden.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Open delay") {
                    Slider(value: $settings.islandHoverDelaySeconds, in: 0...0.5, step: 0.05)
                        .frame(width: 180)
                        .accessibilityIdentifier("settings.islandHoverDelay")
                    Text("\(Int((settings.islandHoverDelaySeconds * 1_000).rounded())) ms")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
                .disabled(!settings.islandEnabled
                          || !settings.islandHoverRevealEnabled)
                LabeledContent("Close delay") {
                    Slider(value: $settings.islandHoverLeaveDelaySeconds, in: 0...1, step: 0.05)
                        .frame(width: 180)
                        .accessibilityIdentifier("settings.islandHoverLeaveDelay")
                    Text("\(Int((settings.islandHoverLeaveDelaySeconds * 1_000).rounded())) ms")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
                .disabled(!settings.islandEnabled
                          || !settings.islandHoverRevealEnabled)
                Text("The panel closes after you move away. Pin it to keep it open.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open panel when dragging files or text near the top", isOn: $settings.islandDragApproachEnabled)
                    .disabled(!settings.islandEnabled)
                    .accessibilityIdentifier("settings.islandDragApproach")
                Text("File and text drags work independently of Open panel on hover.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Dropping files or text on the notch display always opens Shelf. The wider approach area is optional.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shelf Shortcut") {
                Toggle("Enable shelf shortcut", isOn: $settings.hotKeyEnabled)

                LabeledContent("Shortcut") {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(shortcut: $settings.hotKeyShortcut)
                        Button("Restore Default") {
                            settings.hotKeyShortcut = .default
                        }
                        .disabled(settings.hotKeyShortcut == .default)
                    }
                }

                // UX3: Double-click to save clipboard. When enabled, a delay is added on single-click with
                // a recognition window —— footnote
                // Explain this trade-off; disable to restore zero delay single-click.
                Toggle("Double-press saves clipboard", isOn: $settings.hotKeyDoublePressSavesClipboard)
                    .disabled(!settings.hotKeyEnabled)
                Text("When enabled, a single press toggles the shelf after a brief delay (0.3 s) so a double press can be recognized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = hotKeyMonitor.registrationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
