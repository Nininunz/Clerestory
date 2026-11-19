import SwiftUI
@testable import Clerestory

/// IDs are part of the CLI/manifest contract; labels can change independently.
@MainActor
struct ModuleScenario {
    let id: String
    let label: String
    let makeView: () throws -> ModuleScenarioContent
}

/// Surface state travels with the module view, rather than being independently spoofed.
@MainActor
struct ModuleScenarioContent {
    let view: AnyView
    var dropTarget: DropTargetState? = nil
    var notices: ShelfNoticeModel? = nil
}

/// Explicit lifetime for isolated preferences used by rendered views.
@MainActor
final class PreviewContext {
    private var suites: [String] = []

    func defaults() -> UserDefaults {
        let name = "Clerestory.TestKit.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    func settings() -> SettingsStore { SettingsStore(defaults: defaults()) }

    func cleanUp() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites.removeAll()
    }
}
