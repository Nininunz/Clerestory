import AppKit
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import OpenYoink

/// Strategy mapping / stack expansion / assertion of representations for each kind in DragPayloadBuilder.
///
/// After the representation collection is written to the real (test private) pasteboard via
/// `NSPasteboard.writeObjects`, assert its declared types (advertised types) — consistent with the path
/// AppKit takes during dragging, i.e., the type collection actually seen by the drop target. The dragging
/// session itself (`beginDraggingSession`) requires a real window and mouse event, to be included in
/// manual regression checklist.
///
/// Note: Starting with macOS 26 SDK, `NSItemProvider` does not have `NSPasteboardWriting` consistency, and
/// cannot be used as a drag writer; therefore, the assertion object should be for pasteboard advertised
/// types rather than `registeredTypeIdentifiers`.
@MainActor
final class DragPayloadBuilderTests: XCTestCase {
    private let bookmarkService = BookmarkService()

    // MARK: - Helpers

    private func makeItem(kind: ItemKind, name: String = "item") -> ShelfItem {
        switch kind {
        case .file, .folder, .image:
            ShelfItem(kind: kind, path: "/tmp/\(name)", displayName: name)
        case .text:
            ShelfItem(kind: .text, displayName: name, text: "sample text")
        case .url:
            ShelfItem(kind: .url, displayName: name, urlString: "https://example.com")
        case .stack:
            ShelfItem(kind: .stack, displayName: name, children: [
                ShelfItem(kind: .file, path: "/tmp/child-a.txt", displayName: "child-a.txt"),
            ])
        }
    }

    /// Write the writer to a test pasteboard and return the set of declared types.
    private func advertisedTypes(of writer: NSPasteboardWriting) -> [String] {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        guard pasteboard.writeObjects([writer]) else { return [] }
        return pasteboard.types?.map(\.rawValue) ?? []
    }

