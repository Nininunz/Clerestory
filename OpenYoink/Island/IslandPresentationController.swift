import AppKit
import SwiftUI
import OSLog

/// Coordinates one expanded surface and its optional notch companion.
/// Shelf owns imports and keyboard actions; this object owns presentation only.
@MainActor
final class IslandPresentationController: NSObject {
    private let notchScreenGeometry: () -> IslandGeometryResolver.ScreenGeometry?
    private let usesSystemScreens: Bool
    private var panelDisplayID: String?
    private var panelScreenAnchor: CGPoint?
    private var triggerPoint: CGPoint?
    private let screenGeometry: (CGPoint) -> IslandGeometryResolver.ScreenGeometry?
    private let settings: SettingsStore
    private let islandActivityCoordinator: IslandActivityCoordinator
    private let islandModuleRegistry: IslandModuleRegistry
    private let islandModuleContainer: IslandModuleContainer
    private let notices: () -> ShelfNoticePanelController?
    private let collapse: (Bool) -> Void
    private let islandLogger = Logger(subsystem: "com.nininunz.OpenYoink", category: "IslandPresentation")
    let expanded: IslandExpandedWindowController
    let notch: IslandNotchWindowController
    private var islandPanel: ShelfPanel { expanded.panel }
    private var islandNoticePanel: ShelfNoticePanelController? { notices() }

    init(settings: SettingsStore, coordinator: IslandActivityCoordinator,
         registry: IslandModuleRegistry, modules: IslandModuleContainer,
         notices: @escaping () -> ShelfNoticePanelController?,
         collapse: @escaping (Bool) -> Void,
         makePanel: @escaping (IslandWindowRole) -> ShelfPanel,
         screenGeometry: ((CGPoint) -> IslandGeometryResolver.ScreenGeometry?)? = nil,
         notchScreenGeometry: (() -> IslandGeometryResolver.ScreenGeometry?)? = nil) {
        self.usesSystemScreens = screenGeometry == nil
        self.screenGeometry = screenGeometry ?? { point in
            IslandScreenCatalog.selectedScreen(for: .automatic, pointerPoint: point)
                .map(IslandScreenCatalog.geometry(for:))
        }
        self.notchScreenGeometry = notchScreenGeometry ?? {
            if let screenGeometry { return screenGeometry(NSEvent.mouseLocation) }
            return IslandScreenCatalog.builtInNotchScreen().map(IslandScreenCatalog.geometry(for:))
        }
        self.settings = settings
        islandActivityCoordinator = coordinator
        islandModuleRegistry = registry
        islandModuleContainer = modules
        self.notices = notices
        self.collapse = collapse
        expanded = IslandExpandedWindowController(makePanel: { makePanel(.expanded) })
        notch = IslandNotchWindowController(makePanel: { makePanel(.notch) })
        super.init()
    }

    private var hasAvailableIslandDisplay: Bool {
        screenGeometry(NSEvent.mouseLocation) != nil
    }

    func connect() {
        islandActivityCoordinator.onSurfaceStateWillChange = { [weak self] oldState, newState in
            self?.prepareIslandPanelTransition(from: oldState, to: newState)
        }
        islandActivityCoordinator.onStateDidChange = { [weak self] in
            self?.scheduleIslandLayoutUpdate()
        }
        islandActivityCoordinator.onSurfaceAnimationCompleted = { [weak self] in
            guard let self else { return }
            if self.islandActivityCoordinator.surfaceState == .collapsed,
               let module = self.moduleToRestoreAfterHoverCollapse {
                self.moduleToRestoreAfterHoverCollapse = nil
                self.islandActivityCoordinator.selectedModule = module
            }
            self.logIslandPresentation("surface-animation-completed")
            self.scheduleIslandLayoutUpdate()
        }
    }

    func activate() {
        expanded.configure()
        startIslandEventMonitoring()
        if islandActivityCoordinator.surfaceState == .hidden {
            islandActivityCoordinator.setSurfaceState(.collapsed)
        }
        if !islandModuleRegistry.isEnabled(islandActivityCoordinator.selectedModule) {
            islandActivityCoordinator.selectedModule = islandModuleRegistry.enabledDescriptors.first?.id ?? .quickSettings
        }
        scheduleIslandLayoutUpdate()
        if islandActivityCoordinator.surfaceState.isExpanded { islandPanel.orderFront(nil) }
    }

