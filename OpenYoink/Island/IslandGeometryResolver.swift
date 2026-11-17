import AppKit

/// What the floating (no-notch) Island shows while it is collapsed and nothing
/// urgent is happening. A physical notch is always drawn as is: it never
/// covers usable screen space.
enum IslandFloatingIdleStyle: String, CaseIterable, Sendable {
    /// The full pill, always visible (the pre-1.8.9 behaviour).
    case capsule
    /// A small dot; the pill comes back while the pointer is on it.
    case dot
    /// Nothing at all until the pointer touches the top edge of the screen.
    case hidden
}

enum IslandFloatingPresentation: Equatable, Sendable {
    case capsule
    case dot
    case hidden

    /// Pure decision so the reveal rules are unit-testable.
    static func resolve(style: IslandFloatingIdleStyle,
                        hasPhysicalNotch: Bool,
                        isExpanded: Bool,
                        hasUrgentActivity: Bool,
                        isRevealed: Bool) -> Self {
        guard !hasPhysicalNotch, !isExpanded, !hasUrgentActivity, !isRevealed else {
            return .capsule
        }
        switch style {
        case .capsule: return .capsule
        case .dot: return .dot
        case .hidden: return .hidden
        }
    }
}

enum IslandGeometryResolver {
    static let expandedPanelGap: CGFloat = 8
    static func acceptsFileDrag(at point: CGPoint, compactPointerFrame: CGRect,
                                activationFrame: CGRect, topApproachEnabled: Bool) -> Bool {
        compactPointerFrame.contains(point)
            || (topApproachEnabled && activationFrame.contains(point))
    }
    struct ScreenGeometry: Equatable, Sendable {
        var frame: CGRect
        var visibleFrame: CGRect
        var safeAreaTop: CGFloat
        var auxiliaryTopLeftArea: CGRect
        var auxiliaryTopRightArea: CGRect
    }

    struct Layout: Equatable, Sendable {
        var hasPhysicalNotch: Bool
        var cameraHousingFrame: CGRect
        var compactFrame: CGRect
        var expandedFrame: CGRect
        var activationFrame: CGRect
        /// The full screen, so the floating Island can reveal from its top edge.
        var screenFrame: CGRect = .zero

        var showCompactIsland = true
        var compactIsVisible: Bool { hasPhysicalNotch && showCompactIsland }

        /// Hardware changes placement, never the expanded panel's presentation.
        var pointerTriggerFrame: CGRect {
            if compactIsVisible { return compactPointerFrame }
            let width = hasPhysicalNotch ? cameraHousingFrame.width + 32 : 80
            return CGRect(x: expandedFrame.midX - width / 2,
                          y: screenFrame.maxY - 4, width: width, height: 5)
        }

        var closedNoticeAnchor: CGRect {
            if compactIsVisible { return compactFrame }
            return CGRect(x: expandedFrame.midX, y: expandedFrame.maxY + IslandGeometryResolver.expandedPanelGap,
                          width: 0, height: 0)
        }

        /// Hover-only bridge; no native input window intercepts clicks in the gap.
        func hoverKeepAliveFrame(panelFrame: CGRect) -> CGRect {
            panelFrame.insetBy(dx: -8, dy: -8).union(pointerTriggerFrame)
        }

        /// Window frame for the idle dot: centred on the pill's top edge. The
        /// hit area is larger than the drawn dot so it stays easy to point at.
        var floatingDotFrame: CGRect {
            CGRect(x: compactFrame.midX - IslandGeometryResolver.floatingDotHitSize.width / 2,
                   y: compactFrame.maxY - IslandGeometryResolver.floatingDotHitSize.height,
                   width: IslandGeometryResolver.floatingDotHitSize.width,
                   height: IslandGeometryResolver.floatingDotHitSize.height).integral
        }

        /// Touching the very top of the screen above the pill reveals it.
        /// The pointer pinned to the top edge reports `y == screenFrame.maxY`,
        /// which `CGRect.contains` excludes, so the zone reaches past it.
        var floatingEdgeRevealFrame: CGRect {
            CGRect(x: compactFrame.minX - 24,
                   y: screenFrame.maxY - 4,
                   width: compactFrame.width + 48,
                   height: 8)
        }

        /// Once revealed, the pill stays while the pointer is on it or in the
        /// strip between it and the top of the screen.
        var floatingKeepRevealedFrame: CGRect {
            CGRect(x: compactFrame.minX - 12,
                   y: compactFrame.minY - 10,
                   width: compactFrame.width + 24,
                   height: max(screenFrame.maxY, compactFrame.maxY) - compactFrame.minY + 10)
        }

        var cameraHousingWidth: CGFloat { cameraHousingFrame.width }
        var topInset: CGFloat { cameraHousingFrame.height }

