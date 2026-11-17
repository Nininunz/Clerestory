import SwiftUI

struct PanelDisplaySettingsSection: View {
    var body: some View {
        Section("Displays") {
            Text("The panel opens on the display where you trigger it and stays there until dismissed.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.panelDisplayBehavior")
            Text("The optional notch display stays on the built-in screen. Configure it in Notch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
