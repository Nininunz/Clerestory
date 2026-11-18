import AppKit
import OSLog
import UniformTypeIdentifiers

/// Drag-in dispatch result: synchronously generated items + the number of items still materialized in the
/// background.
struct DropImportResult: Equatable, Sendable {
    /// Projects that can be directly added to the shelf (fileURL / URL / text path are synchronized and
    /// generated).
    var items: [ShelfItem]
    /// Number of materialized tasks dispatched to the backend and generated later via the
    /// `onAsyncItemReady` callback (file promise and image data path).
    var pendingMaterializations: Int

    /// Whether any content has been processed (determines the return value of `performDragOperation`).
    var handled: Bool { !items.isEmpty || pendingMaterializations > 0 }

    static let unhandled = DropImportResult(items: [], pendingMaterializations: 0)
}

/// Drag mode (F-05 dual mode): direct drag = copy reference (current semantic); ⌘+drag = cut and move
/// (original file moved to trash, preserved copy added to shelf). ⌘ only affects file/folder drag-in via
/// fileURL — file promise / text / URL / pure image data do not have the concept of an 'original file'.
enum DropInMode: String, Equatable, Sendable {
    /// Direct drag and drop: preserves original file reference, original file remains untouched (default).
    case copy
    /// A Command-drop stores a managed copy and moves the original to Trash. Dragging the item out
    /// delivers the managed copy and removes it from Shelf.
    case move
}

/// Convert `NSPasteboard` (from `NSDraggingInfo`) into a pure logic layer of `[ShelfItem]`.
///
/// Decouple from AppKit drag and drop protocol: input is pasteboard, output is synchronous items +
/// asynchronous materialization callback, facilitating unit testing (can directly construct
/// `NSPasteboard(name:)` instance in tests to feed data).
///
/// Processing order strictly follows the research report F-03 and implementation plan §2.3:
/// **file promise → fileURL → image data → URL → text**. High priority categories declare types but may
/// not actually read content (a rare source behavior), so it falls back to the next category in order,
/// without discarding the entire drag and drop.
///
/// Task one 'Universal Drag and Drop': if the main chain produces nothing, enter the fallback chain
/// (`fallbackImport`), and process each pasteboard item independently (mixing multiple items, each finds
/// its best export):
/// a. `text/uri-list` → URL item;
/// b. Only HTML/RTF (no plain text) → materialize `.html/.rtf` file item;
/// c. General data materialization (best type selection see `PasteboardTypes.materializationCandidates`);
/// d. Any type that reads non-empty string → text item;
/// e. Log per item, if the entire drag and drop produces nothing → show notice + do not accept drag and
/// drop.
///
/// Known limitations:
/// - Source application: when dragging across apps, `NSDraggingInfo.draggingSource` is nil, this layer
/// only sees the pasteboard, v1 uniformly leaves `sourceApp = nil`.
/// - Folder drag and drop is processed as single item (`kind = .folder`), no recursive expansion.
/// - Main chain maintains the semantics of 'priority category wins overall' (fileURL + text mixed drag and
/// drop only takes fileURL, see existing unit test `testImport_fileURLAndText_fileURLWins`); item-by-item
/// independent processing only occurs within the fallback chain.
@MainActor
final class DropImportCoordinator {
    /// Default display name for materialized image projects (saved file name includes UUID prefix, display
    /// name remains clean).
    /// S10: User visible, goes through catalog localization; keep computed property for compatibility with
    /// existing references (including unit tests).
    nonisolated static var materializedImageDisplayName: String {
        String(localized: "Dropped Image.png")
    }

    /// UX1: Successful import callback (drag and drop and UX3 clipboard save share this entry).
    /// `importItems`
    /// Trigger synchronously on MainActor when returning `handled` —— AppDelegate uses this to mark
    /// Drag and drop automatically triggers a session if content has already been dropped in this round,
    /// and no longer automatically retracts upon drag end.
    var onImportHandled: (@MainActor () -> Void)?

    /// Runtime token verification and import callback for quick onboarding. Only the random token of the
    /// current session
    /// Can allow this app's internal drag to pass through the shelf's 'reject self fall back' defense.
    var isActiveTutorialToken: (@MainActor (String) -> Bool)?
    var onTutorialItemsImported: (@MainActor (String, [ShelfItem]) -> Void)?

