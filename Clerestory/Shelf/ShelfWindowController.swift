import AppKit
import OSLog
import SwiftUI

/// Owns the Panel's windows, its modules and the shared Shelf dependencies. It also
/// owns the Quick Look session and dispatches Shelf keyboard events through
/// `ShelfPanel.onKeyDown`.
///
/// Triggers and settings use `toggleShelf(animated:)`, `showPreferredShelf(animated:)`,
/// or `hidePreferredShelf(animated:)`.
@MainActor
final class ShelfWindowController: NSObject {
    /// Panel (Island) drop destinations, including the approach zone, report drag ends here.
    var onIslandDestinationEntered: ((Int) -> Void)?
    var onIslandDestinationEnded: ((Int, Bool) -> Void)?

    /// Source of Panel, Shelf and module preferences.
    private let settings: SettingsStore
    private let clipboardHistoryStore: ClipboardHistoryStore
    /// Shared item store for ShelfView and the AppKit drop destination.
    private let store: ShelfStore
    /// Converts dropped pasteboard data into Shelf items for DragContainerView.
    private let importCoordinator: DropImportCoordinator
    /// Holds the notice the notice pill shows; Shelf writes to it through `shelfMessenger`.
    private let messages: IslandMessageCenter
    private var shelfMessenger: ModuleMessenger { messages.messenger(for: .shelf) }
    /// DragContainerView updates drop feedback and insertion position for ShelfView to render.
    private let islandDropTargetState = DropTargetState()
    /// ShelfView reports card frames. Drop positioning and marquee selection
    /// share this geometry.
    private let islandGridGeometry = ShelfGridGeometry()
    /// Runtime focus/expanded-stack state shared with SwiftUI card rendering.
    private let interaction = ShelfInteractionState()
    /// Starts drag-out sessions and applies the remove, keep, or ask preference
    /// after the drop. Successful drops enter recent history.
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
    /// Speaks transfer milestones whether or not ShelfView is on screen, through the message
    /// center's announcer so one instance de-duplicates all speech.
    private var transferAnnouncements: TransferAnnouncementObserver?
    /// The Panel's drop destinations confirm Shelf drags through it.
    private let dragStartMonitor: DragStartMonitor
    /// Expanded Island's visible Settings control uses the app's retained,
    /// LSUIElement-safe settings window rather than SwiftUI's response-chain
    /// action, which can silently fail for a non-activating panel.
    private let onOpenSettings: @MainActor () -> Void
    let islandActivityCoordinator: IslandActivityCoordinator
    let islandModuleRegistry: IslandModuleRegistry
    let islandTimerStore: IslandTimerStore
    let powerSourceMonitor: PowerSourceMonitor
    let nowPlayingModuleStore: NowPlayingModuleStore
    let systemStatusModuleStore: SystemStatusModuleStore
    let aiUsageModuleStore: AIUsageModuleStore
    let islandModuleContainer: IslandModuleContainer
    /// Open onboarding presentations. The last one to end restores the earlier visibility.
    private var onboardingPresentationCount = 0

    struct OnboardingPresentationSnapshot: Equatable, Sendable {
        fileprivate let wasVisible: Bool
    }

    private var islandNoticePanel: IslandNoticePanelController?
    private lazy var islandPresentation = IslandPresentationController(
        settings: settings, coordinator: islandActivityCoordinator,
        registry: islandModuleRegistry, modules: islandModuleContainer,
        notices: { [weak self] in self?.islandNoticePanel },
        collapse: { [weak self] in self?.collapseIsland(animated: $0) },
        makePanel: { [unowned self] role in self.makePanel(role: role) })
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
            onDestinationEntered: { [weak self] sequenceNumber in
                self?.onIslandDestinationEntered?(sequenceNumber)
            },
            onDestinationEnded: { [weak self] sequenceNumber, accepted in
                self?.onIslandDestinationEnded?(sequenceNumber, accepted)
            },
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
    private func presentationRoot(role: IslandWindowRole) -> some View {
        if role == .notch {
            IslandNotchView()
        } else {
            IslandExpandedView(
                onPerformRecovery: { [weak self] in self?.performRecovery($0) },
                onOpenSettings: { [weak self] in self?.onOpenSettings() })
        }
    }

