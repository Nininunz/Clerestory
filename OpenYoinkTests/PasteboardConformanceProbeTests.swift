import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenYoink

/// Drag-in conformance probe (Task 1) —— solidify the system behaviors relied upon when registering the
/// `dragInTypes` design into repeatable assertions. These behaviors were previously only known through
/// documentation 'guesswork', now verified by native (macOS 26) testing:
///
/// 1. `availableType(from:)` follows UTI conformance and includes convertible formats such as PNG to TIFF.
/// 2. Legacy types such as text/uri-list and NSFilenamesPboardType can bridge to dyn.* types that match
/// public.data.
/// 3. Generic registration cannot match undeclared custom identifiers because their conformance is
/// unknown.
/// 4. Register `public.calendar-event` and `public.email-message` explicitly. Neither matches the data or
/// item hierarchy or provides a preferred filename extension, so materialization uses
/// `PasteboardTypes.wellKnownExtensionFallback`.
///
/// Testing `registerForDraggedTypes` matching requires a real drag session. These tests cover the same UTI
/// conformance rules as observed through the pasteboard.
final class PasteboardConformanceProbeTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenYoinkProbeTests-\(UUID().uuidString)"))
    }

    private func T(_ raw: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(raw)
    }

    // MARK: - 1. availableType matching through conformance

    func testProbe_declaredPNG_matchesDataImageAndConvertibleTIFF() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(Data([0x89, 0x50]), forType: .png)

        XCTAssertNotNil(pasteboard.availableType(from: [T("public.data")]))
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.image")]))
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.item")]))
        // Convertible formats can match. A declared PNG can also provide TIFF.
        XCTAssertNotNil(pasteboard.availableType(from: [.tiff]))
        // Unrelated type families do not match.
        XCTAssertNil(pasteboard.availableType(from: [.string]))
    }

    func testProbe_declaredPlainText_matchesTextSupertypes() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("hello", forType: .string)

        XCTAssertNotNil(pasteboard.availableType(from: [T("public.text")]))
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.plain-text")]))
    }

    /// Conformance matching is one-way. Declaring a parent type does not match a query for a child type.
    func testProbe_expansionIsDirectional_urlDoesNotMatchFileURL() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([T("public.url")], owner: nil)
        pasteboard.setString("https://example.com", forType: T("public.url"))

        XCTAssertNotNil(pasteboard.availableType(from: [T("public.item")]))
        XCTAssertNil(pasteboard.availableType(from: [.fileURL]))
    }

    // MARK: - 2. Dynamic bridging of legacy pasteboard types

    func testProbe_uriListFlavor_bridgesToDynamicTypeMatchingData_andReadsAtPasteboardLevel() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.uriList], owner: nil)
        pasteboard.setString("https://example.com/", forType: PasteboardTypes.uriList)

        // The pasteboard type list preserves the original flavor string.
        XCTAssertTrue(pasteboard.types?.contains(PasteboardTypes.uriList) ?? false)
        // Bridged dyn.* types match public.data, so generic registration can pick them up.
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.data")]))
        // The original flavor can be read from the pasteboard as a whole. Individual items behave
        // differently, as the next test shows.
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.uriList), "https://example.com/")
        // Item level only has dyn.* bridge type: reading by original flavor is not possible.
        let item = pasteboard.pasteboardItems?.first
        XCTAssertEqual(item?.string(forType: PasteboardTypes.uriList), nil)
    }

    // MARK: - 3. Coverage boundary: undeclared custom identifiers are not hit by generics.

    func testProbe_undeclaredReverseDNSIdentifier_matchesNothingGeneric() {
        let custom = T("com.openyoink.probe.undeclared-\(UUID().uuidString)")
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([custom], owner: nil)
        pasteboard.setData(Data([1, 2, 3]), forType: custom)

        XCTAssertNil(pasteboard.availableType(from: [T("public.data")]))
        XCTAssertNil(pasteboard.availableType(from: [T("public.item")]))
        XCTAssertNil(pasteboard.availableType(from: [T("public.content")]))
    }

    // MARK: - 4. The reason for types that must be explicitly registered and the fallback with extension
    // names.

    func testProbe_calendarEventAndEmailMessage_haveNoDataConformance() {
        // If the system completes their conformance in the future, generic registration can cover it,
        // explicit registration becomes redundant but harmless —— at that time, we can tighten this
        // assertion.
        XCTAssertFalse(UTType.calendarEvent.conforms(to: .data))
        XCTAssertFalse(UTType.calendarEvent.conforms(to: .item))
        XCTAssertFalse(UTType.emailMessage.conforms(to: .data))
    }

    func testProbe_materializationExtensionFacts() {
        XCTAssertEqual(UTType.vCard.preferredFilenameExtension, "vcf")
        // No extension name tag —— the existence reason of `wellKnownExtensionFallback`.
        XCTAssertNil(UTType.calendarEvent.preferredFilenameExtension)
        XCTAssertNil(UTType.emailMessage.preferredFilenameExtension)
        XCTAssertNotNil(UTType.vCard.localizedDescription)
    }

    /// `UTType(_:)` returns nil for non-UTI strings and undeclared identifiers —— cannot rely on
    /// UTType to determine conformance for arbitrary pasteboard type strings.
    func testProbe_uttypeInit_nilForNonUTIAndUndeclaredIdentifiers() {
        XCTAssertNil(UTType("text/uri-list"))
        XCTAssertNil(UTType("com.openyoink.probe.undeclared-\(UUID().uuidString)"))
        XCTAssertNil(UTType("NSFilenamesPboardType"))
        // Contrast: declared types are parsed normally and conformance is searchable.
        XCTAssertTrue(UTType("com.adobe.pdf")?.conforms(to: .data) ?? false)
    }

    // MARK: - 5. The basis of known gaps: html-only item cannot read plain text.

    func testProbe_htmlOnlyItem_hasNoPlainTextButReadableHTMLData() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.html], owner: nil)
        pasteboard.setData(Data("<b>hi</b>".utf8), forType: PasteboardTypes.html)

        let item = pasteboard.pasteboardItems?.first
        XCTAssertNil(item?.string(forType: .string)) // Main chain text phase cannot read → existence reason of fallback branch b.
        XCTAssertNotNil(item?.data(forType: PasteboardTypes.html))
    }
}
