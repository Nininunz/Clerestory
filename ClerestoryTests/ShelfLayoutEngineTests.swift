import CoreGraphics
import XCTest
@testable import Clerestory

/// ShelfLayoutEngine grid column math, shared by the card grid and keyboard navigation.
final class ShelfLayoutEngineTests: XCTestCase {
    func testColumnCount_matchesAdaptiveGridMath() {
        // 84pt minimum column + 12 spacing; panel padding total 32.
        // 320 → grid 288 → 3 columns.
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 320), 3)
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 240), 2)
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 420), 4)
        // Narrower than single column minimum width still at least 1 column.
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 100), 1)
    }

    func testGridColumnCountUsesTheViewportInsideThePadding() {
        XCTAssertEqual(ShelfLayoutEngine.gridColumnCount(for: 288), 3)
        XCTAssertEqual(ShelfLayoutEngine.gridColumnCount(for: 0), 1)
    }
}
