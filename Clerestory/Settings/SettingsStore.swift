import Foundation
import ClerestoryModuleCore

/// UserDefaults-backed app settings, observable by SwiftUI.
///
/// All keys are prefixed with `Clerestory.` to avoid collisions. Defaults are
/// registered on init, so reads always return meaningful values. Trigger
/// settings are consumed by `HotKeyMonitor` (S7); the settings UI lives in
/// `SettingsView` (S8).
@MainActor
@Observable
final class SettingsStore {
    // MARK: - Value types

    /// Stable Island placement across multiple displays. `.main` follows the
    /// display designated as main in System Settings, `.automatic` preserves
    /// the legacy pointer/drag-following behavior, and `.display` pins one
    /// physical display using its ColorSync UUID.
    enum IslandDisplayTarget: Hashable, Sendable {
        case main
        case automatic
        case display(String)

        fileprivate var persistedValue: String {
            switch self {
            case .main: "main"
            case .automatic: "automatic"
            case let .display(id): "display:\(id)"
            }
        }

        fileprivate init(persistedValue: String?) {
            guard let persistedValue else {
                self = .main
                return
            }
            if persistedValue == "automatic" {
                self = .automatic
            } else if persistedValue == "main" {
                self = .main
            } else if persistedValue.hasPrefix("display:") {
                let id = String(persistedValue.dropFirst("display:".count))
                self = id.isEmpty ? .main : .display(id)
            } else {
                self = .main
            }
        }
    }

    /// What happens to an item after it is dragged out of the shelf.
    enum DragOutRemovalPolicy: String, CaseIterable, Sendable {
        case keep   // keep the item on the shelf
        case remove // remove it after a successful drop
        case ask    // ask every time (NSAlert in DragSessionController, S8)
    }

    /// Codable description of the global toggle hot key. Consumed by
    /// `HotKeyMonitor` (S7), which maps it to Carbon modifiers; the S8
    /// `ShortcutRecorderView` writes new values (and clears to nil).
    struct HotKeyShortcut: Codable, Equatable, Sendable {
        /// Hardware-independent virtual key code (kVK_*; 49 = Space).
        var keyCode: UInt32
        var command: Bool
        var shift: Bool
        var option: Bool
        var control: Bool

        /// ⌘⇧Space
        static let `default` = HotKeyShortcut(
            keyCode: 49, command: true, shift: true, option: false, control: false
        )
    }

    // MARK: - General

    var clipboardHistoryEnabled: Bool {
        didSet { defaults.set(clipboardHistoryEnabled, forKey: Keys.clipboardHistoryEnabled) }
    }

    var clipboardHistoryPaused: Bool {
        didSet { defaults.set(clipboardHistoryPaused, forKey: Keys.clipboardHistoryPaused) }
    }

    var clipboardHistoryRetentionDays: Int {
        didSet { defaults.set(clipboardHistoryRetentionDays, forKey: Keys.clipboardHistoryRetentionDays) }
    }

    var clipboardHistoryEntryLimit: Int {
        didSet { defaults.set(clipboardHistoryEntryLimit, forKey: Keys.clipboardHistoryEntryLimit) }
    }
    var clipboardHistoryShortcut: HotKeyShortcut? {
        didSet {
            if let data = try? JSONEncoder().encode(clipboardHistoryShortcut) {
                defaults.set(data, forKey: Keys.clipboardHistoryShortcut)
            }
        }
    }

    var notchModuleOrder: [IslandModuleID] = IslandNotchDisplay.cycleOrder {
        didSet {
            let normalized = notchModuleOrder.reduce(into: [IslandModuleID]()) { result, id in
                if IslandNotchDisplay.cycleOrder.contains(id), !result.contains(id) { result.append(id) }
            }
            if normalized != notchModuleOrder { notchModuleOrder = normalized }
            defaults.set(normalized.map(\.rawValue), forKey: Keys.notchModuleOrder)
        }
    }

    var effectiveNotchModuleOrder: [IslandModuleID] {
        notchModuleOrder.filter { isIslandModuleAvailable($0) && isIslandModuleEnabled($0) }
    }

    var notchDisplay: IslandNotchDisplay {
        IslandNotchDisplay.selected(notchModuleID, enabled: effectiveNotchModuleOrder,
                                      order: effectiveNotchModuleOrder)
    }