        /// CGRect.contains excludes maxY, while the pointer can report the
        /// screen's exact top coordinate when pressed against the menu bar.
        var compactPointerFrame: CGRect {
            guard hasPhysicalNotch else { return compactFrame }
            return CGRect(x: compactFrame.minX, y: compactFrame.minY,
                          width: compactFrame.width, height: compactFrame.height + 1)
        }
    }

    /// Keep the visual wings and their hit targets narrow: these overlays share
    /// the menu-bar row with status items, which macOS does not move aside for us.
    static let compactWingWidth: CGFloat = 40
    /// Match the compact panel to the visible surface. A transparent strip
    /// below the notch would intercept clicks meant for the app underneath.
    static let physicalNotchClickExtension: CGFloat = 0
    static let floatingCompactSize = CGSize(width: 224, height: 38)
    static let floatingDotHitSize = CGSize(width: 44, height: 22)
    static let floatingDotDiameter: CGFloat = 10
    static let maximumExpandedWidth: CGFloat = 492
    static let minimumExpandedWidth: CGFloat = 360
    static let expandedPreferredHeight: CGFloat = 330
    static let maximumExpandedHeightFraction: CGFloat = 0.6

    /// Chooses the screen under the pointer/drag and falls back to the first
    /// remaining screen after a display is unplugged. Keeping this selection
    /// pure makes negative-coordinate and hot-unplug behavior deterministic.
    static func resolve(at point: CGPoint, screens: [ScreenGeometry]) -> Layout? {
        guard let screen = screens.first(where: { $0.frame.contains(point) })
                ?? screens.first else { return nil }
        return resolve(screen: screen)
    }

    static func resolve(screen: ScreenGeometry, preferredExpandedHeight: CGFloat = expandedPreferredHeight, showCompactIsland: Bool = true) -> Layout {
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        // auxiliary areas have been observed in both screen-relative and global
        // coordinates. Their widths are stable in either representation, while
        // subtracting minX/maxX can place the housing on the wrong display.
        let notchWidth = max(0, screen.frame.width - left.width - right.width)
        let notchHeight = max(0, screen.safeAreaTop)
        let hasNotch = notchHeight >= 20
            && !left.isEmpty
            && !right.isEmpty
            && notchWidth >= 40

        let housing: CGRect
        let compact: CGRect
        let topAnchor: CGFloat
        let horizontalAnchor: CGFloat
        if hasNotch {
            housing = CGRect(x: screen.frame.minX + left.width,
                             y: screen.frame.maxY - notchHeight,
                             width: notchWidth,
                             height: notchHeight)
            let width = notchWidth + compactWingWidth * 2
            let compactHeight = notchHeight + physicalNotchClickExtension
            compact = CGRect(x: housing.midX - width / 2,
                             y: screen.frame.maxY - compactHeight,
                             width: width,
                             height: compactHeight)
            topAnchor = min(housing.minY, screen.visibleFrame.maxY) - expandedPanelGap
            horizontalAnchor = housing.midX
        } else {
            housing = .zero
            compact = CGRect(x: screen.visibleFrame.midX - floatingCompactSize.width / 2,
                             y: screen.visibleFrame.maxY - floatingCompactSize.height - 8,
                             width: floatingCompactSize.width,
                             height: floatingCompactSize.height)
            topAnchor = compact.maxY
            horizontalAnchor = screen.visibleFrame.midX
        }

        let availableWidth = max(240, screen.visibleFrame.width - 24)
        let expandedWidth = min(maximumExpandedWidth,
                                max(minimumExpandedWidth,
                                    min(availableWidth, maximumExpandedWidth)))
        let heightCap = max(260, screen.visibleFrame.height * maximumExpandedHeightFraction)
        let expandedHeight = min(max(expandedPreferredHeight, preferredExpandedHeight), heightCap)
        let expanded = CGRect(x: horizontalAnchor - expandedWidth / 2,
                              y: topAnchor - expandedHeight,
                              width: expandedWidth,
                              height: expandedHeight)
        // Approaching the compact Island should reveal Shelf; the expanded
        // module's size must not turn a large part of the desktop into a trigger.
        let activationLeft = max(screen.frame.minX, compact.minX - 32)
        let activationRight = min(screen.frame.maxX, compact.maxX + 32)
        let activationBottom = max(screen.frame.minY, compact.minY - 64)
        let activation = CGRect(x: activationLeft, y: activationBottom,
                                width: activationRight - activationLeft,
                                height: screen.frame.maxY + 1 - activationBottom)
        return Layout(hasPhysicalNotch: hasNotch,
                      cameraHousingFrame: housing,
                      // NSPanel rounds half-point window origins to whole
                      // points, even on Retina displays. Auxiliary notch
                      // areas commonly end in .5; return integral enclosing
                      // frames so layout comparisons use realizable windows.
                      // Keep the hardware housing itself at its real position.
                      compactFrame: compact.integral,
                      expandedFrame: expanded.integral,
                      activationFrame: activation.integral,
                      screenFrame: screen.frame,
                      showCompactIsland: showCompactIsland)
    }
}
