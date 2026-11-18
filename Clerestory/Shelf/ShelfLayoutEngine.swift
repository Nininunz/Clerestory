import Foundation

/// S9: Shelf layout pure logic (planned §2.2) — target screen determination, edge snapping frame, hidden
/// sliding-out direction, frame grabbing, custom frame validation and fallback. All are decoupled from
/// AppKit (NSScreen is first purely converted into `ScreenGeometry`), available for
/// `ShelfWindowController` to call and for direct unit testing.
///
/// Coordinate system: global screen coordinates (`NSEvent.mouseLocation` / `NSScreen.frame` are in the
/// same space, origin at the bottom-left corner of the main screen).
enum ShelfLayoutEngine {
    /// Screen geometry snapshot (pure value of NSScreen.frame / visibleFrame).
    struct ScreenGeometry: Equatable, Sendable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    /// Fallback size when the screen array is empty (macOS normally has at least one screen in operation,
    /// for pure protection).
    static let fallbackSize = CGSize(width: 320, height: 600)

    // MARK: - Compact height

    /// Grid column minimum width and spacing —— consistent with `ShelfView.columnWidth` / `.gridSpacing`
    /// (column count calculation must align with SwiftUI adaptive grid layout).
    static let gridColumnMinimum: CGFloat = 84
    static let gridSpacing: CGFloat = 12
    /// Horizontal/vertical fixed margins inside panel: window outer padding 8×2 + content padding 8×2.
    static let contentPadding: CGFloat = 32
    /// Horizontal width given up on content area when the control is collapsed. The collapse button has
    /// been moved to the title bar (issue #10: inner vertical handle breaks left-right symmetry), content
    /// side margins are now consistent, so it is 0.
    static let handleContentAllowance: CGFloat = 0
    /// Title bar block height (including VStack spacing).
    static let headerHeight: CGFloat = 28
    /// ActivityStrip spacing from itself to VStack. Only reserved when the status is visible to avoid
    /// overlapping cards.
    static let activityStripHeight: CGFloat = 86
    /// Selection action bar (36pt) plus up to 8pt surrounding VStack spacing
    /// (the expanded-stack presentation uses the larger spacing).
    static let quickActionBarHeight: CGFloat = 44
    /// Estimated height of two lines of title + one visible status card. After transfer, Ready card
    /// remains quiet; hosted copy, in-progress, and failed states require real text, not just badges or
    /// colors.
    static let cardRowHeight: CGFloat = 132
    /// Compact total height when shelf is empty (let `ShelfEmptyState` illustration be centered, do not
    /// stretch full height).
    static let emptyStateHeight: CGFloat = 200
    /// Height limit: 80% of visible screen height (overflow is scrolled by grid ScrollView).
    static let maximumHeightFraction: CGFloat = 0.8

    // MARK: - Target display selection

    /// Screen containing the mouse point; fallback to first screen (main screen) if no hit (mouse screen
    /// just removed, or coordinates are empty). Same rule as `ShelfWindowController.screen(containing:)`.
    /// Returns nil for empty array.
    static func targetScreen(mouseLocation: CGPoint, screens: [ScreenGeometry]) -> ScreenGeometry? {
        screens.first { $0.frame.contains(mouseLocation) } ?? screens.first
    }

    // MARK: - Edge layout

    /// UX5: Calculate grid column count from panel width (consistent with SwiftUI
    /// `adaptive(minimum:spacing:)` layout rules: n columns need n×min + (n-1)×spacing ≤ available width).
    /// Subtract fixed margin allowances for handle space (`handleContentAllowance`) — columnCount only
    /// serves compact height calculation for left/right anchors, handles are always visible; custom does
    /// not follow this path.
    static func columnCount(forPanelWidth width: CGFloat) -> Int {
        let gridWidth = width - contentPadding - handleContentAllowance
        return gridColumnCount(for: gridWidth)
    }

