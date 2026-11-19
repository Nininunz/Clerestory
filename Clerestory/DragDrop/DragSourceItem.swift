import AppKit
import OSLog
import SwiftUI

/// A collection of items dragged out at once, calculated by the card event layer (ShelfView / Stack
/// overlay).
struct DragOutContents: Equatable, Sendable {
    /// The actual items dragged out (top-level selection set or overlay child items; stack is expanded
    /// into child items by `DragPayloadBuilder.flattenedItems`).
    var items: [ShelfItem]
    /// The ID of the top-level item involved: removed from the store if the drop is successful and the
    /// strategy is remove.
    /// Stack overlay child items dragged out pass an empty set —— the removal semantics of child items
    /// (unstack local removal)
    /// are designed with S6's stack batch operations, so child items are not removed in this step.
    var topLevelIDs: Set<UUID>

    /// Only items with a writer participate in the session. A stack can be
    /// removed as a group only when every child was included in the drag.
    func restrictingToRepresentedItems(_ representedItems: [ShelfItem]) -> DragOutContents {
        let representedIDs = Set(representedItems.map(\.id))
        let removableIDs = items.filter { item in
            topLevelIDs.contains(item.id)
                && DragPayloadBuilder.flattenedItems([item]).allSatisfy { representedIDs.contains($0.id) }
        }.map(\.id)
        return DragOutContents(items: representedItems, topLevelIDs: Set(removableIDs))
    }
}

/// Isolation rules between Tutorial cards and regular multi-select drag-and-drop (pure function, to avoid
/// tutorial token freeloading).
enum TutorialDragScope {
    static func effectiveContents(_ contents: DragOutContents,
                                  originatingItemID: UUID,
                                  tutorialItemIDs: Set<UUID>) -> DragOutContents {
        let tutorialOrigin = tutorialItemIDs.contains(originatingItemID)
        return DragOutContents(
            items: contents.items.filter { item in
                tutorialOrigin
                    ? item.id == originatingItemID
                    : !tutorialItemIDs.contains(item.id)
            },
            topLevelIDs: tutorialOrigin
                ? contents.topLevelIDs.intersection([originatingItemID])
                : contents.topLevelIDs.subtracting(tutorialItemIDs)
        )
    }
}

/// Drag controller (MainActor): converts the card's mouseDragged into an AppKit drag session.
///
/// Cards are injected via SwiftUI environment (`\.dragOutController`); in Preview/testing, the environment
/// defaults to nil, so card dragging is silently disabled and clicks are unaffected.
@MainActor
final class DragOutController {
    private let store: ShelfStore
    private let settings: SettingsStore
    private let recents: RecentItemsService
    private let bookmarkService: BookmarkService
    /// Long-lived delivery state survives the AppKit drag session because file
    /// promise callbacks may arrive before or after `endedAt`.
    private let deliveryCoordinator: DeliveryCoordinator
    /// Runtime token for an active tutorial card. The token is only written to the pasteboard for this
    /// card's drag; regular items return nil. The closure avoids writing tutorial state into the ShelfItem
    /// schema.
    private let tutorialTokenForItem: @MainActor (UUID) -> String?


    init(store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         bookmarkService: BookmarkService,
         deliveryCoordinator: DeliveryCoordinator,
         tutorialTokenForItem: @escaping @MainActor (UUID) -> String? = { _ in nil }) {
        self.store = store
        self.settings = settings
        self.recents = recents
        self.bookmarkService = bookmarkService
        self.deliveryCoordinator = deliveryCoordinator
        self.tutorialTokenForItem = tutorialTokenForItem
    }

