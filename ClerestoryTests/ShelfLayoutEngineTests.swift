import CoreGraphics
import XCTest
@testable import Clerestory

/// ShelfLayoutEngine (S9) pure logic unit tests: edge attachment, hidden sliding direction, frame
/// grabbing, target screen backtracking (mouse screen is pulled → main screen), custom frame validation
/// and backtracking, Space alignment correction.
///
/// Test geometry: main screen frame (0,0 1920×1080), Dock occupies bottom 60 → visibleFrame (0,60
/// 1920×1020); secondary screen on the right frame (1920,0 2560×1440), menu bar occupies top 25 →
/// visibleFrame (1920,25 2560×1415).
final class ShelfLayoutEngineTests: XCTestCase {
    func testGridOnlyOmitsScrollingWhenItsRowsFit() {
        let oneRow = CGSize(width: 276, height: 132)
        XCTAssertTrue(ShelfLayoutEngine.gridFits(itemCount: 3, viewport: oneRow))
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 4, viewport: oneRow))
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 1, viewport: CGSize(width: 284, height: 131)))
        XCTAssertTrue(ShelfLayoutEngine.gridFits(itemCount: 4, viewport: CGSize(width: 284, height: 276)))
        // Narrow shelves and incomplete initial layout must keep the scroll path.
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 1, viewport: .zero))
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 1, viewport: CGSize(width: 83, height: 300)))
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 3, viewport: CGSize(width: 275, height: 132)))
    }

    private let mainScreen = ShelfLayoutEngine.ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 60, width: 1920, height: 1020)
    )
    private let secondaryScreen = ShelfLayoutEngine.ScreenGeometry(
        frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1920, y: 25, width: 2560, height: 1415)
    )

    // MARK: - Edge attachment (UX5: compact height + vertical centering)

    func testEdgeAttachedFrame_leftAnchorsToVisibleMinX_andCentersVertically() {
        // y = 60 + (1020-144)/2 = 498。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .left, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 498, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_rightAnchorsToVisibleMaxX_andCentersVertically() {
        // x = 4480-320 = 4160；y = 25 + (1415-144)/2 = 660.5。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: secondaryScreen.visibleFrame),
            CGRect(x: 4160, y: 660.5, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_customHasNoEdge() {
        XCTAssertNil(
            ShelfLayoutEngine.edgeAttachedFrame(position: .custom, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame)
        )
    }

    // MARK: - Hidden frame

    func testHiddenFrame_offsetsAwayFromAttachmentEdge() {
        let frame = CGRect(x: 1600, y: 60, width: 320, height: 1020)
        XCTAssertEqual(ShelfLayoutEngine.hiddenFrame(for: frame, position: .right),
                       CGRect(x: 1920, y: 60, width: 320, height: 1020))
        XCTAssertEqual(ShelfLayoutEngine.hiddenFrame(for: frame, position: .left),
                       CGRect(x: 1280, y: 60, width: 320, height: 1020))
    }

    func testHiddenFrame_customStaysInPlace() {
        // custom no sliding: hidden only with transparency animation.
        let frame = CGRect(x: 500, y: 300, width: 320, height: 600)
        XCTAssertEqual(ShelfLayoutEngine.hiddenFrame(for: frame, position: .custom), frame)
    }

    // MARK: - Clamping

    func testClamped_frameInsideReturnsSelf() {
        let frame = CGRect(x: 100, y: 200, width: 320, height: 600)
        XCTAssertEqual(ShelfLayoutEngine.clamped(frame, into: mainScreen.visibleFrame), frame)
    }

    func testClamped_movesOriginMinimallyIntoBounds() {
        // Crossing right edge and top edge: x receives maxX-width, y receives maxY-height.
        let frame = CGRect(x: 1700, y: 1000, width: 320, height: 300)
        XCTAssertEqual(ShelfLayoutEngine.clamped(frame, into: mainScreen.visibleFrame),
                       CGRect(x: 1600, y: 780, width: 320, height: 300))
    }

    func testClamped_shrinksOversizedFrame() {
        let frame = CGRect(x: -100, y: -100, width: 3000, height: 2000)
        XCTAssertEqual(ShelfLayoutEngine.clamped(frame, into: mainScreen.visibleFrame),
                       CGRect(x: 0, y: 60, width: 1920, height: 1020))
    }

    // MARK: - Target screen

    func testTargetScreen_prefersScreenContainingMouse() {
        let screens = [mainScreen, secondaryScreen]
        XCTAssertEqual(ShelfLayoutEngine.targetScreen(mouseLocation: CGPoint(x: 500, y: 500),
                                                      screens: screens), mainScreen)
        XCTAssertEqual(ShelfLayoutEngine.targetScreen(mouseLocation: CGPoint(x: 2000, y: 100),
                                                      screens: screens), secondaryScreen)
    }

    func testTargetScreen_mouseOffAllScreensFallsBackToMain() {
        // Mouse screen just pulled away, coordinates are empty → backtrack to first screen (main screen).
        let screens = [mainScreen, secondaryScreen]
        XCTAssertEqual(ShelfLayoutEngine.targetScreen(mouseLocation: CGPoint(x: -50, y: 3000),
                                                      screens: screens), mainScreen)
    }

    func testTargetScreen_emptyScreensReturnsNil() {
        XCTAssertNil(ShelfLayoutEngine.targetScreen(mouseLocation: .zero, screens: []))
    }

    // MARK: - Custom frame validation

    func testValidatedCustomFrame_insideScreenKeepsPosition() {
        let persisted = CGRect(x: 100, y: 200, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320, screens: [mainScreen]),
            persisted
        )
    }

    func testValidatedCustomFrame_appliesCurrentWidthSetting() {
        // Width is based on setting: persistent width 300, current setting 400 → 400, origin remains
        // unchanged.
        let persisted = CGRect(x: 100, y: 200, width: 300, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 400, screens: [mainScreen]),
            CGRect(x: 100, y: 200, width: 400, height: 600)
        )
    }

    func testValidatedCustomFrame_partiallyOutsideClampsIntoVisibleFrame() {
        // Resolution reduced, persistent frame goes beyond right and top edges → clip to visible area.
        let persisted = CGRect(x: 1800, y: 500, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320, screens: [mainScreen]),
            CGRect(x: 1600, y: 480, width: 320, height: 600)
        )
    }

    func testValidatedCustomFrame_straddlingScreensPicksLargestIntersection() {
        // Spanning dual screens: larger intersection with secondary screen → clip into secondary screen.
        let persisted = CGRect(x: 1800, y: 200, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320,
                                                   screens: [mainScreen, secondaryScreen]),
            CGRect(x: 1920, y: 200, width: 320, height: 600)
        )
    }

    func testValidatedCustomFrame_offAllScreensReturnsNil() {
        // Persistent frame screen has been removed → nil, fallback to default position by caller.
        let persisted = CGRect(x: 5000, y: 5000, width: 320, height: 600)
        XCTAssertNil(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320,
                                                   screens: [mainScreen, secondaryScreen])
        )
    }

    // MARK: - Full target-frame decision

    func testTargetFrame_edgePositionsFollowMouseScreen() {
        let screens = [mainScreen, secondaryScreen]
        // Mouse on secondary screen → stick to right edge of secondary screen; card with semantic state
        // line: 1 item per line = 192, vertically centered.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 1,
                                          mouseLocation: CGPoint(x: 2000, y: 100),
                                          screens: screens, persistedCustomFrame: nil),
            CGRect(x: 4160, y: 636.5, width: 320, height: 192)
        )
        // Mouse on primary screen → stick to left edge of primary screen.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .left, width: 300, itemCount: 1,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: screens, persistedCustomFrame: nil),
            CGRect(x: 0, y: 474, width: 300, height: 192)
        )
    }

    func testTargetFrame_emptyShelfUsesCompactEmptyHeight() {
        // Empty frame: compact empty state height 200, vertically centered on primary screen → y = 60 +
        // (1020-200)/2 = 470.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 0,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil),
            CGRect(x: 1600, y: 470, width: 320, height: 200)
        )
    }

    func testTargetFrame_customWithoutPersistedStartsAtRightEdge() {
        // First select custom (no persistent frame) → default frame starts at right edge of mouse screen
        // (UX5 remains still)
        // custom path: default frame remains full height.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 5,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil),
            CGRect(x: 1600, y: 60, width: 320, height: 1020)
        )
    }

    func testTargetFrame_customWithValidPersistedStaysWhereUserPlacedIt() {
        // Custom does not follow mouse: persistent on secondary screen, mouse on primary screen, still
        // appears at original secondary screen location.
        let persisted = CGRect(x: 2000, y: 100, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 3,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen, secondaryScreen],
                                          persistedCustomFrame: persisted),
            persisted
        )
    }

    func testTargetFrame_customWithUnpluggedPersistedScreenFallsBackToRightEdge() {
        // Persistent frame screen has been removed → fallback to right edge of mouse screen (primary
        // screen if removed).
        let persisted = CGRect(x: 2000, y: 100, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 2,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen],
                                          persistedCustomFrame: persisted),
            CGRect(x: 1600, y: 60, width: 320, height: 1020)
        )
    }

    func testTargetFrame_emptyScreensReturnsFallback() {
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 4,
                                          mouseLocation: .zero, screens: [],
                                          persistedCustomFrame: nil),
            CGRect(origin: .zero, size: ShelfLayoutEngine.fallbackSize)
        )
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 0,
                                          mouseLocation: .zero, screens: [],
                                          persistedCustomFrame: CGRect(x: 100, y: 100, width: 320, height: 600)),
            CGRect(origin: .zero, size: ShelfLayoutEngine.fallbackSize)
        )
    }

    // MARK: - UX5 compact height: column calculation (consistent with SwiftUI adaptive grid)

    func testColumnCount_matchesAdaptiveGridMath() {
        // 88pt minimum column + 12 spacing; panel padding total 32.
        // 320 → grid 288 → 3 columns (3×88+2×12=288 exactly fits).
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 320), 3)
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 240), 2)
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 420), 4)
        // Narrower than single column minimum width still at least 1 column.
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 100), 1)
    }

    // MARK: - UX5 compact height: row count / maximum / empty frame

    func testContentHeight_singleRowForUpToFullRowOfItems() {
        // 3 columns: 1~3 items same as 1 row → 28 + 132 + 32 = 192.
        for count in 1...3 {
            XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: count, panelWidth: 320,
                                                           visibleHeight: 1020), 192)
        }
    }

    func testContentHeight_growsByRow() {
        // 4 items 2 rows → 28 + (132×2 + 12) + 32 = 336; 7 items 3 rows → 480.
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 4, panelWidth: 320,
                                                       visibleHeight: 1020), 336)
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 7, panelWidth: 320,
                                                       visibleHeight: 1020), 480)
    }

    func testContentHeight_narrowerPanelFitsFewerColumnsHenceMoreRows() {
        // Width 240 → 2 columns: 3 items i.e. 2 rows → 336.
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 3, panelWidth: 240,
                                                       visibleHeight: 1020), 336)
    }

    func testContentHeight_capsAtEightyPercentOfVisibleHeight() {
        // Visible height 300 → upper limit 240; 10 items in 4 rows exceed the upper limit → clamped to 240
        // (overflow scrolls).
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 10, panelWidth: 320,
                                                       visibleHeight: 300), 240)
    }

    func testContentHeight_emptyShelfUsesCompactPlaceholderCappedOnTinyScreens() {
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 0, panelWidth: 320,
                                                       visibleHeight: 1020), 200)
        // Tiny screens: empty state is also constrained by the 80% upper limit.
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 0, panelWidth: 320,
                                                       visibleHeight: 200), 160)
    }

    func testContentHeight_activityStripReservesSpaceWithoutExceedingCap() {
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 3, panelWidth: 320,
                                            visibleHeight: 1000, hasActivity: true),
            ShelfLayoutEngine.contentHeight(itemCount: 3, panelWidth: 320,
                                            visibleHeight: 1000)
                + ShelfLayoutEngine.activityStripHeight
        )
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 20, panelWidth: 240,
                                            visibleHeight: 300, hasActivity: true),
            240
        )
    }

    func testContentHeight_quickActionsReserveOneCompactRow() {
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 1, panelWidth: 320,
                                            visibleHeight: 1020,
                                            hasQuickActions: true),
            236
        )
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 1, panelWidth: 320,
                                            visibleHeight: 1020,
                                            hasActivity: true,
                                            hasQuickActions: true),
            322
        )
        // An empty shelf cannot have an explicit selection; the defensive
        // input must not create a floating action-only row.
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 0, panelWidth: 320,
                                            visibleHeight: 1020,
                                            hasQuickActions: true),
            200
        )
    }

    func testTargetFrame_quickActionsRemainEdgeAttachedAndCentered() {
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right,
                                          width: 320,
                                          itemCount: 1,
                                          hasQuickActions: true,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen],
                                          persistedCustomFrame: nil),
            CGRect(x: 1600, y: 452, width: 320, height: 236)
        )
    }

    // MARK: - Space-change correction

    func testOnscreenCorrection_validFrameUnchanged() {
        let frame = CGRect(x: 1600, y: 60, width: 320, height: 1020)
        XCTAssertEqual(
            ShelfLayoutEngine.onscreenCorrection(for: frame, screens: [mainScreen]),
            frame
        )
    }

    func testOnscreenCorrection_partiallyOffscreenClampsBack() {
        let frame = CGRect(x: 100, y: -200, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.onscreenCorrection(for: frame, screens: [mainScreen]),
            CGRect(x: 100, y: 60, width: 320, height: 600)
        )
    }

    func testOnscreenCorrection_fullyOffscreenReturnsNil() {
        let frame = CGRect(x: 9000, y: 9000, width: 320, height: 600)
        XCTAssertNil(ShelfLayoutEngine.onscreenCorrection(for: frame, screens: [mainScreen]))
    }

    func testOnscreenCorrection_emptyScreensReturnsNil() {
        XCTAssertNil(ShelfLayoutEngine.onscreenCorrection(for: .zero, screens: []))
    }
}
