import AppKit

/// EdgeTab pull ring window: a persistent small strip attached to the screen edge (shelf expands and the
/// panel is anchored at the bottom of the shelf).
///
/// Window behavior follows the same baseline as `ShelfPanel`: non-activating, borderless, floating, cross
/// Space, full-screen assist; transparent background, vibrancy/corner radius/outline are drawn by the
/// content layer (`EdgeTabView`). Show/hide and emphasis state animations are explicitly driven by
/// `EdgeTabController` using NSAnimationContext.
@MainActor
final class EdgeTabPanel: NSPanel {
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

        // Transparent background: inward rounded corners / vibrancy / outline are drawn by EdgeTabView.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Fade in/out and emphasis state frame animations are explicitly driven by EdgeTabController.
        animationBehavior = .none
    }
}
