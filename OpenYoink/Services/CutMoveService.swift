import Foundation
import OSLog

/// ⌘+drag-in (cut mode) rearrangement: copy the original file into the vault directory, move the original
/// file to the trash, producing a `isCut = true` ShelfItem (bookmark points to the vault copy).
///
/// Handle each file independently. A failed step falls back to adding a reference. The original only goes
/// to Trash after the managed copy has been verified, so there is always a recoverable copy.
///
/// 1. Source is already inside the app container → reject cut (prevent nesting: vault file 'cut' again
/// would copy itself and move the vault original to trash), silently revert to reference mode;
/// 2. Capture bookmark during drag-and-drop authorization is still valid; actual copy is arranged by the
/// caller to background;
/// 3. `copyItem` to `TempFileService.uniqueFileURL` and validate the copy is in place;
/// 4. Synchronously write to a separate journal the `.prepared` recovery transaction;
/// 5. `FileManager.trashItem` moves the original file to trash (recoverable, safer than removeItem);
/// 6. Trash failure (e.g., read-only volume) → remove the copy, leave original file untouched, revert to
/// reference mode;
/// 7. Mark `.originalTrashed`, then the caller synchronously saves the shelf; only save success clears the
/// transaction. On crash, safe recovery is done on next launch based on source file or copy status.
///
/// `trashOriginal` and `containerURL` can be injected: unit tests use mocks to validate the order and
/// branches (trashItem may not be available in test host), and customize the 'inside container' boundary
/// judgment.
final class CutMoveService: Sendable {
    /// Synchronously captured while the drag pasteboard grant is active.  The
    /// security-scoped bookmark in `referenceItem` lets the expensive copy run
    /// after `performDragOperation` returns.
    struct Request: Equatable, Sendable {
        let sourceURL: URL
        let displayName: String
        let referenceItem: ShelfItem
    }

    /// Reason for reverting to reference mode on move failure.
    enum FallbackReason: Equatable, Sendable {
        /// Source is already inside the app container (prevent nesting), silently revert, no prompt
        /// needed.
        case sourceInsideContainer
        /// Copy to vault directory failed (or copy validation failed): original file remains untouched.
        case copyFailed
        /// Copy is in place but original file failed to move to trash (e.g. read-only volume): copy is
        /// cleared, original file remains.
        case trashFailed
        /// Cannot write recovery transaction before destructive step; copy is cleared, original file
        /// remains.
        case transactionFailed
    }

    /// Result of moving a single file.
    enum Outcome: Equatable, Sendable {
        /// Cut successful: item.isCut = true, path/bookmark points to the preserved copy.
        case moved(ShelfItem)
        /// Fallback reference mode: item is normal (copy semantics), reason is for caller to decide
        /// whether to prompt.
        case fallbackToReference(ShelfItem, FallbackReason)
    }

