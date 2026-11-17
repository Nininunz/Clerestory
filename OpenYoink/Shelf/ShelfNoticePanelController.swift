import AppKit
import Observation
import SwiftUI

/// Owns the independent notice window; presentation policy lives in ShelfNoticePresentation.
@MainActor
final class ShelfNoticePanelController: NSObject {
    private weak var anchor: NSWindow?
    private let notices: ShelfNoticeModel
    private let coordinator: IslandActivityCoordinator
    private let settings: SettingsStore
    private let dropTarget: DropTargetState
    private let onRecovery: (RecoveryAction) -> Void
    let panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)

    private var presentation = ShelfNoticePresentation()
    private var hostingView: NSHostingView<ShelfNoticePanelContent>?
    private var renderedNotice: ShelfNoticeContent?
    private var pillSize = CGSize.zero
    private var lastTargetFrame: CGRect?
    private var isShowing = false
    private var animationGeneration = 0
    private var stopped = false

    init(anchor: NSWindow, notices: ShelfNoticeModel, coordinator: IslandActivityCoordinator,
         settings: SettingsStore, dropTarget: DropTargetState,
         onRecovery: @escaping (RecoveryAction) -> Void) {
        self.anchor = anchor
        self.notices = notices
        self.coordinator = coordinator
        self.settings = settings
        self.dropTarget = dropTarget
        self.onRecovery = onRecovery
        super.init()
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(anchorChanged), name: name, object: anchor)
        }
        observe()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var interactionFrame: CGRect? {
        guard isShowing, panel.isVisible else { return nil }
        return panel.frame.insetBy(dx: ShelfNoticePlacement.shadowInset, dy: ShelfNoticePlacement.shadowInset)
    }

    func contains(_ point: CGPoint) -> Bool {
        guard let frame = interactionFrame else { return false }
        return NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).contains(point)
    }

    /// The larger shadow canvas must not intercept clicks meant for the Island.
    func updatePointer(at point: CGPoint) {
        panel.ignoresMouseEvents = renderedNotice?.recoveryAction == nil || !contains(point)
    }

    func stop() {
        stopped = true
        animationGeneration += 1
        isShowing = false
        NotificationCenter.default.removeObserver(self)
        notices.setPresentationDeferred(false)
        panel.orderOut(nil)
    }

    private var context: ShelfNoticePresentation.Context {
        .init(isEnabled: settings.islandEnabled,
              surface: coordinator.surfaceState,
              isTransitioning: coordinator.isSurfaceTransitionPending,
              isDragging: dropTarget.isTargeted)
    }

    private func observe() {
        guard !stopped else { return }
        withObservationTracking {
            _ = notices.current
            _ = notices.revision
            _ = context
            _ = coordinator.currentLayout
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        refresh()
    }

    @objc private func anchorChanged() { refresh() }

    private func refresh() {
        guard !stopped else { return }
        let phase = presentation.update(revision: notices.current == nil ? nil : notices.revision,
                                        context: context)
        notices.setPresentationDeferred(phase == .waiting)
        guard phase == .visible, let anchor, let notice = notices.current else {
            dismiss()
            return
        }
        updateContent(notice)
        // During a transition the Island window still contains the visible surface.
        let usesSurfaceFrame = coordinator.surfaceState.isExpanded || coordinator.isSurfaceTransitionPending
        let anchorFrame = usesSurfaceFrame && anchor.isVisible
            ? anchor.frame : coordinator.currentLayout?.compactFrame ?? anchor.frame
        let target = ShelfNoticePlacement.frame(below: anchorFrame, pillSize: pillSize)
        panel.level = anchor.level
        if isShowing { move(to: target) } else { show(at: target) }
        lastTargetFrame = target
        updatePointer(at: NSEvent.mouseLocation)
    }

    private func updateContent(_ notice: ShelfNoticeContent) {
        guard renderedNotice != notice else { return }
        let content = ShelfNoticePanelContent(notice: notice, onRecovery: onRecovery)
        let host: NSHostingView<ShelfNoticePanelContent>
        if let hostingView {
            host = hostingView
            host.rootView = content
        } else {
            host = NSHostingView(rootView: content)
            hostingView = host
            panel.contentView = host
        }
        pillSize = ShelfNoticePlacement.pillSize(in: host.fittingSize)
        renderedNotice = notice
        updatePointer(at: NSEvent.mouseLocation)
    }

    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func show(at target: CGRect) {
        animationGeneration += 1 // Invalidate any outstanding fade-out completion.
        isShowing = true
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: reducedMotion ? 0 : 8), display: true)
        panel.orderFront(nil)
        updatePointer(at: NSEvent.mouseLocation)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0 : 0.2
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func move(to target: CGRect) {
        guard lastTargetFrame != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0 : (coordinator.surfaceState.isExpanded
                ? IslandMotion.expandContentDuration : IslandMotion.collapseContentDuration)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func dismiss() {
        guard isShowing else { return }
        isShowing = false
        animationGeneration += 1
        let token = animationGeneration
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0 : 0.16
            panel.animator().alphaValue = 0
            if !reducedMotion { panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 6), display: true) }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == token else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
