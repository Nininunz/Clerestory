import AppKit
import OSLog
import SwiftUI

/// Hides on a non-empty → empty transition when enabled. Explicit shelf
/// management removals and in-progress drags keep the shelf open, while still
/// advancing the baseline so a suppressed hide is never replayed later.
struct EmptyShelfAutoHideRule: Sendable, Equatable {
    private var previousCount: Int?

    /// Evaluates each item update. A true result requests immediate auto-hide.
    /// Always record the new count as the baseline for the next update.
    mutating func evaluate(itemCount: Int, isVisible: Bool, isEnabled: Bool) -> Bool {
        evaluate(itemCount: itemCount, isVisible: isVisible, isEnabled: isEnabled,
                 isDragInProgress: false)
    }

    /// Suppressed transitions still update the baseline. Future delivery-driven
    /// removals continue to follow the user's empty-shelf setting.
    mutating func evaluate(itemCount: Int, isVisible: Bool, isEnabled: Bool,
                           isDragInProgress: Bool, isUserRemoval: Bool = false) -> Bool {
        defer { previousCount = itemCount }
        guard let previousCount else { return false }
        guard !isDragInProgress, !isUserRemoval else { return false }
        return isEnabled && isVisible && previousCount > 0 && itemCount == 0
    }

    /// Clears the baseline so the next update records a count without triggering auto-hide.
    mutating func reset() {
        previousCount = nil
    }
}

/// Controls Shelf visibility, window placement, and display changes. It also
/// owns the Quick Look session and dispatches Shelf keyboard events through
/// `ShelfPanel.onKeyDown`.
///
/// Triggers and settings use `toggleShelf(animated:)`, `showShelf(animated:)`,
/// or `hideShelf(animated:)`. `isShelfVisible` reads the state stored in `AppState`.
@MainActor
final class ShelfWindowController: NSObject {
    private static let animationDuration: TimeInterval = 0.2
    var onClassicDestinationEntered: ((Int) -> Void)?
    var onClassicDestinationEnded: ((Int, Bool) -> Void)?
    var onClassicPresentationRequested: (() -> Void)?

    private let appState: AppState
    /// Source of Shelf position, width, and auto-hide preferences.
    private let settings: SettingsStore
    private let clipboardHistoryStore: ClipboardHistoryStore
    /// Shared item store for ShelfView and the AppKit drop destination.
    private let store: ShelfStore
    /// Keeps the previous count for empty-Shelf auto-hide decisions.
    private var emptyAutoHideRule = EmptyShelfAutoHideRule()
    private var isUserRemovalInProgress = false
    /// Converts dropped pasteboard data into Shelf items for DragContainerView.
    private let importCoordinator: DropImportCoordinator
    /// DragContainerView updates drop feedback and insertion position for ShelfView to render.
    private let classicDropTargetState = DropTargetState()
    private let islandDropTargetState = DropTargetState()
    /// ShelfView reports card frames. Drop positioning and marquee selection
    /// share this geometry.
    private let classicGridGeometry = ShelfGridGeometry()
    private let islandGridGeometry = ShelfGridGeometry()
    /// Runtime focus/expanded-stack state shared with SwiftUI card rendering.
    private let interaction = ShelfInteractionState()
    /// Starts drag-out sessions and applies the remove, keep, or ask preference
    /// after the drop. Successful drops enter recent history and can trigger auto-hide.
    private let classicDragOutController: DragOutController
    private let islandDragOutController: DragOutController
    /// Temporary file storage for text actions in the card context menu.
    private let tempFileService: TempFileService
    /// Owns the Quick Look session across window presentations. Space,
    /// double-click, and the context menu share this coordinator.
    private let quickLookCoordinator: QuickLookCoordinator
    /// v1.2: distinguishes external references from managed-copy loss and owns
    /// the safe user-driven recovery actions.
    private let itemRecoveryController: ItemRecoveryController
    /// v1.3: shared non-destructive selection actions and the retained AppKit
    /// share-session lifecycle.
    private let shelfActionRunner: ShelfActionRunner
    /// Batch-level VoiceOver announcements live for the controller lifetime so
    /// SwiftUI redraws cannot repeat already spoken events.
    private let accessibilityAnnouncementCenter = AccessibilityAnnouncementCenter()
    /// Reads DragStartMonitor.isDragInProgress. Auto-hide must keep an already
    /// visible Shelf open during a drag.
    private let dragStartMonitor: DragStartMonitor
    /// Expanded Island's visible Settings control uses the app's retained,
    /// LSUIElement-safe settings window rather than SwiftUI's response-chain
    /// action, which can silently fail for a non-activating panel.
    private let onOpenSettings: @MainActor () -> Void
    /// v1.4: the classic shelf and Island share one dependency graph and one
    /// ShelfStore, but each owns an independent panel and visibility state.
    let islandActivityCoordinator: IslandActivityCoordinator
    let islandModuleRegistry: IslandModuleRegistry
    let islandTimerStore: IslandTimerStore
    let powerSourceMonitor: PowerSourceMonitor
    let nowPlayingModuleStore: NowPlayingModuleStore
    let systemStatusModuleStore: SystemStatusModuleStore
    let aiUsageModuleStore: AIUsageModuleStore
    let favoriteFoldersStore: FavoriteFoldersStore
    let favoriteFolderDropCoordinator: FavoriteFolderDropCoordinator
    let islandModuleContainer: IslandModuleContainer
    private let transfersModuleRuntime: TransfersModuleRuntime
    private let timerModuleRuntime: CallbackIslandModuleRuntime
    private let batteryModuleRuntime: CallbackIslandModuleRuntime
    private let mediaModuleRuntime: CallbackIslandModuleRuntime
    private let favoriteFoldersModuleRuntime: CallbackIslandModuleRuntime
    private var classicHoverPreviewState = ClassicShelfHoverPreviewStateMachine()
    private var classicHoverExitTask: Task<Void, Never>?
    private var classicHoverGlobalMonitor: Any?
    private var classicHoverLocalMonitor: Any?
    private var isOpeningClassicHoverPreview = false
    /// Onboarding pauses auto-hide without changing the saved preference.
    private var onboardingPresentationCount = 0
    private var quickActionLayoutTask: Task<Void, Never>?
    private var classicFrameTransition = ShelfFrameTransitionState()
    private var classicVisibilityTransition = ShelfVisibilityTransitionState()
    /// Tracks the classic side Shelf transition to or from its edge tab.
    private let classicReveal = ShelfRevealState()
    /// Defer window frame and shadow updates during the edge-tab transition.
    /// Any preference write can trigger applyPresentationSettings.
    private var isClassicMorphing = false
    /// Replays layout requests from item or preference changes after the transition.
    private var isClassicLayoutDeferred = false
    /// New height requests and hiding invalidate completion of an older animation.
    private var classicResizeGeneration: UInt = 0
    /// Transparent padding between the classic window frame and its glass surface.
    private static let classicSurfaceInset: CGFloat = 8