    /// Drag initiation entry point: `CardDragSourceAnchorView` calls the card's callback when mouseDragged
    /// exceeds the threshold. Must be on the main thread, and `event` must be the current gesture's
    /// mouseDown/mouseDragged event (`beginDraggingSession` hard requirement).
    func beginDrag(contents: DragOutContents,
                   originatingItemID: UUID,
                   from sourceView: NSView,
                   event: NSEvent) {
        // Tutorial token must never be mixed into regular multi-select drag-and-drop: drag only the
        // tutorial card from a tutorial card; remove any potentially selected tutorial cards when dragging
        // from a regular card. This ensures that the tutorial target accepts the token without
        // inadvertently triggering the removal of other user cards or recent project strategies.
        let tutorialIDs = Set(contents.items.compactMap { item in
            tutorialTokenForItem(item.id) == nil ? nil : item.id
        })
        let effectiveContents = TutorialDragScope.effectiveContents(
            contents,
            originatingItemID: originatingItemID,
            tutorialItemIDs: tutorialIDs
        )
        let sessionID = UUID()
        let dragAnchorOffset = Self.dragAnchorOffset(from: sourceView, event: event)
        let deliveryCoordinator = deliveryCoordinator
        let sink = DeliverySink(
            promiseRequested: { itemID in
                Task { @MainActor in
                    deliveryCoordinator.notePromiseRequested(sessionID: sessionID,
                                                             itemID: itemID)
                }
            },
            delivered: { itemID, url in
                Task { @MainActor in
                    deliveryCoordinator.noteDelivered(sessionID: sessionID,
                                                      itemID: itemID,
                                                      destination: url)
                }
            },
            failed: { itemID in
                Task { @MainActor in
                    deliveryCoordinator.noteFailed(sessionID: sessionID, itemID: itemID)
                }
            }
        )
        let fileAccess = DragPayloadBuilder.makeFileAccessLease(
            for: effectiveContents.items,
            bookmarkService: bookmarkService
        )
        let flattenedPreviewItems = DragPayloadBuilder.flattenedItems(effectiveContents.items)
        let represented = DragPayloadBuilder.makeDraggingItems(
            for: effectiveContents.items,
            frame: sourceView.bounds,
            bookmarkService: bookmarkService,
            delivery: sink,
            tutorialTokensByItemID: Dictionary(
                uniqueKeysWithValues: DragPayloadBuilder.flattenedItems(effectiveContents.items).compactMap { item in
                    tutorialTokenForItem(item.id).map { (item.id, $0) }
                }
            ),
            cardPreviewImage: flattenedPreviewItems.count == 1
                ? Self.makeCardPreview(for: flattenedPreviewItems[0])
                : nil
        )
        guard !represented.isEmpty else { return }
        let draggingItems = represented.map(\.draggingItem)
        let representedContents = effectiveContents.restrictingToRepresentedItems(represented.map(\.item))
        deliveryCoordinator.noteSessionBegan(id: sessionID, contents: representedContents)
        // Independent NSDraggingSource per session: no reuse state, result handling depends only on the
        // current contents.
        let source = DragSessionController(contents: representedContents,
                                           sessionID: sessionID,
                                           store: store,
                                           settings: settings,
                                           recents: recents,
                                           delivery: deliveryCoordinator,
                                           policyExcludedItemIDs: Set(
                                               DragPayloadBuilder.flattenedItems(effectiveContents.items).compactMap { item in
                                                   tutorialTokenForItem(item.id) == nil ? nil : item.id
                                               }
                                           ),
                                           dragAnchorOffset: dragAnchorOffset,
                                           fileAccess: fileAccess)
        // Counted only once a session really starts: the source's
        // `draggingSession(_:endedAt:)` is the matching decrement, and the early
        // return above has no session to end.
        deliveryCoordinator.noteDragSessionStarted()
        sourceView.beginDraggingSession(with: draggingItems, event: event, source: source)
    }

