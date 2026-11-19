/// Presentation policy independent of AppKit windows, animations, and timers.
struct IslandNoticePresentation {
    struct Context {
        var isEnabled: Bool
        var surface: IslandSurfaceState
        var isTransitioning: Bool
        var isDragging: Bool
    }

    enum Phase: Equatable {
        case idle
        case waiting
        case visible
    }

    private(set) var phase: Phase = .idle
    private var revision: UInt64?
    private var hasAppeared = false

    /// Each new notice waits for an unpinned Island to close. Once presented,
    /// that notice follows later expansion changes without being queued again.
    mutating func update(revision nextRevision: UInt64?, context: Context) -> Phase {
        if revision != nextRevision {
            revision = nextRevision
            hasAppeared = false
        }
        guard nextRevision != nil, context.isEnabled else {
            phase = .idle
            return phase
        }
        let waitsForClose = !hasAppeared && (context.surface == .expanded || context.isTransitioning)
        if context.isDragging || waitsForClose {
            phase = .waiting
        } else {
            hasAppeared = true
            phase = .visible
        }
        return phase
    }
}
