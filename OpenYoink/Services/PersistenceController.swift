import Foundation
import OSLog

/// Shared locations inside the app's sandbox container.
enum AppDirectories {
    private static let uiTestDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenYoinkUITests-" + UUID().uuidString, isDirectory: true)

    /// `Application Support/Clerestory` inside the sandbox container.
    static func applicationSupport() -> URL {
        // Allocate before any service can load state. Clearing a shared test
        // directory in applicationWillFinishLaunching is too late for stores
        // initialized by SwiftUI while constructing the app scene.
        if ProcessInfo.processInfo.environment["OPENYOINK_UI_TESTING"] == "1" {
            return uiTestDirectory
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Clerestory", isDirectory: true)
    }
}

/// ISO8601 with fractional seconds, used for dates in `shelf.json` so the file
/// stays human-readable and hand-editable.
private func makeShelfDateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

/// On-disk envelope for `shelf.json`.
private struct ShelfSnapshot: Codable, Sendable {
    var schemaVersion: Int
    var items: [ShelfItem]
}

/// JSON persistence for the shelf's items.
///
/// Storage is a single `shelf.json` in `Application Support/Clerestory` (inside
/// the sandbox container). Writes are atomic (temporary file + rename) and
/// debounced: rapid `scheduleSave(_:)` calls coalesce into one disk write.
@MainActor
final class PersistenceController {
    /// Current on-disk schema version. Bump it and add a migration in
    /// `migrate(_:)` when the format changes.
    static let currentSchemaVersion = 1

    /// Directory containing `shelf.json`; inject a custom one in tests.
    let directoryURL: URL
    /// Debounce interval for `scheduleSave(_:)`; inject a small value in tests.
    let debounceInterval: Duration

    /// Number of completed disk writes (diagnostics and tests).
    private(set) var saveCount = 0