    /// Draws the drag preview at the same size the item occupies in the shelf:
    /// the card's thumbnail area is a fixed 52pt-high box with aspect-fit, so a
    /// portrait image stays narrow and a document keeps its square icon.
    private static func makeCardPreview(for item: ShelfItem) -> NSImage? {
        let thumbnail = thumbnailImage(for: item)
        let aspect = thumbnail.flatMap { image -> CGFloat? in
            guard image.size.width > 0, image.size.height > 0 else { return nil }
            return image.size.height / image.size.width
        } ?? 1
        let thumbnailHeight: CGFloat = 52
        let thumbnailWidth = min(max(thumbnailHeight / max(aspect, 0.1), 20), 88)
        let labelHeight: CGFloat = 18
        let width = max(thumbnailWidth, 64)
        let size = NSSize(width: width,
                          height: (thumbnailHeight + labelHeight + 4).rounded())

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        representation.size = size

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let thumbnailRect = NSRect(x: (width - thumbnailWidth) / 2,
                                   y: labelHeight + 4,
                                   width: thumbnailWidth,
                                   height: thumbnailHeight)
        if let thumbnail {
            drawAspectFit(thumbnail, in: thumbnailRect, cornerRadius: 6)
        }

        let labelRect = NSRect(x: 0, y: 0, width: width, height: labelHeight)
        (isDark ? NSColor(calibratedWhite: 0.24, alpha: 0.94)
                : NSColor(calibratedWhite: 0.97, alpha: 0.96)).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (item.displayName as NSString).draw(
            with: labelRect.insetBy(dx: 5, dy: 3),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .regular),
                .foregroundColor: isDark
                    ? NSColor.white.withAlphaComponent(0.92)
                    : NSColor.black.withAlphaComponent(0.75),
                .paragraphStyle: paragraph
            ]
        )

        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private static func thumbnailImage(for item: ShelfItem) -> NSImage? {
        if let cached = DragImageCache.image(for: item.id) {
            return NSImage(cgImage: cached,
                           size: NSSize(width: cached.width, height: cached.height))
        }
        if let path = item.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let symbolName = switch item.kind {
        case .text: "doc.text"
        case .url: "link"
        default: "doc"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private static func drawAspectFit(_ image: NSImage, in rect: NSRect, cornerRadius: CGFloat) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: rect.midX - drawSize.width / 2,
                              y: rect.midY - drawSize.height / 2,
                              width: drawSize.width, height: drawSize.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Offset from the current pointer to the source card center, in window
    /// coordinates. Adding it to a dragging location yields the card center.
    private static func dragAnchorOffset(from sourceView: NSView,
                                         event: NSEvent) -> CGSize {
        guard sourceView.window != nil else { return .zero }
        let center = sourceView.convert(
            NSPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY),
            to: nil
        )
        let pointer = event.locationInWindow
        return CGSize(width: center.x - pointer.x,
                      height: center.y - pointer.y)
    }
}

/// NSDraggingSource for a single drag session (one instance per session, no cross-session state).
@MainActor
final class DragSessionController: NSObject, NSDraggingSource {
    private let contents: DragOutContents
    var itemsForFolderCopy: [ShelfItem] { contents.items }
    var topLevelItemIDs: Set<UUID> { contents.topLevelIDs }
    var acceptedByFolderCopy = false
    var acceptedByShelfReorder = false
    var canReorderOnShelf: Bool {
        !topLevelItemIDs.isEmpty
            && policyExcludedItemIDs.isDisjoint(with: topLevelItemIDs)
    }
    var dragAnchorOffset: CGSize { anchorOffset }
    private let sessionID: UUID
    private let store: ShelfStore
    private let settings: SettingsStore
    private let recents: RecentItemsService
    private let delivery: DeliveryCoordinator?
    /// Tutorial items are cleaned up by OnboardingController after the real target is confirmed, and are
    /// unaffected by the user's regular drag-out strategy. They are never added to Recent Items.
    private let policyExcludedItemIDs: Set<UUID>
    private let anchorOffset: CGSize
    private var fileAccess: BookmarkAccessLease?

    init(contents: DragOutContents,
         sessionID: UUID = UUID(),
         store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         delivery: DeliveryCoordinator? = nil,
         policyExcludedItemIDs: Set<UUID> = [],
         dragAnchorOffset: CGSize = .zero,
         fileAccess: BookmarkAccessLease? = nil) {
        self.contents = contents
        self.sessionID = sessionID
        self.store = store
        self.settings = settings
        self.recents = recents
        self.delivery = delivery
        self.policyExcludedItemIDs = policyExcludedItemIDs
        self.anchorOffset = dragAnchorOffset
        self.fileAccess = fileAccess
        super.init()
    }

