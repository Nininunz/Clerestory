import AppKit
import Synchronization
import XCTest
@testable import OpenYoink

/// Write logic of FilePromiseProvider: Use temporary directory real files to directly call `writeCopy` and
/// delegate methods for verification. Real drag-and-drop session chain (target app triggers
/// writePromiseTo) is listed in manual regression checklist (Finder / browser upload test page / Mail).
///
/// Test class is @MainActor (provider/AppKit objects isolated consistently), so not using setUp/tearDown
/// (XCTestCase's overrides are non-isolated, accessing MainActor state will trigger warnings) — each test
/// case constructs fixtures in place and cleans up with defer; `writeCopy` itself is a non-isolated pure
/// function.
@MainActor
final class FilePromiseProviderTests: XCTestCase {
    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePayload(sourceURL: URL,
                             bookmark: Data? = nil,
                             suggestedName: String = "hello.txt",
                             promisedFileType: String = "public.plain-text") -> FilePromiseProvider.Payload {
        FilePromiseProvider.Payload(sourceURL: sourceURL,
                                    bookmark: bookmark,
                                    suggestedName: suggestedName,
                                    promisedFileType: promisedFileType)
    }

    // MARK: - writeCopy

    func testWriteCopy_copiesFileToDestination_andKeepsSource() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "promise content".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("drop-target/hello.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        try FilePromiseProvider.writeCopy(of: makePayload(sourceURL: source),
                                          to: destination,
                                          bookmarkService: bookmarkService)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "promise content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "promise 落盘是 copy，源文件必须保留")
    }

    func testWriteCopy_withBookmark_resolvesAndCopies() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("bookmarked.txt")
        try "via bookmark".write(to: source, atomically: true, encoding: .utf8)
        let bookmark = try bookmarkService.createBookmark(for: source)
        let destination = directory.appendingPathComponent("out.txt")

        try FilePromiseProvider.writeCopy(of: makePayload(sourceURL: source, bookmark: bookmark),
                                          to: destination,
                                          bookmarkService: bookmarkService)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "via bookmark")
    }

    func testWriteCopy_folder_copiesRecursively() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFolder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "nested".write(to: sourceFolder.appendingPathComponent("nested.txt"),
                           atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("docs-copy")

        try FilePromiseProvider.writeCopy(
            of: makePayload(sourceURL: sourceFolder,
                            suggestedName: "docs",
                            promisedFileType: "public.folder"),
            to: destination,
            bookmarkService: bookmarkService)

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("nested.txt"),
                                  encoding: .utf8), "nested")
    }

    func testUnresolvableBookmarkFailsDeliveryWithoutCopyingFromSavedPath() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("replacement.txt")
        let contents = Data("unrelated replacement file".utf8)
        try contents.write(to: source)
        let destination = directory.appendingPathComponent("export.txt")
        let delivered = Mutex(false)
        let failed = Mutex(false)
        let completionError = Mutex<Error??>(nil)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: source, bookmark: Data("unresolvable bookmark".utf8)),
            bookmarkService: BookmarkService(),
            onDelivered: { _ in delivered.withLock { $0 = true } },
            onError: { _ in failed.withLock { $0 = true } }
        )
        let delegate = try XCTUnwrap(provider.delegate)
        delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNotNil(try XCTUnwrap(completionError.withLock { $0 }))
        XCTAssertFalse(delivered.withLock { $0 })
        XCTAssertTrue(failed.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    func testWriteCopy_missingSource_throws() {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        let payload = makePayload(sourceURL: directory.appendingPathComponent("nonexistent.txt"))

        XCTAssertThrowsError(try FilePromiseProvider.writeCopy(
            of: payload,
            to: directory.appendingPathComponent("out.txt"),
            bookmarkService: bookmarkService))
    }

    // MARK: - Delegate

    func testDelegate_fileNameForType_returnsSuggestedName() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt"),
                                 suggestedName: "报告 2026.txt"),
            bookmarkService: BookmarkService()
        )
        XCTAssertEqual(provider.delegate?.filePromiseProvider(provider, fileNameForType: "public.plain-text"),
                       "报告 2026.txt")
    }

    func testDelegate_writePromiseTo_reportsPromiseRepresentationRequested() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let requestCount = Mutex(0)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: source),
            bookmarkService: BookmarkService(),
            onPromiseRequested: { requestCount.withLock { $0 += 1 } }
        )

        _ = provider.delegate?.filePromiseProvider(provider, fileNameForType: "public.data")
        XCTAssertEqual(requestCount.withLock { $0 }, 0,
                       "询问文件名不代表目标已经请求写入")
        provider.delegate?.filePromiseProvider(
            provider,
            writePromiseTo: directory.appendingPathComponent("out.txt")
        ) { _ in }

        XCTAssertEqual(requestCount.withLock { $0 }, 1)
    }

    func testDelegate_operationQueue_isUserInitiated() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt")),
            bookmarkService: BookmarkService()
        )
        let queue = provider.delegate?.operationQueue?(for: provider)
        XCTAssertEqual(queue?.qualityOfService, .userInitiated)
        XCTAssertFalse(queue === OperationQueue.main, "promise 写入不得在主队列")
    }

    /// Regression (real device crash fix): When the target app requests promise content, the system
    /// synchronously calls delegate via `NSFileProviderXPCMessenger` on **its own XPC queue** — delegate
    /// must be nonisolated, otherwise module default MainActor isolation will trigger
    /// `_dispatch_assert_queue_fail` (SIGTRAP when dragging to QSpace Pro). Use background queue
    /// synchronous call to two delegate methods to reproduce this scenario (GCD `sync` closure does not
    /// escape, no Sendable constraint; if delegate has MainActor isolation, it will crash).
    func testDelegate_methodsCallableFromBackgroundQueue() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/bg.txt"),
                                 suggestedName: "bg.txt"),
            bookmarkService: BookmarkService()
        )
        let delegate = provider.delegate
        DispatchQueue.global().sync {
            _ = delegate?.filePromiseProvider(provider, fileNameForType: "public.data")
            _ = delegate?.operationQueue?(for: provider)
        }
    }

    func testDelegate_writePromiseTo_successReportsNilError() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "delegate write".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("out.txt")
        let provider = FilePromiseProvider(payload: makePayload(sourceURL: source),
                                           bookmarkService: bookmarkService)

        // Delegate method implementation is synchronous write (AppKit calls it on write queue in real
        // session), directly synchronous call in test to assert callback result.
        let completionError = Mutex<Error??>(nil)
        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNil(try XCTUnwrap(completionError.withLock { $0 }))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "delegate write")
    }

    func testDelegate_writePromiseTo_failureReportsErrorWithoutCrashing() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingSource = directory.appendingPathComponent("nonexistent.txt")
        let reportedError = Mutex<Error?>(nil)
        let completionError = Mutex<Error??>(nil)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: missingSource),
            bookmarkService: bookmarkService,
            onError: { error in reportedError.withLock { $0 = error } }
        )

        provider.delegate?.filePromiseProvider(
            provider,
            writePromiseTo: directory.appendingPathComponent("out.txt")
        ) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNotNil(try XCTUnwrap(completionError.withLock { $0 }),
                        "写失败必须把错误回传给接收应用")
        XCTAssertNotNil(reportedError.withLock { $0 },
                        "写失败必须上报 onError（预留 UI 订阅）")
    }

    // MARK: - Direct file writer / promise-only provider

    func testDirectFileWriter_serializesFileURLAndChromiumFilenameList() {
        let source = URL(fileURLWithPath: "/tmp/OpenYoink 示例.txt")
        let writer = DirectFilePasteboardWriter(fileURL: source)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))

        XCTAssertEqual(writer.writableTypes(for: pasteboard), [
            PasteboardTypes.fileURL,
            PasteboardTypes.legacyFilenames,
        ])
        XCTAssertTrue(pasteboard.writeObjects([writer]))
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.fileURL), source.absoluteString)
        XCTAssertEqual(
            pasteboard.propertyList(forType: PasteboardTypes.legacyFilenames) as? [String],
            [source.path]
        )
    }

    func testDirectFileWriter_serializesTutorialTokenIntoRealPasteboard() {
        let token = UUID().uuidString
        let writer = DirectFilePasteboardWriter(
            fileURL: URL(fileURLWithPath: "/tmp/tutorial.txt"),
            tutorialSessionToken: token
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))

        XCTAssertTrue(pasteboard.writeObjects([writer]))
        XCTAssertTrue(pasteboard.types?.contains(PasteboardTypes.tutorialSession) == true)
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.tutorialSession), token)
    }

    func testDirectFileWriter_tiffFallbackIsLazyUntilRequested() {
        let requestCount = Mutex(0)
        let expected = Data([0x49, 0x49, 0x2A, 0x00])
        let writer = DirectFilePasteboardWriter(
            fileURL: URL(fileURLWithPath: "/tmp/image.tiff"),
            tiffDataProvider: {
                requestCount.withLock { $0 += 1 }
                return expected
            }
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))

        XCTAssertTrue(pasteboard.writeObjects([writer]))
        XCTAssertEqual(requestCount.withLock { $0 }, 0,
                       "写入拖拽 pasteboard 时不应提前解码整张图片")
        XCTAssertEqual(pasteboard.data(forType: PasteboardTypes.tiff), expected)
        XCTAssertEqual(requestCount.withLock { $0 }, 1)
    }

    /// F-05: Provider hosting cut items always declares promise type only.
    func testFilePromiseProvider_alwaysAdvertisesPromiseOnly() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt")),
            bookmarkService: BookmarkService()
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        let types = provider.writableTypes(for: pasteboard)

        XCTAssertFalse(types.contains(.fileURL))
        XCTAssertFalse(types.contains(PasteboardTypes.legacyFilenames))
        XCTAssertFalse(types.contains(PasteboardTypes.tiff))
        XCTAssertFalse(types.contains(PasteboardTypes.tutorialSession))
        XCTAssertTrue(types.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) })
    }

    /// F-05: Write completion callback carries target URL (cut item delivery confirmation).
    func testDelegate_writePromiseTo_successCallsOnDeliveredWithDestination() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "deliver me".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("out.txt")
        let deliveredURL = Mutex<URL?>(nil)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: source),
            bookmarkService: bookmarkService,
            onDelivered: { url in deliveredURL.withLock { $0 = url } }
        )

        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination) { _ in }

        XCTAssertEqual(deliveredURL.withLock { $0 }, destination)
    }

    /// F-05: Write failure does not trigger delivery confirmation (only onError).
    func testDelegate_writePromiseTo_failureDoesNotCallOnDelivered() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deliveredURL = Mutex<URL?>(nil)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: directory.appendingPathComponent("nonexistent.txt")),
            bookmarkService: bookmarkService,
            onDelivered: { url in deliveredURL.withLock { $0 = url } }
        )

        provider.delegate?.filePromiseProvider(
            provider,
            writePromiseTo: directory.appendingPathComponent("out.txt")
        ) { _ in }

        XCTAssertNil(deliveredURL.withLock { $0 })
    }

}
