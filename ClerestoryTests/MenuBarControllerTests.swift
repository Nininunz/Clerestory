import XCTest
@testable import Clerestory

/// S10/C8: Feasibility decision to re-add the 'Recent Projects' menu bar item
/// (MenuBarController.canReadd).
final class MenuBarControllerTests: XCTestCase {
    private var temporaryFileURL: URL!

    override func setUpWithError() throws {
        temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClerestoryTests-\(UUID().uuidString)")
        try Data("fixture".utf8).write(to: temporaryFileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryFileURL)
    }

    private func entry(kind: ItemKind, path: String? = nil, urlString: String? = nil) -> RecentEntry {
        RecentEntry(item: ShelfItem(kind: kind,
                                    path: path,
                                    displayName: "Entry",
                                    urlString: urlString),
                    draggedOutAt: Date())
    }

    /// The file still exists and is readable → can be re-added.
    func testFileEntryReaddsWhenReadable() {
        XCTAssertTrue(MenuBarController.canReadd(entry(kind: .file, path: temporaryFileURL.path)))
    }

    /// The file has been deleted/inaccessible → grayed out.
    func testFileEntryDisabledWhenUnreachable() {
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .file, path: "/nonexistent/gone-\(UUID().uuidString)")))
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .image, path: nil)))
    }

    /// URL entries can be re-added if they are parseable.
    func testURLEntryReaddsWhenParseable() {
        XCTAssertTrue(MenuBarController.canReadd(entry(kind: .url, urlString: "https://example.com")))
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .url, urlString: nil)))
    }

    /// text only has a 100-character summary, stack has been expanded into sub-items —— both cannot be
    /// faithfully restored, grayed out.
    func testTextAndStackEntriesAreDisabled() {
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .text)))
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .stack)))
    }
}
