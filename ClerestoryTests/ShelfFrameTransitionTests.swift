import XCTest
@testable import Clerestory

final class ShelfFrameTransitionTests: XCTestCase {
    func testIslandCollapseDestinationSurvivesActivityDefaultsAndSpaceRefreshes() {
        let expanded = CGRect(x: 420, y: 420, width: 600, height: 480)
        let notch = CGRect(x: 570, y: 868, width: 300, height: 32)
        var transition = ShelfFrameTransitionState()
        _ = transition.request(expanded, currentFrame: expanded)
        XCTAssertTrue(transition.request(notch, currentFrame: expanded))
        // The host window stays expanded while SwiftUI folds its content.
        for _ in 0..<20 {
            XCTAssertFalse(transition.request(notch, currentFrame: expanded),
                           "Refreshes during a fold must not cancel or restart the pending resize")
        }
        XCTAssertEqual(transition.targetFrame, notch)
        XCTAssertFalse(transition.request(notch, currentFrame: notch))
    }

    func testReopeningIslandInvalidatesItsPendingNotchDestination() {
        let expanded = CGRect(x: 420, y: 420, width: 600, height: 480)
        let notch = CGRect(x: 570, y: 868, width: 300, height: 32)
        var transition = ShelfFrameTransitionState()
        XCTAssertTrue(transition.request(notch, currentFrame: expanded))
        XCTAssertTrue(transition.request(expanded, currentFrame: expanded))
        XCTAssertEqual(transition.targetFrame, expanded)
        XCTAssertFalse(transition.request(expanded, currentFrame: expanded))
    }

    func testRepeatedLayoutRequestDoesNotInterruptASlideInEitherDirection() {
        for direction in [CGFloat(-1), 1] {
            let target = CGRect(x: direction < 0 ? 0 : 1120,
                                y: 200, width: 320, height: 500)
            let hidden = target.offsetBy(dx: direction * target.width, dy: 0)
            var transition = ShelfFrameTransitionState()
            XCTAssertTrue(transition.request(target, currentFrame: hidden))

            let halfway = CGRect(x: (hidden.minX + target.minX) / 2,
                                  y: target.minY, width: target.width, height: target.height)
            XCTAssertFalse(transition.request(target, currentFrame: halfway),
                           "An unrelated notification must not replace the in-flight slide")
            XCTAssertFalse(transition.request(target, currentFrame: hidden),
                           "Duplicate observers must leave the same slide alone")
            XCTAssertEqual(transition.targetFrame, target)
        }
    }

    func testWidthAndHeightChangesRetargetOnceDuringOpening() {
        var transition = ShelfFrameTransitionState()
        let opening = CGRect(x: 1120, y: 200, width: 320, height: 500)
        let halfway = opening.offsetBy(dx: 160, dy: 0)
        _ = transition.request(opening, currentFrame: halfway)
        let resized = CGRect(x: 1040, y: 150, width: 400, height: 600)

        XCTAssertTrue(transition.request(resized, currentFrame: halfway))
        XCTAssertFalse(transition.request(resized, currentFrame: halfway))
        XCTAssertEqual(transition.targetFrame, resized)
    }

    func testHideThenReopenToSameFrameStartsANewTransition() {
        var transition = ShelfFrameTransitionState()
        let target = CGRect(x: 1120, y: 200, width: 320, height: 500)
        _ = transition.request(target, currentFrame: target)
        transition.reset()
        XCTAssertNil(transition.targetFrame)

        let hidden = target.offsetBy(dx: target.width, dy: 0)
        XCTAssertTrue(transition.request(target, currentFrame: hidden))
        XCTAssertFalse(transition.request(target, currentFrame: hidden))
    }

    func testScreenCorrectionReplacesPreviousDestination() {
        var transition = ShelfFrameTransitionState()
        let oldScreen = CGRect(x: 2560, y: 200, width: 320, height: 500)
        _ = transition.request(oldScreen, currentFrame: oldScreen)
        let newScreen = CGRect(x: 1120, y: 200, width: 320, height: 500)

        XCTAssertTrue(transition.request(newScreen, currentFrame: oldScreen))
        XCTAssertFalse(transition.request(newScreen, currentFrame: newScreen))
        XCTAssertEqual(transition.targetFrame, newScreen)
    }

    func testAlreadyPositionedPanelEstablishesDestinationWithoutMoving() {
        var transition = ShelfFrameTransitionState()
        let custom = CGRect(x: 300, y: 200, width: 320, height: 500)
        XCTAssertFalse(transition.request(custom, currentFrame: custom))
        XCTAssertEqual(transition.targetFrame, custom)
    }
}