    /// Column count for a grid viewport that is already inside the padding.
    ///
    /// SwiftUI's `adaptive` grid re-derives this from its own width, and the
    /// scrolling container is a little narrower than the plain grid, so the
    /// same shelf switched from three columns to two once it started
    /// scrolling. Deriving the count here keeps both states identical.
    static func gridColumnCount(for gridWidth: CGFloat) -> Int {
        max(1, Int((gridWidth + gridSpacing) / (gridColumnMinimum + gridSpacing)))
    }

    /// Use the same conservative row allowance as the window's compact layout.
    /// The viewport width is already inside the shelf's padding and handle.
    static func gridFits(itemCount: Int, viewport: CGSize) -> Bool {
        guard itemCount > 0, viewport.width >= gridColumnMinimum, viewport.height > 0 else { return false }
        let columns = max(1, Int((viewport.width + gridSpacing) / (gridColumnMinimum + gridSpacing)))
        let rows = (itemCount + columns - 1) / columns
        let height = CGFloat(rows) * cardRowHeight + CGFloat(rows - 1) * gridSpacing
        return height <= viewport.height
    }

    /// UX5: Content fitting height —— title bar + inner padding + line height × line count + line spacing;
    /// upper limit is 80% of visible height (scroll overflow); empty shelf gives compact empty state
    /// height.
    static func contentHeight(itemCount: Int,
                              panelWidth: CGFloat,
                              visibleHeight: CGFloat,
                              hasActivity: Bool = false,
                              hasQuickActions: Bool = false,
                              hasSearchControls: Bool = false) -> CGFloat {
        let cap = visibleHeight * maximumHeightFraction
        let activityHeight = (hasActivity ? activityStripHeight : 0) + (hasSearchControls ? 60 : 0)
        guard itemCount > 0 else { return min(emptyStateHeight + activityHeight, cap) }
        let quickActionHeight = hasQuickActions ? quickActionBarHeight : 0
        let columns = columnCount(forPanelWidth: panelWidth)
        let rows = max(1, (itemCount + columns - 1) / columns)
        let gridHeight = CGFloat(rows) * cardRowHeight + CGFloat(rows - 1) * gridSpacing
        return min(headerHeight + gridHeight + contentPadding + activityHeight + quickActionHeight,
                   cap)
    }

    /// Edge adhesion frame: stick to the position corresponding edge. UX5 onwards height is determined by
    /// content (`contentHeight`); EdgeTab vertical position is determined by `edgeOffset` (0 = bottom of
    /// visible area, 1 = top), default 0.5 is the old vertical center. Custom has no concept of adhesion
    /// edge, returns nil (follows `validatedCustomFrame` path).
    static func edgeAttachedFrame(position: SettingsStore.ShelfPosition,
                                  width: CGFloat,
                                  height: CGFloat,
                                  visibleFrame: CGRect,
                                  edgeOffset: CGFloat = 0.5) -> CGRect? {
        let clampedOffset = min(max(edgeOffset, 0), 1)
        let travel = max(0, visibleFrame.height - height)
        let y = visibleFrame.minY + travel * clampedOffset
        switch position {
        case .left:
            return CGRect(x: visibleFrame.minX, y: y,
                          width: width, height: height)
        case .right:
            return CGRect(x: visibleFrame.maxX - width, y: y,
                          width: width, height: height)
        case .custom:
            return nil
        }
    }

    /// Hidden state frame: shift one panel width outside the left/right adhesion edge (slide out direction
    /// reverses with position); custom has no sliding direction, returns original position (show/hide only
    /// has transparency animation).
    static func hiddenFrame(for frame: CGRect, position: SettingsStore.ShelfPosition) -> CGRect {
        switch position {
        case .right: return frame.offsetBy(dx: frame.width, dy: 0)
        case .left: return frame.offsetBy(dx: -frame.width, dy: 0)
        case .custom: return frame
        }
    }

    // MARK: - Transition between the handle and panel

    /// Deformation width extending the handle rectangle beyond the screen edge: allows the outer corner of
    /// the folded glass to be cropped outside the window, matching the appearance of the pull tab with the
    /// outer corner hidden outside the screen edge.
    static let revealEdgeBleed: CGFloat = 12

