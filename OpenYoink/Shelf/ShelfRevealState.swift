import Observation
import SwiftUI

/// Deformation state of the side shelf 'growing from the handle / retracting the handle' (issue #10).
///
/// The handle and shelf are two forms of the same element: When expanded, the panel window is directly
/// positioned to the target frame,
/// Only the glass surface inside SwiftUI grows elastically from the handle rectangle to the full panel,
/// and the content fades in afterward; when retracted,
/// It is the reverse. The window frame remains unchanged throughout, so the grid will not be reordered
/// during the animation, and drag-in/selection geometry
/// Is unaffected (same idea as Island 'fixed canvas + deformation').
///
/// Content maintains its final layout and is only 'unmasked' within the growing glass shape, without
/// scaling, and will not float outside the glass; springs do not rebound to prevent the glass from going
/// out of bounds and being clipped by the window with hard edges.
///
/// Driven by `ShelfWindowController`; `ShelfInteractiveGlassSurface` reads it. All state changes are
/// completed explicitly within `withAnimation`, and the view layer does not have implicit animations, so
/// 'no animation settling' can be achieved by directly assigning values.
@Observable
@MainActor
final class ShelfRevealState {
    /// The glass surface is in an expanded state (false = collapsed at the handle).
    private(set) var isGlassExpanded = true
    /// Panel content is visible (out of sync with the glass: fades in slightly later when expanded, fades
    /// out first when collapsed).
    private(set) var isContentVisible = true
    /// The rectangle of the collapsed glass surface (glass surface local coordinates, top-left origin);
    /// nil = only fade in and out.
    private(set) var collapsedRect: CGRect?
    /// During deformation when dragging files, the entire glass surface receives drag-and-drop (otherwise
    /// only the small opaque handle area would receive it, and dropping the file in the first few hundred
    /// milliseconds would fail).
    var capturesWholeSurface = false
    /// The height of the glass surface during visible height changes (top-aligned); nil = fills the
    /// window.
    ///
    /// When AppKit animates the window frame, SwiftUI content does not re-layout frame by frame: the
    /// content slides with the bottom edge of the window first, and then snaps back to its original
    /// position at the end of the animation (causing a jitter when the toolbar appears or disappears on
    /// selection or deselection). Therefore, height changes are now animated frame by frame by SwiftUI for
    /// both the glass and content height; the window only expands instantly when getting taller, and
    /// remains at its original height when getting shorter with the bottom transparent (see
    /// `ShelfWindowController.resizeClassicSurface`).
    private(set) var surfaceHeight: CGFloat?
    /// A non-animated copy of `surfaceHeight` for use by hit layers that require a stable geometry.
    ///
    /// Spring height animation causes SwiftUI layout to change continuously for about 0.32s: clicks within
    /// the animation window may be lost because the hit target moves between press and release
    /// (manifesting as 'you must wait after selecting a card before you can click the blank area to
    /// deselect it'). Hit layers reading this value won't follow the spring.
    private(set) var stableSurfaceHeight: CGFloat?

    static let resizeAnimation = Animation.spring(response: 0.32, dampingFraction: 1)

    static let expandGlassAnimation = Animation.spring(response: 0.40, dampingFraction: 0.9)
    static let expandContentAnimation = Animation.easeOut(duration: 0.24).delay(0.06)
    static let collapseGlassAnimation = Animation.spring(response: 0.30, dampingFraction: 1)
    static let collapseContentAnimation = Animation.easeIn(duration: 0.12)
    /// Hover preview: faster, almost no rebound, no dragging lag when the pointer glides over.
    static let quickExpandGlassAnimation = Animation.spring(response: 0.30, dampingFraction: 0.95)
    static let quickExpandContentAnimation = Animation.easeOut(duration: 0.16).delay(0.05)
    /// The duration required for the glass surface to visually stabilize (after which the window shadow is
    /// restored).
    static let expandSettleDuration: TimeInterval = 0.45
    static let quickExpandSettleDuration: TimeInterval = 0.34
    /// The duration for collapsing the glass surface (after which orderOut and the handle fade in).
    static let collapseDuration: TimeInterval = 0.3

    /// The actual area occupied by the glass surface (top-aligned, height may be less than the window
    /// canvas).
    func surfaceBounds(in canvas: CGRect) -> CGRect {
        guard let surfaceHeight else { return canvas }
        return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width,
                      height: max(1, min(surfaceHeight, canvas.height)))
    }

    /// Same as `surfaceBounds`, but ignores intermediate values during animation.
    func stableSurfaceBounds(in canvas: CGRect) -> CGRect {
        guard let stableSurfaceHeight else { return canvas }
        return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width,
                      height: max(1, min(stableSurfaceHeight, canvas.height)))
    }

    /// Lock the glass surface height without animation (called before the window expands, keeping the view
    /// unchanged).
    func pinSurfaceHeight(_ height: CGFloat?) {
        surfaceHeight = height
        stableSurfaceHeight = height
    }

    /// Use a spring animation to adjust the glass pane height to `height`, then call the callback.
    func animateSurfaceHeight(to height: CGFloat, completion: @escaping @MainActor () -> Void) {
        // Hit testing directly takes the target height: new areas are immediately clickable during the
        // animation, and old areas won't lose click events due to frame-by-frame shrinking.
        stableSurfaceHeight = height
        withAnimation(Self.resizeAnimation, completionCriteria: .logicallyComplete) {
            surfaceHeight = height
        } completion: {
            MainActor.assumeIsolated { completion() }
        }
    }

    /// Current glass rectangle: expanded to the full glass pane, collapsed to the pull ring rectangle.
    func glassRect(in bounds: CGRect) -> CGRect {
        guard !isGlassExpanded, let collapsedRect else { return bounds }
        return collapsedRect
    }

    /// Collapse to the pull ring without animation (called before panel orderFront).
    func prepareCollapsed(at rect: CGRect?) {
        collapsedRect = rect
        isGlassExpanded = false
        isContentVisible = false
    }

    /// Directly in the expanded state without animation (reduces dynamic effect, custom position, or
    /// non-animated display).
    func showImmediately() {
        isGlassExpanded = true
        isContentVisible = true
        capturesWholeSurface = false
        surfaceHeight = nil
        stableSurfaceHeight = nil
    }

    func expand(quick: Bool = false) {
        withAnimation(quick ? Self.quickExpandGlassAnimation : Self.expandGlassAnimation) {
            isGlassExpanded = true
        }
        withAnimation(quick ? Self.quickExpandContentAnimation : Self.expandContentAnimation) {
            isContentVisible = true
        }
    }

    func collapse(to rect: CGRect?) {
        withAnimation(Self.collapseContentAnimation) { isContentVisible = false }
        // The collapse target is updated in sync with content fading out (the pull ring may have moved due
        // to setting changes).
        collapsedRect = rect
        withAnimation(Self.collapseGlassAnimation) { isGlassExpanded = false }
    }
}

private struct ShelfRevealStateEnvironmentKey: EnvironmentKey {
    static var defaultValue: ShelfRevealState? { nil }
}

extension EnvironmentValues {
    /// Pull ring deformation state of the side shelf; Island / Preview is nil (always expanded).
    var shelfRevealState: ShelfRevealState? {
        get { self[ShelfRevealStateEnvironmentKey.self] }
        set { self[ShelfRevealStateEnvironmentKey.self] = newValue }
    }
}
