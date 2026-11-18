import AppKit
import OSLog
import Sparkle

/// Sparkle 2 auto-update packaging (SwiftPM introduced binary framework; feed hosted on GitHub Pages, DMG
/// published on GitHub Releases, see Scripts/make-release.sh).
///
/// Sandbox configuration basis (comments in Info.plist / entitlements also reference the original text):
/// - `SUEnableInstallerLauncherService = YES`: Sparkle sandbox documentation
///   "The Installer XPC Service is required for Sandboxed applications."
/// - `com.apple.security.network.client`: update checks are the application's only networking activity;
///   having it means the Downloader XPC is not enabled (same documentation: "…you should not enable the
///   Downloader XPC Service.")
/// - mach-lookup temporary exception (`-spks` / `-spki`): same documentation
///   "Communication" section, for Sparkle to communicate with its installer tool.
///
/// The only factual source of the 'Auto Check' switch is `SettingsStore.autoUpdateCheckEnabled`: it is
/// written once to SPUUpdater at start(), and runtime changes are synchronized via applySettings() (driven
/// by AppDelegate's UserDefaults.didChangeNotification, same mechanism as applyTriggerSettings). Sparkle
/// persists this property to SUEnableAutomaticChecks, so we don't need to write it back.
@MainActor
@Observable
final class UpdateController: NSObject {
    /// Stable fallback entry when automatic installation fails. Points to the latest page on GitHub
    /// instead of a specific DMG, ensuring users can manually obtain the current version even if the
    /// appcast or attachment URL is incorrect.
    static let manualDownloadURL = URL(
        string: "https://github.com/Nininunz/Clerestory/releases/latest"
    )!

    /// Summary of update check status (for logs and future UI display; the update prompt UI is handled by
    /// Sparkle's standard user driver).
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case error(String)
    }

    private(set) var status: Status = .idle

    private let settings: SettingsStore
    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "Update")

    /// UpdateController is lazily loaded by AppDelegate, so the updater controller can be created directly
    /// in init. startingUpdater: false, which is explicitly started by start() after settings are applied.
    /// The delegate of SPUUpdater can only be passed in during initialization (weak reference, no public
    /// setter), hence the use of DelegateBridge—bridge object is strongly held by self, satisfying the
    /// requirement that 'the caller is responsible for keeping the delegate alive'.
    private let updaterController: SPUStandardUpdaterController
    private let delegateBridge = DelegateBridge()
    private var didStart = false

    init(settings: SettingsStore) {
        self.settings = settings
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegateBridge,
            userDriverDelegate: nil
        )
        super.init()
        delegateBridge.owner = self
    }

    /// Menu item availability (Sparkle recommends for validating the timing of checkForUpdates; KVO
    /// property, here only for instantaneous reading, menu items remain always enabled—Sparkle itself
    /// ignores duplicate requests during an update check).
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    /// Start the updater (idempotent). Start regardless of whether the 'Auto Check' switch is on—manual
    /// 'Check for Updates...' also requires an already started updater; the switch only controls automatic
    /// scheduling. Apply settings to Sparkle once before start (its header comment also requires not to
    /// overwrite user preferences on every launch, here the written settings are the sole source of truth
    /// from our settings page, consistent in semantics).
    func start() {
        guard !didStart else { return }
        didStart = true
        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = settings.autoUpdateCheckEnabled
        do {
            try updater.start()
            logger.info("Sparkle updater started (automaticChecks: \(updater.automaticallyChecksForUpdates))")
        } catch {
            logger.error("Sparkle updater failed to start: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    /// Setting change → synchronize SUAutomaticallyChecksForUpdates. Do not write if the value is the
    /// same—writing would re-write UserDefaults and trigger didChange notification again, causing an
    /// unnecessary loop (same logic as the idempotent protection in applyTriggerSettings).
    func applySettings() {
        guard didStart else { return }
        let updater = updaterController.updater
        if updater.automaticallyChecksForUpdates != settings.autoUpdateCheckEnabled {
            updater.automaticallyChecksForUpdates = settings.autoUpdateCheckEnabled
        }
    }

    /// Menu entry 'Check for Updates...'. Can be manually triggered even if auto-check is off.
    func checkForUpdates() {
        start()
        status = .checking
        updaterController.checkForUpdates(nil)
    }

    func openManualDownloadPage() {
        NSWorkspace.shared.open(Self.manualDownloadURL)
    }

    // MARK: - Delegate callbacks forwarded by DelegateBridge

    fileprivate func noteUpdateNotFound() {
        status = .upToDate
    }

    /// Sparkle's 'no update available' also falls under the abort callback (SUSparkleErrorDomain /
    /// SUNoUpdateError = 1001, see Sparkle/SUErrors.h)—this is not an error, but categorized under
    /// upToDate (Sparkle itself does not log this, SPUUpdater.m:798).
    private static func isNoUpdateError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue
    }

    fileprivate func noteUpdateAborted(_ error: any Error) {
        guard !Self.isNoUpdateError(error) else {
            status = .upToDate
            return
        }
        status = .error(error.localizedDescription)
        logger.error("Sparkle update aborted: \(error.localizedDescription, privacy: .public)")
    }

    /// Update check cycle ends (including background auto-check). If error != nil → log error status;
    /// cases with no error and no update found are already covered by noteUpdateNotFound; if an update is
    /// found, the UI is already handed over to Sparkle, so set checking back to idle.
    fileprivate func noteUpdateCycleFinished(error: (any Error)?) {
        if let error, !Self.isNoUpdateError(error) {
            status = .error(error.localizedDescription)
            logger.error("Sparkle update cycle failed: \(error.localizedDescription, privacy: .public)")
        } else if error != nil {
            status = .upToDate
        } else if status == .checking {
            status = .idle
        }
    }
}

/// SPUUpdaterDelegate bridge: Sparkle only accepts delegates injected during initialization (weak
/// reference). Forward callbacks back to UpdateController (weak, same lifecycle as owner, controller holds
/// the bridge, updater weakly holds the bridge, no cycles). Sparkle calls back on the main thread;
/// nonisolated + Task returns to MainActor, following project conventions
/// (AppDelegate.userDefaultsDidChange).
private final class DelegateBridge: NSObject, SPUUpdaterDelegate {
    weak var owner: UpdateController?

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in self.owner?.noteUpdateNotFound() }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in self.owner?.noteUpdateAborted(error) }
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        Task { @MainActor in self.owner?.noteUpdateCycleFinished(error: error) }
    }
}
