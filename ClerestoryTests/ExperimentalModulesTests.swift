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
        let experimental = registry.descriptors.map(\.id).filter { !SettingsStore.standardModuleIDs.contains($0) }
            + [IslandModuleID(rawValue: "future")]
        for id in experimental + [.battery] { settings.setIslandModuleEnabled(true, id: id) }
        settings.assignIslandShortcut(.timer, at: 2)
        settings.assignIslandShortcut(.battery, at: 7)
        settings.notchModuleOrder = [.timer, .shelf, .battery]
        settings.notchModuleID = .timer
        let saved = settings.islandModuleConfiguration

        XCTAssertFalse(settings.experimentalModulesEnabled)
        registry.apply(settings: settings)
        XCTAssertEqual(registry.enabledDescriptors.map(\.id), [.shelf, .battery])
        XCTAssertTrue(registry.isEnabled(.quickSettings))
        XCTAssertEqual(settings.notchDisplay, .shelf)
        XCTAssertEqual(settings.effectiveNotchModuleOrder, [.shelf, .battery])
        for id in experimental {
            XCTAssertFalse(settings.isIslandModuleAvailable(id))
            XCTAssertFalse(settings.effectiveIslandModuleConfiguration.isEnabled(id))
            XCTAssertFalse(settings.effectiveIslandModuleConfiguration.shortcutPositions.contains(id))
        }
        XCTAssertTrue(settings.isIslandModuleAvailable(.battery))
        XCTAssertTrue(settings.effectiveIslandModuleConfiguration.isEnabled(.battery))
        XCTAssertEqual(settings.effectiveIslandModuleConfiguration.shortcutPositions[0], .shelf)
        XCTAssertEqual(settings.effectiveIslandModuleConfiguration.shortcutPositions[1], .quickSettings)
        XCTAssertEqual(settings.effectiveIslandModuleConfiguration.shortcutPositions[7], .battery)
        XCTAssertEqual(settings.islandModuleConfiguration, saved)

        settings.experimentalModulesEnabled = true
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.experimentalModulesEnabled)
        XCTAssertEqual(reloaded.effectiveIslandModuleConfiguration, saved)
        XCTAssertEqual(reloaded.notchDisplay, .timer)
        reloaded.experimentalModulesEnabled = false
        XCTAssertEqual(SettingsStore(defaults: defaults).islandModuleConfiguration, saved)
        XCTAssertFalse(SettingsStore(defaults: defaults).experimentalModulesEnabled)
    }

    func testBatteryIsAvailableByDefault() throws {
        let name = "ExperimentalModules.Battery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.experimentalModulesEnabled)
        XCTAssertTrue(settings.isIslandModuleAvailable(.battery))
        XCTAssertTrue(settings.effectiveIslandModuleConfiguration.isEnabled(.battery))
        XCTAssertTrue(settings.effectiveNotchModuleOrder.contains(.battery))
        XCTAssertEqual(settings.effectiveIslandShortcuts.shortcutPositions.prefix(3), [.shelf, .quickSettings, .battery])
        let registry = IslandModuleRegistry()
        registry.apply(settings: settings)
        XCTAssertTrue(registry.isEnabled(.battery))
        XCTAssertFalse(registry.isEnabled(.timer))
    }

    func testQuickSettingsRemainsReachableWithShelfDisabled() throws {
        let name = "ExperimentalModules.Empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.setIslandModuleEnabled(false, id: .shelf)
        settings.setIslandModuleEnabled(false, id: .battery)
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
