import XCTest
@testable import Clerestory

final class IslandNoticePresentationTests: XCTestCase {
    private func context(_ surface: IslandSurfaceState = .collapsed, transitioning: Bool = false,
                         dragging: Bool = false, enabled: Bool = true,
                         shown: IslandModuleID? = nil) -> IslandNoticePresentation.Context {
        .init(isEnabled: enabled, surface: surface, isTransitioning: transitioning, isDragging: dragging,
              shownModule: shown)
    }

    func testNewNoticeWaitsForReleaseAndCompletedClose() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(noticeID: nil, context: context(.expanded)), .idle)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.expanded, dragging: true)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.expanded)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, context: context(transitioning: true)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, context: context()), .visible)
    }

    func testPinnedNoticeStillWaitsForReleaseAndOpeningAnimation() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(noticeID: 1, context: context(.pinned, dragging: true)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.pinned, transitioning: true)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.pinned)), .visible)
    }

    func testDisplayedNoticeFollowsReopeningButReplacementWaitsAgain() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(noticeID: 1, context: context()), .visible)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.expanded, transitioning: true)), .visible)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.expanded)), .visible)
        XCTAssertEqual(state.update(noticeID: 2, context: context(.expanded)), .waiting)
        XCTAssertEqual(state.update(noticeID: 2, context: context(.pinned)), .visible)
    }

    func testDragSuspensionRetainsDisplayedStateAndExpiryClearsIt() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(noticeID: 1, context: context()), .visible)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.expanded, dragging: true)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.expanded)), .visible)
        XCTAssertEqual(state.update(noticeID: nil, context: context(.expanded)), .idle)
        XCTAssertEqual(state.update(noticeID: 2, context: context(.expanded)), .waiting)
    }

    func testDisabledPresentationNeverHoldsOrDisplaysFeedback() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(noticeID: 1, context: context(.expanded, dragging: true, enabled: false)), .idle)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.expanded)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, context: context(.hidden)), .visible)
    }

    func testShownModuleNoticeIsImmediateInUnpinnedPanel() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(noticeID: 1, from: .clipboard, context: context(.expanded, shown: .clipboard)), .visible)
        XCTAssertEqual(state.update(noticeID: 1, from: .clipboard, context: context(.expanded, shown: .shelf)), .visible,
                       "Switching pages keeps a notice that has appeared")
        XCTAssertEqual(state.update(noticeID: 2, from: .clipboard, context: context(.expanded, transitioning: true,
                                                                                    shown: .clipboard)), .waiting,
                       "The opening animation still comes first")
        XCTAssertEqual(state.update(noticeID: 2, from: .clipboard, context: context(.expanded, shown: .clipboard)), .visible)
    }

    func testOtherModuleNoticeStillWaitsForUnpinnedPanelToClose() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(noticeID: 1, from: .battery, context: context(.expanded, shown: .shelf)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, from: .battery, context: context(.expanded, shown: .timer)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, from: .battery, context: context(transitioning: true)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, from: .battery, context: context()), .visible)
    }

    func testDragDefersEvenTheShownModulesNotice() {
        var state = IslandNoticePresentation()
        XCTAssertEqual(state.update(noticeID: 1, from: .shelf,
                                    context: context(.expanded, dragging: true, shown: .shelf)), .waiting)
        XCTAssertEqual(state.update(noticeID: 1, from: .shelf, context: context(.expanded, shown: .shelf)), .visible)
    }

    func testOthersWaitOnlyForAnUnpinnedPanel() {
        XCTAssertTrue(context(.expanded, shown: .shelf).othersWaitForClose)
        XCTAssertFalse(context(.pinned, shown: .shelf).othersWaitForClose)
        XCTAssertFalse(context(.collapsed).othersWaitForClose)
    }
}
