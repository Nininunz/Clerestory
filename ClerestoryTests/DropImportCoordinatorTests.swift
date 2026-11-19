import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Clerestory

/// Verify import classification, ordering, and item fields. Feed file URLs, text, URLs, and image data
/// through `NSPasteboard(name:)` and inspect the resulting ShelfItems.
///
/// file promise path cannot be unit tested: `NSFilePromiseReceiver` can only be created by the source app
/// of a real drag session
/// (cannot be instantiated in tests), this path is listed in manual regression checklist.
@MainActor
final class DropImportCoordinatorTests: XCTestCase {
    func testReleasedDuplicateDropShowsNoticeAndStillAddsNewFiles() {
        let context = makeContext()
        defer { context.cleanup() }
        let existing = ShelfItem(kind: .file, path: "/tmp/existing.txt", displayName: "existing.txt")
        let fresh = ShelfItem(kind: .file, path: "/tmp/new.txt", displayName: "new.txt")
        let store = ShelfStore(items: [existing])
        XCTAssertNil(context.messages.current)
        context.coordinator.addDroppedItems([existing, fresh], to: store)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(context.messages.current?.notice, ShelfNotice.alreadyOnShelf.notice)
        context.coordinator.messenger.post(.reconnected)
        context.coordinator.addDroppedItems([], to: store)
        XCTAssertEqual(context.messages.current?.notice, ShelfNotice.reconnected.notice,
                       "Old duplicate state must not produce another notice")
        context.coordinator.addDroppedItems([existing], to: store)
        XCTAssertEqual(context.messages.current?.notice, ShelfNotice.alreadyOnShelf.notice)
        XCTAssertEqual(store.items.count, 2)
    }

    /// Fixtures for each test case: Construct in place, cleanup() at the end of the test case (via defer).
    /// Do not use setUp/tearDown —— these overrides in XCTestCase are non-isolated,
    /// accessing isolated state in @MainActor test class will generate warnings (consistent with defer
    /// cleanup pattern in ShelfStoreTests).
    @MainActor
    private struct Context {
        let bookmarkService = BookmarkService()
        let tempFileService: TempFileService
        let messages = IslandMessageCenter()
        let coordinator: DropImportCoordinator
        var temporaryURLs: [URL] = []

