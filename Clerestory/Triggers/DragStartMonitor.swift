import AppKit

/// UX1 drag start recognition (pure logic state machine, decoupled from AppKit for unit testing):
/// Left click records the start point → dragging, linear displacement from the start point reaches
/// threshold to determine 'drag start'
/// (exactly one callback) → left click up ends.
///
/// Threshold uses 'displacement from the pressed point' rather than 'accumulated path length': micro
/// tremors of the hand during a press will accumulate path length but almost no displacement. The
/// displacement criterion prevents 'holding' from being mistakenly judged as dragging.
struct DragGestureTracker: Sendable, Equatable {
    /// State machine phase.
    enum Phase: String, Sendable, Equatable {
        /// Left mouse button not pressed.
        case idle
        /// Pressed but not yet confirmed as dragging (displacement not reached threshold).
        case pressing
        /// Confirmed dragging (threshold crossed, callback executed).
        case dragging
    }

    /// Dragging displacement threshold (point). ~8pt, same magnitude as system dragging initiation
    /// threshold.
    static let defaultThreshold: CGFloat = 8

    private(set) var phase: Phase = .idle
    private var origin: CGPoint = .zero
    let threshold: CGFloat

    init(threshold: CGFloat = Self.defaultThreshold) {
        self.threshold = threshold
    }

    /// Left mouse button pressed: record start point, enter pressing. (Protection against missed release:
    /// pressing always resets the session.)
    mutating func mouseDown(at point: CGPoint) {
        phase = .pressing
        origin = point
    }

    /// Dragging movement sampling. Return `true` exactly once — at the moment displacement first reaches
    /// threshold; subsequent movements during this drag session always return `false`.
    mutating func mouseDragged(to point: CGPoint) -> Bool {
        guard phase == .pressing else { return false }
        guard hypot(point.x - origin.x, point.y - origin.y) >= threshold else { return false }
        phase = .dragging
        return true
    }

    /// Left mouse button released. Return `true` indicates this release ended a confirmed drag; return
    /// `false` for normal click (displacement not reached threshold).
    mutating func mouseUp() -> Bool {
        defer { phase = .idle }
        return phase == .dragging
    }

    /// Reset (called when stopping listening, discard half session).
    mutating func reset() {
        phase = .idle
    }
}

/// Decides when a Panel opened by a drag learns how that drag ended (pure logic, decoupled from
/// AppKit).
///
/// `DragStartMonitor` reports mouse-up from the global event stream, and AppKit can call
/// `performDragOperation` on the Panel after that, so the import may not have happened at
/// mouse-up. Once a Panel drop destination has seen the drag, the decision waits for both
/// mouse-up and that destination's completion. A drag no Panel destination saw decides at
/// mouse-up. If the destination never reports, `destinationTimedOut(generation:)` decides with
/// what is known.
struct IslandDragEndSession: Sendable, Equatable {
    /// How long to wait for a Panel destination after mouse-up.
    static let destinationTimeout: Duration = .seconds(1)

    /// What the caller does after an event.
    enum Step: Sendable, Equatable {
        /// Nothing to do now.
        case noAction
        /// Wait for the destination; call `destinationTimedOut(generation:)` after
        /// `destinationTimeout`.
        case awaitDestination(generation: Int)
        /// End the Panel drag now with this result.
        case endDrag(imported: Bool)
    }

    /// Identifies the current drag so a timeout from an older drag is ignored.
    private(set) var generation = 0
    private(set) var isDragging = false
    /// Whether this drag opened the Panel.
    private(set) var didActivatePanel = false
    /// Mouse-up has arrived and the decision waits for the destination.
    private(set) var isAwaitingDestination = false
    private var receivedImport = false
    private var destinationSequenceNumber: Int?
    private var destinationDidEnd = false
    private var destinationAccepted = false