    /// Shared bookmark service (ShelfWindowController injects it into SwiftUI environment,
    /// For card thumbnails/open operations to resolve file access rights via bookmark parsing).
    let bookmarkService: BookmarkService
    /// D10: Inline prompt center for failed drag and drop/materialization (ShelfWindowController injects
    /// it into SwiftUI environment,
    /// ShelfView renders the transient capsule below the title bar).
    let noticeCenter: ShelfNoticeModel
    /// F-05: ⌘+drag (cut mode) transfer orchestration (copy → validation → trash → isCut item).
    let cutMoveService: CutMoveService
    /// Record recovery transactions for managed moves. Only call `markManagedMoveCommitted` to remove a
    /// record after the managed item has been saved to the Shelf snapshot synchronously.
    let managedMoveJournal: ManagedMoveJournal
    /// v1.2: promised files are journaled before leaving staging and remain
    /// retryable until their ShelfItem is synchronously persisted.
    let pendingImportJournal: PendingImportJournal
    /// v1.2: runtime-only batch status rendered by ShelfActivityStrip.
    let transferStore: TransferStore
    private let tempFileService: TempFileService
    private let promiseReceiver: FilePromiseReceiver
    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "DropImport")

    init(bookmarkService: BookmarkService,
         tempFileService: TempFileService,
         noticeCenter: ShelfNoticeModel = ShelfNoticeModel(),
         managedMoveJournal: ManagedMoveJournal? = nil,
         pendingImportJournal: PendingImportJournal? = nil,
         transferStore: TransferStore? = nil,
         cutMoveService: CutMoveService? = nil) {
        self.bookmarkService = bookmarkService
        self.tempFileService = tempFileService
        self.noticeCenter = noticeCenter
        self.transferStore = transferStore ?? TransferStore()
        let journal = managedMoveJournal
            ?? cutMoveService?.managedMoveJournal
            ?? ManagedMoveJournal(directoryURL: tempFileService.directoryURL.deletingLastPathComponent())
        self.managedMoveJournal = journal
        let pendingJournal = pendingImportJournal ?? PendingImportJournal(
            directoryURL: tempFileService.directoryURL.deletingLastPathComponent(),
            managedDirectoryURL: tempFileService.directoryURL
        )
        self.pendingImportJournal = pendingJournal
        self.cutMoveService = cutMoveService ?? CutMoveService(
            tempFileService: tempFileService,
            bookmarkService: bookmarkService,
            managedMoveJournal: journal
        )
        self.promiseReceiver = FilePromiseReceiver(tempFileService: tempFileService,
                                                   bookmarkService: bookmarkService,
                                                   pendingImportJournal: pendingJournal,
                                                   transferStore: self.transferStore)
    }

    /// Publish duplicate feedback only when a released drop actually skips files.
    func addDroppedItems(_ items: [ShelfItem], to store: ShelfStore, at index: Int? = nil) {
        let previousDuplicate = store.duplicateDrop?.id
        store.add(contentsOf: items, at: index)
        if !ShelfDuplicateFeedback.usesFileOverlay,
           store.duplicateDrop?.id != previousDuplicate {
            noticeCenter.show(.alreadyOnShelf)
        }
    }

    // MARK: - Entry point

    /// This pure function selects the drop mode and can be unit-tested directly. Holding Command for a
    /// drop containing a file URL selects .move. All other drops use .copy because non-file content has no
    /// original file to move. The caller reads the current modifiers from `NSEvent.modifierFlags` during
    /// the drag session.
    nonisolated static func dropMode(for pasteboard: NSPasteboard,
                                     modifiers: NSEvent.ModifierFlags) -> DropInMode {
        guard modifiers.contains(.command),
              PasteboardTypes.supports(.fileURL, types: pasteboard.types ?? []) else {
            return .copy
        }
        return .move
    }

    /// Dispatch a drag. Synchronously produce items that can be imported and put them in the return value;
    /// file promise and image data
    /// Are materialized in the background, and then produced one by one via `onAsyncItemReady` (called on
    /// MainActor).
    /// UX1: Results are triggered synchronously via `onImportHandled` when `handled`.
    /// F-05: When `mode == .move` (⌘+drag), the fileURL branch switches to cut transfer.
    @discardableResult
    func importItems(from pasteboard: NSPasteboard,
                     mode: DropInMode = .copy,
                     onManagedMoveReady: (@MainActor (ShelfItem) -> Bool)? = nil,
                     onPromisedItemReady: (@MainActor (ShelfItem) -> Bool)? = nil,
                     onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void) -> DropImportResult {
        let batchID = UUID()
        let tutorialToken = activeTutorialToken(in: pasteboard)
        let wrappedAsyncReady: @MainActor (ShelfItem) -> Void = { [weak self] item in
            onAsyncItemReady(item)
            guard let self, let tutorialToken else { return }
            self.onTutorialItemsImported?(tutorialToken, [item])
        }
        let wrappedPromisedReady: @MainActor (ShelfItem) -> Bool = { [weak self] item in
            guard let onPromisedItemReady else {
                wrappedAsyncReady(item)
                return true
            }
            let committed = onPromisedItemReady(item)
            if committed, let self, let tutorialToken {
                self.onTutorialItemsImported?(tutorialToken, [item])
            }
            return committed
        }
        let result = dispatchImport(from: pasteboard,
                                    batchID: batchID,
                                    mode: mode,
                                    onManagedMoveReady: onManagedMoveReady,
                                    onPromisedItemReady: wrappedPromisedReady,
                                    onAsyncItemReady: wrappedAsyncReady)
        if result.handled {
            onImportHandled?()
        }
        return result
    }

    /// `NSDraggingDestination` is used to determine whether the same-process source is the current
    /// exercise, not a regular
    /// shelf card fall back. Strictly reject when token mismatch.
    func acceptsInternalTutorialDrag(_ pasteboard: NSPasteboard) -> Bool {
        activeTutorialToken(in: pasteboard) != nil
    }

    /// Synchronously file URL items are first put into ShelfStore by the caller, then this method is
    /// called to proceed with the guide,
    /// Ensuring that the exercise card already exists in the shelf when the panel switches to the second
    /// step.
    func noteSynchronousTutorialImport(from pasteboard: NSPasteboard,
                                       items: [ShelfItem]) {
        guard !items.isEmpty, let token = activeTutorialToken(in: pasteboard) else { return }
        onTutorialItemsImported?(token, items)
    }

    private func activeTutorialToken(in pasteboard: NSPasteboard) -> String? {
        guard let token = pasteboard.string(forType: PasteboardTypes.tutorialSession),
              !token.isEmpty,
              isActiveTutorialToken?(token) == true else {
            return nil
        }
        return token
    }

    /// Actual dispatch logic (under the thin wrapper of `importItems`, for uniform triggering of import
    /// callbacks).
    private func dispatchImport(from pasteboard: NSPasteboard,
                                batchID: UUID,
                                mode: DropInMode,
                                onManagedMoveReady: (@MainActor (ShelfItem) -> Bool)?,
                                onPromisedItemReady: @escaping @MainActor (ShelfItem) -> Bool,
                                onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void) -> DropImportResult {
        let types = pasteboard.types ?? []

        // 1. File promise takes priority (high-quality representation; F-03 clearly recommends trying
        // promise first).
        if PasteboardTypes.supports(.filePromise, types: types) {
            let pending = promiseReceiver.receivePromises(from: pasteboard,
                                                           taskID: batchID,
                                                           onItemReady: onPromisedItemReady)
            if pending > 0 {
                return DropImportResult(items: [], pendingMaterializations: pending)
            }
            // Declared promise type but readObjects can't get receiver: continue to fallback.
        }

        // 2. fileURL (Finder file/folder, and other app's file representation).
        if PasteboardTypes.supports(.fileURL, types: types) {
            if mode == .move {
                // v1.2: copy/trash can be expensive. Capture bookmarks while
                // the pasteboard grant is active, then perform each transaction
                // serially on a detached task.
                let pending = scheduleCutMovedItems(
                    from: pasteboard,
                    taskID: batchID,
                    onManagedMoveReady: onManagedMoveReady,
                    onItemReady: onAsyncItemReady
                )
                if pending > 0 {
                    return DropImportResult(items: [], pendingMaterializations: pending)
                }
            } else {
                let items = fileURLItems(from: pasteboard)
                if !items.isEmpty {
                    return DropImportResult(items: items, pendingMaterializations: 0)
                }
            }
        }

        // 3. Image data (bitmaps without file URL): Materialize PNG to TempFileService directory.
        if let imageType = PasteboardTypes.preferredImageType(in: types) {
            let pending = scheduleImageMaterialization(from: pasteboard,
                                                       taskID: batchID,
                                                       preferredType: imageType,
                                                       onItemReady: onAsyncItemReady)
            if pending > 0 {
                return DropImportResult(items: [], pendingMaterializations: pending)
            }
        }

        // 4. URL。
        if PasteboardTypes.supports(.url, types: types) {
            let items = urlItems(from: pasteboard)
            if !items.isEmpty {
                return DropImportResult(items: items, pendingMaterializations: 0)
            }
        }

        // 5. Text family (v1 only takes plain text, see type comment).
        if PasteboardTypes.supports(.text, types: types) {
            let items = textItems(from: pasteboard)
            if !items.isEmpty {
                return DropImportResult(items: items, pendingMaterializations: 0)
            }
        }

        // 6. Fallback chain (task one): Process each item sequentially when the main chain produces
        // nothing, trying to materialize content as much as possible.
        let fallback = fallbackImport(from: pasteboard,
                                      taskID: batchID,
                                      onAsyncItemReady: onAsyncItemReady)
        guard !fallback.items.isEmpty || fallback.pending > 0 else {
            logger.warning("Drop contained no importable content; declared types: \(types.map(\.rawValue), privacy: .public)")
            noticeCenter.show(.unsupportedContent)
            return .unhandled
        }
        // A heterogeneous fallback drop can contain synchronous rich text/URL
        // items alongside background materializations. Once a runtime batch
        // exists, include those already-ready items in the same factual total.
        if fallback.pending > 0, !fallback.items.isEmpty {
            transferStore.extendImport(id: batchID, by: fallback.items.count)
            for item in fallback.items {
                transferStore.recordSuccess(taskID: batchID, itemID: item.id)
            }
        }
        return DropImportResult(items: fallback.items, pendingMaterializations: fallback.pending)
    }

    // MARK: - Drop fallback chain

    /// Fallback chain: When the main chain (promise→fileURL→image→url→text) produces nothing, call this
    /// chain.
    /// Process each pasteboard item independently through a→b→c→d branches; items produced synchronously
    /// are returned directly,
    /// Materialize general data (payload may be large) by writing to disk in the background and counting
    /// as pending.
    private func fallbackImport(from pasteboard: NSPasteboard,
                                taskID: UUID,
                                onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void)
        -> (items: [ShelfItem], pending: Int) {
        var items: [ShelfItem] = []
        var pending = 0

        // a. URL variants: text/uri-list. Probe conclusion: This flavor is bridged at the item level as
        //    dyn.* dynamic types (item.string(forType: "text/uri-List") cannot read it),
        //    and can only be read at the pasteboard level using the original flavor string, so this branch
        // is at the pasteboard level;
        //    each line is a URI (# starts a comment line), and each line produces a URL item.
        let urlListItems = urlListVariantItems(from: pasteboard)
        items.append(contentsOf: urlListItems)

        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            // When URI-list has already produced URL items, skip the item that is "all dyn.* bridged
            // types" —
            // It is the projection of uri-list at the item level (probe A), and going through b/c/d will
            // produce the same content again as .dat/text items.
            if !urlListItems.isEmpty,
               pasteboardItem.types.allSatisfy({ $0.rawValue.hasPrefix("dyn.") }) {
                continue
            }
            // b. Only HTML/RTF (items without plain text will reach the fallback chain): Materialize rich
            // text file items,
            //    dragging to Pages/browser remains rich text. Payload is text-level size, and is written
            // to disk synchronously.
            if let richItem = richTextFileItem(from: pasteboardItem) {
                items.append(richItem)
                continue
            }
            // c. Materialize general data: Best type selection (tier sorting see
            //    `PasteboardTypes.materializationCandidates`), write to disk in the background.
            if scheduleDataMaterialization(from: pasteboardItem,
                                           taskID: taskID,
                                           onItemReady: onAsyncItemReady) {
                pending += 1
                continue
            }
            // d. String fallback: Any type that can string(forType:) produce non-empty content → text
            // item.
            if let textItem = fallbackTextItem(from: pasteboardItem) {
                items.append(textItem)
                continue
            }
            // e. Per-item failure log (not silent).
            logger.info("Fallback import skipped an item; declared types: \(pasteboardItem.types.map(\.rawValue), privacy: .public)")
        }
        return (items, pending)
    }

    /// Branch a: text/uri-list → URL item (each line is a URI, # comment lines are skipped; the first
    /// invalid line
    /// does not affect the rest). Read at the pasteboard level (bridging reason see `fallbackImport`
    /// comment).
    private func urlListVariantItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        guard (pasteboard.types ?? []).contains(PasteboardTypes.uriList),
              let payload = pasteboard.string(forType: PasteboardTypes.uriList),
              !payload.isEmpty else {
            return []
        }
        return payload.components(separatedBy: .newlines).compactMap { line in
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, !candidate.hasPrefix("#"),
                  let url = URL(string: candidate), url.scheme != nil else {
                return nil
            }
            return ShelfItem(kind: .url,
                             displayName: url.host() ?? candidate,
                             urlString: candidate)
        }
    }

    /// Branch b: Only HTML/RTF items → materialize as .html/.rtf file items (kind=.file,
    /// dragging out remains rich text). displayName uses the first line of plain text extracted by
    /// NSAttributedString
    /// truncated; if extraction is empty, use a localized fallback name. HTML parsing must be done on the
    /// main thread (this class runs
    /// on MainActor), do not move to background tasks.
    private func richTextFileItem(from pasteboardItem: NSPasteboardItem) -> ShelfItem? {
        if pasteboardItem.types.contains(PasteboardTypes.html),
           let data = pasteboardItem.data(forType: PasteboardTypes.html), !data.isEmpty {
            let plainText = NSAttributedString(html: data, documentAttributes: nil)?.string ?? ""
            return writeRichTextFile(data: data,
                                     fileExtension: "html",
                                     plainText: plainText,
                                     fallbackBaseName: String(localized: "Dropped HTML"))
        }
        if pasteboardItem.types.contains(PasteboardTypes.rtf),
           let data = pasteboardItem.data(forType: PasteboardTypes.rtf), !data.isEmpty {
            let plainText = NSAttributedString(rtf: data, documentAttributes: nil)?.string ?? ""
            return writeRichTextFile(data: data,
                                     fileExtension: "rtf",
                                     plainText: plainText,
                                     fallbackBaseName: String(localized: "Dropped RTF"))
        }
        return nil
    }

    /// Materializing rich text to disk (shared by branch b). Failures are not silent: log + notice, return
    /// nil
    /// so the caller can continue trying subsequent branches (string fallback may still produce text
    /// items).
    private func writeRichTextFile(data: Data, fileExtension: String,
                                   plainText: String, fallbackBaseName: String) -> ShelfItem? {
        // Use fallback name when extracted plain text is empty. Probe conclusion: HTML containing only
        // <img> and other embedded objects
        // extracts U+FFFC (object replacement character), remove it first before checking for emptiness;
        // reuse the text item naming rule (first line truncated) for non-empty content.
        let stripped = plainText.replacingOccurrences(of: "\u{FFFC}", with: "")
        let hasText = !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let baseName = hasText ? Self.displayName(forText: stripped) : fallbackBaseName
        let fileName = "\(Self.sanitizedFileNameComponent(baseName)).\(fileExtension)"
        do {
            let destination = try tempFileService.uniqueFileURL(suggestedName: fileName)
            try data.write(to: destination, options: .atomic)
            return Self.makeFileBackedItem(for: destination,
                                           displayName: fileName,
                                           forcedKind: .file,
                                           bookmarkService: bookmarkService,
                                           logger: logger)
        } catch {
            logger.error("Failed to materialize dropped rich text: \(error.localizedDescription, privacy: .public)")
            noticeCenter.show(.importFailed)
            return nil
        }
    }

    /// Branch c: General data materialization. Take the first type that can read non-empty data in the
    /// order of `materializationCandidates` tier. Write to disk in the background (payload may be large,
    /// same pattern as image materialization). Kind is inferred by UTI (image → .image, others → .file).
    /// Return whether it was dispatched.
    private func scheduleDataMaterialization(from pasteboardItem: NSPasteboardItem,
                                             taskID: UUID,
                                             onItemReady: @escaping @MainActor (ShelfItem) -> Void) -> Bool {
        for candidate in PasteboardTypes.materializationCandidates(in: pasteboardItem.types) {
            // tier3 (dynamic/bridge/generic) and able to read "meaningful text" → text item is more useful
            // than .dat. Let it go to branch d (text flavors like utf8-external-plain-text that NSUTType
            // parses to nil; probe: string(forType:) works for them). Note that there must be a meaningful
            // threshold: string(forType:) will also do lossy decoding for binary data (probe: [1,2,3] →
            // "\u{1}\u{2}\u{3}"), without the threshold, binary data will be turned into gibberish text.
            if candidate.tier == 3,
               let text = pasteboardItem.string(forType: candidate.type),
               Self.isMeaningfulText(text) {
                continue
            }
            let type = candidate.type
            guard let data = pasteboardItem.data(forType: type), !data.isEmpty else { continue }
            let fileExtension = PasteboardTypes.materializationFileExtension(for: type)
            let baseName = PasteboardTypes.materializedDisplayBaseName(for: type)
            let fileName = "\(Self.sanitizedFileNameComponent(baseName)).\(fileExtension)"
            let kind: ItemKind = UTType(type.rawValue)?.conforms(to: .image) == true ? .image : .file
            transferStore.extendImport(id: taskID, by: 1)
            let reportFailure: @MainActor () -> Void = { [transferStore] in
                transferStore.recordFailure(
                    taskID: taskID,
                    failure: TransferFailure(
                        reason: .materializationFailed,
                        itemName: fileName,
                        recoveryAction: .dragAgainFromSource
                    )
                )
            }
            let reportSuccess: @MainActor (ShelfItem) -> Void = { [transferStore] item in
                onItemReady(item)
                transferStore.recordSuccess(taskID: taskID, itemID: item.id)
            }
            Task.detached { [bookmarkService, tempFileService, logger] in
                do {
                    let destination = try tempFileService.uniqueFileURL(suggestedName: fileName)
                    try data.write(to: destination, options: .atomic)
                    let item = Self.makeFileBackedItem(for: destination,
                                                       displayName: fileName,
                                                       forcedKind: kind,
                                                       bookmarkService: bookmarkService,
                                                       logger: logger)
                    await reportSuccess(item)
                } catch {
                    logger.error("Failed to materialize dropped data (\(type.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    await reportFailure()
                }
            }
            return true
        }
        return false
    }

    /// Branch d: String fallback —— if any type of item can read "meaningful text", produce a text item
    /// (take the first in declaration order). `string(forType:)` returns nil for non-string types, and
    /// does lossy decoding for binary data —— `isMeaningfulText` filters out gibberish.
    private func fallbackTextItem(from pasteboardItem: NSPasteboardItem) -> ShelfItem? {
        for type in pasteboardItem.types {
            guard let text = pasteboardItem.string(forType: type),
                  Self.isMeaningfulText(text) else { continue }
            return ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)
        }
        return nil
    }

    /// Fallback for "meaningful text" in string fallback: non-empty and contains no control characters
    /// (whitespace/line breaks/tab excluded). Probe conclusion: `string(forType:)` may do lossy decoding
    /// for any binary data (e.g., [0x01,0x02,0x03] → "\u{1}\u{2}\u{3}"), without this threshold, binary
    /// payload will be misclassified as gibber, and not materialized as .dat.
    nonisolated static func isMeaningfulText(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        let controls = CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines)
        return string.rangeOfCharacter(from: controls) == nil
    }

    /// Cleaning up materialized file names: remove path separators (display name first line may contain
    /// "/", `TempFileService`'s lastPathComponent cleaning will eat the entire name prefix).
    nonisolated static func sanitizedFileNameComponent(_ name: String) -> String {
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? String(localized: "Dropped Item") : sanitized
    }

    // MARK: - fileURL

    private func fileURLItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return []
        }
        return urls.map { Self.makeFileBackedItem(for: $0, displayName: $0.lastPathComponent, bookmarkService: bookmarkService, logger: logger) }
    }

    // MARK: - File URL drops in cut mode

    /// ⌘+drag-in: During drag-and-drop session, synchronize capturing URL + bookmark, then move copy →
    /// journal → trash to background serial execution. Serial execution avoids multiple drag-ins competing
    /// for disk IO at once, and maintains source order. Successful managed items go through dedicated
    /// callbacks, and the caller must first synchronize persistence before deleting journal; failed
    /// fallback items go through normal async callbacks.
    private func scheduleCutMovedItems(
        from pasteboard: NSPasteboard,
        taskID: UUID,
        onManagedMoveReady: (@MainActor (ShelfItem) -> Bool)?,
        onItemReady: @escaping @MainActor (ShelfItem) -> Void
    ) -> Int {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return 0
        }

        let service = cutMoveService
        let requests = urls.map {
            service.prepareRequest(for: $0, displayName: $0.lastPathComponent)
        }
        guard !requests.isEmpty else { return 0 }
        transferStore.beginImport(
            id: taskID,
            expectedCount: requests.count,
            safetyMessage: String(localized: "Managed copies are protected while originals move to the Trash.")
        )
        let transferStore = transferStore
        Task.detached(priority: .userInitiated) {
            for request in requests {
                switch service.makeCutItem(for: request) {
                case .moved(let item):
                    await MainActor.run {
                        let committed: Bool
                        if let onManagedMoveReady {
                            committed = onManagedMoveReady(item)
                        } else {
                            // Defensive compatibility path. The journal stays
                            // until startup reconciliation if the caller does
                            // not provide the commit-aware callback.
                            onItemReady(item)
                            committed = true
                        }
                        if committed {
                            transferStore.recordSuccess(taskID: taskID, itemID: item.id)
                        } else {
                            transferStore.recordWarning(
                                taskID: taskID,
                                itemID: item.id,
                                warning: TransferFailure(
                                    reason: .persistenceFailed,
                                    itemName: request.displayName,
                                    recoveryAction: .openStorageRecovery,
                                    impact: .itemAddedWithWarning
                                )
                            )
                        }
                    }
                case .fallbackToReference(let item, let reason):
                    await MainActor.run {
                        onItemReady(item)
                        if reason == .sourceInsideContainer {
                            // The item was intentionally downgraded to a normal
                            // reference, so the batch still succeeded.
                            transferStore.recordSuccess(taskID: taskID, itemID: item.id)
                        } else {
                            transferStore.recordWarning(
                                taskID: taskID,
                                itemID: item.id,
                                warning: TransferFailure(
                                    reason: .managedMoveFellBackToReference,
                                    itemName: request.displayName,
                                    recoveryAction: .dismiss,
                                    impact: .itemAddedWithWarning
                                )
                            )
                        }
                    }
                }
            }
        }
        return requests.count
    }

    /// Deletes the recovery transaction after the caller has synchronously
    /// committed `item` to the shelf snapshot. Failure is safe: the record is
    /// reconciled on the next launch and continues protecting its managed path.
    func markManagedMoveCommitted(itemID: UUID) {
        do {
            try managedMoveJournal.remove(id: itemID)
        } catch {
            logger.error("Failed to finish managed move transaction \(itemID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Image data

    /// Extract image Data from each pasteboard item and dispatch to background materialization.
    /// NSPasteboardItem is not Sendable, Data must be extracted on this layer (MainActor) locally, not
    /// passed across actors with original item.
    private func scheduleImageMaterialization(from pasteboard: NSPasteboard,
                                              taskID: UUID,
                                              preferredType: NSPasteboard.PasteboardType,
                                              onItemReady: @escaping @MainActor (ShelfItem) -> Void) -> Int {
        let payloads: [(type: NSPasteboard.PasteboardType, data: Data)] =
            (pasteboard.pasteboardItems ?? []).compactMap { item in
                guard let type = PasteboardTypes.preferredImageType(in: item.types),
                      let data = item.data(forType: type) else {
                    return nil
                }
                return (type, data)
            }

        guard !payloads.isEmpty else { return 0 }
        transferStore.beginImport(id: taskID, expectedCount: payloads.count)
        let reportFailure: @MainActor () -> Void = { [transferStore] in
            transferStore.recordFailure(
                taskID: taskID,
                failure: TransferFailure(
                    reason: .materializationFailed,
                    itemName: Self.materializedImageDisplayName,
                    recoveryAction: .dragAgainFromSource
                )
            )
        }
        let reportSuccess: @MainActor (ShelfItem) -> Void = { [transferStore] item in
            onItemReady(item)
            transferStore.recordSuccess(taskID: taskID, itemID: item.id)
        }
        for payload in payloads {
            Task.detached { [bookmarkService, tempFileService, logger] in
                do {
                    guard let pngData = Self.pngData(from: payload.data, type: payload.type) else {
                        throw DropImportError.imageConversionFailed
                    }
                    let destination = try tempFileService.uniqueFileURL(suggestedName: Self.materializedImageDisplayName)
                    try pngData.write(to: destination, options: .atomic)
                    let item = Self.makeFileBackedItem(for: destination,
                                                       displayName: Self.materializedImageDisplayName,
                                                       forcedKind: .image,
                                                       bookmarkService: bookmarkService,
                                                       logger: logger)
                    await reportSuccess(item)
                } catch {
                    // Fail without crashing or being silent: log + D10 inline prompt, drag-and-drop is
                    // still considered as handled.
                    logger.error("Failed to materialize dropped image data: \(error.localizedDescription, privacy: .public)")
                    await reportFailure()
                }
            }
        }
        return payloads.count
    }

    /// Use PNG data directly; TIFF / general image is transcoded to PNG via NSBitmapImageRep.
    /// Non-isolated: transcoding is done in background task locally, NSBitmapImageRep (non-Sendable) is
    /// not passed across actors.
    private nonisolated static func pngData(from data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == PasteboardTypes.png {
            return data
        }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    // MARK: - URL

    private func urlItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard item.types.contains(PasteboardTypes.url),
                  let string = item.string(forType: PasteboardTypes.url),
                  let url = URL(string: string),
                  url.scheme != nil else {
                return nil
            }
            return ShelfItem(kind: .url,
                             displayName: url.host() ?? string,
                             urlString: string)
        }
    }

    // MARK: - Text

    private func textItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> ShelfItem? in
            guard let text = item.string(forType: .string), !text.isEmpty else { return nil }
            return ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)
        }
        // Few sources only provide string on the overall pasteboard (per-item reading is empty).
        if items.isEmpty,
           let text = pasteboard.string(forType: .string), !text.isEmpty {
            return [ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)]
        }
        return items
    }

    /// Text item display name: truncate first line (60 characters), fallback to localized "Text" for blank
    /// text.
    nonisolated static func displayName(forText text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return String(localized: "Text") }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    // MARK: - Shared file-backed item construction

    /// Create file, folder, and image items by inferring the kind and creating a security-scoped bookmark
    /// immediately. This nonisolated entry point is also used by the background materialization callback
    /// in `FilePromiseReceiver` and by image materialization tasks. If bookmark creation fails, log the
    /// failure and keep the item so its path remains available for display and recovery.
    nonisolated static func makeFileBackedItem(for url: URL,
                                               displayName: String,
                                               forcedKind: ItemKind? = nil,
                                               promisedTypeIdentifiers: [String] = [],
                                               bookmarkService: BookmarkService,
                                               logger: Logger) -> ShelfItem {
        let kind = forcedKind ?? inferFileKind(for: url, promisedTypeIdentifiers: promisedTypeIdentifiers)
        let bookmark: Data?
        do {
            bookmark = try bookmarkService.createBookmark(for: url)
        } catch {
            logger.error("Failed to create bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            bookmark = nil
        }
        return ShelfItem(kind: kind, path: url.path, bookmark: bookmark, displayName: displayName)
    }

    /// Kind inference is based on the actual materialization result: folder (directory and not a package)
    /// → recognizable extension name
    /// (image / file) → single, clear promise UTI as a fallback → file.
    ///
    /// A single NSFilePromiseReceiver can deliver multiple, even different types of files; its
    /// `fileTypes` is a receiver-level collection, and you cannot apply any image type from the collection
    /// to each
    /// individual file callback, otherwise text files in the same batch will be incorrectly labeled as
    /// images.
    nonisolated static func inferFileKind(for url: URL, promisedTypeIdentifiers: [String] = []) -> ItemKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true {
            return .folder
        }
        if !url.pathExtension.isEmpty,
           let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image) ? .image : .file
        }

        let promisedTypes = Set(promisedTypeIdentifiers.compactMap(UTType.init))
        if promisedTypes.count == 1, let type = promisedTypes.first {
            if type.conforms(to: .folder), !type.conforms(to: .package) { return .folder }
            if type.conforms(to: .image) { return .image }
        }
        return .file
    }
}

/// Materialization error on drag-in.
enum DropImportError: LocalizedError {
    /// The dragged-in bitmap data cannot be converted into a PNG.
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            String(localized: "Dropped image data could not be converted to PNG.")
        }
    }
}
