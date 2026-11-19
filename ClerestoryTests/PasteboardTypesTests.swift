import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Clerestory

/// PasteboardTypes capability detection and priority (pure function, no pasteboard instance construction).
final class PasteboardTypesTests: XCTestCase {
    func testNativeApproachZoneAcceptsFilesAndTextButRejectsWindowDragsAndBrowserURLs() {
        for types: [NSPasteboard.PasteboardType] in [[], [.URL], [.png], [.string, .URL], [.string, .png], [PasteboardTypes.uriList, .string], [.init("com.example.window-drag")]] {
            XCTAssertFalse(DragContainerView.acceptsApproachPayload(types, isApproachZone: true))
        }
        for type in PasteboardTypes.textTypes {
            XCTAssertTrue(DragContainerView.acceptsApproachPayload([type], isApproachZone: true))
        }
        XCTAssertTrue(DragContainerView.acceptsApproachPayload([.string, .html, .rtf], isApproachZone: true))
        XCTAssertTrue(DragContainerView.acceptsApproachPayload([.fileURL], isApproachZone: true))
        XCTAssertTrue(DragContainerView.acceptsApproachPayload(PasteboardTypes.filePromiseTypes, isApproachZone: true))
        XCTAssertTrue(DragContainerView.acceptsApproachPayload([.string], isApproachZone: false))
    }

    // MARK: - Category detection

    func testSupports_fileURL() {
        XCTAssertTrue(PasteboardTypes.supports(.fileURL, types: [.fileURL]))
        XCTAssertFalse(PasteboardTypes.supports(.fileURL, types: [.string]))
    }

    func testSupports_textCoversPlainHTMLRTF() {
        for type in [PasteboardTypes.plainText, .html, .rtf] {
            XCTAssertTrue(PasteboardTypes.supports(.text, types: [type]), "\(type.rawValue) should count as text")
        }
        XCTAssertFalse(PasteboardTypes.supports(.text, types: [.png]))
    }

    func testSupports_imageCoversPNGTIFFGeneric() {
        for type in PasteboardTypes.imageTypes {
            XCTAssertTrue(PasteboardTypes.supports(.image, types: [type]), "\(type.rawValue) should count as image")
        }
    }

    func testSupports_url() {
        XCTAssertTrue(PasteboardTypes.supports(.url, types: [PasteboardTypes.url]))
        XCTAssertFalse(PasteboardTypes.supports(.url, types: [.string]))
    }

    func testSupports_filePromise() {
        XCTAssertFalse(PasteboardTypes.filePromiseTypes.isEmpty)
        XCTAssertTrue(PasteboardTypes.supports(.filePromise, types: PasteboardTypes.filePromiseTypes))
        XCTAssertFalse(PasteboardTypes.supports(.filePromise, types: [.fileURL]))
    }

    // MARK: - Edge auto-reveal file gate

    func testHasFileDragContent_acceptsFileURLAndFilePromise() {
        XCTAssertTrue(PasteboardTypes.hasFileDragContent(in: [.fileURL]))
        XCTAssertTrue(PasteboardTypes.hasFileDragContent(
            in: PasteboardTypes.filePromiseTypes
        ))
        XCTAssertTrue(PasteboardTypes.hasFileDragContent(
            in: [.string, .fileURL, PasteboardTypes.url]
        ))
    }

    func testHasFileDragContent_rejectsBrowserTabAndNonFilePayloads() {
        XCTAssertFalse(PasteboardTypes.hasFileDragContent(
            in: [PasteboardTypes.url, .string]
        ))
        XCTAssertFalse(PasteboardTypes.hasFileDragContent(
            in: [.png, .tiff, PasteboardTypes.image]
        ))
        XCTAssertFalse(PasteboardTypes.hasFileDragContent(
            in: [.html, .rtf, PasteboardTypes.plainText]
        ))
        XCTAssertFalse(PasteboardTypes.hasFileDragContent(
            in: [NSPasteboard.PasteboardType("com.example.browser-tab")]
        ))
        XCTAssertFalse(PasteboardTypes.hasFileDragContent(in: []))
    }

    // MARK: - Priority (F-03: promise → fileURL → image → url → text)

