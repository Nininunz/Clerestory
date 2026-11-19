import AppKit

/// EdgeTab: A persistent tab attached to the screen edge (user-confirmed interaction design):
/// 1. Single click → expand/collapse shelf (`onToggleShelf`);
/// 2. Drag files onto the tab → reuse `DropImportCoordinator` to import and trigger shelf display;
/// 3. Hold and drag → move along the edge (persist `shelfEdgeOffset`); cursor crossing the screen center
/// line approaches the opposite edge (`ShelfLayoutEngine.shouldFlipSide`) → switch sides in real time,
/// persist `shelfPosition` upon release;
/// 4. Visibility state machine: `edgeTabEnabled && position != .custom && !isShelfVisible` ——
///    The tab only appears when the shelf is hidden (the tab and shelf are two states of the same element,
/// visible at different times, confirmed by the user); after the shelf is expanded, the panel's
/// **edge-side invisible hot zone** takes over the 'tap the same point to collapse' action (see the outer
/// edge collapse hot zone in ShelfView); custom free position mode has no tab (title bar drag has already
/// covered it, see `WindowDragHandle`);
/// 5. During dragging (`DragStartMonitor.isDragInProgress`) → accent border/light fill + slight
/// magnification (`ShelfLayoutEngine.edgeTabEmphasisFrame`) to suggest interaction.
///
/// All layouts are pure functions of `ShelfLayoutEngine` (frame/offset/flip/ emphasis/anchor frame). This
/// class only handles windows and state machine. The normal position adheres to the same screen attachment
/// rule as shelf (mouse screen, see `ShelfWindowController.screen(containing:)`), and the anchor position
/// takes the screen where the shelf panel is located (`layoutVisibleFrame`).
@MainActor
final class EdgeTabController: NSObject {
    private static let fadeDuration: TimeInterval = 0.18
    private static let handOffFadeDuration: TimeInterval = 0.08
    private static let emphasisDuration: TimeInterval = 0.15
    /// Duration for frame migration during anchoring/returning (synchronized with ShelfWindowController's
    /// visibility animation).
    private static let moveDuration: TimeInterval = 0.2

    private let appState: AppState
    private let settings: SettingsStore
    private let store: ShelfStore
    private let importCoordinator: DropImportCoordinator
    private let dragStartMonitor: DragStartMonitor
    private let onToggleShelf: @MainActor () -> Void
    private let onShowShelf: @MainActor () -> Void
    private let onPreviewSuppressed: @MainActor () -> Void

    /// The handle is being dragged (repositioning session in progress). Mirrored to
    /// `AppState.isEdgeTabBeingDragged` to suppress shelf invocation for drag triggers (dragging the
    /// handle itself should not invoke shelf); this flag is only used for local emphasis state and layout
    /// gating.
    private var isTabBeingDragged = false

    /// Drop hover (file drag is hovering over the handle and content is importable).
    private var isDropTargeted = false
    /// Current applied emphasis state (used for change detection to avoid redundant animations).
    private var isEmphasized = false
    private var visibilityTransition = ShelfVisibilityTransitionState()

    private lazy var panel: EdgeTabPanel = {
        let panel = EdgeTabPanel(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: ShelfLayoutEngine.edgeTabWidth,
                                             height: ShelfLayoutEngine.edgeTabHeight)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = tabView
        panel.setAccessibilityLabel(String(localized: "Show Shelf"))
        return panel
    }()

    private lazy var tabView: EdgeTabView = {
        let view = EdgeTabView(frame: NSRect(origin: .zero,
                                             size: NSSize(width: ShelfLayoutEngine.edgeTabWidth,
                                                          height: ShelfLayoutEngine.edgeTabHeight)))
        view.position = settings.shelfPosition
        view.onClick = { [weak self] in
            self?.onPreviewSuppressed()
            self?.onToggleShelf()
        }
        view.onReposition = { [weak self] offset, position in
            self?.finishReposition(offset: offset, position: position)
        }
        view.onRepositionStateChanged = { [weak self] active in
            guard let self else { return }
            self.isTabBeingDragged = active
            self.appState.setEdgeTabBeingDragged(active)
            if active { self.onPreviewSuppressed() }
            // Only set the flag, do not re-evaluate emphasis state: When the drag monitor's
            // isDragInProgress is lifted, it is reset in the next runloop, at which point re-evaluation
            // would cause a frame flash hint; the observation callback for drag end will perform the final
            // evaluation.
        }
        view.onDropTargetChanged = { [weak self] targeted in
            guard let self, self.isDropTargeted != targeted else { return }
            self.isDropTargeted = targeted
            if targeted { self.onPreviewSuppressed() }
            self.updateEmphasis(animated: true)
        }
        view.onDrop = { [weak self] pasteboard in
            self?.handleDrop(pasteboard) ?? false
        }
        return view
    }()

