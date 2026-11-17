import AppKit
import SwiftUI

struct PanelDisplaySettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @State private var islandScreens: [IslandScreenCatalog.Option] = []

    var body: some View {
        @Bindable var settings = settings
        Group {
            Section("Panel") {
                Toggle("Enable panel", isOn: $settings.islandEnabled)

                if settings.islandEnabled {
                    Text("The same panel is used on every display. Choose where it opens below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if islandScreens.isEmpty {
                        Text("Connect a display to show the panel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Display", selection: $settings.islandDisplayTarget) {
                            Text("Main Display")
                                .tag(SettingsStore.IslandDisplayTarget.main)
                            Text("Follow Pointer")
                                .tag(SettingsStore.IslandDisplayTarget.automatic)
                            ForEach(islandScreens) { screen in
                                Text(islandScreenTitle(screen))
                                    .tag(SettingsStore.IslandDisplayTarget.display(screen.id))
                            }
                            if case let .display(id) = settings.islandDisplayTarget,
                               !islandScreens.contains(where: { $0.id == id }) {
                                Text("Unavailable Display")
                                    .tag(SettingsStore.IslandDisplayTarget.display(id))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("settings.islandDisplay")

                        Text(islandDisplayDescription)
                            .font(.caption)
                            .foregroundStyle(isSelectedIslandDisplayUnavailable
                                             ? Color.orange : Color.secondary)

                        Text("Configure the optional notch display in Notch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

        }
        .onAppear { refreshIslandScreens() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshIslandScreens()
        }
    }

    private func refreshIslandScreens() {
        islandScreens = IslandScreenCatalog.options()
    }

    private func islandScreenTitle(_ screen: IslandScreenCatalog.Option) -> String {
        guard screen.isMain else { return screen.name }
        return "\(screen.name) · \(String(localized: "Current Main"))"
    }

    private var isSelectedIslandDisplayUnavailable: Bool {
        guard case let .display(id) = settings.islandDisplayTarget else {
            return false
        }
        return !islandScreens.contains(where: { $0.id == id })
    }

    private var islandDisplayDescription: String {
        switch settings.islandDisplayTarget {
        case .main:
            if islandScreens.contains(where: \.isMain) {
                String(localized: "The panel stays on the display chosen as main in System Settings.")
            } else {
                String(localized: "The panel uses a connected display until the main display is available.")
            }
        case .automatic:
            String(localized: "The panel follows the pointer across displays.")
        case .display where isSelectedIslandDisplayUnavailable:
            String(localized: "This display is unavailable. The panel temporarily uses a connected display.")
        case .display:
            String(localized: "The panel stays on this display until you choose another.")
        }
    }
}
