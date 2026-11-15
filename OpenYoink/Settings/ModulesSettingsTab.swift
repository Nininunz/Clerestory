import SwiftUI

struct ModulesSettingsTab: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsForm {
            if settings.islandEnabled {
                Section("Island Modules") {
                    islandModuleControl("Shelf", id: .shelf)
                    Text("Turning off the Shelf module never deletes its items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    islandModuleControl("Transfers", id: .transfers)
                    islandModuleControl("Timer", id: .timer)
                    islandModuleControl("Battery", id: .battery)
                    if settings.isIslandModuleEnabled(.battery) {
                        Toggle("Notify when fully charged",
                               isOn: $settings.islandFullChargeAlertEnabled)
                    }

                    islandModuleControl("System Status", id: .system)
                    Text("System status is read-only and never terminates apps, cleans disks, controls fans, or reads private sensors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    islandModuleControl("Now Playing", id: .media)
                    Text("Shows artwork and controls from the active media player. Processing stays on this Mac; compatibility can vary after macOS updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    islandModuleControl("Quick Access", id: .folders)
                    islandModuleControl("Clipboard History", id: .clipboard)

                    islandModuleControl("AI Usage", id: .aiUsage)
                    if settings.isIslandModuleEnabled(.aiUsage) {
                        Picker("Show in compact Island", selection: $settings.aiUsageCompactMetric) {
                            Text("Nothing").tag(AIUsageCompactMetric.off)
                            Text("Today's spend").tag(AIUsageCompactMetric.todayCost)
                            Text("Today's tokens").tag(AIUsageCompactMetric.todayTokens)
                            Text("Highest limit usage").tag(AIUsageCompactMetric.tightestLimit)
                        }
                        .pickerStyle(.menu)
                        Toggle("Notify at 80% and 95% of a usage limit",
                               isOn: $settings.aiUsageLimitAlertsEnabled)
                    }
                    HStack(spacing: 4) {
                        Text("Token usage, spend and plan limits come from TokenTracker, a free, open-source app. It needs to be running.")
                        Link("Get TokenTracker", destination: TokenTrackerClient.projectURL)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text("Open the Island module library to drag the five pinned positions into order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Island Modules") {
                    Text("Enable OpenYoink Island in General to configure modules.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func islandModuleControl(
        _ title: LocalizedStringKey,
        id: IslandModuleID
    ) -> some View {
        let enabled = settings.isIslandModuleEnabled(id)
        let pinned = settings.isIslandModulePinned(id)
        let pinnedCount = settings.islandModuleConfiguration.pinnedModuleIDs.count
        return HStack {
            Toggle(title, isOn: Binding(
                get: { settings.isIslandModuleEnabled(id) },
                set: { settings.setIslandModuleEnabled($0, id: id) }
            ))
            Spacer()
            Button {
                settings.setIslandModulePinned(!pinned, id: id)
            } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .disabled(!enabled || (!pinned && pinnedCount >= 5))
        }
    }
}
