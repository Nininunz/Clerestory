import AppKit
import XCTest
@testable import OpenYoink

/// Task one 'Universal Drag In' fallback chain unit test: Main chain (promise→fileURL→image→url→text) all
/// zero output,
/// walk through a(uri-list)→b(only HTML/RTF)→c(general data materialization)→d(string fallback) branches
/// per pasteboard item;
/// all failures → notice prompt + do not accept drag and drop.
///
/// Use a vCard and an unknown binary item to verify that fallback import handles each item independently.
/// The separate testImport_fileURLAndText_fileURLWins assertion covers the primary path, where file URLs
/// take precedence over text on the same pasteboard.
@MainActor
final class DropImportFallbackTests: XCTestCase {
    /// Same fixtures pattern as DropImportCoordinatorTests: in-place construction, defer cleanup.
    @MainActor
    private struct Context {
        let bookmarkService = BookmarkService()
        let tempFileService: TempFileService
        let noticeCenter = ShelfNoticeModel()
        let coordinator: DropImportCoordinator
        var temporaryURLs: [URL] = []

        init() {
            let materializedDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-Materialized-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: materializedDir)
            coordinator = DropImportCoordinator(bookmarkService: bookmarkService,
                                                tempFileService: tempFileService,
                                                noticeCenter: noticeCenter)
            temporaryURLs.append(materializedDir)
        }

        func cleanup() {
            bookmarkService.stopAccessingAll()
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func makeContext() -> Context { Context() }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
    }

    private func T(_ raw: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(raw)
    }

    private func ignoringAsyncItems() -> @MainActor (ShelfItem) -> Void {
        { _ in XCTFail("no async materialization expected for this pasteboard") }
    }

    // MARK: - Branch b: Only HTML / Only RTF

