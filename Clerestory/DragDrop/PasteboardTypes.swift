import AppKit
import UniformTypeIdentifiers

/// Shared pasteboard type constants and capability probing for drag-in/drag-out.
///
/// All capability probing is pure functions (input type array, output category set), not touching specific
/// pasteboard instances, so they can be directly asserted in unit tests without constructing
/// real drag sessions. Processing order follows the research report F-03 and implementation plan §2.3:
/// file promise → fileURL → image data → URL → text; tasks are appended after with fallback chains
/// (URL variants → only HTML/RTF materialization → generic data materialization → string fallback,
/// see `DropImportCoordinator`), and the registration list is relaxed to "universal drag-in"
/// (see conformance probe conclusions for each type in `PasteboardConformanceProbeTests`
/// and the constant comments in this file).
enum PasteboardTypes {
    // MARK: - Type constants

    /// `public.file-url` —— File drag representation used by Finder and most apps.
    static let fileURL: NSPasteboard.PasteboardType = .fileURL
    /// Chromium's macOS file-upload drop path still reads the legacy
    /// filename-list flavor even when `public.file-url` is present. AppKit no
    /// longer exposes the deprecated constant to Swift, so keep the wire
    /// value local and advertise it only alongside a real direct file URL.
    static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    /// `public.utf8-plain-text`.
    static let plainText: NSPasteboard.PasteboardType = .string
    /// `public.html`.
    static let html = NSPasteboard.PasteboardType(UTType.html.identifier)
    /// `public.rtf`.
    static let rtf = NSPasteboard.PasteboardType(UTType.rtf.identifier)
    /// `public.png`.
    static let png = NSPasteboard.PasteboardType(UTType.png.identifier)
    /// `public.tiff`.
    static let tiff = NSPasteboard.PasteboardType(UTType.tiff.identifier)
    /// `public.image` (generic image data).
    static let image = NSPasteboard.PasteboardType(UTType.image.identifier)
    /// `public.url`.
    static let url = NSPasteboard.PasteboardType(UTType.url.identifier)
    /// `public.text` (generic text supertype; after registration, conformance covers other text flavors
    /// like utf16).
    static let text = NSPasteboard.PasteboardType(UTType.text.identifier)
    /// `text/uri-list` —— Non-UTI MIME flavor (probe: `UTType("text/uri-list")` is nil,
    /// pasteboard bridges it to dyn.* dynamic type). URL list representation for browser multi-link
    /// drag-and-drop.
    static let uriList = NSPasteboard.PasteboardType("text/uri-list")
    /// `public.vcard` (contact card, extension vcf).
    static let vCard = NSPasteboard.PasteboardType(UTType.vCard.identifier)
    /// `public.calendar-event`.
    /// Probe conclusion: This type is declared in the system but has **no supertypes**, generic
    /// registration (like public.data) does not cover it, so it must be registered explicitly.
    static let calendarEvent = NSPasteboard.PasteboardType(UTType.calendarEvent.identifier)
    /// `public.email-message`.
    /// Probe conclusion: It only conforms to `public.message`, not under data/item, so it must be
    /// registered explicitly (Mail drag-and-drop uses this type or promise).
    static let emailMessage = NSPasteboard.PasteboardType(UTType.emailMessage.identifier)
    /// `public.data` —— Generic fallback.
    /// Probe conclusion: `availableType(from:)` expands along UTI conformance (declared public.png
    /// pasteboard hits public.data/public.image,
    /// even generating public.tiff); non-UTI legacy flavors (text/uri-list,
    /// NSFilenamesPboardType, etc.) are bridged to dyn.* dynamic types and also hit public.data.
    /// Unregistered reverse domain custom identifiers (system doesn't know their conformance) are
    /// exceptions and cannot be matched.
    static let data = NSPasteboard.PasteboardType(UTType.data.identifier)
    /// `public.item` —— Root of all things (includes URL family; `public.url` conforms to `public.item`,
    /// Probe: Declaring `public.url` pasteboard hits `public.item/public.data`).
    static let item = NSPasteboard.PasteboardType(UTType.item.identifier)
    /// `public.content`.
    static let content = NSPasteboard.PasteboardType(UTType.content.identifier)
    /// The UTI form of `NSFileContentsPboardType`. Register the `public.file-contents` string directly
    /// because the SDK has no corresponding static `UTType` property.
    static let fileContents = NSPasteboard.PasteboardType("public.file-contents")
    /// Token for quick start tutorial process. It is only used to confirm real drag-in/drag-out within the
    /// same tutorial session,
    /// and does not carry file content or appear in normal drag-and-drop registration list.
    static let tutorialSession = NSPasteboard.PasteboardType("com.nininunz.Clerestory.tutorial-session")

