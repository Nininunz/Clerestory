import AppKit
import Synchronization
import XCTest
@testable import Clerestory

/// Cover the CutMoveService sequence of copying, verifying, and trashing before creating an isCut item,
/// along with Command-drop dispatch in DropImportCoordinator. Use real files in a disposable directory and
/// inject a Trash operation to verify ordering and failures without relying on Trash in the test host.
@MainActor
final class CutMoveServiceTests: XCTestCase {
    /// Fixtures for each test case: in-place construction, defer cleanup at the end of the test case (same
    /// pattern as DropImportCoordinatorTests, no setUp/tearDown).
    @MainActor
    private struct Context {
        let bookmarkService = BookmarkService()
        let tempFileService: TempFileService
        /// Simulated 'app container' root (source is rejected when cutting).
        let containerURL: URL
        var temporaryURLs: [URL] = []

        init() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClerestoryTests-CutMove-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: root.appendingPathComponent("Materialized", isDirectory: true))
            containerURL = root.appendingPathComponent("Container", isDirectory: true)
            temporaryURLs.append(root)
        }

        func cleanup() {
            bookmarkService.stopAccessingAll()
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    private func makeContext() -> Context { Context() }

    /// Create a source file/folder outside the container (in a temporary directory).
    private func makeSourceFile(in context: inout Context, named name: String = "sample.txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClerestoryTests-\(UUID().uuidString)-\(name)")
        try "sample content".write(to: url, atomically: true, encoding: .utf8)
        context.temporaryURLs.append(url)
        return url
    }

    /// Default trash mock is provided by the caller via a closure (Mutex is not copyable and cannot be
    /// passed across parameters,
    /// so it is constructed in-place within the test case and captured into the closure —— same pattern as
    /// FilePromiseProviderTests).
    private func makeService(context: Context,
                             trashOriginal: @escaping @Sendable (URL) throws -> Void) -> CutMoveService {
        CutMoveService(
            tempFileService: context.tempFileService,
            bookmarkService: context.bookmarkService,
            containerURL: context.containerURL,
            trashOriginal: trashOriginal
        )
    }

    private func managedDirectoryContents(_ context: Context) throws -> [String] {
        let directory = context.tempFileService.directoryURL
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    // MARK: - Success path

    func testMakeCutItem_success_copiesToManagedDirAndTrashesOriginal() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "notes.txt")
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: source, displayName: "notes.txt")

        guard case .moved(let item) = outcome else {
            return XCTFail("Expected .moved, got \(outcome)")
        }
        XCTAssertTrue(item.isCut)
        XCTAssertEqual(item.displayName, "notes.txt", "displayName keeps the original name (no UUID prefix exposed)")
        XCTAssertEqual(item.kind, .file)
        XCTAssertNotNil(item.bookmark, "bookmark should point to the managed copy")
        // Copy is in place and content is consistent.
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix(context.tempFileService.directoryURL.path),
                      "Managed copy should be inside the Materialized directory: \(path)")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), "sample content")
        // Original file is moved to the 'Trash' (mock deletion), and trash is called once after the copy.
        XCTAssertEqual(trashed.withLock { $0 }, [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "Original location should be gone")
        guard case .loaded(let records) = service.managedMoveJournal.loadResult() else {
            return XCTFail("A recovery transaction must remain after the original is trashed")
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].state, .originalTrashed)
        XCTAssertEqual(records[0].managedItem.id, item.id)
    }

    func testMakeCutItem_folder_movesRecursively() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClerestoryTests-\(UUID().uuidString)-docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "nested".write(to: folder.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        context.temporaryURLs.append(folder)
        let service = makeService(context: context) { url in
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: folder, displayName: "docs")

        guard case .moved(let item) = outcome else {
            return XCTFail("Expected .moved, got \(outcome)")
        }
        XCTAssertEqual(item.kind, .folder)
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("inner.txt"),
                                  encoding: .utf8), "nested")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - Failed branch

    func testMakeCutItem_copyFailure_keepsOriginalAndFallsBack() throws {
        let context = makeContext()
        defer { context.cleanup() }
        // Source does not exist → copyItem throws an error.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClerestoryTests-\(UUID().uuidString)-ghost.txt")
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: missing, displayName: "ghost.txt")

        guard case .fallbackToReference(let item, let reason) = outcome else {
            return XCTFail("Expected .fallbackToReference, got \(outcome)")
        }
        XCTAssertEqual(reason, .copyFailed)
        XCTAssertFalse(item.isCut, "The fallback item is in plain reference mode")
        XCTAssertEqual(item.path, missing.path)
        XCTAssertEqual(trashed.withLock { $0 }, [], "The original file must not be touched when copy fails")
        XCTAssertEqual(try managedDirectoryContents(context), [], "No partial copy may be left behind")
    }

    func testMakeCutItem_trashFailure_removesCopyAndFallsBack() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "readonly.txt")
        struct TrashRefused: Error {}
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            throw TrashRefused()
        }

        let outcome = service.makeCutItem(for: source, displayName: "readonly.txt")

        guard case .fallbackToReference(let item, let reason) = outcome else {
            return XCTFail("Expected .fallbackToReference, got \(outcome)")
        }
        XCTAssertEqual(reason, .trashFailed)
        XCTAssertFalse(item.isCut)
        XCTAssertEqual(item.path, source.path, "The fallback reference points to the original file")
        XCTAssertEqual(trashed.withLock { $0 }, [source], "trash was attempted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "The original file must stay in place when trash fails")
        XCTAssertEqual(try managedDirectoryContents(context), [], "The copy must be cleaned up")
        XCTAssertEqual(service.managedMoveJournal.loadResult(), .missing,
                       "No live transaction may remain after the destructive step fails")
    }

    func testMakeCutItem_damagedJournalNeverTrashesOriginal() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "protected.txt")
        let root = context.tempFileService.directoryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("managed-moves.json"))
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: source, displayName: "protected.txt")

        guard case .fallbackToReference(let item, let reason) = outcome else {
            return XCTFail("Expected .fallbackToReference, got \(outcome)")
        }
        XCTAssertEqual(reason, .transactionFailed)
        XCTAssertEqual(item.path, source.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(trashed.withLock { $0 }, [])
        XCTAssertEqual(try managedDirectoryContents(context), [])
    }

    func testMakeCutItem_sourceInsideContainer_rejected() throws {
        let context = makeContext()
        defer { context.cleanup() }
        // Source is inside a 'container' (to prevent nesting).
        let container = context.containerURL
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let source = container.appendingPathComponent("already-ours.txt")
        try "inside".write(to: source, atomically: true, encoding: .utf8)
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: source, displayName: "already-ours.txt")

        guard case .fallbackToReference(let item, let reason) = outcome else {
            return XCTFail("Expected .fallbackToReference, got \(outcome)")
        }
        XCTAssertEqual(reason, .sourceInsideContainer)
        XCTAssertFalse(item.isCut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Source inside the container is untouched")
        XCTAssertEqual(trashed.withLock { $0 }, [], "trash must not be called when the cut is refused")
        XCTAssertEqual(try managedDirectoryContents(context), [], "No copy is made when the cut is refused")
    }

    // MARK: - dropMode modifier key determination

    func testDropMode_commandWithFileURL_isMove() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClerestoryTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: .command), .move)
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: [.command, .option]), .move,
                       "⌘ combined with other modifier keys is still a cut")
    }

    func testDropMode_withoutCommand_isCopy() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClerestoryTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: []), .copy)
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: .option), .copy,
                       "⌥ is not a cut modifier key")
    }

    func testDropMode_commandWithNonFileContent_isCopy() {
        let text = NSPasteboard(name: NSPasteboard.Name("ClerestoryTests-\(UUID().uuidString)"))
        text.writeObjects(["hello" as NSString])
        XCTAssertEqual(DropImportCoordinator.dropMode(for: text, modifiers: .command), .copy,
                       "Text has no \"original file\" concept, so ⌘ has no effect")

        let url = NSPasteboard(name: NSPasteboard.Name("ClerestoryTests-\(UUID().uuidString)"))
        url.declareTypes([PasteboardTypes.url], owner: nil)
        url.setString("https://www.apple.com", forType: PasteboardTypes.url)
        XCTAssertEqual(DropImportCoordinator.dropMode(for: url, modifiers: .command), .copy,
                       "A URL has no \"original file\" concept, so ⌘ has no effect")
    }

    // MARK: - Coordinator integration (⌘ dispatch + per-file independent success/failure)

    func testImport_moveMode_perFileIndependentOutcomes() async throws {
        var context = makeContext()
        defer { context.cleanup() }
        let movable = try makeSourceFile(in: &context, named: "movable.txt")
        let stuck = try makeSourceFile(in: &context, named: "stuck.txt")
        struct TrashRefused: Error {}
        let noticeCenter = ShelfNoticeModel()
        let service = CutMoveService(
            tempFileService: context.tempFileService,
            bookmarkService: context.bookmarkService,
            containerURL: context.containerURL,
            trashOriginal: { url in
                if url.lastPathComponent.contains("stuck") {
                    throw TrashRefused()
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        let coordinator = DropImportCoordinator(
            bookmarkService: context.bookmarkService,
            tempFileService: context.tempFileService,
            noticeCenter: noticeCenter,
            cutMoveService: service
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClerestoryTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([movable as NSURL, stuck as NSURL])

        var received: [ShelfItem] = []
        let completion = expectation(description: "Both background managed moves complete")
        completion.expectedFulfillmentCount = 2
        let collect: @MainActor (ShelfItem) -> Void = { item in
            received.append(item)
            completion.fulfill()
        }
        let result = coordinator.importItems(
            from: pasteboard,
            mode: .move,
            onManagedMoveReady: { item in
                collect(item)
                return true
            },
            onAsyncItemReady: collect
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.pendingMaterializations, 2)
        await fulfillment(of: [completion], timeout: 3)

        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received[0].isCut, "The item whose trash succeeded is cut onto the shelf")
        XCTAssertFalse(received[1].isCut, "The item whose trash failed falls back to reference mode")
        XCTAssertEqual(received[1].path, stuck.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path), "The failed file is left as is")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movable.path), "Moved file is gone from its original location")
        guard case .partiallySucceeded(let successCount, let failures) =
            coordinator.transferStore.currentTask?.phase else {
            return XCTFail("A managed-move fallback should produce an actionable batch warning")
        }
        XCTAssertEqual(successCount, 2, "Both the move and the safe fallback reference landed on the shelf")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].reason, .managedMoveFellBackToReference)
        XCTAssertNil(noticeCenter.message, "ActivityStrip alone presents batch status, avoiding duplicate notices")
    }

    func testImport_copyMode_neverCuts() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "keepme.txt")
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }
        let coordinator = DropImportCoordinator(
            bookmarkService: context.bookmarkService,
            tempFileService: context.tempFileService,
            cutMoveService: service
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClerestoryTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([source as NSURL])

        let result = coordinator.importItems(from: pasteboard, mode: .copy) { _ in }

        let item = try XCTUnwrap(result.items.first)
        XCTAssertFalse(item.isCut)
        XCTAssertEqual(item.path, source.path, "Copy mode stores a reference to the original file")
        XCTAssertEqual(trashed.withLock { $0 }, [], "Copy mode does not call trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Copy mode leaves the original untouched")
    }

    func testImport_moveMode_persistenceFailureBecomesRecoveryWarning() async throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "needs-recovery.txt")
        let service = makeService(context: context) { url in
            try FileManager.default.removeItem(at: url)
        }
        let coordinator = DropImportCoordinator(
            bookmarkService: context.bookmarkService,
            tempFileService: context.tempFileService,
            cutMoveService: service
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClerestoryTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([source as NSURL])
        let callback = expectation(description: "managed item reached persistence boundary")

        coordinator.importItems(
            from: pasteboard,
            mode: .move,
            onManagedMoveReady: { _ in
                callback.fulfill()
                return false
            },
            onAsyncItemReady: { _ in XCTFail("successful move should use managed callback") }
        )
        await fulfillment(of: [callback], timeout: 3)

        guard case .partiallySucceeded(let successCount, let failures) =
            coordinator.transferStore.currentTask?.phase else {
            return XCTFail("An immediate persistence failure must be kept as a recoverable warning")
        }
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(failures.first?.reason, .persistenceFailed)
        XCTAssertEqual(failures.first?.impact, .itemAddedWithWarning)
        XCTAssertEqual(failures.first?.recoveryAction, .openStorageRecovery)
    }
}