    private func makePanel(role islandRole: IslandWindowRole) -> ShelfPanel {
        let panel = ShelfPanel(
            // IslandPresentationController sets both windows' frames.
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.acceptsKeyboardFocus = islandRole == .expanded
        panel.title = islandRole == .notch ? "Clerestory Notch" : "Clerestory Panel"
        panel.setAccessibilityIdentifier(islandRole == .notch
                                        ? "island.window.compact" : "island.window.expanded")
        // SwiftUI presentation preferences alone don't set AppKit controls'
        // appearance inside this custom, non-activating Island panel.
        panel.appearance = NSAppearance(named: .darkAqua)
        // Wrap the hosting view in DragContainerView for AppKit drag destination events.
        let hostingController = NSHostingController(
            rootView: presentationRoot(role: islandRole)
                .environment(store)
                .environment(islandDropTargetState)
                .environment(settings)
                .environment(islandGridGeometry)
                .environment(interaction)
                .environment(\.shelfMessenger, shelfMessenger)
                .environment(importCoordinator.transferStore)
                .environment(islandActivityCoordinator)
                .environment(messages)
                .environment(islandModuleRegistry)
                .environment(islandModuleContainer)
                .environment(islandTimerStore)
                .environment(powerSourceMonitor)
                .environment(nowPlayingModuleStore)
                .environment(systemStatusModuleStore)
                .environment(aiUsageModuleStore)
                .environment(clipboardHistoryStore)
                .environment(\.bookmarkService, importCoordinator.bookmarkService)
                .environment(\.dragOutController, islandDragOutController)
                .environment(\.quickLookCoordinator, quickLookCoordinator)
                .environment(\.tempFileService, tempFileService)
                .environment(\.itemRecoveryController, itemRecoveryController)
                .environment(\.shelfActionRunner, shelfActionRunner)
                .environment(\.shelfFocusAction, { [weak panel] in
                    guard let panel else { return }
                    NSApp.activate()
                    panel.makeKeyAndOrderFront(nil)
                    if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor {
                        panel.makeFirstResponder(nil)
                    }
                })
        )
        // The controller owns both window frames. A disappearing module's
        // SwiftUI minimum size must not resize or move the hidden panel.
        hostingController.sizingOptions = []
        hostingController.view.setAccessibilityLabel(islandRole == .notch
            ? String(localized: "Notch") : String(localized: "Clerestory Panel"))
        let isExpandedPanel = islandRole == .expanded
        panel.contentView = DragContainerView(
            store: store,
            coordinator: importCoordinator,
            dropTargetState: islandDropTargetState,
            gridGeometry: islandGridGeometry,
            // Clipboard History takes no drops while it is shown in the expanded Panel.
            refusesDrops: { [weak self] in
                guard isExpandedPanel, let self else { return false }
                return self.islandActivityCoordinator.surfaceState.isExpanded
                    && self.islandActivityCoordinator.selectedModule == .clipboard
            },
            onDestinationEntered: { [weak self] sequenceNumber in
                self?.onIslandDestinationEntered?(sequenceNumber)
            },
            onDestinationEnded: { [weak self] sequenceNumber, accepted in
                self?.onIslandDestinationEnded?(sequenceNumber, accepted)
            },
            onNativeShelfDrag: { [weak self] in
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
        if islandRole == .expanded {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(
                    islandPresentation, selector: #selector(IslandPresentationController.islandWindowStateDidChange(_:)),
                    name: name, object: panel
                )
            }
        }
        if islandRole == .expanded {
            islandNoticePanel = IslandNoticePanelController(
                anchor: panel, messages: messages,
                coordinator: islandActivityCoordinator, settings: settings,
                dropTarget: islandDropTargetState)
            messages.routeAction = { [weak self] in self?.performNoticeAction($0) }
        }
        return panel
    }

    var isIslandExpanded: Bool {
        islandActivityCoordinator.surfaceState.isExpanded
    }

    /// Whether the Shelf command's surface, the Panel's Shelf, is open.
    var isPreferredShelfExpanded: Bool {
        isIslandShelfAvailable && islandActivityCoordinator.surfaceState.isExpanded
    }

    /// The Shelf command opens the Panel's Shelf module, so it needs both turned on.
    private var isIslandShelfAvailable: Bool {
        settings.islandEnabled && settings.islandShelfEnabled
    }

    init(store: ShelfStore,
         importCoordinator: DropImportCoordinator,
         messages: IslandMessageCenter,
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
        self.store = store
        self.importCoordinator = importCoordinator
        self.messages = messages
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
            },
            messenger: messages.messenger(for: .system)
        )
        let aiUsageModuleStore = AIUsageModuleStore(
            makeProvider: { TokenTrackerClient(port: settings.aiUsageServerPort) },
            isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded
                    && islandActivityCoordinator.selectedModule == .aiUsage
            },
            notchMetric: { settings.aiUsageNotchMetric },
            alertsEnabled: { settings.aiUsageLimitAlertsEnabled },
            messenger: messages.messenger(for: .aiUsage)
        )
        let shelfRuntime = CallbackIslandModuleRuntime(
            descriptor: islandModuleRegistry.descriptor(for: .shelf)!
        )
        let transfersModuleRuntime = TransfersModuleRuntime(
            transferStore: importCoordinator.transferStore,
            messenger: messages.messenger(for: .transfers)
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
        self.islandActivityCoordinator = islandActivityCoordinator
        self.islandModuleRegistry = islandModuleRegistry
        self.islandTimerStore = islandTimerStore
        self.powerSourceMonitor = powerSourceMonitor
        self.nowPlayingModuleStore = nowPlayingModuleStore
        self.systemStatusModuleStore = systemStatusModuleStore
        self.aiUsageModuleStore = aiUsageModuleStore
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
                    descriptor: aiUsageModuleStore.descriptor,
                    runtime: aiUsageModuleStore,
                    makeContentView: { _ in AnyView(IslandAIUsageView()) }
                ),
            ],
            messages: messages
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
            messenger: messages.messenger(for: .shelf),
            openStorageRecovery: onOpenStorageRecovery
        )
        self.shelfActionRunner = ShelfActionRunner(
            bookmarkService: importCoordinator.bookmarkService,
            messenger: messages.messenger(for: .shelf)
        )
        super.init()
        transferAnnouncements = TransferAnnouncementObserver(transferStore: importCoordinator.transferStore,
                                                             announcer: messages.announcer)
        islandPresentation.connect()
        islandTimerStore.messenger = messages.messenger(for: .timer)
        islandTimerStore.onDidFinish = { [weak self] in
            guard let self,
                  self.settings.isIslandModuleAvailable(.timer),
                  self.settings.islandEnabled,
                  self.hasAvailableIslandDisplay,
                  self.islandActivityCoordinator.surfaceState != .pinned else { return }
            self.islandActivityCoordinator.show(module: .timer)
        }
        powerSourceMonitor.messenger = messages.messenger(for: .battery)
        nowPlayingModuleStore.messenger = messages.messenger(for: .media)
        store.onItemsDidChange = { [weak self] in
            guard let self else { return }
            self.interaction.normalize(for: self.store.items)
        }
        quickLookCoordinator.onNavigationKey = { [weak self] event in
            guard let self else { return false }
            return self.handleItemKeyDown(event, in: self.islandPanel)
        }
        quickLookCoordinator.sourceWindowLevel = { [weak self] in
            self?.islandPanel.level ?? .normal
        }
        quickLookCoordinator.onPreviewVisibilityChanged = { [weak self] visible in
            self?.islandPresentation.setQuickLookVisible(visible)
        }
        // Restore keyboard focus to a visible Shelf after Quick Look closes
        // so Space, Delete, and Escape work without activating Clerestory.
        quickLookCoordinator.onPanelClosed = { [weak self] in
            guard let self, self.islandActivityCoordinator.surfaceState.isExpanded else { return }
            self.islandPanel.makeKey()
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
        // Apply Panel and module preference changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public API

    func shutdown() {
        islandNotchPanel.orderOut(nil)
        islandNoticePanel?.stop()
        transferAnnouncements?.stop()
        setIslandDragZoneActive(false)
        stopIslandModules()
        islandPresentation.deactivate()
    }

    func toggleShelf(animated: Bool = true) {
        guard isIslandShelfAvailable, hasAvailableIslandDisplay else { return }
        islandActivityCoordinator.toggle()
    }

    /// Global-hot-key entry point: showing the shelf also makes its
    /// nonactivating panel key so the user can continue entirely by keyboard.
    func toggleShelfForKeyboard(animated: Bool = true) {
        guard isIslandShelfAvailable, hasAvailableIslandDisplay else { return }
        if islandActivityCoordinator.surfaceState.isExpanded {
            collapseIsland(animated: animated)
        } else {
            showIslandShelf(animated: animated, takeKeyboardFocus: true)
        }
    }

    /// The one handler for recovery actions offered in the panel: the Shelf activity strip, the
    /// Transfers module, and the notice pill's Open Recovery button. "Select Item" focuses the retained item and shows the
    /// Shelf so the user can drag it out again; other actions go to `ItemRecoveryController`.
    func performRecovery(_ action: RecoveryAction) {
        switch action {
        case .retryByDraggingOut(let itemID):
            guard interaction.focusRetainedItem(itemID, in: store) else { return }
            showPreferredShelf(animated: true, takeKeyboardFocus: true)
        case .openStorageRecovery, .locateExternalFile, .dragAgainFromSource, .dismiss:
            itemRecoveryController.perform(action)
        }
    }

    /// Routes the notice pill's button.
    private func performNoticeAction(_ action: IslandNoticeAction) {
        switch action {
        case .openStorageRecovery:
            performRecovery(.openStorageRecovery)
        case .openModule(let moduleID):
            islandActivityCoordinator.show(module: moduleID,
                                           pinned: islandActivityCoordinator.surfaceState == .pinned)
        }
    }

    func showPreferredShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        showIslandShelf(animated: animated, takeKeyboardFocus: takeKeyboardFocus)
    }

    func hidePreferredShelf(animated: Bool = true) {
        guard isIslandShelfAvailable else { return }
        collapseIsland(animated: animated)
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

    /// Onboarding saves the prior visibility and shows Shelf.
    /// When the lease ends, it restores visibility without writing preferences.
    func beginOnboardingPresentation() -> OnboardingPresentationSnapshot {
        // Without the Panel's Shelf there is nothing to show, and so nothing to close later.
        let wasVisible = !isIslandShelfAvailable || islandActivityCoordinator.surfaceState.isExpanded
        onboardingPresentationCount += 1
        if !wasVisible {
            showIslandShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        return OnboardingPresentationSnapshot(wasVisible: wasVisible)
    }

    func endOnboardingPresentation(_ snapshot: OnboardingPresentationSnapshot) {
        onboardingPresentationCount = max(0, onboardingPresentationCount - 1)
        guard onboardingPresentationCount == 0, !snapshot.wasVisible else { return }
        collapseIsland(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Onboarding can lay out against the target frame while Shelf is hidden,
    /// without creating or showing the panel.
    var visibleOrTargetFrame: CGRect {
        islandActivityCoordinator.surfaceState.isExpanded
            ? islandPanel.interactionFrame : islandPresentation.islandLayout().expandedFrame
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
        shelfMessenger.post(ClipboardController.notice(for: result))
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
                shelfMessenger.post(.removalFailed)
                return true
            }
        }
        interaction.normalize(for: store.items)
        quickLookCoordinator.refreshPreview(contextItem: focusedItem())
        return true
    }

    // MARK: - Display changes

    /// Finds the screen containing the point, falling back to the main screen.
    static func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens[0]
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        applyPresentationSettings()
    }

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
    }

    /// UserDefaults also posts this notification for unrelated writes; applying
    /// unchanged settings is a no-op.
    ///
    /// NotificationCenter calls the selector on the posting thread. Keep it
    /// nonisolated and move window work to the main actor to avoid an isolation assertion.
    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyPresentationSettings(animated: true)
        }
    }

    // MARK: - Island presentation

    private var hasAvailableIslandDisplay: Bool {
        IslandScreenCatalog.selectedScreen(for: .automatic,
                                           pointerPoint: NSEvent.mouseLocation) != nil
    }

    /// Applies Panel and module preferences. Turning the Panel off never deletes Shelf content.
    func applyPresentationSettings(animated: Bool = false) {
        islandModuleRegistry.apply(settings: settings)
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
        if islandActivityCoordinator.endDrag(imported: imported, hasPendingNotice: hasPendingNotice) {
            // The drag opened the panel and the drop keeps it open: moving away closes it, as
            // after a hover. A panel opened by click or shortcut before the drag stays as it was.
            islandPresentation.resumeHoverDismissal()
        }
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
