import AppKit
import OSLog

/// `NSFilePromiseReceiver` handles: receiving drag-and-drop operations that generate files after being
/// dropped (e.g., from Photos, Safari large images, etc.), materializing them into the directory managed
/// by `TempFileService`, then generating a `ShelfItem` (kind inferred by UTType) + secure bookmark, and
/// callback to MainActor for shelving.
///
/// Process: synchronously extract the receiver inside `performDragOperation` (must read within the drag
/// session), create an independent staging subdirectory for each receiver → `receivePromisedFiles` writes
/// in the background via `OperationQueue` (.userInitiated, non-blocking main thread) → after completion,
/// write staging and intended materialization paths into `PendingImportJournal` → move files to the
/// top-level materialized directory → create bookmark + ShelfItem → synchronize with MainActor for
/// persistent callback. Only delete recovery records after the shelf snapshot is written to disk.
///
/// Error path: prompt the source to re-drag during the receiving phase; once recovery records are
/// established, moving files, bookmarks, or shelf persistence failures will retain the files, and provide
/// a real retry entry in Storage.
@MainActor
final class FilePromiseReceiver {
    private let tempFileService: TempFileService
    private let bookmarkService: BookmarkService
    private let pendingImportJournal: PendingImportJournal
    private let transferStore: TransferStore
    private let operationQueue: OperationQueue
    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "FilePromiseReceiver")

    init(tempFileService: TempFileService,
         bookmarkService: BookmarkService,
         pendingImportJournal: PendingImportJournal,
         transferStore: TransferStore = TransferStore()) {
        self.tempFileService = tempFileService
        self.bookmarkService = bookmarkService
        self.pendingImportJournal = pendingImportJournal
        self.transferStore = transferStore
        self.operationQueue = OperationQueue()
        self.operationQueue.name = "com.nininunz.Clerestory.FilePromiseReceive"
        // Plan §2.3: promise writing is scheduled in the background queue with QoS userInitiated.
        self.operationQueue.qualityOfService = .userInitiated
    }

    /// Extract all promise receivers from the pasteboard during drag-and-drop and dispatch
    /// materialization.
    ///
    /// Must be called within the drag session (`performDragOperation`) — after the session ends, the
    /// pasteboard and receiver's `fileTypes` are no longer reliable. Return the number of successfully
    /// dispatched receivers; returning 0 indicates that promise types were declared but objects could not
    /// be read, and the caller should fall back to subsequent categories like fileURL with priority.
    func receivePromises(from pasteboard: NSPasteboard,
                         taskID: UUID,
                         onItemReady: @escaping @MainActor (ShelfItem) -> Bool) -> Int {
        guard let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty else {
            return 0
        }

        var dispatched = 0
        // P1 Review Fix: All receivers in the same drag share a single staging directory
        // (NSFilePromiseReceiver.h:25: 'All file promisesReceiver's in a drag must specify the same
        // destination location'). Previously, each receiver had its own directory + callback and deletion
        // — but reader callbacks are triggered per file (a single receiver can deliver multiple files),
        // and deleting the directory upon the first file completion would leave no space for subsequent
        // files. Now, shared directory with no cleanup in callbacks: files are immediately moved to the
        // top-level materialized directory; staging leftovers are handled by age-based cleanup at startup.
        let stagingURL: URL
        do {
            stagingURL = try tempFileService.createPromiseStagingDirectory()
        } catch {
            logger.error("Failed to create promise staging directory: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        transferStore.beginImport(id: taskID, expectedCount: nil)
        var expectedFileCount = 0
        let reportSuccess: @MainActor (ShelfItem, UUID) -> Void = {
            [transferStore, pendingImportJournal, logger] item, recoveryID in
            if onItemReady(item) {
                do {
                    try pendingImportJournal.remove(id: recoveryID)
                } catch {
                    // The shelf item is already durable. Keeping a stale
                    // record is safe and startup reconciliation removes it.
                    logger.error("Failed to clear completed pending import \(recoveryID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                transferStore.recordSuccess(taskID: taskID, itemID: item.id)
            } else {
                transferStore.recordFailure(
                    taskID: taskID,
                    failure: TransferFailure(
                        reason: .persistenceFailed,
                        itemName: item.displayName,
                        recoveryAction: .openStorageRecovery
                    )
                )
            }
        }
        let reportFailure: @MainActor (String?, RecoveryAction) -> Void = {
            [transferStore] itemName, recoveryAction in
            transferStore.recordFailure(
                taskID: taskID,
                failure: TransferFailure(
                    reason: .promiseReceiveFailed,
                    itemName: itemName,
                    recoveryAction: recoveryAction
                )
            )
        }
        for receiver in receivers {
            // `fileTypes` are only valid during the drag session and are immediately extracted as value
            // types.
            let promisedTypes = receiver.fileTypes
            dispatched += 1
            // Callbacks are executed on the operationQueue (background): only capture Sendable services
            // and value types, not MainActor-isolated self; success/failure are both routed back to
            // MainActor via closures with Task inside. Closures must explicitly be `@Sendable` (SE-0420:
            // @Sendable closures are always nonisolated) — otherwise, closures formed in MainActor context
            // will carry MainActor isolation and cause `_dispatch_assert_queue_fail` (SIGTRAP crash:
            // occurs when dragging images/GIFs from the browser through promise materialization).
            receiver.receivePromisedFiles(
                atDestination: stagingURL,
                options: [:],
                operationQueue: operationQueue
            ) { @Sendable [tempFileService, bookmarkService, pendingImportJournal, logger] fileURL, error in
                Self.handleMaterializedPromise(
                    fileURL: fileURL,
                    error: error,
                    promisedTypes: promisedTypes,
                    tempFileService: tempFileService,
                    bookmarkService: bookmarkService,
                    pendingImportJournal: pendingImportJournal,
                    logger: logger,
                    completion: { item, recoveryID in
                        Task { @MainActor in
                            reportSuccess(item, recoveryID)
                        }
                    },
                    failure: { recoveryAction in
                        Task { @MainActor in
                            reportFailure(fileURL.lastPathComponent, recoveryAction)
                        }
                    }
                )
            }
            // `fileNames` becomes available after the promise is called in and
            // is a better count than `fileTypes` for legacy multi-file promises.
            // Keep one as the conservative minimum so cancellation still ends
            // the batch when a source reports no names.
            expectedFileCount += max(receiver.fileNames.count, 1)
        }
        transferStore.setExpectedCount(expectedFileCount, for: taskID)
        return dispatched
    }

    /// Background materialization completion handling (OperationQueue context, non-isolated).
    /// Success: Move to the top level of the materialization directory → kind inference + bookmark →
    /// completion.
    /// Failure: Log the error + failure callback (recorded in TransferStore, shown in the Shelf
    /// activity strip).
    /// Callbacks are triggered per file, hence **do not touch shared staging directory** (cleared by
    /// age-based cleanup at startup).
    nonisolated static func handleMaterializedPromise(
        fileURL: URL?,
        error: Error?,
        promisedTypes: [String],
        tempFileService: TempFileService,
        bookmarkService: BookmarkService,
        pendingImportJournal: PendingImportJournal,
        logger: Logger,
        completion: (ShelfItem, UUID) -> Void,
        failure: (RecoveryAction) -> Void
    ) {
        if let error {
            logger.error("File promise materialization failed: \(error.localizedDescription, privacy: .public)")
            failure(.dragAgainFromSource)
            return
        }
        guard let fileURL else {
            logger.error("File promise delivered neither a file URL nor an error; dropping this receiver")
            failure(.dragAgainFromSource)
            return
        }

        var recoveryRecord: PendingImportJournal.Record?
        do {
            let destination = try tempFileService.uniqueFileURL(suggestedName: fileURL.lastPathComponent)
            // This is the crash-safety boundary: both possible payload paths
            // are durable before the move begins.
            let record = try pendingImportJournal.create(
                stagingURL: fileURL,
                destinationURL: destination,
                displayName: fileURL.lastPathComponent,
                promisedTypeIdentifiers: promisedTypes
            )
            recoveryRecord = record
            try FileManager.default.moveItem(at: fileURL, to: destination)
            let bookmark = try bookmarkService.createBookmark(for: destination)
            let item = ShelfItem(
                id: record.id,
                kind: DropImportCoordinator.inferFileKind(
                    for: destination,
                    promisedTypeIdentifiers: promisedTypes
                ),
                path: destination.path,
                bookmark: bookmark,
                // Display name uses the original filename provided by the promise source, without the UUID
                // prefix.
                displayName: record.displayName
            )
            completion(item, record.id)
        } catch {
            logger.error("Failed to finalize materialized promise \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            failure(recoveryRecord == nil ? .dragAgainFromSource : .openStorageRecovery)
        }
    }
}
