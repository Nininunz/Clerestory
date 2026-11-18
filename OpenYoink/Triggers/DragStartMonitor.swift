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

/// UX1/2: Decision on shelf auto-show/hide during a drag session (pure logic, decoupled from AppKit).
///
/// Semantics (user confirmation):
/// - When drag triggers shelf appearance, mark as `shownAutomatically` (only if shelf was not visible
/// before drag — if it was visible before, it was user-initiated, so do not change this session);
/// - If content successfully drops into shelf during this drag (`DropImportCoordinator.onImportHandled`) →
/// `noteImport()` resets the 'no drop' assumption;
/// - Drag ends: if no drop, shelf retracts; if successful drop, shelf remains expanded by default, can be
/// closed by user.
/// - Wait for AppKit's drop result when entering local receiving area, rather than guessing callback
/// delay.
struct DragAutoShowSession: Sendable, Equatable {
    /// Whether this session is in a confirmed drag (mouseDown threshold crossed → mouseUp).
    private(set) var isDragging = false
    /// Whether this drag triggered automatic shelf appearance (shelf was originally invisible).
    private(set) var shownAutomatically = false
    /// Whether content has successfully dropped into shelf during this drag.
    private(set) var receivedImport = false
    private var destinationSequenceNumber: Int?
    private var destinationDidEnd = false
    private var destinationAccepted = false
    private var keepAfterDrop = true

    /// Drag started (threshold crossed): start new session, clear all previous markers.
    mutating func dragBegan() {
        self = Self()
        isDragging = true
    }

    /// Mark 'this display is triggered by drag-driven auto-show'. Ignore when not in a drag session (e.g.,
    /// triggered by shortcut key, clipboard save trigger) — those are explicit intents and do not
    /// participate in auto-retract.
    mutating func markShownAutomatically() {
        guard isDragging else { return }
        shownAutomatically = true
    }

    /// This round has content successfully entered the shelf (synchronous import or already dispatched
    /// asynchronous materialization).
    mutating func noteImport() {
        receivedImport = true
    }

    /// A real AppKit destination owns completion once it has seen this drag.
    /// Keep the identity after exit: draggingEnded also covers cancellation or
    /// a drop elsewhere. A late callback from an older drag cannot close a new one.
    mutating func destinationEntered(sequenceNumber: Int) {
        guard isDragging,
              destinationSequenceNumber == nil || destinationSequenceNumber == sequenceNumber else { return }
        destinationSequenceNumber = sequenceNumber
    }

    /// Returns a hide decision only after BOTH mouse-up and destination completion.
    mutating func destinationEnded(sequenceNumber: Int, accepted: Bool) -> Bool {
        guard destinationSequenceNumber == sequenceNumber, !destinationDidEnd else { return false }
        destinationDidEnd = true
        destinationAccepted = accepted
        return isDragging ? false : finish()
    }

    /// Explicit show/hide takes ownership away from automatic presentation.
    mutating func cancelAutomaticHide() {
        shownAutomatically = false
    }

    mutating func dragEnded(keepShelfOpenAfterDrop: Bool = true) -> Bool {
        guard isDragging else { return false }
        isDragging = false
        keepAfterDrop = keepShelfOpenAfterDrop
        if destinationSequenceNumber != nil && !destinationDidEnd { return false }
        return finish()
    }

    private mutating func finish() -> Bool {
        defer { self = Self() }
        let accepted = destinationSequenceNumber == nil ? receivedImport : destinationAccepted
        return shownAutomatically && !(accepted && keepAfterDrop)
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
/// session, safe for `DragAutoShowSession` to idle).
///
/// EdgeTab: `isDragInProgress` is an observable 'drag in progress' state (set when threshold is confirmed,
/// not affected by `shouldSuppress` — suppression only blocks show, does not change the fact that dragging
/// is happening), used for highliting in edge pull ring; reset on lift or `stop()`.
@MainActor
@Observable
final class DragStartMonitor {
    /// Whether the event monitors are currently registered.
    private(set) var isMonitoring = false

    /// EdgeTab: Confirmed drag session is in progress (threshold crossed → lift).
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
