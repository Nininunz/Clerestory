import AppKit
import XCTest
@testable import OpenYoink

/// UX1 Drag start state machine (DragGestureTracker) and pure logic unit test for auto-show session
/// (DragAutoShowSession).
final class DragStartMonitorTests: XCTestCase {
    func testTextApproachRequiresFreshDragPayloadAndCannotLeakIntoNextGesture() {
        for types in [[NSPasteboard.PasteboardType.string], [.string, .html, .rtf]] {
            var tracker = DragPasteboardTracker()
            let eligible = PasteboardTypes.hasShelfApproachContent(in: types)
            XCTAssertTrue(eligible)
            tracker.mouseDown(changeCount: 10)
            // Merely selecting text or moving a window leaves the prior pasteboard unchanged.
            XCTAssertFalse(tracker.mouseDragged(changeCount: 10, hasEligibleContent: eligible))
            XCTAssertTrue(tracker.mouseDragged(changeCount: 11, hasEligibleContent: eligible))
            XCTAssertTrue(tracker.mouseDragged(changeCount: 11, hasEligibleContent: eligible))
            tracker.mouseUp()
            tracker.mouseDown(changeCount: 11)
            XCTAssertFalse(tracker.mouseDragged(changeCount: 11, hasEligibleContent: eligible))
            // A fresh browser drag with a text fallback still cannot expand Shelf.
            XCTAssertFalse(tracker.mouseDragged(changeCount: 12, hasEligibleContent:
                PasteboardTypes.hasShelfApproachContent(in: [.URL, .string])))
        }
    }

    // MARK: - DragGestureTracker

