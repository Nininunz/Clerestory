import Foundation
import Observation

/// Global app state (shelf visibility, etc).
///
/// SwiftUI observes this state through `@Environment`. On the AppKit side, `ShelfWindowController` updates
/// `isShelfVisible` when it shows or hides the panel.
@MainActor
@Observable
final class AppState {
    /// Whether the Shelf panel is currently visible.
    private(set) var isShelfVisible = false

    /// EdgeTab: The ring is being pressed and dragged (repositioning session in progress), maintained by
    /// EdgeTabController. Drag-driven triggers (DragStartMonitor invocation / EdgeTriggerMonitor edge) are
    /// suppressed based on this. Dragging the ring itself should not trigger the shelf. Placed here rather
    /// than EdgeTabController: monitor's suppression closure referencing the controller would cause a lazy
    /// property cycle (edgeTabController ⇄ dragStartMonitor).
    private(set) var isEdgeTabBeingDragged = false

    func toggleShelf() {
        isShelfVisible.toggle()
    }

    func showShelf() {
        isShelfVisible = true
    }

    func hideShelf() {
        isShelfVisible = false
    }

    /// Start/end of EdgeTab repositioning session.
    func setEdgeTabBeingDragged(_ dragged: Bool) {
        isEdgeTabBeingDragged = dragged
    }
}
