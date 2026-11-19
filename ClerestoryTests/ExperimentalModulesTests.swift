import XCTest
@testable import Clerestory

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
        settings.assignIslandShortcut(.timer, at: 2)
        settings.assignIslandShortcut(.battery, at: 7)
        settings.notchModuleOrder = [.timer, .battery, .shelf]
        settings.notchModuleID = .battery
        let saved = settings.islandModuleConfiguration

        XCTAssertFalse(settings.experimentalModulesEnabled)
        registry.apply(settings: settings)
        XCTAssertEqual(registry.enabledDescriptors.map(\.id), [.shelf])
        XCTAssertTrue(registry.isEnabled(.quickSettings))
        XCTAssertEqual(settings.notchDisplay, .shelf)
        XCTAssertEqual(settings.effectiveNotchModuleOrder, [.shelf])
        for id in experimental {
            XCTAssertFalse(settings.isIslandModuleAvailable(id))
            XCTAssertFalse(settings.effectiveIslandModuleConfiguration.isEnabled(id))
            XCTAssertFalse(settings.effectiveIslandModuleConfiguration.shortcutPositions.contains(id))
        }
        XCTAssertEqual(settings.effectiveIslandModuleConfiguration.shortcutPositions[0], .shelf)
        XCTAssertEqual(settings.effectiveIslandModuleConfiguration.shortcutPositions[1], .quickSettings)
        XCTAssertEqual(settings.islandModuleConfiguration, saved)

        settings.experimentalModulesEnabled = true
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.experimentalModulesEnabled)
        XCTAssertEqual(reloaded.effectiveIslandModuleConfiguration, saved)
        XCTAssertEqual(reloaded.notchDisplay, .battery)
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
        settings.notchCycleShortcut = settings.clipboardHistoryShortcut
        XCTAssertFalse(settings.notchCycleShortcutConflicts)
        settings.experimentalModulesEnabled = true
        XCTAssertTrue(settings.notchCycleShortcutConflicts)
    }
}
