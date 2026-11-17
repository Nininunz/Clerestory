import XCTest
@testable import OpenYoink

@MainActor
final class ExperimentalModulesTests: XCTestCase {
    func testGateDefaultsOffAndPreservesSavedChoicesAcrossRestart() throws {
        let name = "ExperimentalModules.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let registry = IslandModuleRegistry()
        let experimental = registry.descriptors.map(\.id).filter { $0 != .shelf } + [IslandModuleID(rawValue: "future")]
        for id in experimental { settings.setIslandModuleEnabled(true, id: id) }
        settings.assignIslandShortcut(.timer, at: 0)
        settings.assignIslandShortcut(.battery, at: 7)
        settings.compactModuleOrder = [.timer, .battery, .shelf]
        settings.compactModuleID = .battery
        let saved = settings.islandModuleConfiguration

        XCTAssertFalse(settings.experimentalModulesEnabled)
        registry.apply(settings: settings)
        XCTAssertEqual(registry.enabledDescriptors.map(\.id), [.shelf])
        XCTAssertTrue(registry.isEnabled(.quickSettings))
        XCTAssertEqual(settings.compactDisplay, .shelf)
        XCTAssertEqual(settings.effectiveCompactModuleOrder, [.shelf])
        for id in experimental {
            XCTAssertFalse(settings.isIslandModuleAvailable(id))
            XCTAssertFalse(settings.effectiveIslandModuleConfiguration.isEnabled(id))
            XCTAssertFalse(settings.effectiveIslandModuleConfiguration.shortcutPositions.contains(id))
        }
        XCTAssertEqual(settings.effectiveIslandModuleConfiguration.shortcutPositions[3], .shelf)
        XCTAssertEqual(settings.effectiveIslandModuleConfiguration.shortcutPositions[4], .quickSettings)
        XCTAssertEqual(settings.islandModuleConfiguration, saved)

        settings.experimentalModulesEnabled = true
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.experimentalModulesEnabled)
        XCTAssertEqual(reloaded.effectiveIslandModuleConfiguration, saved)
        XCTAssertEqual(reloaded.compactDisplay, .battery)
        reloaded.experimentalModulesEnabled = false
        XCTAssertEqual(SettingsStore(defaults: defaults).islandModuleConfiguration, saved)
        XCTAssertFalse(SettingsStore(defaults: defaults).experimentalModulesEnabled)
    }

    func testQuickSettingsRemainsReachableWithShelfDisabled() throws {
        let name = "ExperimentalModules.Empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.setIslandModuleEnabled(false, id: .shelf)
        let registry = IslandModuleRegistry()
        registry.apply(settings: settings)
        XCTAssertTrue(registry.enabledDescriptors.isEmpty)
        XCTAssertTrue(registry.isEnabled(.quickSettings))
        XCTAssertEqual(settings.effectiveIslandModuleConfiguration.shortcutPositions.compactMap { $0 }, [.quickSettings])
        settings.compactCycleShortcut = settings.clipboardHistoryShortcut
        XCTAssertFalse(settings.compactCycleShortcutConflicts)
        settings.experimentalModulesEnabled = true
        XCTAssertTrue(settings.compactCycleShortcutConflicts)
    }
}
