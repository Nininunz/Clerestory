import AppKit

/// UX1 拖拽开始识别（纯逻辑状态机，与 AppKit 解耦供单测）：
/// 左键按下记录起点 → 按住移动、与起点的直线位移达到阈值判定「拖拽开始」
/// （恰好回调一次）→ 左键抬起结束。
///
/// 阈值采用「与按下点的位移」而非「路径累计长度」：点击按住不放时手的微颤
/// 会累计路径长度但几乎不产生位移，位移判据不会把「按住不放」误判为拖拽。
struct DragGestureTracker: Sendable, Equatable {
    /// 状态机相位。
    enum Phase: String, Sendable, Equatable {
        /// 左键未按下。
        case idle
        /// 已按下、尚未确认拖拽（位移未达阈值）。
        case pressing
        /// 已确认拖拽（阈值已跨越、已回调）。
        case dragging
    }

    /// 拖拽判定位移阈值（点）。~8pt 与系统拖拽启动阈值同量级。
    static let defaultThreshold: CGFloat = 8

    private(set) var phase: Phase = .idle
    private var origin: CGPoint = .zero
    let threshold: CGFloat

    init(threshold: CGFloat = Self.defaultThreshold) {
        self.threshold = threshold
    }

    /// 左键按下：记录起点，进入 pressing。（漏抬起的防护：按下总是重置会话。）
    mutating func mouseDown(at point: CGPoint) {
        phase = .pressing
        origin = point
    }

    /// 按住移动采样。返回 `true` 恰好一次 —— 位移首次达到阈值的时刻；
    /// 此后本次拖拽的继续移动恒返回 `false`。
    mutating func mouseDragged(to point: CGPoint) -> Bool {
        guard phase == .pressing else { return false }
        guard hypot(point.x - origin.x, point.y - origin.y) >= threshold else { return false }
        phase = .dragging
        return true
    }

    /// 左键抬起。返回 `true` 表示本次抬起结束了一个已确认的拖拽；
    /// 普通点击（未达阈值）返回 `false`。
    mutating func mouseUp() -> Bool {
        defer { phase = .idle }
        return phase == .dragging
    }

    /// 复位（停止监听时调用，丢弃半会话）。
    mutating func reset() {
        phase = .idle
    }
}

/// UX1/2: 一次拖拽会话中 shelf 自动显隐的裁决（纯逻辑，与 AppKit 解耦）。
///
/// 语义（用户确认）：
/// - 拖拽驱动唤出 shelf 时打 `shownAutomatically` 标记（仅当唤出前 shelf
///   不可见 —— 拖拽前已可见说明是用户手动唤出的，本轮不动它）；
/// - 本轮拖拽中有内容成功落入 shelf（`DropImportCoordinator.onImportHandled`）
///   → `noteImport()` 复位「无落入」假设；
/// - 拖拽结束：未投放则收回；成功投放默认保持展开，可由用户关闭。
/// - 已进入本地接收区时等待 AppKit 的投放结果，而不是猜测回调延迟。
struct DragAutoShowSession: Sendable, Equatable {
    /// 本轮是否处于已确认的拖拽会话中（mouseDown 阈值跨越 → mouseUp）。
    private(set) var isDragging = false
    /// 本轮拖拽是否触发了自动唤出（唤出时 shelf 原本不可见）。
    private(set) var shownAutomatically = false
    /// 本轮拖拽中是否已有内容成功入架。
    private(set) var receivedImport = false
    private var destinationSequenceNumber: Int?
    private var destinationDidEnd = false
    private var destinationAccepted = false
    private var keepAfterDrop = true

    /// 拖拽开始（阈值跨越）：开启新会话，清空上一轮的全部标记。
    mutating func dragBegan() {
        self = Self()
        isDragging = true
    }

    /// 标记「本次显示为拖拽驱动的自动唤出」。不在拖拽会话中（如快捷键
    /// 唤出、剪贴板保存唤出）时忽略 —— 那些是显式意图，不参与自动收回。
    mutating func markShownAutomatically() {
        guard isDragging else { return }
        shownAutomatically = true
    }

    /// 本轮有内容成功入架（同步导入或已派发异步物化）。
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
/// 沙箱合规：`NSEvent.addGlobalMonitorForEvents` 监听
/// `leftMouseDown/leftMouseDragged/leftMouseUp` 无需 Accessibility 权限
/// （只读、不消费事件）。global monitor 覆盖其他应用内的拖拽，local
/// monitor 覆盖从本应用窗口（shelf 卡片拖出等）起始的拖拽。
///
/// 注册生命周期与 `MouseShakeMonitor` 一致：monitor 只存在于 `start` 与
/// `stop` 之间；`start` 幂等。
///
/// 回调语义：
/// - `onDragStart`：首次检测到新文件或文本拖拽（忽略列表前台时经 `shouldSuppress` 抑制）；
/// - `onDragEnd`：已确认拖拽的左键抬起（不被抑制 —— 抑制即无会话，
///   配合 `DragAutoShowSession` 空转安全）。
///
/// EdgeTab: `isDragInProgress` 是可观察的「拖拽进行中」状态（阈值确认即置位，
/// 不受 `shouldSuppress` 影响 —— 抑制只挡唤出，不改变「正在拖拽」的事实），
/// 供边缘拉环做投放暗示高亮；抬起或 `stop()` 复位。
@MainActor
@Observable
final class DragStartMonitor {
    /// Whether the event monitors are currently registered.
    private(set) var isMonitoring = false

    /// EdgeTab: 已确认的拖拽会话进行中（阈值跨越 → 抬起）。
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