    func testClickWithoutMovement_neverStartsDrag() {
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 103, y: 102))) // Displacement ~3.6 < 8
        XCTAssertEqual(tracker.phase, .pressing)
        // Normal click lift: Do not report drag end.
        XCTAssertFalse(tracker.mouseUp())
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testDrag_firesExactlyOnceWhenThresholdCrossed() {
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 105, y: 100))) // 5pt < 8
        // Confirmation is made once the threshold is reached (>= determination).
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 108, y: 100)))
        XCTAssertEqual(tracker.phase, .dragging)
        // After confirmation, further movement does not trigger repeated callbacks.
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 200, y: 200)))
        // Lift reports drag end, followed by reset.
        XCTAssertTrue(tracker.mouseUp())
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testDisplacementIsMeasuredFromOrigin_notPathLength() {
        // Small circle shaking: The path length has already exceeded the threshold, but the displacement
        // from the start has never reached → no trigger.
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 104, y: 100)))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 100, y: 104)))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 96, y: 100)))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 100, y: 96)))
        XCTAssertEqual(tracker.phase, .pressing)
    }

    func testDiagonalDisplacement_usesEuclideanDistance() {
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: .zero)
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 4, y: 4))) // ~5.66 < 8
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 6, y: 6)))  // ~8.49 ≥ 8
    }

    func testNewMouseDown_rearmsAfterMissedMouseUp() {
        // Lost lift event from previous round (defense): Reset session on new press to trigger again.
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: .zero)
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 20, y: 0)))
        tracker.mouseDown(at: CGPoint(x: 500, y: 500))
        XCTAssertEqual(tracker.phase, .pressing)
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 508, y: 500)))
        XCTAssertTrue(tracker.mouseUp())
    }

    func testMouseUpWithoutPress_isNoOp() {
        var tracker = DragGestureTracker(threshold: 8)
        XCTAssertFalse(tracker.mouseUp())
        XCTAssertEqual(tracker.phase, .idle)
    }

    // MARK: - DragAutoShowSession

    func testAutoShow_dragEndedWithoutImport_requestsHide() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        XCTAssertTrue(session.dragEnded())
        // Session resets after completion: Lifting again does not repeat the request.
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_importDuringDrag_keepsShelfByDefault() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_importDuringDrag_hidesWhenDisabled() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        XCTAssertTrue(session.dragEnded(keepShelfOpenAfterDrop: false))
    }

    func testAutoShow_mouseUpBeforeAcceptedDrop_keepsShelfWithoutTimeout() {
        var session = destinationSession()
        XCTAssertFalse(session.dragEnded())
        XCTAssertFalse(session.isDragging)
        XCTAssertTrue(session.shownAutomatically, "Retain ownership until the real destination callback")
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
        XCTAssertEqual(session, DragAutoShowSession())
    }

    func testAutoShow_mouseUpBeforeAcceptedDrop_hidesOnlyAfterImportWhenDisabled() {
        var session = destinationSession()
        XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: false))
        XCTAssertTrue(session.destinationEnded(sequenceNumber: 10, accepted: true))
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
    }

    func testAutoShow_destinationBeforeMouseUp_respectsBothSettings() {
        for keep in [true, false] {
            var session = destinationSession()
            XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
            XCTAssertTrue(session.isDragging, "Never hide while the global drag is active")
            XCTAssertEqual(session.dragEnded(keepShelfOpenAfterDrop: keep), !keep)
            XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: keep))
        }
    }

    func testAutoShow_rejectedCancelledOrDroppedElsewhere_hidesInEitherCallbackOrder() {
        for keep in [true, false] {
            var early = destinationSession()
            XCTAssertFalse(early.destinationEnded(sequenceNumber: 10, accepted: false))
            XCTAssertTrue(early.dragEnded(keepShelfOpenAfterDrop: keep))
            var late = destinationSession()
            XCTAssertFalse(late.dragEnded(keepShelfOpenAfterDrop: keep))
            XCTAssertTrue(late.destinationEnded(sequenceNumber: 10, accepted: false))
        }
    }

    func testAutoShow_duplicateDestinationEnd_doesNotOverwriteAcceptance() {
        var session = destinationSession()
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_oldCallbackCannotHideNewDrag() {
        var session = destinationSession()
        XCTAssertFalse(session.dragEnded())
        session.dragBegan()
        session.markShownAutomatically()
        session.destinationEntered(sequenceNumber: 11)
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
        XCTAssertTrue(session.isDragging)
        XCTAssertFalse(session.dragEnded())
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
        XCTAssertTrue(session.destinationEnded(sequenceNumber: 11, accepted: false))
    }

    func testAutoShow_explicitShowOrHideCancelsPendingAutomaticHide() {
        for accepted in [true, false] {
            var session = destinationSession()
            XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: false))
            session.cancelAutomaticHide()
            XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: accepted))
        }
    }

    func testAutoShow_manualPresentationDuringDragTakesOwnership() {
        var session = destinationSession()
        session.cancelAutomaticHide()
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
        XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: false))
    }

    func testAutoShow_unrelatedImportDoesNotTurnRejectedDestinationIntoSuccess() {
        var session = destinationSession()
        session.noteImport()
        XCTAssertFalse(session.dragEnded())
        XCTAssertTrue(session.destinationEnded(sequenceNumber: 10, accepted: false))
    }

    func testAutoShow_destinationOutsideTrackedDragDoesNotAcquireOwnership() {
        var session = DragAutoShowSession()
        session.destinationEntered(sequenceNumber: 10)
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
        XCTAssertEqual(session, DragAutoShowSession())
    }

    func testAutoShow_manuallyVisibleDestinationNeverHides() {
        for accepted in [true, false] {
            var session = DragAutoShowSession()
            session.dragBegan()
            session.destinationEntered(sequenceNumber: 10)
            XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: false))
            XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: accepted))
        }
    }

    func testAutoShow_repeatedEntryKeepsAcceptedOutcome() {
        var session = destinationSession()
        session.destinationEntered(sequenceNumber: 10)
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
        session.destinationEntered(sequenceNumber: 10)
        XCTAssertFalse(session.dragEnded())
    }

    private func destinationSession() -> DragAutoShowSession {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.destinationEntered(sequenceNumber: 10)
        return session
    }

    func testAutoShow_importDuringDrag_keepsShelfWhenConfigured() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: true))
    }

    func testAutoShow_markedOutsideDrag_isIgnored() {
        // Summoning in non-drag session (shortcut/clipping save) is an explicit intent and does not
        // participate in automatic retraction.
        var session = DragAutoShowSession()
        session.markShownAutomatically()
        XCTAssertFalse(session.shownAutomatically)
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_shelfVisibleBeforeDrag_staysUntouched() {
        // Shelf is already visible before drag (manual summon): Caller does not mark, drag end does not
        // retract.
        var session = DragAutoShowSession()
        session.dragBegan()
        // (No markShownAutomatically — corresponds to visibility guard in AppDelegate)
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_newDragResetsPreviousSession() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        // Reset all marks for new drag: Any automatic summon without import in this round will still be
        // retracted.
        session.dragBegan()
        session.markShownAutomatically()
        XCTAssertTrue(session.dragEnded())
    }
}
