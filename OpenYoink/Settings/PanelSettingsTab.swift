import SwiftUI

struct PanelSettingsTab: View {
    var body: some View {
        SettingsForm {
            PanelDisplaySettingsSection()
            PanelTriggerSettingsSections()
            Section("Shortcut Positions") {
                Text("Choose which enabled modules appear in the panel's navigation. These positions are shared with Quick Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                ExpandedShortcutEditor(style: .settings)
            }
            IgnoredAppsSettingsSection()
        }
    }
}
