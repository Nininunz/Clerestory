import XCTest
@testable import Clerestory

/// Trigger settings default values and persistence (SettingsStore's S7 fields).
@MainActor
final class TriggerSettingsTests: XCTestCase {
    // MARK: - Helpers

    /// Independent UserDefaults suite to avoid polluting the app's own settings.
    private func makeSuite() throws -> (defaults: UserDefaults, name: String) {
        let name = "ClerestoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    // MARK: - SettingsStore defaults & persistence

    func testDefaults_matchPlanRiskTable() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.hotKeyEnabled)
        XCTAssertEqual(store.hotKeyShortcut, .default)
        XCTAssertEqual(store.ignoredAppBundleIDs, [])
        XCTAssertTrue(store.hotKeyDoublePressSavesClipboard)
    }

    func testTriggerSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.hotKeyEnabled = false
        store.hotKeyDoublePressSavesClipboard = false
        store.hotKeyShortcut = SettingsStore.HotKeyShortcut(
            keyCode: 3, command: true, shift: false, option: true, control: false
        )
        store.ignoredAppBundleIDs = ["com.apple.safari"]

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.hotKeyEnabled)
        XCTAssertFalse(reloaded.hotKeyDoublePressSavesClipboard)
        XCTAssertEqual(reloaded.hotKeyShortcut,
                       SettingsStore.HotKeyShortcut(keyCode: 3, command: true,
                                                    shift: false, option: true, control: false))
        XCTAssertEqual(reloaded.ignoredAppBundleIDs, ["com.apple.safari"])
    }
}
