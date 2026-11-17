import XCTest
@testable import OpenYoink

@MainActor
final class IslandCompactSelectionTests: XCTestCase {
    func testCustomCompactOrderPersistsAndRemainsIndependentOfExpandedSlots() throws {
        let suite = "OpenYoink.CompactOrder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalModulesEnabled = true
        for id in IslandCompactDisplay.cycleOrder { settings.setIslandModuleEnabled(true, id: id) }
        let expanded = settings.islandModuleConfiguration.shortcutPositions
        settings.compactModuleOrder = [.battery, .timer, .shelf]
        settings.compactModuleID = .battery
        settings.cycleCompactModule()
        XCTAssertEqual(settings.compactModuleID, .timer)
        settings.cycleCompactModule(backwards: true)
        XCTAssertEqual(settings.compactModuleID, .battery)
        settings.setCompactModuleIncluded(false, id: .battery)
        XCTAssertEqual(settings.compactDisplay, .timer)
        settings.moveCompactModule(.shelf, to: .timer)
        XCTAssertEqual(settings.compactModuleOrder, [.shelf, .timer])
        XCTAssertEqual(settings.compactDisplay, .shelf)
        XCTAssertEqual(settings.islandModuleConfiguration.shortcutPositions, expanded)
        settings.setIslandModuleEnabled(false, id: .shelf)
        XCTAssertEqual(settings.effectiveCompactModuleOrder, [.timer])
        settings.setIslandModuleEnabled(true, id: .shelf)
        XCTAssertEqual(SettingsStore(defaults: defaults).compactModuleOrder, [.shelf, .timer])
        // Compact edits never changed the previously configured expanded positions.
        settings.restoreDefaultIslandShortcuts()
        XCTAssertEqual(settings.islandModuleConfiguration.shortcutPositions, expanded)
        settings.compactModuleOrder = []
        XCTAssertEqual(settings.compactDisplay, .fallback)
        XCTAssertTrue(SettingsStore(defaults: defaults).compactModuleOrder.isEmpty)
    }

    func testCycleSkipsDisabledAndUnsupportedModulesAndWraps() {
        let enabled: [IslandModuleID] = [.shelf, .timer, .media, .folders, .system, .clipboard, .quickSettings]
        XCTAssertEqual(IslandCompactDisplay.next(after: .shelf, enabled: enabled), .timer)
        XCTAssertEqual(IslandCompactDisplay.next(after: .timer, enabled: enabled), .media)
        XCTAssertEqual(IslandCompactDisplay.next(after: .media, enabled: enabled), .shelf)
        XCTAssertEqual(IslandCompactDisplay.next(after: .battery, enabled: enabled), .timer)
        XCTAssertEqual(IslandCompactDisplay.selected(.battery, enabled: enabled), .shelf)
    }

    func testReverseCycleWrapsAndSkipsDisabledModules() {
        let enabled: [IslandModuleID] = [.shelf, .timer, .media, .system]
        XCTAssertEqual(IslandCompactDisplay.next(after: .shelf, enabled: enabled, backwards: true), .media)
        XCTAssertEqual(IslandCompactDisplay.next(after: .media, enabled: enabled, backwards: true), .timer)
        XCTAssertEqual(IslandCompactDisplay.next(after: .timer, enabled: enabled, backwards: true), .shelf)
        XCTAssertEqual(IslandCompactDisplay.next(after: .battery, enabled: enabled, backwards: true), .media)
        XCTAssertNil(IslandCompactDisplay.next(after: .shelf, enabled: [], backwards: true))
        XCTAssertEqual(IslandCompactDisplay.next(after: .shelf, enabled: [.shelf], backwards: true), .shelf)
    }

    func testReverseShortcutAndDirection() throws {
        let suite = "OpenYoink.ReverseCycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalModulesEnabled = true
        var reverse = SettingsStore.HotKeyShortcut.compactCycle
        reverse.shift = true
        XCTAssertEqual(settings.compactReverseCycleShortcut, reverse)
        settings.clipboardHistoryShortcut = reverse
        XCTAssertTrue(settings.compactCycleShortcutConflicts)
        settings.clipboardHistoryShortcut = nil
        settings.hotKeyEnabled = true
        settings.hotKeyShortcut = reverse
        XCTAssertTrue(settings.compactCycleShortcutConflicts)
        settings.hotKeyEnabled = false
        XCTAssertFalse(settings.compactCycleShortcutConflicts)
        settings.compactCycleShortcut = reverse
        XCTAssertEqual(settings.compactReverseCycleShortcut, .compactCycle)
        settings.compactCycleShortcut = nil
        XCTAssertNil(settings.compactReverseCycleShortcut)
        for id in IslandCompactDisplay.cycleOrder { settings.setIslandModuleEnabled(true, id: id) }
        settings.compactModuleID = .shelf
        settings.cycleCompactModule(backwards: true)
        XCTAssertEqual(settings.compactModuleID, .aiUsage)
        XCTAssertTrue(settings.compactCycleBackwards)
        settings.cycleCompactModule()
        XCTAssertEqual(settings.compactModuleID, .shelf)
        XCTAssertFalse(settings.compactCycleBackwards)
    }

    func testExistingSlideUsesNewDirectionOnFirstReversal() {
        var backwards = false
        let outgoing = IslandCompactSlideModifier(progress: -0.5, isBackwards: { backwards })
        let incoming = IslandCompactSlideModifier(progress: 0.5, isBackwards: { backwards })
        XCTAssertLessThan(outgoing.horizontalOffset, 0)
        XCTAssertGreaterThan(incoming.horizontalOffset, 0)
        backwards = true
        XCTAssertGreaterThan(outgoing.horizontalOffset, 0)
        XCTAssertLessThan(incoming.horizontalOffset, 0)
        backwards = false
        XCTAssertLessThan(outgoing.horizontalOffset, 0)
        XCTAssertGreaterThan(incoming.horizontalOffset, 0)
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
        settings.experimentalModulesEnabled = true
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
        settings.experimentalModulesEnabled = true
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
        settings.experimentalModulesEnabled = true
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
