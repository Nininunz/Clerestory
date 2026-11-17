import Foundation

/// Flip this to restore the retained file-area blur and duplicate overlay.
enum ShelfDuplicateFeedback {
    static let usesFileOverlay = false

    @MainActor
    static func isDuplicateTarget(_ target: DropTargetState) -> Bool {
        target.isTargeted && target.hasDuplicateFiles && !target.isReordering && target.mode == .copy
    }
}
