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
        XCTAssertEqual(positions, [.shelf, .quickSettings, nil, nil, nil, nil, nil, nil])
        XCTAssertEqual(store.islandModuleConfiguration.enabledModuleIDs, enabled)
        XCTAssertEqual(SettingsStore(defaults: defaults).islandModuleConfiguration.shortcutPositions, positions)
    }

    func testEdgeTabIconPreferencesPersistIndependentlyOfTabVisibility() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.edgeTabIconVisible)
        XCTAssertEqual(store.edgeTabIconSize, 10)
        store.edgeTabIconVisible = false
        store.edgeTabIconSize = 6

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.edgeTabIconVisible)
        XCTAssertEqual(reloaded.edgeTabIconSize, 6)
        XCTAssertTrue(reloaded.edgeTabEnabled, "Hiding the icon must not disable its handle")

        reloaded.edgeTabIconVisible = true
        XCTAssertEqual(SettingsStore(defaults: defaults).edgeTabIconSize, 6)
    }

    func testEdgeTabIconSizeNormalizesEditsAndPersistedValues() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        for (input, expected) in [(-10.0, 6.0), (100, 10), (.infinity, 10), (.nan, 10)] {
            store.edgeTabIconSize = input
            XCTAssertEqual(store.edgeTabIconSize, expected)
            XCTAssertEqual(SettingsStore(defaults: defaults).edgeTabIconSize, expected)
        }
        defaults.set(100, forKey: "Clerestory.edgeTabIconSize")
        XCTAssertEqual(SettingsStore(defaults: defaults).edgeTabIconSize, 10)
    }

    func testGeneralSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.shelfPosition = .left
        store.shelfWidth = 420
        store.autoHide = true
        store.keepShelfOpenAfterDrop = true
        store.dragOutRemovalPolicy = .ask

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.shelfPosition, .left)
        XCTAssertEqual(reloaded.shelfWidth, 420)
        XCTAssertTrue(reloaded.autoHide)
        XCTAssertTrue(reloaded.keepShelfOpenAfterDrop)
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
        XCTAssertEqual(store.shelfPosition, .right)
        XCTAssertEqual(store.shelfWidth, 320)
        XCTAssertFalse(store.autoHide)
        XCTAssertTrue(store.keepShelfOpenAfterDrop)
        XCTAssertEqual(store.dragOutRemovalPolicy, .keep)
        XCTAssertEqual(store.onboardingVersion, 0)
        XCTAssertFalse(store.hadPersistedOnboardingVersion)
        XCTAssertEqual(store.shelfPresentationMode, .island)
        XCTAssertEqual(store.shelfPlacement, .island)
        XCTAssertTrue(store.classicShelfEnabled)
        XCTAssertTrue(store.islandEnabled)
        XCTAssertTrue(store.menuBarIconEnabled)
        XCTAssertEqual(store.islandDisplayTarget, .main)
        XCTAssertTrue(store.islandShelfEnabled)
        XCTAssertEqual(store.preferredShelfSurface, .island)
        XCTAssertEqual(store.effectivePreferredShelfSurface, .island)
        XCTAssertTrue(store.islandHoverRevealEnabled)
        XCTAssertTrue(store.islandClickRevealEnabled)
        XCTAssertEqual(store.islandHoverDelaySeconds, 0.15)
        XCTAssertEqual(store.islandHoverLeaveDelaySeconds, 0.25)
        XCTAssertTrue(store.islandDragApproachEnabled)
        XCTAssertTrue(store.islandTimerEnabled)
        XCTAssertTrue(store.islandBatteryEnabled)
        XCTAssertFalse(store.islandMediaEnabled)
        XCTAssertFalse(store.isIslandModuleEnabled(.folders))
        XCTAssertFalse(store.isIslandModulePinned(.folders))
        XCTAssertEqual(store.islandModuleConfiguration.enabledModuleIDs,
                       [.shelf, .transfers, .timer, .battery, .system])
        XCTAssertEqual(store.islandModuleConfiguration.pinnedModuleIDs,
                       [.shelf])
        XCTAssertEqual(store.islandModuleConfiguration.shortcutPositions[0], .shelf)
        XCTAssertEqual(store.islandModuleConfiguration.shortcutPositions[1], .quickSettings)
        XCTAssertTrue(store.classicShelfHoverRevealEnabled)
    }

    func testExistingUserKeepsSuccessfulDropBehaviorWithoutNewPreference() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1, forKey: "Clerestory.onboardingVersion")
        defaults.set(true, forKey: "Clerestory.autoHide")
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.keepShelfOpenAfterDrop)
        XCTAssertTrue(store.autoHide, "Drag-out preference remains independent")
    }

    func testKeepShelfOpenAfterDrop_explicitFalseSurvivesReload() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        store.keepShelfOpenAfterDrop = false
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.keepShelfOpenAfterDrop)
        XCTAssertFalse(reloaded.autoHide)
        XCTAssertTrue(reloaded.autoHideWhenEmpty)
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
        XCTAssertTrue(store.classicShelfHoverRevealEnabled)
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

    func testIslandPlacementPreservesLastClassicPosition() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.shelfPosition = .left
        store.shelfPlacement = .island
        XCTAssertEqual(store.shelfPresentationMode, .island)
        XCTAssertEqual(store.shelfPosition, .left)

        store.shelfPlacement = .right
        XCTAssertEqual(store.shelfPresentationMode, .classic)
        XCTAssertEqual(store.shelfPosition, .right)
    }

    func testIslandSettingsPersistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.menuBarIconEnabled = false
        store.shelfPlacement = .island
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
        XCTAssertEqual(reloaded.shelfPresentationMode, .island)
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
        defaults.set(1, forKey: "Clerestory.shelfSurfaceSettingsVersion")
        defaults.set(false, forKey: "Clerestory.islandEnabled")
        defaults.set(false, forKey: "Clerestory.classicShelfEnabled")
        defaults.set(false, forKey: "Clerestory.showCompactIsland")

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.islandEnabled)
        XCTAssertFalse(store.showNotch)
        XCTAssertTrue(SettingsStore(defaults: defaults).islandEnabled)
    }

    func testSideShelfAndIslandPersistIndependently() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.classicShelfEnabled = true
        store.islandEnabled = true
        store.islandShelfEnabled = true
        store.preferredShelfSurface = .island

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.classicShelfEnabled)
        XCTAssertTrue(reloaded.islandEnabled)
        XCTAssertTrue(reloaded.islandShelfEnabled)
        XCTAssertEqual(reloaded.preferredShelfSurface, .island)
        XCTAssertEqual(reloaded.effectivePreferredShelfSurface, .island)

        reloaded.islandShelfEnabled = false
        XCTAssertTrue(reloaded.classicShelfEnabled)
        XCTAssertTrue(reloaded.islandEnabled)
        XCTAssertEqual(reloaded.preferredShelfSurface, .island)
        XCTAssertNil(reloaded.effectivePreferredShelfSurface)
    }

    func testLegacyIslandModeMigratesToIndependentSurfaceSettings() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("island", forKey: "Clerestory.shelfPresentationMode")

        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.classicShelfEnabled)
        XCTAssertTrue(store.islandEnabled)
        XCTAssertTrue(store.islandShelfEnabled)
        XCTAssertEqual(store.preferredShelfSurface, .island)
        XCTAssertEqual(store.effectivePreferredShelfSurface, .island)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.classicShelfEnabled)
        XCTAssertTrue(reloaded.islandEnabled)
        XCTAssertTrue(reloaded.islandShelfEnabled)
        XCTAssertEqual(reloaded.preferredShelfSurface, .island)
    }

    func testExistingClassicUserDoesNotInheritFreshInstallIslandDefault() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1, forKey: "Clerestory.onboardingVersion")

        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.classicShelfEnabled)
        XCTAssertTrue(store.islandEnabled)
        XCTAssertTrue(store.islandShelfEnabled)
        XCTAssertEqual(store.preferredShelfSurface, .classic)
    }

    func testEffectivePreferredSurfaceFallsBackWithoutOverwritingPreference() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.classicShelfEnabled = true
        store.islandEnabled = true
        store.islandShelfEnabled = true
        store.preferredShelfSurface = .island
        XCTAssertEqual(store.effectivePreferredShelfSurface, .island)

        store.islandEnabled = false
        XCTAssertNil(store.effectivePreferredShelfSurface)
        XCTAssertEqual(store.preferredShelfSurface, .island)

        store.classicShelfEnabled = false
        XCTAssertNil(store.effectivePreferredShelfSurface)

        store.islandEnabled = true
        XCTAssertEqual(store.effectivePreferredShelfSurface, .island)
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

    func testCustomShelfFrame_defaultsToNil() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertNil(SettingsStore(defaults: defaults).customShelfFrame)
    }

    func testCustomShelfFrame_persistsAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        let frame = CGRect(x: 120, y: 240, width: 360, height: 800)
        store.customShelfFrame = frame

        XCTAssertEqual(SettingsStore(defaults: defaults).customShelfFrame, frame)
    }

    func testCustomShelfFrame_clearedRemovesPersistedValue() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.customShelfFrame = CGRect(x: 0, y: 0, width: 320, height: 600)
        store.customShelfFrame = nil

        XCTAssertNil(SettingsStore(defaults: defaults).customShelfFrame)
    }

    func testCustomShelfFrame_corruptDataFallsBackToNil() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(Data([0x00, 0x01]), forKey: "Clerestory.customShelfFrame")
        XCTAssertNil(SettingsStore(defaults: defaults).customShelfFrame)
    }

    func testShelfPosition_customPersistsAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.shelfPosition = .custom

        XCTAssertEqual(SettingsStore(defaults: defaults).shelfPosition, .custom)
    }

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

    // MARK: - EdgeTab settings

    func testEdgeTabSettings_defaults() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        // Default vertical centering (maintain old visual appearance), pull ring default on.
        XCTAssertEqual(store.shelfEdgeOffset, 0.5)
        XCTAssertTrue(store.edgeTabEnabled)
    }

    func testEdgeTabSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.shelfEdgeOffset = 0.2
        store.edgeTabEnabled = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.shelfEdgeOffset, 0.2)
        XCTAssertFalse(reloaded.edgeTabEnabled)
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
}
