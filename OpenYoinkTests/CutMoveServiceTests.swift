import AppKit
import Synchronization
import XCTest
@testable import OpenYoink

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
                .appendingPathComponent("OpenYoinkTests-CutMove-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-\(name)")
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
            return XCTFail("期望 .moved，得到 \(outcome)")
        }
        XCTAssertTrue(item.isCut)
        XCTAssertEqual(item.displayName, "notes.txt", "displayName 保持原名（不暴露 UUID 前缀）")
        XCTAssertEqual(item.kind, .file)
        XCTAssertNotNil(item.bookmark, "bookmark 应指向保管副本")
        // Copy is in place and content is consistent.
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix(context.tempFileService.directoryURL.path),
                      "保管副本应在 Materialized 目录内：\(path)")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), "sample content")
        // Original file is moved to the 'Trash' (mock deletion), and trash is called once after the copy.
        XCTAssertEqual(trashed.withLock { $0 }, [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "原位置应已消失")
        guard case .loaded(let records) = service.managedMoveJournal.loadResult() else {
            return XCTFail("原文件进废纸篓后必须保留恢复事务")
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].state, .originalTrashed)
        XCTAssertEqual(records[0].managedItem.id, item.id)
    }

    func testMakeCutItem_folder_movesRecursively() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "nested".write(to: folder.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        context.temporaryURLs.append(folder)
        let service = makeService(context: context) { url in
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: folder, displayName: "docs")

        guard case .moved(let item) = outcome else {
            return XCTFail("期望 .moved，得到 \(outcome)")
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
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-ghost.txt")
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: missing, displayName: "ghost.txt")

        guard case .fallbackToReference(let item, let reason) = outcome else {
            return XCTFail("期望 .fallbackToReference，得到 \(outcome)")
        }
        XCTAssertEqual(reason, .copyFailed)
        XCTAssertFalse(item.isCut, "回退项是普通引用模式")
        XCTAssertEqual(item.path, missing.path)
        XCTAssertEqual(trashed.withLock { $0 }, [], "copy 失败时不得触碰原文件")
        XCTAssertEqual(try managedDirectoryContents(context), [], "不得留下半成品副本")
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
            return XCTFail("期望 .fallbackToReference，得到 \(outcome)")
        }
        XCTAssertEqual(reason, .trashFailed)
        XCTAssertFalse(item.isCut)
        XCTAssertEqual(item.path, source.path, "回退引用指向原文件")
        XCTAssertEqual(trashed.withLock { $0 }, [source], "trash 已尝试")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "trash 失败时原文件必须保持不动")
        XCTAssertEqual(try managedDirectoryContents(context), [], "副本必须被清掉")
        XCTAssertEqual(service.managedMoveJournal.loadResult(), .missing,
                       "破坏性步骤失败后不得残留有效事务")
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
            return XCTFail("期望 .fallbackToReference，得到 \(outcome)")
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
            return XCTFail("期望 .fallbackToReference，得到 \(outcome)")
        }
        XCTAssertEqual(reason, .sourceInsideContainer)
        XCTAssertFalse(item.isCut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "容器内源不动")
        XCTAssertEqual(trashed.withLock { $0 }, [], "拒绝剪切时不得调用 trash")
        XCTAssertEqual(try managedDirectoryContents(context), [], "拒绝剪切时不产生副本")
    }

    // MARK: - dropMode modifier key determination

    func testDropMode_commandWithFileURL_isMove() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: .command), .move)
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: [.command, .option]), .move,
                       "⌘ 与其他修饰键组合仍为剪切")
    }

    func testDropMode_withoutCommand_isCopy() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: []), .copy)
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: .option), .copy,
                       "⌥ 不是剪切修饰键")
    }

    func testDropMode_commandWithNonFileContent_isCopy() {
        let text = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        text.writeObjects(["hello" as NSString])
        XCTAssertEqual(DropImportCoordinator.dropMode(for: text, modifiers: .command), .copy,
                       "文本没有「原文件」概念，⌘ 无效")

        let url = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        url.declareTypes([PasteboardTypes.url], owner: nil)
        url.setString("https://www.apple.com", forType: PasteboardTypes.url)
        XCTAssertEqual(DropImportCoordinator.dropMode(for: url, modifiers: .command), .copy,
                       "URL 没有「原文件」概念，⌘ 无效")
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([movable as NSURL, stuck as NSURL])

        var received: [ShelfItem] = []
        let completion = expectation(description: "两个后台托管移动均完成")
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
        XCTAssertTrue(received[0].isCut, "trash 成功者剪切入架")
        XCTAssertFalse(received[1].isCut, "trash 失败者回退引用模式")
        XCTAssertEqual(received[1].path, stuck.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path), "失败文件原样保留")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movable.path), "成功文件原位置消失")
        guard case .partiallySucceeded(let successCount, let failures) =
            coordinator.transferStore.currentTask?.phase else {
            return XCTFail("托管移动回退应形成可操作的批次警告")
        }
        XCTAssertEqual(successCount, 2, "成功移动与安全回退的引用都已实际入架")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].reason, .managedMoveFellBackToReference)
        XCTAssertNil(noticeCenter.message, "批次状态由 ActivityStrip 统一呈现，避免重复提示")
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([source as NSURL])

        let result = coordinator.importItems(from: pasteboard, mode: .copy) { _ in }

        let item = try XCTUnwrap(result.items.first)
        XCTAssertFalse(item.isCut)
        XCTAssertEqual(item.path, source.path, "复制模式保存原文件引用")
        XCTAssertEqual(trashed.withLock { $0 }, [], "复制模式不调用 trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "复制模式原文件不动")
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
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
            return XCTFail("即时持久化失败必须保留为可恢复警告")
        }
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(failures.first?.reason, .persistenceFailed)
        XCTAssertEqual(failures.first?.impact, .itemAddedWithWarning)
        XCTAssertEqual(failures.first?.recoveryAction, .openStorageRecovery)
    }
}
