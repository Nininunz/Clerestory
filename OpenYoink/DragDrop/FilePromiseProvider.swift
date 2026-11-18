import AppKit
import OSLog

/// Direct pasteboard writer for an existing file.
///
/// `NSFilePromiseProvider` in a real `NSDraggingSession` only retains system promise types. Subclasses
/// that override and append file URLs/TIFFs/private tokens will be discarded by AppKit. Regular files
/// therefore use an independent writer to ensure the following accurately represent real drag-and-drop
/// pasteboard entries:
/// - `public.file-url`: Finder, Safari, and most desktop targets;
/// - `NSFilenamesPboardType`: macOS file upload path for Chromium;
/// - Optional `public.tiff`: image bitmap fallback (lazy);
/// - Optional tutorial token: session validation for quick start targets.
nonisolated final class DirectFilePasteboardWriter: NSObject, NSPasteboardWriting {
    private let fileURL: URL
    private let tiffDataProvider: (@Sendable () -> Data?)?
    private let tutorialSessionToken: String?

    init(fileURL: URL,
         tiffDataProvider: (@Sendable () -> Data?)? = nil,
         tutorialSessionToken: String? = nil) {
        self.fileURL = fileURL
        self.tiffDataProvider = tiffDataProvider
        self.tutorialSessionToken = tutorialSessionToken
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var result: [NSPasteboard.PasteboardType] = [
            PasteboardTypes.fileURL,
            PasteboardTypes.legacyFilenames,
        ]
        if tiffDataProvider != nil {
            result.append(PasteboardTypes.tiff)
        }
        if tutorialSessionToken != nil {
            result.append(PasteboardTypes.tutorialSession)
        }
        return result
    }

    /// URLs, compatible filenames, and tutorial tokens are all small and can be written immediately to
    /// avoid missing due to writer lifecycle or special drag-and-drop routing during cross-process target
    /// requests. TIFFs may be larger, so continue to lazily generate them based on pasteboard promises.
    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == PasteboardTypes.tiff ? .promised : []
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case PasteboardTypes.fileURL:
            fileURL.absoluteString as NSString
        case PasteboardTypes.legacyFilenames:
            [fileURL.path] as NSArray
        case PasteboardTypes.tiff where tiffDataProvider != nil:
            tiffDataProvider?()
        case PasteboardTypes.tutorialSession where tutorialSessionToken != nil:
            tutorialSessionToken as NSString?
        default:
            nil
        }
    }
}

/// File-promise writer for hosted clipboard items: delivery is only confirmed after the target
/// successfully writes. Then, `DeliveryCoordinator` will remove the item and clean up the hosted copy.
///
/// This class intentionally maintains **promise-only**. If advertising a file URL, Finder, and other
/// targets may directly read the source path without triggering the promise delegate. The app would then
/// be unable to prove that the target has been written to disk, and the move semantics would lose the
/// security loop. Ordinary (non-cut) files are provided with direct representation by
/// `DirectFilePasteboardWriter`, and this class is not used.
///
/// Concurrency: The provider itself is only constructed on MainActor and handed over to AppKit drag
/// sessions; delegate callbacks occur on the background write queue (`operationQueue(for:)`), so the
/// delegate only holds Sendable values (`Payload` value types, `BookmarkService`, `Logger`, `@Sendable`
/// error callbacks). Non-Sendable providers do not enter the background path.
final class FilePromiseProvider: NSFilePromiseProvider {
    /// All the information required for a single promise write (value types, Sendable).
    struct Payload: Equatable, Sendable {
        /// The source file URL parsed at the start of the drag (the latest path if the bookmark is
        /// resolvable).
        let sourceURL: URL
        /// Secure Bookmark: Re-parsed on write and gain sandbox access (file may be moved during shelf
        /// stay; fallback to `sourceURL` on parsing failure).
        let bookmark: Data?
        /// Recommended file name on target side (`fileNameForType`): Use original file name with
        /// `displayName`.
        let suggestedName: String
        /// Declared promised content UTI (inferred and validated via system declaration table by
        /// extension; folder is `public.folder`; see defense notes in
        /// `DragPayloadBuilder.promisedFileType`).
        let promisedFileType: String
    }

    /// Strongly hold delegate (`NSFilePromiseProvider.delegate` is a weak reference).
    private let promiseDelegate: FilePromiseDelegate