    func setNotchModuleIncluded(_ included: Bool, id: IslandModuleID) {
        if included {
            if !notchModuleOrder.contains(id) { notchModuleOrder.append(id) }
        } else {
            notchModuleOrder.removeAll { $0 == id }
        }
    }

    func moveNotchModule(_ id: IslandModuleID, to target: IslandModuleID) {
        guard let source = notchModuleOrder.firstIndex(of: id),
              let destination = notchModuleOrder.firstIndex(of: target), source != destination else { return }
        notchModuleOrder.remove(at: source)
        notchModuleOrder.insert(id, at: destination)
    }

    var notchModuleID: IslandModuleID = .shelf {
        didSet { defaults.set(notchModuleID.rawValue, forKey: Keys.notchModuleID) }
    }
    /// Off by default: any default would also claim its Shift variant for
    /// reverse cycling, and Control–Option–Space is macOS's input-source switch.
    var notchCycleShortcut: HotKeyShortcut? = nil {
        didSet {
            if let data = try? JSONEncoder().encode(notchCycleShortcut) {
                defaults.set(data, forKey: Keys.notchCycleShortcut)
            }
        }
    }
    var notchCycleShortcutError: String?
    private(set) var notchCycleBackwards = false

    var notchReverseCycleShortcut: HotKeyShortcut? {
        guard var shortcut = notchCycleShortcut else { return nil }
        shortcut.shift.toggle()
        return shortcut
    }

    var notchCycleShortcutConflicts: Bool {
        guard let shortcut = notchCycleShortcut else { return false }
        return [shortcut, notchReverseCycleShortcut].compactMap { $0 }.contains {
            (hotKeyEnabled && $0 == hotKeyShortcut) || (experimentalModulesEnabled && $0 == clipboardHistoryShortcut)
        }
    }

    func cycleNotchModule(backwards: Bool = false) {
        if let next = IslandNotchDisplay.next(after: notchModuleID,
                enabled: effectiveNotchModuleOrder, backwards: backwards, order: effectiveNotchModuleOrder) {
            notchCycleBackwards = backwards
            notchModuleID = next
        }
    }

    var showNotch: Bool {
        didSet { defaults.set(showNotch, forKey: Keys.showNotch) }
    }

    /// The Panel is the app's only surface, so it starts on at every launch. Tests turn it off
    /// to check the code that depends on it.
    var islandEnabled = true

    var menuBarIconEnabled: Bool {
        didSet { defaults.set(menuBarIconEnabled, forKey: Keys.menuBarIconEnabled) }
    }

    /// Legacy preference retained for compatibility; panel placement now follows the trigger display.
    var islandDisplayTarget: IslandDisplayTarget {
        didSet {
            defaults.set(islandDisplayTarget.persistedValue,
                         forKey: Keys.islandDisplayTarget)
        }
    }

    /// Shelf is an optional Island module. Turning it off never deletes shelf
    /// contents.
    var islandShelfEnabled: Bool {
        didSet {
            defaults.set(islandShelfEnabled, forKey: Keys.islandShelfEnabled)
            syncModuleConfigurationFromLegacy(.shelf, enabled: islandShelfEnabled)
        }
    }

    /// Hover and click reveal are independent. The menu, drag approach and
    /// global shortcut can still open Island when either is disabled.
    var islandHoverRevealEnabled: Bool {
        didSet { defaults.set(islandHoverRevealEnabled, forKey: Keys.islandHoverRevealEnabled) }
    }

    var islandClickRevealEnabled: Bool {
        didSet { defaults.set(islandClickRevealEnabled, forKey: Keys.islandClickRevealEnabled) }
    }

    /// Time the pointer must stay over the notch display before previewing it.
    var islandHoverDelaySeconds: Double {
        didSet { defaults.set(islandHoverDelaySeconds, forKey: Keys.islandHoverDelaySeconds) }
    }

    /// Grace period before a hover preview closes after the pointer leaves.
    var islandHoverLeaveDelaySeconds: Double {
        didSet { defaults.set(islandHoverLeaveDelaySeconds, forKey: Keys.islandHoverLeaveDelaySeconds) }
    }