    init(appState: AppState,
         settings: SettingsStore,
         store: ShelfStore,
         importCoordinator: DropImportCoordinator,
         dragStartMonitor: DragStartMonitor,
         onToggleShelf: @escaping @MainActor () -> Void,
         onShowShelf: @escaping @MainActor () -> Void,
         onPreviewSuppressed: @escaping @MainActor () -> Void = {}) {
        self.appState = appState
        self.settings = settings
        self.store = store
        self.importCoordinator = importCoordinator
        self.dragStartMonitor = dragStartMonitor
        self.onToggleShelf = onToggleShelf
        self.onShowShelf = onShowShelf
        self.onPreviewSuppressed = onPreviewSuppressed
        super.init()
        beginObservation()
        // Set changes (edgeTabEnabled / shelfPosition / shelfEdgeOffset —— including persistence during
        // drag ring lift) are unified re-evaluation.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        // Plug/unplug screen / change resolution → recalculate based on new geometry (revert mouse
        // screen/main screen when the screen is removed).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Initial evaluation (shelf hidden on startup → ring immediately positioned, no animation).
        applyState(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Visibility state machine

    /// Show EdgeTab when enabled, the position has an attached edge, and Shelf is hidden. While Shelf is
    /// open, the transparent hit area along the same outer edge handles dismissal.
    private var shouldBeVisible: Bool {
        settings.classicShelfEnabled
            && settings.edgeTabEnabled
            && settings.shelfPosition != .custom
            && !appState.isShelfVisible
    }

    /// Unified state evaluation: visibility / settings / screen parameters / drag state changes trigger a
    /// call.
    private func applyState(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        tabView.configure(appearance: settings.appearance,
                          iconVisible: settings.edgeTabIconVisible,
                          iconSize: settings.edgeTabIconSize)
        // Attachment side is synchronized to the view (corner orientation / switch side reference); during
        // drag session, position is managed by gesture (may have switched side in real time but not yet
        // persisted), so this does not override.
        if !isTabBeingDragged {
            tabView.position = settings.shelfPosition
        }
        guard shouldBeVisible else {
            // Force clear emphasis state when hidden: next showTab always starts from the normal frame,
            // then updateEmphasis handles emphasis as needed (to avoid showing with outdated emphasis
            // frame).
            if isEmphasized {
                isEmphasized = false
                tabView.isEmphasized = false
            }
            hideTab(animated: animated)
            return
        }
        let wasHiddenForShelf = visibilityTransition.isVisible == false
        let visibilityChanged = visibilityTransition.request(visible: true) != nil
        let target = currentTargetFrame()
        if panel.isVisible {
            // Reversing a fade-out keeps the window ordered in. Restore alpha
            // as well as its layout; isVisible alone does not imply alpha == 1.
            if visibilityChanged { restoreTabAlpha(animated: animated) }
            // During drag ring movement, frame is directly controlled by gesture, so this does not
            // interfere. Normal position migration (settings/screen parameter changes) is animated.
            if !isTabBeingDragged, panel.frame != target {
                if animated {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = Self.moveDuration
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        panel.animator().setFrame(target, display: true)
                    }
                } else {
                    panel.setFrame(target, display: true)
                }
            }
        } else {
            // issue #10: the shelf folds back into the tab first; only then
            // does the tab itself fade in, so the two never double up.
            showTab(target, animated: animated,
                    delay: wasHiddenForShelf ? ShelfRevealState.collapseDuration * 0.7 : 0)
        }
        updateEmphasis(animated: animated)
    }

    private func showTab(_ frame: NSRect, animated: Bool, delay: TimeInterval = 0) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(frame, display: false)
        guard animated else {
            panel.alphaValue = 1
            presentTabPanel()
            return
        }
        panel.alphaValue = 0
        presentTabPanel()
        guard delay > 0 else {
            restoreTabAlpha(animated: animated)
            return
        }
        let generation = visibilityTransition.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.isCurrent(generation, visible: true),
                      self.panel.isVisible else { return }
                self.restoreTabAlpha(animated: true)
            }
        }
    }

    /// Same Space handling as the shelf panel: re-assert the collection behavior
    /// and order front regardless of activation so the tab also joins another
    /// app's full-screen Space instead of staying on its previous one.
    private func presentTabPanel() {
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.orderFrontRegardless()
    }

    private func restoreTabAlpha(animated: Bool) {
        guard animated else {
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hideTab(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let generation = visibilityTransition.request(visible: false) else { return }
        guard panel.isVisible else { return }
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            // The shelf's glass starts exactly on the tab and covers it, so the
            // tab only needs a brief hand-off fade (issue #10).
            context.duration = appState.isShelfVisible ? Self.handOffFadeDuration : Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // During the fade-out period, if the state changes back to being in position (re-enable), do
            // not interrupt.
            MainActor.assumeIsolated {
                guard let self,
                      self.visibilityTransition.isCurrent(generation, visible: false),
                      !self.shouldBeVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Layout

    /// Pull ring target screen (same rule as shelf: the screen where the mouse is located, fallback to
    /// main screen if pulled off).
    private func targetVisibleFrame() -> CGRect {
        ShelfWindowController.screen(containing: NSEvent.mouseLocation).visibleFrame
    }

    /// Normal frame: edge normal position (nil for custom only appears when the state machine fails, as a
    /// fallback to a base frame).
    private func baseFrame() -> NSRect {
        return ShelfLayoutEngine.edgeTabFrame(position: settings.shelfPosition,
                                              offset: CGFloat(settings.shelfEdgeOffset),
                                              visibleFrame: targetVisibleFrame())
            ?? NSRect(x: 0, y: 0,
                      width: ShelfLayoutEngine.edgeTabWidth,
                      height: ShelfLayoutEngine.edgeTabHeight)
    }

    /// Current target frame: emphasize state takes the enlarged frame.
    private func currentTargetFrame() -> NSRect {
        let base = baseFrame()
        guard isEmphasized else { return base }
        return ShelfLayoutEngine.edgeTabEmphasisFrame(from: base,
                                                      position: settings.shelfPosition,
                                                      visibleFrame: targetVisibleFrame())
    }

    // MARK: - Emphasis (drag affordance / drop hover)

    /// Emphasize state = drop hover || (dragging in progress and not dragging the ring itself). When
    /// changed, synchronize view highlighting and animate frame switching (normal ↔ slight enlargement).
    private func updateEmphasis(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let emphasized = panel.isVisible
            && (isDropTargeted || (dragStartMonitor.isDragInProgress && !isTabBeingDragged))
        guard emphasized != isEmphasized else { return }
        isEmphasized = emphasized
        tabView.isEmphasized = emphasized
        let target = currentTargetFrame()
        guard animated else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.emphasisDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Gesture results

    /// Drag end (displacement ≥ threshold): persist offset and attachment side. Write to UserDefaults via
    /// didChangeNotification to trigger applyState re-layout —— target frame and gesture end point are
    /// aligned, no visual jump.
    private func finishReposition(offset: CGFloat, position: SettingsStore.ShelfPosition) {
        settings.shelfEdgeOffset = Double(offset)
        if settings.shelfPosition != position {
            settings.shelfPosition = position
        }
    }

    /// Drag and drop on ring: reuse drag insertion dispatch (includes ⌘ cut mode, same determination as
    /// `DragContainerView`); synchronize items directly inserted, asynchronously materialize and append
    /// one by one; show shelf feedback if content is processed.
    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        let mode = DropImportCoordinator.dropMode(for: pasteboard, modifiers: NSEvent.modifierFlags)
        let result = importCoordinator.importItems(
            from: pasteboard,
            mode: mode,
            onManagedMoveReady: { [store, importCoordinator] item in
                do {
                    try store.addAndPersistNow(item)
                    importCoordinator.markManagedMoveCommitted(itemID: item.id)
                    return true
                } catch {
                    store.add(item)
                    importCoordinator.messenger.post(.moveAwaitingSave)
                    return false
                }
            },
            onPromisedItemReady: { [store, importCoordinator] item in
                do {
                    try store.addAndPersistNow(item)
                    return true
                } catch {
                    importCoordinator.messenger.post(.receivedAwaitingRecovery)
                    return false
                }
            }
        ) { [store] item in
            store.add(item)
        }
        guard result.handled else { return false }
        store.add(contentsOf: result.items)
        onShowShelf()
        return true
    }

    // MARK: - Observation

    /// Track shelf visibility and dragging in progress status. onChange of withObservationTracking only
    /// triggers once, re-register after each change; onChange is @Sendable non-isolated closure, bridge
    /// back to MainActor to read latest value (same bridging mode as userDefaultsDidChange). applyState
    /// reads the latest value rather than incremental changes, ensuring safe merging of multiple changes.
    private func beginObservation() {
        withObservationTracking {
            _ = appState.isShelfVisible
            _ = dragStartMonitor.isDragInProgress
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyState(animated: true)
                self.beginObservation()
            }
        }
    }

    /// Must be nonisolated: Notifications are delivered via synchronous callback on the delivery thread
    /// (same as ShelfWindowController / AppDelegate).
    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyState(animated: true)
        }
    }

    @objc private nonisolated func screenParametersDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyState(animated: true)
        }
    }
}