        init() {
            let materializedDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClerestoryTests-Materialized-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: materializedDir)
            coordinator = DropImportCoordinator(bookmarkService: bookmarkService, tempFileService: tempFileService,
                                                messenger: messages.messenger(for: .shelf))
            temporaryURLs.append(materializedDir)
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

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("ClerestoryTests-\(UUID().uuidString)"))
    }

    private func makeTempFile(in context: inout Context, named name: String = "sample.txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClerestoryTests-\(UUID().uuidString)-\(name)")
        try "sample content".write(to: url, atomically: true, encoding: .utf8)
        context.temporaryURLs.append(url)
        return url
    }

    private func makeTempDirectory(in context: inout Context) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClerestoryTests-\(UUID().uuidString)-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        context.temporaryURLs.append(url)
        return url
    }

    /// 1×1 PNG.
    private func makePNGData() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Unused asynchronous callback in this step.
    private func ignoringAsyncItems() -> @MainActor (ShelfItem) -> Void {
        { _ in XCTFail("no async materialization expected for this pasteboard") }
    }

    // MARK: - fileURL

    func testImport_fileURL_producesFileItemWithBookmark() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context, named: "notes.txt")
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([fileURL as NSURL])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.pendingMaterializations, 0)
        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.path, fileURL.path)
        XCTAssertEqual(item.displayName, fileURL.lastPathComponent)
        XCTAssertNotNil(item.bookmark)
        XCTAssertNil(item.sourceApp) // v1: Cross-app drag source uniformly set to nil
    }

    func testImport_directoryURL_producesFolderItem_notExpanded() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let folderURL = try makeTempDirectory(in: &context)
        // Place a file in a folder, verify v1 does not expand recursively.
        try "inner".write(to: folderURL.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([folderURL as NSURL])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .folder)
        XCTAssertNil(item.children)
    }

    func testImport_imageFileURL_producesImageKind() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClerestoryTests-\(UUID().uuidString)-pic.png")
        try makePNGData().write(to: imageURL)
        context.temporaryURLs.append(imageURL)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([imageURL as NSURL])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(try XCTUnwrap(result.items.only).kind, .image)
    }

    func testImport_multipleFileURLs_preservesOrder() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let first = try makeTempFile(in: &context, named: "a.txt")
        let second = try makeTempFile(in: &context, named: "b.txt")
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([first as NSURL, second as NSURL])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.items.map(\.displayName), [first.lastPathComponent, second.lastPathComponent])
    }

    func testTutorialTokenAllowsOnlyCurrentInternalSessionAndReportsRealImportedItem() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context, named: OnboardingSessionStore.tutorialFileName)
        let token = UUID().uuidString
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.addTypes([PasteboardTypes.tutorialSession], owner: nil)
        pasteboard.setString(token, forType: PasteboardTypes.tutorialSession)
        context.coordinator.isActiveTutorialToken = { $0 == token }

        XCTAssertTrue(context.coordinator.acceptsInternalTutorialDrag(pasteboard))
        var callback: (String, [ShelfItem])?
        context.coordinator.onTutorialItemsImported = { callback = ($0, $1) }
        let result = context.coordinator.importItems(from: pasteboard,
                                                     onAsyncItemReady: ignoringAsyncItems())
        context.coordinator.noteSynchronousTutorialImport(from: pasteboard,
                                                          items: result.items)

        XCTAssertEqual(callback?.0, token)
        XCTAssertEqual(callback?.1.only?.path, fileURL.path)

        context.coordinator.isActiveTutorialToken = { _ in false }
        XCTAssertFalse(context.coordinator.acceptsInternalTutorialDrag(pasteboard))
    }

    // MARK: - File promise kind inference

    func testInferFileKind_actualExtensionWinsOverReceiverTypeCollection() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let textURL = try makeTempFile(in: &context, named: "mixed-promise.txt")

        let kind = DropImportCoordinator.inferFileKind(
            for: textURL,
            promisedTypeIdentifiers: [UTType.png.identifier, UTType.plainText.identifier]
        )

        XCTAssertEqual(kind, .file)
    }

    func testInferFileKind_singlePromisedImageType_isFallbackForExtensionlessFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context, named: "extensionless")

        XCTAssertEqual(
            DropImportCoordinator.inferFileKind(
                for: fileURL,
                promisedTypeIdentifiers: [UTType.png.identifier]
            ),
            .image
        )
    }

    func testInferFileKind_mixedPromisedTypes_doNotMisclassifyExtensionlessFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context, named: "extensionless")

        XCTAssertEqual(
            DropImportCoordinator.inferFileKind(
                for: fileURL,
                promisedTypeIdentifiers: [UTType.png.identifier, UTType.plainText.identifier]
            ),
            .file
        )
    }

    func testInferFileKind_actualDirectoryWinsOverPromisedImageType() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let folderURL = try makeTempDirectory(in: &context)

        XCTAssertEqual(
            DropImportCoordinator.inferFileKind(
                for: folderURL,
                promisedTypeIdentifiers: [UTType.png.identifier]
            ),
            .folder
        )
    }

    // MARK: - Priority

    /// When fileURL and text exist together, take fileURL in F-03 order, text is ignored.
    func testImport_fileURLAndText_fileURLWins() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([fileURL as NSURL, "dragged text" as NSString])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertNil(item.text)
    }

    // MARK: - Image data

    /// PNG bitmap without file URL: Asynchronously materialized to TempFileService directory, kind =
    /// .image.
    func testImport_pngData_materializesImageItem() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pngData = try makePNGData()
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(pngData, forType: .png)

        let itemReady = expectation(description: "image item materialized")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.displayName, DropImportCoordinator.materializedImageDisplayName)
        XCTAssertNotNil(item.bookmark)
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix(context.tempFileService.directoryURL.path))
        // Content on disk matches the original PNG.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), pngData)
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.phase, .delivered)
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.itemIDs, [item.id])
    }

    /// JPEG image data is stored as dropped, with its own extension.
    func testImport_jpegData_keepsOriginalBytes() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try makePNGData()))
        let jpegData = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.jpeg], owner: nil)
        pasteboard.setData(jpegData, forType: PasteboardTypes.jpeg)

        let itemReady = expectation(description: "JPEG item materialized")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }

        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)
        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.displayName, DropImportCoordinator.materializedJPEGDisplayName)
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), jpegData)
    }

    /// An item carrying both JPEG data and a link becomes an image, not a link
    /// (ported from MuQY1818/OpenYoink@219e1d1).
    func testImport_jpegDataWinsOverLinkOnTheSameItem() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try makePNGData()))
        let jpegData = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.jpeg, PasteboardTypes.url], owner: nil)
        pasteboard.setData(jpegData, forType: PasteboardTypes.jpeg)
        pasteboard.setString("https://example.com/photo.jpg", forType: PasteboardTypes.url)

        let itemReady = expectation(description: "image wins over link")
        let result = context.coordinator.importItems(from: pasteboard) { item in
            XCTAssertEqual(item.kind, .image)
            itemReady.fulfill()
        }
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)
    }

    /// A JPEG that also promises TIFF (a JPEG history entry copied back) keeps its JPEG bytes, and
    /// the TIFF is never built.
    func testImport_jpegWithPromisedTIFF_keepsJPEGAndNeverBuildsTIFF() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try makePNGData()))
        let jpegData = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let provider = CountingTIFFProvider()
        let item = NSPasteboardItem()
        item.setData(jpegData, forType: PasteboardTypes.jpeg)
        item.setDataProvider(provider, forTypes: [.tiff])
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let itemReady = expectation(description: "JPEG kept")
        var received: ShelfItem?
        _ = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }
        await fulfillment(of: [itemReady], timeout: 5)
        let path = try XCTUnwrap(received?.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), jpegData)
        XCTAssertEqual(provider.requests, 0, "The promised TIFF must not be requested")
    }

    /// An empty PNG next to a valid TIFF on the same item uses the TIFF.
    func testImport_emptyPNGWithValidTIFF_usesTIFF() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: try makePNGData())?.tiffRepresentation)
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(Data(), forType: .png)
        pasteboard.setData(tiff, forType: .tiff)

        let itemReady = expectation(description: "TIFF used")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)
        XCTAssertEqual(received?.kind, .image)
    }

    /// An empty image representation is skipped, so the drop falls through to the text instead of
    /// failing (ported from MuQY1818/OpenYoink@219e1d1).
    func testImport_emptyImageData_fallsThroughToText() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png, .string], owner: nil)
        pasteboard.setData(Data(), forType: .png)
        pasteboard.setString("hello", forType: .string)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.pendingMaterializations, 0)
        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .text)
    }

    // MARK: - Add Clipboard Image to Shelf (ported from MuQY1818/OpenYoink@219e1d1)

    func testClipboardImage_usesImageEvenWhenOtherTypesArePresent() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        let pngData = try makePNGData()
        let mixed = NSPasteboardItem()
        mixed.setString("https://example.com/image", forType: .URL)
        mixed.setData(pngData, forType: .png)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([mixed]))

        let itemReady = expectation(description: "clipboard image added")
        var received: ShelfItem?
        let count = context.coordinator.importClipboardImages(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }
        XCTAssertEqual(count, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.displayName, String(localized: "Clipboard Image.png"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(item.path))), pngData)
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.phase, .delivered)
    }

    func testClipboardImage_doesNotFallBackToFileURLOrText() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let file = try makeTempFile(in: &context, named: "notes.txt")
        let pasteboard = makePasteboard()
        let text = NSPasteboardItem()
        text.setString("copied text", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([file as NSURL, text]))
        context.coordinator.onImportHandled = { XCTFail("nothing should be imported") }

        XCTAssertEqual(context.coordinator.importClipboardImages(from: pasteboard,
                                                                 onItemReady: ignoringAsyncItems()), 0)
        XCTAssertNil(context.coordinator.transferStore.currentTask)
    }

    /// Copying a file in Finder can carry its icon as a bitmap; that is not an image to add.
    func testClipboardImage_skipsCopiedFileIcons() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        let fileCopy = NSPasteboardItem()
        fileCopy.setString(URL(fileURLWithPath: "/tmp/photo.png").absoluteString, forType: PasteboardTypes.fileURL)
        fileCopy.setData(try makePNGData(), forType: .png)
        fileCopy.setData(Data([0x69, 0x63, 0x6E, 0x73]), forType: .init("com.apple.icns"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileCopy]))

        XCTAssertEqual(context.coordinator.importClipboardImages(from: pasteboard,
                                                                 onItemReady: ignoringAsyncItems()), 0)
        XCTAssertNil(context.coordinator.transferStore.currentTask)
    }

    // MARK: - URL

    func testImport_publicURL_producesURLItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.url], owner: nil)
        pasteboard.setString("https://www.apple.com", forType: PasteboardTypes.url)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .url)
        XCTAssertEqual(item.urlString, "https://www.apple.com")
        XCTAssertEqual(item.displayName, "www.apple.com")
        XCTAssertNil(item.path)
        XCTAssertNil(item.bookmark)
    }

    // MARK: - Text

    func testImport_plainText_producesTextItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.writeObjects(["Hello shelf" as NSString])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.text, "Hello shelf")
        XCTAssertEqual(item.displayName, "Hello shelf")
    }

    func testImport_multilineText_displayNameUsesFirstLineTruncated() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let longLine = String(repeating: "x", count: 80)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects(["\(longLine)\nsecond line" as NSString])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let displayName = try XCTUnwrap(result.items.only?.displayName)
        XCTAssertTrue(displayName.hasSuffix("…"))
        XCTAssertEqual(displayName.count, 61)
    }

    // MARK: - Unhandled

    func testImport_emptyPasteboard_isUnhandled() {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())
        XCTAssertFalse(result.handled)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

/// Counts requests for a promised TIFF, to prove the importer never asks for it.
private final class CountingTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var requests = 0

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        requests += 1
    }
}