    /// Write the drag writer to a test pasteboard and return it so assertions can read the payload through
    /// the same path as a drop target.
    private func writtenPasteboard(for writer: NSPasteboardWriting) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        precondition(pasteboard.writeObjects([writer]), "writer 必须能写入 pasteboard")
        return pasteboard
    }

    // MARK: - Pure function: strategy mapping

    func testStrategy_kindMapping() {
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .file)), .fileBacked)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .folder)), .fileBacked)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .image)), .fileBackedImage)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .text)), .plainText)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .url)), .webURL)
        XCTAssertNil(DragPayloadBuilder.strategy(for: makeItem(kind: .stack)),
                     "stack 不整体拖出，由 flattenedItems 展开")
    }

    func testCanMakePasteboardWriterRejectsMalformedCards() {
        XCTAssertFalse(DragPayloadBuilder.canMakePasteboardWriter(
            for: ShelfItem(kind: .file, displayName: "missing-path")
        ))
        XCTAssertFalse(DragPayloadBuilder.canMakePasteboardWriter(
            for: ShelfItem(kind: .text, displayName: "empty", text: "")
        ))
        XCTAssertFalse(DragPayloadBuilder.canMakePasteboardWriter(
            for: ShelfItem(kind: .url, displayName: "bad", urlString: nil)
        ))
        XCTAssertTrue(DragPayloadBuilder.canMakePasteboardWriter(
            for: ShelfItem(kind: .text, displayName: "ok", text: "hello")
        ))
    }

    // MARK: - Pure function: stack unwinding

    func testFlattenedItems_expandsStacksPreservingOrder() {
        let a = ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt")
        let b = ShelfItem(kind: .text, displayName: "b", text: "b")
        let c = ShelfItem(kind: .url, displayName: "c", urlString: "https://c.example.com")
        let d = ShelfItem(kind: .file, path: "/tmp/d.txt", displayName: "d.txt")
        let stack = ShelfItem(kind: .stack, displayName: "s", children: [b, c])

        let flat = DragPayloadBuilder.flattenedItems([a, stack, d])

        XCTAssertEqual(flat.map(\.displayName), ["a.txt", "b", "c", "d.txt"])
        XCTAssertEqual(flat.map(\.id), [a.id, b.id, c.id, d.id])
    }

    func testFlattenedItems_nestedStackAndEmptyStack() {
        let leaf = ShelfItem(kind: .file, path: "/tmp/leaf.txt", displayName: "leaf.txt")
        let inner = ShelfItem(kind: .stack, displayName: "inner", children: [leaf])
        let outer = ShelfItem(kind: .stack, displayName: "outer", children: [inner])
        let empty = ShelfItem(kind: .stack, displayName: "empty", children: [])

        // Unwind nested stack recursively; retain empty stack as-is (to be handled by writer construction
        // to discard nil).
        let flat = DragPayloadBuilder.flattenedItems([outer, empty])
        XCTAssertEqual(flat.map(\.displayName), ["leaf.txt", "empty"])
    }

    // MARK: - Pure function: promisedFileType

    func testPromisedFileType_folderExtensionFallback() {
        let folder = ShelfItem(kind: .folder, path: "/tmp/docs", displayName: "docs")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: folder), UTType.folder.identifier)

        // Compare with the system declaration table (starting with macOS 26, some UTIs like public.pdf are
        // no longer declared; the declaration table may return other declared identifiers like
        // com.adobe.pdf).
        let text = ShelfItem(kind: .file, path: "/tmp/notes.txt", displayName: "notes.txt")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: text),
                       UTType(filenameExtension: "txt")?.identifier)

        let pdf = ShelfItem(kind: .file, path: "/tmp/report.pdf", displayName: "report.pdf")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: pdf),
                       UTType(filenameExtension: "pdf")?.identifier)

        let png = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: png),
                       UTType(filenameExtension: "png")?.identifier)

        let noExtension = ShelfItem(kind: .file, path: "/tmp/README", displayName: "README")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: noExtension), UTType.data.identifier)

        let noPath = ShelfItem(kind: .file, displayName: "ghost")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: noPath), UTType.data.identifier)
    }

    /// NSFilePromiseProvider throws an NSException for invalid fileType (non-catchable) — the output of
    /// promisedFileType must conform to kUTTypeData/kUTTypeDirectory.
    func testPromisedFileType_alwaysConformsToDataOrDirectory() {
        let samples = [
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .file, path: "/tmp/a.pdf", displayName: "a.pdf"),
            ShelfItem(kind: .image, path: "/tmp/a.png", displayName: "a.png"),
            ShelfItem(kind: .file, path: "/tmp/a.unknownext123", displayName: "a.unknownext123"),
            ShelfItem(kind: .folder, path: "/tmp/docs", displayName: "docs"),
            ShelfItem(kind: .file, path: "/tmp/README", displayName: "README"),
        ]
        for item in samples {
            let identifier = DragPayloadBuilder.promisedFileType(for: item)
            let type = UTType(identifier)
            XCTAssertNotNil(type, "\(identifier) 必须是已声明 UTI")
            XCTAssertTrue(type?.conforms(to: .data) == true || type?.conforms(to: .directory) == true,
                          "\(identifier) 必须符合 data/directory（NSFilePromiseProvider 硬性要求）")
        }
    }

    // MARK: - Regular file item: direct file representation

    func testUnresolvableBookmarkDoesNotAdvertiseTheSavedPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let replacement = directory.appendingPathComponent("report.txt")
        try Data("unrelated replacement file".utf8).write(to: replacement)
        let item = ShelfItem(kind: .file,
                             path: replacement.path,
                             bookmark: Data("unresolvable bookmark".utf8),
                             displayName: replacement.lastPathComponent)

        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))
        XCTAssertEqual(try Data(contentsOf: replacement), Data("unrelated replacement file".utf8))
    }

    func testMixedDragRemovalKeepsTheItemThatCouldNotBeRepresented() throws {
        let suite = "OpenYoinkTests-SkippedDrag-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("available.txt")
        let original = Data("copy only".utf8)
        try original.write(to: source)
        let available = ShelfItem(kind: .file, path: source.path, displayName: source.lastPathComponent)
        let skipped = ShelfItem(kind: .file,
                                path: directory.appendingPathComponent("offline.txt").path,
                                bookmark: Data("unresolvable bookmark".utf8),
                                displayName: "offline.txt")
        let selected = DragOutContents(items: [available, skipped], topLevelIDs: [available.id, skipped.id])
        let represented = DragPayloadBuilder.makeDraggingItems(
            for: selected.items,
            frame: CGRect(x: 0, y: 0, width: 88, height: 100),
            bookmarkService: bookmarkService
        )
        let settings = SettingsStore(defaults: defaults)
        settings.dragOutRemovalPolicy = .remove
        let store = ShelfStore(items: selected.items)
        let recents = RecentItemsService(directoryURL: directory)
        let session = DragSessionController(
            contents: selected.restrictingToRepresentedItems(represented.map(\.item)),
            store: store,
            settings: settings,
            recents: recents
        )
        session.completeDrag(operation: .copy)

        XCTAssertEqual(store.items, [skipped])
        XCTAssertEqual(recents.entries.map(\.path), [source.path])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testFileItem_writerAdvertisesFileURLAndChromiumFilenameList() throws {
        let item = ShelfItem(kind: .file, path: "/tmp/report.pdf", displayName: "report.pdf")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        XCTAssertNotNil(writer as? DirectFilePasteboardWriter,
                        "普通文件必须使用真实拖拽会保留全部类型的直接 writer")

        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(UTType.fileURL.identifier),
                      "advertised types \(advertised) 应含 public.file-url（Finder copy 语义路径）")
        XCTAssertTrue(advertised.contains(PasteboardTypes.legacyFilenames.rawValue),
                      "advertised types \(advertised) 应含 Chromium 文件名列表")
        XCTAssertFalse(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) },
                       "普通文件不得依赖真实拖拽会丢失附加类型的 promise provider")

        XCTAssertEqual(writer.pasteboardPropertyList(forType: .fileURL) as? String,
                       "file:///tmp/report.pdf")
        XCTAssertEqual(
            writer.pasteboardPropertyList(forType: PasteboardTypes.legacyFilenames) as? [String],
            ["/tmp/report.pdf"]
        )
    }

    func testFolderItem_writerAdvertisesDirectFileRepresentations() throws {
        let item = ShelfItem(kind: .folder, path: "/tmp/docs", displayName: "docs")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        XCTAssertNotNil(writer as? DirectFilePasteboardWriter)
        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(UTType.fileURL.identifier))
        XCTAssertTrue(advertised.contains(PasteboardTypes.legacyFilenames.rawValue))
        XCTAssertFalse(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
    }

    func testImageItem_writerAdvertisesDirectFileRepresentationsAndTIFF() throws {
        let item = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        XCTAssertNotNil(writer as? DirectFilePasteboardWriter)
        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(UTType.fileURL.identifier))
        XCTAssertTrue(advertised.contains(PasteboardTypes.legacyFilenames.rawValue))
        XCTAssertFalse(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
        XCTAssertTrue(advertised.contains(UTType.tiff.identifier),
                      "图片项应声明 public.tiff 位图回退")
    }

    // MARK: - Text item

    func testTextItem_advertisesPlainText() throws {
        let item = ShelfItem(kind: .text, displayName: "note", text: "hello shelf")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        // NSPasteboardItem can only be written to one pasteboard (writing a second time will throw an
        // exception) — write once, assert declared types on the same board with read-back data (read-back
        // path consistent with the target application).
        let pasteboard = writtenPasteboard(for: writer)
        let advertised = pasteboard.types?.map(\.rawValue) ?? []
        XCTAssertTrue(advertised.contains(UTType.utf8PlainText.identifier),
                      "advertised types \(advertised) 应含 public.utf8-plain-text")
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier))
        XCTAssertEqual(pasteboard.string(forType: .string), "hello shelf")
    }

    // MARK: - URL item

    func testURLItem_advertisesURLAndText_butNotFileURL() throws {
        let item = ShelfItem(kind: .url, displayName: "Apple", urlString: "https://www.apple.com")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let pasteboard = writtenPasteboard(for: writer)
        let advertised = pasteboard.types?.map(\.rawValue) ?? []
        XCTAssertTrue(advertised.contains(UTType.url.identifier))
        XCTAssertTrue(advertised.contains(UTType.utf8PlainText.identifier))
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier),
                       "web URL 不得连带声明 public.file-url（错误表示）")
        // Read-back path consistent with the target application (NSURL reading + text fallback).
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.url), "https://www.apple.com")
        XCTAssertEqual(pasteboard.string(forType: .string), "https://www.apple.com")
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
        XCTAssertEqual(urls, [URL(string: "https://www.apple.com")!])
    }

    // MARK: - F-05 Cut item: advertise only promise types

    func testCutItem_writerAdvertisesPromiseOnly_noFileURL() throws {
        var item = ShelfItem(kind: .file, path: "/tmp/report.pdf", displayName: "report.pdf")
        item.isCut = true
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let provider = try XCTUnwrap(writer as? FilePromiseProvider,
                                     "托管剪切项必须使用可确认落盘的 promise provider")
        XCTAssertEqual(provider.fileType, DragPayloadBuilder.promisedFileType(for: item))
        let advertised = advertisedTypes(of: writer)
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier),
                       "剪切项不得广告 public.file-url（否则 Finder 直读路径绕过交付确认）：\(advertised)")
        XCTAssertFalse(advertised.contains(PasteboardTypes.legacyFilenames.rawValue),
                       "剪切项不得通过 legacy 路径绕过交付确认")
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes
        XCTAssertTrue(advertised.contains { promiseTypes.contains($0) },
                      "剪切项必须保留 promise 类型（一切目的地必经 promise 写入）：\(advertised)")
        // fileURL representation does not produce data (double defense: not declared, and request also
        // returns nil).
        XCTAssertNil(writer.pasteboardPropertyList(forType: .fileURL))
    }

    func testCutImageItem_noTiffFallbackEither() throws {
        var item = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        item.isCut = true
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let advertised = advertisedTypes(of: writer)
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier))
        XCTAssertFalse(advertised.contains(UTType.tiff.identifier),
                       "剪切图片项不挂 tiff 位图回退（位图目标无法确认交付）")
        XCTAssertTrue(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
    }

    func testTutorialFileWriterCarriesPrivateTokenAlongsideRealFileRepresentations() throws {
        let item = ShelfItem(kind: .file,
                             path: "/tmp/OpenYoink 练习文件.txt",
                             displayName: "OpenYoink 练习文件.txt")
        let token = UUID().uuidString
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(
            for: item,
            bookmarkService: bookmarkService,
            tutorialSessionToken: token
        ))

        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(PasteboardTypes.fileURL.rawValue))
        XCTAssertTrue(advertised.contains(PasteboardTypes.legacyFilenames.rawValue))
        XCTAssertTrue(advertised.contains(PasteboardTypes.tutorialSession.rawValue))
        XCTAssertFalse(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
        XCTAssertNotNil(writer as? DirectFilePasteboardWriter)
        XCTAssertEqual(writer.pasteboardPropertyList(forType: PasteboardTypes.tutorialSession) as? String,
                       token)
    }

    /// Delivery confirmation attachment: After the promise of the writer is written, the item id is
    /// reported by the sink.
    func testCutItem_deliverySink_reportsItemID() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let managedSource = directory.appendingPathComponent("cut.txt")
        try "cut content".write(to: managedSource, atomically: true, encoding: .utf8)
        var item = ShelfItem(kind: .file, path: managedSource.path, displayName: "cut.txt")
        item.isCut = true

        let deliveredID = Mutex<UUID?>(nil)
        let deliveredURL = Mutex<URL?>(nil)
        let sink = DeliverySink(
            promiseRequested: { _ in },
            delivered: { id, url in
                deliveredID.withLock { $0 = id }
                deliveredURL.withLock { $0 = url }
            },
            failed: { _ in XCTFail("写入应成功") }
        )
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(
            for: item, bookmarkService: bookmarkService, delivery: sink))
        let provider = try XCTUnwrap(writer as? FilePromiseProvider)
        let destination = directory.appendingPathComponent("delivered/cut.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let completionError = Mutex<Error??>(nil)
        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNil(try XCTUnwrap(completionError.withLock { $0 }))
        XCTAssertEqual(deliveredID.withLock { $0 }, item.id)
        XCTAssertEqual(deliveredURL.withLock { $0 }, destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "cut content")
    }

    // MARK: - Unconstructable item

    func testInvalidItems_returnNilWriter() {
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .text, displayName: "empty"), // No text
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .url, displayName: "no url"), // No urlString
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .url, displayName: "bad", urlString: "ht tp://bad url"), // Invalid URL
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .file, displayName: "ghost"), // No path
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: makeItem(kind: .stack), // Stack not expanded
            bookmarkService: bookmarkService))
    }

    // MARK: - NSDraggingItem assembly (multiple selection / stack)

    func testMakeDraggingItems_multiSelection_producesOnePerItem() {
        let items = [
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .text, displayName: "b", text: "b"),
            ShelfItem(kind: .url, displayName: "c", urlString: "https://c.example.com"),
        ]
        let frame = NSRect(x: 0, y: 0, width: 88, height: 100)

        let draggingItems = DragPayloadBuilder.makeDraggingItems(for: items, frame: frame, bookmarkService: bookmarkService)

        XCTAssertEqual(draggingItems.count, 3)
        for (_, draggingItem) in draggingItems {
            XCTAssertEqual(draggingItem.draggingFrame, frame)
        }
    }

    func testMakeDraggingItems_stackExpandsToChildren() {
        let stack = ShelfItem(kind: .stack, displayName: "s", children: [
            ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png"),
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .url, displayName: "c", urlString: "https://c.example.com"),
        ])

        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: [stack], frame: NSRect(x: 0, y: 0, width: 88, height: 100), bookmarkService: bookmarkService)

        XCTAssertEqual(draggingItems.count, 3, "stack 拖出 = 其全部子项")
    }

    func testMakeDraggingItems_skipsUnbuildableItems() {
        let items = [
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .text, displayName: "empty"), // No text → nil writer
        ]
        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: items, frame: NSRect(x: 0, y: 0, width: 88, height: 100), bookmarkService: bookmarkService)
        XCTAssertEqual(draggingItems.count, 1)
    }
}