/// EdgeTab content view: Follow system material from appearance settings + inward rounded corners + 1pt
/// inner stroke + small tray SF Symbol (secondary color). Three responsibilities:
/// 1. Mouse gestures (self-managed, no `performDrag` —— constrain movement along edge + edge switch
/// detection):
///    mouseDown records start point → mouseDragged moves along edge (real-time grabbing; approaching the
/// opposite edge across the center line, real-time edge switch, ring adheres to opposite edge at same
/// height) → mouseUp: displacement < 4pt is considered a click,
///    otherwise report offset/attached side for persistence;
/// 2. NSDraggingDestination: register `PasteboardTypes.dragInTypes`, hover/drop callbacks are passed to
/// EdgeTabController;
/// 3. Accent appearance (accent stroke + light fill), driven by controller.
@MainActor
final class EdgeTabView: NSView {
    /// Displacement criteria for click/drag (point).
    static let clickThreshold: CGFloat = 4
    static let cornerRadius: CGFloat = 8

    /// Current attached side (synchronized with controller layout; updated locally instantly during drag
    /// edge switch),
    /// decides corner direction and stroke path. custom has no ring, only serves as fallback (no flip).
    var position: SettingsStore.ShelfPosition = .right {
        didSet {
            guard oldValue != position else { return }
            updateCornering()
        }
    }

