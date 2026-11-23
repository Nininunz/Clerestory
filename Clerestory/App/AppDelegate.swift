import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let uiTestingDefaultsSuite = "com.nininunz.Clerestory.UITests"
    private static var isUITestingEnvironment: Bool {
        ProcessInfo.processInfo.environment["CLERESTORY_UI_TESTING"] == "1"
    }

    private static func makeSettingsDefaults() -> UserDefaults {
        guard isUITestingEnvironment else { return .standard }
        guard let defaults = UserDefaults(suiteName: uiTestingDefaultsSuite) else {
            fatalError("Unable to create the isolated UI-testing defaults suite")
        }
        defaults.removePersistentDomain(forName: uiTestingDefaultsSuite)
        return defaults
    }

    // Capture before SettingsStore migrations and services create persistent data.
    private static func makeStartupSettings() -> (settings: SettingsStore, hadLegacyInstall: Bool) {
        let defaults = makeSettingsDefaults()
        let domain = isUITestingEnvironment ? uiTestingDefaultsSuite
            : (Bundle.main.bundleIdentifier ?? "com.nininunz.Clerestory")
        let evidence = OnboardingLaunchPolicy.hasExistingInstallation(
            preferences: defaults.persistentDomain(forName: domain) ?? [:],
            supportEntries: (try? FileManager.default.contentsOfDirectory(
                atPath: AppDirectories.applicationSupport().path)) ?? []
        )
        return (SettingsStore(defaults: defaults), evidence)
    }

    private let startup = AppDelegate.makeStartupSettings()
    /// Persists Shelf changes as atomic JSON writes with a 500 ms debounce.
    private let persistence = PersistenceController()
    /// Creates and resolves security-scoped bookmarks and manages access for thumbnails and opening files.
    private let bookmarkService = BookmarkService()
    /// Stores files materialized from file promises and image data.
    private let tempFileService = TempFileService()
    /// Tracks crash recovery for managed Command-drops independently of shelf.json.
    /// Every materialized-file cleanup pass must protect paths referenced by the journal.
    private let managedMoveJournal = ManagedMoveJournal()
    /// v1.2: file-promise staging/finalization recovery. Lazy construction
    /// keeps its managed root identical to TempFileService in every build.
    private lazy var pendingImportJournal = PendingImportJournal(
        managedDirectoryURL: tempFileService.directoryURL
    )
    /// Holds the notice shown in the notice pill. It lives here because the drop import pipeline
    /// and the startup recovery notices need it before ShelfWindowController exists.
    private let messages = IslandMessageCenter()
    private var shelfMessenger: ModuleMessenger { messages.messenger(for: .shelf) }
    /// Share the active tutorial item token without coupling the lazy Shelf and onboarding objects.
    private let onboardingDragContext = OnboardingDragContext()
    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "App")
    private var isUITesting: Bool {
        Self.isUITestingEnvironment
    }
    /// Read shelf.json only once at startup. A failed read quarantines the corrupt
    /// file. Reading again would report it missing and could allow unsafe orphan cleanup.
    private lazy var initialShelfLoadResult = persistence.loadResult()
    /// Owns the Shelf item store that is injected into ShelfView.
    private lazy var shelfStore = ShelfStore(items: initialShelfLoadResult.items,
                                             persistence: persistence)
    /// Dispatches pasteboard data to Shelf items and reports failures as Shelf notices.
    private lazy var dropImportCoordinator = DropImportCoordinator(bookmarkService: bookmarkService,
                                                                   tempFileService: tempFileService,
                                                                   messenger: shelfMessenger,
                                                                   managedMoveJournal: managedMoveJournal,
                                                                   pendingImportJournal: pendingImportJournal)
    /// User settings shared with drag-session policy and injected into the SwiftUI Settings scene.
    var settingsStore: SettingsStore { startup.settings }
    lazy var clipboardHistoryStore: ClipboardHistoryStore = {
        let history = ClipboardHistoryStore(settings: settingsStore, messenger: messages.messenger(for: .clipboard))
        history.onAddToShelf = { [weak self] content in self?.addHistoryToShelf(content) }
        history.onShowWindow = { [weak self] in self?.clipboardHistoryWindowController.show() }
        return history
    }()
    private lazy var clipboardHistoryWindowController = ClipboardHistoryWindowController(
        history: clipboardHistoryStore, settings: settingsStore
    )
    /// Shared Settings navigation lets unavailable managed items open Storage directly.
    let settingsNavigation = SettingsNavigationModel()
    /// Login item status comes directly from SMAppService.
    let launchAtLoginController = LaunchAtLoginController()
    /// Recovery snapshots, managed storage usage, and safe cleanup for Settings → Storage.
    lazy var storageManagementController = StorageManagementController(
        persistence: persistence,
        tempFileService: tempFileService,
        shelfStore: shelfStore,
        managedMoveJournal: managedMoveJournal,
        pendingImportJournal: pendingImportJournal,
        bookmarkService: bookmarkService,
        additionalProtectedPaths: { [weak self] in
            (self?.deliveryCoordinator.protectedMaterializedPaths ?? [])
                .union(self?.shelfStore.undoProtectedPaths ?? [])
        },
        prepareRestoredItems: { [weak self] items in
            guard let self else { return items }
            return items.map { self.refreshedByResolvingBookmark($0) ?? $0 }
        }
    )
    /// Recent drag-outs are stored in memory and recents.json and shown in the menu bar.
    private let recentItemsService = RecentItemsService()
    /// v1.2: shared drag-out acceptance/promise-delivery coordinator. Storage
    /// cleanup consults its runtime file leases.
    private lazy var deliveryCoordinator = DeliveryCoordinator(
        store: shelfStore,
        recents: recentItemsService,
        tempFileService: tempFileService,
        transferStore: dropImportCoordinator.transferStore
    )
    /// Sparkle creates its updater controller on first start or manual check.
    /// The process shuts down its XPC connections and scheduler on exit.
    lazy var updateController = UpdateController(settings: settingsStore)
    /// Help, voluntary issue reporting and privacy-safe local diagnostics.
    lazy var supportController = SupportController(settings: settingsStore)

    private lazy var shelfWindowController: ShelfWindowController = ShelfWindowController(store: shelfStore,
                                                                   importCoordinator: dropImportCoordinator,
                                                                   messages: messages,
                                                                   tempFileService: tempFileService,
                                                                   settings: settingsStore,
                                                                   recents: recentItemsService,
                                                                   deliveryCoordinator: deliveryCoordinator,
                                                                   dragStartMonitor: dragStartMonitor,
                                                                   clipboardHistoryStore: clipboardHistoryStore,
                                                                   onOpenSettings: { [weak self] in
                                                                       self?.settingsWindowController.show(pane: .general)
                                                                   },
                                                                   onOpenModuleSettings: { [weak self] destination in
                                                                       self?.settingsWindowController.show(module: destination)
                                                                   },
                                                                   onOpenStorageRecovery: { [weak self] in
                                                                       self?.settingsWindowController.show(pane: .storage)
                                                                   },
                                                                   tutorialTokenForItem: { [weak self] itemID in
                                                                       self?.onboardingDragContext.token(for: itemID)
                                                                   })
    private lazy var shelfPresentationCoordinator = ShelfPresentationCoordinator(
        windowController: shelfWindowController
    )
    private lazy var onboardingController = OnboardingController(
        settings: settingsStore,
        shelfStore: shelfStore,
        shelfWindowController: shelfWindowController,
        importCoordinator: dropImportCoordinator,
        dragContext: onboardingDragContext
    )
    private lazy var settingsWindowController = SettingsWindowController(settings: settingsStore,
                                                                         hotKeyMonitor: hotKeyMonitor,
                                                                         launchAtLoginController: launchAtLoginController,
                                                                         updateController: updateController,
                                                                         storageManagementController: storageManagementController,
                                                                         navigation: settingsNavigation,
                                                                         supportController: supportController,
                                                                         clipboardHistoryStore: clipboardHistoryStore)
    private lazy var menuBarController = MenuBarController(
        settings: settingsStore,
        isShelfExpanded: { [weak self] in
            self?.shelfPresentationCoordinator.isExpanded ?? false
        },
        recents: recentItemsService,
        onToggleShelf: { [weak self] in
            self?.toggleShelf()
        },
        onReaddRecent: { [weak self] entry in
            self?.readdRecent(entry)
        },
        onShowSettings: { [weak self] in
            self?.settingsWindowController.show()
        },
        onShowQuickStart: { [weak self] in
            self?.onboardingController.replay()
        },
        onOpenHelp: { [weak self] in
            self?.supportController.openHelp()
        },
        onReportIssue: { [weak self] in
            self?.supportController.reportIssue()
        },
        onCheckForUpdates: { [weak self] in
            self?.updateController.checkForUpdates()
        },
        onOpenManualUpdate: { [weak self] in
            self?.updateController.openManualDownloadPage()
        },
        onShowClipboardHistory: { [weak self] in
            self?.clipboardHistoryWindowController.show()
        },
        onAddClipboardImage: { [weak self] in
            self?.addClipboardImageToShelf()
        }
    )

    /// Registers global shortcuts using Carbon, with an NSEvent monitor as fallback.
    /// Settings shows registration errors. One press toggles Shelf. An optional double press
    /// within about 0.3 seconds saves the clipboard to Shelf.
    lazy var hotKeyMonitor = HotKeyMonitor(
        shortcut: settingsStore.hotKeyShortcut,
        onPress: { [weak self] in
            self?.toggleShelfForKeyboard()
        },
        onDoublePress: { [weak self] in
            self?.saveClipboardToShelf()
        }
    )
    lazy var notchCycleHotKeyMonitor = HotKeyMonitor(
        shortcut: settingsStore.notchCycleShortcut, hotKeyIdentifier: 3,
        onPress: { [weak self] in self?.settingsStore.cycleNotchModule() },
        onDoublePress: {}
    )
    lazy var notchReverseCycleHotKeyMonitor = HotKeyMonitor(
        shortcut: settingsStore.notchReverseCycleShortcut, hotKeyIdentifier: 4,
        onPress: { [weak self] in self?.settingsStore.cycleNotchModule(backwards: true) },
        onDoublePress: {}
    )
    lazy var clipboardHotKeyMonitor = HotKeyMonitor(
        shortcut: settingsStore.clipboardHistoryShortcut, hotKeyIdentifier: 2,
        onPress: { [weak self] in self?.clipboardHistoryWindowController.show() },
        onDoublePress: {}
    )
    /// Tracks drag start after pointer travel crosses the threshold and drag end on mouse-up.
    /// It stays registered while the Panel can open for a drag.
    private lazy var dragStartMonitor = DragStartMonitor(shouldSuppress: { [weak self] in
        guard let self else { return false }
        return IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onDragStart: { [weak self] in
        self?.handleDragStart()
    }, onPotentialDragChange: { [weak self] active in
        self?.shelfWindowController.setIslandDragZoneActive(active)
    }, onNativeDragUpdate: { [weak self] point in
        self?.handleDragUpdate(at: point)
    }, onDragEnd: { [weak self] in
        self?.handleDragEnd()
    })
    /// Decides when a Panel the drag opened learns how the drag ended.
    private var islandDragEndSession = IslandDragEndSession()
    private var islandDragEndTimeout: Task<Void, Never>?
    private var noticeRevisionBeforeDrag: UInt64 = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        if isUITesting {
            settingsStore.islandEnabled = true
            settingsStore.showNotch = !ProcessInfo.processInfo.arguments.contains("--ui-testing-hide-compact")
            settingsStore.islandHoverRevealEnabled = ProcessInfo.processInfo.arguments.contains("--ui-testing-hover")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Check for existing data before Sparkle or new preferences can make a fresh install
        // look like an upgrade from a version that predates onboardingVersion.
        let hasLegacyInstallEvidence = legacyInstallEvidence()
        _ = menuBarController
        if !isUITesting && settingsStore.experimentalModulesEnabled { clipboardHistoryStore.start() }
        // Start Sparkle after applying the automatic update preference. Startup is idempotent.
        if !isUITesting {
            updateController.start()
        }
        // Count successful drops and clipboard saves so a Panel the drag opened stays open after import.
        dropImportCoordinator.onImportHandled = { [weak self] in
            self?.islandDragEndSession.noteImport()
        }
        shelfWindowController.onIslandDestinationEntered = { [weak self] sequenceNumber in
            self?.islandDragEndSession.destinationEntered(sequenceNumber: sequenceNumber)
        }
        shelfWindowController.onIslandDestinationEnded = { [weak self] sequenceNumber, accepted in
            guard let self else { return }
            self.applyIslandDragEnd(
                self.islandDragEndSession.destinationEnded(sequenceNumber: sequenceNumber, accepted: accepted)
            )
        }
        if !isUITesting {
            applyTriggerSettings()
        }
        shelfPresentationCoordinator.applyCurrentMode(animated: false)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(userDefaultsDidChange(_:)),
                                               name: UserDefaults.didChangeNotification,
                                               object: nil)
        // Recover unfinished managed Command-drops before resolving bookmarks
        // or cleaning up orphans. A managed copy may still be awaiting its Shelf record.
        recoverManagedMoveTransactions()
        reconcilePendingImports()
        // Resolve saved bookmarks first so cleanup uses current paths. Mark unresolved
        // items unavailable and recreate stale bookmarks with their updated paths.
        resolvePersistedBookmarks()
        // Only clean up orphans when shelf.json was read successfully or was absent
        // and no quarantined recovery snapshot remains. A failed read leaves the store
        // empty, so using it for cleanup could delete every managed file. Preserve
        // Materialized across restarts while a recovery snapshot still exists.
        if !persistence.canSafelyCleanupMaterializedOrphans(after: initialShelfLoadResult)
            || !managedMoveJournal.permitsManagedOrphanCleanup
            || !pendingImportJournal.permitsOrphanCleanup {
            logger.warning("Skipping materialized orphan cleanup because shelf recovery data is present or persistence could not be trusted")
        } else {
            cleanupMaterializedOrphans()
        }
        // Staging cleanup is independent of the Shelf load result. It sweeps
        // PromiseStaging directories older than an hour and protects pending imports.
        tempFileService.cleanupStaleStagingDirectories(
            keepingPaths: pendingImportJournal.protectedPaths()
        )
        // Start onboarding after loading Shelf, recovering transactions, resolving
        // bookmarks, and cleaning up. Only then can onboarding trust an empty Shelf.
        if isUITesting && !ProcessInfo.processInfo.arguments.contains("--ui-testing-onboarding") {
            presentRequestedUITestSurface()
        } else {
            onboardingController.startAtLaunch(
                hasLegacyInstallEvidence: hasLegacyInstallEvidence
            )
        }
        #if DEBUG
        DebugTestMessages.center = messages
        #endif
    }

    private func presentRequestedUITestSurface() {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        if arguments.contains("--ui-testing-shelf-files") {
            do {
                let fixture = try ShelfUITestFixture()
                fixture.seed(shelfStore)
            } catch {
                fatalError("Unable to create isolated Shelf UI fixtures: \(error)")
            }
        }
        if arguments.contains("--ui-testing-drag-source") { dragStartMonitor.start() }
        #endif
        if arguments.contains("--ui-testing-open-settings") {
            settingsWindowController.show(pane: .general)
        } else if arguments.contains("--ui-testing-show-shelf") {
            shelfWindowController.showIslandShelf(takeKeyboardFocus: true)
        }
    }

    /// Reopening the running app from Finder, Launchpad, or Spotlight opens Settings.
    /// This gives users an entry point when macOS hides the menu bar icon for lack of space.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindowController.show()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        clipboardHistoryStore.stop()
        guard let save = clipboardHistoryStore.finalSave() else { return .terminateNow }
        // The quit can be requested from a block on the main dispatch queue, as Sparkle does
        // before relaunching. AppKit then waits for the reply inside that block, so the save
        // runs off the main actor and the reply goes through the main run loop (#123).
        Task.detached {
            await save()
            MainRunLoop.perform { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardHistoryStore.stop()
        shelfPresentationCoordinator.shutdown()
        onboardingController.applicationWillTerminate()
        do {
            try persistence.saveNow(shelfStore.items)
            reconcileCommittedManagedMoves()
            reconcilePendingImports()
        } catch {
            // Keep recovery transactions when durability cannot be proven.
            logger.error("Failed to synchronously save shelf during termination: \(error.localizedDescription, privacy: .public)")
        }
        bookmarkService.stopAccessingAll()
        hotKeyMonitor.setEnabled(false)
        clipboardHotKeyMonitor.setEnabled(false)
        notchCycleHotKeyMonitor.setEnabled(false)
        notchReverseCycleHotKeyMonitor.setEnabled(false)
        dragStartMonitor.stop()
    }

    /// Older versions have no onboardingVersion key. Check persisted preferences or existing
    /// Application Support data from before startup writes. Registered defaults and the Tutorial
    /// directory alone do not count as evidence of an upgrade.
    private func legacyInstallEvidence() -> Bool {
        switch initialShelfLoadResult {
        case .loaded, .failed:
            return true
        case .missing:
            break
        }

        return startup.hadLegacyInstall
    }

    func toggleShelf() {
        shelfPresentationCoordinator.toggle(animated: true)
    }

    private func toggleShelfForKeyboard() {
        shelfPresentationCoordinator.toggleForKeyboard(animated: true)
    }

    // MARK: - Drag-driven Panel

    /// Start tracking a confirmed drag after it crosses the movement threshold.
    private func handleDragStart() {
        // End a Panel drag still waiting for its destination before the notice baseline moves.
        applyIslandDragEnd(islandDragEndSession.dragBegan())
        noticeRevisionBeforeDrag = messages.noticeRevision(for: .shelf)
    }

    private func handleDragUpdate(at point: CGPoint) {
        guard settingsStore.islandEnabled,
              settingsStore.islandShelfEnabled else { return }
        if shelfPresentationCoordinator.dragApproachedTop(at: point) {
            islandDragEndSession.markPanelActivated()
        }
    }

    /// Mouse-up ends the drag. Successful imports, including queued materialization, are
    /// recorded through onImportHandled and noteImport.
    private func handleDragEnd() {
        applyIslandDragEnd(islandDragEndSession.mouseUp())
    }

    /// Ends the drag for a Panel the drag opened once mouse-up and any Panel destination that
    /// saw the drag have both finished. The drop can reach the Panel after mouse-up, so
    /// deciding at mouse-up would miss the import and collapse the Panel.
    private func applyIslandDragEnd(_ step: IslandDragEndSession.Step) {
        switch step {
        case .noAction:
            return
        case .awaitDestination(let generation):
            islandDragEndTimeout?.cancel()
            islandDragEndTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: IslandDragEndSession.destinationTimeout)
                guard !Task.isCancelled, let self else { return }
                self.applyIslandDragEnd(self.islandDragEndSession.destinationTimedOut(generation: generation))
            }
        case .endDrag(let imported):
            islandDragEndTimeout?.cancel()
            islandDragEndTimeout = nil
            shelfPresentationCoordinator.dragEnded(
                imported: imported,
                // Only Shelf feedback from this drag collapses the panel the drag opened.
                hasPendingNotice: messages.hasNewCurrentNotice(from: .shelf, since: noticeRevisionBeforeDrag)
            )
        }
    }

    // MARK: - UX3 clipboard save

    /// "Add Clipboard Image to Shelf" adds only the clipboard's image and reveals Shelf to show
    /// it. With no image, the Shelf stays closed and the notice shows under the notch.
    private func addClipboardImageToShelf() {
        let scheduled = dropImportCoordinator.importClipboardImages(from: .general) { [weak self] item in
            self?.shelfStore.add(item)
        }
        switch ClipboardImageImportOutcome(scheduledCount: scheduled) {
        case .showShelf:
            shelfPresentationCoordinator.show(animated: true)
        case .notice(let notice):
            shelfMessenger.post(notice)
        }
    }

    /// A double press uses the drop import pipeline for clipboard files, images, URLs, and text.
    /// A successful import reveals Shelf. If there is nothing to import, show the existing notice
    /// only when Shelf is already visible.
    private func saveClipboardToShelf() {
        let result = dropImportCoordinator.importItems(from: .general) { [weak self] item in
            self?.shelfStore.add(item)
        }
        guard result.handled else {
            if shelfPresentationCoordinator.isExpanded {
                shelfMessenger.post(.clipboardEmpty)
            }
            return
        }
        shelfStore.add(contentsOf: result.items)
        shelfPresentationCoordinator.show(animated: true)
    }

    // MARK: - Recent items re-add (S10)

    private func addHistoryToShelf(_ content: ClipboardHistoryEntry.Content) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        switch content {
        case .text(let value): item.setString(value, forType: .string)
        case .url(let value): item.setString(value, forType: .URL)
        // Pass the stored bytes; the importer writes the image off the main actor.
        case .image(let data, let type): item.setData(data, forType: .init(type))
        }
        pasteboard.writeObjects([item])
        let result = dropImportCoordinator.importItems(from: pasteboard) { [weak self] item in
            self?.shelfStore.add(item)
        }
        guard result.handled else { return }
        shelfStore.add(contentsOf: result.items)
        shelfPresentationCoordinator.show(animated: true)
    }

    /// Re-add a recent item from the menu bar. Files get a new bookmark after the menu checks
    /// access through canReadd. URLs are restored directly. Text and stacks are disabled in
    /// the menu. Reveal Shelf after re-adding an item.
    private func readdRecent(_ entry: RecentEntry) {
        switch entry.kind {
        case .file, .folder, .image:
            guard let path = entry.path else { return }
            let item = DropImportCoordinator.makeFileBackedItem(
                for: URL(fileURLWithPath: path),
                displayName: entry.displayName,
                bookmarkService: bookmarkService,
                logger: logger
            )
            shelfStore.add(item)
        case .url:
            guard let urlString = entry.urlString else { return }
            shelfStore.add(ShelfItem(kind: .url,
                                     displayName: entry.displayName,
                                     urlString: urlString))
        case .text, .stack:
            return
        }
        shelfPresentationCoordinator.show(animated: true)
    }

    // MARK: - Bookmark resolution at launch (S4)

    /// Resolve saved bookmarks at startup.
    /// - An unavailable external reference can be relinked by the user.
    /// - A missing managed copy is handled through Storage and recovery.
    /// - Refresh a stale bookmark and update the stored path when resolution succeeds.
    /// - Resolve stack children recursively.
    private func resolvePersistedBookmarks() {
        for item in shelfStore.items {
            if let refreshed = refreshedByResolvingBookmark(item) {
                shelfStore.update(refreshed)
            }
        }
    }

    /// Return an updated item only when it changed. Process stack children recursively.
    private func refreshedByResolvingBookmark(_ item: ShelfItem) -> ShelfItem? {
        let result = ItemAvailabilityResolver.refresh(
            item,
            bookmarkService: bookmarkService
        )
        return result.item == item ? nil : result.item
    }

    // MARK: - Materialized file cleanup (S4)

    /// Reconciles crash-recovery transactions before any materialized cleanup.
    /// Any surviving managed copy is restored as the authoritative `isCut`
    /// item. The source path may have been recreated after a crash, so its mere
    /// existence cannot prove that trashing never happened. Only when the
    /// managed copy is gone do we fall back to the source reference. Nothing is
    /// mutated while shelf persistence is untrusted.
    private func recoverManagedMoveTransactions() {
        let loadResult = managedMoveJournal.loadResult()
        guard case .loaded(let records) = loadResult, !records.isEmpty else {
            if loadResult == .failed {
                shelfMessenger.post(.moveRecoveryNeedsAttention)
            }
            return
        }

        var recoveredItems = shelfStore.items
        var resolved: [ManagedMoveJournal.Record] = []
        var unresolvedCount = 0
        let fileManager = FileManager.default
        let persistenceIsTrusted = persistence.canSafelyCleanupMaterializedOrphans(
            after: initialShelfLoadResult
        )
        let persistedItemIDs = itemIDs(in: shelfStore.items)

        for record in records {
            let sourceExists = record.referenceItem.path.map(fileManager.fileExists(atPath:)) ?? false
            let managedExists = record.managedItem.path.map(fileManager.fileExists(atPath:)) ?? false
            let decision = ManagedMoveRecoveryPlanner.decision(
                for: record,
                sourceExists: sourceExists,
                managedExists: managedExists,
                persistedItemIDs: persistedItemIDs
            )

            if decision == .alreadyCommitted {
                // A crash after shelf save but before journal deletion needs no
                // content mutation.
                try? managedMoveJournal.remove(id: record.id)
                continue
            }
            guard persistenceIsTrusted else {
                logger.warning("Deferring managed move recovery because shelf persistence is not trusted")
                unresolvedCount += 1
                continue
            }

            let itemToRecover: ShelfItem
            switch decision {
            case .recoverReference:
                itemToRecover = record.referenceItem
            case .recoverManaged:
                itemToRecover = record.managedItem
            case .alreadyCommitted:
                continue
            case .unresolved:
                unresolvedCount += 1
                continue
            }
            if !containsItem(id: itemToRecover.id, in: recoveredItems) {
                recoveredItems.append(itemToRecover)
            }
            resolved.append(record)
        }

        if !resolved.isEmpty {
            do {
                try persistence.saveNow(recoveredItems)
                shelfStore.replaceWithPersistedItems(recoveredItems)
                for record in resolved {
                    try? managedMoveJournal.remove(id: record.id)
                }
                shelfMessenger.post(.moveRecovered)
            } catch {
                logger.error("Failed to persist recovered managed moves: \(error.localizedDescription, privacy: .public)")
                unresolvedCount += resolved.count
            }
        }

        if unresolvedCount > 0 {
            shelfMessenger.post(.partialMoveRecoveryNeedsAttention)
        }
    }

    /// Normal termination flushes shelf.json first, then clears any journal
    /// records whose managed/reference item is now durable. Crashes leave the
    /// records intact for `recoverManagedMoveTransactions`.
    private func reconcileCommittedManagedMoves() {
        guard case .loaded(let records) = managedMoveJournal.loadResult() else { return }
        for record in records where shelfContainsItem(id: record.managedItem.id)
            || shelfContainsItem(id: record.referenceItem.id) {
            try? managedMoveJournal.remove(id: record.id)
        }
    }

    /// Removes only records whose stable id is already present in the loaded
    /// shelf. All other records remain available in Settings > Storage for an
    /// explicit retry; startup never guesses that an incomplete import should
    /// silently create a card.
    private func reconcilePendingImports() {
        switch pendingImportJournal.loadResult() {
        case .loaded(let records):
            var remainingCount = 0
            for record in records {
                if shelfContainsItem(id: record.id) {
                    do {
                        try pendingImportJournal.remove(id: record.id)
                    } catch {
                        logger.error("Failed to reconcile completed pending import \(record.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    remainingCount += 1
                }
            }
            if remainingCount > 0 {
                shelfMessenger.post(.interruptedImportRecovered)
            }
        case .failed:
            shelfMessenger.post(.importRecoveryNeedsAttention)
        case .missing:
            break
        }
    }

    private func shelfContainsItem(id: UUID) -> Bool {
        containsItem(id: id, in: shelfStore.items)
    }

    private func containsItem(id: UUID, in items: [ShelfItem]) -> Bool {
        items.contains { item in
            item.id == id || containsItem(id: id, in: item.children ?? [])
        }
    }

    private func itemIDs(in items: [ShelfItem]) -> Set<UUID> {
        var ids = Set<UUID>()
        for item in items {
            ids.insert(item.id)
            ids.formUnion(itemIDs(in: item.children ?? []))
        }
        return ids
    }

    /// Remove orphaned materialized files while preserving files referenced by
    /// Shelf items, including stack children.
    private func cleanupMaterializedOrphans() {
        let managedPrefix = tempFileService.directoryURL.standardizedFileURL.path + "/"
        // Protect files referenced by the last valid snapshot so restoring a Shelf item
        // also restores access to its materialized contents.
        let protectedItems = shelfStore.items + persistence.recoverableSnapshotItems()
        var protectedPaths = materializedPaths(in: protectedItems, managedPrefix: managedPrefix)
        protectedPaths.formUnion(managedMoveJournal.protectedManagedPaths())
        protectedPaths.formUnion(pendingImportJournal.protectedPaths())
        tempFileService.cleanupOrphans(keepingPaths: protectedPaths)
    }

    private func materializedPaths(in items: [ShelfItem], managedPrefix: String) -> Set<String> {
        var paths = Set<String>()
        for item in items {
            if let path = item.path, path.hasPrefix(managedPrefix) {
                paths.insert(path)
            }
            if let children = item.children {
                paths.formUnion(materializedPaths(in: children, managedPrefix: managedPrefix))
            }
        }
        return paths
    }

    // MARK: - Trigger wiring (S7)

    /// Apply trigger settings at startup and after defaults changes. Monitors ignore identical
    /// configurations so unrelated preference changes cannot register duplicate listeners.
    /// Drag tracking runs while the Panel's Shelf can open for a drag.
    private func applyTriggerSettings() {
        if !isUITesting && settingsStore.experimentalModulesEnabled {
            clipboardHistoryStore.start()
        } else {
            clipboardHistoryStore.stop()
            clipboardHistoryWindowController.hide()
        }
        // Release a conflicting cycle registration before registering the other action.
        if settingsStore.notchCycleShortcutConflicts || !settingsStore.islandEnabled {
            notchCycleHotKeyMonitor.setEnabled(false)
            notchReverseCycleHotKeyMonitor.setEnabled(false)
        }
        hotKeyMonitor.updateShortcut(settingsStore.hotKeyShortcut)
        hotKeyMonitor.setDoublePressEnabled(settingsStore.hotKeyDoublePressSavesClipboard)
        hotKeyMonitor.setEnabled(settingsStore.hotKeyEnabled)
        clipboardHotKeyMonitor.updateShortcut(settingsStore.clipboardHistoryShortcut)
        clipboardHotKeyMonitor.setEnabled(settingsStore.experimentalModulesEnabled && settingsStore.clipboardHistoryShortcut != nil
            && (!settingsStore.hotKeyEnabled || settingsStore.clipboardHistoryShortcut != settingsStore.hotKeyShortcut))
        clipboardHistoryStore.shortcutRegistrationError = settingsStore.hotKeyEnabled
            && settingsStore.clipboardHistoryShortcut != nil
            && settingsStore.clipboardHistoryShortcut == settingsStore.hotKeyShortcut
            ? String(localized: "Choose a history shortcut different from the shelf shortcut.")
            : clipboardHotKeyMonitor.registrationError

        let cycleShortcut = settingsStore.notchCycleShortcut
        let cycleConflict = settingsStore.notchCycleShortcutConflicts
        // Release both first so swapping the Shift modifier cannot collide with the old pair.
        notchCycleHotKeyMonitor.setEnabled(false)
        notchReverseCycleHotKeyMonitor.setEnabled(false)
        notchCycleHotKeyMonitor.updateShortcut(cycleShortcut)
        notchReverseCycleHotKeyMonitor.updateShortcut(settingsStore.notchReverseCycleShortcut)
        notchCycleHotKeyMonitor.setEnabled(settingsStore.islandEnabled && cycleShortcut != nil && !cycleConflict)
        notchReverseCycleHotKeyMonitor.setEnabled(settingsStore.islandEnabled && cycleShortcut != nil && !cycleConflict)
        settingsStore.notchCycleShortcutError = cycleConflict
            ? String(localized: "Choose a notch shortcut whose forward and reverse combinations differ from the shelf and clipboard shortcuts.")
            : notchCycleHotKeyMonitor.registrationError ?? notchReverseCycleHotKeyMonitor.registrationError

        let islandDragActive = settingsStore.islandEnabled
            && settingsStore.islandShelfEnabled
            && !IslandScreenCatalog.options().isEmpty
        if islandDragActive {
            dragStartMonitor.start()
        } else {
            dragStartMonitor.stop()
        }
    }

    /// Reapply trigger configuration when settings change.
    ///
    /// The selector-based defaults observer avoids capturing main-actor state in the Sendable,
    /// nonisolated callback used by withObservationTracking. ShelfWindowController uses the same
    /// pattern for screen changes. applyTriggerSettings skips duplicate registrations.
    ///
    /// NotificationCenter invokes the selector synchronously on the posting thread. XCTest can
    /// register defaults on a background thread, so the selector stays nonisolated and dispatches
    /// to the main actor to avoid a runtime isolation trap.
    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyTriggerSettings()
            self.shelfPresentationCoordinator.applyCurrentMode(animated: true)
            self.menuBarController.applyVisibility()
            // Synchronize Sparkle's automatic check setting only when it changes.
            self.updateController.applySettings()
            self.clipboardHistoryStore.prune(force: true)
            self.clipboardHistoryStore.updateRecording()
        }
    }
}

/// What "Add Clipboard Image to Shelf" does after scheduling imports. Opening the panel only
/// for a real image keeps the "no image" notice under the notch instead of behind an open panel.
enum ClipboardImageImportOutcome: Equatable {
    case showShelf
    case notice(ShelfNotice)

    init(scheduledCount: Int) {
        self = scheduledCount > 0 ? .showShelf : .notice(.clipboardHasNoImage)
    }
}
