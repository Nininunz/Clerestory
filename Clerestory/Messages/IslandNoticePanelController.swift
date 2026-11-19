import AppKit
import Observation
import SwiftUI

/// Owns the independent notice pill window; presentation policy lives in IslandNoticePresentation.
/// It is the message center's presenter: it runs the notice clock only while the pill is on
/// screen and the pointer is not resting on its button.
@MainActor
final class IslandNoticePanelController: NSObject {
    private weak var anchor: NSWindow?
    private let messages: IslandMessageCenter
    private let coordinator: IslandActivityCoordinator
    private let settings: SettingsStore
    private let dropTarget: DropTargetState
    private let pointerLocation: @MainActor () -> CGPoint
    let panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)

    private var presentation = IslandNoticePresentation()
    private var phase: IslandNoticePresentation.Phase = .idle
    private var isPointerOverAction = false
    private var hostingView: NSHostingView<IslandNoticePanelContent>?
    private var renderedNotice: IslandNotice?
    private var pillSize = CGSize.zero
    private var lastTargetFrame: CGRect?
    private var isShowing = false
    private var animationGeneration = 0
    private var stopped = false

    init(anchor: NSWindow, messages: IslandMessageCenter, coordinator: IslandActivityCoordinator,
         settings: SettingsStore, dropTarget: DropTargetState,
         pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) {
        self.anchor = anchor
        self.messages = messages
        self.coordinator = coordinator
        self.settings = settings
        self.dropTarget = dropTarget
        self.pointerLocation = pointerLocation
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
        return panel.frame.insetBy(dx: IslandNoticePlacement.shadowInset, dy: IslandNoticePlacement.shadowInset)
    }

    func contains(_ point: CGPoint) -> Bool {
        guard let frame = interactionFrame else { return false }
        return NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).contains(point)
    }

    /// The larger shadow canvas must not intercept clicks meant for the Island. Resting on a
    /// pill's button holds the notice; IslandPresentationController calls this on every move.
    func updatePointer(at point: CGPoint) {
        isPointerOverAction = renderedNotice?.action != nil && contains(point)
        panel.ignoresMouseEvents = !isPointerOverAction
        updateNoticeClock()
    }

    /// Only visible, unheld time counts. With the Panel disabled (idle) nothing can show the
    /// notice, so it times out as if seen rather than piling up.
    private func updateNoticeClock() {
        guard !stopped else { return }
        let running = switch phase {
        case .visible: !isPointerOverAction
        case .idle: true
        case .waiting: false
        }
        messages.setNoticeClockRunning(running)
    }

    func stop() {
        stopped = true
        animationGeneration += 1
        isShowing = false
        NotificationCenter.default.removeObserver(self)
        // Without a presenter nobody can see a notice, so its time does not count.
        messages.setNoticeClockRunning(false)
        panel.orderOut(nil)
    }

    private var context: IslandNoticePresentation.Context {
        .init(isEnabled: settings.islandEnabled,
              surface: coordinator.surfaceState,
              isTransitioning: coordinator.isSurfaceTransitionPending,
              isDragging: dropTarget.isTargeted,
              shownModule: coordinator.surfaceState.isExpanded ? coordinator.selectedModule : nil)
    }

    private func observe() {
        guard !stopped else { return }
        withObservationTracking {
            _ = messages.currentNotice
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
        let current = messages.currentNotice
        phase = presentation.update(noticeID: current?.id, from: current?.moduleID, context: context)
        guard phase == .visible, let anchor, let notice = current?.notice else {
            dismiss()
            updatePointer(at: pointerLocation())
            return
        }
        updateContent(notice)
        // During a transition the Island window still contains the visible surface.
        let usesSurfaceFrame = coordinator.surfaceState.isExpanded || coordinator.isSurfaceTransitionPending
        let anchorFrame = usesSurfaceFrame && anchor.isVisible
            ? (anchor as? ShelfPanel)?.interactionFrame ?? anchor.frame
            : coordinator.currentLayout?.closedNoticeAnchor ?? anchor.frame
        let target = IslandNoticePlacement.frame(below: anchorFrame, pillSize: pillSize)
        panel.level = anchor.level
        if isShowing { move(to: target) } else { show(at: target) }
        lastTargetFrame = target
        updatePointer(at: pointerLocation())
    }

    private func updateContent(_ notice: IslandNotice) {
        guard renderedNotice != notice else { return }
        let content = IslandNoticePanelContent(notice: notice) { [weak messages] action in
            messages?.perform(action)
        }
        let host: NSHostingView<IslandNoticePanelContent>
        if let hostingView {
            host = hostingView
            host.rootView = content
        } else {
            host = NSHostingView(rootView: content)
            hostingView = host
            panel.contentView = host
        }
        pillSize = IslandNoticePlacement.pillSize(in: host.fittingSize)
        renderedNotice = notice
        updatePointer(at: pointerLocation())
    }

    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func show(at target: CGRect) {
        animationGeneration += 1 // Invalidate any outstanding fade-out completion.
        isShowing = true
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: reducedMotion ? 0 : 8), display: true)
        panel.orderFront(nil)
        updatePointer(at: pointerLocation())
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
