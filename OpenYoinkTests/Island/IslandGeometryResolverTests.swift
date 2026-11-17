import AppKit
import XCTest
@testable import OpenYoink

final class IslandGeometryResolverTests: XCTestCase {
    func testDetachedPanelKeepsHoverAcrossGapWithoutGrowingNotchHitbox() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: -1512, y: 100, width: 1512, height: 982),
            visibleFrame: CGRect(x: -1512, y: 100, width: 1512, height: 944),
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: -1512, y: 1044, width: 645, height: 38),
            auxiliaryTopRightArea: CGRect(x: -645, y: 1044, width: 645, height: 38))
        let layout = IslandGeometryResolver.resolve(screen: screen)
        let keepAlive = layout.hoverKeepAliveFrame(panelFrame: layout.expandedFrame)
        let gap = CGPoint(x: layout.notchFrame.midX, y: layout.notchFrame.minY - 4)
        XCTAssertTrue(keepAlive.contains(gap))
        XCTAssertTrue(keepAlive.contains(CGPoint(x: layout.notchFrame.minX + 10, y: screen.frame.maxY)))
        XCTAssertTrue(keepAlive.contains(CGPoint(x: layout.expandedFrame.midX, y: layout.expandedFrame.midY)))
        XCTAssertFalse(layout.notchPointerFrame.contains(gap))
        XCTAssertFalse(keepAlive.contains(CGPoint(x: keepAlive.maxX + 1, y: gap.y)))
        XCTAssertFalse(keepAlive.contains(CGPoint(x: gap.x, y: keepAlive.minY - 1)))
    }

    @MainActor
    func testNotchCompanionCannotStealKeyboardFocus() {
        let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        XCTAssertTrue(panel.canBecomeKey)
        panel.acceptsKeyboardFocus = false
        XCTAssertFalse(panel.canBecomeKey)
        panel.close()
    }

    func testExtendedHeightKeepsTopAnchorAndRespectsScreenCap() {
        for height: CGFloat in [600, 982] {
            let screen = IslandGeometryResolver.ScreenGeometry(
                frame: CGRect(x: 0, y: 0, width: 1512, height: height),
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: height - 38),
                safeAreaTop: 38,
                auxiliaryTopLeftArea: CGRect(x: 0, y: height - 38, width: 645, height: 38),
                auxiliaryTopRightArea: CGRect(x: 867, y: height - 38, width: 645, height: 38))
            let regular = IslandGeometryResolver.resolve(screen: screen)
            let extended = IslandGeometryResolver.resolve(screen: screen, preferredExpandedHeight: 550)
            XCTAssertEqual(extended.expandedFrame.maxY, regular.expandedFrame.maxY)
            XCTAssertEqual(extended.expandedFrame.width, regular.expandedFrame.width)
            XCTAssertEqual(extended.notchFrame, regular.notchFrame)
            XCTAssertGreaterThan(extended.expandedFrame.height, regular.expandedFrame.height)
            XCTAssertLessThanOrEqual(extended.expandedFrame.height, (height - 38) * 0.6 + 1)
        }
    }

    func testPhysicalNotchUsesAuxiliaryGapAndWings() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 645, height: 38),
            auxiliaryTopRightArea: CGRect(x: 867, y: 944, width: 645, height: 38)
        )
        let layout = IslandGeometryResolver.resolve(screen: screen)
        XCTAssertTrue(layout.hasPhysicalNotch)
        XCTAssertEqual(layout.cameraHousingFrame,
                       CGRect(x: 645, y: 944, width: 222, height: 38))
        XCTAssertEqual(layout.notchFrame.width,
                       222 + IslandGeometryResolver.notchWingWidth * 2)
        XCTAssertEqual(layout.notchFrame.height,
                       38 + IslandGeometryResolver.physicalNotchClickExtension)
        XCTAssertEqual(layout.notchFrame.height, layout.cameraHousingFrame.height,
                       "The compact hit area must end with the visible notch surface")
        XCTAssertEqual(layout.notchFrame.midX, screen.frame.midX)
        XCTAssertEqual(layout.notchFrame.maxY, screen.frame.maxY)
        XCTAssertTrue(layout.notchPointerFrame.contains(
            CGPoint(x: layout.notchFrame.minX + 20, y: screen.frame.maxY)))
        XCTAssertFalse(layout.notchPointerFrame.contains(
            CGPoint(x: layout.notchFrame.minX + 20, y: layout.notchFrame.minY - 1)))
        XCTAssertEqual(layout.notchFrame.minY - layout.expandedFrame.maxY,
                       IslandGeometryResolver.expandedPanelGap)
        XCTAssertTrue(layout.notchIsVisible)
        XCTAssertFalse(layout.notchFrame.intersects(layout.expandedFrame))
    }

    func testPhysicalNotchWingsFollowReportedGapAcrossDisplaySizes() {
        let screenWidths: [CGFloat] = [1280, 1440, 1512, 1710, 1800, 2056, 2560]
        let housingWidths: [CGFloat] = [160, 184, 185.5, 200, 220, 222, 222.5, 240, 260, 300]
        for screenWidth in screenWidths {
            for housingWidth in housingWidths {
                for screenX in [CGFloat(0), -screenWidth] {
                    let sideWidth = (screenWidth - housingWidth) / 2
                    let screen = IslandGeometryResolver.ScreenGeometry(
                        frame: CGRect(x: screenX, y: 0, width: screenWidth, height: 1329),
                        visibleFrame: CGRect(x: screenX, y: 0, width: screenWidth, height: 1291),
                        safeAreaTop: 38,
                        auxiliaryTopLeftArea: CGRect(x: screenX, y: 1291,
                                                     width: sideWidth, height: 38),
                        auxiliaryTopRightArea: CGRect(x: screenX + sideWidth + housingWidth,
                                                      y: 1291, width: sideWidth, height: 38)
                    )
                    let layout = IslandGeometryResolver.resolve(screen: screen)
                    let leftWingEdge = layout.cameraHousingFrame.minX
                        - IslandGeometryResolver.notchWingWidth
                    let rightWingEdge = layout.cameraHousingFrame.maxX
                        + IslandGeometryResolver.notchWingWidth
                    XCTAssertTrue(layout.hasPhysicalNotch)
                    XCTAssertFalse(layout.expandedFrame.intersects(layout.notchFrame))
                    XCTAssertEqual(layout.expandedFrame.midX, layout.notchFrame.midX, accuracy: 0.5)
                    XCTAssertEqual(layout.notchFrame.minY - layout.expandedFrame.maxY,
                                   IslandGeometryResolver.expandedPanelGap, accuracy: 1)
                    XCTAssertEqual(layout.cameraHousingFrame.width, housingWidth)
                    XCTAssertLessThanOrEqual(layout.notchFrame.minX, leftWingEdge)
                    XCTAssertGreaterThan(layout.notchFrame.minX, leftWingEdge - 1)
                    XCTAssertGreaterThanOrEqual(layout.notchFrame.maxX, rightWingEdge)
                    XCTAssertLessThan(layout.notchFrame.maxX, rightWingEdge + 1)
                }
            }
        }
    }

    func testNoNotchUsesFloatingPillBelowVisibleTop() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            safeAreaTop: 0, auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        )
        let layout = IslandGeometryResolver.resolve(screen: screen)
        XCTAssertFalse(layout.hasPhysicalNotch)
        XCTAssertEqual(layout.notchFrame.size,
                       IslandGeometryResolver.floatingCompactSize)
        XCTAssertEqual(layout.notchFrame.maxY, screen.visibleFrame.maxY - 8)
        XCTAssertEqual(layout.expandedFrame.maxY, layout.notchFrame.maxY)
    }

    func testFloatingIdleDotSitsOnThePillsTopCentreAndRevealsFromScreenEdge() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            safeAreaTop: 0, auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        )
        let layout = IslandGeometryResolver.resolve(screen: screen)
        let dot = layout.floatingDotFrame
        XCTAssertEqual(dot.size, IslandGeometryResolver.floatingDotHitSize)
        XCTAssertEqual(dot.midX, layout.notchFrame.midX)
        XCTAssertEqual(dot.maxY, layout.notchFrame.maxY)
        // Most of the pill's area is free for the app underneath.
        XCTAssertLessThan(dot.width * dot.height,
                          layout.notchFrame.width * layout.notchFrame.height / 8)
        // The top pixel row above the pill reveals it; the middle of the
        // pill's former area does not.
        XCTAssertTrue(layout.floatingEdgeRevealFrame.contains(CGPoint(x: 640, y: 799)))
        // The pointer pinned to the top edge reports y == screen maxY.
        XCTAssertTrue(layout.floatingEdgeRevealFrame.contains(CGPoint(x: 640, y: 800)))
        XCTAssertFalse(layout.floatingEdgeRevealFrame.contains(CGPoint(x: 640, y: layout.notchFrame.midY)))
        XCTAssertFalse(layout.floatingEdgeRevealFrame.contains(CGPoint(x: 100, y: 799)))
        XCTAssertTrue(layout.floatingKeepRevealedFrame.contains(layout.notchFrame.center))
        XCTAssertTrue(layout.floatingKeepRevealedFrame.contains(CGPoint(x: 640, y: 799)))
    }

    func testFloatingPresentationOnlyShrinksAnIdleCollapsedFloatingIsland() {
        func resolve(_ style: IslandFloatingIdleStyle, notch: Bool = false, expanded: Bool = false,
                     urgent: Bool = false, revealed: Bool = false) -> IslandFloatingPresentation {
            .resolve(style: style, hasPhysicalNotch: notch, isExpanded: expanded,
                     hasUrgentActivity: urgent, isRevealed: revealed)
        }
        XCTAssertEqual(resolve(.capsule), .capsule)
        XCTAssertEqual(resolve(.dot), .dot)
        XCTAssertEqual(resolve(.hidden), .hidden)
        XCTAssertEqual(resolve(.dot, notch: true), .capsule)
        XCTAssertEqual(resolve(.hidden, expanded: true), .capsule)
        XCTAssertEqual(resolve(.hidden, urgent: true), .capsule)
        XCTAssertEqual(resolve(.dot, revealed: true), .capsule)
    }

    func testHalfPointNotchAreasDoNotCreateAnUnreachableWindowDestination() {
        for screenX in [CGFloat(0), CGFloat(-1512)] {
            let screen = IslandGeometryResolver.ScreenGeometry(
                frame: CGRect(x: screenX, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: screenX, y: 0, width: 1512, height: 949),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                auxiliaryTopRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
            )
            let layout = IslandGeometryResolver.resolve(screen: screen)
            XCTAssertEqual(layout.cameraHousingFrame.minX, screenX + 663.5)
            XCTAssertEqual(layout.notchFrame, layout.notchFrame.integral)
            XCTAssertEqual(layout.expandedFrame, layout.expandedFrame.integral)
            XCTAssertEqual(layout.notchFrame.midX, layout.expandedFrame.midX)
            XCTAssertEqual(layout.notchFrame.maxY, screen.frame.maxY)
            var transition = ShelfFrameTransitionState()
            XCTAssertFalse(transition.request(layout.notchFrame,
                                               currentFrame: layout.notchFrame.integral))
            transition.reset()
            XCTAssertFalse(transition.request(layout.notchFrame,
                                               currentFrame: layout.notchFrame.integral))
        }
    }

    func testNotchHousingUsesAuxiliaryWidthsAcrossCoordinateSpaces() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: -1512, y: 0, width: 1512, height: 949),
            safeAreaTop: 32,
            // Some screen snapshots expose these rects in screen-local coordinates.
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 848, y: 950, width: 664, height: 32)
        )

        let layout = IslandGeometryResolver.resolve(screen: screen)

        XCTAssertTrue(layout.hasPhysicalNotch)
        XCTAssertEqual(layout.cameraHousingFrame,
                       CGRect(x: -849, y: 950, width: 185, height: 32))
        XCTAssertEqual(layout.notchFrame.midX, layout.cameraHousingFrame.midX)
        XCTAssertEqual(layout.expandedFrame.midX, layout.cameraHousingFrame.midX)
        XCTAssertEqual(layout.notchFrame.height,
                       32 + IslandGeometryResolver.physicalNotchClickExtension)
        XCTAssertEqual(layout.notchFrame.maxY, screen.frame.maxY)
    }

    func testNegativeCoordinateExternalScreenStaysOnThatScreen() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: -2560, y: -200, width: 2560, height: 1440),
            visibleFrame: CGRect(x: -2560, y: -200, width: 2560, height: 1415),
            safeAreaTop: 0, auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        )
        let layout = IslandGeometryResolver.resolve(screen: screen)
        XCTAssertEqual(layout.notchFrame.midX, screen.visibleFrame.midX)
        XCTAssertTrue(screen.frame.contains(layout.activationFrame.center))
        XCTAssertLessThanOrEqual(layout.expandedFrame.height,
                                 screen.visibleFrame.height * 0.6)
    }

    func testNarrowDisplayClampsExpandedWidthToAvailableSpace() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 340, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 340, height: 775),
            safeAreaTop: 0, auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        )
        let layout = IslandGeometryResolver.resolve(screen: screen)
        XCTAssertEqual(layout.expandedFrame.width, 360)
        XCTAssertEqual(layout.expandedFrame.midX, screen.visibleFrame.midX)
    }

    func testDisplayRemovalFallsBackToRemainingScreen() throws {
        let main = geometry(x: 0, width: 1512, height: 982)
        let removed = geometry(x: 1512, width: 1920, height: 1080)
        let point = CGPoint(x: removed.frame.midX, y: removed.frame.midY)
        XCTAssertEqual(try XCTUnwrap(IslandGeometryResolver.resolve(
            at: point, screens: [main, removed]
        )).notchFrame.midX, removed.visibleFrame.midX)
        XCTAssertEqual(try XCTUnwrap(IslandGeometryResolver.resolve(
            at: point, screens: [main]
        )).notchFrame.midX, main.visibleFrame.midX)
    }

    func testResolutionChangeRecomputesFrames() throws {
        let before = geometry(x: 0, width: 1512, height: 982)
        let after = geometry(x: 0, width: 1280, height: 800)
        let point = CGPoint(x: 600, y: 700)
        let first = try XCTUnwrap(IslandGeometryResolver.resolve(at: point,
                                                                  screens: [before]))
        let second = try XCTUnwrap(IslandGeometryResolver.resolve(at: point,
                                                                   screens: [after]))
        XCTAssertNotEqual(first.notchFrame, second.notchFrame)
        XCTAssertLessThanOrEqual(second.expandedFrame.height,
                                 after.visibleFrame.height * 0.6)
    }

    func testFileDragOnNotchIslandDoesNotNeedTopApproachSetting() {
        let notch = CGRect(x: 100, y: 900, width: 300, height: 38)
        let topZone = CGRect(x: 50, y: 850, width: 400, height: 88)
        XCTAssertTrue(IslandGeometryResolver.acceptsFileDrag(
            at: CGPoint(x: 120, y: 920), notchPointerFrame: notch,
            activationFrame: topZone, topApproachEnabled: false))
        XCTAssertFalse(IslandGeometryResolver.acceptsFileDrag(
            at: CGPoint(x: 80, y: 900), notchPointerFrame: notch,
            activationFrame: topZone, topApproachEnabled: false))
        XCTAssertTrue(IslandGeometryResolver.acceptsFileDrag(
            at: CGPoint(x: 80, y: 900), notchPointerFrame: notch,
            activationFrame: topZone, topApproachEnabled: true))
    }

    func testFileDragActivatesOnlyInsideTopZone() {
        let screen = geometry(x: 0, width: 1512, height: 982)
        let layout = IslandGeometryResolver.resolve(screen: screen)
        XCTAssertEqual(layout.activationFrame.width, layout.notchFrame.width + 64)
        XCTAssertEqual(layout.activationFrame.minY, layout.notchFrame.minY - 64)
        XCTAssertEqual(layout.activationFrame.maxY, screen.frame.maxY + 1)
        XCTAssertTrue(layout.activationFrame.contains(layout.notchFrame))
        XCTAssertFalse(layout.activationFrame.contains(layout.expandedFrame))
        let extended = IslandGeometryResolver.resolve(screen: screen, preferredExpandedHeight: 600)
        XCTAssertEqual(extended.activationFrame, layout.activationFrame)
        // Probe the full approach area, including its lower corners well
        // outside the notch notch, rather than testing only the top edge.
        for x in [layout.activationFrame.minX + 1, layout.activationFrame.midX, layout.activationFrame.maxX - 1] {
            for y in [layout.activationFrame.minY + 1, layout.activationFrame.midY, layout.activationFrame.maxY - 1] {
                XCTAssertTrue(IslandGeometryResolver.acceptsFileDrag(
                    at: CGPoint(x: x, y: y), notchPointerFrame: .null,
                    activationFrame: layout.activationFrame, topApproachEnabled: true))
            }
        }
        XCTAssertFalse(IslandGeometryResolver.acceptsFileDrag(
            at: CGPoint(x: layout.activationFrame.midX, y: layout.activationFrame.minY - 1),
            notchPointerFrame: .null, activationFrame: layout.activationFrame, topApproachEnabled: true))

        let approachPoint = CGPoint(x: layout.activationFrame.minX - 1,
                                    y: screen.frame.maxY - 120)
        XCTAssertFalse(IslandGeometryResolver.acceptsFileDrag(
            at: approachPoint, notchPointerFrame: .null,
            activationFrame: layout.activationFrame, topApproachEnabled: true))
        XCTAssertTrue(IslandGeometryResolver.acceptsFileDrag(
            at: CGPoint(x: layout.activationFrame.midX, y: screen.frame.maxY),
            notchPointerFrame: .null, activationFrame: layout.activationFrame,
            topApproachEnabled: true))
        XCTAssertFalse(IslandGeometryResolver.acceptsFileDrag(
            at: approachPoint, notchPointerFrame: .null,
            activationFrame: layout.activationFrame, topApproachEnabled: false))
    }

    func testNotchVisibilityNeverChangesExpandedPlacementOrDragZone() {
        for hasNotch in [true, false] {
            let screen = IslandGeometryResolver.ScreenGeometry(
                frame: CGRect(x: -1512, y: 100, width: 1512, height: 982),
                visibleFrame: CGRect(x: -1512, y: 100, width: 1512, height: 944),
                safeAreaTop: hasNotch ? 38 : 0,
                auxiliaryTopLeftArea: hasNotch ? CGRect(x: 0, y: 0, width: 645, height: 38) : .zero,
                auxiliaryTopRightArea: hasNotch ? CGRect(x: 0, y: 0, width: 645, height: 38) : .zero)
            let shown = IslandGeometryResolver.resolve(screen: screen, showNotch: true)
            let hidden = IslandGeometryResolver.resolve(screen: screen, showNotch: false)
            XCTAssertEqual(shown.notchIsVisible, hasNotch)
            XCTAssertFalse(hidden.notchIsVisible)
            XCTAssertEqual(shown.expandedFrame, hidden.expandedFrame)
            XCTAssertEqual(shown.activationFrame, hidden.activationFrame)
            XCTAssertEqual(hidden.expandedFrame.maxY, screen.visibleFrame.maxY - 8)
            XCTAssertTrue(hidden.pointerTriggerFrame.contains(CGPoint(x: hidden.expandedFrame.midX, y: screen.frame.maxY)))
            XCTAssertFalse(hidden.pointerTriggerFrame.contains(CGPoint(x: hidden.expandedFrame.midX, y: screen.frame.maxY - 5)))
            XCTAssertFalse(hidden.pointerTriggerFrame.contains(CGPoint(x: screen.frame.minX + 10, y: screen.frame.maxY)))
            XCTAssertEqual(hidden.closedNoticeAnchor.minY, hidden.expandedFrame.maxY + 8)
            if hasNotch { XCTAssertEqual(shown.closedNoticeAnchor, shown.notchFrame) }
            let gap = CGPoint(x: hidden.expandedFrame.midX, y: hidden.expandedFrame.maxY + 4)
            XCTAssertTrue(hidden.hoverKeepAliveFrame(panelFrame: hidden.expandedFrame).contains(gap))
            XCTAssertFalse(hidden.pointerTriggerFrame.contains(gap))
        }
    }

    private func geometry(x: CGFloat, width: CGFloat,
                          height: CGFloat) -> IslandGeometryResolver.ScreenGeometry {
        .init(frame: CGRect(x: x, y: 0, width: width, height: height),
              visibleFrame: CGRect(x: x, y: 0, width: width, height: height - 25),
              safeAreaTop: 0,
              auxiliaryTopLeftArea: .zero,
              auxiliaryTopRightArea: .zero)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