    /// Expands the Island Shelf when a file or text drag approaches the top center.
    /// Independent of pointer hover.
    var islandDragApproachEnabled: Bool {
        didSet {
            defaults.set(islandDragApproachEnabled,
                         forKey: Keys.islandDragApproachEnabled)
        }
    }

    var islandTimerEnabled: Bool {
        didSet {
            defaults.set(islandTimerEnabled, forKey: Keys.islandTimerEnabled)
            syncModuleConfigurationFromLegacy(.timer, enabled: islandTimerEnabled)
        }
    }

    var islandBatteryEnabled: Bool {
        didSet {
            defaults.set(islandBatteryEnabled, forKey: Keys.islandBatteryEnabled)
            syncModuleConfigurationFromLegacy(.battery, enabled: islandBatteryEnabled)
        }
    }

    /// The Battery leaf opens macOS Battery settings instead of using the Low Power Mode helper.
    var lowPowerModeOpensSystemSettings = false {
        didSet { defaults.set(lowPowerModeOpensSystemSettings, forKey: Keys.lowPowerModeOpensSystemSettings) }
    }

    var islandFullChargeAlertEnabled: Bool {
        didSet {
            defaults.set(islandFullChargeAlertEnabled,
                         forKey: Keys.islandFullChargeAlertEnabled)
        }
    }

    /// AI usage module (data from TokenTracker): the number shown in the
    /// notch display while the module is enabled.
    var aiUsageNotchMetric: AIUsageNotchMetric {
        didSet { defaults.set(aiUsageNotchMetric.rawValue, forKey: Keys.aiUsageNotchMetric) }
    }

    /// Island alert when a plan limit crosses 80% / 95%.
    var aiUsageLimitAlertsEnabled: Bool {
        didSet { defaults.set(aiUsageLimitAlertsEnabled, forKey: Keys.aiUsageLimitAlertsEnabled) }
    }

    /// TokenTracker's local API port. No UI: only changes for a custom
    /// `tokentracker serve --port`.
    var aiUsageServerPort: Int {
        didSet { defaults.set(aiUsageServerPort, forKey: Keys.aiUsageServerPort) }
    }


    /// Optional local Now Playing module. It remains opt-in so a fallback
    /// player never requests Automation access until the user asks for media
    /// controls, while the UI itself is a first-class Island module.
    var islandMediaEnabled: Bool {
        didSet {
            defaults.set(islandMediaEnabled, forKey: Keys.islandMediaEnabled)
            syncModuleConfigurationFromLegacy(.media, enabled: islandMediaEnabled)
        }
    }

    /// Modules that are available without Experimental Modules.
    static let standardModuleIDs: Set<IslandModuleID> = [.shelf, .quickSettings, .battery]

    /// Opt-in availability for modules beyond the standard ones.
    var experimentalModulesEnabled = false {
        didSet { defaults.set(experimentalModulesEnabled, forKey: Keys.experimentalModulesEnabled) }
    }

    func isIslandModuleAvailable(_ id: IslandModuleID) -> Bool {
        Self.standardModuleIDs.contains(id) || experimentalModulesEnabled
    }

    /// Apply feature availability without rewriting the user's saved module choices.
    var effectiveIslandModuleConfiguration: IslandModuleConfiguration {
        effectiveIslandShortcuts
    }

    /// One expanded toolbar configuration on every display.
    var effectiveIslandShortcuts: IslandModuleConfiguration {
        var configuration = islandModuleConfiguration
        guard !experimentalModulesEnabled else { return configuration }
        for (index, id) in configuration.shortcutPositions.enumerated() {
            if let id, !isIslandModuleAvailable(id) { configuration.assignShortcut(nil, at: index) }
        }
        for id in configuration.enabledModuleIDs where !isIslandModuleAvailable(id) {
            configuration.setEnabled(false, for: id)
        }
        return configuration
    }

    /// Saved enablement and shortcut positions, independent of feature availability.
    var islandModuleConfiguration: IslandModuleConfiguration {
        didSet {
            persistIslandModuleConfiguration()
            applyConfigurationToLegacyProperties()
        }
    }

    func isIslandModuleEnabled(_ id: IslandModuleID) -> Bool {
        islandModuleConfiguration.isEnabled(id)
    }