    /// Operation mask: Only declare `.copy`, never declare `.move`.
    ///
    /// If `.move` is declared, Finder targets will perform 'move' operations under default or modifier key
    /// combinations — copying to the target and deleting the original file, which violates the principle
    /// of 'never deleting user original files' (Plan §1.2; Survey Report 7.2 Risk C: Final semantics are
    /// determined by the source mask, target return value, and modifier keys together; source-side
    /// narrowing is the most reliable boundary). Only giving `.copy` and dragging to Finder is always a
    /// copy, ⌥/⌘ cannot upgrade it to a move.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// Session end handling: Only process according to the set strategy when an actual drop occurs
    /// (`operation` is non-empty; cancel/reject is empty) — remove top-level items and record in recent
    /// history, retain as-is, or (`.ask`) show a confirmation dialog.
    ///
    /// F-05: The `isCut` item does not participate in the above strategy — the cut semantics imply
    /// removal. After delivery confirmation (promise write completion), `DeliveryCoordinator` removes the
    /// item from the shelf and deletes the custody copy, and it is not affected by `dragOutRemovalPolicy`.
    /// When the session is canceled (`operation == []`), the cut item and custody file are retained as-is.
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        completeDrag(operation: operation)
    }

    func completeDrag(operation: NSDragOperation) {
        defer { fileAccess = nil }
        delivery?.noteDragSessionEnded()
        if acceptedByFolderCopy || acceptedByShelfReorder {
            delivery?.noteSessionEnded(id: sessionID, accepted: false)
            return
        }
        guard operation != [] else {
            delivery?.noteSessionEnded(id: sessionID, accepted: false)
            return
        }
        switch settings.dragOutRemovalPolicy {
        case .keep:
            break
        case .remove:
            removeDraggedItems()
        case .ask:
            askWhetherToRemove()
        }
        // Report acceptance after the removal policy has run. If a promise
        // failure arrived early, the coordinator can now safely reinsert the
        // failed snapshot instead of having this method remove it afterwards.
        delivery?.noteSessionEnded(id: sessionID, accepted: true)
    }

    /// Marks this session as an internal Shelf reorder. The source must not
    /// treat the destination acknowledgement as an external delivery.
    func acceptShelfReorder() {
        acceptedByShelfReorder = true
    }

    /// These top-level IDs exclude cut items. The remove and ask policies apply only to non-cut items.
    /// Applying .remove before delivery confirmation can orphan the managed copy, which cleanupOrphans
    /// would then delete on the next launch.
    private var nonCutTopLevelIDs: Set<UUID> {
        contents.topLevelIDs.filter { id in
            !policyExcludedItemIDs.contains(id)
                && contents.items.first(where: { $0.id == id })?.isCut != true
        }
    }

    /// F-05: The set of expanded items after removing the cut item (recent history only records non-cut
    /// items; cut items are separately recorded by `DeliveryCoordinator` upon delivery confirmation).
    private var nonCutFlattenedItems: [ShelfItem] {
        DragPayloadBuilder.flattenedItems(contents.items).filter {
            !$0.isCut && !policyExcludedItemIDs.contains($0.id)
        }
    }

    /// Remove top-level items and record in recent history (`.remove` strategy and `.ask` confirmation
    /// removal share the same logic). Floating sub-items dragged out with `topLevelIDs` empty, not removed
    /// from the shelf, but still recorded in history.
    private func removeDraggedItems() {
        let ids = nonCutTopLevelIDs
        if !ids.isEmpty {
            store.remove(ids: ids)
        }
        recents.record(nonCutFlattenedItems)
    }

    /// S8: `.ask` strategy — after a successful drag-out, ask whether to remove from the shelf; if 'Don't
    /// ask again' is checked, the current selection is written back as the keep/remove strategy. F-05:
    /// Only ask for non-cut items (cut items are automatically removed from the shelf after delivery, no
    /// need to ask).
    ///
    /// LSUIElement notes: The app has no Dock and is usually inactive. Before showing `NSAlert`, it must
    /// call `NSApp.activate(ignoringOtherApps:)` to bring the app to the foreground, otherwise the dialog
    /// will appear behind other app windows and look like 'nothing happened'. `runModal` is app-level
    /// modal: the drag-out session is now ended, and blocking the main thread to wait for a response is
    /// acceptable, and it is also required for the 'ask each time' semantics.
    private func askWhetherToRemove() {
        let itemCount = nonCutTopLevelIDs.isEmpty
            ? nonCutFlattenedItems.count
            : nonCutTopLevelIDs.count
        guard itemCount > 0 else { return }
        let alert = NSAlert()
        alert.messageText = itemCount == 1
            ? String(localized: "Remove the dragged item from the shelf?")
            : String(localized: "Remove the \(itemCount) dragged items from the shelf?")
        alert.informativeText = String(localized: "The original files are never deleted.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Keep"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let verdict = DragOutRemovalDecision.verdict(
            removeChosen: response == .alertFirstButtonReturn,
            dontAskAgain: alert.suppressionButton?.state == .on
        )
        if let policy = verdict.policyToPersist {
            settings.dragOutRemovalPolicy = policy
        }
        if verdict.shouldRemove {
            removeDraggedItems()
        }
    }
}