    func deactivate() {
        hideImmediately()
        stopIslandEventMonitoring()
        islandActivityCoordinator.hide()
        notch.hide()
    }

    func hideImmediately() {
        islandLayoutTask?.cancel()
        islandLayoutTask = nil
        islandFrameTransition.reset()
        expanded.hide()
        panelScreenAnchor = nil
        panelDisplayID = nil
        triggerPoint = nil
    }

    private func updateNotchPanel() {
        let layout = notchScreenGeometry().map {
            IslandGeometryResolver.resolve(screen: $0, showNotch: settings.showNotch)
        }
        islandActivityCoordinator.notchLayout = layout
        guard let layout else { notch.hide(); return }
        notch.update(layout: layout, enabled: settings.islandEnabled, level: islandPanel.level)
    }

    func prepareTrigger(at point: CGPoint) {
        guard !islandActivityCoordinator.surfaceState.isExpanded else { return }
        triggerPoint = point
    }

    private func collapseIsland(animated: Bool) { collapse(animated) }

    deinit {
        islandHoverTask?.cancel()
        islandHoverExitTask?.cancel()
        islandLayoutTask?.cancel()
        shortcutSettleTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private var islandGlobalMonitor: Any?
    private var islandLocalMonitor: Any?
    private var islandTrackingMenus = Set<ObjectIdentifier>()
    private var quickLookVisible = false
    private var islandHoverTask: Task<Void, Never>?
    private var islandHoverExitTask: Task<Void, Never>?
    private var islandHoverPreview = IslandHoverPreviewStateMachine()
    private var moduleBeforeIslandHoverPreview: IslandModuleID?
    private var moduleToRestoreAfterHoverCollapse: IslandModuleID?
    private var islandLayoutTask: Task<Void, Never>?
    private var islandFrameTransition = ShelfFrameTransitionState()
    private func islandTargetFrame() -> NSRect {
        let layout = islandLayout()
        islandActivityCoordinator.currentLayout = layout
        islandPanel.hasShadow = false
        updateNotchPanel()
        expanded.updatePointer(at: NSEvent.mouseLocation)
        return IslandSurfaceShadow.windowFrame(for: layout.expandedFrame)
    }

    private func interactiveNotchFrame(for layout: IslandGeometryResolver.Layout) -> NSRect {
        layout.pointerTriggerFrame
    }

    private func prepareIslandPanelTransition(
        from oldState: IslandSurfaceState,
        to newState: IslandSurfaceState
    ) {
        if newState == .pinned {
            performIslandHoverActions(islandHoverPreview.handle(.committed))
        } else if oldState == .pinned, newState == .expanded {
            let inside = hoverKeepAliveFrame(for: islandLayout()).contains(NSEvent.mouseLocation)
            performIslandHoverActions(islandHoverPreview.handle(.unpinned(pointerInside: inside)))
        } else if oldState.isExpanded, !newState.isExpanded {
            resetIslandHoverPreview(restoreSelection: true)
        }
        if !oldState.isExpanded, newState.isExpanded {
            moduleToRestoreAfterHoverCollapse = nil
        }
        islandLogger.notice("surface-transition \(String(describing: oldState), privacy: .public) -> \(String(describing: newState), privacy: .public) id=\(self.islandActivityCoordinator.surfaceTransitionID)")
        guard settings.islandEnabled, hasAvailableIslandDisplay,
              !oldState.isExpanded,
              newState.isExpanded else { return }
        // A selected-module change can already have queued a notch layout
        // pass. Cancel it so no stale frame is applied between preparation and
        // the actual surface-state mutation.
        islandLayoutTask?.cancel()
        islandLayoutTask = nil

        let point = triggerPoint ?? NSEvent.mouseLocation
        triggerPoint = nil
        if usesSystemScreens {
            panelDisplayID = IslandScreenCatalog.selectedScreen(for: .automatic, pointerPoint: point)
                .map(IslandScreenCatalog.identifier(for:))
        }
        let screen = screenGeometry(point)
        panelScreenAnchor = screen.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        let layout = islandLayout(at: point)
        islandActivityCoordinator.currentLayout = layout
        islandPanel.hasShadow = false
        updateNotchPanel()
        // Size the expanded window before SwiftUI reveals its content. Notch
        // remains in its own optional, non-key window.
        // Simultaneously animating the AppKit frame and SwiftUI layout caused
        // lateral jumps, so only SwiftUI animates the opening here.
        let windowFrame = IslandSurfaceShadow.windowFrame(for: layout.expandedFrame)
        _ = islandFrameTransition.request(windowFrame, currentFrame: islandPanel.frame)
        if islandPanel.frame != windowFrame {
            islandPanel.setFrame(windowFrame, display: true)
        }
        expanded.updatePointer(at: NSEvent.mouseLocation)
        if !islandPanel.isVisible { islandPanel.orderFront(nil) }
    }

    func islandLayout(at point: CGPoint = NSEvent.mouseLocation)
        -> IslandGeometryResolver.Layout {
        let selectedGeometry: IslandGeometryResolver.ScreenGeometry?
        if usesSystemScreens, let id = panelDisplayID {
            let screen = NSScreen.screens.first { IslandScreenCatalog.identifier(for: $0) == id }
                ?? IslandScreenCatalog.selectedScreen(for: .automatic, pointerPoint: point)
            panelDisplayID = screen.map(IslandScreenCatalog.identifier(for:))
            selectedGeometry = screen.map(IslandScreenCatalog.geometry(for:))
        } else {
            selectedGeometry = screenGeometry(panelScreenAnchor ?? point)
        }
        if let screen = selectedGeometry {
            return IslandGeometryResolver.resolve(
                screen: screen,
                preferredExpandedHeight: islandActivityCoordinator.preferredExpandedHeight(
                    for: islandModuleContainer.registration(for: islandActivityCoordinator.selectedModule)?.descriptor),
                showNotch: settings.showNotch
            )
        }
        return IslandGeometryResolver.resolve(screen: .init(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        ), preferredExpandedHeight: islandActivityCoordinator.preferredExpandedHeight(
                    for: islandModuleContainer.registration(for: islandActivityCoordinator.selectedModule)?.descriptor),
            showNotch: settings.showNotch)
    }

    func scheduleIslandLayoutUpdate() {
        guard settings.islandEnabled else { return }
        let target = islandTargetFrame()
        // SwiftUI owns the visible fold. A wall-clock sleep can expire before
        // that animation has even started during Show Desktop. Keep the host
        // canvas intact until its actual completion, including interrupted folds.
        if !islandActivityCoordinator.surfaceState.isExpanded,
           islandActivityCoordinator.isSurfaceTransitionPending,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return
        }
        if !islandActivityCoordinator.surfaceState.isExpanded {
            islandLayoutTask?.cancel()
            islandLayoutTask = nil
            islandFrameTransition.reset()
            islandPanel.orderOut(nil)
            panelScreenAnchor = nil
            panelDisplayID = nil
            return
        }
        // Activity samples, defaults notifications and desktop/Space changes
        // can all arrive during the same collapse. Compare destinations before
        // cancelling: identical requests must not restart its deadline.
        if islandLayoutTask == nil { islandFrameTransition.reset() }
        guard islandFrameTransition.request(target, currentFrame: islandPanel.frame) else { return }
        islandLayoutTask?.cancel()
        islandLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            defer {
                // A cancelled task may have been replaced by a newer request.
                if !Task.isCancelled {
                    self.islandLayoutTask = nil
                    self.islandFrameTransition.reset()
                }
            }

            guard target != self.islandPanel.frame else { return }

            if !self.islandActivityCoordinator.surfaceState.isExpanded {
                guard !self.islandActivityCoordinator.isSurfaceTransitionPending
                        || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                self.islandPanel.setFrame(target, display: true)
                self.logIslandPresentation("compact-frame-applied")
                return
            }
            await self.animateIsland(to: target)
        }
    }

    private func animateIsland(to target: NSRect) async {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            islandPanel.setFrame(target, display: true)
            return
        }
        let isExpanding = target.height > islandPanel.frame.height
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = isExpanding
                    ? IslandMotion.expandWindowDuration
                    : IslandMotion.collapseWindowDuration
                context.timingFunction = isExpanding
                    ? CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.18, 1.0)
                    : CAMediaTimingFunction(controlPoints: 0.40, 0.00, 0.20, 1.0)
                islandPanel.animator().setFrame(target, display: true)
            }, completionHandler: {
                continuation.resume()
            })
        }
    }

    private var islandShortcutSwipe = IslandShortcutSwipe()
    private var shortcutSettleTask: Task<Void, Never>?

    private func handleIslandShortcutSwipe(_ event: NSEvent) -> Bool {
        guard event.window === islandPanel,
              islandActivityCoordinator.surfaceState.isExpanded,
              event.hasPreciseScrollingDeltas,
              !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return false }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            guard islandActivityCoordinator.shortcutSwipeOffset != 0 else { return false }
            settleShortcutSwipe(cancelled: event.phase.contains(.cancelled), timestamp: event.timestamp)
            return true
        }
        if shortcutSettleTask != nil { return true }
        let result = islandShortcutSwipe.sample(
            dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
            began: event.phase.contains(.began), momentum: !event.momentumPhase.isEmpty,
            timestamp: event.timestamp)
        switch result {
        case .ignored: return false
        case .consumed: return true
        case let .drag(offset):
            let step = offset < 0 ? 1 : -1
            let target = IslandShortcutSwipe.target(
                current: islandActivityCoordinator.selectedModule, step: step,
                pinned: settings.effectiveIslandShortcuts.shortcutPositions.compactMap { $0 },
                enabled: islandModuleRegistry.isEnabled)
            let width = IslandExpandedLayout.contentWidth(surfaceWidth: islandActivityCoordinator.currentLayout?.expandedFrame.width ?? 492)
            islandActivityCoordinator.shortcutSwipeDirection = step
            islandActivityCoordinator.shortcutSwipeTarget = target
            islandActivityCoordinator.shortcutSwipeOffset = target == nil
                ? max(-24, min(24, offset * 0.18)) : max(-width, min(width, offset))
            return true
        }
    }

    private func settleShortcutSwipe(cancelled: Bool, timestamp: TimeInterval) {
        let coordinator = islandActivityCoordinator
        let revision = coordinator.shortcutNavigationRevision
        let target = coordinator.shortcutSwipeTarget
        let width = IslandExpandedLayout.contentWidth(surfaceWidth: coordinator.currentLayout?.expandedFrame.width ?? 492)
        let projected = islandShortcutSwipe.projectedTranslation(at: timestamp)
        let commit = IslandShortcutSwipe.shouldCommit(
            projected: projected, direction: coordinator.shortcutSwipeDirection, width: width,
            hasTarget: target != nil, cancelled: cancelled)
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.2
        withAnimation(.easeOut(duration: duration)) {
            coordinator.shortcutSwipeOffset = commit ? -CGFloat(coordinator.shortcutSwipeDirection) * width : 0
        }
        shortcutSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                coordinator.completeShortcutSwipe(target: commit ? target : nil, revision: revision)
            }
            self.shortcutSettleTask = nil
        }
    }

    private func startIslandEventMonitoring() {
        guard islandGlobalMonitor == nil, islandLocalMonitor == nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(islandMenuBegan(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(islandMenuEnded(_:)),
            name: NSMenu.didEndTrackingNotification, object: nil)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged]
        islandGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleIslandEvent(event, at: point) }
        }
        islandLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask.union(.scrollWheel)) {
            [weak self] event in
            if MainActor.assumeIsolated({ self?.islandTrackingMenus.isEmpty == false }) {
                return event
            }
            if event.type == .scrollWheel {
                let consumed = MainActor.assumeIsolated {
                    self?.handleIslandShortcutSwipe(event) == true
                }
                return consumed ? nil : event
            }
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleIslandEvent(event, at: point) }
            return event
        }
    }

    @objc private func islandMenuBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              islandActivityCoordinator.surfaceState.isExpanded,
              !islandTrackingMenus.isEmpty || islandPanel.interactionFrame.contains(NSEvent.mouseLocation) else { return }
        islandTrackingMenus.insert(ObjectIdentifier(menu))
        performIslandHoverActions(islandHoverPreview.handle(.menuOpened))
    }

    @objc private func islandMenuEnded(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              islandTrackingMenus.remove(ObjectIdentifier(menu)) != nil,
              islandTrackingMenus.isEmpty, !quickLookVisible else { return }
        let inside = hoverKeepAliveFrame(for: islandLayout()).contains(NSEvent.mouseLocation)
        performIslandHoverActions(islandHoverPreview.handle(.menuClosed(pointerInside: inside)))
    }

    func setQuickLookVisible(_ visible: Bool) {
        guard quickLookVisible != visible else { return }
        quickLookVisible = visible
        guard islandActivityCoordinator.surfaceState.isExpanded else { return }
        if visible {
            performIslandHoverActions(islandHoverPreview.handle(.menuOpened))
        } else if islandTrackingMenus.isEmpty {
            let inside = hoverKeepAliveFrame(for: islandLayout()).contains(NSEvent.mouseLocation)
            performIslandHoverActions(islandHoverPreview.handle(.menuClosed(pointerInside: inside)))
        }
    }

    func stopIslandEventMonitoring() {
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        islandTrackingMenus.removeAll()
        shortcutSettleTask?.cancel()
        shortcutSettleTask = nil
        islandActivityCoordinator.shortcutSwipeOffset = 0
        islandActivityCoordinator.shortcutSwipeTarget = nil
        islandShortcutSwipe = IslandShortcutSwipe()
        if let islandGlobalMonitor {
            NSEvent.removeMonitor(islandGlobalMonitor)
            self.islandGlobalMonitor = nil
        }
        if let islandLocalMonitor {
            NSEvent.removeMonitor(islandLocalMonitor)
            self.islandLocalMonitor = nil
        }
        islandHoverTask?.cancel()
        islandHoverExitTask?.cancel()
        islandHoverTask = nil
        islandHoverExitTask = nil
        islandHoverPreview = IslandHoverPreviewStateMachine()
        moduleBeforeIslandHoverPreview = nil
        islandActivityCoordinator.setPointerHovering(false)
    }

    func handleIslandEvent(_ event: NSEvent, at point: CGPoint) {
        expanded.updatePointer(at: point)
        islandNoticePanel?.updatePointer(at: point)
        guard settings.islandEnabled, islandTrackingMenus.isEmpty, !quickLookVisible else { return }
        switch event.type {
        case .leftMouseDown:
            if islandNoticePanel?.contains(point) == true { return }
            if !islandActivityCoordinator.surfaceState.isExpanded {
                let layout = islandLayout(at: point)
                guard settings.islandClickRevealEnabled,
                      interactiveNotchFrame(for: layout).contains(point) else { return }
                performIslandHoverActions(islandHoverPreview.handle(.committed))
                prepareTrigger(at: point)
                islandActivityCoordinator.currentLayout = layout
                islandActivityCoordinator.show(module: effectiveIslandOpenModule)
                return
            }
            let layout = islandLayout(at: point)
            if layout.pointerTriggerFrame.contains(point) {
                return
            }
            if islandHoverPreview.phase == .preview || islandHoverPreview.phase == .leaving,
               islandPanel.interactionFrame.contains(point) {
                performIslandHoverActions(islandHoverPreview.handle(.entered))
                return
            }
            guard islandActivityCoordinator.surfaceState == .expanded,
                  !islandPanel.interactionFrame.contains(point) else { return }
            islandLogger.notice("outside-click event=\(event.eventNumber) window=\(event.windowNumber)")
            collapseIsland(animated: true)
        case .mouseMoved:
            let layout = islandLayout(at: point)
            if islandActivityCoordinator.currentLayout != layout {
                scheduleIslandLayoutUpdate()
            }
            let interactiveFrame = interactiveNotchFrame(for: layout)
            islandActivityCoordinator.setPointerHovering(
                !islandActivityCoordinator.surfaceState.isExpanded
                    && islandActivityCoordinator.notchLayout?.notchIsVisible == true
                    && islandActivityCoordinator.notchLayout?.notchPointerFrame.contains(point) == true
            )
            if islandHoverPreview.phase == .preview || islandHoverPreview.phase == .leaving {
                let inside = hoverKeepAliveFrame(for: layout).contains(point)
                performIslandHoverActions(islandHoverPreview.handle(inside ? .entered : .left))
                return
            }
            guard settings.islandHoverRevealEnabled else {
                resetIslandHoverPreview(restoreSelection: true)
                return
            }
            let canStart = islandActivityCoordinator.canRevealOnHover
                && !islandActivityCoordinator.surfaceState.isExpanded
                && interactiveFrame.contains(point)
            performIslandHoverActions(islandHoverPreview.handle(canStart ? .entered : .left))
        default:
            break
        }
    }

    func resetIslandHoverPreview(restoreSelection: Bool) {
        let actions = islandHoverPreview.handle(.reset)
        islandHoverTask?.cancel()
        islandHoverExitTask?.cancel()
        islandHoverTask = nil
        islandHoverExitTask = nil
        if restoreSelection, actions.contains(.dismissPreview),
           let module = moduleBeforeIslandHoverPreview {
            moduleToRestoreAfterHoverCollapse = module
        }
        moduleBeforeIslandHoverPreview = nil
    }

    private func hoverKeepAliveFrame(for layout: IslandGeometryResolver.Layout) -> CGRect {
        var frame = layout.hoverKeepAliveFrame(panelFrame: islandPanel.interactionFrame)
        if let noticeFrame = islandNoticePanel?.interactionFrame { frame = frame.union(noticeFrame) }
        return frame
    }

    private func performIslandHoverActions(_ actions: [IslandHoverPreviewStateMachine.Action]) {
        for action in actions {
            switch action {
            case .scheduleDwell:
                islandHoverTask?.cancel()
                islandHoverTask = Task { @MainActor [weak self] in
                    let delay = max(0, min(self?.settings.islandHoverDelaySeconds ?? 0.15, 0.5))
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, !Task.isCancelled else { return }
                    self.islandHoverTask = nil
                    let layout = self.islandLayout()
                    let hoverEnabled = self.settings.islandHoverRevealEnabled
                    let inside = hoverEnabled && self.islandActivityCoordinator.canRevealOnHover
                        && !self.islandActivityCoordinator.surfaceState.isExpanded
                        && layout.pointerTriggerFrame.contains(NSEvent.mouseLocation)
                    self.performIslandHoverActions(
                        self.islandHoverPreview.handle(inside ? .dwellElapsed : .left)
                    )
                }
            case .cancelDwell:
                islandHoverTask?.cancel()
                islandHoverTask = nil
            case .showPreview:
                moduleBeforeIslandHoverPreview = islandActivityCoordinator.selectedModule
                islandActivityCoordinator.show(module: effectiveIslandOpenModule)
            case .scheduleExit:
                islandHoverExitTask?.cancel()
                islandHoverExitTask = Task { @MainActor [weak self] in
                    let delay = max(0, min(self?.settings.islandHoverLeaveDelaySeconds ?? 0.25, 1))
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, !Task.isCancelled else { return }
                    self.islandHoverExitTask = nil
                    let layout = self.islandLayout()
                    let stillOutside = !self.hoverKeepAliveFrame(for: layout)
                        .contains(NSEvent.mouseLocation)
                    self.performIslandHoverActions(
                        self.islandHoverPreview.handle(stillOutside ? .exitElapsed : .entered)
                    )
                }
            case .cancelExit:
                islandHoverExitTask?.cancel()
                islandHoverExitTask = nil
            case .dismissPreview:
                if let module = moduleBeforeIslandHoverPreview {
                    moduleToRestoreAfterHoverCollapse = module
                }
                moduleBeforeIslandHoverPreview = nil
                collapseIsland(animated: true)
            case .commitPreview:
                moduleBeforeIslandHoverPreview = nil
                moduleToRestoreAfterHoverCollapse = nil
            }
        }
    }

    /// Low-frequency lifecycle diagnostics only; never includes clipboard data,
    /// file names, screen contents or a continuous pointer trace.
    func logIslandPresentation(_ reason: String) {
        let state = String(describing: islandActivityCoordinator.surfaceState)
        let frame = NSStringFromRect(islandPanel.frame)
        islandLogger.notice("\(reason, privacy: .public) state=\(state, privacy: .public) id=\(self.islandActivityCoordinator.surfaceTransitionID) pending=\(self.islandActivityCoordinator.isSurfaceTransitionPending) frame=\(frame, privacy: .public) visible=\(self.islandPanel.isVisible) occluded=\(!self.islandPanel.occlusionState.contains(.visible)) key=\(self.islandPanel.isKeyWindow)")
    }

    @objc nonisolated func islandWindowStateDidChange(_ notification: Notification) {
        let reason = notification.name.rawValue
        Task { @MainActor [weak self] in
            self?.logIslandPresentation(reason)
        }
    }

    private var effectiveIslandOpenModule: IslandModuleID {
        if let recent = islandActivityCoordinator.reentryModule(isEnabled: islandModuleRegistry.isEnabled) {
            return recent
        }
        let display = settings.notchDisplay
        if let moduleID = display.moduleID, islandModuleRegistry.isEnabled(moduleID) {
            return moduleID
        }
        if islandModuleRegistry.isEnabled(islandActivityCoordinator.selectedModule) {
            return islandActivityCoordinator.selectedModule
        }
        return islandModuleRegistry.enabledDescriptors.first?.id ?? .quickSettings
    }

}