    /// Starts a new drag. A previous drag that is still waiting for its destination ends now
    /// with what is known, so the Panel never stays in its drag state.
    mutating func dragBegan() -> Step {
        let previous: Step = isAwaitingDestination ? .endDrag(imported: imported) : .noAction
        reset()
        generation &+= 1
        isDragging = true
        return previous
    }

    /// This drag opened the Panel, so its end decides whether the Panel stays open.
    mutating func markPanelActivated() {
        guard isDragging else { return }
        didActivatePanel = true
    }

    /// Content from this drag reached Shelf.
    mutating func noteImport() {
        guard isDragging || isAwaitingDestination else { return }
        receivedImport = true
    }

    /// A Panel destination has seen this drag; it now owns completion. A callback from an
    /// older drag cannot take over a new one.
    mutating func destinationEntered(sequenceNumber: Int) {
        guard isDragging,
              destinationSequenceNumber == nil || destinationSequenceNumber == sequenceNumber else { return }
        destinationSequenceNumber = sequenceNumber
    }

    /// The destination finished: it accepted a drop, or the drag was rejected, cancelled or
    /// dropped elsewhere. Ends the Panel drag if mouse-up has already arrived.
    mutating func destinationEnded(sequenceNumber: Int, accepted: Bool) -> Step {
        guard destinationSequenceNumber == sequenceNumber, !destinationDidEnd else { return .noAction }
        destinationDidEnd = true
        destinationAccepted = accepted
        return isAwaitingDestination ? finish() : .noAction
    }

    /// Mouse-up ended the drag.
    mutating func mouseUp() -> Step {
        guard isDragging else { return .noAction }
        isDragging = false
        guard didActivatePanel else {
            reset()
            return .noAction
        }
        if destinationSequenceNumber != nil && !destinationDidEnd {
            isAwaitingDestination = true
            return .awaitDestination(generation: generation)
        }
        return finish()
    }

    /// The destination did not report in time. Decide with what is known.
    mutating func destinationTimedOut(generation: Int) -> Step {
        guard isAwaitingDestination, generation == self.generation else { return .noAction }
        return finish()
    }

    private var imported: Bool {
        receivedImport || (destinationDidEnd && destinationAccepted)
    }

    private mutating func finish() -> Step {
        let step = Step.endDrag(imported: imported)
        reset()
        return step
    }

    private mutating func reset() {
        let generation = generation
        self = Self()
        self.generation = generation
    }
}

/// Associates drag-pasteboard content with the current mouse gesture.
///
/// `NSPasteboard.Name.drag` retains the previous drag after that gesture ends.
/// Window moves or text selection can therefore leave stale content from an
/// earlier drag visible to an out-of-session type check.
/// A content drag is eligible only after the pasteboard change count advances
/// beyond the value captured for this gesture's mouse-down event.
struct DragPasteboardTracker: Sendable, Equatable {
    private var mouseDownChangeCount: Int?
    private var observedChangeCount: Int?
    private(set) var hasFreshContent = false

    mutating func mouseDown(changeCount: Int) {
        mouseDownChangeCount = changeCount
        observedChangeCount = changeCount
        hasFreshContent = false
    }

    mutating func mouseDragged(changeCount: Int, hasEligibleContent: Bool) -> Bool {
        guard let mouseDownChangeCount else { return false }
        guard observedChangeCount != changeCount else { return hasFreshContent }

        observedChangeCount = changeCount
        if changeCount != mouseDownChangeCount {
            hasFreshContent = hasEligibleContent
        }
        return hasFreshContent
    }

    mutating func mouseUp() {
        reset()
    }

    mutating func reset() {
        mouseDownChangeCount = nil
        observedChangeCount = nil
        hasFreshContent = false
    }
}

struct DragPasteboardSnapshot: Sendable {
    let changeCount: Int
    let typeIdentifiers: [String]

    var types: [NSPasteboard.PasteboardType] {
        typeIdentifiers.map { NSPasteboard.PasteboardType($0) }
    }