    /// Accent state (drag hint / drop hover): accent stroke + light fill, smooth transition.
    var isEmphasized = false {
        didSet {
            guard oldValue != isEmphasized else { return }
            applyEmphasisAppearance(
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        }
    }

    /// Click (lift with displacement < clickThreshold).
    var onClick: (@MainActor () -> Void)?
    /// Drag end report: latest offset and attached side (may have switched edge).
    var onReposition: (@MainActor (CGFloat, SettingsStore.ShelfPosition) -> Void)?
    /// Repositioning session start/end (controller uses this to suppress drag invocation and accent
    /// state).
    var onRepositionStateChanged: (@MainActor (Bool) -> Void)?
    /// Drop hover change.
    var onDropTargetChanged: (@MainActor (Bool) -> Void)?
    /// Drop handling (pasteboard → import); returns whether handled.
    var onDrop: (@MainActor (NSPasteboard) -> Bool)?

    private let vibrancyView = NSVisualEffectView()
    private var nativeGlassView: NSView?
    private let solidView = NSView()
    private let tintLayer = CALayer()
    private let iconView = NSImageView()
    private let strokeLayer = CAShapeLayer()
    private var shelfAppearance = ShelfAppearance.default
    private var hasConfiguredAppearance = false
    private var iconSize = SettingsStore.defaultEdgeTabIconSize
    private var isPointerInside = false
    private var trackingArea: NSTrackingArea?

    // Gesture state (one press session).
    private var isRepositioning = false
    private var dragMoved = false
    private var dragStartCursor: CGPoint = .zero
    private var dragStartCenterY: CGFloat = 0
    private var pendingOffset: CGFloat = 0.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Keep the entire handle hit-testable even with a fully clear material
        // and hidden icon. Only the decoration changes with appearance settings.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor

        vibrancyView.material = .hudWindow
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.wantsLayer = true
        vibrancyView.layer?.cornerRadius = Self.cornerRadius
        vibrancyView.layer?.masksToBounds = true
        vibrancyView.setAccessibilityElement(false)
        vibrancyView.setAccessibilityHidden(true)
        addSubview(vibrancyView)
        solidView.wantsLayer = true
        solidView.setAccessibilityElement(false)
        solidView.setAccessibilityHidden(true)
        addSubview(solidView)
        if #available(macOS 26.0, *) {
            let glass = EdgeTabGlassView()
            glass.contentView = NSView()
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.setAccessibilityElement(false)
            glass.setAccessibilityHidden(true)
            nativeGlassView = glass
            addSubview(glass)
        }
        tintLayer.cornerRadius = Self.cornerRadius
        layer?.addSublayer(tintLayer)