    init(payload: Payload,
         bookmarkService: BookmarkService,
         onPromiseRequested: (@Sendable () -> Void)? = nil,
         onDelivered: (@Sendable (URL) -> Void)? = nil,
         onError: (@Sendable (Error) -> Void)? = nil) {
        let delegate = FilePromiseDelegate(payload: payload,
                                           bookmarkService: bookmarkService,
                                           onPromiseRequested: onPromiseRequested,
                                           onDelivered: onDelivered,
                                           onError: onError)
        self.promiseDelegate = delegate
        // Do not use `super.init(fileType:delegate:)`: NSFilePromiseProvider is an ObjC class cluster, and
        // this initializer internally calls dynamic type `init()`, which triggers an "unimplemented
        // initializer" trap for Swift subclasses (probed in practice). Instead, use the designated
        // initializer `super.init()` and set `fileType`/`delegate` afterward (both are readwrite).
        super.init()
        fileType = payload.promisedFileType
        self.delegate = delegate
    }

    // MARK: - Writing promised files

    /// Resolve the source again when the receiver asks for the file, then
    /// copy it to the receiver's destination under security-scoped access.
    /// A failed bookmark resolution fails delivery and leaves the source intact.
    nonisolated static func writeCopy(of payload: Payload,
                                      to destinationURL: URL,
                                      bookmarkService: BookmarkService) throws {
        let sourceURL = try bookmarkService.resolveFileURL(payload.sourceURL, bookmark: payload.bookmark)
        try bookmarkService.withSecurityScopedAccess(to: sourceURL) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}

/// `NSFilePromiseProviderDelegate` implementation. `writePromiseTo` is executed on the background queue
/// returned by `operationQueue(for:)` (QoS .userInitiated, implementation plan §2.3 "FilePromise
/// Background Write"). Large file copying does not block the main thread.
///
/// Write failure path does not crash: errors are logged via OSLog and returned to the receiving app
/// (completionHandler non-nil), and also reported via `onError` callback (reserved for UI subscription,
/// S10 card error state).
///
/// **Must be `nonisolated`** (fix for real device crash): When the target app requests promise content,
/// the system synchronously calls `operationQueue(for:)` and other methods via
/// `NSFileProviderXPCMessenger` on the **own XPC queue**; this module's default MainActor isolation will
/// trigger `_dispatch_assert_queue_fail` (SIGTRAP crash; QSpace Pro and other promise targets can
/// trigger). The three methods only read and are immutable Sendable states (payload / writeQueue), and any
/// queue call is safe.
nonisolated final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let payload: FilePromiseProvider.Payload
    private let bookmarkService: BookmarkService
    /// Called when the destination selects the promised-file representation.
    private let onPromiseRequested: (@Sendable () -> Void)?
    /// F-05: Write completion (delivery confirmation) callback, parameter is the target URL. Cut items are
    /// removed from shelf and the custody copy is deleted based on this; the callback is triggered on the
    /// write queue, and subscribers must switch actor themselves.
    private let onDelivered: (@Sendable (URL) -> Void)?
    private let onError: (@Sendable (Error) -> Void)?
    private let writeQueue: OperationQueue
    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "FilePromiseProvider")

    init(payload: FilePromiseProvider.Payload,
         bookmarkService: BookmarkService,
         onPromiseRequested: (@Sendable () -> Void)? = nil,
         onDelivered: (@Sendable (URL) -> Void)? = nil,
         onError: (@Sendable (Error) -> Void)?) {
        self.payload = payload
        self.bookmarkService = bookmarkService
        self.onPromiseRequested = onPromiseRequested
        self.onDelivered = onDelivered
        self.onError = onError
        let queue = OperationQueue()
        queue.name = "com.nininunz.Clerestory.FilePromiseWrite"
        queue.qualityOfService = .userInitiated
        self.writeQueue = queue
        super.init()
    }

    /// Recommended file name on target side: displayName original file name (receiving app uses this to
    /// name the materialized file).
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        return payload.suggestedName
    }

    /// Background queue where writing occurs (plan §2.3: userInitiated, does not block main thread).
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }

    /// Called on `writeQueue`: Copy source file to target URL. Any failure will callback with non-nil
    /// error and log, report `onError`, and never throw or crash; on success, first report `onDelivered`
    /// (F-05 delivery confirmation) then callback with nil error.
    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        // This is the first reliable fact that the destination selected the
        // promise representation. `fileNameForType` may be queried while the
        // pasteboard is merely being prepared.
        onPromiseRequested?()
        do {
            try FilePromiseProvider.writeCopy(of: payload, to: url, bookmarkService: bookmarkService)
            onDelivered?(url)
            completionHandler(nil)
        } catch {
            logger.error("File promise write failed for \(self.payload.suggestedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onError?(error)
            completionHandler(error)
        }
    }
}
