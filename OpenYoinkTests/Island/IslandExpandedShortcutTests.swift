import XCTest
@testable import OpenYoink

@MainActor
final class IslandExpandedShortcutTests: XCTestCase {
    private func withSettings(_ test: (UserDefaults) throws -> Void) throws {
        let name = "UnifiedShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }

    func testUnifiedDefaultsAndSlotCapacityFollowEnabledModules() throws {
        try withSettings { defaults in
            let settings = SettingsStore(defaults: defaults)
            XCTAssertEqual(settings.effectiveIslandShortcuts.shortcutPositions,
                           [.shelf, .quickSettings, nil, nil, nil, nil, nil, nil])
            XCTAssertEqual(settings.effectiveIslandShortcuts.visibleShortcutIndices(), [0, 1])
            settings.experimentalModulesEnabled = true
            settings.setIslandModuleEnabled(true, id: .timer)
            settings.assignIslandShortcut(.timer, at: 7)
            let saved = settings.islandModuleConfiguration
            settings.experimentalModulesEnabled = false
            XCTAssertEqual(settings.effectiveIslandShortcuts.visibleShortcutIndices(), [0, 1])
            settings.setIslandModuleEnabled(false, id: .shelf)
            XCTAssertEqual(settings.effectiveIslandShortcuts.visibleShortcutIndices(), [1])
            settings.setIslandModuleEnabled(true, id: .shelf)
            settings.assignIslandShortcut(.shelf, at: 0)
            settings.experimentalModulesEnabled = true
            XCTAssertEqual(SettingsStore(defaults: defaults).effectiveIslandShortcuts.shortcutPositions, saved.shortcutPositions)
        }
    }

    func testSavedFloatingPositionsWinAndMigrationRunsOnlyOnce() throws {
        try withSettings { defaults in
            let unknown = IslandModuleID(rawValue: "future-module")
            let old = IslandModuleConfiguration(enabledModuleIDs: [.shelf, .timer, unknown], pinnedModuleIDs: [.timer, .shelf])
            defaults.set(try JSONEncoder().encode(old), forKey: "OpenYoink.islandModuleConfiguration")
            let floating: [IslandModuleID?] = [nil, .timer, .quickSettings, nil, .shelf, unknown, nil, nil]
            defaults.set(try JSONEncoder().encode(floating), forKey: "OpenYoink.notchlessShortcutPositions")
            defaults.set(["timer", "shelf"], forKey: "OpenYoink.compactModuleOrder")
            let settings = SettingsStore(defaults: defaults)
            XCTAssertEqual(settings.islandModuleConfiguration.shortcutPositions, floating)
            XCTAssertTrue(settings.islandModuleConfiguration.isEnabled(unknown))
            XCTAssertEqual(settings.compactModuleOrder, [.timer, .shelf])
            settings.assignIslandShortcut(.quickSettings, at: 7)
            let edited = settings.islandModuleConfiguration.shortcutPositions
            XCTAssertEqual(SettingsStore(defaults: defaults).islandModuleConfiguration.shortcutPositions, edited)
            settings.restoreDefaultIslandShortcuts()
            let restored = SettingsStore(defaults: defaults)
            XCTAssertEqual(restored.islandModuleConfiguration.shortcutPositions.prefix(2), [.shelf, .quickSettings])
            XCTAssertTrue(restored.islandModuleConfiguration.isEnabled(unknown))
        }
    }

    func testNotchedPositionsMigrateInVisualOrderWhenFloatingLayoutAbsentOrCorrupt() throws {
        for corrupt in [false, true] {
            try withSettings { defaults in
                var old = IslandModuleConfiguration(enabledModuleIDs: [.shelf, .timer], pinnedModuleIDs: [])
                old.assignShortcut(.timer, at: 2)
                old.assignShortcut(.shelf, at: 3)
                old.assignShortcut(.quickSettings, at: 6)
                defaults.set(try JSONEncoder().encode(old), forKey: "OpenYoink.islandModuleConfiguration")
                if corrupt { defaults.set(Data("bad data".utf8), forKey: "OpenYoink.notchlessShortcutPositions") }
                let settings = SettingsStore(defaults: defaults)
                XCTAssertEqual(settings.islandModuleConfiguration.shortcutPositions,
                               [.timer, .shelf, .quickSettings, nil, nil, nil, nil, nil])
                XCTAssertEqual(SettingsStore(defaults: defaults).islandModuleConfiguration, settings.islandModuleConfiguration)
            }
        }
    }

    func testCompactPreferencePersistsWithoutChangingModuleChoices() throws {
        try withSettings { defaults in
            let settings = SettingsStore(defaults: defaults)
            XCTAssertTrue(settings.showCompactIsland)
            settings.compactModuleID = .timer
            let saved = settings.islandModuleConfiguration
            settings.showCompactIsland = false
            let restored = SettingsStore(defaults: defaults)
            XCTAssertFalse(restored.showCompactIsland)
            XCTAssertEqual(restored.compactModuleID, .timer)
            XCTAssertEqual(restored.islandModuleConfiguration, saved)
        }
    }
}
