import SwiftUI

/// Keep the rendered surface alive until its own animated values reach closed.
/// A removal transition cannot reliably propagate changing environment values
/// into the subtree SwiftUI has already detached.
struct IslandSurfaceAnimationHost<Content: View>: View {
    let isExpanded: Bool
    let transitionID: UInt64
    let onCompleted: (UInt64) -> Void
    @ViewBuilder var content: (IslandSurfaceReveal) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = IslandSurfaceReveal(progress: 0, opacity: 0)
    @State private var isMounted = false
    @State private var targetExpanded = false
    @State private var animationID: UUID?
    @State private var requestedTransitionID: UInt64 = 0

    var body: some View {
        ZStack(alignment: .top) {
            if isMounted {
                content(reveal)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: transitionID, initial: true) { update() }
    }

    private func update() {
        requestedTransitionID = transitionID
        if reduceMotion {
            animationID = nil
            targetExpanded = isExpanded
            reveal = .init(progress: isExpanded ? 1 : 0, opacity: isExpanded ? 1 : 0)
            isMounted = isExpanded
            onCompleted(requestedTransitionID)
            return
        }
        guard targetExpanded != isExpanded else {
            if animationID == nil { onCompleted(requestedTransitionID) }
            return
        }
        targetExpanded = isExpanded
        let id = UUID()
        animationID = id
        let needsMount = isExpanded && !isMounted
        if needsMount {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                reveal = .init(progress: 0, opacity: 0.82)
                isMounted = true
            }
            // Commit the initial mounted shape before changing its target.
            DispatchQueue.main.async { animate(id: id) }
        } else {
            animate(id: id)
        }
    }

    private func animate(id: UUID) {
        guard animationID == id else { return }
        withAnimation(.smooth(duration: targetExpanded ? IslandMotion.expandContentDuration
                                  : IslandMotion.collapseContentDuration, extraBounce: 0),
                      completionCriteria: .removed) {
            reveal = .init(progress: targetExpanded ? 1 : 0, opacity: targetExpanded ? 1 : 0)
        } completion: {
            guard animationID == id else { return }
            animationID = nil
            if !targetExpanded { isMounted = false }
            onCompleted(requestedTransitionID)
        }
    }
}
