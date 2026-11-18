import XCTest
@testable import OpenYoink

/// S6: Availability rules for project operations (`ItemActions.canX`, pure logic) —
/// the basis for right-click menu disabled state and stale 'File Unavailable' branch.
@MainActor
final class ItemActionsTests: XCTestCase {
    // MARK: - Helpers

    private func item(_ kind: ItemKind,
                      path: String? = nil,
                      text: String? = nil,
                      urlString: String? = nil,
                      children: [ShelfItem]? = nil,
                      stale: Bool = false) -> ShelfItem {
        var result = ShelfItem(kind: kind, path: path, displayName: "item",
                               text: text, urlString: urlString, children: children)
        result.isStale = stale
        return result
    }

    // MARK: - Open

    func testCanOpen() {
        // file/folder/image: Must have a path; folder can be opened (open in Finder).
        XCTAssertTrue(ItemActions.canOpen(item(.file, path: "/tmp/a.txt")))
        XCTAssertTrue(ItemActions.canOpen(item(.folder, path: "/tmp")))
        XCTAssertTrue(ItemActions.canOpen(item(.image, path: "/tmp/a.png")))
        XCTAssertFalse(ItemActions.canOpen(item(.file)))
        // text: Write to a temporary .txt and open it, must have content.
        XCTAssertTrue(ItemActions.canOpen(item(.text, text: "hello")))
        XCTAssertFalse(ItemActions.canOpen(item(.text, text: "")))
        XCTAssertFalse(ItemActions.canOpen(item(.text)))
        // url: NSWorkspace.open URL, must be able to parse out the URL.
        XCTAssertTrue(ItemActions.canOpen(item(.url, urlString: "https://example.com")))
        XCTAssertFalse(ItemActions.canOpen(item(.url, urlString: "")))
        XCTAssertFalse(ItemActions.canOpen(item(.url)))
        // stack does not provide 'Open'.
        XCTAssertFalse(ItemActions.canOpen(item(.stack, children: [item(.file, path: "/tmp/a")])))
        // stale items are always unavailable.
        XCTAssertFalse(ItemActions.canOpen(item(.file, path: "/tmp/a.txt", stale: true)))
    }

    // MARK: - Show in Finder

    func testCanRevealInFinder() {
        // file/folder/image: Locate the parsed URL.
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.file, path: "/tmp/a.txt")))
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.folder, path: "/tmp")))
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.image, path: "/tmp/a.png")))
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.file)))
        // text: Locate its temporary .txt (materialized/temporary files can also be located).
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.text, text: "hello")))
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.text)))
        // url without a local file, stack without a single corresponding file: unavailable.
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.url, urlString: "https://example.com")))
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.stack, children: [item(.file, path: "/tmp/a")])))
        // stale items are always unavailable.
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.file, path: "/tmp/a.txt", stale: true)))
    }

    // MARK: - Quick Look

    func testCanQuickLook() {
        // file/folder/image: Must have a path and not be stale (macOS QL supports folders, not disabled).
        XCTAssertTrue(ItemActions.canQuickLook(item(.file, path: "/tmp/a.txt")))
        XCTAssertTrue(ItemActions.canQuickLook(item(.folder, path: "/tmp")))
        XCTAssertTrue(ItemActions.canQuickLook(item(.image, path: "/tmp/a.png")))
        XCTAssertFalse(ItemActions.canQuickLook(item(.file)))
        // text: Temporary .txt preview, must have content.
        XCTAssertTrue(ItemActions.canQuickLook(item(.text, text: "hello")))
        XCTAssertFalse(ItemActions.canQuickLook(item(.text, text: "")))
        // url: Fall back to temporary .txt of URL string, must have URL string.
        XCTAssertTrue(ItemActions.canQuickLook(item(.url, urlString: "https://example.com")))
        XCTAssertFalse(ItemActions.canQuickLook(item(.url)))
        // stack: Any child item can be previewed (nested recursion).
        let liveStack = item(.stack, children: [item(.file, path: "/tmp/a", stale: true),
                                                item(.stack, children: [item(.text, text: "hi")])])
        XCTAssertTrue(ItemActions.canQuickLook(liveStack))
        XCTAssertFalse(ItemActions.canQuickLook(item(.stack, children: [item(.file, path: "/tmp/a", stale: true)])))
        XCTAssertFalse(ItemActions.canQuickLook(item(.stack, children: [])))
        XCTAssertFalse(ItemActions.canQuickLook(item(.stack)))
        // stale items are always unavailable.
        XCTAssertFalse(ItemActions.canQuickLook(item(.file, path: "/tmp/a.txt", stale: true)))
    }
}
