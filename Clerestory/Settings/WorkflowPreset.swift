import Foundation

enum WorkflowPreset: String, CaseIterable, Identifiable {
    case files, clipboard, toolbox
    var id: Self { self }
    var title: String {
        switch self {
        case .files: String(localized: "Files")
        case .clipboard: String(localized: "Files & Clipboard")
        case .toolbox: String(localized: "Full Toolbox")
        }
    }
    static func availableCases(experimentalModulesEnabled: Bool) -> [Self] {
        experimentalModulesEnabled ? allCases : [.files]
    }

    func detail(experimentalModulesEnabled: Bool) -> String {
        let modules: String
        switch self {
        case .files:
            modules = experimentalModulesEnabled
                ? String(localized: "Use Shelf and Transfers for files.")
                : String(localized: "Use Shelf for files. Hidden module preferences are preserved.")
        case .clipboard:
            modules = String(localized: "Use Shelf, Transfers and Clipboard History. Recording stays under your control.")
        case .toolbox:
            modules = String(localized: "Enable all available modules. Clipboard recording stays under your control.")
        }
        return modules + " " + String(localized: "Enable the panel and drag-to-open, and turn off hover opening.")
    }

}

extension SettingsStore {
    /// Changes presentation only. Data, privacy consent, shortcut, and unknown module IDs survive.
    func applyWorkflowPreset(_ preset: WorkflowPreset) {
        guard WorkflowPreset.availableCases(experimentalModulesEnabled: experimentalModulesEnabled).contains(preset) else { return }
        islandDragApproachEnabled = true
        islandHoverRevealEnabled = false
        islandEnabled = true
        let builtIns = IslandModuleRegistry().descriptors.map(\.id)
        let enabled: [IslandModuleID]
        let pinned: [IslandModuleID]
        switch preset {
        case .files: enabled = [.shelf, .transfers]; pinned = [.shelf]
        case .clipboard: enabled = [.shelf, .transfers, .clipboard]; pinned = [.shelf, .clipboard]
        case .toolbox: enabled = builtIns; pinned = [.shelf, .clipboard, .media, .system]
        }
        var configuration = islandModuleConfiguration
        // Preserve hidden/unknown modules and their exact saved shortcut positions.
        for id in builtIns where isIslandModuleAvailable(id) {
            configuration.setEnabled(enabled.contains(id), for: id)
            if !pinned.contains(id) { configuration.setPinned(false, for: id) }
        }
        for id in pinned where isIslandModuleAvailable(id) {
            configuration.setPinned(true, for: id)
        }
        islandModuleConfiguration = configuration
    }
}
