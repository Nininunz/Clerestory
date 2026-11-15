import XCTest
@testable import OpenYoink

@MainActor
final class IslandCompactSelectionTests: XCTestCase {
    func testCycleSkipsDisabledAndUnsupportedModulesAndWraps() {
        let enabled: [IslandModuleID] = [.shelf, .timer, .media, .folders, .system, .clipboard, .quickSettings]
        XCTAssertEqual(IslandCompactDisplay.next(after: .shelf, enabled: enabled), .timer)
        XCTAssertEqual(IslandCompactDisplay.next(after: .timer, enabled: enabled), .media)
        XCTAssertEqual(IslandCompactDisplay.next(after: .media, enabled: enabled), .shelf)
        XCTAssertEqual(IslandCompactDisplay.next(after: .battery, enabled: enabled), .timer)
        XCTAssertEqual(IslandCompactDisplay.selected(.battery, enabled: enabled), .shelf)
    }

    func testZeroAndOneAvailableModule() {
        XCTAssertNil(IslandCompactDisplay.next(after: .shelf, enabled: [.system]))
        XCTAssertEqual(IslandCompactDisplay.selected(.shelf, enabled: [.system]), .fallback)
        XCTAssertEqual(IslandCompactDisplay.next(after: .battery, enabled: [.battery]), .battery)
    }

    func testChoiceAndShortcutPersistAndClearingShortcutStaysCleared() throws {
        let suite = "OpenYoink.CompactSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.compactModuleID, .shelf)
        XCTAssertEqual(settings.compactCycleShortcut, .compactCycle)
        settings.compactModuleID = .battery
        settings.compactCycleShortcut = .init(keyCode: 17, command: true, shift: false, option: true, control: false)
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.compactModuleID, .battery)
        XCTAssertEqual(restored.compactCycleShortcut, settings.compactCycleShortcut)
        restored.compactCycleShortcut = nil
        XCTAssertNil(SettingsStore(defaults: defaults).compactCycleShortcut)
    }

    func testCycleDoesNotChangeExpandedSelectionAndActivitiesDoNotChangeChoice() throws {
        let suite = "OpenYoink.CompactSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        for id in IslandCompactDisplay.cycleOrder { settings.setIslandModuleEnabled(true, id: id) }
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .system)
        settings.compactModuleID = .battery
        coordinator.publish(.init(id: "timer", moduleID: .timer, priority: .timerFinished,
                                  title: "Timer finished", detail: nil, systemImage: "timer", expiresAt: nil))
        XCTAssertEqual(IslandCompactDisplay.selected(settings.compactModuleID,
            enabled: settings.islandModuleConfiguration.enabledModuleIDs), .battery)
        settings.cycleCompactModule()
        XCTAssertEqual(settings.compactModuleID, .media)
        XCTAssertEqual(coordinator.selectedModule, .system)
    }

    func testConflictsWithExistingShortcuts() throws {
        let suite = "OpenYoink.CompactSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.compactCycleShortcutConflicts)
        settings.hotKeyEnabled = true
        settings.compactCycleShortcut = settings.hotKeyShortcut
        XCTAssertTrue(settings.compactCycleShortcutConflicts)
        settings.hotKeyEnabled = false
        XCTAssertFalse(settings.compactCycleShortcutConflicts)
        settings.compactCycleShortcut = settings.clipboardHistoryShortcut
        XCTAssertTrue(settings.compactCycleShortcutConflicts)
        settings.compactCycleShortcut = nil
        XCTAssertFalse(settings.compactCycleShortcutConflicts)
    }
}
