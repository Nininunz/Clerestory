import AppKit
import UniformTypeIdentifiers

/// Lifecycle channel for file-promise of managed cut items. Callbacks may occur before or after AppKit
/// session results and may come from the provider's background queue; the receiver is responsible for
/// switching back to their own actor.
struct DeliverySink: Sendable {
    /// The destination selected the promised-file representation.
    var promiseRequested: @Sendable (UUID) -> Void
    /// Write completed: parameters are item id and delivery target URL.
    var delivered: @Sendable (UUID, URL) -> Void
    /// Write failed: parameters are item id (item remains in shelf, can be retried).
    var failed: @Sendable (UUID) -> Void
}

/// Drag-out payload assembly: ShelfItem → pasteboard writer multiple representations / `[NSDraggingItem]`
/// (Implementation plan §2.3 "Drag-out", Research Report F-04).
///
/// ## File Payload Technical Route
///
/// A drag-out item = an `NSDraggingItem` = a pasteboard writer:
/// - Regular file/folder: `DirectFilePasteboardWriter`, providing `public.file-url` and
///   `NSFilenamesPboardType`; the latter is used for macOS upload paths in Chromium.
/// - Regular image: also adds lazy `public.tiff` bitmap fallback.
/// - Hosted cut item: promise-only `FilePromiseProvider`; it is discarded only after the target confirms
/// the write.
/// - Tutorial file: the direct writer also carries a private session token.
///
/// Cannot append these representations to `NSFilePromiseProvider` subclasses: private pasteboard
/// `writeObjects` may show appended types, but the real `NSDraggingSession` will only retain system
/// promise types, making Chromium, image fallback, and tutorial token actually unavailable.
///
/// ## Pure Function Part
/// `strategy(for:)` / `flattenedItems(_:)` / `promisedFileType(for:)` do not construct
/// AppKit objects; unit tests directly assert the strategy and flattening semantics.
enum DragPayloadBuilder {
    /// Representation strategies for each kind.
    enum Strategy: Equatable, Sendable {
        /// File/folder: regular items use direct file representation, hosted cut items use file promise.
        case fileBacked
        /// Image: fileBacked + `public.tiff` bitmap fallback (planned in §2.3).
        case fileBackedImage
        /// Plain text: `public.utf8-plain-text` (the current model only stores plain; the drag-in side v1
        /// does not retain HTML/RTF original content, so there is no rich text representation to
        /// register).
        case plainText
        /// Web URL: `public.url` + plain text.
        case webURL
    }

    /// Stack does not drag out as a whole (it is expanded into child items by `flattenedItems`), so
    /// returns nil.
    static func strategy(for item: ShelfItem) -> Strategy? {
        switch item.kind {
        case .file, .folder: .fileBacked
        case .image: .fileBackedImage
        case .text: .plainText
        case .url: .webURL
        case .stack: nil
        }
    }

    /// Mirrors the guards used by writer construction without creating AppKit
    /// objects. Delivery batches use it so skipped malformed cards do not
    /// inflate the expected outcome count and leave the activity strip stuck.
    static func canMakePasteboardWriter(for item: ShelfItem) -> Bool {
        switch strategy(for: item) {
        case .fileBacked, .fileBackedImage:
            return item.path != nil
        case .plainText:
            return item.text?.isEmpty == false
        case .webURL:
            guard let value = item.urlString else { return false }
            return URL(string: value) != nil
        case nil:
            return false
        }
    }

    /// Expand stack into all child items (recursively, defend against nested stacks), non-stack items are
    /// retained as-is,
    /// order remains unchanged. Semantics: dragging out a stack card = dragging out all its child items
    /// (planned in §2.3).
    static func flattenedItems(_ items: [ShelfItem]) -> [ShelfItem] {
        items.flatMap { item -> [ShelfItem] in
            guard item.kind == .stack, let children = item.children, !children.isEmpty else {
                return [item]
            }
            return flattenedItems(children)
        }
    }