    /// `NSFilePromiseReceiver` readable promise type (Apple recommends directly using its
    /// `readableDraggedTypes` registration, instead of writing UTI strings manually).
    static let filePromiseTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// Image data family, ordered by priority at materialization (PNG no conversion, TIFF needs encoding).
    static let imageTypes: [NSPasteboard.PasteboardType] = [png, tiff, image]
    /// Text family. Main chain only materializes plain text; drag-and-drop with only HTML/RTF (no plain
    /// text)
    /// is handled by `DropImportCoordinator` chain materializing as .html/.rtf file items (Task 1).
    static let textTypes: [NSPasteboard.PasteboardType] = [plainText, html, rtf]

    /// Broad fallback registration type (Task 1 'Universal Drag-in'). After registration, AppKit matches
    /// drag types by conformance
    /// (see probe conclusions in previous constant comments). Almost all draggable content will reach
    /// `draggingEntered`;
    /// rejection when content cannot be read is handled by `DropImportCoordinator` fallback chain.
    /// They **are not preferred for materialization** (no semantics/extension), only appear in the last
    /// tier of `materializationCandidates`
    /// (item only declares `public.data` and has payload, content is not lost).
    static let genericFallbackTypes: [NSPasteboard.PasteboardType] = [data, item, content, fileContents]

    /// All drag-in types registered by `DragContainerView` / `EdgeTabView`.
    /// Task 1 expands: main chain types + URL variants/unconformed specific types + generic fallback.
    static let dragInTypes: [NSPasteboard.PasteboardType] =
        filePromiseTypes + [fileURL] + imageTypes + [url] + textTypes
        + [text, uriList, vCard, calendarEvent, emailMessage]
        + genericFallbackTypes

    // MARK: - Capability probing (pure functions)

    /// Drag and drop a category. The declaration order of `allCases` determines the processing priority
    /// (F-03).
    enum Category: CaseIterable, Equatable, Sendable {
        /// High-quality file promise (Photos / Safari large images, etc., sources that are generated after
        /// being dropped).
        case filePromise
        /// URL of a file/folder that already exists on disk.
        case fileURL
        /// Bitmap data without a file URL, such as PNG, TIFF, or a generic image.
        case image
        /// Web URL.
        case url
        /// Plain text / HTML / RTF.
        case text
    }

    /// Detect which categories are covered by the type array, and return a list of categories sorted by
    /// priority.
    static func availableCategories(in types: [NSPasteboard.PasteboardType]) -> [Category] {
        Category.allCases.filter { supports($0, types: types) }
    }

    /// Take the highest priority category by priority; return nil if no applicable type is found (drag and
    /// drop should be rejected).
    static func preferredCategory(in types: [NSPasteboard.PasteboardType]) -> Category? {
        availableCategories(in: types).first
    }

    /// Whether the type array supports the specified category.
    static func supports(_ category: Category, types: [NSPasteboard.PasteboardType]) -> Bool {
        switch category {
        case .filePromise:
            types.contains { filePromiseTypes.contains($0) }
        case .fileURL:
            types.contains(fileURL)
        case .image:
            types.contains { imageTypes.contains($0) }
        case .url:
            types.contains(url)
        case .text:
            types.contains { textTypes.contains($0) }
        }
    }

    /// Edge auto-expansion only accepts real file sources. Browser tabs, web links, text, and image data
    /// can still be dragged into shelf after manually opening it, but shelf cannot be triggered simply by
    /// proximity to the screen edge.
    ///
    /// File promise indicates that a real file will be generated upon dropping (e.g., Photos / Mail), so
    /// it is counted as file drag like existing file URLs on disk.
    static func hasFileDragContent(in types: [NSPasteboard.PasteboardType]) -> Bool {
        supports(.fileURL, types: types) || supports(.filePromise, types: types)
    }

    /// Island approach accepts files and text selections. URL/image payloads
    /// often include a text fallback; that alone must not turn them into text drags.
    static func hasShelfApproachContent(in types: [NSPasteboard.PasteboardType]) -> Bool {
        if hasFileDragContent(in: types) { return true }
        guard !supports(.url, types: types), !types.contains(uriList),
              !supports(.image, types: types) else { return false }
        return supports(.text, types: types)
    }

    /// Prioritized materialized types in image data: PNG is directly saved to disk, TIFF/general image
    /// needs to be transcoded to PNG.
    static func preferredImageType(in types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        imageTypes.first { types.contains($0) }
    }

