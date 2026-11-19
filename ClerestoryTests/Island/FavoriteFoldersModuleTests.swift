import AppKit
import XCTest
@testable import Clerestory

@MainActor
final class FavoriteFoldersModuleTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    func testPersistenceRoundTripPreservesOrderAndMetadata() throws {
        let directory = try makeTemporaryDirectory()
        let persistence = FavoriteFoldersPersistenceController(directoryURL: directory)
        let firstAddedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let secondAddedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let first = FavoriteFolder(
            bookmark: Data("first".utf8),
            lastKnownPath: "/tmp/First",
            customDisplayName: "Work",
            addedAt: firstAddedAt
        )
        let second = FavoriteFolder(
            bookmark: Data("second".utf8),
            lastKnownPath: "/tmp/Second",
            addedAt: secondAddedAt
        )

        try persistence.saveNow([first, second])

        XCTAssertEqual(persistence.loadResult(), .loaded([first, second]))
    }

    func testCorruptPersistenceIsQuarantinedWithoutOverwrite() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("folder-favorites.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fileURL)
        let persistence = FavoriteFoldersPersistenceController(directoryURL: directory)

        XCTAssertEqual(persistence.loadResult(), .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("folder-favorites.json.corrupt-") })
    }

    func testAddingFoldersDeduplicatesAndRejectsFiles() throws {
        let folder = try makeTemporaryDirectory()
        let file = folder.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: file)
        let store = makeStore()
        store.start()

        let first = store.addFolders([folder, file])
        let second = store.addFolders([folder])

        XCTAssertEqual(first, .init(added: 1, duplicates: 0, rejected: 1))
        XCTAssertEqual(second, .init(added: 0, duplicates: 1, rejected: 0))
        XCTAssertEqual(store.items.count, 1)
    }

    func testAddingFoldersPostsNotices() throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        let file = first.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: file)
        let messages = IslandMessageCenter.forTesting()
        let store = makeStore(messages: messages)
        store.start()

        _ = store.addFolders([first])
        assertNotice(in: messages, key: "added", tone: .success, title: "Folder added to Quick Access.")
        _ = store.addFolders([second, file])
        assertNotice(in: messages, key: "added", tone: .success, title: "Folder added to Quick Access.")
        _ = store.addFolders([first, second])
        assertNotice(in: messages, key: "duplicate", tone: .info, title: "This folder is already in Quick Access.")
        _ = store.addFolders([file])
        assertNotice(in: messages, key: "add-failed", tone: .error, title: "Some folders could not be added.")
        XCTAssertEqual(FavoriteFoldersStore.importNotice(for: .init(added: 2))?.title, "Folders added to Quick Access.")
        XCTAssertNil(FavoriteFoldersStore.importNotice(for: .init()))
    }

    func testLoadFailureIsALastingRowUntilAFolderIsAdded() throws {
        let directory = try makeTemporaryDirectory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("folder-favorites.json"))
        let folder = try makeTemporaryDirectory()
        let messages = IslandMessageCenter.forTesting()
        let store = FavoriteFoldersStore(
            persistence: FavoriteFoldersPersistenceController(directoryURL: directory),
            bookmarkService: BookmarkService(),
            opener: FavoriteFolderOpenerSpy(),
            messenger: messages.messenger(for: .folders)
        )

        store.start()
        XCTAssertTrue(store.didFailToLoad)
        XCTAssertNil(messages.currentNotice, "A load failure is page content, not a notice")

        _ = store.addFolders([folder])
        XCTAssertFalse(store.didFailToLoad)
        store.stop()
    }

    func testDefaultOpenDoesNotSpecifyFinderOrAnotherApplication() throws {
        let folder = try makeTemporaryDirectory()
        let opener = FavoriteFolderOpenerSpy()
        let store = makeStore(opener: opener)
        store.start()
        _ = store.addFolders([folder])
        let itemID = try XCTUnwrap(store.items.first?.id)

        XCTAssertTrue(store.open(itemID))
        XCTAssertEqual(opener.openedFolderURLs, [folder.standardizedFileURL])
        XCTAssertEqual(opener.applicationArguments, [nil])
    }

    func testOpenWithApplicationPassesOnlyTheExplicitOverride() throws {
        let folder = try makeTemporaryDirectory()
        let application = URL(fileURLWithPath: "/Applications/QSpace.app")
        let opener = FavoriteFolderOpenerSpy()
        let store = makeStore(opener: opener)
        store.start()
        _ = store.addFolders([folder])
        let itemID = try XCTUnwrap(store.items.first?.id)

        XCTAssertTrue(store.open(itemID, with: application))
        XCTAssertEqual(opener.applicationArguments, [application])
    }

    func testOpenFailureMarksOnlyTheFavoriteUnavailable() throws {
        let folder = try makeTemporaryDirectory()
        let opener = FavoriteFolderOpenerSpy()
        opener.nextErrorMessage = "Handler unavailable"
        let messages = IslandMessageCenter.forTesting()
        let store = makeStore(opener: opener, messages: messages)
        store.start()
        _ = store.addFolders([folder])
        let itemID = try XCTUnwrap(store.items.first?.id)

        XCTAssertTrue(store.open(itemID))

        XCTAssertTrue(store.isUnavailable(itemID))
        let posted = try XCTUnwrap(messages.currentNotice)
        XCTAssertEqual(posted.notice.key, "open-failed")
        XCTAssertEqual(posted.notice.tone, .error)
        XCTAssertEqual(posted.notice.title, "Could not open this folder.")
        XCTAssertEqual(posted.notice.detail, "Could not open this folder. Handler unavailable")

        opener.nextErrorMessage = nil
        XCTAssertTrue(store.open(itemID))
        XCTAssertFalse(store.isUnavailable(itemID))
        XCTAssertNil(messages.currentNotice, "Opening it again withdraws the failure")
    }

    func testMissingFolderShowsOnItsTileWithoutANotice() throws {
        let folder = try makeTemporaryDirectory()
        let messages = IslandMessageCenter.forTesting()
        let store = makeStore(messages: messages)
        store.start()
        _ = store.addFolders([folder])
        messages.messenger(for: .folders).withdrawNotice("added")
        let itemID = try XCTUnwrap(store.items.first?.id)
        try FileManager.default.removeItem(at: folder)

        XCTAssertFalse(store.open(itemID))

        XCTAssertTrue(store.isUnavailable(itemID))
        XCTAssertNil(messages.currentNotice)
    }

    func testRelocatingToAFilePostsTheReason() throws {
        let folder = try makeTemporaryDirectory()
        let file = folder.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: file)
        let messages = IslandMessageCenter.forTesting()
        let store = makeStore(messages: messages)
        store.start()
        _ = store.addFolders([folder])
        let itemID = try XCTUnwrap(store.items.first?.id)

        XCTAssertFalse(store.relocate(itemID, to: file))
        assertNotice(in: messages, key: "relocate-failed", tone: .error,
                     title: "Only folders can be added to Quick Access.")

        XCTAssertTrue(store.relocate(itemID, to: folder))
        XCTAssertNil(messages.currentNotice, "Relocating withdraws the failure")
    }

    func testPasteboardRoutingAcceptsFoldersAndRejectsFiles() throws {
        let folder = try makeTemporaryDirectory()
        let file = folder.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: file)
        let store = makeStore()

        let folderPasteboard = NSPasteboard(
            name: .init("FavoriteFoldersTests-folder-\(UUID().uuidString)")
        )
        folderPasteboard.clearContents()
        folderPasteboard.writeObjects([folder as NSURL])
        let filePasteboard = NSPasteboard(
            name: .init("FavoriteFoldersTests-file-\(UUID().uuidString)")
        )
        filePasteboard.clearContents()
        filePasteboard.writeObjects([file as NSURL])

        XCTAssertTrue(store.canImportFolders(from: folderPasteboard))
        XCTAssertFalse(store.canImportFolders(from: filePasteboard))
    }

    func testRemoveFavoriteDoesNotDeleteOriginalFolder() throws {
        let folder = try makeTemporaryDirectory()
        let store = makeStore()
        store.start()
        _ = store.addFolders([folder])
        let itemID = try XCTUnwrap(store.items.first?.id)

        store.remove(itemID)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testMoveRenameAndSelectionRemainOrdered() throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        let store = makeStore()
        store.start()
        _ = store.addFolders([first, second])
        let firstID = try XCTUnwrap(store.items.first?.id)
        let secondID = try XCTUnwrap(store.items.last?.id)

        store.move(secondID, before: firstID)
        store.rename(secondID, to: "Projects")
        store.select(secondID)

        XCTAssertEqual(store.items.map(\.id), [secondID, firstID])
        XCTAssertEqual(store.items.first?.displayName, "Projects")
        XCTAssertEqual(store.selectedID, secondID)
    }

    func testFolderCopyShowsProgressStatusThenCompletionNotice() async throws {
        let target = try makeTemporaryDirectory()
        let sourceFolder = try makeTemporaryDirectory()
        let file = sourceFolder.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: file)
        let store = makeStore()
        store.start()
        XCTAssertEqual(store.addFolders([target]).added, 1)
        let folderID = try XCTUnwrap(store.items.first?.id)

        let messages = IslandMessageCenter.forTesting()
        messages.moduleDidStart(.folders)
        let coordinator = FavoriteFolderDropCoordinator(folders: store, bookmarks: BookmarkService())
        coordinator.messenger = messages.messenger(for: .folders)
        let tile = CGRect(x: 0, y: 0, width: 100, height: 100)
        coordinator.tileFrames[folderID] = tile
        coordinator.viewport = tile
        let pasteboard = NSPasteboard(name: .init("FavoriteFoldersTests-copy-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])

        XCTAssertTrue(coordinator.perform(DragContainerDropContext(
            pasteboard: pasteboard, location: CGPoint(x: 50, y: 50), isInternal: false, internalItems: nil
        )))
        let copying = try XCTUnwrap(messages.topStatus(for: .folders))
        XCTAssertEqual(copying.key, "copy")
        XCTAssertEqual(copying.title, "Copying files…")
        XCTAssertEqual(copying.tone, .progress)
        XCTAssertNil(messages.currentNotice)

        // The copy runs on the copier actor; give it up to 10 s.
        let deadline = ContinuousClock.now + .seconds(10)
        while coordinator.isCopying, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard !coordinator.isCopying else {
            return XCTFail("The folder copy did not finish within 10 s")
        }
        XCTAssertTrue(messages.statuses(for: .folders).isEmpty, "Completion clears the status")
        let posted = try XCTUnwrap(messages.currentNotice)
        XCTAssertEqual(posted.moduleID, .folders)
        XCTAssertEqual(posted.notice.title, "Folder copy complete")
        XCTAssertEqual(posted.notice.detail, "Copied: 1 · Skipped: 0 · Failed: 0 · Cancelled: 0")
        XCTAssertEqual(posted.notice.tone, .success)
        XCTAssertEqual(IslandMessageCenter.duration(for: posted.notice), 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("note.txt").path))
    }

    func testFolderCopyNoticeWarnsWhenAnythingFailed() {
        let failed = FavoriteFolderDropCoordinator.completionNotice(for: FolderCopyResult(copied: 2, failed: 1))
        XCTAssertEqual(failed.tone, .warning)
        XCTAssertEqual(failed.detail, "Copied: 2 · Skipped: 0 · Failed: 1 · Cancelled: 0")
        let skipped = FavoriteFolderDropCoordinator.completionNotice(for: FolderCopyResult(copied: 1, skipped: 1))
        XCTAssertEqual(skipped.tone, .success)
    }

    func testStartAndStopAreIdempotent() {
        let store = makeStore()

        store.start()
        store.start()
        XCTAssertTrue(store.isRunning)

        store.stop()
        store.stop()
        XCTAssertFalse(store.isRunning)
    }

    private func makeStore(
        opener: (any FavoriteFolderOpening)? = nil,
        messages: IslandMessageCenter? = nil
    ) -> FavoriteFoldersStore {
        FavoriteFoldersStore(
            bookmarkService: BookmarkService(),
            opener: opener ?? FavoriteFolderOpenerSpy(),
            messenger: messages?.messenger(for: .folders) ?? .inert
        )
    }

    private func assertNotice(in messages: IslandMessageCenter, key: String, tone: IslandNotice.Tone,
                              title: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let posted = messages.currentNotice else {
            return XCTFail("No notice posted", file: file, line: line)
        }
        XCTAssertEqual(posted.moduleID, .folders, file: file, line: line)
        XCTAssertEqual(posted.notice.key, key, file: file, line: line)
        XCTAssertEqual(posted.notice.tone, tone, file: file, line: line)
        XCTAssertEqual(posted.notice.title, title, file: file, line: line)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Clerestory-FavoriteFoldersTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }
}

@MainActor
private final class FavoriteFolderOpenerSpy: FavoriteFolderOpening {
    var defaultApplication: URL?
    var applications: [URL] = []
    private(set) var openedFolderURLs: [URL] = []
    private(set) var applicationArguments: [URL?] = []
    var nextErrorMessage: String?

    func defaultApplicationURL(for folderURL: URL) -> URL? {
        defaultApplication
    }

    func applicationURLs(for folderURL: URL) -> [URL] {
        applications
    }

    func open(
        _ folderURL: URL,
        with applicationURL: URL?,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        openedFolderURLs.append(folderURL.standardizedFileURL)
        applicationArguments.append(applicationURL)
        completion(nextErrorMessage)
    }
}
