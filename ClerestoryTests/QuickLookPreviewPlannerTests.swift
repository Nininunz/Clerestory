import AppKit
import XCTest
@testable import Clerestory

/// S6: Quick Look preview collection parsing rules (`QuickLookPreviewPlanner`, pure logic).
final class QuickLookPreviewPlannerTests: XCTestCase {
    @MainActor
    func testPreviewAppearsAboveIslandWithoutLoweringHigherPreviewLevel() {
        let island = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        XCTAssertGreaterThan(QuickLookCoordinator.previewLevel(original: .floating, source: island).rawValue,
                             island.rawValue)
        XCTAssertGreaterThan(QuickLookCoordinator.previewLevel(original: .normal, source: .floating).rawValue,
                             NSWindow.Level.floating.rawValue)
        XCTAssertEqual(QuickLookCoordinator.previewLevel(original: .screenSaver, source: island), .screenSaver)
        XCTAssertEqual(QuickLookCoordinator.previewLevel(original: .floating, source: nil), .floating)
    }

    // MARK: - Helpers

    private func file(_ name: String, stale: Bool = false) -> ShelfItem {
        var item = ShelfItem(kind: .file, path: "/tmp/\(name)", displayName: name)
        item.isStale = stale
        return item
    }

    private func stack(_ name: String, children: [ShelfItem]) -> ShelfItem {
        ShelfItem(kind: .stack, displayName: name, children: children)
    }

    private func ids(_ items: [ShelfItem]) -> [UUID] {
        items.map(\.id)
    }

    // MARK: - Base set rules (§2.3 Quick Look)

    /// Right-click on the selected card: Preview the entire selected set, with the order as displayed.
    func testContextItemInSelection_previewsWholeSelectionInDisplayOrder() {
        let a = file("a"), b = file("b"), c = file("c")
        let result = QuickLookPreviewPlanner.previewItems(selection: [a, b, c], contextItem: b)
        XCTAssertEqual(ids(result), ids([a, b, c]))
    }

    /// Right-click on an unselected card (or Stack overlay item): Preview only itself, ignoring the
    /// current selection.
    func testContextItemOutsideSelection_previewsContextItemOnly() {
        let a = file("a"), b = file("b")
        let context = file("x")
        let result = QuickLookPreviewPlanner.previewItems(selection: [a, b], contextItem: context)
        XCTAssertEqual(ids(result), [context.id])
    }

    /// Empty path (no context item): Preview the current selected set; if no item is selected, there is no
    /// preview.
    func testNilContextItem_usesSelectionOrNothing() {
        let a = file("a"), b = file("b")
        XCTAssertEqual(ids(QuickLookPreviewPlanner.previewItems(selection: [a, b], contextItem: nil)),
                       ids([a, b]))
        XCTAssertTrue(QuickLookPreviewPlanner.previewItems(selection: [], contextItem: nil).isEmpty)
    }

    // MARK: - Stack flattening

    /// Recursively expand stack into children (including nested stacks within children), maintaining the
    /// order.
    func testStacksAreFlattenedRecursively() {
        let f1 = file("f1"), f2 = file("f2"), f3 = file("f3"), f4 = file("f4")
        let inner = stack("inner", children: [f2, f3])
        let outer = stack("outer", children: [f1, inner])
        let result = QuickLookPreviewPlanner.previewItems(selection: [outer, f4], contextItem: nil)
        XCTAssertEqual(ids(result), ids([f1, f2, f3, f4]))
    }

    /// Selecting a single stack card as context: Expand its children instead of previewing the stack
    /// itself.
    func testContextStackExpandsToChildren() {
        let f1 = file("f1"), f2 = file("f2")
        let s = stack("s", children: [f1, f2])
        let result = QuickLookPreviewPlanner.previewItems(selection: [s], contextItem: s)
        XCTAssertEqual(ids(result), ids([f1, f2]))
    }

    // MARK: - Stale filtering

    /// Stale items (bookmark is invalid, QL cannot open) are removed from the preview set, including stack
    /// children; if all are stale, the set is empty (caller does not open panel).
    func testStaleItemsAreFilteredIncludingStackChildren() {
        let a = file("a", stale: true), b = file("b")
        XCTAssertEqual(ids(QuickLookPreviewPlanner.previewItems(selection: [a, b], contextItem: nil)),
                       [b.id])

        let staleChild = file("c", stale: true), liveChild = file("d")
        let s = stack("s", children: [staleChild, liveChild])
        XCTAssertEqual(ids(QuickLookPreviewPlanner.previewItems(selection: [s], contextItem: nil)),
                       [liveChild.id])

        let allStale = stack("t", children: [file("e", stale: true)])
        XCTAssertTrue(QuickLookPreviewPlanner.previewItems(selection: [a, allStale], contextItem: nil).isEmpty)
    }

    // MARK: - Current index

    /// Start item = the position of the context item in the flattened set; 0 if not provided or not found.
    func testCurrentIndex() {
        let f1 = file("f1"), f2 = file("f2"), f3 = file("f3")
        let flattened = [f1, f2, f3]
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: flattened, contextItem: f3), 2)
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: flattened, contextItem: file("other")), 0)
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: flattened, contextItem: nil), 0)
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: [], contextItem: f1), 0)
    }
}
