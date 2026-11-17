#if DEBUG
import SwiftUI

struct DebugSettingsTab: View {
    @State private var simulateNoNotch = IslandDebugMode.simulatesNoNotch

    var body: some View {
        SettingsForm {
            Section("Island Preview") {
                Toggle("Simulate a display without a notch", isOn: Binding(
                    get: { simulateNoNotch },
                    set: { enabled in
                        simulateNoNotch = enabled
                        IslandDebugMode.setSimulatesNoNotch(enabled)
                    }
                ))
                .accessibilityIdentifier("settings.debug.simulateNoNotch")

                Text("Hover at the top center to open the full Island. Turn this off to return to the physical notch.")
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
