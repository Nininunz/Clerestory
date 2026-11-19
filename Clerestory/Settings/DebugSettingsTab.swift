#if DEBUG
import SwiftUI

struct DebugSettingsTab: View {
    @State private var simulateNoNotch = IslandDebugMode.simulatesNoNotch

    var body: some View {
        SettingsForm {
            Section("Test Messages") {
                Text("Posts sample messages so the notice pill, the notch and VoiceOver can be checked by hand. They come from Shelf, which is always running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Notice") { DebugTestMessages.postNotice() }
                    Button("Notice with a Button") { DebugTestMessages.postNoticeWithButton() }
                    Button("Error") { DebugTestMessages.postError() }
                }
                HStack {
                    Button("Warning Status") { DebugTestMessages.raiseStatus(.warning) }
                    Button("Critical Status") { DebugTestMessages.raiseStatus(.critical) }
                    Button("Clear Statuses") { DebugTestMessages.clearStatuses() }
                }
            }

            Section("Display Simulation") {
                Toggle("Simulate a display without a notch", isOn: Binding(
                    get: { simulateNoNotch },
                    set: { enabled in
                        simulateNoNotch = enabled
                        IslandDebugMode.setSimulatesNoNotch(enabled)
                    }
                ))
                .accessibilityIdentifier("settings.debug.simulateNoNotch")

                Text("Uses the same panel while hiding the notch display. Your opening controls in Panel still apply. Turn this off to use the real display geometry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            simulateNoNotch = IslandDebugMode.simulatesNoNotch
        }
    }
}

/// Sample messages for the Debug tab. The app delegate hands over its message center at launch.
@MainActor
enum DebugTestMessages {
    static weak var center: IslandMessageCenter?

    private static let statusKeys = ["debug-warning", "debug-critical"]
    private static var messenger: ModuleMessenger? { center?.messenger(for: .shelf) }

    static func postNotice() {
        messenger?.post(IslandNotice(key: "debug-notice", title: "Test notice"))
    }

    /// Open Recovery opens Settings → Storage, which is harmless with nothing to recover.
    static func postNoticeWithButton() {
        messenger?.post(IslandNotice(key: "debug-button", title: "Test notice with a button",
                                     tone: .warning, action: .openStorageRecovery))
    }

    static func postError() {
        messenger?.post(IslandNotice(key: "debug-error", title: "Test error",
                                     detail: "Test error with a longer description for VoiceOver.",
                                     tone: .error))
    }

    /// Raised once per key. Clear the statuses to raise them again.
    static func raiseStatus(_ tone: IslandStatus.Tone) {
        let critical = tone == .critical
        messenger?.setStatus(IslandStatus(
            key: critical ? "debug-critical" : "debug-warning",
            title: critical ? "Test critical status" : "Test warning status",
            detail: "Debug",
            systemImage: "ladybug.fill",
            tone: tone
        ))
    }

    static func clearStatuses() {
        for key in statusKeys { messenger?.clearStatus(key) }
    }
}
#endif