    /// Start and end rectangles for expansion/collapse deformation: the position of the pull tab in the
    /// shelf's glass surface local coordinate system (top-left origin, consistent with SwiftUI).
    /// - surfaceFrame: the screen frame of the glass surface (window frame inset by `windowInset`).
    /// - tabFrame: the screen frame of the pull tab (`edgeTabFrame`).
    /// Vertically, it clamps into the glass surface (extending from the nearest side if the pull tab
    /// offset is not aligned with the panel). Horizontally, it adheres to the screen edge and extends
    /// outward by `revealEdgeBleed`. custom without edge attachment → nil (only fade in/out).
    static func revealOriginRect(surfaceFrame: CGRect,
                                 tabFrame: CGRect,
                                 position: SettingsStore.ShelfPosition,
                                 windowInset: CGFloat) -> CGRect? {
        guard surfaceFrame.width > 0, surfaceFrame.height > 0 else { return nil }
        let height = min(tabFrame.height, surfaceFrame.height)
        let top = min(max(surfaceFrame.maxY - tabFrame.maxY, 0), surfaceFrame.height - height)
        let width = min(tabFrame.width, surfaceFrame.width) + revealEdgeBleed
        switch position {
        case .right:
            let screenEdge = surfaceFrame.width + windowInset
            return CGRect(x: screenEdge - width + revealEdgeBleed, y: top,
                          width: width, height: height)
        case .left:
            return CGRect(x: -windowInset - revealEdgeBleed, y: top,
                          width: width, height: height)
        case .custom:
            return nil
        }
    }

    // MARK: - EdgeTab layout

    /// Normal exposure width of the pull tab (lateral dimension along the edge side).
    static let edgeTabWidth: CGFloat = 14
    /// Height of the pull tab (longitudinal dimension along the edge direction).
    static let edgeTabHeight: CGFloat = 84