    // MARK: - General drop acceptance and materialization

    /// Drag highlight/reception determination ("Drop everything" semantics). After wide fallback
    /// registration, almost all drag-and-drop that reaches `draggingEntered` can be materialized by the
    /// fallback chain —— as long as any type is declared, it accepts highlight; only truly zero content
    /// (no type declaration) is rejected. The fallback from dragging out is handled by the caller's
    /// `draggingSource == nil` guard and is not included in this determination.
    static func hasImportableContent(in types: [NSPasteboard.PasteboardType]) -> Bool {
        !types.isEmpty
    }

    /// Types already handled by the main chain or dedicated branches are excluded from general
    /// materialization candidates. (html/rtf go through the rich text materialization branch;
    /// plainText/url/fileURL/uri-list each have their own paths.)
    static let handledElsewhereTypes: [NSPasteboard.PasteboardType] =
        [fileURL, url, uriList] + textTypes + filePromiseTypes

    /// Fallback extension for known types without `preferredFilenameExtension` (Probe B: calendar-event /
    /// email-message have no extension tags, but materialized files must have the correct extension to be
    /// recognized by Calendar/Mail and other targets).
    static let wellKnownExtensionFallback: [NSPasteboard.PasteboardType: String] = [
        calendarEvent: "ics",
        emailMessage: "eml",
    ]

    /// General materialization candidates: type + tier (1 most specific, 3 most generic).
    struct MaterializationCandidate: Equatable, Sendable {
        let type: NSPasteboard.PasteboardType
        /// 1 = type declared non-dynamic UTI and has an extension; 2 = type declared non-dynamic UTI but
        /// no extension; 3 = dynamic/bridge/legacy flavor or generic signal types.
        let tier: Int
    }

    /// General data materialization candidate type sorting (pure function; same tier maintains declaration
    /// order): - tier1: declared, non-dynamic UTI, and has `preferredFilenameExtension` (most specific); -
    /// tier2: declared, non-dynamic UTI but no extension (e.g., calendar-event/email-message); - tier3:
    /// dynamic/bridge/legacy flavor and generic signal types —— data is also content, item only declares
    /// public.data and has payload will not be lost (Probe Group 10). In tier3, if `string(forType:)` can
    /// read non-empty content, the caller should let the string fallback branch produce text items (more
    /// useful than .dat —— e.g., utf8-external-plain-text, which UTType parses to nil). Text family
    /// (declared, conforms to .text, no extension) and URL family are excluded and handed to the string
    /// fallback branch. `handledElsewhereTypes` are overall excluded.
    static func materializationCandidates(in types: [NSPasteboard.PasteboardType]) -> [MaterializationCandidate] {
        let excluded = Set(handledElsewhereTypes)
        var tier1: [MaterializationCandidate] = []
        var tier2: [MaterializationCandidate] = []
        var tier3: [MaterializationCandidate] = []
        for type in types where !excluded.contains(type) {
            guard let utType = UTType(type.rawValue), !utType.isDynamic else {
                tier3.append(MaterializationCandidate(type: type, tier: 3)) // Non-UTI strings or dynamic dyn.* bridge types.
                continue
            }
            if utType.preferredFilenameExtension != nil {
                tier1.append(MaterializationCandidate(type: type, tier: 1))
            } else if genericFallbackTypes.contains(type) {
                tier3.append(MaterializationCandidate(type: type, tier: 3))
            } else if utType.conforms(to: .text) || utType.conforms(to: .url) {
                continue // For extensionless text or URLs, the string fallback is a better fit.
            } else {
                tier2.append(MaterializationCandidate(type: type, tier: 2))
            }
        }
        return tier1 + tier2 + tier3
    }

    /// Extension of materialized file: type's `preferredFilenameExtension` → known fallback table → "dat".
    static func materializationFileExtension(for type: NSPasteboard.PasteboardType) -> String {
        if let utType = UTType(type.rawValue), !utType.isDynamic,
           let ext = utType.preferredFilenameExtension, !ext.isEmpty {
            return ext
        }
        return wellKnownExtensionFallback[type] ?? "dat"
    }

    /// The display name of the physical project (without extension): localizedDescription of the type
    /// (e.g. vCard → "electronic business card"). If not available, use localized "Dropped Item".
    static func materializedDisplayBaseName(for type: NSPasteboard.PasteboardType) -> String {
        if let utType = UTType(type.rawValue), !utType.isDynamic,
           let description = utType.localizedDescription, !description.isEmpty {
            return description
        }
        return String(localized: "Dropped Item")
    }
}
