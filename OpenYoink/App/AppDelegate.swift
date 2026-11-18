import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let uiTestingDefaultsSuite = "com.nininunz.OpenYoink.UITests"
    private static var isUITestingEnvironment: Bool {
        ProcessInfo.processInfo.environment["OPENYOINK_UI_TESTING"] == "1"
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
            : (Bundle.main.bundleIdentifier ?? "com.nininunz.OpenYoink")
        let evidence = OnboardingLaunchPolicy.hasExistingInstallation(
            preferences: defaults.persistentDomain(forName: domain) ?? [:],
            supportEntries: (try? FileManager.default.contentsOfDirectory(
                atPath: AppDirectories.applicationSupport().path)) ?? []
        )
        return (SettingsStore(defaults: defaults), evidence)
    }

    private let startup = AppDelegate.makeStartupSettings()
    private let appState = AppState()
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
    /// Shows a temporary inline notice when a drop or materialization fails.
    private let shelfNotice = ShelfNoticeModel()
    /// Share the active tutorial item token without coupling the lazy Shelf and onboarding objects.
    private let onboardingDragContext = OnboardingDragContext()
    private let logger = Logger(subsystem: "com.nininunz.OpenYoink", category: "App")
    private var isUITesting: Bool {
        Self.isUITestingEnvironment
    }
    /// Read shelf.json only once at startup. A failed read quarantines the corrupt
    /// file. Reading again would report it missing and could allow unsafe orphan cleanup.
    private lazy var initialShelfLoadResult = persistence.loadResult()
    /// Owns the Shelf item store that is injected into ShelfView.
    private lazy var shelfStore = ShelfStore(items: initialShelfLoadResult.items,
                                             persistence: persistence)
    /// Dispatches pasteboard data to Shelf items and reports failures through shelfNotice.
    private lazy var dropImportCoordinator = DropImportCoordinator(bookmarkService: bookmarkService,
                                                                   tempFileService: tempFileService,
                                                                   noticeCenter: shelfNotice,
                                                                   managedMoveJournal: managedMoveJournal,
                                                                   pendingImportJournal: pendingImportJournal)
    /// 用户设置（S5 起拖出后移除策略被 DragSessionController 读取；S8 由
    /// SettingsView 编辑）。internal：OpenYoinkApp 的 Settings scene 注入环境用。
    var settingsStore: SettingsStore { startup.settings }
    lazy var clipboardHistoryStore: ClipboardHistoryStore = {
        let history = ClipboardHistoryStore(settings: settingsStore)
        history.onAddToShelf = { [weak self] content in self?.addHistoryToShelf(content) }
        history.onShowWindow = { [weak self] in self?.clipboardHistoryWindowController.show() }
        return history
    }()
    private lazy var clipboardHistoryWindowController = ClipboardHistoryWindowController(
        history: clipboardHistoryStore, settings: settingsStore
    )
    /// 设置窗口的共享导航状态，允许不可用的托管项目直接打开“存储”页。
    let settingsNavigation = SettingsNavigationModel()
    /// 系统登录项状态（不复制到 UserDefaults；SMAppService 是唯一事实源）。
    let launchAtLoginController = LaunchAtLoginController()
    /// 恢复快照、托管目录占用与安全清理（设置-存储）。
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
                .union(self?.shelfWindowController.favoriteFolderDropCoordinator.protectedPaths ?? [])
        },
        prepareRestoredItems: { [weak self] items in
            guard let self else { return items }
            return items.map { self.refreshedByResolvingBookmark($0) ?? $0 }
        }
    )
    /// S5: 最近拖出历史（内存 + recents.json；S10 已接入菜单栏「最近项目」）。
    private let recentItemsService = RecentItemsService()
    /// v1.2: shared drag-out acceptance/promise-delivery coordinator. Storage
    /// cleanup consults its runtime file leases.
    private lazy var deliveryCoordinator = DeliveryCoordinator(
        store: shelfStore,
        recents: recentItemsService,
        tempFileService: tempFileService,
        transferStore: dropImportCoordinator.transferStore
    )
    /// Sparkle 2 自动更新封装（懒加载：首次 start/手动检查时创建
    /// SPUStandardUpdaterController；terminate 无需显式释放——XPC 连接与
    /// 调度器随进程终止，无后台常驻资源）。
    lazy var updateController = UpdateController(settings: settingsStore)
    /// Help, voluntary issue reporting and privacy-safe local diagnostics.
    lazy var supportController = SupportController(settings: settingsStore)

    private lazy var shelfWindowController: ShelfWindowController = ShelfWindowController(appState: appState,
                                                                   store: shelfStore,
                                                                   importCoordinator: dropImportCoordinator,
                                                                   tempFileService: tempFileService,
                                                                   settings: settingsStore,
                                                                   recents: recentItemsService,
                                                                   deliveryCoordinator: deliveryCoordinator,
                                                                   dragStartMonitor: dragStartMonitor,
                                                                   clipboardHistoryStore: clipboardHistoryStore,
                                                                   onOpenSettings: { [weak self] in
                                                                       self?.settingsWindowController.show(pane: .general)
                                                                   },
                                                                   onOpenModuleSettings: { [weak self] in
                                                                       self?.settingsWindowController.show(pane: .modules)
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
        }
    )

    /// S7: 全局快捷键监听（Carbon RegisterEventHotKey 为主、NSEvent 全局监听
    /// 为备；注册失败状态供 S8 设置页提示）。internal：Settings scene 注入
    /// 环境（registrationError 展示）用。
    /// UX3: 单击 = toggle；双击 = 保存剪贴板到 shelf（识别窗 ~0.3s，设置可关）。
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
    /// UX2: 屏幕边缘触发（拖拽版）。仅「唤出」不「隐藏」：贴边的意图是取用
    /// shelf（通常紧接着要向该侧投放），再次贴边反而隐藏会产生往复开关的
    /// 挫败感；隐藏仍由快捷键/菜单与 UX1 拖空无落入自动收回承担。
    /// UX2 设计变更（用户确认）：纯悬停不再触发，仅拖拽中（按住左键）贴边
    /// 短停留唤出；custom 位置无贴附缘时暂停（applyTriggerSettings）。
    /// EdgeTab: 拖动拉环本身（isEdgeTabBeingDragged）也是 leftMouseDragged，
    /// 会路过贴缘带 —— 抑制，避免重定位拉环时误唤出。
    private lazy var edgeTriggerMonitor = EdgeTriggerMonitor(shouldSuppress: { [weak self] in
        guard let self else { return true }
        return self.appState.isShelfVisible
            || self.appState.isEdgeTabBeingDragged
            || IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onTrigger: { [weak self] in
        guard let self, !self.appState.isShelfVisible else { return }
        // UX2: 拖拽贴边唤出也记入自动唤出会话（拖空无落入自动收回）。
        self.shelfPresentationCoordinator.showClassic(animated: true)
        self.dragAutoShowSession.markShownAutomatically()
    })
    /// UX1: 拖拽开始监听（按下 → 位移超阈值判定拖拽 → 抬起结束）。
    /// 同时承担 UX2 贴边唤出的会话记帐：只要任一拖拽驱动唤出路径可能
    /// 生效（immediate 或边缘触发可用）就保持注册。EdgeTab 起还供给
    /// `isDragInProgress` 可观察状态（拉环投放暗示），因此拉环启用时
    /// 同样保持注册（applyTriggerSettings）。
    /// EdgeTab: 拖动拉环本身被识别为拖拽是正常的，但不应唤出 shelf ——
    /// 经 isEdgeTabBeingDragged 抑制（拉环此时独占该手势）。
    private lazy var dragStartMonitor = DragStartMonitor(shouldSuppress: { [weak self] in
        guard let self else { return false }
        return self.appState.isEdgeTabBeingDragged
            || IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onDragStart: { [weak self] in
        self?.handleDragStart()
    }, onPotentialDragChange: { [weak self] active in
        self?.shelfWindowController.setIslandDragZoneActive(active)
    }, onNativeDragUpdate: { [weak self] point in
        self?.handleDragUpdate(at: point)
    }, onDragEnd: { [weak self] in
        self?.handleDragEnd()
    })
    /// UX1/2: 拖拽自动唤出会话裁决（纯逻辑状态机，见 Triggers/DragStartMonitor）。
    private var dragAutoShowSession = DragAutoShowSession()
    private var islandDragWasActivated = false
    private var noticeRevisionBeforeDrag: UInt64 = 0

    /// EdgeTab: 贴屏幕边缘的常驻拉环（单击展开 / 拖入接收 / 沿边拖动换位）。
    /// 拉环与 shelf 互斥（shelf 展开时拉环隐藏；shelf 的外缘隐形热区承担
    /// 同点位收起）。
    private lazy var edgeTabController = EdgeTabController(
        appState: appState,
        settings: settingsStore,
        store: shelfStore,
        importCoordinator: dropImportCoordinator,
        dragStartMonitor: dragStartMonitor,
        onToggleShelf: { [weak self] in
            self?.shelfPresentationCoordinator.toggleClassic(animated: true)
        },
        onShowShelf: { [weak self] in
            self?.shelfPresentationCoordinator.showClassic(animated: true)
        },
        onPreviewSuppressed: { [weak self] in
            self?.shelfWindowController.suppressClassicHoverPreview()
        }
    )

    /// S10: 语言覆盖必须在最早阶段生效——`AppleLanguages` 决定进程后续加载的
    /// 本地化资源（Bundle 主语言在首个本地化查询时锁定），故放在
    /// willFinishLaunching（SwiftUI scene 与任何 UI 构建之前）。
    /// 设置页注明「重启后生效」：运行期切换只写偏好，下次启动由此应用。
    func applicationWillFinishLaunching(_ notification: Notification) {
        if isUITesting {
            settingsStore.islandEnabled = true
            settingsStore.showNotch = !ProcessInfo.processInfo.arguments.contains("--ui-testing-hide-compact")
            settingsStore.islandHoverRevealEnabled = ProcessInfo.processInfo.arguments.contains("--ui-testing-hover")
        }
        if !isUITesting {
            applyLanguageOverride()
        }
    }

    /// 按 `SettingsStore.language` 覆盖 `AppleLanguages`；`.system` 时移除覆盖，
    /// 完全交还系统语言列表。
    private func applyLanguageOverride() {
        switch settingsStore.language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .chinese:
            UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 必须在 Sparkle start 或任何新版本偏好写入之前采样，才能区分真正
        // 全新安装与没有 onboardingVersion 键的旧版本升级。
        let hasLegacyInstallEvidence = legacyInstallEvidence()
        _ = menuBarController
        if !isUITesting && settingsStore.experimentalModulesEnabled { clipboardHistoryStore.start() }
        // EdgeTab: 拉环随启动就位（shelf 初始隐藏，拉环立即在边缘就位）。
        if SideShelfAvailability.isEnabled { _ = edgeTabController }
        // Sparkle: 启动 updater（应用「自动检查」设置后 start；幂等）。
        if !isUITesting {
            updateController.start()
        }
        // UX1: 成功导入（拖入/剪贴板保存）→ 标记拖拽自动唤出会话「本轮
        // 已有内容落入」，拖结束时不再自动收回。
        dropImportCoordinator.onImportHandled = { [weak self] in
            self?.dragAutoShowSession.noteImport()
            self?.shelfWindowController.promoteClassicHoverPreviewIfNeeded()
        }
        shelfWindowController.onClassicDestinationEntered = { [weak self] sequenceNumber in
            self?.dragAutoShowSession.destinationEntered(sequenceNumber: sequenceNumber)
        }
        shelfWindowController.onClassicDestinationEnded = { [weak self] sequenceNumber, accepted in
            guard let self else { return }
            if self.dragAutoShowSession.destinationEnded(sequenceNumber: sequenceNumber, accepted: accepted),
               self.appState.isShelfVisible {
                self.shelfPresentationCoordinator.hideClassic(animated: true)
            }
        }
        shelfWindowController.onClassicPresentationRequested = { [weak self] in
            self?.dragAutoShowSession.cancelAutomaticHide()
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

    /// 应用已在运行时再次打开（Finder / 启动台 / Spotlight 双击）：弹出设置。
    /// 菜单栏图标太多时 macOS 会把 OpenYoink 的图标藏起来且不提示，这是
    /// 此时唯一能找到的入口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindowController.show()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        clipboardHistoryStore.stop()
        Task { @MainActor in
            await clipboardHistoryStore.flush()
            sender.reply(toApplicationShouldTerminate: true)
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
        edgeTriggerMonitor.stop()
        dragStartMonitor.stop()
    }

    /// 旧版没有 onboardingVersion，需从本版本写入前的持久化痕迹判断升级。
    /// 注册域默认值不算证据；bundle 的持久化 domain 与 Application Support
    /// 中既有数据任一存在即可。Tutorial 自身被排除，避免中断 session 被误判。
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

    // MARK: - UX1/UX2 drag-driven appearance

    /// UX1: 拖拽确认（位移超阈值）。开启新会话记帐；用户显式选择
    /// `.immediate` 模式时
    /// shelf 不可见时立即唤出并打自动唤出标记（拖拽前已可见 = 用户手动
    /// 唤出，不标记、不动它）。`.edgeOnly` 只做记帐，唤出交给边缘触发。
    private func handleDragStart() {
        noticeRevisionBeforeDrag = shelfNotice.revision
        dragAutoShowSession.dragBegan()
        guard settingsStore.effectivePreferredShelfSurface == .classic else { return }
        guard settingsStore.classicShelfEnabled else { return }
        guard settingsStore.dragAutoAppearMode == .immediate else { return }
        guard !appState.isShelfVisible else { return }
        shelfPresentationCoordinator.showClassic(animated: true)
        dragAutoShowSession.markShownAutomatically()
    }

    private func handleDragUpdate(at point: CGPoint) {
        guard settingsStore.islandEnabled,
              settingsStore.islandShelfEnabled else { return }
        if shelfPresentationCoordinator.dragApproachedTop(at: point) {
            islandDragWasActivated = true
        }
    }

    /// UX1: 未投放时自动收回；成功拖入默认保持展开，可由设置关闭。
    /// 本地接收区的回调可能晚于 mouse-up；状态机等待真实完成事件。
    ///
    /// 任务二审查结论（拖拽中可见性不变式）：本路径不会「拖拽中误隐」——
    /// DragStartMonitor 在派发 onDragEnd 前已把 isDragInProgress 复位，
    /// 收回只发生在抬起之后；成功落入（含已派发的异步物化）经
    /// onImportHandled → noteImport 置位，并由设置决定是否保持展开。
    /// 空架自动隐藏（拖拽中唯一可能误隐的路径）已在 EmptyShelfAutoHideRule
    /// 内按 isDragInProgress 门控。
    private func handleDragEnd() {
        let imported = dragAutoShowSession.receivedImport
        let shouldHideClassic = dragAutoShowSession.dragEnded(
            keepShelfOpenAfterDrop: settingsStore.keepShelfOpenAfterDrop
        )
        if islandDragWasActivated {
            shelfPresentationCoordinator.dragEnded(
                imported: imported,
                hasPendingNotice: shelfNotice.current != nil && shelfNotice.revision != noticeRevisionBeforeDrag
            )
            islandDragWasActivated = false
        }
        guard shouldHideClassic, appState.isShelfVisible else { return }
        shelfPresentationCoordinator.hideClassic(animated: true)
    }

    // MARK: - UX3 clipboard save

    /// 双击快捷键保存剪贴板：复用 `DropImportCoordinator` 的拖入分派（文件 /
    /// 图片 / URL / 文本）。成功导入即唤出 shelf 给出反馈；空剪贴板或无
    /// 可导入内容时不动作（shelf 可见时走既有 notice 提示）。
    private func saveClipboardToShelf() {
        let result = dropImportCoordinator.importItems(from: .general) { [weak self] item in
            self?.shelfStore.add(item)
        }
        guard result.handled else {
            if appState.isShelfVisible {
                shelfNotice.show(.clipboardEmpty)
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

    /// 菜单栏「最近项目」点击重新入架：文件类按路径重建 ShelfItem（含新的
    /// 安全书签；`canReadd` 已在菜单侧确认可访问），URL 直接复原。text/stack
    /// 条目在菜单侧已置灰，不会到达这里。入架后唤出 shelf 给出明确反馈。
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
                shelfNotice.show(.moveRecoveryNeedsAttention)
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
                shelfNotice.show(.moveRecovered)
            } catch {
                logger.error("Failed to persist recovered managed moves: \(error.localizedDescription, privacy: .public)")
                unresolvedCount += resolved.count
            }
        }

        if unresolvedCount > 0 {
            shelfNotice.show(.partialMoveRecoveryNeedsAttention)
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
                shelfNotice.show(.interruptedImportRecovered)
            }
        case .failed:
            shelfNotice.show(.importRecoveryNeedsAttention)
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

    /// S7: 按当前设置启停触发监听（启动时与设置变更时调用）。各 monitor
    /// 内部对「配置未变」做了幂等保护，因此可响应任意 UserDefaults 变更
    /// 直接重应用，不会重复注册事件监听。
    ///
    /// UX1/2: 拖拽自动出现由 `dragAutoAppearMode` 单控 —— `.immediate`
    /// 由 DragStartMonitor 在拖拽确认时直接唤出；`.edgeOnly` 由
    /// EdgeTriggerMonitor（拖拽贴边短停留）唤出；`.off` 两者皆停。
    /// 边缘机制在 custom 位置无贴附缘时暂停。DragStartMonitor 还承担
    /// 自动唤出会话记帐（拖空无落入自动收回），因此任一唤出路径可用
    /// 时都要保持注册；EdgeTab 起还供给拉环投放暗示的 `isDragInProgress`
    /// 状态，拉环可用（edgeTabEnabled 且非 custom）时同样保持注册。
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

        let classicActive = SideShelfAvailability.isEnabled && settingsStore.classicShelfEnabled
        let edgeActive = classicActive
            && settingsStore.dragAutoAppearMode == .edgeOnly
            && settingsStore.shelfPosition != .custom
        if edgeActive {
            edgeTriggerMonitor.start(
                side: settingsStore.shelfPosition,
                dwellTime: settingsStore.edgeTriggerSensitivity.edgeDwellTime,
                bandWidth: settingsStore.edgeTriggerSensitivity.edgeBandWidth
            )
        } else {
            edgeTriggerMonitor.stop()
        }

        // EdgeTab 拉环常驻（开启 && 非 custom 即在位，不再随 shelf 显隐），
        // monitor 注册与拉环在位同一判定 —— 拉环一在位就需要拖拽状态。
        let edgeTabActive = classicActive
            && settingsStore.edgeTabEnabled
            && settingsStore.shelfPosition != .custom
        let islandDragActive = settingsStore.islandEnabled
            && settingsStore.islandShelfEnabled
            && !IslandScreenCatalog.options().isEmpty
        let classicImmediateActive = settingsStore.effectivePreferredShelfSurface == .classic
            && settingsStore.dragAutoAppearMode == .immediate
        if classicImmediateActive
            || edgeActive || edgeTabActive || islandDragActive {
            dragStartMonitor.start()
        } else {
            dragStartMonitor.stop()
        }
    }

    /// S7: 设置变更 → 重应用触发配置。
    ///
    /// 为什么用 UserDefaults.didChangeNotification 而不是 withObservationTracking：
    /// 后者的 onChange 是 @Sendable 非隔离闭包，Swift 6 严格并发下无法捕获
    /// MainActor 隔离的 self；选择器式 NotificationCenter 观察不涉闭包捕获，
    /// 是本项目已验证的等价机制（同 ShelfWindowController 的屏幕参数监听）。
    /// applyTriggerSettings 幂等，无关设置项的变更不会导致重复注册。
    ///
    /// 必须 nonisolated：该通知按投递线程同步回调，而投递方可能是任意线程
    /// （XCTest 引导阶段就在后台线程 registerDefaults:）；若选择器方法保留
    /// MainActor 隔离，运行期隔离断言会在投递线程上直接 SIGTRAP。
    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyTriggerSettings()
            self.shelfPresentationCoordinator.applyCurrentMode(animated: true)
            self.menuBarController.applyVisibility()
            // Sparkle: 「自动检查更新」开关同步（值未变时不写，幂等）。
            self.updateController.applySettings()
            self.clipboardHistoryStore.prune(force: true)
            self.clipboardHistoryStore.updateRecording()
        }
    }
}