        iconView.image = NSImage(
            systemSymbolName: "tray.and.arrow.down",
            accessibilityDescription: String(localized: "Show Shelf")
        )
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // The containing EdgeTabView is the actual button and already exposes
        // a localized "Show Shelf" label. Keep the decorative symbol out of
        // the accessibility tree so audits and VoiceOver do not encounter a
        // second, unlabeled element for the same control.
        iconView.setAccessibilityElement(false)
        iconView.setAccessibilityHidden(true)
        addSubview(iconView)

        // Inner stroke / accent fill layer: path only adds arcs to inward two corners, inset 0.5.
        strokeLayer.lineWidth = 1
        strokeLayer.zPosition = 1
        layer?.addSublayer(strokeLayer)

        registerForDraggedTypes(PasteboardTypes.dragInTypes)

        setAccessibilityRole(.button)
        // Ring appears only when shelf is hidden, click to expand (mutually exclusive model, see
        // controller).
        setAccessibilityLabel(String(localized: "Show Shelf"))

        updateCornering()
        configure(appearance: .default, iconVisible: true,
                  iconSize: SettingsStore.defaultEdgeTabIconSize)
        applyEmphasisAppearance(animated: false)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private nonisolated func accessibilityOptionsDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.updateMaterial()
            self?.applyEmphasisAppearance(animated: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EdgeTabView is created programmatically")
    }

    override func layout() {
        super.layout()
        if vibrancyView.frame != bounds { vibrancyView.frame = bounds }
        // Put the outer rounded corners beyond the screen edge instead of
        // clipping the system effect's own edge optics with a layer mask.
        let glassFrame = NSRect(x: position == .left ? -Self.cornerRadius : 0,
                                y: 0, width: bounds.width + Self.cornerRadius,
                                height: bounds.height)
        if nativeGlassView?.frame != glassFrame { nativeGlassView?.frame = glassFrame }
        if solidView.frame != bounds { solidView.frame = bounds }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        strokeLayer.frame = bounds
        updateStrokePath()
        CATransaction.commit()
        let iconFrame = ShelfLayoutEngine.edgeTabIconFrame(in: bounds, size: iconSize)
        iconView.frame = iconView.superview?.convert(iconFrame, from: self) ?? iconFrame
    }