    /// Keep at least 2pt around the glyph, independently of the tab's hit area.
    static func edgeTabIconFrame(in bounds: CGRect, size: Double) -> CGRect {
        let requested = SettingsStore.normalizedEdgeTabIconSize(size)
        let side = min(CGFloat(requested), max(0, min(bounds.width, bounds.height) - 4))
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                      width: side, height: side)
    }
    /// Emphasized state (widen and heighten for drag-and-drop hint / hover): edge side and center y remain
    /// unchanged.
    static let edgeTabEmphasizedWidth: CGFloat = 18
    static let edgeTabEmphasizedHeight: CGFloat = 92
    /// Edge switch detection band: when dragging the pull tab, if the cursor crosses the screen center
    /// line and is within this value of the opposite edge, it switches to the opposite side.
    static let edgeTabFlipDistance: CGFloat = 120

    /// Normal frame of the pull tab: adheres to the corresponding edge (same visibleFrame as shelf,
    /// avoiding Dock/menu bar occlusion area); `offset` (0 = center of pull tab adheres to bottom edge of
    /// visible area, 1 = top edge) maps vertical position and clamps. custom without edge attachment → nil
    /// (caller does not display the pull tab).
    ///
    /// The offset mapping is based on the center of the pull tab (not the bottom edge), and is the exact
    /// inverse function of `edgeTabOffset(forCenterY:)` — dragging ends and persisting the offset allows
    /// frame reconstruction without jumping.
    static func edgeTabFrame(position: SettingsStore.ShelfPosition,
                             offset: CGFloat,
                             visibleFrame: CGRect) -> CGRect? {
        let x: CGFloat
        switch position {
        case .left: x = visibleFrame.minX
        case .right: x = visibleFrame.maxX - edgeTabWidth
        case .custom: return nil
        }
        let height = min(edgeTabHeight, visibleFrame.height)
        let clampedOffset = min(max(offset, 0), 1)
        let travel = max(0, visibleFrame.height - height)
        let centerY = visibleFrame.minY + height / 2 + travel * clampedOffset
        return CGRect(x: x, y: centerY - height / 2,
                      width: edgeTabWidth, height: height)
    }

    /// Center y of the pull tab (driven by cursor during dragging) → offset (0 = bottom edge, 1 = top
    /// edge), clamped into [0,1]. If visible height is less than pull tab height, no vertical movement,
    /// revert to 0.5.
    static func edgeTabOffset(forCenterY centerY: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let height = min(edgeTabHeight, visibleFrame.height)
        let travel = visibleFrame.height - height
        guard travel > 0 else { return 0.5 }
        let raw = (centerY - visibleFrame.minY - height / 2) / travel
        return min(max(raw, 0), 1)
    }

    /// Emphasized state frame (slight enlargement for drag hint): edge side and center y remain unchanged,
    /// width expands inward, height symmetrically increases, and result is clamped into visibleFrame.
    /// custom without pull tab, return as is.
    static func edgeTabEmphasisFrame(from base: CGRect,
                                     position: SettingsStore.ShelfPosition,
                                     visibleFrame: CGRect) -> CGRect {
        let x: CGFloat
        switch position {
        case .left: x = visibleFrame.minX
        case .right: x = visibleFrame.maxX - edgeTabEmphasizedWidth
        case .custom: return base
        }
        let height = min(edgeTabEmphasizedHeight, visibleFrame.height)
        let frame = CGRect(x: x, y: base.midY - height / 2,
                           width: edgeTabEmphasizedWidth, height: height)
        return clamped(frame, into: visibleFrame)
    }

    /// Edge switch detection during dragging: if the cursor crosses the screen center line and enters the
    /// band area within `flipDistance` of the opposite edge → switch to the opposite side. Only approach
    /// the opposite edge but not cross the center line → no switch (narrow screen protection: band may
    /// overlap with center line). custom without edge attachment, never switch.
    static func shouldFlipSide(position: SettingsStore.ShelfPosition,
                               cursorLocation: CGPoint,
                               screenFrame: CGRect,
                               flipDistance: CGFloat = edgeTabFlipDistance) -> Bool {
        switch position {
        case .right:
            return cursorLocation.x < screenFrame.midX
                && cursorLocation.x - screenFrame.minX < flipDistance
        case .left:
            return cursorLocation.x > screenFrame.midX
                && screenFrame.maxX - cursorLocation.x < flipDistance
        case .custom:
            return false
        }
    }

    // MARK: - Inner-edge collapse handle

    /// Handle width (points). 10pt, attached to the shape edge side; paired with `handleContentAllowance`
    /// (content area starts from 12pt away from shape edge) to avoid overlap with the first column card —
    /// previously 14pt without spacing would overlap horizontally with the first column card by 6pt
    /// (discovered during real device testing).
    static let innerEdgeHandleWidth: CGFloat = 10

    /// Attachment side of the inner edge fold handle.
    enum InnerEdgeHandleSide: Sendable, Equatable {
        /// Handle on the panel left edge (right anchor shelf: handle faces the screen center, chevron
        /// points to the right edge).
        case leading
        /// Handle is on the right edge of the panel (left anchor shelf).
        case trailing
    }

    /// Handle side determination (pure function): The handle is always on the inner edge of the shelf
    /// facing the screen center ——
    /// Right anchor → left edge of the panel (leading); Left anchor → right edge (trailing).
    /// Custom free position without attached edge → nil (no handle displayed, title bar drag handle
    /// already covers).
    static func innerEdgeHandleSide(for position: SettingsStore.ShelfPosition) -> InnerEdgeHandleSide? {
        switch position {
        case .right: return .leading
        case .left: return .trailing
        case .custom: return nil
        }
    }

    // MARK: - Grabbing and Validation

    /// Grab any frame into visibleFrame: First shrink the frame to fit within the available area,
    /// Then move the origin to the nearest available position (minimum displacement). Return itself if
    /// already within the area.
    static func clamped(_ frame: CGRect, into visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, visibleFrame.width),
                          height: min(frame.height, visibleFrame.height))
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Screen with the largest intersection area with the frame. Determine intersection based on screen
    /// frame (not visibleFrame):
    /// User dragging to menu bar / Dock obscured area still considers the screen, and the frame is
    /// adjusted into visibleFrame during grabbing.
    /// Return nil if zero intersection area with all screens (including empty array).
    static func bestIntersectingScreen(for frame: CGRect, screens: [ScreenGeometry]) -> ScreenGeometry? {
        var best: ScreenGeometry?
        var bestArea: CGFloat = 0
        for screen in screens where screen.frame.intersects(frame) {
            let intersection = screen.frame.intersection(frame)
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    /// Validate persistent custom frame: Width is set as specified (width setting still applies in custom
    /// mode),
    /// Height and position take persistent values, and the frame is adjusted into the visibleFrame of the
    /// screen with the largest intersection.
    /// Return nil if completely outside all screens (screen has been removed), to be reverted by the
    /// caller to default position.
    static func validatedCustomFrame(_ persisted: CGRect,
                                     width: CGFloat,
                                     screens: [ScreenGeometry]) -> CGRect? {
        guard let screen = bestIntersectingScreen(for: persisted, screens: screens) else { return nil }
        let sized = CGRect(x: persisted.minX, y: persisted.minY, width: width, height: persisted.height)
        return clamped(sized, into: screen.visibleFrame)
    }

    /// Correction after Space switch: If the frame still intersects with a screen → grab back into that
    /// screen's visibleFrame
    /// (Normally, the grabbing result is itself, i.e., no-op); Return nil if completely outside all
    /// screens or screen array is empty,
    /// Caller will recalculate the targetFrame from scratch.
    ///
    /// Only correct, not reposition by mouse —— canJoinAllSpaces + stationary keeps the panel in its
    /// original
    /// global coordinates appearing on each Space, following the mouse would cause cross-screen drift.
    static func onscreenCorrection(for frame: CGRect, screens: [ScreenGeometry]) -> CGRect? {
        guard let screen = bestIntersectingScreen(for: frame, screens: screens) else { return nil }
        return clamped(frame, into: screen.visibleFrame)
    }

    // MARK: - Full Target Frame Decision

    /// Target frame decision shared by show / screen parameter changes / setting changes / item
    /// additions/removals:
    /// - Left/Right: Target screen (mouse screen, fallback to main screen if removed) visibleFrame edge
    /// adhesion,
    ///   UX5 and above height aligns with content (itemCount → row count → compact height, max 80% screen
    /// height),
    ///   EdgeTab and above vertical position based on edgeOffset (default 0.5 = vertical center);
    /// - Custom: Use persistent frame after validation (height takes persistent value, not
    /// content-dependent);
    ///   No persistent (first time selecting custom) or persistent frame outside all screens (screen
    /// removed) →
    ///   Target screen right edge default frame starting;
    /// - Screen array is empty (protection): Fallback to origin frame.
    static func targetFrame(position: SettingsStore.ShelfPosition,
                            width: CGFloat,
                            itemCount: Int,
                            hasActivity: Bool = false,
                            hasQuickActions: Bool = false,
                            hasSearchControls: Bool = false,
                            mouseLocation: CGPoint,
                            screens: [ScreenGeometry],
                            persistedCustomFrame: CGRect?,
                            edgeOffset: CGFloat = 0.5) -> CGRect {
        guard let screen = targetScreen(mouseLocation: mouseLocation, screens: screens) else {
            return CGRect(origin: .zero, size: fallbackSize)
        }
        switch position {
        case .left, .right:
            let height = contentHeight(itemCount: itemCount,
                                       panelWidth: width,
                                       visibleHeight: screen.visibleFrame.height,
                                       hasActivity: hasActivity,
                                       hasQuickActions: hasQuickActions,
                                       hasSearchControls: hasSearchControls)
            // Left/right must have edge frame (nil only returned for custom), fallback same as protection
            // branch.
            return edgeAttachedFrame(position: position, width: width, height: height,
                                     visibleFrame: screen.visibleFrame, edgeOffset: edgeOffset)
                ?? CGRect(origin: .zero, size: fallbackSize)
        case .custom:
            if let persistedCustomFrame,
               let valid = validatedCustomFrame(persistedCustomFrame, width: width, screens: screens) {
                return valid
            }
            // First time custom / persistent screen removed: Right edge default frame starting.
            return CGRect(x: screen.visibleFrame.maxX - width,
                          y: screen.visibleFrame.minY,
                          width: width,
                          height: screen.visibleFrame.height)
        }
    }
}
