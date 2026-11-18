import AppKit
import SwiftUI

/// Window drag handle for custom position mode (S9, planned §1.1 setting line closure).
///
/// A transparent NSView covers the Shelf title bar. Mouse-down enters AppKit’s standard window drag loop
/// through `performDrag(with:)`, which handles moving between displays and constrains the window to the
/// screen. On mouse-up, `onDragEnded` passes the final frame in screen coordinates to the caller for
/// persistence.
///
/// Why not use `isMovableByWindowBackground`: the entire panel background can be dragged, which may
/// interfere with card dragging out
/// (NSDraggingSession source, mouseDragged driven) and ScrollView scrolling gesture; dragging entry is
/// narrowed to the title bar area to avoid interference.
@MainActor
final class WindowDragHandleView: NSView {
    /// Drag end callback (parameter is the final window frame, global screen coordinates).
    var onDragEnded: ((NSRect) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WindowDragHandleView is created programmatically")
    }

    /// Click to enter window drag loop; panel nonactivating, acceptsFirstMouse ensures
    /// the first click can drag even when the app is not active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.performDrag(with: event)
        onDragEnded?(window.frame)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// SwiftUI bridging (see ShelfView.header, only mounted in custom position mode).
struct WindowDragHandle: NSViewRepresentable {
    var onDragEnded: @MainActor (NSRect) -> Void

    func makeNSView(context: Context) -> WindowDragHandleView {
        let view = WindowDragHandleView()
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: WindowDragHandleView, context: Context) {
        nsView.onDragEnded = onDragEnded
    }
}
