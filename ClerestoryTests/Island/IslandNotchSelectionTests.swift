import XCTest
@testable import Clerestory

@MainActor
final class IslandNotchSelectionTests: XCTestCase {
    func testLegacyCompactPreferenceKeysRoundTripThroughNotchNames() throws {
        let suite = "NotchLegacyPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcut = SettingsStore.HotKeyShortcut(keyCode: 18, command: true, shift: false, option: true, control: false)
        defaults.set(false, forKey: "Clerestory.showCompactIsland")
        defaults.set(["battery", "shelf"], forKey: "Clerestory.compactModuleOrder")
        defaults.set("battery", forKey: "Clerestory.compactModuleID")
        defaults.set(try JSONEncoder().encode(shortcut), forKey: "Clerestory.compactCycleShortcut")
        defaults.set("todayTokens", forKey: "Clerestory.aiUsageCompactMetric")

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.showNotch)
        XCTAssertEqual(settings.notchModuleOrder, [.battery, .shelf])
        XCTAssertEqual(settings.notchModuleID, .battery)
        XCTAssertEqual(settings.notchCycleShortcut, shortcut)
        XCTAssertEqual(settings.aiUsageNotchMetric, .todayTokens)

        settings.showNotch = true
        settings.notchModuleOrder = [.timer, .shelf]
        settings.notchModuleID = .timer
        settings.notchCycleShortcut = nil
        settings.aiUsageNotchMetric = .tightestLimit
        XCTAssertTrue(defaults.bool(forKey: "Clerestory.showCompactIsland"))
        XCTAssertEqual(defaults.stringArray(forKey: "Clerestory.compactModuleOrder"), ["timer", "shelf"])
        XCTAssertEqual(defaults.string(forKey: "Clerestory.compactModuleID"), "timer")
        XCTAssertEqual(defaults.string(forKey: "Clerestory.aiUsageCompactMetric"), "tightestLimit")
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertNil(reloaded.notchCycleShortcut)
        XCTAssertEqual(reloaded.notchModuleOrder, [.timer, .shelf])
        XCTAssertEqual(reloaded.notchModuleID, .timer)
        XCTAssertEqual(reloaded.aiUsageNotchMetric, .tightestLimit)
        XCTAssertTrue(reloaded.showNotch)
        for key in ["showNotch", "notchModuleOrder", "notchModuleID", "notchCycleShortcut", "aiUsageNotchMetric"] {
            XCTAssertNil(defaults.object(forKey: "Clerestory.\(key)"), "Must retain the legacy storage key")
        }
    }

    func testCustomNotchOrderPersistsAndRemainsIndependentOfExpandedSlots() throws {
        let suite = "Clerestory.NotchOrder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalModulesEnabled = true
        for id in IslandNotchDisplay.cycleOrder { settings.setIslandModuleEnabled(true, id: id) }
        let expanded = settings.islandModuleConfiguration.shortcutPositions
        settings.notchModuleOrder = [.battery, .timer, .shelf]
        settings.notchModuleID = .battery
        settings.cycleNotchModule()
        XCTAssertEqual(settings.notchModuleID, .timer)
        settings.cycleNotchModule(backwards: true)
        XCTAssertEqual(settings.notchModuleID, .battery)
        settings.setNotchModuleIncluded(false, id: .battery)
        XCTAssertEqual(settings.notchDisplay, .timer)
        settings.moveNotchModule(.shelf, to: .timer)
        XCTAssertEqual(settings.notchModuleOrder, [.shelf, .timer])
        XCTAssertEqual(settings.notchDisplay, .shelf)
        XCTAssertEqual(settings.islandModuleConfiguration.shortcutPositions, expanded)
        settings.setIslandModuleEnabled(false, id: .shelf)
        XCTAssertEqual(settings.effectiveNotchModuleOrder, [.timer])
        settings.setIslandModuleEnabled(true, id: .shelf)
        XCTAssertEqual(SettingsStore(defaults: defaults).notchModuleOrder, [.shelf, .timer])
        // Notch edits never changed the previously configured expanded positions.
        settings.restoreDefaultIslandShortcuts()
        XCTAssertEqual(settings.islandModuleConfiguration.shortcutPositions, expanded)
        settings.notchModuleOrder = []
        XCTAssertEqual(settings.notchDisplay, .fallback)
        XCTAssertTrue(SettingsStore(defaults: defaults).notchModuleOrder.isEmpty)
    }

    func testCycleSkipsDisabledAndUnsupportedModulesAndWraps() {
        let enabled: [IslandModuleID] = [.shelf, .timer, .media, .folders, .system, .clipboard, .quickSettings]
        XCTAssertEqual(IslandNotchDisplay.next(after: .shelf, enabled: enabled), .timer)
        XCTAssertEqual(IslandNotchDisplay.next(after: .timer, enabled: enabled), .media)
        XCTAssertEqual(IslandNotchDisplay.next(after: .media, enabled: enabled), .shelf)
        XCTAssertEqual(IslandNotchDisplay.next(after: .battery, enabled: enabled), .timer)
        XCTAssertEqual(IslandNotchDisplay.selected(.battery, enabled: enabled), .shelf)
    }

    func testReverseCycleWrapsAndSkipsDisabledModules() {
        let enabled: [IslandModuleID] = [.shelf, .timer, .media, .system]
        XCTAssertEqual(IslandNotchDisplay.next(after: .shelf, enabled: enabled, backwards: true), .media)
        XCTAssertEqual(IslandNotchDisplay.next(after: .media, enabled: enabled, backwards: true), .timer)
        XCTAssertEqual(IslandNotchDisplay.next(after: .timer, enabled: enabled, backwards: true), .shelf)
        XCTAssertEqual(IslandNotchDisplay.next(after: .battery, enabled: enabled, backwards: true), .media)
        XCTAssertNil(IslandNotchDisplay.next(after: .shelf, enabled: [], backwards: true))
        XCTAssertEqual(IslandNotchDisplay.next(after: .shelf, enabled: [.shelf], backwards: true), .shelf)
    }

    func testReverseShortcutAndDirection() throws {
        let suite = "Clerestory.ReverseCycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalModulesEnabled = true
        var reverse = SettingsStore.HotKeyShortcut.notchCycle
        reverse.shift = true
        XCTAssertEqual(settings.notchReverseCycleShortcut, reverse)
        settings.clipboardHistoryShortcut = reverse
        XCTAssertTrue(settings.notchCycleShortcutConflicts)
        settings.clipboardHistoryShortcut = nil
        settings.hotKeyEnabled = true
        settings.hotKeyShortcut = reverse
        XCTAssertTrue(settings.notchCycleShortcutConflicts)
        settings.hotKeyEnabled = false
        XCTAssertFalse(settings.notchCycleShortcutConflicts)
        settings.notchCycleShortcut = reverse
        XCTAssertEqual(settings.notchReverseCycleShortcut, .notchCycle)
        settings.notchCycleShortcut = nil
        XCTAssertNil(settings.notchReverseCycleShortcut)
        for id in IslandNotchDisplay.cycleOrder { settings.setIslandModuleEnabled(true, id: id) }
        settings.notchModuleID = .shelf
        settings.cycleNotchModule(backwards: true)
        XCTAssertEqual(settings.notchModuleID, .aiUsage)
        XCTAssertTrue(settings.notchCycleBackwards)
        settings.cycleNotchModule()
        XCTAssertEqual(settings.notchModuleID, .shelf)
        XCTAssertFalse(settings.notchCycleBackwards)
    }

    func testExistingSlideUsesNewDirectionOnFirstReversal() {
        var backwards = false
        let outgoing = IslandNotchSlideModifier(progress: -0.5, isBackwards: { backwards })
        let incoming = IslandNotchSlideModifier(progress: 0.5, isBackwards: { backwards })
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
        XCTAssertNil(IslandNotchDisplay.next(after: .shelf, enabled: [.system]))
        XCTAssertEqual(IslandNotchDisplay.selected(.shelf, enabled: [.system]), .fallback)
        XCTAssertEqual(IslandNotchDisplay.next(after: .battery, enabled: [.battery]), .battery)
    }

    func testChoiceAndShortcutPersistAndClearingShortcutStaysCleared() throws {
        let suite = "Clerestory.NotchSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalModulesEnabled = true
        XCTAssertEqual(settings.notchModuleID, .shelf)
        XCTAssertEqual(settings.notchCycleShortcut, .notchCycle)
        settings.notchModuleID = .battery
        settings.notchCycleShortcut = .init(keyCode: 17, command: true, shift: false, option: true, control: false)
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.notchModuleID, .battery)
        XCTAssertEqual(restored.notchCycleShortcut, settings.notchCycleShortcut)
        restored.notchCycleShortcut = nil
        XCTAssertNil(SettingsStore(defaults: defaults).notchCycleShortcut)
    }

    func testCycleDoesNotChangeExpandedSelectionAndActivitiesDoNotChangeChoice() throws {
        let suite = "Clerestory.NotchSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalModulesEnabled = true
        for id in IslandNotchDisplay.cycleOrder { settings.setIslandModuleEnabled(true, id: id) }
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .system)
        settings.notchModuleID = .battery
        coordinator.publish(.init(id: "timer", moduleID: .timer, priority: .timerFinished,
                                  title: "Timer finished", detail: nil, systemImage: "timer", expiresAt: nil))
        XCTAssertEqual(IslandNotchDisplay.selected(settings.notchModuleID,
            enabled: settings.islandModuleConfiguration.enabledModuleIDs), .battery)
        settings.cycleNotchModule()
        XCTAssertEqual(settings.notchModuleID, .media)
        XCTAssertEqual(coordinator.selectedModule, .system)
    }

    func testConflictsWithExistingShortcuts() throws {
        let suite = "Clerestory.NotchSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalModulesEnabled = true
        XCTAssertFalse(settings.notchCycleShortcutConflicts)
        settings.hotKeyEnabled = true
        settings.notchCycleShortcut = settings.hotKeyShortcut
        XCTAssertTrue(settings.notchCycleShortcutConflicts)
        settings.hotKeyEnabled = false
        XCTAssertFalse(settings.notchCycleShortcutConflicts)
        settings.notchCycleShortcut = settings.clipboardHistoryShortcut
        XCTAssertTrue(settings.notchCycleShortcutConflicts)
        settings.notchCycleShortcut = nil
        XCTAssertFalse(settings.notchCycleShortcutConflicts)
    }
}
