import CoreGraphics
import XCTest
@testable import Clerestory

/// Edge trigger pure logic: trigger with condition (isInsideEdgeBand) and dwell tracking
/// (EdgeDwellTracker).
final class EdgeTriggerMonitorTests: XCTestCase {
    // MARK: - Current-gesture file drag gate

    func testFileDrag_staleFilePasteboardAtMouseDownDoesNotCount() {
        var tracker = DragPasteboardTracker()
        tracker.mouseDown(changeCount: 21)

        XCTAssertFalse(tracker.mouseDragged(changeCount: 21, hasEligibleContent: true))
        XCTAssertFalse(tracker.hasFreshContent)
    }

    func testFileDrag_freshFilePasteboardAfterMouseDownCounts() {
        var tracker = DragPasteboardTracker()
        tracker.mouseDown(changeCount: 21)

        XCTAssertTrue(tracker.mouseDragged(changeCount: 22, hasEligibleContent: true))
        XCTAssertTrue(tracker.mouseDragged(changeCount: 22, hasEligibleContent: true))
    }

    func testFileDrag_freshBrowserPayloadDoesNotCount() {
        var tracker = DragPasteboardTracker()
        tracker.mouseDown(changeCount: 21)

        XCTAssertFalse(tracker.mouseDragged(changeCount: 22, hasEligibleContent: false))
        XCTAssertFalse(tracker.hasFreshContent)
    }

    func testFileDrag_newGestureCannotReusePreviousFileDrag() {
        var tracker = DragPasteboardTracker()
        tracker.mouseDown(changeCount: 21)
        XCTAssertTrue(tracker.mouseDragged(changeCount: 22, hasEligibleContent: true))
        tracker.mouseUp()

        XCTAssertFalse(tracker.mouseDragged(changeCount: 22, hasEligibleContent: true))
        tracker.mouseDown(changeCount: 22)
        XCTAssertFalse(tracker.mouseDragged(changeCount: 22, hasEligibleContent: true))
    }

    // MARK: - Edge band

    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testBand_rightSide_insideAtAndBeyondBoundary() {
        // Right edge band [maxX-4, maxX], boundary values are included.
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 999.5, y: 400),
                                                          screenFrame: frame, side: .right, bandWidth: 4))
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 996, y: 400),
                                                          screenFrame: frame, side: .right, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 995.9, y: 400),
                                                           screenFrame: frame, side: .right, bandWidth: 4))
        // Left side is not within the right edge band.
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 0.5, y: 400),
                                                           screenFrame: frame, side: .right, bandWidth: 4))
    }

    func testBand_leftSide_insideAtAndBeyondBoundary() {
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 0.5, y: 400),
                                                          screenFrame: frame, side: .left, bandWidth: 4))
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 4, y: 400),
                                                          screenFrame: frame, side: .left, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 4.1, y: 400),
                                                           screenFrame: frame, side: .left, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 999, y: 400),
                                                           screenFrame: frame, side: .left, bandWidth: 4))
    }

    func testBand_pointOutsideScreen_neverCounts() {
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 1200, y: 400),
                                                           screenFrame: frame, side: .right, bandWidth: 4))
    }

    func testBand_customPosition_neverInside() {
        // S9: custom position has no attachment edge, no hit on any point of the screen.
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 999.5, y: 400),
                                                           screenFrame: frame, side: .custom, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 0.5, y: 400),
                                                           screenFrame: frame, side: .custom, bandWidth: 4))
    }

    func testBand_nonZeroOriginScreen() {
        // Secondary screen (origin is not 0): band condition is based on screen frame rather than fixed
        // coordinates.
        let secondScreen = CGRect(x: 1000, y: 0, width: 1440, height: 900)
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 2438, y: 100),
                                                          screenFrame: secondScreen, side: .right, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 1001, y: 100),
                                                           screenFrame: secondScreen, side: .right, bandWidth: 4))
    }

    // MARK: - Dwell tracker

    func testDwell_firesOnlyAfterThreshold() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0)) // Enter, start timing
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.2))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.49))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 0.5))
    }

    func testDwell_exactBoundaryCounts() {
        // Stay duration exactly equals the threshold (>= trigger) will activate.
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 1.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 1.5))
    }

    func testDwell_leavingBandRearmsTimer() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.3))
        XCTAssertFalse(tracker.addSample(isInside: false, at: 0.4)) // Leave: timing resets
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.5)) // Re-enter
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.9)) // 0.4s < 0.5s
        XCTAssertTrue(tracker.addSample(isInside: true, at: 1.0))
    }

    func testDwell_firesOncePerEntry_untilCursorLeaves() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 0.6))
        // Stay within the shelf without repeated triggering (prevent shelf from being hidden again if
        // cursor doesn't move after it's hidden).
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.7))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 5.0))
        // Trigger can only happen again after leaving and re-entering.
        XCTAssertFalse(tracker.addSample(isInside: false, at: 5.1))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 5.2))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 5.8))
    }

    func testDwell_resetRearms() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 0.6))
        tracker.reset()
        XCTAssertFalse(tracker.addSample(isInside: true, at: 1.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 1.5))
    }

    func testDwell_neverInside_neverFires() {
        var tracker = EdgeDwellTracker(dwellTime: 0.3)
        for index in 0..<20 {
            XCTAssertFalse(tracker.addSample(isInside: false, at: TimeInterval(index) * 0.1))
        }
    }
}
