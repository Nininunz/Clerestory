import Foundation
import OSLog

/// A record of 'recently dragged out': item summary + time.
struct RecentEntry: Codable, Equatable, Identifiable, Sendable {
    /// Each record has an independent id (same ShelfItem can be dragged out repeatedly, cannot reuse
    /// item.id).
    var id: UUID
    var displayName: String
    var kind: ItemKind
    /// Last known path of file-type items (S10 menu can use this to 'Show in Finder' / re-shelf).
    var path: String?
    var urlString: String?
    /// Text item summary (first 100 characters).
    var textPreview: String?
    var draggedOutAt: Date

    init(item: ShelfItem, draggedOutAt: Date, id: UUID = UUID()) {
        self.id = id
        self.displayName = item.displayName
        self.kind = item.kind
        self.path = item.path
        self.urlString = item.urlString
        self.textPreview = item.text.map { String($0.prefix(100)) }
        self.draggedOutAt = draggedOutAt
    }
}

/// Lightweight recent dragged-out history (implementation plan §2.2 `RecentItemsService`): in-memory array
/// + JSON persistence (`Application Support/Clerestory/recents.json`, a standalone file alongside
/// `shelf.json`), max 20 items, latest first.
///
/// Disk writing follows the atomic write approach of PersistenceController (temporary file + rename), but
/// no debouncing —— dragging out is a low-frequency event, synchronous writing of a small JSON is
/// sufficient. Damaged files are logged, history is rolled back to empty, never crash. The menu bar
/// 'Recent Items' is integrated in S10; this step only provides the API.
@MainActor
@Observable
final class RecentItemsService {
    /// Historical item limit (number of items).
    static let maxEntryCount = 20

    /// Current history, latest first.
    private(set) var entries: [RecentEntry] = []

    /// Storage directory; a temporary directory is injected during testing.
    let directoryURL: URL

    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "RecentItems")

    private var fileURL: URL {
        directoryURL.appendingPathComponent("recents.json")
    }

    private static let currentSchemaVersion = 1

    /// Same date format as PersistenceController (ISO8601 with milliseconds, readable by files).
    /// Non-isolated: encoding/decoding closures are executed in non-isolated context.
    private nonisolated static func makeDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeDateFormatter().string(from: date))
        }
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = makeDateFormatter().date(from: string)
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

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? AppDirectories.applicationSupport()
        self.entries = loadEntries()
    }

    // MARK: - Recording

    /// Record a batch of dragged-out items (insert this batch at the front, maintain drag order within the
    /// batch), trim to the limit, and immediately write to disk. Ignore empty input.
    func record(_ items: [ShelfItem], at date: Date = Date()) {
        guard !items.isEmpty else { return }
        entries.insert(contentsOf: items.map { RecentEntry(item: $0, draggedOutAt: date) }, at: 0)
        if entries.count > Self.maxEntryCount {
            entries.removeLast(entries.count - Self.maxEntryCount)
        }
        saveToDiskOrLog()
    }

    /// Clear history (reserved for S10 menu).
    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        saveToDiskOrLog()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var entries: [RecentEntry]
    }

    /// Read on startup; fallback to empty history if file is missing or damaged (log the error, do not
    /// throw).
    private func loadEntries() -> [RecentEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            if snapshot.schemaVersion > Self.currentSchemaVersion {
                logger.warning("recents.json schema v\(snapshot.schemaVersion) is newer than supported v\(Self.currentSchemaVersion); decoding best-effort")
            }
            return snapshot.entries
        } catch {
            logger.error("Failed to load \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func saveToDiskOrLog() {
        do {
            try writeToDisk()
        } catch {
            logger.error("Failed to save \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Atomic write: encode to a temporary file in the same directory, then atomically replace the target
    /// (same approach as PersistenceController, independent file no debouncing). Never delete the old file
    /// first, otherwise replace/move failure would lose the still usable recent history.
    private func writeToDisk() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let snapshot = Snapshot(schemaVersion: Self.currentSchemaVersion, entries: entries)
        let data = try encoder.encode(snapshot)
        let temporaryURL = directoryURL.appendingPathComponent("recents.json.tmp")
        try data.write(to: temporaryURL)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }
}