    /// Only HTML (no plain text —— main chain text phase can't read it): materialized as .html file item,
    /// displayName uses NSAttributedString-extracted plain text first line, disk content is original text.
    func testFallback_htmlOnlyDrop_materializesHTMLFileItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let html = Data("<p>Hello <b>HTML</b></p><p>second</p>".utf8)
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.html], owner: nil)
        pasteboard.setData(html, forType: PasteboardTypes.html)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.pendingMaterializations, 0)
        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, "Hello HTML.html")
        XCTAssertNotNil(item.bookmark)
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix(context.tempFileService.directoryURL.path))
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "html")
        // Disk content remains unchanged —— dragging to Pages/browser remains rich text.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), html)
    }

    /// Only RTF and system bridge plain-text conversion is unavailable (probe: valid RTF is automatically
    /// bridged to utf8/utf16 plain-text flavor by pasteboard, producing text item in main chain text phase
    /// —— that's existing behavior; this case covers the b branch when bridging fails): materialized as
    /// .rtf file item, use localized fallback name if plain text can't be extracted.
    func testFallback_rtfWithoutPlainTextBridge_materializesRTFFileItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let rtf = Data("not really rtf".utf8) // Invalid RTF: bridging conversion fails during reading (probe confirmed)
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.rtf], owner: nil)
        pasteboard.setData(rtf, forType: PasteboardTypes.rtf)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, String(localized: "Dropped RTF") + ".rtf")
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "rtf")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), rtf)
    }

    /// HTML can't extract plain text (pure tags/images) falls back to localized fallback name.
    func testFallback_htmlWithoutExtractableText_usesLocalizedFallbackName() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.html], owner: nil)
        pasteboard.setData(Data(#"<img src="x.png">"#.utf8), forType: PasteboardTypes.html)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.displayName, String(localized: "Dropped HTML") + ".html")
    }

    // MARK: - Branch a: text/uri-list

    /// uri-list (pasteboard-level flavor; # comment lines and empty lines are skipped, one URL item per
    /// line). Additional validation for deduplication: item-level dyn.* bridging projection won't produce
    /// duplicate text items through d branch.
    func testFallback_uriList_producesURLItemPerLine() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.uriList], owner: nil)
        pasteboard.setString("https://a.com/\r\n# a comment\r\n\r\nhttps://b.com/path",
                             forType: PasteboardTypes.uriList)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.pendingMaterializations, 0)
        XCTAssertEqual(result.items.map(\.urlString), ["https://a.com/", "https://b.com/path"])
        XCTAssertEqual(result.items.map(\.kind), [.url, .url])
        XCTAssertEqual(result.items.map(\.displayName), ["a.com", "b.com"])
    }

    // MARK: - Branch c: General data materialization

    /// vCard data: tier1 (specific UTI with preferredFilenameExtension) → .vcf file item.
    func testFallback_vCardData_materializesVCFFileItem() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let vcf = Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Test Person\r\nEND:VCARD\r\n".utf8)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(vcf, forType: T("public.vcard"))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([pasteboardItem])

        let itemReady = expectation(description: "vCard materialized")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .file)
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "vcf")
        XCTAssertTrue(item.displayName.hasSuffix(".vcf"))
        XCTAssertNotNil(item.bookmark)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), vcf)
    }

    /// Undeclared custom type (UTType resolves to nil) → tier3, materialized as .dat, content preserved.
    /// Payload contains NUL/control bytes: ensure that even `string(forType:)`'s lossy decoding can't pass
    /// `isMeaningfulText` threshold (probe: pure printable bytes are decoded into string).
    func testFallback_unknownBinaryData_materializesDatFileItem() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let blob = Data([0x00, 0xFF, 0x01, 0xFE])
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([T("com.openyoink.test.unknown-blob")], owner: nil)
        pasteboard.setData(blob, forType: T("com.openyoink.test.unknown-blob"))

        let itemReady = expectation(description: "blob materialized")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .file)
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "dat")
        XCTAssertEqual(item.displayName, String(localized: "Dropped Item") + ".dat")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), blob)
    }

    // MARK: - Mixed multiple items (fallback chain processes each item independently)

    /// One vCard item + one unknown binary item: each goes through c branch for independent
    /// materialization, no interference.
    func testFallback_mixedFallbackItems_eachMaterializesIndependently() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let vcfItem = NSPasteboardItem()
        vcfItem.setData(Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:A\r\nEND:VCARD\r\n".utf8),
                        forType: T("public.vcard"))
        let blobItem = NSPasteboardItem()
        blobItem.setData(Data([0x00, 0x01, 0x02, 0x03]), forType: T("com.openyoink.test.unknown-blob"))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([vcfItem, blobItem])

        let allReady = expectation(description: "both materialized")
        allReady.expectedFulfillmentCount = 2
        var extensions: [String] = []
        let result = context.coordinator.importItems(from: pasteboard) { item in
            if let path = item.path {
                extensions.append(URL(fileURLWithPath: path).pathExtension)
            }
            allReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 2)
        await fulfillment(of: [allReady], timeout: 5)
        XCTAssertEqual(Set(extensions), ["vcf", "dat"])
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.phase, .delivered)
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.itemIDs.count, 2)
    }

    // MARK: - Branch d: String fallback

    /// Item declared a strange text class type (main chain .string can't read): branch d takes the first
    /// type that can produce non-empty content via string(forType:).
    func testFallback_exoticStringType_producesTextItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("exotic payload", forType: T("public.utf8-external-plain-text"))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([pasteboardItem])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.text, "exotic payload")
        XCTAssertEqual(item.displayName, "exotic payload")
    }

    // MARK: - Branch e: zero content

    /// Declared a type but can't read any content: per-item logs (manual verification), zero output for
    /// the whole →
    /// No drag and drop + notice prompt (dual-language key see Localizable.xcstrings).
    func testFallback_itemWithNoReadableContent_isUnhandled_andShowsNotice() {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([T("com.openyoink.test.void")], owner: nil)
        // Write no data —— zero content item.

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertFalse(result.handled)
        XCTAssertEqual(context.noticeCenter.message,
                       String(localized: "That content can't be added to the shelf yet."))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