    nonisolated static func current() -> DragPasteboardSnapshot {
        let pasteboard = NSPasteboard(name: .drag)
        return DragPasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            typeIdentifiers: pasteboard.types?.map(\.rawValue) ?? []
        )
    }
}

/// Global Shelf-content drag monitor. A fresh drag pasteboard change establishes the
/// session; a common-run-loop poll fills gaps in AppKit mouse event delivery.
///
/// Sandbox compliance: `NSEvent.addGlobalMonitorForEvents` listens to
/// `leftMouseDown/leftMouseDragged/leftMouseUp` without Accessibility permissions (read-only, does not
/// consume events). Global monitor covers drag from other apps, local monitor covers drag starting from
/// this app's window (shelf card drag out, etc).
///
/// Monitor exists only between `start` and `stop`; `start` is idempotent.
///
/// Callback semantics:
/// - `onDragStart`: First detection of new file or text drag (ignores drag if suppressed by
/// `shouldSuppress` when not in the foreground list);
/// - `onDragEnd`: Left mouse button lifted after confirmed drag (not suppressed — suppression means no
/// session).
///
/// `isDragInProgress` is set when the threshold is confirmed, whether or not `shouldSuppress` blocks
/// the session, and resets on lift or `stop()`.
@MainActor
@Observable
final class DragStartMonitor {
    /// Whether the event monitors are currently registered.
    private(set) var isMonitoring = false

    /// Confirmed drag session is in progress (threshold crossed → lift).
    private(set) var isDragInProgress = false

    private var gestureTracker = DragGestureTracker()
    private var dragPayloadTracker = DragPasteboardTracker()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var dragPollTimer: Timer?
    private var dragSessionSuppressed = false
    private var lastIdlePasteboardChangeCount: Int?
    private var isPotentialDrag = false
    private let onPotentialDragChange: @MainActor (Bool) -> Void
    private let onNativeDragUpdate: @MainActor (CGPoint) -> Void

    /// Ignore-list gate, evaluated only at the moment a drag is confirmed.
    private let shouldSuppress: @MainActor () -> Bool
    private let onDragStart: @MainActor () -> Void
    private let onDragUpdate: @MainActor (CGPoint) -> Void
    private let onDragEnd: @MainActor () -> Void

    init(shouldSuppress: @escaping @MainActor () -> Bool,
         onDragStart: @escaping @MainActor () -> Void,
         onDragUpdate: @escaping @MainActor (CGPoint) -> Void = { _ in },
         onPotentialDragChange: @escaping @MainActor (Bool) -> Void = { _ in },
         onNativeDragUpdate: @escaping @MainActor (CGPoint) -> Void = { _ in },
         onDragEnd: @escaping @MainActor () -> Void) {
        self.shouldSuppress = shouldSuppress
        self.onDragStart = onDragStart
        self.onDragUpdate = onDragUpdate
        self.onDragEnd = onDragEnd
        self.onPotentialDragChange = onPotentialDragChange
        self.onNativeDragUpdate = onNativeDragUpdate
    }

    /// Registers the monitors. Idempotent: starting while monitoring is a no-op.
    func start() {
        guard !isMonitoring else { return }
        let initialChangeCount = DragPasteboardSnapshot.current().changeCount
        lastIdlePasteboardChangeCount = initialChangeCount
        dragPayloadTracker.mouseDown(changeCount: initialChangeCount)
        gestureTracker.mouseDown(at: NSEvent.mouseLocation)

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            let location = NSEvent.mouseLocation
            let type = event.type
            let snapshot = DragPasteboardSnapshot.current()
            Task { @MainActor in
                self.handle(eventType: type, at: location, snapshot: snapshot)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            let location = NSEvent.mouseLocation
            let type = event.type
            let snapshot = DragPasteboardSnapshot.current()
            Task { @MainActor in
                self.handle(eventType: type, at: location, snapshot: snapshot)
            }
            return event
        }
        // Native Finder drags can stop delivering ordinary mouse-drag events,
        // particularly after Show Desktop. Poll the drag pasteboard and pointer
        // while the gesture is active so the Island still sees the content drag.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragPollTimer = timer
        isMonitoring = true
    }