    /// UTI of the content declared by promise: folder → `public.folder`; others are inferred via the
    /// system
    /// declaration table based on the extension; if no/unknown extension, fallback to `public.data`.
    ///
    /// Defensive note (tested on macOS 26): `NSFilePromiseProvider.init(fileType:)` throws NSException for
    /// fileType that does not conform to kUTTypeData/kUTTypeDirectory (Swift cannot catch, leading to
    /// process crash),
    /// and some standard UTIs (like `public.pdf`) are no longer declared on macOS 26
    /// (`UTType("public.pdf") == nil`).
    /// Therefore, only accept types returned by `UTType(filenameExtension:)` that have been verified to
    /// conform to .data/.directory;
    /// static members of `UTType` (like `UTType.pdf`) cannot be used directly.
    static func promisedFileType(for item: ShelfItem) -> String {
        if item.kind == .folder {
            return UTType.folder.identifier
        }
        if let path = item.path {
            let pathExtension = URL(fileURLWithPath: path).pathExtension
            if !pathExtension.isEmpty,
               let type = UTType(filenameExtension: pathExtension),
               type.conforms(to: .data) || type.conforms(to: .directory) {
                return type.identifier
            }
        }
        return UTType.data.identifier
    }

    // MARK: - Writer construction

    /// AppKit transfers file access when the destination reads the pasteboard,
    /// which can happen well after the writers have been constructed.
    static func makeFileAccessLease(for items: [ShelfItem],
                                    bookmarkService: BookmarkService) -> BookmarkAccessLease {
        var accessedURLs: [URL] = []
        for item in flattenedItems(items) where !item.isCut {
            guard strategy(for: item) == .fileBacked || strategy(for: item) == .fileBackedImage,
                  let bookmark = item.bookmark,
                  let resolved = try? bookmarkService.resolve(bookmark) else { continue }
            if bookmarkService.startAccessing(resolved.url) {
                accessedURLs.append(resolved.url)
            }
        }
        return BookmarkAccessLease(accessedURLs: accessedURLs, service: bookmarkService)
    }

    /// Single item pasteboard writer. Returns nil when unable to construct (text has no content, url has
    /// no address, file has no path, stack not expanded).
    /// `delivery` only observes the file promise of hosted drag items; regular files are confirmed by
    /// session results.
    @MainActor
    static func makePasteboardWriter(for item: ShelfItem,
                                     bookmarkService: BookmarkService,
                                     delivery: DeliverySink? = nil,
                                     tutorialSessionToken: String? = nil) -> NSPasteboardWriting? {
        switch strategy(for: item) {
        case .fileBacked, .fileBackedImage:
            return makeFileBackedWriter(for: item,
                                        bookmarkService: bookmarkService,
                                        delivery: delivery,
                                        tutorialSessionToken: tutorialSessionToken)
        case .plainText:
            return makeTextItem(for: item)
        case .webURL:
            return makeURLItem(for: item)
        case nil:
            return nil
        }
    }

