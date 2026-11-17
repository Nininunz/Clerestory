#if DEBUG
import SwiftUI

struct DebugSettingsTab: View {
    @State private var simulateNoNotch = IslandDebugMode.simulatesNoNotch

    var body: some View {
        SettingsForm {
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
#endif