/// S8: Decision on the `.ask` strategy confirmation dialog (pure logic, covered by unit tests; NSAlert
/// interaction itself cannot be headless tested). When 'Don't ask again' is checked, the current selection
/// is solidified as the subsequent strategy.
enum DragOutRemovalDecision {
    struct Verdict: Equatable, Sendable {
        /// Whether to remove from the shelf this time.
        var shouldRemove: Bool
        /// Need to write back the solidified strategy to SettingsStore; if 'Don't ask again' is not
        /// checked, it is nil.
        var policyToPersist: SettingsStore.DragOutRemovalPolicy?
    }

    nonisolated static func verdict(removeChosen: Bool, dontAskAgain: Bool) -> Verdict {
        Verdict(shouldRemove: removeChosen,
                policyToPersist: dontAskAgain ? (removeChosen ? .remove : .keep) : nil)
    }
}

// MARK: - Delivery coordination

/// Uniformly record direct drag-out and managed cut delivery: ordinary items are confirmed by AppKit
/// session results; managed cut items must also satisfy both 'target accepts session' and 'file promise
/// has been written' to be removed from the shelf. Session snapshots are also used for failure recovery
/// and runtime file leases.
@MainActor
final class DeliveryCoordinator {
    private enum PromiseState {
        case notRequested
        case requested
        case delivered(URL)
        case failed
    }

    private struct PendingItem {
        let item: ShelfItem
        let insertionIndex: Int
        let supportsFilePromise: Bool
        var promiseState: PromiseState
    }

    private struct PendingSession {
        let id: UUID
        let startedAt: Date
        let orderedItemIDs: [UUID]
        var itemsByID: [UUID: PendingItem]
        var accepted: Bool?
    }

    private var sessions: [UUID: PendingSession] = [:]
    private var latestSessionByItemID: [UUID: UUID] = [:]