    let tempFileService: TempFileService
    let bookmarkService: BookmarkService
    let managedMoveJournal: ManagedMoveJournal
    /// Determine root inside the app container (default app container Data root; test injection temporary
    /// directory).
    let containerURL: URL
    /// Original file moved to trash; test injection mock validation orchestration and failure branch.
    let trashOriginal: @Sendable (URL) throws -> URL?

    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "CutMove")

    init(tempFileService: TempFileService,
         bookmarkService: BookmarkService,
         managedMoveJournal: ManagedMoveJournal? = nil,
         containerURL: URL? = nil,
         trashOriginal: (@Sendable (URL) throws -> Void)? = nil) {
        self.tempFileService = tempFileService
        self.bookmarkService = bookmarkService
        self.managedMoveJournal = managedMoveJournal ?? ManagedMoveJournal(
            directoryURL: tempFileService.directoryURL.deletingLastPathComponent()
        )
        // Container Data root = `~/Library/Containers/<id>/Data`; non-sandboxed (test host)
        // Fallback to user Library parent directory semantics is unreliable, so test must inject.
        self.containerURL = containerURL
            ?? AppDirectories.applicationSupport()  // <Data>/Library/Application Support/Clerestory
                .deletingLastPathComponent()        // <Data>/Library/Application Support
                .deletingLastPathComponent()        // <Data>/Library
                .deletingLastPathComponent()        // <Data>
        if let trashOriginal {
            self.trashOriginal = { url in
                try trashOriginal(url)
                return nil
            }
        } else {
            self.trashOriginal = { url in
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                return resultingURL as URL?
            }
        }
    }

    /// Capture normal reference and bookmark during drag-and-drop session while still valid. Caller can
    /// then send a `Request`
    /// To background task, avoiding large file copy blocking MainActor.
    func prepareRequest(for sourceURL: URL, displayName: String) -> Request {
        let referenceItem = DropImportCoordinator.makeFileBackedItem(
            for: sourceURL,
            displayName: displayName,
            bookmarkService: bookmarkService,
            logger: logger
        )
        return Request(sourceURL: sourceURL,
                       displayName: displayName,
                       referenceItem: referenceItem)
    }

    /// Backward-compatible synchronous entry point used by focused service
    /// tests. Production drop handling calls this overload on a detached task.
    func makeCutItem(for sourceURL: URL, displayName: String) -> Outcome {
        makeCutItem(for: prepareRequest(for: sourceURL, displayName: displayName))
    }

    /// Move a single file or folder. Only the managed copy can be permanently deleted during cleanup. On
    /// failure, the original remains in place.
    func makeCutItem(for request: Request) -> Outcome {
        let sourceURL = request.sourceURL
        let displayName = request.displayName
        let referenceItem = request.referenceItem

        // 1. Prevent nesting: source is already inside the app container (e.g. file inside the custody
        // directory is dragged in again).
        guard !isInsideContainer(sourceURL) else {
            return .fallbackToReference(referenceItem, .sourceInsideContainer)
        }

        // 2. Copy to custody directory. First create source bookmark and copy within secure scope (access
        // granted by system at drag-in moment;
        // Explicit bookmark + startAccessing matches existing import path).
        let destination: URL
        do {
            destination = try tempFileService.uniqueFileURL(suggestedName: displayName)
        } catch {
            logger.error("Cut move: failed to allocate managed file URL for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .fallbackToReference(referenceItem, .copyFailed)
        }
        do {
            try bookmarkService.withSecurityScopedAccess(to: sourceURL) {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }
        } catch {
            logger.error("Cut move: copy failed for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination) // Remove the partial copy.
            return .fallbackToReference(referenceItem, .copyFailed)
        }

        // 3. Validate copy is in place.
        guard FileManager.default.fileExists(atPath: destination.path) else {
            logger.error("Cut move: managed copy missing after copy for \(sourceURL.path, privacy: .public)")
            return .fallbackToReference(referenceItem, .copyFailed)
        }

        // 4. Write recovery transaction before any destructive operation. managed item is now fully
        // constructed;
        // If journal write fails, do not proceed to move original file.
        var item = DropImportCoordinator.makeFileBackedItem(
            for: destination,
            displayName: displayName,
            bookmarkService: bookmarkService,
            logger: logger
        )
        item.isCut = true
        do {
            try managedMoveJournal.createPrepared(referenceItem: referenceItem,
                                                  managedItem: item)
        } catch {
            logger.error("Cut move: failed to create recovery transaction for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return .fallbackToReference(referenceItem, .transactionFailed)
        }

        // 5. Move the original to Trash so it remains recoverable. If this fails, clear the journal entry,
        // remove the managed copy, and fall back to adding a reference to the untouched original. If
        // clearing the entry fails, the next launch sees the .prepared record and the existing original
        // and recovers a regular reference.
        let resultingTrashURL: URL?
        do {
            resultingTrashURL = try trashOriginal(sourceURL)
        } catch {
            logger.error("Cut move: trash failed for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? managedMoveJournal.remove(id: item.id)
            try? FileManager.default.removeItem(at: destination)
            return .fallbackToReference(referenceItem, .trashFailed)
        }

        // 6. The original file has been moved to the trash. If the update fails, the old `.prepared`
        // record can still be safely recovered based on 'original path missing + hosted copy exists'. Do
        // not discard successful results because of this.
        do {
            try managedMoveJournal.markOriginalTrashed(id: item.id,
                                                       resultingURL: resultingTrashURL)
        } catch {
            logger.error("Cut move: failed to advance recovery transaction for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // 7. Success: item points to the custody copy, isCut = true. Only after the caller synchronously
        // writes it to the shelf snapshot can the transaction be deleted.
        return .moved(item)
    }

    /// Whether the source path (normalized + resolved symlink) is within the container root.
    private func isInsideContainer(_ url: URL) -> Bool {
        let containerPath = containerURL.standardizedFileURL.resolvingSymlinksInPath().path
        let sourcePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = containerPath.hasSuffix("/") ? containerPath : containerPath + "/"
        return sourcePath.hasPrefix(prefix)
    }
}
