import XCTest
@testable import Clerestory

/// Task three: shelf inner edge handle side logic (ShelfLayoutEngine.innerEdgeHandleSide). The handle is
/// always on the inner edge of the shelf facing the screen center; custom free position has no attached
/// edge, and the handle is not displayed.
final class ShelfCollapseHandleTests: XCTestCase {
    func testHandleSide_rightAnchoredShelf_placesHandleOnLeadingEdge() {
        XCTAssertEqual(ShelfLayoutEngine.innerEdgeHandleSide(for: .right), .leading)
    }

    func testHandleSide_leftAnchoredShelf_placesHandleOnTrailingEdge() {
        XCTAssertEqual(ShelfLayoutEngine.innerEdgeHandleSide(for: .left), .trailing)
    }

    func testHandleSide_customPosition_hasNoHandle() {
        XCTAssertNil(ShelfLayoutEngine.innerEdgeHandleSide(for: .custom))
    }

    /// Handle width must be ≤ panel margin band (outer 8pt + content 8pt padding) — it is placed as a
    /// overlay within the margin band, not taking up grid width (column count calculation and card
    /// coordinate system are not polluted).
    func testHandleWidth_fitsInsidePanelMarginBand() {
        XCTAssertEqual(ShelfLayoutEngine.innerEdgeHandleWidth, 10)
        XCTAssertLessThanOrEqual(ShelfLayoutEngine.innerEdgeHandleWidth, 16)
    }
}
