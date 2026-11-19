/// Presentation policy independent of AppKit windows, animations, and timers.
struct IslandNoticePresentation {
    struct Context {
        var isEnabled: Bool
        var surface: IslandSurfaceState
        var isTransitioning: Bool
        var isDragging: Bool
        /// The module the expanded panel shows, or `nil` when the panel is not expanded.
        var shownModule: IslandModuleID? = nil

        /// Whether a new notice from a module other than `shownModule` waits for the panel to
        /// close: the panel is open and not pinned. The message center gets the same answer
        /// through `setShownModule(_:othersWait:)`, so its queue agrees with this policy.
        var othersWaitForClose: Bool { surface == .expanded }
    }

    enum Phase: Equatable {
        case idle
        case waiting
        case visible
    }

    private(set) var phase: Phase = .idle
    private var noticeID: UInt64?
    private var hasAppeared = false

    /// A new notice waits for an unpinned panel to close, unless the panel shows the module that
    /// posted it. A drag defers every notice. Once presented, a notice follows later expansion
    /// changes without waiting again.
    mutating func update(noticeID nextID: UInt64?, from moduleID: IslandModuleID? = nil,
                         context: Context) -> Phase {
        if noticeID != nextID {
            noticeID = nextID
            hasAppeared = false
        }
        guard nextID != nil, context.isEnabled else {
            phase = .idle
            return phase
        }
        let isFromShownModule = moduleID != nil && moduleID == context.shownModule
        let waitsForClose = !hasAppeared
            && ((context.othersWaitForClose && !isFromShownModule) || context.isTransitioning)
        if context.isDragging || waitsForClose {
            phase = .waiting
        } else {
            hasAppeared = true
            phase = .visible
        }
        return phase
    }
}
