import XCTest
@testable import Clerestory

/// S8 face of SettingsStore: persistent round-trip for general settings, clearable shortcuts (Optional:
/// key missing → default; persistent null → clear explicitly), and ignore list editing helper
/// (deduplicate, trim, remove).
@MainActor
final class SettingsStoreTests: XCTestCase {
    /// Independent UserDefaults suite to avoid polluting the app's own settings.
    private func makeSuite() throws -> (defaults: UserDefaults, name: String) {
        let name = "ClerestoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    // MARK: - General settings persistence

    func testRestoreShortcutDefaultsPreservesEnabledModulesAndPersistsPositions() throws {
        let suite = "Clerestory.ShortcutDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.setIslandModuleEnabled(false, id: .timer)
        store.setIslandModuleEnabled(true, id: .aiUsage)
        store.assignIslandShortcut(.quickSettings, at: 0)
        store.assignIslandShortcut(.aiUsage, at: 6)
        let enabled = store.islandModuleConfiguration.enabledModuleIDs
        store.restoreDefaultIslandShortcuts()
        let positions = store.islandModuleConfiguration.shortcutPositions
        XCTAssertEqual(positions, [.shelf, .quickSettings, .battery, nil, nil, nil, nil, nil])
        XCTAssertEqual(store.islandModuleConfiguration.enabledModuleIDs, enabled)
        XCTAssertEqual(SettingsStore(defaults: defaults).islandModuleConfiguration.shortcutPositions, positions)

        store.setIslandModuleEnabled(false, id: .battery)
        store.restoreDefaultIslandShortcuts()
        XCTAssertEqual(store.islandModuleConfiguration.shortcutPositions,
                       [.shelf, .quickSettings, nil, nil, nil, nil, nil, nil])
    }

    func testGeneralSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.dragOutRemovalPolicy = .ask

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dragOutRemovalPolicy, .ask)
    }

    func testExplicitHoverOptOutSurvivesDefaultChange() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "Clerestory.islandHoverRevealEnabled")
        XCTAssertFalse(SettingsStore(defaults: defaults).islandHoverRevealEnabled)
    }

    func testGeneralSettings_defaults() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragOutRemovalPolicy, .keep)
        XCTAssertEqual(store.onboardingVersion, 0)
        XCTAssertFalse(store.hadPersistedOnboardingVersion)
        XCTAssertTrue(store.islandEnabled)
        XCTAssertTrue(store.menuBarIconEnabled)
        XCTAssertEqual(store.islandDisplayTarget, .main)
        XCTAssertTrue(store.islandShelfEnabled)
        XCTAssertTrue(store.islandHoverRevealEnabled)
        XCTAssertTrue(store.islandClickRevealEnabled)
        XCTAssertEqual(store.islandHoverDelaySeconds, 0.15)
        XCTAssertEqual(store.islandHoverLeaveDelaySeconds, 0.25)
        XCTAssertTrue(store.islandDragApproachEnabled)
        XCTAssertTrue(store.islandTimerEnabled)
        XCTAssertTrue(store.islandBatteryEnabled)
        XCTAssertFalse(store.islandMediaEnabled)
        XCTAssertFalse(store.isIslandModuleEnabled(.clipboard))
        XCTAssertFalse(store.isIslandModulePinned(.clipboard))
        XCTAssertEqual(store.islandModuleConfiguration.enabledModuleIDs,
                       [.shelf, .transfers, .timer, .battery, .system])
        XCTAssertEqual(store.islandModuleConfiguration.pinnedModuleIDs,
                       [.shelf, .battery])
        XCTAssertEqual(store.islandModuleConfiguration.shortcutPositions[0], .shelf)
        XCTAssertEqual(store.islandModuleConfiguration.shortcutPositions[1], .quickSettings)
        XCTAssertEqual(store.islandModuleConfiguration.shortcutPositions[2], .battery)
    }

    func testExistingUserMigratesLegacyModuleOrderWithoutEnablingSystem() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1, forKey: "Clerestory.onboardingVersion")
        defaults.set(true, forKey: "Clerestory.islandShelfEnabled")
        defaults.set(true, forKey: "Clerestory.islandMediaEnabled")
        defaults.set(true, forKey: "Clerestory.islandTimerEnabled")
        defaults.set(false, forKey: "Clerestory.islandBatteryEnabled")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.islandModuleConfiguration.enabledModuleIDs,
                       [.shelf, .media, .transfers, .timer])
        XCTAssertEqual(store.islandModuleConfiguration.pinnedModuleIDs,
                       [.shelf, .media, .transfers, .timer])
        XCTAssertFalse(store.isIslandModuleEnabled(.system))
    }

    func testUnknownModuleIDsSurviveReloadAndRuntimeEdits() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let unknown = IslandModuleID(rawValue: "future.weather")
        let configuration = IslandModuleConfiguration(
            enabledModuleIDs: [.shelf, unknown],
            pinnedModuleIDs: [unknown, .shelf]
        )
        defaults.set(try JSONEncoder().encode(configuration),
                     forKey: "Clerestory.islandModuleConfiguration")

        let store = SettingsStore(defaults: defaults)
        store.setIslandModuleEnabled(true, id: .timer)
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.isIslandModuleEnabled(unknown))
        XCTAssertTrue(reloaded.isIslandModulePinned(unknown))
    }

    func testPrimaryConfigurationShadowWritesLegacyBooleans() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)

        store.setIslandModuleEnabled(false, id: .timer)
        store.setIslandModuleEnabled(true, id: .media)

        XCTAssertFalse(defaults.bool(forKey: "Clerestory.islandTimerEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "Clerestory.islandMediaEnabled"))
    }

    func testLoadingPrimaryConfigurationRefreshesLegacyShadowKeys() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = IslandModuleConfiguration(
            enabledModuleIDs: [.transfers, .media], pinnedModuleIDs: [.media]
        )
        defaults.set(try JSONEncoder().encode(configuration),
                     forKey: "Clerestory.islandModuleConfiguration")
        defaults.set(true, forKey: "Clerestory.islandTimerEnabled")
        defaults.set(false, forKey: "Clerestory.islandMediaEnabled")

        _ = SettingsStore(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: "Clerestory.islandTimerEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "Clerestory.islandMediaEnabled"))
    }

    func testCorruptModuleConfigurationIsBackedUpWithoutBeingOverwritten() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let corrupt = Data([0x00, 0xCA, 0xFE])
        defaults.set(corrupt, forKey: "Clerestory.islandModuleConfiguration")

        let store = SettingsStore(defaults: defaults)

        XCTAssertFalse(store.islandModuleConfiguration.enabledModuleIDs.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "Clerestory.islandModuleConfiguration"), corrupt)
        XCTAssertEqual(defaults.data(forKey: "Clerestory.islandModuleConfigurationCorruptBackup"),
                       corrupt)
    }

    func testIslandSettingsPersistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.menuBarIconEnabled = false
        store.islandDisplayTarget = .display("display-uuid")
        store.islandHoverRevealEnabled = true
        store.islandClickRevealEnabled = false
        store.islandHoverDelaySeconds = 0.05
        store.islandHoverLeaveDelaySeconds = 0.8
        store.islandDragApproachEnabled = true
        store.islandTimerEnabled = false
        store.islandBatteryEnabled = false
        store.islandFullChargeAlertEnabled = true
        store.islandMediaEnabled = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.menuBarIconEnabled)
        XCTAssertEqual(reloaded.islandDisplayTarget, .display("display-uuid"))
        XCTAssertTrue(reloaded.islandHoverRevealEnabled)
        XCTAssertFalse(reloaded.islandClickRevealEnabled)
        XCTAssertEqual(reloaded.islandHoverDelaySeconds, 0.05)
        XCTAssertEqual(reloaded.islandHoverLeaveDelaySeconds, 0.8)
        XCTAssertTrue(reloaded.islandDragApproachEnabled)
        XCTAssertFalse(reloaded.islandTimerEnabled)
        XCTAssertFalse(reloaded.islandBatteryEnabled)
        XCTAssertTrue(reloaded.islandFullChargeAlertEnabled)
        XCTAssertTrue(reloaded.islandMediaEnabled)
    }

    func testLowBatteryWarningDefaultsToTwentyPersistsAndRejectsOtherValues() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.lowBatteryWarningPercent, 20)

        store.lowBatteryWarningPercent = 30
        XCTAssertEqual(SettingsStore(defaults: defaults).lowBatteryWarningPercent, 30)

        defaults.set(7, forKey: "Clerestory.lowBatteryWarningPercent")
        XCTAssertEqual(SettingsStore(defaults: defaults).lowBatteryWarningPercent, 20)
    }

    func testIslandDisplayTargetCanSwitchBackToAutomatic() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.islandDisplayTarget = .display("external-display")
        XCTAssertEqual(SettingsStore(defaults: defaults).islandDisplayTarget,
                       .display("external-display"))

        store.islandDisplayTarget = .automatic
        XCTAssertEqual(SettingsStore(defaults: defaults).islandDisplayTarget,
                       .automatic)
    }

    func testRetiredPanelToggleCannotDisablePanelOnRelaunch() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "Clerestory.islandEnabled")
        defaults.set(false, forKey: "Clerestory.showCompactIsland")

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.islandEnabled)
        XCTAssertFalse(store.showNotch)
        XCTAssertTrue(SettingsStore(defaults: defaults).islandEnabled)
    }

    func testOnboardingVersionPersistsAndKeepsExplicitState() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.onboardingVersion = 1

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.onboardingVersion, 1)
        XCTAssertTrue(reloaded.hadPersistedOnboardingVersion)
    }

    // MARK: - Custom shelf frame (S9)

    // MARK: - Clearable hot key shortcut

    func testHotKeyShortcut_absentKeyFallsBackToDefault() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(SettingsStore(defaults: defaults).hotKeyShortcut, .default)
    }

    func testHotKeyShortcut_clearedStateSurvivesReload() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.hotKeyShortcut = nil

        // ‘Clear’ must be an explicit state persistence (encoded as JSON null), not fallback to default
        // shortcuts.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertNil(reloaded.hotKeyShortcut)
    }

    func testHotKeyShortcut_recordingAfterClearRoundTrips() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.hotKeyShortcut = nil
        store.hotKeyShortcut = SettingsStore.HotKeyShortcut(
            keyCode: 8, command: true, shift: false, option: true, control: false
        )

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hotKeyShortcut,
                       SettingsStore.HotKeyShortcut(keyCode: 8, command: true,
                                                    shift: false, option: true, control: false))
    }

    // MARK: - Ignore list editing

    func testAddIgnoredApp_appendsNewBundleID() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addIgnoredApp(bundleID: "com.apple.safari")
        store.addIgnoredApp(bundleID: "com.google.Chrome")

        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari", "com.google.Chrome"])
    }

    func testAddIgnoredApp_dedupesCaseInsensitively() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addIgnoredApp(bundleID: "com.apple.safari")
        store.addIgnoredApp(bundleID: "COM.APPLE.SAFARI")

        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari"])
    }

    func testAddIgnoredApp_trimsWhitespaceAndRejectsEmpty() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addIgnoredApp(bundleID: "  com.apple.safari  ")
        store.addIgnoredApp(bundleID: "   ")
        store.addIgnoredApp(bundleID: "")

        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari"])
    }

    func testRemoveIgnoredApps_removesExactlyTheGivenIDs() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.ignoredAppBundleIDs = ["com.apple.safari", "com.google.Chrome", "com.apple.mail"]
        store.removeIgnoredApps(bundleIDs: ["com.google.Chrome"])
        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari", "com.apple.mail"])

        store.removeIgnoredApps(bundleIDs: [])
        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari", "com.apple.mail"])
    }

    func testIgnoreListEdits_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addIgnoredApp(bundleID: "com.apple.safari")
        store.addIgnoredApp(bundleID: "com.apple.mail")
        store.removeIgnoredApps(bundleIDs: ["com.apple.safari"])

        XCTAssertEqual(SettingsStore(defaults: defaults).ignoredAppBundleIDs, ["com.apple.mail"])
    }

    func testLowPowerModeSystemSettingsChoiceDefaultsOffAndPersists() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.lowPowerModeOpensSystemSettings)
        store.lowPowerModeOpensSystemSettings = true
        XCTAssertTrue(SettingsStore(defaults: defaults).lowPowerModeOpensSystemSettings)
    }
}
