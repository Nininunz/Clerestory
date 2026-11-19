import XCTest
@testable import Clerestory

/// UX6 Empty Shelf Auto Hide Rule (EmptyShelfAutoHideRule, pure logic):
/// Trigger based on 'non-empty → empty' transition; manually summoned empty shelf (no transition) is
/// naturally exempt.
final class EmptyShelfAutoHideTests: XCTestCase {
    func testNonEmptyToEmpty_whileVisible_requestsHide() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true)) // Establish baseline
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testManuallySummonedEmptyShelf_neverHides() {
        // User manually summons empty shelf: initial assessment only establishes baseline, subsequent 0→0
        // changes do not trigger.
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testTransitionWhileHidden_doesNotFire_andKeepsBaselineFresh() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 3, isVisible: true, isEnabled: true))
        // Empty when hidden (e.g., menu bar cleared): no trigger (no shelf to hide), baseline updates
        // normally.
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: false, isEnabled: true))
        // After user summons empty shelf: 0→0 does not trigger.
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testSettingDisabled_neverFires() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: false))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: false))
    }

    func testPartialRemoval_doesNotFire() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 3, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true))
    }

    func testEmptyThenRefilledThenEmptied_firesOnEachTransition() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testUserRemovalKeepsShelfOpenButLaterDeliveryStillHides() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: false))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: false, isUserRemoval: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: false))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true,
                                     isDragInProgress: false))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                    isDragInProgress: false))
    }

    // MARK: - Task 2: Dragging in progress does not auto-hide (invariant gate)

    /// During dragging, items transition from >0 to 0 (e.g., another hand presses Delete to clear) →
    /// cannot hide,
    /// otherwise cross-app drag-and-drop suspended over shelf will fail (race condition suspected in real
    /// device verification).
    func testDragInProgress_transitionToEmpty_isSuppressed() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: true)) // Establish baseline
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
    }

    /// Suppressed hide does not re-trigger: baseline is already 0 at drag end, subsequent 0→0 changes do
    /// not trigger —
    /// empty shelf remains visible, user explicitly folds it (safe direction).
    func testDragInProgress_suppressedHide_isNotReplayedAfterDragEnds() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: true)) // Suppressed, baseline updated to 0
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: false)) // Drag ends, 0→0 no trigger
    }

    /// Gate only blocks 'dragging': After dragging ends, refill → then clear, trigger normally.
    func testAfterDragEnds_ruleFiresNormally() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true,
                                     isDragInProgress: false))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                    isDragInProgress: false))
    }
}
