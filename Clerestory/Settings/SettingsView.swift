import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsNavigationModel {
    var selectedPane: SettingsPane = .general
    var moduleSettingsDestination: ModuleSettingsDestination?

    func open(_ pane: SettingsPane) {
        switch pane {
        case .shelf:
            selectedPane = .modules
            moduleSettingsDestination = .shelf
        case .triggers, .ignoredApps:
            selectedPane = .panel
            moduleSettingsDestination = nil
        case .clipboard:
            selectedPane = .modules
            moduleSettingsDestination = .clipboard
        default:
            selectedPane = SettingsPane.visibleCases.contains(pane) ? pane : .general
            moduleSettingsDestination = nil
        }
    }

    /// Open one module's detail page, or the module list when `destination` is nil.
    func openModule(_ destination: ModuleSettingsDestination?) {
        selectedPane = .modules
        moduleSettingsDestination = destination
    }

    /// Tab focus can move independently of selection in the button sidebar.
    /// Arrow navigation continues from that focused button, not the old pane.
    @discardableResult
    func moveSidebarSelection(forward: Bool, focusedPane: SettingsPane?) -> SettingsPane? {
        let currentPane = focusedPane ?? selectedPane
        guard let current = SettingsPane.visibleCases.firstIndex(of: currentPane) else { return nil }
        let next = current + (forward ? 1 : -1)
        guard SettingsPane.visibleCases.indices.contains(next) else { return nil }
        let pane = SettingsPane.visibleCases[next]
        open(pane)
        return pane
    }
}

/// Sidebar navigation and independently scrolling pages hosted by SettingsWindowController.
struct SettingsView: View {
    @Environment(SettingsNavigationModel.self) private var navigation
    @State private var windowVisibility = SettingsWindowVisibility()
    @FocusState private var focusedPane: SettingsPane?

    var body: some View {
        ZStack {
            if windowVisibility.displaysContent {
                settingsContent
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 680, idealWidth: 720, maxWidth: .infinity,
               minHeight: 480, idealHeight: 520, maxHeight: .infinity)
        .background {
            SettingsWindowVisibilityReader(visibility: windowVisibility)
                .frame(width: 0, height: 0)
        }
    }

    private var settingsContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsPane.visibleCases) { pane in
                    Button {
                        navigation.open(pane)
                    } label: {
                        Label(pane.title, systemImage: pane.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background {
                                if navigation.selectedPane == pane {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(0.18))
                                } else if focusedPane == pane {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.06))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focusedPane, equals: pane)
                    .accessibilityAddTraits(navigation.selectedPane == pane ? .isSelected : [])
                    .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(minWidth: 156, idealWidth: 168, maxWidth: 188)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Settings Categories")
            .onMoveCommand { direction in
                guard direction == .up || direction == .down,
                      let pane = navigation.moveSidebarSelection(
                        forward: direction == .down, focusedPane: focusedPane
                      ) else { return }
                focusedPane = pane
            }

            Divider()

            selectedContent(for: navigation.selectedPane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("settings.content.\(navigation.selectedPane.rawValue)")
        }
    }

    @ViewBuilder
    private func selectedContent(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsTab()
        case .panel, .triggers, .ignoredApps:
            PanelSettingsTab()
        case .notch:
            NotchSettingsTab()
        case .shelf:
            ShelfSettingsTab()
        case .modules:
            ModulesSettingsTab()
        case .clipboard:
            ClipboardSettingsTab()
        case .storage:
            StorageSettingsTab()
        case .debug:
            #if DEBUG
            DebugSettingsTab()
            #else
            GeneralSettingsTab()
            #endif
        case .about:
            AboutSettingsTab()
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case panel
    case notch = "compact" // Preserve existing navigation identifiers.
    case shelf
    case modules
    case clipboard
    case triggers
    case ignoredApps
    case storage
    case debug
    case about

    static var visibleCases: [SettingsPane] {
        #if DEBUG
        allCases.filter { $0 != .triggers && $0 != .ignoredApps && $0 != .shelf && $0 != .clipboard }
        #else
        allCases.filter { $0 != .triggers && $0 != .ignoredApps && $0 != .shelf && $0 != .clipboard && $0 != .debug }
        #endif
    }

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .panel: "Panel"
        case .notch: "Notch"
        case .shelf: "Shelf"
        case .modules: "Modules"
        case .clipboard: "Clipboard"
        case .triggers: "Triggers"
        case .ignoredApps: "Ignored Apps"
        case .storage: "Storage"
        case .debug: "Debug"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .panel: "macwindow"
        case .notch: "macbook.gen2"
        case .shelf: "tray"
        case .modules: "square.grid.2x2"
        case .clipboard: "doc.on.clipboard"
        case .triggers: "keyboard"
        case .ignoredApps: "hand.raised"
        case .storage: "externaldrive"
        case .debug: "ladybug"
        case .about: "info.circle"
        }
    }
}
