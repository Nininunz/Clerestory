import XCTest
@testable import OpenYoink

@MainActor
final class IslandNotchlessShortcutTests: XCTestCase {
    func testVisibleSlotsFollowGateAndEnablementWithoutChangingSavedPositions() throws {
        let name = "ShortcutCapacity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        for notched in [false, true] {
            let configuration = settings.effectiveIslandShortcuts(hasPhysicalNotch: notched)
            XCTAssertEqual(configuration.visibleShortcutIndices(hasPhysicalNotch: notched), notched ? [3, 4] : [0, 1])
        }
        settings.experimentalModulesEnabled = true
        settings.setIslandModuleEnabled(true, id: .timer)
        settings.assignIslandShortcut(.timer, at: 7, hasPhysicalNotch: false)
        let saved = settings.islandShortcuts(hasPhysicalNotch: false)
        settings.experimentalModulesEnabled = false
        XCTAssertEqual(settings.effectiveIslandShortcuts(hasPhysicalNotch: false)
            .visibleShortcutIndices(hasPhysicalNotch: false), [0, 1])
        settings.setIslandModuleEnabled(false, id: .shelf)
        XCTAssertEqual(settings.effectiveIslandShortcuts(hasPhysicalNotch: false)
            .visibleShortcutIndices(hasPhysicalNotch: false), [1])
        settings.setIslandModuleEnabled(true, id: .shelf)
        settings.experimentalModulesEnabled = true
        let restored = SettingsStore(defaults: defaults).effectiveIslandShortcuts(hasPhysicalNotch: false)
        XCTAssertEqual(restored.shortcutPositions, saved.shortcutPositions)
        XCTAssertTrue(restored.visibleShortcutIndices(hasPhysicalNotch: false).contains(7))
    }

    func testNotchlessDefaultsStartAtLeftAndEditsPersistIndependently() throws {
        let name = "NotchlessShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let notched = settings.effectiveIslandShortcuts(hasPhysicalNotch: true).shortcutPositions
        let floatingDefault: [IslandModuleID?] = [.shelf, .quickSettings, nil, nil, nil, nil, nil, nil]
        XCTAssertEqual(notched, [nil, nil, nil, .shelf, .quickSettings, nil, nil, nil])
        XCTAssertEqual(settings.effectiveIslandShortcuts(hasPhysicalNotch: false).shortcutPositions, floatingDefault)

        settings.assignIslandShortcut(.quickSettings, at: 7, hasPhysicalNotch: false)
        settings.assignIslandShortcut(.shelf, at: 2, hasPhysicalNotch: false)
        let edited = settings.effectiveIslandShortcuts(hasPhysicalNotch: false).shortcutPositions
        XCTAssertEqual(edited[2], .shelf)
        XCTAssertEqual(edited[7], .quickSettings)
        XCTAssertEqual(settings.effectiveIslandShortcuts(hasPhysicalNotch: true).shortcutPositions, notched)
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.effectiveIslandShortcuts(hasPhysicalNotch: false).shortcutPositions, edited)
        reloaded.restoreDefaultIslandShortcuts(hasPhysicalNotch: false)
        XCTAssertEqual(reloaded.effectiveIslandShortcuts(hasPhysicalNotch: false).shortcutPositions, floatingDefault)
        XCTAssertEqual(reloaded.effectiveIslandShortcuts(hasPhysicalNotch: true).shortcutPositions, notched)
        XCTAssertEqual(SettingsStore(defaults: defaults).effectiveIslandShortcuts(hasPhysicalNotch: false).shortcutPositions, floatingDefault)
    }

    func testExperimentalGatePreservesNotchlessPositions() throws {
        let name = "NotchlessGate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalModulesEnabled = true
        settings.setIslandModuleEnabled(true, id: .timer)
        settings.assignIslandShortcut(.timer, at: 4, hasPhysicalNotch: false)
        settings.experimentalModulesEnabled = false
        XCTAssertNil(settings.effectiveIslandShortcuts(hasPhysicalNotch: false).shortcutPositions[4])
        settings.experimentalModulesEnabled = true
        XCTAssertEqual(settings.effectiveIslandShortcuts(hasPhysicalNotch: false).shortcutPositions[4], .timer)
    }
}