    private let store: ShelfStore
    private let recents: RecentItemsService
    private let tempFileService: TempFileService
    private let transferStore: TransferStore
    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "Delivery")

    init(store: ShelfStore,
         recents: RecentItemsService,
         tempFileService: TempFileService,
         transferStore: TransferStore) {
        self.store = store
        self.recents = recents
        self.tempFileService = tempFileService
        self.transferStore = transferStore
    }

    func noteSessionBegan(id: UUID, contents: DragOutContents) {
        let flattened = DragPayloadBuilder.flattenedItems(contents.items)
            .filter(DragPayloadBuilder.canMakePasteboardWriter)
        var itemsByID: [UUID: PendingItem] = [:]
        var orderedItemIDs: [UUID] = []
        for item in flattened where itemsByID[item.id] == nil {
            let strategy = DragPayloadBuilder.strategy(for: item)
            let supportsPromise = item.isCut
                && (strategy == .fileBacked || strategy == .fileBackedImage)
            itemsByID[item.id] = PendingItem(
                item: item,
                insertionIndex: insertionIndex(for: item.id),
                supportsFilePromise: supportsPromise,
                promiseState: .notRequested
            )
            orderedItemIDs.append(item.id)
            latestSessionByItemID[item.id] = id
        }
        guard !orderedItemIDs.isEmpty else { return }
        sessions[id] = PendingSession(id: id,
                                      startedAt: Date(),
                                      orderedItemIDs: orderedItemIDs,
                                      itemsByID: itemsByID,
                                      accepted: nil)
        transferStore.beginExport(id: id, itemIDs: orderedItemIDs)
        trimRetainedSessions()
    }

    func notePromiseRequested(sessionID: UUID, itemID: UUID) {
        guard latestSessionByItemID[itemID] == sessionID,
              var session = sessions[sessionID],
              var pending = session.itemsByID[itemID],
              pending.supportsFilePromise else { return }
        switch pending.promiseState {
        case .notRequested:
            pending.promiseState = .requested
            session.itemsByID[itemID] = pending
            sessions[sessionID] = session
            transferStore.recordExportPromiseRequested(taskID: sessionID, itemID: itemID)
        case .requested, .delivered, .failed:
            break
        }
    }

    func noteDelivered(sessionID: UUID, itemID: UUID, destination: URL) {
        guard latestSessionByItemID[itemID] == sessionID,
              var session = sessions[sessionID],
              var pending = session.itemsByID[itemID],
              pending.supportsFilePromise else { return }
        switch pending.promiseState {
        case .delivered, .failed:
            return
        case .notRequested, .requested:
            pending.promiseState = .delivered(destination)
            session.itemsByID[itemID] = pending
            sessions[sessionID] = session
        }
        guard session.accepted == true else { return }
        transferStore.recordExportDelivered(taskID: sessionID, itemID: itemID)
        if pending.item.isCut {
            finalizeManagedItem(pending.item, destination: destination)
        }
    }

    func noteFailed(sessionID: UUID, itemID: UUID) {
        guard latestSessionByItemID[itemID] == sessionID,
              var session = sessions[sessionID],
              var pending = session.itemsByID[itemID],
              pending.supportsFilePromise else { return }
        switch pending.promiseState {
        case .delivered, .failed:
            return
        case .notRequested, .requested:
            pending.promiseState = .failed
            session.itemsByID[itemID] = pending
            sessions[sessionID] = session
        }
        guard session.accepted == true else { return }
        registerFailure(pending.item,
                        insertionIndex: pending.insertionIndex,
                        sessionID: sessionID)
    }

    func noteSessionEnded(id: UUID, accepted: Bool) {
        guard var session = sessions[id] else { return }
        guard accepted else {
            transferStore.finishExportSession(taskID: id, accepted: false)
            discardSession(id)
            return
        }

        session.accepted = true
        sessions[id] = session
        let directlyAccepted = Set(session.orderedItemIDs.compactMap { itemID -> UUID? in
            guard let pending = session.itemsByID[itemID] else { return nil }
            if !pending.supportsFilePromise { return itemID }
            if !pending.item.isCut, case .notRequested = pending.promiseState {
                return itemID
            }
            return nil
        })
        transferStore.finishExportSession(taskID: id,
                                          accepted: true,
                                          directlyAcceptedItemIDs: directlyAccepted)

        // Promise callbacks may have beaten the AppKit session callback.
        for itemID in session.orderedItemIDs {
            guard let pending = session.itemsByID[itemID] else { continue }
            switch pending.promiseState {
            case .delivered(let destination):
                transferStore.recordExportDelivered(taskID: id, itemID: itemID)
                if pending.item.isCut {
                    finalizeManagedItem(pending.item, destination: destination)
                }
            case .failed:
                registerFailure(pending.item,
                                insertionIndex: pending.insertionIndex,
                                sessionID: id)
            case .notRequested, .requested:
                break
            }
        }
    }

    /// Brackets an AppKit dragging session so the shelf can hide its transfer
    /// strip mid-drag. Call `noteDragSessionStarted` only right before
    /// `beginDraggingSession`; the NSDraggingSource end callback balances it.
    func noteDragSessionStarted() {
        transferStore.noteDragSessionStarted()
    }

    func noteDragSessionEnded() {
        transferStore.noteDragSessionEnded()
    }

    /// Runtime file leases used by Storage settings. A direct drop can remove
    /// a materialized card before a target makes a late promise request; these
    /// snapshots prevent manual cleanup from deleting the only retained bytes.
    var protectedMaterializedPaths: Set<String> {
        let root = tempFileService.directoryURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var result = Set<String>()
        for session in sessions.values where session.accepted == true {
            for pending in session.itemsByID.values {
                guard case .delivered = pending.promiseState else {
                    if !containsItem(pending.item.id),
                       let path = pending.item.path {
                        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
                        if standardized.hasPrefix(prefix) {
                            result.insert(standardized)
                        }
                    }
                    continue
                }
            }
        }
        return result
    }

    private func registerFailure(_ item: ShelfItem,
                                 insertionIndex: Int,
                                 sessionID: UUID) {
        if !containsItem(item.id) {
            store.add(item, at: insertionIndex)
        }
        transferStore.recordExportFailure(
            taskID: sessionID,
            itemID: item.id,
            failure: TransferFailure(
                reason: .deliveryFailed,
                itemName: item.displayName,
                recoveryAction: .retryByDraggingOut(itemID: item.id)
            )
        )
    }

    private func finalizeManagedItem(_ item: ShelfItem, destination: URL) {
        store.invalidateUndoForDeliveredItem(item.id)
        if let path = item.path {
            do {
                try tempFileService.removeMaterializedFile(at: URL(fileURLWithPath: path))
            } catch {
                logger.error("Failed to delete managed cut file \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if store.item(withID: item.id) != nil {
            store.remove(ids: [item.id])
        } else if let stack = store.items.first(where: {
            containsItem(item.id, in: $0.children ?? [])
        }) {
            store.removeChild(item.id, fromStack: stack.id)
        }
        var entry = item
        entry.path = destination.path
        recents.record([entry])
    }

    private func insertionIndex(for itemID: UUID) -> Int {
        if let index = store.index(ofItemWithID: itemID) {
            return index
        }
        return store.items.firstIndex { containsItem(itemID, in: $0.children ?? []) }
            ?? store.items.count
    }

    private func containsItem(_ itemID: UUID) -> Bool {
        store.items.contains { item in
            item.id == itemID || containsItem(itemID, in: item.children ?? [])
        }
    }

    private func containsItem(_ itemID: UUID, in items: [ShelfItem]) -> Bool {
        items.contains { item in
            item.id == itemID || containsItem(itemID, in: item.children ?? [])
        }
    }

    private func discardSession(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        for itemID in session.orderedItemIDs where latestSessionByItemID[itemID] == id {
            latestSessionByItemID.removeValue(forKey: itemID)
        }
    }

    /// Bound runtime snapshots while keeping current/incomplete sessions. The
    /// oldest completed ordinary sessions are the first candidates; active
    /// managed deliveries are never evicted.
    private func trimRetainedSessions() {
        guard sessions.count > 128 else { return }
        let removable = sessions.values
            .filter { session in
                guard session.accepted != nil else { return false }
                return session.itemsByID.values.allSatisfy { pending in
                    !pending.item.isCut && {
                        switch pending.promiseState {
                        case .requested: false
                        case .notRequested, .delivered, .failed: true
                        }
                    }()
                }
            }
            .sorted { $0.startedAt < $1.startedAt }
            .prefix(sessions.count - 128)
            .map(\.id)
        for id in removable {
            discardSession(id)
        }
    }
}

// MARK: - SwiftUI environment

private struct DragOutControllerEnvironmentKey: EnvironmentKey {
    // The default of nil disables dragging in previews and unit tests. Clicking still works.
    static var defaultValue: DragOutController? { nil }
}

extension EnvironmentValues {
    /// Drag out the main control; injected by ShelfWindowController on the root of panel content.
    var dragOutController: DragOutController? {
        get { self[DragOutControllerEnvironmentKey.self] }
        set { self[DragOutControllerEnvironmentKey.self] = newValue }
    }
}