    func testPreferredCategory_promiseBeatsEverything() {
        let types = PasteboardTypes.filePromiseTypes + [.fileURL, .png, PasteboardTypes.url, .string]
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: types), .filePromise)
    }

    /// When text and fileURL are both present, fileURL is taken in order.
    func testPreferredCategory_fileURLBeatsText() {
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: [.string, .fileURL]), .fileURL)
    }

    func testPreferredCategory_imageBeatsURLAndText() {
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: [.string, PasteboardTypes.url, .tiff]), .image)
    }

    func testPreferredCategory_urlBeatsText() {
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: [.string, PasteboardTypes.url]), .url)
    }

    func testPreferredCategory_textIsLastResort() {
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: [.html, .rtf]), .text)
    }

    func testPreferredCategory_emptyOrUnknownTypes_returnsNil() {
        XCTAssertNil(PasteboardTypes.preferredCategory(in: []))
        XCTAssertNil(PasteboardTypes.preferredCategory(in: [NSPasteboard.PasteboardType("com.example.unknown")]))
    }

    // MARK: - Image type preference

    func testPreferredImageType_prefersPNGOverTIFF() {
        XCTAssertEqual(PasteboardTypes.preferredImageType(in: [.tiff, .png]), .png)
        XCTAssertEqual(PasteboardTypes.preferredImageType(in: [.tiff]), .tiff)
        XCTAssertNil(PasteboardTypes.preferredImageType(in: [.string]))
    }

    // MARK: - Registration set

    func testDragInTypes_coversAllCategories() {
        let registered = PasteboardTypes.dragInTypes
        for category in PasteboardTypes.Category.allCases {
            XCTAssertTrue(PasteboardTypes.supports(category, types: registered),
                          "dragInTypes should register \(category)")
        }
    }

    // MARK: - Task one: wide fallback registration and "Drop everything" determination.

    /// Registration list is relaxed: URL variants + specific types without conformance + generic fallbacks
    /// are all listed.
    func testDragInTypes_includesWideNetFallbacks() {
        let registered = PasteboardTypes.dragInTypes
        for type in [PasteboardTypes.text, PasteboardTypes.uriList, PasteboardTypes.vCard,
                     PasteboardTypes.calendarEvent, PasteboardTypes.emailMessage,
                     PasteboardTypes.data, PasteboardTypes.item, PasteboardTypes.content,
                     PasteboardTypes.fileContents] {
            XCTAssertTrue(registered.contains(type), "dragInTypes should register \(type.rawValue)")
        }
    }

    /// "Drop everything" semantic highlighting: declaring any type is accepted; zero types are rejected.
    func testHasImportableContent_acceptsAnythingWithDeclaredTypes() {
        XCTAssertFalse(PasteboardTypes.hasImportableContent(in: []))
        XCTAssertTrue(PasteboardTypes.hasImportableContent(in: [.string]))
        XCTAssertTrue(PasteboardTypes.hasImportableContent(in: [PasteboardTypes.uriList]))
        XCTAssertTrue(PasteboardTypes.hasImportableContent(
            in: [NSPasteboard.PasteboardType("com.example.unknown")]))
    }

    // MARK: - Task one: generalization of candidate selection (pure function).

    /// Types already handled by main chain or specialized branches are not entered into the candidate
    /// list.
    func testMaterializationCandidates_excludesHandledElsewhereTypes() {
        let handled: [NSPasteboard.PasteboardType] =
            [.fileURL, PasteboardTypes.url, .string, PasteboardTypes.html, PasteboardTypes.rtf]
            + [PasteboardTypes.uriList] + PasteboardTypes.filePromiseTypes
        XCTAssertTrue(PasteboardTypes.materializationCandidates(in: handled).isEmpty)
    }

    /// tier classification: specific UTI with extension → 1; specific UTI without extension → 2; undclared
    /// identifier / generic signal type → 3.
    func testMaterializationCandidates_tierAssignment() {
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [PasteboardTypes.vCard]),
                       [.init(type: PasteboardTypes.vCard, tier: 1)])
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [PasteboardTypes.calendarEvent]),
                       [.init(type: PasteboardTypes.calendarEvent, tier: 2)])
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [PasteboardTypes.emailMessage]),
                       [.init(type: PasteboardTypes.emailMessage, tier: 2)])
        let unknown = NSPasteboard.PasteboardType("com.clerestory.test.undeclared")
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [unknown]),
                       [.init(type: unknown, tier: 3)])
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [PasteboardTypes.data]),
                       [.init(type: PasteboardTypes.data, tier: 3)])
    }

    /// Sorting: tier1 has priority, items within the same tier maintain declaration order; text family
    /// (conforms to .text and no extension) are excluded —— handed over to the string fallback branch.
    func testMaterializationCandidates_orderingAndTextExclusion() {
        let unknown = NSPasteboard.PasteboardType("com.clerestory.test.undeclared")
        let utf16 = NSPasteboard.PasteboardType("public.utf16-plain-text")
        let candidates = PasteboardTypes.materializationCandidates(
            in: [unknown, PasteboardTypes.calendarEvent, PasteboardTypes.vCard, utf16])
        XCTAssertEqual(candidates, [.init(type: PasteboardTypes.vCard, tier: 1),
                                    .init(type: PasteboardTypes.calendarEvent, tier: 2),
                                    .init(type: unknown, tier: 3)])
    }

    // MARK: - Task 1: Materialize extension and display name

    func testMaterializationFileExtension_preferredThenKnownTableThenDat() {
        XCTAssertEqual(PasteboardTypes.materializationFileExtension(for: PasteboardTypes.vCard), "vcf")
        XCTAssertEqual(PasteboardTypes.materializationFileExtension(for: PasteboardTypes.calendarEvent), "ics")
        XCTAssertEqual(PasteboardTypes.materializationFileExtension(for: PasteboardTypes.emailMessage), "eml")
        let unknown = NSPasteboard.PasteboardType("com.clerestory.test.undeclared")
        XCTAssertEqual(PasteboardTypes.materializationFileExtension(for: unknown), "dat")
    }

    func testMaterializedDisplayBaseName_typeDescriptionOrLocalizedFallback() {
        XCTAssertEqual(PasteboardTypes.materializedDisplayBaseName(for: PasteboardTypes.vCard),
                       UTType.vCard.localizedDescription)
        let unknown = NSPasteboard.PasteboardType("com.clerestory.test.undeclared")
        XCTAssertEqual(PasteboardTypes.materializedDisplayBaseName(for: unknown),
                       String(localized: "Dropped Item"))
    }
}
