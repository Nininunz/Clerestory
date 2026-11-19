import XCTest
@testable import Clerestory

final class IslandNoticePresentationTests: XCTestCase {
    private func context(_ surface: IslandSurfaceState = .collapsed, transitioning: Bool = false,
                         dragging: Bool = false, enabled: Bool = true) -> IslandNoticePresentation.Context {
        .init(isEnabled: enabled, surface: surface, isTransitioning: transitioning, isDragging: dragging)
    }

    func testNewNoticeWaitsForReleaseAndCompletedClose() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(revision: nil, context: context(.expanded)), .idle)
        XCTAssertEqual(state.update(revision: 1, context: context(.expanded, dragging: true)), .waiting)
        XCTAssertEqual(state.update(revision: 1, context: context(.expanded)), .waiting)
        XCTAssertEqual(state.update(revision: 1, context: context(transitioning: true)), .waiting)
        XCTAssertEqual(state.update(revision: 1, context: context()), .visible)
    }

    func testPinnedNoticeStillWaitsForReleaseAndOpeningAnimation() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(revision: 1, context: context(.pinned, dragging: true)), .waiting)
        XCTAssertEqual(state.update(revision: 1, context: context(.pinned, transitioning: true)), .waiting)
        XCTAssertEqual(state.update(revision: 1, context: context(.pinned)), .visible)
    }

    func testDisplayedNoticeFollowsReopeningButReplacementWaitsAgain() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(revision: 1, context: context()), .visible)
        XCTAssertEqual(state.update(revision: 1, context: context(.expanded, transitioning: true)), .visible)
        XCTAssertEqual(state.update(revision: 1, context: context(.expanded)), .visible)
        XCTAssertEqual(state.update(revision: 2, context: context(.expanded)), .waiting)
        XCTAssertEqual(state.update(revision: 2, context: context(.pinned)), .visible)
    }

    func testDragSuspensionRetainsDisplayedStateAndExpiryClearsIt() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(revision: 1, context: context()), .visible)
        XCTAssertEqual(state.update(revision: 1, context: context(.expanded, dragging: true)), .waiting)
        XCTAssertEqual(state.update(revision: 1, context: context(.expanded)), .visible)
        XCTAssertEqual(state.update(revision: nil, context: context(.expanded)), .idle)
        XCTAssertEqual(state.update(revision: 2, context: context(.expanded)), .waiting)
    }

    func testDisabledPresentationNeverHoldsOrDisplaysFeedback() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(revision: 1, context: context(.expanded, dragging: true, enabled: false)), .idle)
        XCTAssertEqual(state.update(revision: 1, context: context(.expanded)), .waiting)
        XCTAssertEqual(state.update(revision: 1, context: context(.hidden)), .visible)
    }
}