    func isIslandModulePinned(_ id: IslandModuleID) -> Bool {
        islandModuleConfiguration.isPinned(id)
    }

    func setIslandModuleEnabled(_ enabled: Bool, id: IslandModuleID) {
        var configuration = islandModuleConfiguration
        configuration.setEnabled(enabled, for: id)
        islandModuleConfiguration = configuration
    }

    func setIslandModulePinned(_ pinned: Bool, id: IslandModuleID) {
        var configuration = islandModuleConfiguration
        configuration.setPinned(pinned, for: id)
        islandModuleConfiguration = configuration
    }

    func assignIslandShortcut(_ id: IslandModuleID?, at index: Int) {
        var configuration = islandModuleConfiguration
        configuration.assignShortcut(id, at: index)
        islandModuleConfiguration = configuration
    }

    func restoreDefaultIslandShortcuts() {
        islandModuleConfiguration = Self.defaultIslandShortcuts(
            enabled: islandModuleConfiguration.enabledModuleIDs)
    }

    /// Shelf, Quick Settings, then Battery when it is enabled.
    private static func defaultIslandShortcuts(enabled: [IslandModuleID]) -> IslandModuleConfiguration {
        expandedConfiguration(enabled: enabled, positions: [.shelf, .quickSettings, .battery])
    }

    private static func expandedConfiguration(enabled: [IslandModuleID], positions: [IslandModuleID?]) -> IslandModuleConfiguration {
        var configuration = IslandModuleConfiguration(enabledModuleIDs: enabled, pinnedModuleIDs: [])
        configuration.assignShortcut(.quickSettings, at: positions.firstIndex(of: .quickSettings) ?? 1)
        for (index, id) in positions.prefix(IslandModuleConfiguration.shortcutPositionCount).enumerated()
            where id != .quickSettings {
            configuration.assignShortcut(id, at: index)
        }
        return configuration
    }

    func movePinnedIslandModules(fromOffsets: IndexSet, toOffset: Int) {
        var configuration = islandModuleConfiguration
        configuration.movePinned(fromOffsets: fromOffsets, toOffset: toOffset)
        islandModuleConfiguration = configuration
    }

    /// What happens after an item is dragged out. Default: keep.
    var dragOutRemovalPolicy: DragOutRemovalPolicy {
        didSet { defaults.set(dragOutRemovalPolicy.rawValue, forKey: Keys.dragOutRemovalPolicy) }
    }


    /// Sparkle automatically checks for updates (the only network behavior). Default: true.
    /// Applied to SPUUpdater.automaticallyChecksForUpdates by UpdateController
    /// (once at launch + sync on UserDefaults change).
    var autoUpdateCheckEnabled: Bool {
        didSet { defaults.set(autoUpdateCheckEnabled, forKey: Keys.autoUpdateCheckEnabled) }
    }

    /// Completed/skipped Quick Look version. 0 means not completed; increment this value when adding new
    /// flows,
    /// no need to modify shelf persistence schema.
    var onboardingVersion: Int {
        didSet { defaults.set(onboardingVersion, forKey: Keys.onboardingVersion) }
    }

    /// Whether this key actually exists in the persistent preferences at launch. It is deliberately not
    /// included
    /// in `register(defaults:)`, allowing to distinguish between 'fresh install' and 'explicitly handled
    /// onboarding'.
    let hadPersistedOnboardingVersion: Bool

    // MARK: - Triggers (wired in S7; settings UI in S8)