    /// Removes all event registrations.
    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        dragPollTimer?.invalidate()
        dragPollTimer = nil
        setPotentialDrag(false)
        dragPayloadTracker.reset()
        gestureTracker.reset()
        isMonitoring = false
        isDragInProgress = false
        dragSessionSuppressed = false
        lastIdlePasteboardChangeCount = nil
    }

    private func pollDrag() {
        guard isMonitoring else { return }
        let snapshot = DragPasteboardSnapshot.current()
        if NSEvent.pressedMouseButtons & 1 == 0 {
            setPotentialDrag(false)
            finishDrag()
            // Keep a baseline while idle. The drag pasteboard retains the
            // previous payload, so only a new change may start another session.
            lastIdlePasteboardChangeCount = snapshot.changeCount
            dragPayloadTracker.mouseDown(changeCount: snapshot.changeCount)
            gestureTracker.mouseDown(at: NSEvent.mouseLocation)
            return
        }
        sampleDrag(at: NSEvent.mouseLocation, snapshot: snapshot)
    }

    private func sampleDrag(at point: CGPoint, snapshot: DragPasteboardSnapshot) {
        let hasSharedShelfDrag = dragPayloadTracker.mouseDragged(
            changeCount: snapshot.changeCount,
            hasEligibleContent: PasteboardTypes.hasShelfApproachContent(in: snapshot.types)
        )
        let movedFarEnough = gestureTracker.mouseDragged(to: point)
            || gestureTracker.phase == .dragging
        setPotentialDrag(movedFarEnough && !shouldSuppress())
        guard hasSharedShelfDrag else { return }
        if !isDragInProgress {
            isDragInProgress = true
            dragSessionSuppressed = shouldSuppress()
            if !dragSessionSuppressed { onDragStart() }
        }
        if !dragSessionSuppressed { onDragUpdate(point) }
    }

    private func finishDrag() {
        guard isDragInProgress else { return }
        isDragInProgress = false
        dragSessionSuppressed = false
        onDragEnd()
    }

    private func setPotentialDrag(_ active: Bool) {
        guard active != isPotentialDrag else { return }
        isPotentialDrag = active
        onPotentialDragChange(active)
    }

    /// The Island destination has the session's real pasteboard even when
    /// cross-process drag data never appears on the shared pasteboard.
    func confirmShelfDragFromDestination(at point: CGPoint) {
        guard isMonitoring else { return }
        if !isDragInProgress {
            isDragInProgress = true
            dragSessionSuppressed = shouldSuppress()
            if !dragSessionSuppressed { onDragStart() }
        }
        if !dragSessionSuppressed { onNativeDragUpdate(point) }
    }

    private func handle(eventType: NSEvent.EventType,
                        at point: CGPoint,
                        snapshot: DragPasteboardSnapshot) {
        guard isMonitoring else { return }
        switch eventType {
        case .leftMouseDown:
            guard !isDragInProgress else { return }
            gestureTracker.mouseDown(at: point)
            // The drag pasteboard may already have changed by the time the
            // mouse-down event reaches us after Show Desktop. Use the last
            // idle sample so that early change still belongs to this gesture.
            dragPayloadTracker.mouseDown(
                changeCount: lastIdlePasteboardChangeCount ?? snapshot.changeCount
            )
        case .leftMouseDragged:
            sampleDrag(at: point, snapshot: snapshot)
        case .leftMouseUp:
            setPotentialDrag(false)
            dragPayloadTracker.mouseUp()
            gestureTracker.reset()
            finishDrag()
        default:
            break
        }
    }
}