    /// Keep each writer's Shelf item alongside its dragging item so the
    /// session can apply its removal policy only to items it represents.
    @MainActor
    static func makeDraggingItems(for items: [ShelfItem],
                                  frame: NSRect,
                                  bookmarkService: BookmarkService,
                                  delivery: DeliverySink? = nil,
                                  tutorialTokensByItemID: [UUID: String] = [:],
                                  cardPreviewImage: NSImage? = nil) -> [(item: ShelfItem, draggingItem: NSDraggingItem)] {
        let flattened = flattenedItems(items)
        let singleItemPreview = flattened.count == 1 ? cardPreviewImage : nil
        return flattened.compactMap { item in
            guard let writer = makePasteboardWriter(
                for: item,
                bookmarkService: bookmarkService,
                delivery: delivery,
                tutorialSessionToken: tutorialTokensByItemID[item.id]
            ) else {
                return nil
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let contents = singleItemPreview ?? dragImage(for: item)
            // The preview keeps the item's own aspect ratio, so the frame
            // follows it instead of squeezing it back into the card's box. It
            // is centred on the card: Shelf reordering targets the card centre,
            // and the preview the user steers must sit on that same point.
            let draggingFrame = singleItemPreview.map {
                NSRect(x: frame.midX - $0.size.width / 2,
                       y: frame.midY - $0.size.height / 2,
                       width: $0.size.width,
                       height: $0.size.height)
            } ?? frame
            draggingItem.setDraggingFrame(draggingFrame, contents: contents)
            return (item, draggingItem)
        }
    }

    /// Drag image (S10/C7): Prefer the real thumbnail already loaded by the card (`DragImageCache`),
    /// Drag initiation is a synchronous path, so only cache can be used; fallback to
    /// `NSWorkspace.icon(forFile:)`
    /// (synchronous, no need for file read permissions), text/URL use SF Symbol consistent with card
    /// placeholder.
    /// Uniform 64pt.
    @MainActor
    static func dragImage(for item: ShelfItem) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        if let cached = DragImageCache.image(for: item.id) {
            return NSImage(cgImage: cached, size: size)
        }
        if let path = item.path {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = size
            return icon
        }
        let symbolName = switch item.kind {
        case .text: "doc.text"
        case .url: "link"
        default: "doc"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        image.size = size
        return image
    }

    // MARK: - File/folder/image

    /// Existing regular files use direct writer: fileURL + Chromium-compatible filename list,
    /// images add public.tiff, tutorial items add private token. In real drag, AppKit
    /// preserves these types as-is; additional types from `NSFilePromiseProvider` subclasses
    /// will be discarded by the system, so cannot carry multi-representation payloads for regular files.
    ///
    /// Cut items (`item.isCut`) advertise only file-promise types. Advertising `public.file-url` lets
    /// Finder bypass the promise, so the app cannot confirm delivery before completing the move. TIFF
    /// fallback has the same problem. Delivery requests, successes, and failures are reported through
    /// `delivery`.
    @MainActor
    private static func makeFileBackedWriter(for item: ShelfItem,
                                             bookmarkService: BookmarkService,
                                             delivery: DeliverySink?,
                                             tutorialSessionToken: String?) -> NSPasteboardWriting? {
        let bookmark = item.bookmark
        guard let savedURL = item.fileURL,
              let sourceURL = try? bookmarkService.resolveFileURL(savedURL, bookmark: bookmark) else { return nil }
        let includeImageFallback = strategy(for: item) == .fileBackedImage && !item.isCut
        let tiffDataProvider: (@Sendable () -> Data?)?
        if includeImageFallback {
            // Lazy: Read the file only when the target requests public.tiff.
            tiffDataProvider = { tiffData(sourceURL: sourceURL, bookmark: bookmark, bookmarkService: bookmarkService) }
        } else {
            tiffDataProvider = nil
        }
        if !item.isCut {
            return DirectFilePasteboardWriter(
                fileURL: sourceURL,
                tiffDataProvider: tiffDataProvider,
                tutorialSessionToken: tutorialSessionToken
            )
        }
        let itemID = item.id
        // Explicit type local variables (ternary + closure literals make the type inference unable to
        // produce diagnostics).
        let onPromiseRequested: @Sendable () -> Void = {
            delivery?.promiseRequested(itemID)
        }
        let onDelivered: @Sendable (URL) -> Void = { url in
            delivery?.delivered(itemID, url)
        }
        let onError: @Sendable (Error) -> Void = { _ in
            delivery?.failed(itemID)
        }
        return FilePromiseProvider(
            payload: FilePromiseProvider.Payload(
                sourceURL: sourceURL,
                bookmark: bookmark,
                suggestedName: item.displayName,
                promisedFileType: promisedFileType(for: item)
            ),
            bookmarkService: bookmarkService,
            onPromiseRequested: onPromiseRequested,
            onDelivered: onDelivered,
            onError: onError
        )
    }

    /// Image bitmap fallback: Read the image within a safe scope and export TIFF data. NSImage is not
    /// Sendable,
    /// create and extract Data (Sendable) in place, no cross-actor.
    nonisolated static func tiffData(sourceURL: URL, bookmark: Data?, bookmarkService: BookmarkService) -> Data? {
        guard let url = try? bookmarkService.resolveFileURL(sourceURL, bookmark: bookmark) else { return nil }
        return bookmarkService.withSecurityScopedAccess(to: url) {
            NSImage(contentsOf: url)?.tiffRepresentation
        }
    }

    // MARK: - Text

    /// Plain text: `public.utf8-plain-text` (NSPasteboardItem directly writes the type).
    @MainActor
    private static func makeTextItem(for item: ShelfItem) -> NSPasteboardItem? {
        guard let text = item.text, !text.isEmpty else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(text, forType: PasteboardTypes.plainText)
        return pasteboardItem
    }

    // MARK: - URL

    /// Web URL: `public.url` (URL string) + plain text fallback (text box/address bar).
    /// Do not write `public.file-url`: this is an incorrect representation for http(s) URLs, which may
    /// mislead Finder class targets.
    @MainActor
    private static func makeURLItem(for item: ShelfItem) -> NSPasteboardItem? {
        guard let urlString = item.urlString, URL(string: urlString) != nil else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(urlString, forType: PasteboardTypes.url)
        pasteboardItem.setString(urlString, forType: PasteboardTypes.plainText)
        return pasteboardItem
    }
}
