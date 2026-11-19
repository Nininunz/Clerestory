import XCTest
@testable import Clerestory

/// Trigger settings default values and persistence (SettingsStore's S7 field), as well as
/// TriggerSensitivity → recognition parameter gear mapping.
@MainActor
final class TriggerSettingsTests: XCTestCase {
    // MARK: - Helpers

    /// Independent UserDefaults suite to avoid polluting the app's own settings.
    private func makeSuite() throws -> (defaults: UserDefaults, name: String) {
        let name = "ClerestoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    // MARK: - Sensitivity mappings

    func testEdgeMappings_higherSensitivityMeansEasierTrigger() {
        XCTAssertGreaterThan(TriggerSensitivity.low.edgeDwellTime,
                             TriggerSensitivity.medium.edgeDwellTime)
        XCTAssertGreaterThan(TriggerSensitivity.medium.edgeDwellTime,
                             TriggerSensitivity.high.edgeDwellTime)
        XCTAssertLessThan(TriggerSensitivity.low.edgeBandWidth,
                          TriggerSensitivity.medium.edgeBandWidth)
        XCTAssertLessThan(TriggerSensitivity.medium.edgeBandWidth,
                          TriggerSensitivity.high.edgeBandWidth)
    }

    func testEdgeMappings_dragTunedValues() {
        // UX2: Drag scenarios (moving while holding left click and snapping to edges) have shorter dwell
        // time and wider bandwidth than hover scenarios.
        XCTAssertEqual(TriggerSensitivity.low.edgeDwellTime, 0.4)
        XCTAssertEqual(TriggerSensitivity.medium.edgeDwellTime, 0.2)
        XCTAssertEqual(TriggerSensitivity.high.edgeDwellTime, 0.1)
        XCTAssertEqual(TriggerSensitivity.low.edgeBandWidth, 6)
        XCTAssertEqual(TriggerSensitivity.medium.edgeBandWidth, 10)
        XCTAssertEqual(TriggerSensitivity.high.edgeBandWidth, 16)
    }

    // MARK: - SettingsStore defaults & persistence

    func testDefaults_matchPlanRiskTable() throws {
        // Plan §6: Shortcuts default on, edges default off, sensitivity default medium.
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.hotKeyEnabled)
        XCTAssertFalse(store.edgeTriggerEnabled)
        XCTAssertEqual(store.edgeTriggerSensitivity, .medium)
        XCTAssertEqual(store.hotKeyShortcut, .default)
        XCTAssertEqual(store.ignoredAppBundleIDs, [])
        // UX batch new items' default values: appear when dragged to the edge, double-click to copy to
        // clipboard, empty frame auto-hide.
        XCTAssertEqual(store.dragAutoAppearMode, .edgeOnly)
        XCTAssertTrue(store.hotKeyDoublePressSavesClipboard)
        XCTAssertTrue(store.autoHideWhenEmpty)
    }

    func testTriggerSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.hotKeyEnabled = false
        store.edgeTriggerEnabled = true
        store.edgeTriggerSensitivity = .low
        store.hotKeyShortcut = SettingsStore.HotKeyShortcut(
            keyCode: 3, command: true, shift: false, option: true, control: false
        )
        store.ignoredAppBundleIDs = ["com.apple.safari"]

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.hotKeyEnabled)
        XCTAssertTrue(reloaded.edgeTriggerEnabled)
        XCTAssertEqual(reloaded.edgeTriggerSensitivity, .low)
        XCTAssertEqual(reloaded.hotKeyShortcut,
                       SettingsStore.HotKeyShortcut(keyCode: 3, command: true,
                                                    shift: false, option: true, control: false))
        XCTAssertEqual(reloaded.ignoredAppBundleIDs, ["com.apple.safari"])
    }

    func testInvalidEdgeSensitivity_fallsBackToMedium() throws {
        // S7 previously stored placeholder values as Double; fallback to medium when reading old or dirty
        // values, without crashing.
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("garbage", forKey: "Clerestory.edgeTriggerSensitivity")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.edgeTriggerSensitivity, .medium)
    }

    // MARK: - UX batch: New settings persistence and migration

    func testUXSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.dragAutoAppearMode = .edgeOnly
        store.hotKeyDoublePressSavesClipboard = false
        store.autoHideWhenEmpty = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dragAutoAppearMode, .edgeOnly)
        XCTAssertFalse(reloaded.hotKeyDoublePressSavesClipboard)
        XCTAssertFalse(reloaded.autoHideWhenEmpty)
    }

    func testDragAutoAppearMode_invalidPersistedValue_fallsBackToEdgeOnly() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("garbage", forKey: "Clerestory.dragAutoAppearMode")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragAutoAppearMode, .edgeOnly)
    }

    func testDragAutoAppearMode_legacyEdgeTriggerEnabled_migratesToEdgeOnly() throws {
        // UX1 migration: Old boolean edge trigger switch was on and never persisted new mode → .edgeOnly.
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: "Clerestory.edgeTriggerEnabled")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragAutoAppearMode, .edgeOnly)

        // Migration immediately persisted: subsequent instances still read edgeOnly.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dragAutoAppearMode, .edgeOnly)
    }

    func testDragAutoAppearMode_explicitModeWinsOverLegacyFlag() throws {
        // Explicitly persisted new mode → old boolean switch no longer participates (migration occurs only
        // once).
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: "Clerestory.edgeTriggerEnabled")
        defaults.set("off", forKey: "Clerestory.dragAutoAppearMode")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragAutoAppearMode, .off)
    }
}