    /// Global hot key (⌘⇧Space) toggles the shelf. Default: true.
    var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }

    /// UX3: double-pressing the global hot key saves the general pasteboard
    /// to the shelf. While enabled, a single press toggles the shelf after a
    /// short (~0.3 s) discrimination delay; disabling it restores zero-latency
    /// single presses. Default: true.
    var hotKeyDoublePressSavesClipboard: Bool {
        didSet { defaults.set(hotKeyDoublePressSavesClipboard, forKey: Keys.hotKeyDoublePressSavesClipboard) }
    }

    /// The toggle hot key, or nil when the user cleared it in the recorder
    /// (no shortcut assigned; `hotKeyEnabled` stays untouched so re-recording
    /// a shortcut re-arms the monitor without a separate toggle).
    ///
    /// Persisted as JSON. Three persisted states: key absent → `.default`
    /// (fresh install); JSON `null` → explicitly cleared; object → shortcut.
    var hotKeyShortcut: HotKeyShortcut? {
        didSet {
            // Encoding the Optional itself: a cleared shortcut persists as
            // top-level `null`, distinguishing it from "never customized".
            if let data = try? JSONEncoder().encode(hotKeyShortcut) {
                defaults.set(data, forKey: Keys.hotKeyShortcut)
            }
        }
    }

    // MARK: - Ignore list

    /// Bundle identifiers of apps in which drag triggers stay silent.
    var ignoredAppBundleIDs: [String] {
        didSet { defaults.set(ignoredAppBundleIDs, forKey: Keys.ignoredAppBundleIDs) }
    }

    /// Adds a bundle ID to the ignore list (settings page, S8). Trims
    /// whitespace and dedupes case-insensitively, mirroring the matching
    /// rules of `IgnoreListService.isIgnored`.
    func addIgnoredApp(bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let isDuplicate = ignoredAppBundleIDs.contains {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !isDuplicate else { return }
        ignoredAppBundleIDs.append(trimmed)
    }

    /// Removes entries from the ignore list (settings page, S8).
    func removeIgnoredApps(bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else { return }
        ignoredAppBundleIDs.removeAll { bundleIDs.contains($0) }
    }

    // MARK: - Init

    private let defaults: UserDefaults
    @ObservationIgnored private var isApplyingModuleConfiguration = false

    /// Shared persistence domain for feature stores that must follow the
    /// isolated UI-test/defaults suite instead of silently using `.standard`.
    var defaultsStore: UserDefaults { defaults }

    private enum Keys {
        private static let prefix = "Clerestory."
        static let clipboardHistoryEnabled = prefix + "clipboardHistoryEnabled"
        static let clipboardHistoryPaused = prefix + "clipboardHistoryPaused"
        static let clipboardHistoryRetentionDays = prefix + "clipboardHistoryRetentionDays"
        static let clipboardHistoryEntryLimit = prefix + "clipboardHistoryEntryLimit"
        // Keep legacy storage keys so the Notch rename preserves saved preferences.
        static let notchModuleOrder = prefix + "compactModuleOrder"
        static let notchModuleID = prefix + "compactModuleID"
        static let notchCycleShortcut = prefix + "compactCycleShortcut"
        static let clipboardHistoryShortcut = prefix + "clipboardHistoryShortcut"
        static let showNotch = prefix + "showCompactIsland"
        static let expandedShortcutsVersion = prefix + "expandedShortcutsVersion"
        static let menuBarIconEnabled = prefix + "menuBarIconEnabled"
        static let islandDisplayTarget = prefix + "islandDisplayTarget"
        static let islandShelfEnabled = prefix + "islandShelfEnabled"
        static let islandHoverRevealEnabled = prefix + "islandHoverRevealEnabled"
        static let islandClickRevealEnabled = prefix + "islandClickRevealEnabled"
        static let islandHoverDelaySeconds = prefix + "islandHoverDelaySeconds"
        static let islandHoverLeaveDelaySeconds = prefix + "islandHoverLeaveDelaySeconds"
        static let islandDragApproachEnabled = prefix + "islandDragApproachEnabled"
        static let islandTimerEnabled = prefix + "islandTimerEnabled"
        static let islandBatteryEnabled = prefix + "islandBatteryEnabled"
        static let islandFullChargeAlertEnabled = prefix + "islandFullChargeAlertEnabled"
        static let lowPowerModeOpensSystemSettings = prefix + "lowPowerModeOpensSystemSettings"
        static let islandMediaEnabled = prefix + "islandMediaEnabled"
        static let aiUsageNotchMetric = prefix + "aiUsageCompactMetric"
        static let aiUsageLimitAlertsEnabled = prefix + "aiUsageLimitAlertsEnabled"
        static let aiUsageServerPort = prefix + "aiUsageServerPort"
        static let experimentalModulesEnabled = prefix + "experimentalModulesEnabled"
        static let notchlessShortcutPositions = prefix + "notchlessShortcutPositions"
        static let islandModuleConfiguration = prefix + "islandModuleConfiguration"
        static let islandModuleConfigurationCorruptBackup =
            prefix + "islandModuleConfigurationCorruptBackup"
        static let dragOutRemovalPolicy = prefix + "dragOutRemovalPolicy"
        static let autoUpdateCheckEnabled = prefix + "autoUpdateCheckEnabled"
        static let onboardingVersion = prefix + "onboardingVersion"
        static let hotKeyEnabled = prefix + "hotKeyEnabled"
        static let hotKeyDoublePressSavesClipboard = prefix + "hotKeyDoublePressSavesClipboard"
        static let hotKeyShortcut = prefix + "hotKeyShortcut"
        static let ignoredAppBundleIDs = prefix + "ignoredAppBundleIDs"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hadPersistedOnboardingVersion = defaults.object(forKey: Keys.onboardingVersion) != nil
        let persistedModuleConfigurationData = defaults.data(
            forKey: Keys.islandModuleConfiguration
        )
        // Registration defaults are process-wide and leak into isolated test
        // suites. Only durable migration evidence may classify an install as
        // existing; v1.5 has onboardingVersion, while pre-release modular
        // builds may only have the versioned configuration blob.
        let hadPersistedAppSettings = hadPersistedOnboardingVersion
            || persistedModuleConfigurationData != nil
        defaults.register(defaults: [
            Keys.clipboardHistoryEnabled: false,
            Keys.clipboardHistoryPaused: false,
            Keys.clipboardHistoryRetentionDays: 7,
            Keys.menuBarIconEnabled: true,
            Keys.islandDisplayTarget: IslandDisplayTarget.main.persistedValue,
            Keys.islandShelfEnabled: true,
            Keys.islandHoverRevealEnabled: true,
            Keys.islandClickRevealEnabled: true,
            Keys.islandHoverDelaySeconds: 0.15,
            Keys.islandHoverLeaveDelaySeconds: 0.25,
            Keys.islandDragApproachEnabled: true,
            Keys.islandTimerEnabled: true,
            Keys.islandBatteryEnabled: true,
            Keys.islandFullChargeAlertEnabled: false,
            Keys.islandMediaEnabled: false,
            Keys.aiUsageNotchMetric: AIUsageNotchMetric.todayCost.rawValue,
            Keys.aiUsageLimitAlertsEnabled: true,
            Keys.aiUsageServerPort: TokenTrackerClient.defaultPort,
            Keys.dragOutRemovalPolicy: DragOutRemovalPolicy.keep.rawValue,
            Keys.autoUpdateCheckEnabled: true,
            Keys.hotKeyEnabled: true,
            Keys.hotKeyDoublePressSavesClipboard: true,
            Keys.ignoredAppBundleIDs: [String](),
        ])

        showNotch = defaults.object(forKey: Keys.showNotch) as? Bool ?? true
        experimentalModulesEnabled = defaults.bool(forKey: Keys.experimentalModulesEnabled)
        lowPowerModeOpensSystemSettings = defaults.bool(forKey: Keys.lowPowerModeOpensSystemSettings)
        clipboardHistoryEnabled = defaults.bool(forKey: Keys.clipboardHistoryEnabled)
        clipboardHistoryPaused = defaults.bool(forKey: Keys.clipboardHistoryPaused)
        let retentionDays = defaults.integer(forKey: Keys.clipboardHistoryRetentionDays)
        clipboardHistoryRetentionDays = [1, 7, 30].contains(retentionDays) ? retentionDays : 7
        let entryLimit = defaults.integer(forKey: Keys.clipboardHistoryEntryLimit)
        clipboardHistoryEntryLimit = ClipboardHistoryPolicy.supportedEntryLimits.contains(entryLimit) ? entryLimit : 30
        if let data = defaults.data(forKey: Keys.clipboardHistoryShortcut) {
            clipboardHistoryShortcut = (try? JSONDecoder().decode(HotKeyShortcut?.self, from: data)) ?? nil
        } else {
            clipboardHistoryShortcut = HotKeyShortcut(keyCode: 9, command: true, shift: true, option: false, control: false)
        }
        if let savedOrder = defaults.stringArray(forKey: Keys.notchModuleOrder) {
            notchModuleOrder = savedOrder.map(IslandModuleID.init(rawValue:)).reduce(into: []) { result, id in
                if IslandNotchDisplay.cycleOrder.contains(id), !result.contains(id) { result.append(id) }
            }
        }
        notchModuleID = defaults.string(forKey: Keys.notchModuleID).map(IslandModuleID.init(rawValue:)) ?? .shelf
        if let data = defaults.data(forKey: Keys.notchCycleShortcut) {
            notchCycleShortcut = (try? JSONDecoder().decode(HotKeyShortcut?.self, from: data)) ?? nil
        }
        menuBarIconEnabled = defaults.bool(forKey: Keys.menuBarIconEnabled)
        islandDisplayTarget = IslandDisplayTarget(
            persistedValue: defaults.string(forKey: Keys.islandDisplayTarget)
        )
        let resolvedIslandShelfEnabled = defaults.bool(forKey: Keys.islandShelfEnabled)
        islandShelfEnabled = resolvedIslandShelfEnabled
        let resolvedIslandHoverRevealEnabled = defaults.bool(
            forKey: Keys.islandHoverRevealEnabled
        )
        let resolvedIslandDragApproachEnabled = defaults.bool(
            forKey: Keys.islandDragApproachEnabled
        )
        let resolvedIslandTimerEnabled = defaults.bool(forKey: Keys.islandTimerEnabled)
        let resolvedIslandBatteryEnabled = defaults.bool(forKey: Keys.islandBatteryEnabled)
        let resolvedIslandFullChargeAlertEnabled = defaults.bool(
            forKey: Keys.islandFullChargeAlertEnabled
        )
        let resolvedIslandMediaEnabled = defaults.bool(forKey: Keys.islandMediaEnabled)
        islandHoverRevealEnabled = resolvedIslandHoverRevealEnabled
        islandClickRevealEnabled = defaults.bool(forKey: Keys.islandClickRevealEnabled)
        islandHoverDelaySeconds = min(max(defaults.double(forKey: Keys.islandHoverDelaySeconds), 0), 0.5)
        islandHoverLeaveDelaySeconds = min(max(defaults.double(forKey: Keys.islandHoverLeaveDelaySeconds), 0), 1)
        islandDragApproachEnabled = resolvedIslandDragApproachEnabled
        islandTimerEnabled = resolvedIslandTimerEnabled
        islandBatteryEnabled = resolvedIslandBatteryEnabled
        islandFullChargeAlertEnabled = resolvedIslandFullChargeAlertEnabled
        islandMediaEnabled = resolvedIslandMediaEnabled
        aiUsageNotchMetric = defaults.string(forKey: Keys.aiUsageNotchMetric)
            .flatMap(AIUsageNotchMetric.init(rawValue:)) ?? .todayCost
        aiUsageLimitAlertsEnabled = defaults.bool(forKey: Keys.aiUsageLimitAlertsEnabled)
        let storedPort = defaults.integer(forKey: Keys.aiUsageServerPort)
        aiUsageServerPort = (1...65535).contains(storedPort) ? storedPort : TokenTrackerClient.defaultPort
        let migratedModuleConfiguration = Self.migratedModuleConfiguration(
            existingInstallation: hadPersistedAppSettings,
            shelfEnabled: resolvedIslandShelfEnabled,
            timerEnabled: resolvedIslandTimerEnabled,
            batteryEnabled: resolvedIslandBatteryEnabled,
            mediaEnabled: resolvedIslandMediaEnabled
        )
        if let persistedModuleConfigurationData {
            do {
                var decoded = try JSONDecoder().decode(
                    IslandModuleConfiguration.self,
                    from: persistedModuleConfigurationData
                )
                decoded.normalize()
                islandModuleConfiguration = decoded
            } catch {
                islandModuleConfiguration = migratedModuleConfiguration
                if defaults.data(forKey: Keys.islandModuleConfigurationCorruptBackup) == nil {
                    defaults.set(persistedModuleConfigurationData,
                                 forKey: Keys.islandModuleConfigurationCorruptBackup)
                }
            }
        } else {
            islandModuleConfiguration = migratedModuleConfiguration
            if let encoded = try? JSONEncoder().encode(migratedModuleConfiguration) {
                defaults.set(encoded, forKey: Keys.islandModuleConfiguration)
            }
        }
        dragOutRemovalPolicy = DragOutRemovalPolicy(
            rawValue: defaults.string(forKey: Keys.dragOutRemovalPolicy) ?? ""
        ) ?? .keep
        autoUpdateCheckEnabled = defaults.bool(forKey: Keys.autoUpdateCheckEnabled)
        onboardingVersion = defaults.object(forKey: Keys.onboardingVersion) as? Int ?? 0
        hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
        hotKeyDoublePressSavesClipboard = defaults.bool(forKey: Keys.hotKeyDoublePressSavesClipboard)
        if let data = defaults.data(forKey: Keys.hotKeyShortcut) {
            // Explicit do/catch instead of `try? … ?? .default`: try? would flatten
            // 'decoding success as nil' (JSON null = explicit clear) and 'decoding failure'
            // into the same nil (SE-0230), and the cleared state would be swallowed.
            do {
                hotKeyShortcut = try JSONDecoder().decode(HotKeyShortcut?.self, from: data)
            } catch {
                hotKeyShortcut = .default
            }
        } else {
            hotKeyShortcut = .default
        }
        ignoredAppBundleIDs = defaults.stringArray(forKey: Keys.ignoredAppBundleIDs) ?? []
        let primaryConfigurationIsReadable = persistedModuleConfigurationData == nil
            || persistedModuleConfigurationData.flatMap { try? JSONDecoder().decode(IslandModuleConfiguration.self, from: $0) } != nil
        if defaults.integer(forKey: Keys.expandedShortcutsVersion) < 1, primaryConfigurationIsReadable {
            let floating = defaults.data(forKey: Keys.notchlessShortcutPositions)
                .flatMap { try? JSONDecoder().decode([IslandModuleID?].self, from: $0) }
            let positions = floating ?? islandModuleConfiguration.shortcutPositions.compactMap { $0 }.map(Optional.some)
            islandModuleConfiguration = Self.expandedConfiguration(
                enabled: islandModuleConfiguration.enabledModuleIDs, positions: positions)
            persistIslandModuleConfiguration()
            defaults.set(1, forKey: Keys.expandedShortcutsVersion)
        }
        // A valid primary configuration wins on every launch. Refresh the
        // one-release v1.5 shadow keys immediately, not only after the user
        // changes a module in this process.
        applyConfigurationToLegacyProperties()
    }

    private static func migratedModuleConfiguration(
        existingInstallation: Bool,
        shelfEnabled: Bool,
        timerEnabled: Bool,
        batteryEnabled: Bool,
        mediaEnabled: Bool
    ) -> IslandModuleConfiguration {
        if !existingInstallation {
            return defaultIslandShortcuts(enabled: [.shelf, .transfers, .timer, .battery, .system])
        }

        var enabled: [IslandModuleID] = []
        if shelfEnabled { enabled.append(.shelf) }
        if mediaEnabled { enabled.append(.media) }
        enabled.append(.transfers)
        if timerEnabled { enabled.append(.timer) }
        if batteryEnabled { enabled.append(.battery) }
        return IslandModuleConfiguration(
            enabledModuleIDs: enabled,
            pinnedModuleIDs: Array(enabled.prefix(
                IslandModuleConfiguration.maximumPinnedModules
            ))
        )
    }

    private func syncModuleConfigurationFromLegacy(_ id: IslandModuleID,
                                                    enabled: Bool) {
        guard !isApplyingModuleConfiguration else { return }
        var configuration = islandModuleConfiguration
        configuration.setEnabled(enabled, for: id)
        islandModuleConfiguration = configuration
    }

    private func persistIslandModuleConfiguration() {
        guard let data = try? JSONEncoder().encode(islandModuleConfiguration) else { return }
        defaults.set(data, forKey: Keys.islandModuleConfiguration)
    }

    private func applyConfigurationToLegacyProperties() {
        guard !isApplyingModuleConfiguration else { return }
        isApplyingModuleConfiguration = true
        defer { isApplyingModuleConfiguration = false }
        islandShelfEnabled = islandModuleConfiguration.isEnabled(.shelf)
        islandTimerEnabled = islandModuleConfiguration.isEnabled(.timer)
        islandBatteryEnabled = islandModuleConfiguration.isEnabled(.battery)
        islandMediaEnabled = islandModuleConfiguration.isEnabled(.media)
    }
}