    func configure(appearance: ShelfAppearance, iconVisible: Bool, iconSize: Double) {
        let iconSize = SettingsStore.normalizedEdgeTabIconSize(iconSize)
        guard !hasConfiguredAppearance || shelfAppearance != appearance || iconView.isHidden == iconVisible
                || self.iconSize != iconSize else { return }
        hasConfiguredAppearance = true
        shelfAppearance = appearance
        self.iconSize = iconSize
        iconView.isHidden = !iconVisible
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: CGFloat(self.iconSize), weight: .regular
        )
        needsLayout = true
        updateMaterial()
        applyEmphasisAppearance(animated: false)
    }

    private func updateMaterial() {
        let appearance = shelfAppearance
        let workspace = NSWorkspace.shared
        let opaque = workspace.accessibilityDisplayShouldReduceTransparency || appearance.material == .solid
        let nativeGlass = appearance.usesNativeGlass(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
        ) && nativeGlassView != nil
        vibrancyView.isHidden = opaque || nativeGlass || appearance.material == .clear
        nativeGlassView?.isHidden = !nativeGlass
        solidView.isHidden = !opaque && appearance.material != .clear
        tintLayer.isHidden = nativeGlass
        if #available(macOS 26.0, *), let glass = nativeGlassView as? NSGlassEffectView {
            glass.tintColor = appearance.nativeGlassTint
            let iconContainer = nativeGlass ? glass.contentView : self
            if let iconContainer, iconView.superview !== iconContainer {
                iconContainer.addSubview(iconView)
                needsLayout = true
            }
        }
        let theme: NSAppearance? = switch appearance.theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        if self.appearance?.name != theme?.name { self.appearance = theme }
        vibrancyView.material = appearance.material == .frosted ? .popover : .hudWindow
        let opacity = appearance.surfaceOpacity(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
        )
        vibrancyView.alphaValue = opacity
        nativeGlassView?.alphaValue = opacity
        solidView.alphaValue = opacity
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solidView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            tintLayer.backgroundColor = appearance.tint.nsColor.withAlphaComponent(
                appearance.tintOpacity(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
            ).cgColor
        }
        // issue #10: interactive glass inflates past the tab's window on press
        // and gets clipped into a hard outline. Hover/press feedback is drawn
        // by `applyEmphasisAppearance` instead.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let glass = nativeGlassView as? NSGlassEffectView,
           glass.effectIsInteractive {
            glass.effectIsInteractive = false
        }
        #endif
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solidView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        applyEmphasisAppearance(animated: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Decorative native material views must never intercept tab gestures.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        applyEmphasisAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        applyEmphasisAppearance(animated: true)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Mouse gesture (click / reposition / flip)

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartCursor = NSEvent.mouseLocation
        dragStartCenterY = window.frame.midY
        dragMoved = false
        isRepositioning = true
        applyEmphasisAppearance(animated: true)
        onRepositionStateChanged?(true)
    }

    /// Movement along edge: y is driven by drag displacement (start center + Δy, via offset grabbing);
    /// x always adheres to current attached edge —— when approaching opposite edge across center line,
    /// switch edge in real time (adhere to opposite edge at same height).
    override func mouseDragged(with event: NSEvent) {
        guard isRepositioning, let window else { return }
        let cursor = NSEvent.mouseLocation
        if !dragMoved {
            let displacement = hypot(cursor.x - dragStartCursor.x, cursor.y - dragStartCursor.y)
            guard displacement >= Self.clickThreshold else { return }
            dragMoved = true
        }
        let screen = ShelfWindowController.screen(containing: cursor)
        if ShelfLayoutEngine.shouldFlipSide(position: position,
                                            cursorLocation: cursor,
                                            screenFrame: screen.frame) {
            position = position == .left ? .right : .left
        }
        let centerY = dragStartCenterY + (cursor.y - dragStartCursor.y)
        let offset = ShelfLayoutEngine.edgeTabOffset(forCenterY: centerY,
                                                     visibleFrame: screen.visibleFrame)
        pendingOffset = offset
        if let frame = ShelfLayoutEngine.edgeTabFrame(position: position, offset: offset,
                                                      visibleFrame: screen.visibleFrame) {
            window.setFrame(frame, display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isRepositioning else { return }
        isRepositioning = false
        applyEmphasisAppearance(animated: true)
        onRepositionStateChanged?(false)
        if dragMoved {
            dragMoved = false
            onReposition?(pendingOffset, position)
        } else {
            onClick?()
        }
    }

    // MARK: - NSDraggingDestination

    /// Drag out from this app card (draggingSource not empty) is not accepted —— same as
    /// `DragContainerView`, to avoid "drag out and drop back" creating duplicate references.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.isAcceptableDrop(sender) else { return [] }
        onDropTargetChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.isAcceptableDrop(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDropTargetChanged?(false)
    }

    private static func isAcceptableDrop(_ sender: NSDraggingInfo) -> Bool {
        // "Drop everything" semantics same as DragContainerView (task one).
        sender.draggingSource == nil
            && PasteboardTypes.hasImportableContent(in: sender.draggingPasteboard.types ?? [])
    }

    // MARK: - Appearance

    /// Rounded corners facing inward: right edge pull ring rounds left two corners, left edge pull ring
    /// rounds right two corners (symmetrical vertically, unrelated to whether the layer coordinate system
    /// is flipped).
    private func updateCornering() {
        let corners: CACornerMask = position == .left
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        vibrancyView.layer?.maskedCorners = corners
        solidView.layer?.cornerRadius = Self.cornerRadius
        solidView.layer?.maskedCorners = corners
        solidView.layer?.masksToBounds = true
        tintLayer.maskedCorners = corners
        needsLayout = true
        updateStrokePath()
    }

    private func updateStrokePath() {
        let rect = CGRect(origin: .zero, size: bounds.size).insetBy(dx: 0.5, dy: 0.5)
        strokeLayer.path = Self.innerRoundedPath(in: rect,
                                                 radius: Self.cornerRadius - 0.5,
                                                 position: position)
    }

    private func applyEmphasisAppearance(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let interacting = isPointerInside || isRepositioning
        let nativeGlass = shelfAppearance.usesNativeGlass(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let stroke: CGColor = isEmphasized
                ? NSColor.controlAccentColor.cgColor
                : NSColor.labelColor.withAlphaComponent(nativeGlass ? 0 : (interacting ? 0.24 : 0.10)).cgColor
            let fill: CGColor = isEmphasized
                ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                : NSColor.labelColor.withAlphaComponent(isRepositioning ? (nativeGlass ? 0.08 : 0.10)
                                                         : (interacting ? (nativeGlass ? 0.04 : 0.05) : 0)).cgColor
            // Smooth transition: explicit CATransaction duration makes color changes go through implicit
            // animation.
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(animated ? 0.15 : 0)
            strokeLayer.strokeColor = stroke
            strokeLayer.fillColor = fill
            CATransaction.commit()
        }
    }

    /// Only rounded corners on the inward two corners of a rounded rectangle path (right-angle on the edge
    /// side). The path is symmetrical vertically, y-up / y-down coordinate systems are both correct.
    private static func innerRoundedPath(in rect: CGRect,
                                         radius: CGFloat,
                                         position: SettingsStore.ShelfPosition) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let path = CGMutablePath()
        switch position {
        case .right:
            // Facing inward = left side: top-left and bottom-left corners are rounded.
            path.move(to: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: minX + r, y: maxY))
            path.addArc(center: CGPoint(x: minX + r, y: maxY - r), radius: r,
                        startAngle: .pi / 2, endAngle: .pi, clockwise: false)
            path.addLine(to: CGPoint(x: minX, y: minY + r))
            path.addArc(center: CGPoint(x: minX + r, y: minY + r), radius: r,
                        startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
            path.closeSubpath()
        case .left:
            // Facing inward = right side: top-right and bottom-right corners are rounded.
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: maxX - r, y: maxY))
            path.addArc(center: CGPoint(x: maxX - r, y: maxY - r), radius: r,
                        startAngle: .pi / 2, endAngle: 0, clockwise: true)
            path.addLine(to: CGPoint(x: maxX, y: minY + r))
            path.addArc(center: CGPoint(x: maxX - r, y: minY + r), radius: r,
                        startAngle: 0, endAngle: .pi * 1.5, clockwise: true)
            path.closeSubpath()
        case .custom:
            // No pull ring; full rounded rectangle as fallback (should not be reached).
            path.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r,
                                transform: nil))
        }
        return path
    }
}

@available(macOS 26.0, *)
private final class EdgeTabGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