    /// Bounds used for hover, hit testing, and transitions. When the glass
    /// surface shrinks in resizeClassicSurface, the extra window area below
    /// it remains transparent and ignores clicks.
    private var classicLogicalFrame: NSRect {
        let frame = classicPanel.frame
        guard let surfaceHeight = classicReveal.surfaceHeight else { return frame }
        let height = min(frame.height, surfaceHeight + Self.classicSurfaceInset * 2)
        return NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// A direct frame change invalidates the height animation and lets the glass fill the window again.
    private func resetClassicSurfaceHeight() {
        classicResizeGeneration &+= 1
        classicReveal.pinSurfaceHeight(nil)
    }

    struct OnboardingPresentationSnapshot: Equatable, Sendable {
        fileprivate let surface: SettingsStore.PreferredShelfSurface
        fileprivate let wasVisible: Bool
    }

    private lazy var classicPanel: ShelfPanel = makePanel(
        presentationStyle: .classic,
        dropTargetState: classicDropTargetState,
        gridGeometry: classicGridGeometry,
        dragOutController: classicDragOutController
    )

    private var islandNoticePanel: ShelfNoticePanelController?
    private lazy var islandPresentation = IslandPresentationController(
        settings: settings, coordinator: islandActivityCoordinator,
        registry: islandModuleRegistry, modules: islandModuleContainer,
        notices: { [weak self] in self?.islandNoticePanel },
        collapse: { [weak self] in self?.collapseIsland(animated: $0) },
        makePanel: { [unowned self] role in
            self.makePanel(presentationStyle: .island,
                dropTargetState: self.islandDropTargetState,
                gridGeometry: self.islandGridGeometry,
                dragOutController: self.islandDragOutController, islandRole: role)
        })
    private var islandPanel: ShelfPanel { islandPresentation.expanded.panel }
    private var islandNotchPanel: ShelfPanel { islandPresentation.notch.panel }

    private var dragZoneHandoffTask: Task<Void, Never>?
    private var islandDragZonePanels: [String: ShelfPanel] = [:]

    private func makeIslandDragZonePanel() -> ShelfPanel {
        let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.allowsTopEdgeOverlap = true
        panel.hasShadow = false
        // Keep the native approach receiver hit-testable without visible chrome.
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        panel.ignoresMouseEvents = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 7)
        let content = NSViewController()
        content.view = NSView(frame: .zero)
        panel.contentView = DragContainerView(
            store: store, coordinator: importCoordinator,
            dropTargetState: islandDropTargetState, gridGeometry: islandGridGeometry,
            onNativeShelfDrag: { [weak self] in
                guard let self else { return }
                self.dragStartMonitor.confirmShelfDragFromDestination(at: NSEvent.mouseLocation)
                guard self.islandActivityCoordinator.surfaceState.isExpanded,
                      self.dragZoneHandoffTask == nil else { return }
                // Retain a valid destination for a quick release while the
                // expanded shelf animates into place above this clear panel.
                self.dragZoneHandoffTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(IslandMotion.expandWindowDuration))
                    guard !Task.isCancelled else { return }
                    self?.islandDragZonePanels.values.forEach { $0.orderOut(nil) }
                }
            }, isApproachZone: true, contentViewController: content)
        return panel
    }

    func setIslandDragZoneActive(_ active: Bool) {
        guard active, settings.islandEnabled, settings.islandShelfEnabled,
              settings.islandDragApproachEnabled, hasAvailableIslandDisplay,
              !islandActivityCoordinator.surfaceState.isExpanded else {
            dragZoneHandoffTask?.cancel()
            dragZoneHandoffTask = nil
            islandDragZonePanels.values.forEach { $0.orderOut(nil) }
            return
        }
        let screens = NSScreen.screens
        let connected = Set(screens.map(IslandScreenCatalog.identifier(for:)))
        for id in Array(islandDragZonePanels.keys) where !connected.contains(id) {
            islandDragZonePanels.removeValue(forKey: id)?.orderOut(nil)
        }
        // A drag can cross displays without restarting its native session.
        // Keep a destination on each screen rather than moving one under the pointer.
        for screen in screens {
            let id = IslandScreenCatalog.identifier(for: screen)
            let panel = islandDragZonePanels[id] ?? makeIslandDragZonePanel()
            islandDragZonePanels[id] = panel
            let layout = IslandGeometryResolver.resolve(screen: IslandScreenCatalog.geometry(for: screen),
                                                        showNotch: settings.showNotch)
            panel.setFrame(layout.activationFrame, display: true)
            panel.orderFront(nil)
        }
    }

    @ViewBuilder
    private func presentationRoot(_ style: ShelfPresentationStyle, role: IslandWindowRole) -> some View {
        if style == .classic {
            ShelfView()
        } else if role == .notch {
            IslandNotchView()
        } else {
            IslandExpandedView(
                onPerformRecovery: { [weak self] in self?.itemRecoveryController.perform($0) },
                onOpenSettings: { [weak self] in self?.onOpenSettings() })
        }
    }

    private func makePanel(
        presentationStyle: ShelfPresentationStyle,
        dropTargetState: DropTargetState,
        gridGeometry: ShelfGridGeometry,
        dragOutController: DragOutController,
        islandRole: IslandWindowRole = .expanded
    ) -> ShelfPanel {
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: settings.shelfWidth, height: 600)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.acceptsKeyboardFocus = islandRole == .expanded
        if presentationStyle == .island {
            panel.title = islandRole == .notch ? "Clerestory Notch" : "Clerestory Panel"
            panel.setAccessibilityIdentifier(islandRole == .notch
                                            ? "island.window.compact" : "island.window.expanded")
        }
        // SwiftUI presentation preferences alone don't set AppKit controls'
        // appearance inside this custom, non-activating Island panel.
        if presentationStyle == .island {
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        // Wrap the hosting view in DragContainerView for AppKit drag destination events.
        let hostingController = NSHostingController(
            rootView: presentationRoot(presentationStyle, role: islandRole)
                .environment(store)
                .environment(dropTargetState)
                .environment(settings)
                .environment(gridGeometry)
                .environment(interaction)
                .environment(importCoordinator.noticeCenter)
                .environment(importCoordinator.transferStore)
                .environment(islandActivityCoordinator)
                .environment(islandModuleRegistry)
                .environment(islandModuleContainer)
                .environment(islandTimerStore)
                .environment(powerSourceMonitor)
                .environment(nowPlayingModuleStore)
                .environment(systemStatusModuleStore)
                .environment(aiUsageModuleStore)
                .environment(favoriteFoldersStore)
                .environment(favoriteFolderDropCoordinator)
                .environment(clipboardHistoryStore)
                .environment(\.bookmarkService, importCoordinator.bookmarkService)
                .environment(\.dragOutController, dragOutController)
                .environment(\.quickLookCoordinator, quickLookCoordinator)
                .environment(\.tempFileService, tempFileService)
                .environment(\.itemRecoveryController, itemRecoveryController)
                .environment(\.shelfActionRunner, shelfActionRunner)
                .environment(\.accessibilityAnnouncementCenter,
                              accessibilityAnnouncementCenter)
                // The inner collapse handle uses the standard hideShelf animation.
                .environment(\.shelfRevealState,
                             presentationStyle == .classic ? classicReveal : nil)
                .environment(\.shelfHideAction, { [weak self] in
                    if presentationStyle == .island {
                        self?.collapseIsland(animated: true)
                    } else {
                        self?.hideShelf(animated: true)
                    }
                })
                .environment(\.shelfFocusAction, { [weak panel] in
                    guard let panel else { return }
                    NSApp.activate()
                    panel.makeKeyAndOrderFront(nil)
                    if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor {
                        panel.makeFirstResponder(nil)
                    }
                })
                .environment(\.shelfUserRemovalAction, { [weak self] action in
                    guard let self else { action(); return }
                    let previous = self.isUserRemovalInProgress
                    self.isUserRemovalInProgress = true
                    defer { self.isUserRemovalInProgress = previous }
                    action()
                })
        )
        if presentationStyle == .island {
            // The controller owns both window frames. A disappearing module's
            // SwiftUI minimum size must not resize or move the hidden panel.
            hostingController.sizingOptions = []
            hostingController.view.setAccessibilityLabel(islandRole == .notch
                ? String(localized: "Notch") : String(localized: "Clerestory Panel"))
        }
        let dropOverride: DragContainerDropOverride? = presentationStyle == .island && islandRole == .expanded
            ? DragContainerDropOverride(
                isActive: { [weak self] in
                    guard let self else { return false }
                    return self.islandActivityCoordinator.surfaceState.isExpanded
                        && [.folders, .clipboard].contains(self.islandActivityCoordinator.selectedModule)
                },
                canHandle: { [weak self] context in
                    guard let self, self.islandActivityCoordinator.selectedModule == .folders else { return false }
                    return self.favoriteFolderDropCoordinator.update(context)
                },
                perform: { [weak self] context in
                    guard let self, self.islandActivityCoordinator.selectedModule == .folders else { return false }
                    return self.favoriteFolderDropCoordinator.perform(context)
                },
                reset: { [weak self] in self?.favoriteFolderDropCoordinator.resetTarget() }
            )
            : nil
        panel.contentView = DragContainerView(
            store: store,
            coordinator: importCoordinator,
            dropTargetState: dropTargetState,
            gridGeometry: gridGeometry,
            dropOverride: dropOverride,
            onDestinationEntered: { [weak self] sequenceNumber in
                guard presentationStyle == .classic else { return }
                self?.onClassicDestinationEntered?(sequenceNumber)
            },
            onDestinationEnded: { [weak self] sequenceNumber, accepted in
                guard presentationStyle == .classic else { return }
                self?.onClassicDestinationEnded?(sequenceNumber, accepted)
            },
            onNativeShelfDrag: { [weak self] in
                guard presentationStyle == .island else { return }
                self?.dragStartMonitor.confirmShelfDragFromDestination(at: NSEvent.mouseLocation)
            },
            contentViewController: hostingController
        )
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        // A card click has already made the panel key. Dispatch the Space,
        // Delete, and Escape events that the content leaves unhandled.
        panel.onKeyDown = { [weak self] event in
            self?.handleItemKeyDown(event, in: panel) ?? false
        }
        if presentationStyle == .island && islandRole == .expanded {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(
                    islandPresentation, selector: #selector(IslandPresentationController.islandWindowStateDidChange(_:)),
                    name: name, object: panel
                )
            }
        }
        if presentationStyle == .island && islandRole == .expanded {
            islandNoticePanel = ShelfNoticePanelController(
                anchor: panel, notices: importCoordinator.noticeCenter,
                coordinator: islandActivityCoordinator, settings: settings,
                dropTarget: islandDropTargetState,
                onRecovery: { [weak self] in self?.itemRecoveryController.perform($0) })
        }
        return panel
    }

    var isShelfVisible: Bool {
        appState.isShelfVisible
    }

    var isIslandExpanded: Bool {
        islandActivityCoordinator.surfaceState.isExpanded
    }

    var isPreferredShelfExpanded: Bool {
        switch effectivePreferredShelfSurface {
        case .classic: appState.isShelfVisible
        case .island: islandActivityCoordinator.surfaceState.isExpanded
        case nil: false
        }
    }

    init(appState: AppState,
         store: ShelfStore,
         importCoordinator: DropImportCoordinator,
         tempFileService: TempFileService,
         settings: SettingsStore,
         recents: RecentItemsService,
         deliveryCoordinator: DeliveryCoordinator,
         dragStartMonitor: DragStartMonitor,
         clipboardHistoryStore: ClipboardHistoryStore,
         onOpenSettings: @escaping @MainActor () -> Void = {},
         onOpenModuleSettings: @escaping @MainActor () -> Void = {},
         onOpenStorageRecovery: @escaping @MainActor () -> Void = {},
         tutorialTokenForItem: @escaping @MainActor (UUID) -> String? = { _ in nil }) {
        self.appState = appState
        self.store = store
        self.importCoordinator = importCoordinator
        self.tempFileService = tempFileService
        self.settings = settings
        self.clipboardHistoryStore = clipboardHistoryStore
        self.dragStartMonitor = dragStartMonitor
        self.onOpenSettings = onOpenSettings
        let islandActivityCoordinator = IslandActivityCoordinator(defaults: settings.defaultsStore)
        let islandModuleRegistry = IslandModuleRegistry()
        let islandTimerStore = IslandTimerStore(defaults: settings.defaultsStore)
        let powerSourceMonitor = PowerSourceMonitor(
            isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded && islandActivityCoordinator.selectedModule == .battery
            },
            fullChargeAlertEnabled: { settings.islandFullChargeAlertEnabled }
        )
        let nowPlayingModuleStore = NowPlayingModuleStore(
            sourceFactory: { NowPlayingSourceFactory.bundled(isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded && islandActivityCoordinator.selectedModule == .media
            }) }
        )
        let systemStatusModuleStore = SystemStatusModuleStore(
            isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded
                    && islandActivityCoordinator.selectedModule == .system
            }
        )
        let aiUsageModuleStore = AIUsageModuleStore(
            makeProvider: { TokenTrackerClient(port: settings.aiUsageServerPort) },
            isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded
                    && islandActivityCoordinator.selectedModule == .aiUsage
            },
            notchMetric: { settings.aiUsageNotchMetric },
            alertsEnabled: { settings.aiUsageLimitAlertsEnabled }
        )
        let favoriteFoldersStore = FavoriteFoldersStore(
            persistence: FavoriteFoldersPersistenceController(),
            bookmarkService: importCoordinator.bookmarkService
        )
        let favoriteFolderDropCoordinator = FavoriteFolderDropCoordinator(folders: favoriteFoldersStore,
                                                                          bookmarks: importCoordinator.bookmarkService)
        let shelfRuntime = CallbackIslandModuleRuntime(
            descriptor: islandModuleRegistry.descriptor(for: .shelf)!
        )
        let transfersModuleRuntime = TransfersModuleRuntime(
            transferStore: importCoordinator.transferStore
        )
        // Recording belongs to the app lifecycle, independently of Island.
        let clipboardRuntime = CallbackIslandModuleRuntime(
            descriptor: islandModuleRegistry.descriptor(for: .clipboard)!
        )
        let timerModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: islandTimerStore.descriptor,
            start: { islandTimerStore.start() },
            stop: { islandTimerStore.stop() }
        )
        let batteryModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: powerSourceMonitor.descriptor,
            start: { powerSourceMonitor.start() },
            stop: { powerSourceMonitor.stop() }
        )
        let mediaModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: nowPlayingModuleStore.descriptor,
            start: { nowPlayingModuleStore.start() },
            stop: { nowPlayingModuleStore.stop() }
        )
        let favoriteFoldersModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: islandModuleRegistry.descriptor(for: .folders)!,
            start: { favoriteFoldersStore.start() },
            stop: { favoriteFoldersStore.stop(); favoriteFolderDropCoordinator.cancelCopy() }
        )
        self.islandActivityCoordinator = islandActivityCoordinator
        self.islandModuleRegistry = islandModuleRegistry
        self.islandTimerStore = islandTimerStore
        self.powerSourceMonitor = powerSourceMonitor
        self.nowPlayingModuleStore = nowPlayingModuleStore
        self.systemStatusModuleStore = systemStatusModuleStore
        self.aiUsageModuleStore = aiUsageModuleStore
        self.favoriteFoldersStore = favoriteFoldersStore
        self.favoriteFolderDropCoordinator = favoriteFolderDropCoordinator
        self.transfersModuleRuntime = transfersModuleRuntime
        self.timerModuleRuntime = timerModuleRuntime
        self.batteryModuleRuntime = batteryModuleRuntime
        self.mediaModuleRuntime = mediaModuleRuntime
        self.favoriteFoldersModuleRuntime = favoriteFoldersModuleRuntime
        self.islandModuleContainer = IslandModuleContainer(
            registrations: [
                IslandModuleRegistration(
                    descriptor: IslandModuleRegistry.quickSettingsDescriptor,
                    runtime: CallbackIslandModuleRuntime(descriptor: IslandModuleRegistry.quickSettingsDescriptor),
                    makeContentView: { context in
                        AnyView(IslandModuleLibraryView(onOpenSettings: {
                            islandActivityCoordinator.collapse()
                            onOpenModuleSettings()
                        }))
                    }
                ),
                IslandModuleRegistration(
                    descriptor: clipboardRuntime.descriptor,
                    runtime: clipboardRuntime,
                    makeContentView: { _ in AnyView(ClipboardHistoryView(isIsland: true)) }
                ),
                IslandModuleRegistration(
                    descriptor: shelfRuntime.descriptor,
                    runtime: shelfRuntime,
                    makeContentView: { _ in AnyView(IslandShelfModuleView()) }
                ),
                IslandModuleRegistration(
                    descriptor: transfersModuleRuntime.descriptor,
                    runtime: transfersModuleRuntime,
                    makeContentView: { context in
                        AnyView(IslandTransfersView(
                            onPerformRecovery: context.onPerformRecovery
                        ))
                    }
                ),
                IslandModuleRegistration(
                    descriptor: timerModuleRuntime.descriptor,
                    runtime: timerModuleRuntime,
                    makeContentView: { _ in AnyView(IslandTimerView()) }
                ),
                IslandModuleRegistration(
                    descriptor: batteryModuleRuntime.descriptor,
                    runtime: batteryModuleRuntime,
                    makeContentView: { _ in AnyView(IslandBatteryView()) }
                ),
                IslandModuleRegistration(
                    descriptor: systemStatusModuleStore.descriptor,
                    runtime: systemStatusModuleStore,
                    makeContentView: { _ in AnyView(IslandSystemStatusView()) }
                ),
                IslandModuleRegistration(
                    descriptor: mediaModuleRuntime.descriptor,
                    runtime: mediaModuleRuntime,
                    makeContentView: { _ in
                        AnyView(IslandNowPlayingView())
                    }
                ),
                IslandModuleRegistration(
                    descriptor: favoriteFoldersModuleRuntime.descriptor,
                    runtime: favoriteFoldersModuleRuntime,
                    makeContentView: { _ in AnyView(FavoriteFoldersModuleView()) }
                ),
                IslandModuleRegistration(
                    descriptor: aiUsageModuleStore.descriptor,
                    runtime: aiUsageModuleStore,
                    makeContentView: { _ in AnyView(IslandAIUsageView()) }
                ),
            ],
            coordinator: islandActivityCoordinator
        )
        self.classicDragOutController = DragOutController(
            store: store,
            settings: settings,
            recents: recents,
            bookmarkService: importCoordinator.bookmarkService,
            deliveryCoordinator: deliveryCoordinator,
            tutorialTokenForItem: tutorialTokenForItem
        )
        self.islandDragOutController = DragOutController(
            store: store,
            settings: settings,
            recents: recents,
            bookmarkService: importCoordinator.bookmarkService,
            deliveryCoordinator: deliveryCoordinator,
            tutorialTokenForItem: tutorialTokenForItem
        )
        self.quickLookCoordinator = QuickLookCoordinator(
            store: store,
            bookmarkService: importCoordinator.bookmarkService,
            tempFileService: tempFileService
        )
        self.itemRecoveryController = ItemRecoveryController(
            store: store,
            bookmarkService: importCoordinator.bookmarkService,
            notices: importCoordinator.noticeCenter,
            openStorageRecovery: onOpenStorageRecovery
        )
        self.shelfActionRunner = ShelfActionRunner(
            bookmarkService: importCoordinator.bookmarkService,
            notices: importCoordinator.noticeCenter
        )
        super.init()
        islandPresentation.connect()
        islandTimerStore.onActivity = { [weak self] activity in
            self?.timerModuleRuntime.replaceActivity(activity)
            if activity?.priority == .timerFinished,
               self?.settings.isIslandModuleAvailable(.timer) == true,
               let self,
               self.settings.islandEnabled,
               self.hasAvailableIslandDisplay,
               self.islandActivityCoordinator.surfaceState != .pinned {
                self.islandActivityCoordinator.show(module: .timer)
            }
        }
        powerSourceMonitor.onActivity = { [weak self] activity in
            self?.batteryModuleRuntime.replaceActivity(activity)
        }
        favoriteFolderDropCoordinator.onActivity = { [weak self] activity in
            self?.favoriteFoldersModuleRuntime.replaceActivity(activity)
        }
        nowPlayingModuleStore.onActivity = { [weak self] activity in
            self?.mediaModuleRuntime.replaceActivity(activity)
        }
        // Item updates can animate the height and trigger empty-Shelf auto-hide.
        store.onItemsDidChange = { [weak self] in
            self?.handleItemsDidChange()
        }
        store.onSelectionDidChange = { [weak self] in
            self?.handleQuickActionVisibilityDidChange()
        }
        interaction.onActionSelectionDidChange = { [weak self] in
            self?.handleQuickActionVisibilityDidChange()
        }
        importCoordinator.transferStore.onVisibilityDidChange = { [weak self] in
            self?.handleActivityVisibilityDidChange()
        }
        // DragSessionController reports a successful drop only when the operation
        // is nonempty. Read the current auto-hide preference when the callback runs.
        classicDragOutController.onSuccessfulDrop = { [weak self] in
            guard let self,
                  self.onboardingPresentationCount == 0,
                  self.settings.autoHide else { return }
            self.hideShelf(animated: true)
        }
        islandDragOutController.onSuccessfulDrop = { [weak self] in
            guard let self,
                  self.onboardingPresentationCount == 0,
                  self.settings.autoHide else { return }
            self.collapseIsland(animated: true)
        }
        quickLookCoordinator.onNavigationKey = { [weak self] event in
            guard let self else { return false }
            let panel = self.islandPanel.isVisible ? self.islandPanel : self.classicPanel
            return self.handleItemKeyDown(event, in: panel)
        }
        quickLookCoordinator.sourceWindowLevel = { [weak self] in
            guard let self else { return .normal }
            return self.islandPanel.isVisible ? self.islandPanel.level : self.classicPanel.level
        }
        quickLookCoordinator.onPreviewVisibilityChanged = { [weak self] visible in
            self?.islandPresentation.setQuickLookVisible(visible)
        }
        // Restore keyboard focus to a visible Shelf after Quick Look closes
        // so Space, Delete, and Escape work without activating Clerestory.
        quickLookCoordinator.onPanelClosed = { [weak self] in
            guard let self,
                  self.appState.isShelfVisible
                    || self.islandActivityCoordinator.surfaceState.isExpanded else { return }
            if self.islandActivityCoordinator.surfaceState.isExpanded {
                self.islandPanel.makeKey()
            } else if self.classicPanel.isVisible {
                self.classicPanel.makeKey()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Revalidate the frame in place after switching Spaces.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        // Animate to the new frame when the position or width changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        quickActionLayoutTask?.cancel()
        classicHoverExitTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public API

    func shutdown() {
        islandNotchPanel.orderOut(nil)
        islandNoticePanel?.stop()
        setIslandDragZoneActive(false)
        favoriteFolderDropCoordinator.cancelCopy()
        quickActionLayoutTask?.cancel()
        classicHoverExitTask?.cancel()
        stopClassicHoverPreviewMonitoring()
        stopIslandModules()
        islandPresentation.deactivate()
    }

    func toggleShelf(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic:
            if appState.isShelfVisible {
                if classicHoverPreviewState.isPreview {
                    promoteClassicHoverPreview()
                } else {
                    hideShelf(animated: animated)
                }
            } else {
                showShelf(animated: animated)
            }
        case .island:
            guard hasAvailableIslandDisplay else { return }
            islandActivityCoordinator.toggle()
        case nil:
            break
        }
    }

    /// Global-hot-key entry point: showing the shelf also makes its
    /// nonactivating panel key so the user can continue entirely by keyboard.
    func toggleShelfForKeyboard(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic:
            if appState.isShelfVisible {
                if classicHoverPreviewState.isPreview {
                    promoteClassicHoverPreview()
                    classicPanel.makeKey()
                } else {
                    hideShelf(animated: animated)
                }
            } else {
                showShelf(animated: animated, takeKeyboardFocus: true)
            }
        case .island:
            guard hasAvailableIslandDisplay else { return }
            if islandActivityCoordinator.surfaceState.isExpanded {
                collapseIsland(animated: animated)
            } else {
                showIslandShelf(animated: animated, takeKeyboardFocus: true)
            }
        case nil:
            break
        }
    }

    func showPreferredShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        switch effectivePreferredShelfSurface {
        case .classic:
            showShelf(animated: animated, takeKeyboardFocus: takeKeyboardFocus)
        case .island:
            showIslandShelf(animated: animated, takeKeyboardFocus: takeKeyboardFocus)
        case nil:
            break
        }
    }

    func hidePreferredShelf(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic: hideShelf(animated: animated)
        case .island: collapseIsland(animated: animated)
        case nil: break
        }
    }

    /// Slides and fades in from the attached screen edge.
    func showShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        guard SideShelfAvailability.isEnabled else { return }
        onClassicPresentationRequested?()
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isOpeningClassicHoverPreview {
            performClassicHoverActions(
                classicHoverPreviewState.handle(.persistentInteraction)
            )
        }
        guard settings.classicShelfEnabled else { return }
        // Repeated show requests may promote a preview or request focus, but
        // must not put an already visible/sliding panel back offscreen.
        if appState.isShelfVisible {
            if takeKeyboardFocus, interaction.focusedItemID == nil {
                interaction.focusedItemID = store.selectedItems.first?.id ?? store.items.first?.id
            }
            applyClassicLayout(animated: animated)
            if takeKeyboardFocus { classicPanel.makeKey() }
            return
        }
        itemRecoveryController.refreshAll()
        interaction.normalize(for: store.items)
        if takeKeyboardFocus, interaction.focusedItemID == nil {
            interaction.focusedItemID = store.selectedItems.first?.id ?? store.items.first?.id
        }
        let generation = classicVisibilityTransition.request(visible: true)
        let wasOnscreen = classicPanel.isVisible
        appState.showShelf()
        let targetFrame = classicTargetFrame()
        _ = classicFrameTransition.request(targetFrame, currentFrame: classicLogicalFrame)
        guard animated else {
            endClassicMorph()
            classicReveal.showImmediately()
            classicPanel.hasShadow = classicWantsWindowShadow
            classicPanel.alphaValue = 1
            classicPanel.setFrame(targetFrame, display: false)
            presentClassicPanel()
            if takeKeyboardFocus { classicPanel.makeKey() }
            return
        }
        if let origin = classicRevealOrigin(for: targetFrame), let generation {
            growClassicShelf(from: origin, to: targetFrame, wasOnscreen: wasOnscreen,
                             generation: generation, takeKeyboardFocus: takeKeyboardFocus)
            return
        }
        endClassicMorph()
        classicReveal.showImmediately()
        classicPanel.hasShadow = classicWantsWindowShadow
        // A closing panel is still onscreen. Reverse from its current frame and
        // alpha instead of jumping back to the fully hidden starting position.
        if !wasOnscreen {
            classicPanel.alphaValue = 0
            classicPanel.setFrame(classicHiddenFrame(for: targetFrame), display: false)
        }
        presentClassicPanel()
        if takeKeyboardFocus { classicPanel.makeKey() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            classicPanel.animator().alphaValue = 1
            classicPanel.animator().setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Edge tab ↔ shelf morph (issue #10)

    /// Native Liquid Glass already renders its edge. An AppKit shadow adds
    /// a second dark rim that appears all at once after the transition.
    /// Other materials rely on the window shadow for depth.
    private var classicWantsWindowShadow: Bool {
        !settings.appearance.usesNativeGlass(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    /// Returns the edge tab's frame in glass coordinates. Custom placement
    /// has no attached edge and falls back to the slide and fade transition.
    private func classicRevealOrigin(for panelFrame: NSRect) -> CGRect? {
        let surface = panelFrame.insetBy(dx: Self.classicSurfaceInset, dy: Self.classicSurfaceInset)
        let visibleFrame = Self.screen(containing: CGPoint(x: panelFrame.midX, y: panelFrame.midY))
            .visibleFrame
        guard let tab = ShelfLayoutEngine.edgeTabFrame(position: settings.shelfPosition,
                                                       offset: CGFloat(settings.shelfEdgeOffset),
                                                       visibleFrame: visibleFrame) else { return nil }
        return ShelfLayoutEngine.revealOriginRect(surfaceFrame: surface, tabFrame: tab,
                                                  position: settings.shelfPosition,
                                                  windowInset: Self.classicSurfaceInset)
    }

    /// Orders the panel in front of whatever is on screen, including another
    /// app's full-screen Space. Re-asserting the collection behavior makes
    /// AppKit re-join the active Space; a plain `orderFront` from an inactive
    /// app can leave the panel behind on the Space it last appeared on.
    private func presentClassicPanel() {
        // `.moveToActiveSpace` forces the panel into the Space that is on
        // screen right now, which fixes the first reveal inside a brand-new
        // full-screen Space. It cannot be combined with `.canJoinAllSpaces`,
        // so the panel switches to all-spaces behavior right after ordering.
        classicPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        classicPanel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.classicPanel.collectionBehavior =
                    [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            }
        }
    }

    /// Position the window at its final frame first. Animate the SwiftUI glass
    /// surface from the edge tab so the grid stays laid out at its final size.
    private func growClassicShelf(from origin: CGRect, to targetFrame: NSRect, wasOnscreen: Bool,
                                  generation: UInt, takeKeyboardFocus: Bool) {
        // AppKit's shadow can retain an intermediate window shape. Restore and
        // recalculate it after the glass transition completes.
        isClassicMorphing = true
        classicPanel.hasShadow = false
        if !wasOnscreen {
            classicReveal.pinSurfaceHeight(nil)
            classicReveal.prepareCollapsed(at: origin)
        }
        classicReveal.capturesWholeSurface = dragStartMonitor.isDragInProgress
        // Use a quicker transition without bounce for hover previews.
        let quick = isOpeningClassicHoverPreview
        classicPanel.alphaValue = 1
        if classicPanel.frame != targetFrame {
            resetClassicSurfaceHeight()
            classicPanel.setFrame(targetFrame, display: false)
        }
        presentClassicPanel()
        if takeKeyboardFocus { classicPanel.makeKey() }
        // Commit the collapsed state for one frame so SwiftUI cannot coalesce both states and skip the animation.
        classicPanel.contentView?.layoutSubtreeIfNeeded()
        classicPanel.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.classicVisibilityTransition.isCurrent(generation, visible: true) else { return }
                self.classicReveal.expand(quick: quick)
                let settle = quick ? ShelfRevealState.quickExpandSettleDuration
                                   : ShelfRevealState.expandSettleDuration
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              self.classicVisibilityTransition.isCurrent(generation, visible: true)
                        else { return }
                        self.finishClassicGrow(generation: generation)
                    }
                }
            }
        }
    }

    private func finishClassicGrow(generation: UInt) {
        // Remove the drop fallback overlay and wait for SwiftUI to redraw before
        // recalculating the shadow. Otherwise the shadow follows the overlay's rectangle.
        let hadWholeSurfaceCapture = classicReveal.capturesWholeSurface
        classicReveal.capturesWholeSurface = false
        let restore = { [weak self] in
            guard let self,
                  self.classicVisibilityTransition.isCurrent(generation, visible: true) else { return }
            self.endClassicMorph()
            self.classicPanel.hasShadow = self.classicWantsWindowShadow
            self.classicPanel.invalidateShadow()
        }
        if hadWholeSurfaceCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { restore() }
            }
        } else {
            restore()
        }
    }

    /// Applies layout requests that were deferred during the edge-tab transition.
    private func endClassicMorph() {
        guard isClassicMorphing else { return }
        isClassicMorphing = false
        if isClassicLayoutDeferred {
            isClassicLayoutDeferred = false
            applyClassicLayout(animated: true)
        }
    }

    /// Fades the content, shrinks the glass to the edge tab, then orders out the window and reveals the tab.
    private func foldClassicShelf(into origin: CGRect, generation: UInt) {
        isClassicMorphing = true
        classicPanel.hasShadow = false
        classicReveal.capturesWholeSurface = false
        classicReveal.collapse(to: origin)
        DispatchQueue.main.asyncAfter(deadline: .now() + ShelfRevealState.collapseDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.classicVisibilityTransition.isCurrent(generation, visible: false),
                      !self.appState.isShelfVisible else { return }
                // The next presentation recomputes the target frame using the latest layout.
                self.isClassicLayoutDeferred = false
                self.isClassicMorphing = false
                self.classicPanel.orderOut(nil)
            }
        }
    }

    func showIslandShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        guard settings.islandEnabled, settings.islandShelfEnabled,
              hasAvailableIslandDisplay else { return }
        itemRecoveryController.refreshAll()
        interaction.normalize(for: store.items)
        if takeKeyboardFocus, interaction.focusedItemID == nil {
            interaction.focusedItemID = store.selectedItems.first?.id ?? store.items.first?.id
        }
        islandActivityCoordinator.show(module: .shelf)
        islandPanel.orderFront(nil)
        if takeKeyboardFocus { islandPanel.makeKey() }
    }

    /// Onboarding saves the prior visibility, pauses auto-hide, and shows Shelf.
    /// When the lease ends, it restores visibility without writing preferences.
    func beginOnboardingPresentation() -> OnboardingPresentationSnapshot {
        let surface = effectivePreferredShelfSurface ?? .classic
        let wasVisible = surface == .classic
            ? appState.isShelfVisible
            : islandActivityCoordinator.surfaceState.isExpanded
        let snapshot = OnboardingPresentationSnapshot(surface: surface, wasVisible: wasVisible)
        onboardingPresentationCount += 1
        if !wasVisible {
            if surface == .island {
                showIslandShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            } else {
                showShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
        return snapshot
    }

    func endOnboardingPresentation(_ snapshot: OnboardingPresentationSnapshot) {
        onboardingPresentationCount = max(0, onboardingPresentationCount - 1)
        guard onboardingPresentationCount == 0, !snapshot.wasVisible else { return }
        if snapshot.surface == .island {
            collapseIsland(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else if appState.isShelfVisible {
            hideShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// Onboarding can lay out against the target frame while Shelf is hidden,
    /// without creating or showing the panel.
    var visibleOrTargetFrame: CGRect {
        if effectivePreferredShelfSurface == .island {
            return islandActivityCoordinator.surfaceState.isExpanded
                ? islandPanel.interactionFrame : islandPresentation.islandLayout().expandedFrame
        }
        return appState.isShelfVisible ? classicLogicalFrame : classicTargetFrame()
    }

    /// Slides and fades out toward the attached edge, then orders the window out.
    func hideShelf(animated: Bool = true) {
        onClassicPresentationRequested?()
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        performClassicHoverActions(classicHoverPreviewState.handle(.shelfHidden))
        guard appState.isShelfVisible else { return }
        stopClassicHoverPreviewMonitoring()
        quickActionLayoutTask?.cancel()
        quickActionLayoutTask = nil
        let generation = classicVisibilityTransition.request(visible: false)
        classicResizeGeneration &+= 1
        let visibleFrame = classicFrameTransition.targetFrame ?? classicLogicalFrame
        appState.hideShelf()
        classicFrameTransition.reset()
        // Close Quick Look and release its resources as Shelf hides, without restoring keyboard focus.
        quickLookCoordinator.closeForShelfHide()
        let targetFrame = classicHiddenFrame(for: visibleFrame)
        guard animated else {
            classicPanel.orderOut(nil)
            isClassicMorphing = false
            isClassicLayoutDeferred = false
            classicReveal.showImmediately()
            classicPanel.hasShadow = classicWantsWindowShadow
            return
        }
        if let generation, let origin = classicRevealOrigin(for: classicLogicalFrame) {
            foldClassicShelf(into: origin, generation: generation)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            classicPanel.animator().alphaValue = 0
            classicPanel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in
            // Let a new show request interrupt the hide transition.
            MainActor.assumeIsolated {
                guard let self, let generation,
                      self.classicVisibilityTransition.isCurrent(generation, visible: false),
                      !self.appState.isShelfVisible else { return }
                self.classicPanel.orderOut(nil)
            }
        })
    }

    func collapseIsland(animated: Bool = true) {
        guard settings.islandEnabled else { return }
        islandPresentation.resetIslandHoverPreview(restoreSelection: true)
        quickLookCoordinator.closeForShelfHide()
        islandPresentation.logIslandPresentation("collapse-request")
        islandActivityCoordinator.collapse()
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            islandPresentation.hideImmediately()
        }
    }

    // MARK: - Classic shelf hover preview

    /// EdgeTabController forwards pointer changes here so the preview state is
    /// shared with the actual shelf window and all persistent interactions.
    func classicEdgeTabHoverChanged(_ hovering: Bool) {
        guard settings.classicShelfHoverRevealEnabled,
              settings.classicShelfEnabled,
              settings.edgeTabEnabled,
              settings.shelfPosition != .custom,
              !dragStartMonitor.isDragInProgress,
              !IgnoreListService.frontmostAppIsIgnored(
                in: settings.ignoredAppBundleIDs
              ) else {
            suppressClassicHoverPreview()
            return
        }
        let event: ClassicShelfHoverPreviewStateMachine.Event = hovering
            ? .tabEntered : .tabExited
        performClassicHoverActions(classicHoverPreviewState.handle(event))
    }

    func suppressClassicHoverPreview() {
        performClassicHoverActions(classicHoverPreviewState.handle(.suppress))
    }

    func promoteClassicHoverPreviewIfNeeded() {
        guard classicHoverPreviewState.isPreview else { return }
        promoteClassicHoverPreview()
    }

    private func promoteClassicHoverPreview() {
        performClassicHoverActions(
            classicHoverPreviewState.handle(.persistentInteraction)
        )
    }

    private func performClassicHoverActions(
        _ actions: [ClassicShelfHoverPreviewStateMachine.Action]
    ) {
        for action in actions {
            switch action {
            case .scheduleDwell:
                // `mouseEntered` already expresses the user's proximity
                // intent. Reveal in the same event turn; only mouse exit keeps
                // a grace period so crossing from the tab into the shelf does
                // not make the panel flicker.
                performClassicHoverActions(
                    classicHoverPreviewState.handle(.dwellElapsed)
                )
            case .cancelDwell:
                continue
            case .showPreview:
                guard !appState.isShelfVisible else { continue }
                isOpeningClassicHoverPreview = true
                showShelf(animated: true, takeKeyboardFocus: false)
                isOpeningClassicHoverPreview = false
                startClassicHoverPreviewMonitoring()
                updateClassicHoverPreviewPointer(at: NSEvent.mouseLocation)
            case .scheduleExit:
                guard classicHoverExitTask == nil else { continue }
                classicHoverExitTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, !Task.isCancelled else { return }
                    self.classicHoverExitTask = nil
                    self.performClassicHoverActions(
                        self.classicHoverPreviewState.handle(.exitElapsed)
                    )
                }
            case .cancelExit:
                classicHoverExitTask?.cancel()
                classicHoverExitTask = nil
            case .hidePreview:
                stopClassicHoverPreviewMonitoring()
                if appState.isShelfVisible { hideShelf(animated: true) }
            case .promoteToPersistent:
                classicHoverExitTask?.cancel()
                classicHoverExitTask = nil
                stopClassicHoverPreviewMonitoring()
            }
        }
    }

    private func startClassicHoverPreviewMonitoring() {
        guard classicHoverGlobalMonitor == nil, classicHoverLocalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged,
        ]
        classicHoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleClassicHoverPreviewEvent(event, at: point) }
        }
        classicHoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleClassicHoverPreviewEvent(event, at: point) }
            return event
        }
    }

    private func stopClassicHoverPreviewMonitoring() {
        if let classicHoverGlobalMonitor {
            NSEvent.removeMonitor(classicHoverGlobalMonitor)
            self.classicHoverGlobalMonitor = nil
        }
        if let classicHoverLocalMonitor {
            NSEvent.removeMonitor(classicHoverLocalMonitor)
            self.classicHoverLocalMonitor = nil
        }
    }

    private func handleClassicHoverPreviewEvent(_ event: NSEvent, at point: CGPoint) {
        guard classicHoverPreviewState.isPreview else { return }
        guard !IgnoreListService.frontmostAppIsIgnored(
            in: settings.ignoredAppBundleIDs
        ) else {
            suppressClassicHoverPreview()
            return
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged:
            if classicLogicalFrame.contains(point) { promoteClassicHoverPreview() }
        case .mouseMoved:
            updateClassicHoverPreviewPointer(at: point)
        default:
            break
        }
    }

    private func updateClassicHoverPreviewPointer(at point: CGPoint) {
        let event: ClassicShelfHoverPreviewStateMachine.Event = classicLogicalFrame
            .insetBy(dx: -2, dy: -2).contains(point) ? .shelfEntered : .shelfExited
        performClassicHoverActions(classicHoverPreviewState.handle(event))
    }

    private var effectivePreferredShelfSurface: SettingsStore.PreferredShelfSurface? {
        settings.effectivePreferredShelfSurface
    }

    // MARK: - Item keyboard handling (S6)

    /// Arrow keys select the focused item. Shift plus an arrow adjusts an
    /// anchored range. Quick Look forwards navigation here so the preview and
    /// Shelf selection agree. Quick Look handles its own Space and Escape keys.
    ///
    /// A card click makes Shelf key through CardDragSourceAnchorView.mouseUp.
    /// Pass through global shortcuts such as Command-Shift-Space for AppDelegate.
    private func handleItemKeyDown(_ event: NSEvent, in sourcePanel: ShelfPanel) -> Bool {
        if let editor = sourcePanel.firstResponder as? NSTextView, editor.isFieldEditor { return false }
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.subtract([.capsLock, .function, .numericPad])

        // The global summon shortcut is user-configurable and may equal one
        // of the fixed quick-action combinations below. In that case it keeps
        // priority; never execute a shelf action from the same key press.
        if settings.hotKeyEnabled,
           let globalShortcut = settings.hotKeyShortcut,
           HotKeyMonitor.matches(event, shortcut: globalShortcut) {
            return false
        }

        if sourcePanel === islandPanel,
           islandActivityCoordinator.selectedModule == .clipboard {
            if event.keyCode == 53, modifiers.isEmpty {
                collapseIsland(animated: true)
                return true
            }
            return false
        }

        if sourcePanel === islandPanel,
           islandActivityCoordinator.selectedModule == .folders {
            return handleFavoriteFoldersKeyDown(event, modifiers: modifiers)
        }

        if modifiers == [.command, .option],
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            return performKeyboardAction(.copyPath)
        }
        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "j" {
            return performKeyboardAction(.revealInFinder)
        }
        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            return performKeyboardAction(.share, relativeTo: sourcePanel.contentView)
        }

        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                return store.undoLastRemoval()
            case "a":
                selectAllVisibleItems()
                return true
            case "c":
                return copyKeyboardItems()
            default:
                return false
            }
        }

        if modifiers.isEmpty || modifiers == .shift {
            let extending = modifiers == .shift
            let direction: ShelfArrowDirection?
            switch event.keyCode {
            case 123: direction = .left
            case 124: direction = .right
            case 125: direction = .down
            case 126: direction = .up
            default: direction = nil
            }
            if let direction {
                return moveKeyboardFocus(
                    direction,
                    extendingSelection: extending,
                    panelWidth: sourcePanel.frame.width
                )
            }
        }

        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 49: // Space
            return quickLookCoordinator.toggle(contextItem: focusedItem())
        case 36, 76: // Return / keypad Enter
            return openFocusedItem()
        case 51, 117: // Delete / Forward Delete
            return removeKeyboardItems()
        case 53: // Escape
            if quickLookCoordinator.isPreviewing {
                quickLookCoordinator.dismiss()
                return true
            }
            if interaction.clearActiveSelection(in: store) { return true }
            if interaction.expandedStackID != nil {
                interaction.exitStack()
                return true
            }
            if sourcePanel === islandPanel {
                collapseIsland(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                return true
            }
            hideShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            return true
        default:
            return false
        }
    }

    private func handleFavoriteFoldersKeyDown(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 123: return favoriteFoldersStore.selectRelative(delta: -1)
        case 124: return favoriteFoldersStore.selectRelative(delta: 1)
        case 125: return favoriteFoldersStore.selectRelative(delta: 2)
        case 126: return favoriteFoldersStore.selectRelative(delta: -2)
        case 36, 76: return favoriteFoldersStore.openSelected()
        case 51, 117: return favoriteFoldersStore.removeSelected()
        case 53:
            collapseIsland(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            return true
        default:
            return false
        }
    }

    private func visibleKeyboardItems() -> [ShelfItem] {
        interaction.visibleItems(in: store.visibleItems)
    }

    private func focusedItem() -> ShelfItem? {
        let visible = visibleKeyboardItems()
        if let focusedItemID = interaction.focusedItemID,
           let item = visible.first(where: { $0.id == focusedItemID }) {
            return item
        }
        return nil
    }

    private func moveKeyboardFocus(_ direction: ShelfArrowDirection,
                                   extendingSelection: Bool,
                                   panelWidth: CGFloat) -> Bool {
        let visible = visibleKeyboardItems()
        guard !visible.isEmpty else { return false }
        let currentIndex: Int
        var hasCurrentItem = true
        if let focusedItemID = interaction.focusedItemID,
           let index = visible.firstIndex(where: { $0.id == focusedItemID }) {
            currentIndex = index
        } else if interaction.expandedStackID == nil,
                  let selected = visible.firstIndex(where: { store.selection.contains($0.id) }) {
            currentIndex = selected
        } else {
            currentIndex = 0
            hasCurrentItem = false
        }
        let destination = ShelfKeyboardNavigator.destinationIndex(
            currentIndex: currentIndex,
            itemCount: visible.count,
            columnCount: islandPanel.isVisible && interaction.expandedStackID == nil
                ? ShelfLayoutEngine.gridColumnCount(for: IslandExpandedLayout.contentWidth(
                    surfaceWidth: panelWidth))
                : ShelfLayoutEngine.columnCount(forPanelWidth: panelWidth),
            direction: direction
        )
        interaction.moveSelection(in: visible, from: currentIndex,
                                  to: hasCurrentItem ? destination : 0,
                                  extending: extendingSelection, store: store)
        quickLookCoordinator.refreshPreview(contextItem: focusedItem())
        return true
    }

    private func selectAllVisibleItems() {
        let visible = visibleKeyboardItems()
        guard !visible.isEmpty else { return }
        if interaction.expandedStackID != nil {
            interaction.childSelection = Set(visible.map(\.id))
        } else {
            store.selectAllVisible()
        }
        if interaction.focusedItemID == nil {
            interaction.focusedItemID = visible[0].id
        }
    }

    private func keyboardActionItems() -> [ShelfItem] {
        let visible = visibleKeyboardItems()
        if interaction.expandedStackID != nil {
            let selected = visible.filter { interaction.childSelection.contains($0.id) }
            if !selected.isEmpty { return selected }
        } else {
            let selected = visible.filter { store.selection.contains($0.id) }
            if !selected.isEmpty { return selected }
        }
        if interaction.isSelecting { return [] }
        guard let focusedItemID = interaction.focusedItemID,
              let focused = visible.first(where: { $0.id == focusedItemID }) else { return [] }
        return [focused]
    }

    private func copyKeyboardItems() -> Bool {
        let items = keyboardActionItems()
        guard !items.isEmpty else { return false }
        let result = ClipboardController.copy(
            items,
            bookmarkService: importCoordinator.bookmarkService
        )
        importCoordinator.noticeCenter.show(ClipboardController.notice(for: result))
        return true
    }

    private func performKeyboardAction(_ action: ShelfAction,
                                       relativeTo anchorView: NSView? = nil) -> Bool {
        let items = keyboardActionItems()
        guard !items.isEmpty, ShelfActionCatalog.canPerform(action, on: items) else {
            return false
        }
        shelfActionRunner.perform(action, on: items, relativeTo: anchorView)
        return true
    }

    private func openFocusedItem() -> Bool {
        guard let item = focusedItem() else { return false }
        if interaction.isSelecting, interaction.expandedStackID == nil {
            store.toggleSelection(item.id)
            return true
        }
        if item.availability != .available {
            itemRecoveryController.recover(item)
            return true
        }
        if item.kind == .stack {
            guard ShelfStackAvailability.isEnabled else { return false }
            if interaction.expandedStackID == item.id {
                interaction.exitStack()
            } else {
                interaction.enterStack(item)
            }
            return true
        }
        guard ItemActions.canOpen(item) else { return false }
        ItemActions.open(item,
                         bookmarkService: importCoordinator.bookmarkService,
                         tempFileService: tempFileService)
        return true
    }

    private func removeKeyboardItems() -> Bool {
        let previous = isUserRemovalInProgress
        isUserRemovalInProgress = true
        defer { isUserRemovalInProgress = previous }
        let items = keyboardActionItems()
        guard !items.isEmpty else { return false }
        let ids = Set(items.map(\.id))
        if let stackID = interaction.expandedStackID {
            guard store.removeChildrenForUser(ids: ids, fromStack: stackID) else { return false }
            interaction.childSelection.subtract(ids)
        } else {
            do {
                try store.removeBatchForUser(ids: ids)
            } catch {
                importCoordinator.noticeCenter.show(.removalFailed)
                return true
            }
        }
        interaction.normalize(for: store.items)
        quickLookCoordinator.refreshPreview(contextItem: focusedItem())
        return true
    }

    // MARK: - Layout

    /// SettingsStore supplies position and width. ShelfLayoutEngine computes
    /// the frame from display geometry and item count. Edge placement uses the
    /// pointer's display and falls back to the main display when necessary.
    /// Height fits the content up to 80% of the visible screen height.
    /// shelfEdgeOffset controls vertical placement from 0 (bottom) to 1 (top).
    /// Custom placement uses a validated saved frame or starts at the target
    /// display's right edge when the saved display is unavailable.
    private func classicTargetFrame() -> NSRect {
        ShelfLayoutEngine.targetFrame(
            position: settings.shelfPosition,
            width: settings.shelfWidth,
            itemCount: store.items.count,
            hasActivity: importCoordinator.transferStore.hasVisibleActivity,
            hasQuickActions: hasVisibleQuickActions,
            hasSearchControls: true,
            mouseLocation: NSEvent.mouseLocation,
            screens: Self.screenGeometries(),
            persistedCustomFrame: settings.customShelfFrame,
            edgeOffset: CGFloat(settings.shelfEdgeOffset)
        )
    }

    private var hasVisibleQuickActions: Bool {
        guard !interaction.isSelecting else { return false }
        let items = ShelfActionSelectionResolver.explicitItems(
            topLevelItems: store.items,
            topLevelSelection: store.selection,
            expandedStackID: interaction.expandedStackID,
            childSelection: interaction.childSelection
        )
        return ShelfActionCatalog.hasAnyAction(for: items)
    }

    /// Edge placement slides one panel width offscreen. Custom placement fades in place.
    private func classicHiddenFrame(for frame: NSRect) -> NSRect {
        ShelfLayoutEngine.hiddenFrame(for: frame, position: settings.shelfPosition)
    }

    /// Captures display geometry as values for ShelfLayoutEngine.
    private static func screenGeometries() -> [ShelfLayoutEngine.ScreenGeometry] {
        NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    /// Finds the screen containing the point, falling back to the main screen.
    /// EdgeTriggerMonitor shares this lookup so the trigger and Shelf open on the same display.
    static func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens[0]
    }

    /// Recompute a visible Shelf's frame after display or resolution changes.
    /// When the selected display disappears, use the main display. A saved
    /// custom frame outside every screen falls back to the default right edge.
    /// A hidden Shelf calculates its frame the next time it opens.
    @objc private func screenParametersDidChange(_ notification: Notification) {
        if appState.isShelfVisible {
            let target = classicTargetFrame()
            _ = classicFrameTransition.request(target, currentFrame: classicLogicalFrame)
            resetClassicSurfaceHeight()
            classicPanel.setFrame(target, display: true)
        }
        applyPresentationSettings()
    }

    /// The stationary window joins all Spaces at the same global coordinates.
    /// After a Space switch, clamp its existing frame without animation if needed.
    /// Following the pointer here could move Shelf to a different display.
    ///
    /// NotificationCenter delivers synchronously on the posting thread, so this
    /// selector stays nonisolated and dispatches window work to the main actor.
    @objc private nonisolated func activeSpaceDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.islandPresentation.logIslandPresentation("active-space-changed")
            self.revalidateFrameAfterSpaceChange()
        }
    }

    private func revalidateFrameAfterSpaceChange() {
        if settings.islandEnabled,
           IslandScreenCatalog.selectedScreen(for: .automatic,
                                              pointerPoint: NSEvent.mouseLocation) != nil {
            // A desktop/Space transition must not re-order an already visible
            // Island or truncate a pending collapse with an immediate resize.
            islandPresentation.scheduleIslandLayoutUpdate()
        }
        guard appState.isShelfVisible else { return }
        // Validate the destination during a slide, not its offscreen start.
        let frame = classicFrameTransition.targetFrame ?? classicLogicalFrame
        let corrected = ShelfLayoutEngine.onscreenCorrection(for: frame,
                                                             screens: Self.screenGeometries())
            ?? classicTargetFrame()
        guard corrected != frame else { return }
        _ = classicFrameTransition.request(corrected, currentFrame: classicLogicalFrame)
        resetClassicSurfaceHeight()
        classicPanel.setFrame(corrected, display: true)
    }

    /// A preference change can animate the visible Shelf to its new frame.
    /// Skip the animation when the frame is unchanged because UserDefaults also
    /// posts this notification for unrelated writes.
    ///
    /// NotificationCenter calls the selector on the posting thread. Keep it
    /// nonisolated and move window work to the main actor to avoid an isolation assertion.
    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyLayoutSettings()
        }
    }

    private func applyLayoutSettings() {
        applyPresentationSettings(animated: true)
    }

    private func applyClassicLayout(animated: Bool = true) {
        guard appState.isShelfVisible else { return }
        // Changing the window frame mid-transition would move the edge tab's origin.
        guard !isClassicMorphing else {
            isClassicLayoutDeferred = true
            return
        }
        let current = classicLogicalFrame
        var target = classicTargetFrame()
        // Keep the top edge fixed for content-only height changes so the title
        // and search field do not jump when items or selection actions change.
        let isHeightOnly = settings.shelfPosition != .custom
            && classicPanel.isVisible
            && target.width == current.width && target.minX == current.minX
        if isHeightOnly {
            let visible = Self.screen(containing: CGPoint(x: current.midX, y: current.midY)).visibleFrame
            target.origin.y = min(max(current.maxY - target.height, visible.minY),
                                  visible.maxY - target.height)
        }
        guard classicFrameTransition.request(target, currentFrame: current) else { return }
        guard target != current else { return }
        guard animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            resetClassicSurfaceHeight()
            classicPanel.setFrame(target, display: true)
            return
        }
        if isHeightOnly, current.maxY == target.maxY {
            resizeClassicSurface(to: target)
            return
        }
        resetClassicSurfaceHeight()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            classicPanel.animator().setFrame(target, display: true)
        }
    }

    /// Animate the glass and content height while keeping the top edge fixed.
    /// Grow the window immediately when needed, initially leaving the added area transparent.
    ///
    /// WindowServer can apply a smaller height before moving the window's origin
    /// up, especially after opening the Share menu. That makes the whole Shelf
    /// jump down for a few frames. Keep the unused bottom area transparent and
    /// noninteractive until the next hide or frame change reclaims it.
    private func resizeClassicSurface(to target: NSRect) {
        classicResizeGeneration &+= 1
        let generation = classicResizeGeneration
        let inset = Self.classicSurfaceInset * 2
        let window = classicPanel.frame
        let shownHeight = classicReveal.surfaceHeight ?? (window.height - inset)
        let targetHeight = target.height - inset
        let needsTallerWindow = target.height > window.height
        if needsTallerWindow {
            classicReveal.pinSurfaceHeight(shownHeight)
            classicPanel.setFrame(target, display: true)
        } else if classicReveal.surfaceHeight == nil {
            classicReveal.pinSurfaceHeight(shownHeight)
        }
        let fillsWindow = needsTallerWindow || target.height == window.height
        classicReveal.animateSurfaceHeight(to: targetHeight) { [weak self] in
            guard let self, self.classicResizeGeneration == generation else { return }
            // Unlock the glass height when it fills the window. Otherwise keep the bottom area transparent.
            if fillsWindow { self.classicReveal.pinSurfaceHeight(nil) }
            if self.classicPanel.hasShadow { self.classicPanel.invalidateShadow() }
        }
    }

    /// On item changes, animate the visible Shelf to the new content height.
    /// Custom placement keeps its height. Apply empty-Shelf auto-hide unless a
    /// management removal or drag currently owns the transition.
    private func handleItemsDidChange() {
        interaction.normalize(for: store.items)
        let shouldAutoHide = emptyAutoHideRule.evaluate(
            itemCount: store.items.count,
            isVisible: appState.isShelfVisible,
            isEnabled: settings.autoHideWhenEmpty && onboardingPresentationCount == 0,
            isDragInProgress: dragStartMonitor.isDragInProgress,
            isUserRemoval: isUserRemovalInProgress
        )
        if appState.isShelfVisible {
            applyClassicLayout()
        }
        // Evaluate auto-hide after the height transition so hiding wins if both happen in the same frame.
        if shouldAutoHide {
            hideShelf(animated: true)
        }
    }

    /// ActivityStrip changes compact height but must not participate in the
    /// non-empty → empty auto-hide state machine.
    private func handleActivityVisibilityDidChange() {
        transfersModuleRuntime.refresh()
        applyClassicLayout()
    }

    /// Explicit top-level or expanded-stack selection changes only affect the
    /// quick-action row. They do not enter the item persistence or empty-shelf
    /// auto-hide state machines.
    private func handleQuickActionVisibilityDidChange() {
        guard appState.isShelfVisible else { return }
        quickActionLayoutTask?.cancel()
        quickActionLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.applyQuickActionLayoutChange()
        }
    }

    private func applyQuickActionLayoutChange() {
        quickActionLayoutTask = nil
        applyClassicLayout()
    }

    // MARK: - Island presentation

    private var hasAvailableIslandDisplay: Bool {
        IslandScreenCatalog.selectedScreen(for: .automatic,
                                           pointerPoint: NSEvent.mouseLocation) != nil
    }

    /// Applies two independent surface preferences over the same ShelfStore.
    /// Enabling or disabling one surface never changes the other's visibility
    /// or deletes shelf content.
    func applyPresentationSettings(animated: Bool = false) {
        islandModuleRegistry.apply(settings: settings)
        classicPanel.allowsTopEdgeOverlap = false
        classicPanel.level = .floating
        // Restore the shadow only after the transition so it follows the final outline.
        if !isClassicMorphing { classicPanel.hasShadow = classicWantsWindowShadow }
        if SideShelfAvailability.isEnabled && settings.classicShelfEnabled {
            if appState.isShelfVisible {
                applyClassicLayout(animated: animated)
                if !classicPanel.isVisible {
                    classicPanel.alphaValue = 1
                    presentClassicPanel()
                }
            }
        } else {
            appState.hideShelf()
            _ = classicVisibilityTransition.request(visible: false)
            classicFrameTransition.reset()
            classicPanel.orderOut(nil)
        }

        if settings.islandEnabled && hasAvailableIslandDisplay {
            startEnabledIslandModules()
            islandPresentation.activate()
        } else {
            stopIslandModules()
            islandPresentation.deactivate()
        }
    }

    func islandDragApproachedTop(at point: CGPoint) -> Bool {
        islandPresentation.expanded.updatePointer(at: point)
        guard settings.islandEnabled,
              settings.islandShelfEnabled,
              hasAvailableIslandDisplay else { return false }
        let layout = islandPresentation.islandLayout(at: point)
        guard IslandGeometryResolver.acceptsFileDrag(
            at: point,
            notchPointerFrame: layout.notchIsVisible ? layout.notchPointerFrame : .null,
            activationFrame: layout.activationFrame,
            topApproachEnabled: settings.islandDragApproachEnabled
        ) else { return false }
        islandActivityCoordinator.currentLayout = layout
        if !islandActivityCoordinator.surfaceState.isExpanded {
            islandPresentation.resetIslandHoverPreview(restoreSelection: false)
            islandPresentation.prepareTrigger(at: point)
            islandActivityCoordinator.beginDrag()
            return true
        }
        return false
    }

    func islandDragEnded(imported: Bool, hasPendingNotice: Bool = false) {
        guard settings.islandEnabled, settings.islandShelfEnabled else { return }
        islandActivityCoordinator.endDrag(imported: imported, hasPendingNotice: hasPendingNotice)
    }

    private func startEnabledIslandModules() {
        if !islandModuleRegistry.isEnabled(islandActivityCoordinator.selectedModule) {
            islandActivityCoordinator.selectedModule =
                islandModuleRegistry.enabledDescriptors.first?.id ?? .quickSettings
        }
        islandModuleContainer.apply(
            configuration: settings.effectiveIslandModuleConfiguration,
            isActive: true
        )
    }

    private func stopIslandModules() {
        islandModuleContainer.stopAll()
    }


}