    private var shelfFileURL: URL { directoryURL.appendingPathComponent("shelf.json") }
    private var backupShelfFileURL: URL { directoryURL.appendingPathComponent("shelf.json.backup") }
    private static let corruptSnapshotPrefix = "shelf.json.corrupt-"
    // Older releases recognize this as quarantined recovery data and therefore
    // refuse orphan cleanup instead of deleting archived managed copies.
    private static let removalSnapshotPrefix = "shelf.json.corrupt-removed-"
    private var pendingItems: [ShelfItem]?
    private var saveTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "Persistence")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // .formatted() requires a DateFormatter, which ISO8601DateFormatter is
        // not a subclass of — encode manually.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeShelfDateFormatter().string(from: date))
        }
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            // Accept dates with or without fractional seconds (hand-edited files).
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = makeShelfDateFormatter().date(from: string)
                ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(string)"
            )
        }
        return decoder
    }()

    init(directoryURL: URL? = nil, debounceInterval: Duration = .milliseconds(500)) {
        self.directoryURL = directoryURL ?? AppDirectories.applicationSupport()
        self.debounceInterval = debounceInterval
    }

    // MARK: - Loading

    /// Load result (P1 fix): strictly distinguish between 'no file on first launch' and 'read failure'.
    /// Damaged files must never be silently ignored — the AppDelegate decides whether to allow cleaning up
    /// Materialized orphan files (cleaning is prohibited on load failure, otherwise a single bad write
    /// will cause all custody files to be deleted at the next launch).
    enum LoadResult: Sendable, Equatable {
        /// Successfully read the snapshot (may be empty).
        case loaded([ShelfItem])
        /// File not found (first launch / new state).
        case missing
        /// File exists but reading/decoding failed (isolated to shelf.json.corrupt-<timestamp>).
        case failed

        /// Items used at startup to construct ShelfStore. Failure still allows an empty shelf to enter UI,
        /// but must
        /// retain the same LoadResult, cannot again read and misinterpret isolated files as missing.
        var items: [ShelfItem] {
            guard case .loaded(let items) = self else { return [] }
            return items
        }

        /// Only allow deletion of un-referenced Materialized files when a trusted snapshot is obtained, or
        /// when no snapshot ever existed. These files may still be referenced by corrupted snapshots
        /// during reading failures.
        var permitsMaterializedOrphanCleanup: Bool {
            switch self {
            case .loaded, .missing: true
            case .failed: false
            }
        }
    }

    /// Loads the persisted items. Returns an empty array when the file is
    /// missing or corrupted — see `loadResult()` for the failure-aware variant.
    func load() -> [ShelfItem] {
        loadResult().items
    }

    /// Failure-aware load: missing and failed are separated; when failed, rename the damaged file to
    /// isolate (preserve the scene for manual recovery), then start with a fresh empty shelf.
    func loadResult() -> LoadResult {
        guard FileManager.default.fileExists(atPath: shelfFileURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: shelfFileURL)
            let snapshot = try decoder.decode(ShelfSnapshot.self, from: data)
            return .loaded(migrate(snapshot).items)
        } catch {
            logger.error("Failed to load \(self.shelfFileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            quarantineCorruptFile()
            return .failed
        }
    }

    /// Final safety gate for cleaning up Materialized orphans: this round's read must be trusted, and
    /// there must be
    /// no isolated snapshots left on disk. The latter must take effect across reboots—after damaged files
    /// are moved away, the next read will be `.missing`; if only looking at this round's result, the
    /// second startup would still delete all recovered materials.
    ///
    /// Isolated snapshots are manually moved away after user confirmation to recover or abandon; before
    /// that, it's better to retain a small number of orphans,
    /// and not automatically destroy recoverable data. Directory read exceptions are also treated as
    /// unsafe.
    func canSafelyCleanupMaterializedOrphans(after result: LoadResult) -> Bool {
        guard result.permitsMaterializedOrphanCleanup else { return false }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return true }
        do {
            let names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
            for name in names {
                if Self.isRemovalSnapshotName(name) {
                    // A damaged removal archive can still own the only retained
                    // managed copy. Never infer that its files are unreferenced.
                    guard (try? decodeSnapshot(at: directoryURL.appendingPathComponent(name))) != nil else {
                        return false
                    }
                    continue
                }
                if name.hasPrefix(Self.corruptSnapshotPrefix) { return false }
            }
            return true
        } catch {
            logger.error("Cannot inspect persistence directory before orphan cleanup: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Recovery snapshots

    struct RecoverySnapshot: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case lastKnownGood
            case quarantined
            case removedItems
        }

        let url: URL
        let kind: Kind
        let modifiedAt: Date?
        let byteCount: Int64
        /// Isolated files with `false` are still retained for manual repair, but UI does not allow them to
        /// overwrite current data.
        let isRecoverable: Bool

        var id: URL { url }
    }

    enum RecoveryError: LocalizedError, Equatable {
        case invalidSnapshot
        case snapshotIsUnreadable

        var errorDescription: String? {
            switch self {
            case .invalidSnapshot:
                String(localized: "The selected recovery file is not managed by Clerestory.")
            case .snapshotIsUnreadable:
                String(localized: "This recovery file is damaged and cannot be restored automatically.")
            }
        }
    }

    /// Retains the complete shelf before a batch removal, independently of the
    /// rotating last-known-good backup. Archives are deleted only by an explicit
    /// recovery-data action, so removed managed copies remain protected on launch.
    func saveRemovalRecoverySnapshot(_ items: [ShelfItem]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let snapshot = ShelfSnapshot(schemaVersion: Self.currentSchemaVersion, items: items)
        let data = try encoder.encode(snapshot)
        let url = directoryURL.appendingPathComponent(
            Self.removalSnapshotPrefix + UUID().uuidString + ".json"
        )
        try data.write(to: url, options: .atomic)
    }

    /// Lists independent removal archives, the last known good shelf and
    /// quarantined data. Only fully decodable snapshots are restorable.
    func recoverySnapshots() -> [RecoverySnapshot] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            let kind: RecoverySnapshot.Kind
            if url.lastPathComponent == backupShelfFileURL.lastPathComponent {
                kind = .lastKnownGood
            } else if Self.isRemovalSnapshotName(url.lastPathComponent) {
                kind = .removedItems
            } else if url.lastPathComponent.hasPrefix(Self.corruptSnapshotPrefix) {
                kind = .quarantined
            } else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let recoverable = (try? decodeSnapshot(at: url)) != nil
            return RecoverySnapshot(
                url: url,
                kind: kind,
                modifiedAt: values?.contentModificationDate,
                byteCount: Int64(values?.fileSize ?? 0),
                isRecoverable: recoverable
            )
        }
        .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func loadRecoverySnapshot(_ snapshot: RecoverySnapshot) throws -> [ShelfItem] {
        guard isManagedRecoveryURL(snapshot.url) else { throw RecoveryError.invalidSnapshot }
        do {
            return try decodeSnapshot(at: snapshot.url).items
        } catch {
            throw RecoveryError.snapshotIsUnreadable
        }
    }

    func discardRecoverySnapshot(_ snapshot: RecoverySnapshot) throws {
        guard isManagedRecoveryURL(snapshot.url) else { throw RecoveryError.invalidSnapshot }
        guard FileManager.default.fileExists(atPath: snapshot.url.path) else { return }
        try FileManager.default.removeItem(at: snapshot.url)
    }

    /// Include items from decodable recovery snapshots when deciding which materialized files
    /// to retain. A damaged quarantined snapshot blocks cleanup entirely. A valid backup
    /// protects the files it references.
    func recoverableSnapshotItems() -> [ShelfItem] {
        recoverySnapshots().flatMap { snapshot in
            (try? loadRecoverySnapshot(snapshot)) ?? []
        }
    }

    private func isManagedRecoveryURL(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == directoryURL.standardizedFileURL else {
            return false
        }
        return standardized.lastPathComponent == backupShelfFileURL.lastPathComponent
            || standardized.lastPathComponent.hasPrefix(Self.corruptSnapshotPrefix)
            || Self.isRemovalSnapshotName(standardized.lastPathComponent)
    }

    private static func isRemovalSnapshotName(_ name: String) -> Bool {
        name.hasPrefix(removalSnapshotPrefix) && name.hasSuffix(".json")
    }

    private func decodeSnapshot(at url: URL) throws -> ShelfSnapshot {
        let data = try Data(contentsOf: url)
        return migrate(try decoder.decode(ShelfSnapshot.self, from: data))
    }

    /// Rename the damaged shelf.json to isolate (retained for manual inspection/recovery; next save will
    /// write a new file).
    private func quarantineCorruptFile() {
        let stamp = makeShelfDateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantineURL = directoryURL.appendingPathComponent(Self.corruptSnapshotPrefix + stamp)
        do {
            try FileManager.default.moveItem(at: shelfFileURL, to: quarantineURL)
            logger.warning("Corrupted shelf.json quarantined to \(quarantineURL.path, privacy: .public)")
        } catch {
            // Still return .failed, cleanup safety gate will continue to be closed; clearly record the
            // isolation failure, cannot
            // pretend that a recovery copy has been saved.
            logger.error("Failed to quarantine corrupted shelf.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Saving

    /// Schedules a debounced write. Rapid successive calls coalesce into a
    /// single disk write of the most recent value.
    func scheduleSave(_ items: [ShelfItem]) {
        pendingItems = items
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounceInterval)
            } catch {
                return // cancelled by a newer scheduleSave or flushPendingSave
            }
            guard !Task.isCancelled, let pending = pendingItems else { return }
            pendingItems = nil
            saveTask = nil
            writeToDiskOrLog(pending)
        }
    }

    /// Writes immediately, bypassing the debounce. Throws on I/O errors.
    func saveNow(_ items: [ShelfItem]) throws {
        saveTask?.cancel()
        saveTask = nil
        pendingItems = nil
        try writeToDisk(items)
        saveCount += 1
    }

    /// Forces any pending debounced save to run now, best-effort
    /// (call from `applicationWillTerminate`).
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard let pending = pendingItems else { return }
        pendingItems = nil
        writeToDiskOrLog(pending)
    }

    // MARK: - Internals

    private func writeToDiskOrLog(_ items: [ShelfItem]) {
        do {
            try writeToDisk(items)
            saveCount += 1
        } catch {
            logger.error("Failed to save \(self.shelfFileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Atomic write: encode to a temporary file in the same directory, then
    /// atomically replace the target with it. Deleting the old file first can lose both
    /// snapshots if the move fails or power is lost. A missing snapshot can leave managed
    /// files without references when startup checks for orphans.
    private func writeToDisk(_ items: [ShelfItem]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let snapshot = ShelfSnapshot(schemaVersion: Self.currentSchemaVersion, items: items)
        let data = try encoder.encode(snapshot)
        let temporaryURL = directoryURL.appendingPathComponent("shelf.json.tmp")
        try data.write(to: temporaryURL)
        if fileManager.fileExists(atPath: shelfFileURL.path) {
            // Keep the previous 'decodable' known-good snapshot before each overwrite. .atomic will
            // complete temporary write and replacement in the same directory; backup failure should not
            // prevent the main snapshot from being saved.
            do {
                let previousData = try Data(contentsOf: shelfFileURL)
                _ = try decoder.decode(ShelfSnapshot.self, from: previousData)
                try previousData.write(to: backupShelfFileURL, options: .atomic)
            } catch {
                logger.warning("Could not refresh last-known-good shelf backup: \(error.localizedDescription, privacy: .public)")
            }
            // replaceItemAt is atomic replacement within the same volume; the old file remains unchanged
            // on failure.
            _ = try fileManager.replaceItemAt(shelfFileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: shelfFileURL)
        }
    }

    /// Schema migration hook. v1 is the first schema, so there is nothing to
    /// migrate yet; files written by a newer app version are decoded
    /// best-effort (unknown fields are ignored by the decoder).
    private func migrate(_ snapshot: ShelfSnapshot) -> ShelfSnapshot {
        if snapshot.schemaVersion > Self.currentSchemaVersion {
            logger.warning("shelf.json schema v\(snapshot.schemaVersion) is newer than supported v\(Self.currentSchemaVersion); decoding best-effort")
        }
        return snapshot
    }
}
