import AppKit
import SwiftUI

/// Borderless, nonactivating Shelf window that floats above other windows,
/// joins all Spaces, and can appear alongside full-screen windows.
/// `ShelfView` draws the rounded, translucent surface.
@MainActor
final class ShelfPanel: NSPanel {
    /// Allow top-edge surfaces to use their requested frame. AppKit otherwise
    /// constrains shallow windows to `visibleFrame`, below the menu bar.
    /// The classic Shelf keeps AppKit's standard screen constraints.
    var allowsTopEdgeOverlap = false
    var acceptsKeyboardFocus = true
    /// Drawing room for a SwiftUI shadow is not part of the interactive surface.
    var interactionInset: CGFloat = 0
    var interactionCornerRadius: CGFloat = 0

    var interactionFrame: CGRect { frame.insetBy(dx: interactionInset, dy: interactionInset) }

    func containsInteractionPoint(_ point: CGPoint) -> Bool {
        IslandSurfaceShape(attachedToScreenTop: false, cornerRadius: interactionCornerRadius)
            .path(in: interactionFrame).contains(point)
    }

    /// Handles Space for Quick Look, Delete to remove, and Escape to clear
    /// selection or close Quick Look. Return true to consume the event.
    /// A card click makes the panel key. Unhandled key events from SwiftUI
    /// content reach this callback through the responder chain.
    var onKeyDown: ((NSEvent) -> Bool)?

    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: backingStoreType,
                   defer: flag)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        // ShelfView draws the corners, vibrancy, and border. The window shadow follows the content.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // ShelfWindowController animates showing and hiding the panel through NSAnimationContext.
        animationBehavior = .none
    }

    /// Borderless windows cannot become key by default. A click on a file
    /// must be able to make this panel key so Space, Delete, and Escape
    /// reach it. It can receive keyboard focus without becoming the main window.
    override var canBecomeKey: Bool { acceptsKeyboardFocus }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsTopEdgeOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// When a card or the background is clicked, SwiftUI can briefly focus
    /// the search field as the panel becomes key, causing the focus ring to flash.
    /// Let keyboard navigation or a click in the search area focus the field.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let field = responder as? NSTextField, field.isEditable,
           !Self.allowsTextFocus(field, for: NSApp.currentEvent) {
            return false
        }
        return super.makeFirstResponder(responder)
    }

    private static func allowsTextFocus(_ field: NSTextField, for event: NSEvent?) -> Bool {
        guard let event else { return true }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard event.window === field.window else { return false }
            // SwiftUI draws the magnifying glass beside the text field without a separate
            // NSView. Use the click location so that clicking the icon also focuses search.
            let point = field.convert(event.locationInWindow, from: nil)
            return field.bounds.insetBy(dx: -36, dy: -8).contains(point)
        default:
            return true
        }
    }


    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
