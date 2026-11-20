import SwiftUI

enum ModuleSettingsDestination: String, CaseIterable, Identifiable {
    case shelf, transfers, timer, battery, system, media, clipboard, aiUsage

    var id: Self { self }

    var moduleID: IslandModuleID {
        switch self {
        case .shelf: .shelf
        case .transfers: .transfers
        case .timer: .timer
        case .battery: .battery
        case .system: .system
        case .media: .media
        case .clipboard: .clipboard
        case .aiUsage: .aiUsage
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .shelf: "Shelf"
        case .transfers: "Transfers"
        case .timer: "Timer"
        case .battery: "Battery"
        case .system: "System Status"
        case .media: "Now Playing"
        case .clipboard: "Clipboard History"
        case .aiUsage: "AI Usage"
        }
    }

    var symbol: String {
        switch self {
        case .shelf: "tray"
        case .transfers: "arrow.up.arrow.down"
        case .timer: "timer"
        case .battery: "battery.75percent"
        case .system: "speedometer"
        case .media: "music.note"
        case .clipboard: "doc.on.clipboard"
        case .aiUsage: "chart.line.uptrend.xyaxis"
        }
    }
}

struct ModulesSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SettingsNavigationModel.self) private var navigation
    @State private var pendingPreset: WorkflowPreset?

    var body: some View {
        Group {
            if let destination = navigation.moduleSettingsDestination,
               settings.isIslandModuleAvailable(destination.moduleID) {
                moduleDetail(destination)
            } else {
                moduleList
            }
        }
        .onChange(of: settings.experimentalModulesEnabled) {
            pendingPreset = nil
            if let destination = navigation.moduleSettingsDestination,
               !settings.isIslandModuleAvailable(destination.moduleID) {
                navigation.moduleSettingsDestination = nil
            }
        }
        .alert("Apply Workflow Preset?", isPresented: Binding(
            get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingPreset = nil }
            Button("Apply") {
                if let preset = pendingPreset { settings.applyWorkflowPreset(preset) }
                pendingPreset = nil
            }
        } message: {
            Text(pendingPreset?.detail(experimentalModulesEnabled: settings.experimentalModulesEnabled) ?? "")
        }
    }

    private var moduleList: some View {
        @Bindable var settings = settings
        let destinations = ModuleSettingsDestination.allCases.filter { settings.isIslandModuleAvailable($0.moduleID) }
        return SettingsForm {
            Section("Experimental") {
                Toggle("Experimental Modules", isOn: $settings.experimentalModulesEnabled)
                    .accessibilityIdentifier("settings.experimentalModules")
                Text("Enable modules beyond Shelf, Quick Settings and Battery. Turning this off keeps their saved settings and shortcut positions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Modules") {
                ForEach(destinations) { destination in
                    HStack(spacing: 12) {
                        Button {
                            navigation.moduleSettingsDestination = destination
                        } label: {
                            HStack {
                                Label(destination.title, systemImage: destination.symbol)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.module.\(destination.rawValue).open")
                        Toggle(destination.title, isOn: enabledBinding(destination))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings.module.\(destination.rawValue).enabled")
                    }
                    if destination != destinations.last { Divider() }
                }
                Text("Quick Settings is always available and must occupy one panel shortcut position.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Arrange Panel Shortcuts…") { navigation.open(.panel) }
                Button("Configure Notch…") { navigation.open(.notch) }
            }
            Section("Workflow Presets") {
                Menu("Apply a Preset…") {
                    ForEach(WorkflowPreset.availableCases(experimentalModulesEnabled: settings.experimentalModulesEnabled)) { preset in
                        Button(preset.title) { pendingPreset = preset }
                    }
                }
                if !settings.experimentalModulesEnabled {
                    Text("Enable Experimental Modules to use the clipboard and toolbox presets. Hidden module preferences are preserved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Presets change modules and opening behavior. Your files, history and recording choice are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func moduleDetail(_ destination: ModuleSettingsDestination) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    navigation.moduleSettingsDestination = nil
                } label: {
                    Label("Modules", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.module.back")
                Divider().frame(height: 18)
                Label(destination.title, systemImage: destination.symbol)
                    .font(.headline)
                Spacer()
            }
            .padding(20)
            Divider()
            SettingsForm {
                Section("Module") {
                    Toggle("Enable Module", isOn: enabledBinding(destination))
                    Toggle("Show in panel shortcuts", isOn: Binding(
                        get: { settings.islandModuleConfiguration.isPinned(destination.moduleID) },
                        set: { settings.setIslandModulePinned($0, id: destination.moduleID) }
                    ))
                    .disabled(!settings.islandModuleConfiguration.canTogglePin(for: destination.moduleID))
                    Text("\(settings.effectiveIslandShortcuts.pinnedModuleIDs.count + 1) of \(settings.effectiveIslandShortcuts.visibleShortcutIndices().count) shortcut positions used.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Shortcut placement and notch inclusion are separate from enabling a module. Arrange positions in Panel or Quick Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                specificSettings(destination)
            }
        }
    }

    private func enabledBinding(_ destination: ModuleSettingsDestination) -> Binding<Bool> {
        Binding(get: { settings.isIslandModuleEnabled(destination.moduleID) },
                set: { settings.setIslandModuleEnabled($0, id: destination.moduleID) })
    }

    @ViewBuilder
    private func specificSettings(_ destination: ModuleSettingsDestination) -> some View {
        @Bindable var settings = settings
        switch destination {
        case .shelf:
            ShelfSettingsSections()
            Text("Turning off the Shelf module never deletes its items.")
                .font(.caption).foregroundStyle(.secondary)
        case .clipboard:
            ClipboardSettingsSections()
        case .battery:
            Section("Battery") {
                Toggle("Notify when fully charged", isOn: $settings.islandFullChargeAlertEnabled)
            }
        case .aiUsage:
            Section("AI Usage") {
                Picker("Show in notch", selection: $settings.aiUsageNotchMetric) {
                    Text("Nothing").tag(AIUsageNotchMetric.off)
                    Text("Today's spend").tag(AIUsageNotchMetric.todayCost)
                    Text("Today's tokens").tag(AIUsageNotchMetric.todayTokens)
                    Text("Highest limit usage").tag(AIUsageNotchMetric.tightestLimit)
                }
                .pickerStyle(.menu)
                Toggle("Notify at 80% and 95% of a usage limit", isOn: $settings.aiUsageLimitAlertsEnabled)
                Text("Token usage, spend and plan limits come from TokenTracker, a free, open-source app. It needs to be running.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Get TokenTracker", destination: TokenTrackerClient.projectURL)
            }
        case .system:
            Section("System Status") {
                Text("System status is read-only and never terminates apps, cleans disks, controls fans, or reads private sensors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .media:
            Section("Now Playing") {
                Text("Shows artwork and controls from the active media player. Processing stays on this Mac; compatibility can vary after macOS updates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .timer:
            Section("Timer") {
                Text("Set durations and manage timers in the Timer module.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .transfers:
            Section("Transfers") {
                Text("Transfers appear automatically when you copy or move files. No additional settings are available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
